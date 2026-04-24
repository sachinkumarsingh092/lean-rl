# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

"""Proved-SRE RL environment.

Architecture:
    agent -> SREAction (one ApiVerb)
          -> Lean.verify_verb            (judge: admit / reject)
          -> world.apply_admitted        (kwok or pure-Lean)
          -> world.project_state         (re-read; never trust Lean's predicted state)
          -> Lean.verify_goal            (episode termination)
          -> reward + mask + snapshot

This file deliberately keeps every concern as one small function or class
in one place. Split only if a piece grows beyond ~50 lines.

Configuration via env vars:
    WORLD_BACKEND   "lean" (default) | "kwok"
    SRE_SEED        int; deterministic episode generation when set
    SRE_RUNS_DIR    if set, JSONL trajectories are written under this dir
"""

from __future__ import annotations

import json
import os
import random
import subprocess
import time
from pathlib import Path
from typing import Any
from uuid import uuid4

from openenv.core.env_server.interfaces import Environment
from openenv.core.env_server.types import State

try:
    from ..models import SREAction, SREObservation
    from .verifier import LeanVerifier
except ImportError:
    from models import SREAction, SREObservation
    from server.verifier import LeanVerifier


# ---- World backends -------------------------------------------------------

class WorldLean:
    """Pure-Lean world: Lean's `apply` IS the world. Deterministic, no infra."""

    def __init__(self) -> None:
        self._state: dict[str, Any] = {"nodes": [], "deployments": [], "pods": [], "tick": 0}

    def reset(self, initial: dict) -> None:
        self._state = initial

    def project_state(self) -> dict:
        return self._state

    def apply_admitted(self, verb: dict, lean_post: dict) -> None:
        # Trusted because Lean's apply IS the world here.
        self._state = lean_post

    def wait_quiescent(self) -> bool:
        return True


