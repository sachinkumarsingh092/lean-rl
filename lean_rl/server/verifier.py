# lean_rl/server/verifier.py
"""Thin Python client over the long-lived Lean verifier subprocess.

The Lean binary speaks a line protocol on stdin/stdout. Each request is one
JSON object per line; each response is one JSON object per line. The Lean
side dispatches on the optional "mode" field:

    {"mode": "plan", ...}  -> trajectory verification (existing behaviour)
    {"mode": "verb", ...}  -> single K8s-style ApiVerb verification

Both calls go over the same subprocess; only `verify_verb` is new. The
plan-mode `verify` API is unchanged for back-compat with existing callers
and fixtures.
"""

import json
import os
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

LEAN_BIN = Path(os.getenv(
    "LEAN_VERIFY_BIN",
    Path(__file__).resolve().parents[1] / "lean" / ".lake" / "build" / "bin" / "provedsre",
))


@dataclass
class VerifyResult:
    """Result of a plan-mode (trajectory) verification."""

    ok: bool
    violation: dict | None
    invariants_closed: int
    trajectory_length: int
    violation_prefix_length: int
    error: str | None
    raw: dict


@dataclass
class VerbResult:
    """Result of a verb-mode (single ApiVerb) verification.

    `stage` is one of:
        "wire"       - JSON parse / schema error before admission ran
        "admission"  - admission rejected the verb (notFound, conflict,
                       forbiddenInvariant, ...)
        "applied"    - verb was admitted and applied; `applied_state`
                       holds the new cluster state
    """

    ok: bool
    stage: str
    reject: dict | None = None
    applied_state: dict | None = None
    raw: dict = field(default_factory=dict)


class LeanVerifier:
    """Long-lived Lean subprocess; one call per line."""

    def __init__(self, binary: Path = LEAN_BIN):
        self._binary = binary
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()
        self._start()

    def _start(self) -> None:
        self._proc = subprocess.Popen(
            [str(self._binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,                         # line-buffered
        )
        handshake = self._proc.stdout.readline()
        if not handshake or "ready" not in handshake:
            raise RuntimeError(f"verify binary did not handshake: {handshake!r}")

    def _roundtrip(self, payload: dict) -> dict[str, Any]:
        request = json.dumps(payload, separators=(",", ":"))
        with self._lock:
            assert self._proc and self._proc.stdin and self._proc.stdout
            self._proc.stdin.write(request + "\n")
            self._proc.stdin.flush()
            line = self._proc.stdout.readline()
        if not line:
            raise RuntimeError("verify binary terminated unexpectedly")
        return json.loads(line)

    # ---- plan mode (trajectory) -------------------------------------------

    def verify(self, state: dict, plan: list[dict], req_id: str = "") -> VerifyResult:
        data = self._roundtrip({
            "mode": "plan",
            "id": req_id,
            "state": state,
            "plan": {"actions": plan},
        })
        return VerifyResult(
            ok=bool(data["ok"]),
            violation=data.get("violation"),
            invariants_closed=int(data["invariantsClosed"]),
            trajectory_length=int(data["trajectoryLength"]),
            violation_prefix_length=int(data["violationPrefixLength"]),
            error=data.get("error"),
            raw=data,
        )

    # ---- verb mode (single ApiVerb) ---------------------------------------

    def verify_verb(self, state: dict, verb: dict, req_id: str = "") -> VerbResult:
        data = self._roundtrip({
            "mode": "verb",
            "id": req_id,
            "state": state,
            "verb": verb,
        })
        return VerbResult(
            ok=bool(data["ok"]),
            stage=str(data["stage"]),
            reject=data.get("reject"),
            applied_state=data.get("appliedState"),
            raw=data,
        )

    def close(self) -> None:
        if self._proc:
            try:
                self._proc.stdin.close()
                self._proc.wait(timeout=2)
            except Exception:
                self._proc.kill()
            self._proc = None
