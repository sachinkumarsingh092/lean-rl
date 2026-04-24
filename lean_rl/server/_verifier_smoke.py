"""Smoke test for the Lean verifier subprocess.

Exercises both modes:

  * plan mode: existing trajectory fixtures (t1_ok, t1_pdb_violation,
    anti_affinity_violation) -- regression check that adding the API
    layer didn't break the trajectory verifier.
  * verb mode: the four new verb_*.json fixtures (scale ok, scale
    violating PDB, stale resourceVersion conflict, delete violating
    PDB).

Run from the repo root:
    python -m lean_rl.server._verifier_smoke
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from lean_rl.server.verifier import LeanVerifier, VerbResult, VerifyResult

FIXTURES = Path(__file__).resolve().parents[1] / "lean" / "fixtures"


def _load(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text())


def _ok(label: str) -> None:
    print(f"  PASS  {label}")


def _fail(label: str, detail: str) -> None:
    print(f"  FAIL  {label}: {detail}")
    raise SystemExit(1)


# ---------- plan-mode regressions -----------------------------------------

def check_plan_t1_ok(v: LeanVerifier) -> None:
    fx = _load("t1_ok.json")
    res: VerifyResult = v.verify(fx["state"], fx["plan"]["actions"], fx["id"])
    if not res.ok:
        _fail("plan/t1_ok", f"expected ok=True, got {res.raw}")
    if res.invariants_closed != 3:
        _fail("plan/t1_ok", f"expected invariantsClosed=3, got {res.invariants_closed}")
    _ok("plan/t1_ok")


def check_plan_t1_pdb(v: LeanVerifier) -> None:
    fx = _load("t1_pdb_violation.json")
    res = v.verify(fx["state"], fx["plan"]["actions"], fx["id"])
    if res.ok:
        _fail("plan/t1_pdb_violation", "expected ok=False")
    if not res.violation or res.violation.get("kind") != "pdb":
        _fail("plan/t1_pdb_violation", f"expected pdb violation, got {res.violation}")
    if res.violation_prefix_length != 2:
        _fail("plan/t1_pdb_violation",
              f"expected prefix=2, got {res.violation_prefix_length}")
    _ok("plan/t1_pdb_violation")


def check_plan_anti_affinity(v: LeanVerifier) -> None:
    fx = _load("anti_affinity_violation.json")
    res = v.verify(fx["state"], fx["plan"]["actions"], fx["id"])
    if res.ok:
        _fail("plan/anti_affinity_violation", "expected ok=False")
    if not res.violation or res.violation.get("kind") != "antiAffinity":
        _fail("plan/anti_affinity_violation",
              f"expected antiAffinity violation, got {res.violation}")
    _ok("plan/anti_affinity_violation")


# ---------- verb-mode (new) -----------------------------------------------

def check_verb_scale_ok(v: LeanVerifier) -> None:
    fx = _load("verb_scale_ok.json")
    res: VerbResult = v.verify_verb(fx["state"], fx["verb"], fx["id"])
    if not res.ok:
        _fail("verb/scale_ok", f"expected ok=True, got {res.raw}")
    if res.stage != "applied":
        _fail("verb/scale_ok", f"expected stage=applied, got {res.stage}")
    if res.applied_state is None:
        _fail("verb/scale_ok", "expected appliedState to be present")
    _ok("verb/scale_ok")


def check_verb_scale_pdb(v: LeanVerifier) -> None:
    fx = _load("verb_scale_pdb_violation.json")
    res = v.verify_verb(fx["state"], fx["verb"], fx["id"])
    if res.ok:
        _fail("verb/scale_pdb_violation", "expected ok=False")
    if res.stage != "admission":
        _fail("verb/scale_pdb_violation", f"expected stage=admission, got {res.stage}")
    if not res.reject or res.reject.get("kind") != "forbiddenInvariant":
        _fail("verb/scale_pdb_violation",
              f"expected forbiddenInvariant reject, got {res.reject}")
    if res.reject.get("invariant") != "pdb":
        _fail("verb/scale_pdb_violation",
              f"expected invariant=pdb, got {res.reject.get('invariant')}")
    _ok("verb/scale_pdb_violation")


def check_verb_conflict(v: LeanVerifier) -> None:
    fx = _load("verb_conflict.json")
    res = v.verify_verb(fx["state"], fx["verb"], fx["id"])
    if res.ok:
        _fail("verb/conflict", "expected ok=False")
    if res.stage != "admission":
        _fail("verb/conflict", f"expected stage=admission, got {res.stage}")
    if not res.reject or res.reject.get("kind") != "conflict":
        _fail("verb/conflict", f"expected conflict reject, got {res.reject}")
    if res.reject.get("have") != 7 or res.reject.get("got") != 3:
        _fail("verb/conflict",
              f"expected have=7 got=3, got have={res.reject.get('have')} "
              f"got={res.reject.get('got')}")
    _ok("verb/conflict")


def check_verb_delete_running_pdb(v: LeanVerifier) -> None:
    fx = _load("verb_delete_running_pdb.json")
    res = v.verify_verb(fx["state"], fx["verb"], fx["id"])
    if res.ok:
        _fail("verb/delete_running_pdb", "expected ok=False")
    if res.stage != "admission":
        _fail("verb/delete_running_pdb", f"expected stage=admission, got {res.stage}")
    if not res.reject or res.reject.get("kind") != "forbiddenInvariant":
        _fail("verb/delete_running_pdb",
              f"expected forbiddenInvariant reject, got {res.reject}")
    if res.reject.get("invariant") != "pdb":
        _fail("verb/delete_running_pdb",
              f"expected invariant=pdb, got {res.reject.get('invariant')}")
    _ok("verb/delete_running_pdb")


# ---------- entry ---------------------------------------------------------

CHECKS = [
    check_plan_t1_ok,
    check_plan_t1_pdb,
    check_plan_anti_affinity,
    check_verb_scale_ok,
    check_verb_scale_pdb,
    check_verb_conflict,
    check_verb_delete_running_pdb,
]


def main() -> int:
    print("starting Lean verifier...")
    verifier = LeanVerifier()
    try:
        for check in CHECKS:
            check(verifier)
    finally:
        verifier.close()
    print(f"\nall {len(CHECKS)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