class WorldKwok:
    """kwok-backed world. Bring up a cluster once with `kwokctl create cluster`
    (https://kwok.sigs.k8s.io/) and have `kubectl` on PATH pointed at it via
    KUBECONFIG / current context. Tear down with `kwokctl delete cluster`.

    Identity contract with Lean's Nat ids:
        - Lean ids (NodeId / DeploymentId / PodId / Image) are stored on the
          K8s object as a label `lean.id/<kind>=<n>`, plus `lean.id/image=<n>`
          on pods/deployments. project_state reads them back so round-trip is
          stable.
        - PodPhase: K8s `Pending|Running|Succeeded|Failed` -> Lean
          `Pending|Running|Failed`. Pods with `metadata.deletionTimestamp`
          set are reported as `Terminating`.
    """

    LABEL = "lean.id"
    NS = "default"

    def __init__(self) -> None:
        # Sanity check: cluster reachable.
        self._kc("cluster-info")

    # ---- low-level kubectl --------------------------------------------------

    def _kc(self, *args: str, stdin: str | None = None, check: bool = True) -> str:
        r = subprocess.run(
            ["kubectl", *args],
            input=stdin, capture_output=True, text=True,
        )
        if check and r.returncode != 0:
            raise RuntimeError(f"kubectl {' '.join(args)} failed: {r.stderr.strip()}")
        return r.stdout

    def _apply(self, manifests: list[dict]) -> None:
        doc = "\n---\n".join(json.dumps(m) for m in manifests)
        self._kc("apply", "-f", "-", stdin=doc)

    def _get_json(self, what: str) -> dict:
        return json.loads(self._kc("get", what, "-A", "-o", "json"))

    # ---- manifest builders --------------------------------------------------

    def _node_manifest(self, n: dict) -> dict:
        return {
            "apiVersion": "v1", "kind": "Node",
            "metadata": {
                "name": f"node-{n['id']}",
                "labels": {
                    f"{self.LABEL}/node": str(n["id"]),
                    "type": "kwok",
                    "kubernetes.io/hostname": f"node-{n['id']}",
                },
                "annotations": {"node.alpha.kubernetes.io/ttl": "0"},
            },
            "spec": {
                "taints": [{"key": "kwok.x-k8s.io/node", "value": "fake",
                            "effect": "NoSchedule"}],
                "unschedulable": bool(n.get("cordoned", False)),
            },
            "status": {
                "capacity": {"cpu": str(n["capacity"]["cpu"]),
                             "memory": f"{n['capacity']['mem']}Gi", "pods": "110"},
                "allocatable": {"cpu": str(n["capacity"]["cpu"]),
                                "memory": f"{n['capacity']['mem']}Gi", "pods": "110"},
                "conditions": [{"type": "Ready", "status": "True"}],
            },
        }

    def _deployment_manifest(self, d: dict) -> dict:
        lean_labels = {
            f"{self.LABEL}/deployment": str(d["id"]),
            f"{self.LABEL}/image": str(d["image"]),
            f"{self.LABEL}/cpu": str(d["request"]["cpu"]),
            f"{self.LABEL}/mem": str(d["request"]["mem"]),
        }
        return {
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {
                "name": d["name"], "namespace": d.get("ns", self.NS),
                "labels": {
                    **lean_labels,
                    f"{self.LABEL}/minAvailable": str(d["minAvailable"]),
                    f"{self.LABEL}/antiAffinity": str(d["antiAffinity"]).lower(),
                },
            },
            "spec": {
                "replicas": d["desired"],
                "selector": {"matchLabels": {"app": d["name"]}},
                "template": {
                    "metadata": {"labels": {"app": d["name"], **lean_labels}},
                    "spec": {
                        "tolerations": [{"key": "kwok.x-k8s.io/node",
                                         "operator": "Exists", "effect": "NoSchedule"}],
                        "containers": [{"name": "main", "image": f"image-{d['image']}"}],
                    },
                },
            },
        }

    def _pod_manifest(self, p: dict, dep_name_by_id: dict[int, str]) -> dict:
        dep_name = dep_name_by_id.get(p["deployment"], f"dep-{p['deployment']}")
        return {
            "apiVersion": "v1", "kind": "Pod",
            "metadata": {
                "name": p["name"], "namespace": p.get("ns", self.NS),
                "labels": {
                    "app": dep_name,
                    f"{self.LABEL}/pod": str(p["id"]),
                    f"{self.LABEL}/deployment": str(p["deployment"]),
                    f"{self.LABEL}/image": str(p["image"]),
                    f"{self.LABEL}/cpu": str(p["request"]["cpu"]),
                    f"{self.LABEL}/mem": str(p["request"]["mem"]),
                },
            },
            "spec": {
                "nodeName": f"node-{p['node']}",
                "tolerations": [{"key": "kwok.x-k8s.io/node", "operator": "Exists",
                                 "effect": "NoSchedule"}],
                "containers": [{"name": "main", "image": f"image-{p['image']}"}],
            },
        }

    # ---- World interface ----------------------------------------------------

    def reset(self, initial: dict) -> None:
        # Wipe prior state in the namespace, then create everything fresh.
        self._kc("delete", "deploy,pods", "-n", self.NS, "--all",
                 "--ignore-not-found", check=False)
        self._kc("delete", "nodes", "-l", f"{self.LABEL}/node",
                 "--ignore-not-found", check=False)
        dep_names = {d["id"]: d["name"] for d in initial["deployments"]}
        manifests = (
            [self._node_manifest(n) for n in initial["nodes"]]
            + [self._deployment_manifest(d) for d in initial["deployments"]]
            + [self._pod_manifest(p, dep_names) for p in initial["pods"]]
        )
        self._apply(manifests)
        self.wait_quiescent()

    def project_state(self) -> dict:
        nodes_j = self._get_json("nodes")
        deps_j = self._get_json("deployments")
        pods_j = self._get_json("pods")

        def lbl(o: dict, k: str, default: str = "0") -> str:
            return o["metadata"].get("labels", {}).get(f"{self.LABEL}/{k}", default)

        def rv(o: dict) -> int:
            return int(o["metadata"].get("resourceVersion", "0"))

        nodes = [{
            "id": int(lbl(o, "node")),
            "capacity": {"cpu": int(o["status"]["capacity"]["cpu"]),
                         "mem": int(o["status"]["capacity"]["memory"].rstrip("Gi") or "0")},
            "cordoned": bool(o["spec"].get("unschedulable", False)),
        } for o in nodes_j["items"] if lbl(o, "node", "") != ""]

        deployments = [{
            "id": int(lbl(o, "deployment")),
            "desired": int(o["spec"].get("replicas", 0)),
            "image": int(lbl(o, "image")),
            "request": {"cpu": int(lbl(o, "cpu")), "mem": int(lbl(o, "mem"))},
            "minAvailable": int(lbl(o, "minAvailable")),
            "antiAffinity": lbl(o, "antiAffinity", "false") == "true",
            "name": o["metadata"]["name"],
            "ns": o["metadata"].get("namespace", self.NS),
            "resourceVersion": rv(o),
        } for o in deps_j["items"] if lbl(o, "deployment", "") != ""]

        def phase_of(o: dict) -> str:
            if o["metadata"].get("deletionTimestamp"):
                return "Terminating"
            p = o.get("status", {}).get("phase", "Pending")
            return "Failed" if p == "Succeeded" else p

        def pod_id(o: dict) -> int:
            v = lbl(o, "pod", "")
            if v:
                return int(v)
            # Backfill stable id for controller-created pods (e.g. via scale).
            return abs(hash(o["metadata"]["uid"])) % (1 << 31)

        pods = [{
            "id": pod_id(o),
            "deployment": int(lbl(o, "deployment")),
            "node": int((o["spec"].get("nodeName") or "node-0").split("-")[-1]),
            "image": int(lbl(o, "image")),
            "phase": phase_of(o),
            "request": {"cpu": int(lbl(o, "cpu")), "mem": int(lbl(o, "mem"))},
            "name": o["metadata"]["name"],
            "ns": o["metadata"].get("namespace", self.NS),
            "resourceVersion": rv(o),
        } for o in pods_j["items"] if lbl(o, "deployment", "") != ""]

        return {"nodes": nodes, "deployments": deployments, "pods": pods, "tick": 0}

    def apply_admitted(self, verb: dict, lean_post: dict) -> None:
        op = verb["op"]
        if op == "createPod":
            spec = verb["spec"]
            dep_names = {d["id"]: d["name"] for d in lean_post["deployments"]}
            self._apply([self._pod_manifest(spec, dep_names)])
        elif op == "createDeployment":
            self._apply([self._deployment_manifest(verb["spec"])])
        elif op == "updateDeployment":
            self._apply([self._deployment_manifest(verb["spec"])])
        elif op == "scaleDeployment":
            k = verb["key"]
            self._kc("scale", "deployment", k["name"],
                     "-n", k.get("ns", self.NS),
                     f"--replicas={verb['replicas']}")
        elif op == "deletePodByKey":
            k = verb["key"]
            self._kc("delete", "pod", k["name"],
                     "-n", k.get("ns", self.NS),
                     "--grace-period=0", "--force", "--ignore-not-found")
        else:
            raise ValueError(f"unknown verb op: {op}")
        self.wait_quiescent()

    def wait_quiescent(self, timeout_s: float = 10.0, poll_s: float = 0.25) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            pods = self._get_json("pods")["items"]
            deps = self._get_json("deployments")["items"]
            pods_ok = all(
                p.get("status", {}).get("phase") in ("Running", "Failed", "Succeeded")
                and not p["metadata"].get("deletionTimestamp")
                for p in pods if p["metadata"].get("labels", {}).get(f"{self.LABEL}/pod")
            )
            deps_ok = all(
                d.get("status", {}).get("observedGeneration", 0)
                >= d["metadata"].get("generation", 0)
                for d in deps if d["metadata"].get("labels", {}).get(f"{self.LABEL}/deployment")
            )
            if pods_ok and deps_ok:
                return True
            time.sleep(poll_s)
        return False


