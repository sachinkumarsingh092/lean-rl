#!/usr/bin/env python3
"""Generate diverse seed_plans.jsonl for SFT training.

Each line is {"state": ..., "goal": ..., "verbs": [...]}.
Verb sequences are computed by oracle solvers, then each trajectory
is verified through the Lean binary (every verb admitted, goal achieved).
Only verified trajectories are written out.

Requires the Lean verifier binary to be built:
    cd lean_rl/lean && lake build
"""
from __future__ import annotations

import copy
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))
from lean_rl.server.lean_rl_environment import sample_episode
from lean_rl.server.verifier import LeanVerifier

N_EXAMPLES = 800
OUT = Path(__file__).resolve().parent / "seed_plans.jsonl"


def solve_drain_node(state: dict, goal: dict) -> list[dict] | None:
    target = goal["node"]
    pods_on_target = [
        p for p in state["pods"]
        if p["node"] == target and p["phase"] != "Failed"
    ]
    if not pods_on_target:
        return []
    verbs = []
    for p in pods_on_target:
        verbs.append({
            "op": "deletePodByKey",
            "key": {"kind": "pod", "ns": p["ns"], "name": p["name"]},
        })
    return verbs


def solve_rollout_image(state: dict, goal: dict) -> list[dict] | None:
    dep_id = goal["deployment"]
    new_img = goal["image"]
    dep = next((d for d in state["deployments"] if d["id"] == dep_id), None)
    if dep is None:
        return None
    verbs = []
    if dep["image"] != new_img:
        verbs.append({
            "op": "updateDeployment",
            "key": {"kind": "deployment", "ns": dep["ns"], "name": dep["name"]},
            "resourceVersion": dep["resourceVersion"],
            "spec": {**dep, "image": new_img},
        })
    pods_to_roll = [
        p for p in state["pods"]
        if p["deployment"] == dep_id and p["image"] != new_img
           and p["phase"] == "Running"
    ]
    pod_counter = 0
    for p in pods_to_roll:
        verbs.append({
            "op": "deletePodByKey",
            "key": {"kind": "pod", "ns": p["ns"], "name": p["name"]},
        })
        verbs.append({
            "op": "createPod",
            "spec": {
                "id": p["id"], "deployment": dep_id, "node": p["node"],
                "image": new_img, "phase": "Running", "request": p["request"],
                "name": f"rolled-{pod_counter}", "ns": p["ns"],
                "resourceVersion": 0,
            },
        })
        pod_counter += 1
    return verbs


def solve_scale_to(state: dict, goal: dict) -> list[dict] | None:
    dep_id = goal["deployment"]
    target_replicas = goal["replicas"]
    dep = next((d for d in state["deployments"] if d["id"] == dep_id), None)
    if dep is None:
        return None
    return [{
        "op": "scaleDeployment",
        "key": {"kind": "deployment", "ns": dep["ns"], "name": dep["name"]},
        "resourceVersion": dep["resourceVersion"],
        "replicas": target_replicas,
    }]


SOLVERS = {
    "drainNode": solve_drain_node,
    "rolloutImage": solve_rollout_image,
    "scaleTo": solve_scale_to,
}


def verify_trajectory(verifier: LeanVerifier, state: dict, goal: dict,
                      verbs: list[dict]) -> bool:
    """Step each verb through Lean and check the goal is achieved."""
    s = copy.deepcopy(state)
    for i, verb in enumerate(verbs):
        r = verifier.verify_verb(s, verb)
        if r.stage != "applied":
            print(f"  REJECT step {i}: {r.stage} {r.reject}", file=sys.stderr)
            return False
        s = r.applied_state or s
    g = verifier.verify_goal(s, goal)
    if not g.achieved:
        print(f"  GOAL NOT ACHIEVED after {len(verbs)} steps", file=sys.stderr)
    return g.achieved


def main():
    verifier = LeanVerifier()
    rng = random.Random(42)
    results = []
    rejected = 0
    attempts = 0

    while len(results) < N_EXAMPLES and attempts < N_EXAMPLES * 5:
        attempts += 1
        ep = sample_episode(rng)
        state = ep["initial_state"]
        goal = ep["goal"]
        solver = SOLVERS.get(goal["op"])
        if solver is None:
            continue
        verbs = solver(state, goal)
        if verbs is None:
            continue

        tag = f"[{attempts:3d}] {goal['op']:15s} verbs={len(verbs)}"
        if verify_trajectory(verifier, state, goal, verbs):
            results.append({"state": state, "goal": goal, "verbs": verbs})
            print(f"{tag}  OK ({len(results)}/{N_EXAMPLES})", file=sys.stderr)
        else:
            rejected += 1
            print(f"{tag}  FAIL", file=sys.stderr)

    verifier.close()

    seen = set()
    unique = []
    for r in results:
        key = json.dumps(r, sort_keys=True)
        if key not in seen:
            seen.add(key)
            unique.append(r)
    results = unique

    rng.shuffle(results)
    OUT.write_text(
        "\n".join(json.dumps(r, separators=(",", ":")) for r in results) + "\n"
    )
    print(f"\nWrote {len(results)} verified examples to {OUT}")
    print(f"  attempts={attempts}  rejected={rejected}")

    by_op = {}
    for r in results:
        op = r["goal"]["op"]
        by_op[op] = by_op.get(op, 0) + 1
    for op, count in sorted(by_op.items()):
        print(f"  {op}: {count}")


if __name__ == "__main__":
    main()
