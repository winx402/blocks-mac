#!/usr/bin/env python3
"""P4-A clipboard recorder foundation checks for Blocks."""

from __future__ import annotations

from retired_p4_step5_cleanup_guard import main as _step5_retired_main

if __name__ == "__main__":
    raise SystemExit(_step5_retired_main(__file__))


import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DERIVED = ROOT / "DerivedData" / "Blocks"
HELPER = DERIVED / "Build" / "Products" / "Debug" / "BlocksLoginItemHelper.app" / "Contents" / "MacOS" / "BlocksLoginItemHelper"
STORE_DIR = ROOT / "apps" / "Blocks" / "RuntimeClipboardRecorder"


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-1200:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    ignored = run(["git", "check-ignore", "apps/Blocks/RuntimeClipboardRecorder/p4a-fixture.json"], args.timeout)
    require(ignored["ok"], "recorder_store_not_ignored", "RuntimeClipboardRecorder must stay gitignored", failures)
    observations["store_gitignored"] = ignored["ok"]

    fixture = run(
        [
            str(HELPER),
            "--recorder-fixture",
            "--store-name",
            "p4a-fixture",
            "--reset",
        ],
        args.timeout,
    )
    require(fixture["ok"], "helper_fixture_failed", fixture["stderr_tail"] or fixture["stdout"], failures)
    parsed: dict[str, Any] | None = None
    if fixture["ok"]:
        try:
            parsed = json.loads(fixture["stdout"])
        except json.JSONDecodeError as error:
            failures.append({"code": "helper_fixture_json_failed", "detail": str(error)})
    report = (parsed or {}).get("report", {})
    require(parsed is not None and parsed.get("ok") is True, "helper_fixture_not_ok", fixture["stdout"], failures)
    require(report.get("record_count") == 5, "fixture_record_count_wrong", str(report), failures)
    require(report.get("restorable_count") == 4, "fixture_restorable_count_wrong", str(report), failures)
    require(report.get("excluded_count") == 1, "fixture_excluded_count_wrong", str(report), failures)
    observations["helper_fixture"] = {
        "ok": bool(parsed and parsed.get("ok") is True),
        "record_count": report.get("record_count"),
        "restorable_count": report.get("restorable_count"),
        "excluded_count": report.get("excluded_count"),
        "store_file": report.get("store_file"),
        "sandbox_default_store_used": True,
        "warnings": report.get("warnings", []),
    }

    output = {
        "ok": not failures,
        "suite": "p4a_clipboard_recorder_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