def make_world() -> "WorldLean | WorldKwok":
    backend = os.getenv("WORLD_BACKEND", "lean")
    return WorldKwok() if backend == "kwok" else WorldLean()


# ---- Episode generator ----------------------------------------------------

def sample_episode(rng: random.Random) -> dict:
    """A tiny drainNode scenario: 3 nodes, 2-pod anti-affinity deployment,
    pick one node to drain. PDB minAvailable=1 so at most one pod can be gone.
    """
    n_nodes = 3
    target = rng.randrange(n_nodes)
    nodes = [
        {"id": i, "capacity": {"cpu": 4, "mem": 8}, "cordoned": False}
        for i in range(n_nodes)
    ]
    deployments = [{
        "id": 0, "desired": 2, "image": 1,
        "request": {"cpu": 1, "mem": 1},
        "minAvailable": 1, "antiAffinity": True,
        "name": "api", "ns": "default", "resourceVersion": 1,
    }]
    other = (target + 1) % n_nodes
    pods = [
        {"id": 0, "deployment": 0, "node": other, "image": 1,
         "phase": "Running", "request": {"cpu": 1, "mem": 1},
         "name": "api-0", "ns": "default", "resourceVersion": 2},
        {"id": 1, "deployment": 0, "node": target, "image": 1,
         "phase": "Running", "request": {"cpu": 1, "mem": 1},
         "name": "api-1", "ns": "default", "resourceVersion": 3},
    ]
    return {
        "initial_state": {"nodes": nodes, "deployments": deployments, "pods": pods, "tick": 0},
        "goal": {"op": "drainNode", "node": target},
        "max_steps": 8,
    }


# ---- Reward ---------------------------------------------------------------

GOAL_REWARD = 5.0
STEP_COST = -0.05
APPLY_PENALTY = -0.5
WIRE_PENALTY = -1.0

_INVARIANT_PENALTY = {"pdb": -2.0, "capacity": -1.0, "antiAffinity": -1.0}
_ADMISSION_PENALTY = {"parseError": -1.0, "schemaError": -1.0, "notFound": -0.2, "conflict": -0.2}


