#!/usr/bin/env python3
"""P4-G clipboard long recorder debug-session checks for Blocks."""

from __future__ import annotations

from retired_p4_step5_cleanup_guard import main as _step5_retired_main

if __name__ == "__main__":
    raise SystemExit(_step5_retired_main(__file__))


import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardHistoryView.swift"
RUNTIME_SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardRecorderRuntimeService.swift"
HELPER = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "main.swift"
APP_ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Blocks.entitlements"
HELPER_ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "BlocksLoginItemHelper.entitlements"
WORKSPACE_STORE_DIRECTORY = ROOT / "apps" / "Blocks" / "RuntimeClipboardRecorder"
BUILT_APP_HELPER = (
    ROOT
    / "DerivedData"
    / "Blocks"
    / "Build"
    / "Products"
    / "Debug"
    / "Blocks.app"
    / "Contents"
    / "Library"
    / "LoginItems"
    / "BlocksLoginItemHelper.app"
    / "Contents"
    / "MacOS"
    / "BlocksLoginItemHelper"
)

LANGUAGES = ["zh-Hans", "en", "ja"]
RAW_FIXTURE = "blocks p4d low sensitive fixture"
SESSION_STORE = "p4g-session"
EXCLUDED_STORE = "p4g-excluded"
REQUIRED_LOCALIZABLE_KEYS = [
    "clipboard.startRecorderSession",
    "clipboard.stopRecorderSession",
    "clipboard.recorderSessionDuration",
    "clipboard.runtimePhase.running",
    "clipboard.runtimePhase.stopped",
    "clipboard.runtimePhase.completed",
    "clipboard.runtimeSessionSummary",
    "clipboard.runtimeAppGroupCandidate",
    "clipboard.runtimeAppGroupCandidateNotConfigured",
    "status.clipboardSessionStarted.title",
    "status.clipboardSessionStarted.detail",
    "status.clipboardSessionStopped.title",
    "status.clipboardSessionStopped.detail",
    "status.clipboardSessionCompleted.title",
    "status.clipboardSessionCompleted.detail",
    "status.clipboardSessionAlreadyRunning.title",
    "status.clipboardSessionAlreadyRunning.detail",
]


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


def parse_json_output(text: str) -> dict[str, Any] | None:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def helper_command(*args: str) -> list[str]:
    return [str(BUILT_APP_HELPER), *args]


def contains_raw_content(value: Any) -> bool:
    return RAW_FIXTURE in json.dumps(value, ensure_ascii=False, sort_keys=True)


def validate_records(records: list[dict[str, Any]], failures: list[dict[str, str]], context: str) -> dict[str, Any]:
    raw_hits = [record.get("id", "unknown") for record in records if contains_raw_content(record)]
    restorable = [record.get("id", "unknown") for record in records if record.get("restorable") is True]
    fixture_owned = [record.get("id", "unknown") for record in records if record.get("fixture_owned") is True]
    missing_redacted_fields = [
        record.get("id", "unknown")
        for record in records
        if "signature_sha256_12" not in record
        or "format_summary" not in record
        or "summary" not in record
    ]
    require(not raw_hits, f"{context}_raw_content_found", ", ".join(raw_hits), failures)
    require(not restorable, f"{context}_records_restorable", ", ".join(restorable), failures)
    require(not fixture_owned, f"{context}_fixture_owned_found", ", ".join(fixture_owned), failures)
    require(not missing_redacted_fields, f"{context}_redacted_fields_missing", ", ".join(missing_redacted_fields), failures)
    return {
        "record_count": len(records),
        "raw_hits": raw_hits,
        "restorable": restorable,
        "fixture_owned": fixture_owned,
        "missing_redacted_fields": missing_redacted_fields,
    }


