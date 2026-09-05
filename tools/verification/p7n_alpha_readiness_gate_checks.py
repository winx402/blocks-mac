#!/usr/bin/env python3
"""P7-N sequential Alpha readiness gate.

This gate intentionally runs checks one at a time. Earlier P4/P5 aggregate
checks exposed DerivedData races when multiple scripts built Blocks in
parallel, so this script is the single entry point before Alpha readiness
review.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        return {
            "command": command,
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout_tail": completed.stdout[-2000:],
            "stderr_tail": completed.stderr[-2000:],
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as error:
        return {
            "command": command,
            "ok": False,
            "returncode": None,
            "stdout_tail": ((error.stdout or "")[-2000:] if isinstance(error.stdout, str) else ""),
            "stderr_tail": ((error.stderr or "")[-2000:] if isinstance(error.stderr, str) else ""),
            "timed_out": True,
        }


def main() -> int:
    timeout = 180
    if "--timeout" in sys.argv:
        index = sys.argv.index("--timeout")
        timeout = int(sys.argv[index + 1])

    commands = [
        ["./script/build_and_run.sh", "--verify"],
        ["python3", "tools/verification/p7k_permission_identity_gate_checks.py", "--timeout", str(timeout)],
        # P7-L was coupled to the pre-modularization clipboard source layout.
        # P13-C is its current interaction/layout successor and fails closed
        # against the extracted panel, session, detail, and payload boundaries.
        ["python3", "tools/verification/p13c_clipboard_panel_interaction_layout_checks.py", "--timeout", str(timeout)],
        ["python3", "tools/verification/p7m_translation_settings_productization_checks.py"],
        ["python3", "tools/verification/p7h_clipboard_autopaste_activation_checks.py"],
        ["python3", "tools/verification/p7h_translation_swap_result_sync_checks.py"],
        # P7-I asserted the retired pre-glass bottom tray implementation.
        # Current bottom/side window, layout, resize, and pinned behavior are
        # covered by the P13-C successor above.
        ["python3", "tools/spikes/p2_action_smoke.py", "validate-schemas"],
        ["python3", "tools/spikes/p2_action_smoke.py", "smoke"],
    ]

    results = []
    for command in commands:
        result = run(command, timeout)
        results.append(result)
        if not result["ok"]:
            break

    failures = [result for result in results if not result["ok"]]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7n_alpha_readiness_gate_checks",
        "sequential": True,
        "results": results,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
