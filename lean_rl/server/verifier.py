# proposed: lean_rl/server/verifier.py
import json
import os
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any

LEAN_BIN = Path(os.getenv(
    "LEAN_VERIFY_BIN",
    Path(__file__).resolve().parents[2] / "lean" / ".lake" / "build" / "bin" / "provedsre",
))


@dataclass
class VerifyResult:
    ok: bool
    violation: dict | None
    invariants_closed: int
    trajectory_length: int
    violation_prefix_length: int
    error: str | None
    raw: dict


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

    def verify(self, state: dict, plan: list[dict], req_id: str = "") -> VerifyResult:
        request = json.dumps({"id": req_id, "state": state,
                              "plan": {"actions": plan}}, separators=(",", ":"))
        with self._lock:
            assert self._proc and self._proc.stdin and self._proc.stdout
            self._proc.stdin.write(request + "\n")
            self._proc.stdin.flush()
            line = self._proc.stdout.readline()
        if not line:
            raise RuntimeError("verify binary terminated unexpectedly")
        data: dict[str, Any] = json.loads(line)
        return VerifyResult(
            ok=bool(data["ok"]),
            violation=data.get("violation"),
            invariants_closed=int(data["invariantsClosed"]),
            trajectory_length=int(data["trajectoryLength"]),
            violation_prefix_length=int(data["violationPrefixLength"]),
            error=data.get("error"),
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