def reward_from_verb(stage: str, reject: dict | None) -> float:
    if stage == "wire":
        return WIRE_PENALTY
    if stage != "admission":
        return 0.0
    kind = (reject or {}).get("kind", "")
    if kind == "forbiddenInvariant":
        return _INVARIANT_PENALTY.get((reject or {}).get("invariant", ""), -1.0)
    return _ADMISSION_PENALTY.get(kind, -0.5)


# ---- Action mask ----------------------------------------------------------

def action_mask(state: dict) -> dict[str, Any]:
    """Cheap addressability hints for the agent: what's targetable right now."""
    return {
        "deployments": [
            {"name": d["name"], "ns": d["ns"], "resourceVersion": d["resourceVersion"]}
            for d in state.get("deployments", [])
        ],
        "pods": [
            {"name": p["name"], "ns": p["ns"]}
            for p in state.get("pods", [])
        ],
    }


# ---- Trajectory snapshot --------------------------------------------------

class TrajectoryWriter:
    """One JSONL file per episode under SRE_RUNS_DIR. Disabled if dir is None."""

    def __init__(self, root: str | None) -> None:
        self._root = Path(root) if root else None
        if self._root:
            self._root.mkdir(parents=True, exist_ok=True)
        self._fp = None

    def open(self, episode_id: str) -> None:
        self.close()
        if self._root:
            self._fp = (self._root / f"{episode_id}.jsonl").open("w")

    def write(self, **row) -> None:
        if self._fp:
            self._fp.write(json.dumps(row, separators=(",", ":")) + "\n")

    def close(self) -> None:
        if self._fp:
            self._fp.close()
            self._fp = None


# ---- Environment ----------------------------------------------------------

class LeanRlEnvironment(Environment):
    """Proved-SRE RL gym. Lean is the judge, the world (Lean or kwok) executes."""

    SUPPORTS_CONCURRENT_SESSIONS: bool = False

    def __init__(self) -> None:
        seed = os.getenv("SRE_SEED")
        self._rng = random.Random(int(seed)) if seed else random.Random()
        self._verifier = LeanVerifier()
        self._world = make_world()
        self._snap = TrajectoryWriter(os.getenv("SRE_RUNS_DIR"))
        self._episode: dict | None = None
        self._step_idx = 0
        self._done = False
        self._state_obj = State(episode_id=str(uuid4()), step_count=0)

    @property
    def state(self) -> State:
        return self._state_obj

    def reset(self) -> SREObservation:
        self._episode = sample_episode(self._rng)
        self._world.reset(self._episode["initial_state"])
        self._step_idx = 0
        self._done = False
        eid = str(uuid4())
        self._state_obj = State(episode_id=eid, step_count=0)
        self._snap.open(eid)
        s = self._world.project_state()
        return SREObservation(
            state=s, goal=self._episode["goal"], mask=action_mask(s),
            reward=0.0, done=False,
        )

    def step(self, action: SREAction) -> SREObservation:  # type: ignore[override]
        assert self._episode is not None, "call reset() before step()"
        verb = action.verb
        s_pre = self._world.project_state()

        v = self._verifier.verify_verb(s_pre, verb)
        reward = reward_from_verb(v.stage, v.reject)
        s_post = s_pre

        if v.stage == "applied":
            self._world.apply_admitted(verb, v.applied_state or s_pre)
            if not self._world.wait_quiescent():
                reward += APPLY_PENALTY
                self._done = True
            s_post = self._world.project_state()

        g = self._verifier.verify_goal(s_post, self._episode["goal"])
        reward += STEP_COST + (GOAL_REWARD if g.achieved else 0.0)

        self._step_idx += 1
        self._state_obj.step_count = self._step_idx
        if g.achieved or self._step_idx >= self._episode["max_steps"]:
            self._done = True

        self._snap.write(
            step=self._step_idx, action=verb,
            stage=v.stage, reject=v.reject,
            achieved=g.achieved, reward=reward, state=s_post,
        )
        if self._done:
            self._snap.close()

        return SREObservation(
            state=s_post, goal=self._episode["goal"], mask=action_mask(s_post),
            reward=reward, done=self._done,
            metadata={"stage": v.stage, "reject": v.reject, "achieved": g.achieved},
        )


if __name__ == "__main__":
    env = LeanRlEnvironment()
    obs = env.reset()
    print("reset goal:", obs.goal)
    target = obs.goal["node"]
    pod_on_target = next(p for p in obs.state["pods"] if p["node"] == target)
    obs = env.step(SREAction(verb={
        "op": "deletePodByKey",
        "key": {"kind": "pod", "ns": pod_on_target["ns"], "name": pod_on_target["name"]},
    }))
    print("step:", "reward=", obs.reward, "done=", obs.done, "info=", obs.metadata)
    env._verifier.close()
