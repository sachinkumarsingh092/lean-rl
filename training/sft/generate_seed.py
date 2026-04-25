#!/usr/bin/env python3
"""Generate ~20 verified SFT seed trajectories for Proved-SRE.

Each line of seed_plans.jsonl is {state, goal, verbs} where every verb
passes Lean admission and the final state satisfies the goal.

Usage:  python training/sft/generate_seed.py
"""
from __future__ import annotations

import copy, json, random, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from lean_rl.server.lean_rl_environment import sample_episode
from lean_rl.server.verifier import LeanVerifier

OUT = Path(__file__).resolve().parent / "seed_plans.jsonl"
TARGET = 100


# ---- oracle planners ------------------------------------------------------

def plan_drain(state: dict, goal: dict) -> list[dict]:
    """Delete every live pod on the target node (1 pod in sampled episodes)."""
    target = goal["node"]
    return [
        {"op": "deletePodByKey",
         "key": {"kind": "pod", "ns": p["ns"], "name": p["name"]}}
        for p in state["pods"]
        if p["node"] == target and p["phase"] != "Failed"
    ]


def plan_rollout(state: dict, goal: dict) -> list[dict]:
    """updateDeployment then cycle each old-image pod: delete + createPod(Running).

    createPod with phase=Running keeps availableReplicas >= minAvailable so
    the next deletePodByKey passes PDB admission.
    """
    new_img = goal["image"]
    dep = next(d for d in state["deployments"] if d["id"] == goal["deployment"])

    verbs: list[dict] = [{
        "op": "updateDeployment",
        "key": {"kind": "deployment", "ns": dep["ns"], "name": dep["name"]},
        "resourceVersion": dep["resourceVersion"],
        "spec": {**dep, "image": new_img},
    }]

    old_pods = [p for p in state["pods"]
                if p["deployment"] == dep["id"] and p["image"] != new_img]
    for i, pod in enumerate(old_pods):
        verbs.append({
            "op": "deletePodByKey",
            "key": {"kind": "pod", "ns": pod["ns"], "name": pod["name"]},
        })
        verbs.append({
            "op": "createPod",
            "spec": {
                "id": 0, "deployment": dep["id"], "node": pod["node"],
                "image": new_img, "phase": "Running", "request": pod["request"],
                "name": f"rolled-{i}", "ns": pod["ns"], "resourceVersion": 0,
            },
        })

    return verbs


PLANNERS = {"drainNode": plan_drain, "rolloutImage": plan_rollout}


# ---- verify by stepping through Lean --------------------------------------

def verify_trajectory(verifier: LeanVerifier, state: dict, goal: dict,
                      verbs: list[dict]) -> bool:
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


# ---- main ------------------------------------------------------------------

def main() -> None:
    verifier = LeanVerifier()
    rng = random.Random(42)
    results, attempts = [], 0

    while len(results) < TARGET and attempts < 300:
        attempts += 1
        ep = sample_episode(rng)
        state, goal = ep["initial_state"], ep["goal"]
        planner = PLANNERS.get(goal["op"])
        if not planner:
            continue

        verbs = planner(state, goal)
        tag = f"[{attempts:2d}] {goal['op']:15s} verbs={len(verbs)}"
        ok = verify_trajectory(verifier, state, goal, verbs)
        status = f"OK ({len(results)+1}/{TARGET})" if ok else "FAIL"
        print(f"{tag}  {status}", file=sys.stderr)
        if ok:
            results.append({"state": state, "goal": goal, "verbs": verbs})

    verifier.close()

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as f:
        for r in results:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")

    drains = sum(1 for r in results if r["goal"]["op"] == "drainNode")
    rollouts = len(results) - drains
    print(f"\nWrote {len(results)} trajectories to {OUT}"
          f"  (drain={drains} rollout={rollouts})", file=sys.stderr)
    if len(results) < TARGET:
        sys.exit(1)


if __name__ == "__main__":
    main()