def start_helper_session(store_name: str, exclude_frontmost: bool, timeout: int) -> dict[str, Any]:
    args = helper_command(
        "--recorder-watch",
        "--seconds",
        "6",
        "--store-name",
        store_name,
        "--write-fixture-sample",
        "--reset",
        "--long-session",
        "--flush-each-event",
        "--poll-interval-ms",
        "150",
    )
    if exclude_frontmost:
        args.append("--exclude-frontmost")
    process = subprocess.Popen(
        args,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(1.0)
    running_after_fixture = process.poll() is None
    if running_after_fixture:
        process.terminate()
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate(timeout=timeout)
    else:
        stdout, stderr = process.communicate(timeout=timeout)
    return {
        "running_after_fixture": running_after_fixture,
        "returncode": process.returncode,
        "stdout": stdout,
        "stderr_tail": stderr[-1200:],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    require(BUILT_APP_HELPER.exists(), "embedded_helper_missing", str(BUILT_APP_HELPER), failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}
    if failures:
        print(json.dumps({"ok": False, "suite": "p4g_clipboard_long_recorder_checks", "observations": observations, "failures": failures}, ensure_ascii=False, indent=2, sort_keys=True))
        return 1

    workspace_store = WORKSPACE_STORE_DIRECTORY / f"{SESSION_STORE}.json"
    ignore_check = run(["git", "check-ignore", str(workspace_store.relative_to(ROOT))], args.timeout)
    observations["workspace_store_boundary"] = {
        "ignored": ignore_check["ok"],
        "exists": workspace_store.exists(),
    }
    require(ignore_check["ok"], "workspace_store_not_ignored", str(workspace_store), failures)
    require(not workspace_store.exists(), "workspace_store_written", str(workspace_store), failures)

    preflight = run(helper_command("--recorder-preflight"), args.timeout)
    preflight_json = parse_json_output(preflight["stdout"])
    require(preflight["ok"] and preflight_json is not None, "preflight_failed", preflight["stdout"] or preflight["stderr_tail"], failures)
    if preflight_json is not None:
        report = preflight_json.get("report", {})
        status = report.get("app_group_candidate_status")
        require(status in {"available", "not_configured_for_app_group"}, "app_group_candidate_status_missing", str(report), failures)
        if report.get("app_group_entitlement_enabled") is False:
            require(status == "not_configured_for_app_group", "app_group_candidate_status_wrong", str(report), failures)
        observations["preflight"] = {
            "backend": report.get("backend"),
            "app_group_candidate_status": status,
            "app_group_writable": report.get("app_group_writable"),
        }

    reset = run(helper_command("--recorder-reset", "--store-name", SESSION_STORE), args.timeout)
    require(reset["ok"], "session_reset_failed", reset["stdout"] or reset["stderr_tail"], failures)
    session = start_helper_session(SESSION_STORE, exclude_frontmost=False, timeout=args.timeout)
    require(session["running_after_fixture"], "session_did_not_remain_running", session["stdout"] or session["stderr_tail"], failures)
    observations["session_process"] = {
        "running_after_fixture": session["running_after_fixture"],
        "returncode": session["returncode"],
    }
    inspect = run(helper_command("--recorder-inspect", "--store-name", SESSION_STORE), args.timeout)
    inspect_json = parse_json_output(inspect["stdout"])
    require(inspect["ok"] and inspect_json is not None, "session_inspect_failed", inspect["stdout"] or inspect["stderr_tail"], failures)
    if inspect_json is not None:
        records = inspect_json.get("report", {}).get("records", [])
        require(len(records) >= 1, "session_no_records", str(inspect_json), failures)
        observations["session_records"] = validate_records(records, failures, "session")
        require(not contains_raw_content(inspect_json), "session_output_raw_content_found", "raw fixture appeared in inspect output", failures)

    reset_excluded = run(helper_command("--recorder-reset", "--store-name", EXCLUDED_STORE), args.timeout)
    require(reset_excluded["ok"], "excluded_reset_failed", reset_excluded["stdout"] or reset_excluded["stderr_tail"], failures)
    excluded = start_helper_session(EXCLUDED_STORE, exclude_frontmost=True, timeout=args.timeout)
    require(excluded["running_after_fixture"], "excluded_session_did_not_remain_running", excluded["stdout"] or excluded["stderr_tail"], failures)
    excluded_inspect = run(helper_command("--recorder-inspect", "--store-name", EXCLUDED_STORE), args.timeout)
    excluded_json = parse_json_output(excluded_inspect["stdout"])
    require(excluded_inspect["ok"] and excluded_json is not None, "excluded_inspect_failed", excluded_inspect["stdout"] or excluded_inspect["stderr_tail"], failures)
    if excluded_json is not None:
        records = excluded_json.get("report", {}).get("records", [])
        require(records, "excluded_no_records", str(excluded_json), failures)
        not_excluded = [
            record.get("id", "unknown")
            for record in records
            if record.get("excluded") is not True or record.get("snapshot_skipped") is not True
        ]
        non_empty_types = [
            record.get("id", "unknown")
            for record in records
            if record.get("format_summary", {}).get("types")
        ]
        require(not not_excluded, "excluded_flags_missing", ", ".join(not_excluded), failures)
        require(not non_empty_types, "excluded_read_snapshot", ", ".join(non_empty_types), failures)
        observations["excluded_records"] = validate_records(records, failures, "excluded")

    cleanup_session = run(helper_command("--recorder-reset", "--store-name", SESSION_STORE), args.timeout)
    cleanup_excluded = run(helper_command("--recorder-reset", "--store-name", EXCLUDED_STORE), args.timeout)
    require(cleanup_session["ok"], "cleanup_session_failed", cleanup_session["stdout"] or cleanup_session["stderr_tail"], failures)
    require(cleanup_excluded["ok"], "cleanup_excluded_failed", cleanup_excluded["stdout"] or cleanup_excluded["stderr_tail"], failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    missing_keys = [
        key
        for key in REQUIRED_LOCALIZABLE_KEYS
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in LANGUAGES)
    ]
    require(not missing_keys, "localization_missing", ", ".join(missing_keys), failures)
    observations["required_localization_keys"] = {"checked": len(REQUIRED_LOCALIZABLE_KEYS), "missing": missing_keys}

    app_state_text = APP_STATE.read_text(encoding="utf-8")
    panel_text = PANEL.read_text(encoding="utf-8")
    runtime_text = RUNTIME_SERVICE.read_text(encoding="utf-8")
    helper_text = HELPER.read_text(encoding="utf-8")
    app_entitlements = APP_ENTITLEMENTS.read_text(encoding="utf-8")
    helper_entitlements = HELPER_ENTITLEMENTS.read_text(encoding="utf-8")
    app_combined = f"{app_state_text}\n{panel_text}\n{runtime_text}"
    required_symbols = [
        "RecorderDebugSession",
        "startSession",
        "stopSession",
        "startClipboardRecorderSession",
        "stopClipboardRecorderSession",
        "isClipboardRecorderSessionRunning",
        "p4g-session",
        "clipboard.startRecorderSession",
        "clipboard.stopRecorderSession",
        "clipboard.runtimeSessionSummary",
        "clipboard.runtimePhase.running",
        "clipboard.runtimePhase.stopped",
        "clipboard.runtimePhase.completed",
        "--long-session",
        "--flush-each-event",
        "--poll-interval-ms",
        "app_group_candidate_status",
    ]
    missing_symbols = [
        needle
        for needle in required_symbols
        if needle not in app_combined and needle not in helper_text
    ]
    require(not missing_symbols, "runtime_session_symbols_missing", ", ".join(missing_symbols), failures)
    forbidden_app_hits = [
        needle
        for needle in ["NSPasteboard.general", "SecItem", "URLSession", "getenv(", "rawProviderOutput", "providerRawOutput"]
        if needle in app_combined
    ]
    require(not forbidden_app_hits, "app_forbidden_runtime_found", ", ".join(forbidden_app_hits), failures)
    require("com.apple.security.application-groups" not in app_entitlements, "app_group_entitlement_added_to_app", "P4-G must not enable App Group entitlement", failures)
    require("com.apple.security.application-groups" not in helper_entitlements, "app_group_entitlement_added_to_helper", "P4-G must not enable App Group entitlement", failures)
    observations["symbol_coverage"] = {
        "missing_symbols": missing_symbols,
        "forbidden_app_hits": forbidden_app_hits,
        "app_group_entitlement_absent": "com.apple.security.application-groups" not in app_entitlements + helper_entitlements,
    }

    output = {
        "ok": not failures,
        "suite": "p4g_clipboard_long_recorder_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
