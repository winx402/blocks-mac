#!/usr/bin/env python3
"""Batch runner for P2-K redacted technical validation.

The runner stores only bounded summaries under the ignored
tools/spikes/p2k_validation_output/ directory. It does not persist raw command
streams, screenshots, clipboard content, secrets, or provider event logs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = ROOT / "tools" / "spikes" / "p2k_validation_output"


def audit_id(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, sort_keys=True, ensure_ascii=False, default=str)
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]
    return f"p2k_{int(time.time())}_{digest}"


def checks() -> list[dict[str, Any]]:
    login_bin = (
        "tools/spikes/blocks_login_item_probe/.build/"
        "BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe"
    )
    return [
        {
            "id": "swift_build_macos_probe",
            "command": ["swift", "build", "--package-path", "tools/spikes/blocks_macos_probe"],
            "kind": "build",
        },
        {
            "id": "capture_boundary_suite",
            "command": [
                "swift",
                "run",
                "--package-path",
                "tools/spikes/blocks_macos_probe",
                "BlocksMacOSProbe",
                "blocks-capture",
                "--boundary-suite",
                "--write-png",
            ],
            "kind": "json",
        },
        {
            "id": "pasteboard_complex_roundtrip",
            "command": [
                "swift",
                "run",
                "--package-path",
                "tools/spikes/blocks_macos_probe",
                "BlocksMacOSProbe",
                "blocks-pasteboard",
                "--complex-fixture-roundtrip",
                "--kind",
                "all",
            ],
            "kind": "json",
        },
        {
            "id": "pasteboard_detection_patterns",
            "command": [
                "swift",
                "run",
                "--package-path",
                "tools/spikes/blocks_macos_probe",
                "BlocksMacOSProbe",
                "blocks-pasteboard",
                "--detection-patterns-fixture",
            ],
            "kind": "json",
        },
        {
            "id": "build_login_item_probe",
            "command": ["./tools/spikes/blocks_login_item_probe/scripts/build.sh"],
            "kind": "build",
        },
        {
            "id": "login_helper_recorder_roundtrip",
            "command": [login_bin, "blocks-login-helper", "--recorder-roundtrip", "--seconds", "8"],
            "kind": "json",
        },
        {
            "id": "login_helper_restart_policy",
            "command": [login_bin, "blocks-login-helper", "--restart-policy-check"],
            "kind": "json",
        },
        {
            "id": "login_helper_unregister",
            "command": [login_bin, "blocks-login-helper", "--unregister"],
            "kind": "json",
        },
        {
            "id": "login_helper_no_residue",
            "command": ["pgrep", "-fl", "BlocksLoginItemHelper"],
            "kind": "pgrep_absent",
        },
        {
            "id": "provider_settings_smoke",
            "command": [sys.executable, "tools/spikes/blocks_provider_settings_smoke.py", "smoke"],
            "kind": "json",
        },
        {
            "id": "codex_provider_smoke",
            "command": [sys.executable, "tools/spikes/blocks_provider_smoke.py", "codex", "--timeout", "120"],
            "kind": "json",
        },
        {
            "id": "swift_schema_validator_probe",
            "command": ["swift", "test", "--package-path", "tools/spikes/blocks_schema_validator_probe"],
            "kind": "build",
        },
        {
            "id": "action_schema_validate",
            "command": [sys.executable, "tools/spikes/p2_action_smoke.py", "validate-schemas"],
            "kind": "json_or_text",
        },
        {
            "id": "action_schema_smoke",
            "command": [sys.executable, "tools/spikes/p2_action_smoke.py", "smoke"],
            "kind": "json_or_text",
        },
        {
            "id": "python_compile",
            "command": [
                sys.executable,
                "-m",
                "py_compile",
                "tools/spikes/p2_action_smoke.py",
                "tools/spikes/blocks_provider_smoke.py",
                "tools/spikes/blocks_provider_settings_smoke.py",
                "tools/spikes/p2k_validation_suite.py",
            ],
            "kind": "build",
        },
    ]


def bounded_text_summary(raw: str) -> dict[str, Any]:
    lines = raw.splitlines()
    first = lines[:3]
    return {
        "line_count": len(lines),
        "characters": len(raw),
        "sha256_12": hashlib.sha256(raw.encode("utf-8", errors="replace")).hexdigest()[:12],
        "first_lines": [line[:240] for line in first],
    }


def parse_json_stdout(raw: str) -> dict[str, Any] | None:
    text = raw.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        for line in reversed(lines):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def run_check(check: dict[str, Any], timeout: int) -> dict[str, Any]:
    started = time.monotonic()
    try:
        result = subprocess.run(
            check["command"],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        result = subprocess.CompletedProcess(check["command"], 124, exc.stdout or "", exc.stderr or "")
        timed_out = True
    duration_ms = int((time.monotonic() - started) * 1000)

    kind = check["kind"]
    expected_absent = kind == "pgrep_absent"
    ok = result.returncode == 0
    status = "passed" if ok else "failed"
    if expected_absent:
        ok = result.returncode == 1
        status = "absent" if ok else "residue_found"
    if timed_out:
        ok = False
        status = "timed_out"

    output: dict[str, Any] = {}
    parsed = parse_json_stdout(result.stdout)
    if parsed is not None and kind in {"json", "json_or_text"}:
        output["json"] = parsed
        parsed_status = str(parsed.get("status", "passed"))
        if parsed_status:
            status = parsed_status
        if parsed.get("ok") is False:
            ok = False
            status = parsed_status or "json_reported_failure"
    else:
        output["stdout_summary"] = bounded_text_summary(result.stdout)
    if result.stderr:
        output["stderr_summary"] = bounded_text_summary(result.stderr)

    not_covered_reason = ""
    parsed_observations = parsed.get("observations", {}) if isinstance(parsed, dict) else {}
    if isinstance(parsed_observations, dict) and parsed_observations.get("not_covered_reason"):
        not_covered_reason = str(parsed_observations["not_covered_reason"])
    elif "not_covered" in status:
        not_covered_reason = status
    elif status in {
        "not_authorized",
        "requires_approval",
        "provider_unavailable",
        "provider_timeout",
    }:
        not_covered_reason = status
    if not ok and parsed and parsed.get("status") in {
        "multi_display_not_covered",
        "not_authorized",
        "requires_approval",
    }:
        not_covered_reason = str(parsed["status"])

    body: dict[str, Any] = {
        "id": check["id"],
        "ok": ok,
        "status": status,
        "exit_code": result.returncode,
        "duration_ms": duration_ms,
        "command_shape": [str(part) for part in check["command"]],
        "output": output,
    }
    if not_covered_reason:
        body["not_covered_reason"] = not_covered_reason
    return body


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def plan_payload() -> dict[str, Any]:
    payload = {
        "ok": True,
        "probe": "blocks.p2k_validation_suite",
        "status": "plan_only",
        "prompt_requested": False,
        "observations": {
            "checks": [
                {"id": check["id"], "command_shape": check["command"], "kind": check["kind"]}
                for check in checks()
            ],
            "output_directory": "tools/spikes/p2k_validation_output/",
        },
        "warnings": [
            "Plan-only mode does not execute commands.",
            "Full mode stores only bounded redacted summaries in an ignored local directory.",
        ],
    }
    payload["audit_id"] = audit_id(payload)
    return payload


def all_payload(timeout: int) -> dict[str, Any]:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    results = [run_check(check, timeout=timeout) for check in checks()]
    failed = [result for result in results if not result["ok"]]
    partial = [
        result
        for result in results
        if result.get("not_covered_reason") or result["status"] in {"requires_approval", "not_authorized"}
    ]
    if failed:
        status = "partial" if partial else "failed"
    else:
        status = "partial" if partial else "passed"
    payload = {
        "ok": not failed,
        "probe": "blocks.p2k_validation_suite",
        "status": status,
        "prompt_requested": any(result.get("not_covered_reason") == "requires_approval" for result in results),
        "observations": {
            "result_count": len(results),
            "passed_count": len(results) - len(failed),
            "failed_count": len(failed),
            "not_covered_count": len(partial),
            "results": results,
        },
        "warnings": [
            "Raw command streams are not persisted.",
            "PNG, fixture, recorder and build artifacts remain in ignored local directories.",
        ],
    }
    payload["audit_id"] = audit_id(payload)
    output_file = OUTPUT_DIR / f"p2k-summary-{int(time.time())}.json"
    payload["observations"]["summary_relative_path"] = (
        f"tools/spikes/p2k_validation_output/{output_file.name}"
    )
    output_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    return payload


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Run P2-K batch technical validation")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan-only", action="store_true")
    group.add_argument("--all", action="store_true")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args(argv)

    payload = plan_payload() if args.plan_only else all_payload(timeout=args.timeout)
    emit(payload)
    return 0 if payload["ok"] or payload["status"] == "partial" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
