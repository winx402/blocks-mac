#!/usr/bin/env python3
"""P4-F clipboard runtime gate checks for Blocks."""

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
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardHistoryView.swift"
RUNTIME_SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardRecorderRuntimeService.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
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
REQUIRED_LOCALIZABLE_KEYS = [
    "clipboard.runtimeGate",
    "clipboard.runtimeBackend",
    "clipboard.runtimeBackendNotChecked",
    "clipboard.runtimeAppGroup",
    "clipboard.runtimeLastRun",
    "clipboard.runtimePhase.blocked",
    "clipboard.runtimePhase.debugWatchAvailable",
    "clipboard.runtimePhase.disabled",
    "clipboard.runtimePhase.preflightOnly",
    "clipboard.runPreflight",
    "clipboard.runRedactedWatch",
    "clipboard.resetDebugStore",
    "clipboard.excludeFrontmost",
    "clipboard.runtimeDebugNote",
    "status.clipboardPreflightReady.title",
    "status.clipboardPreflightReady.detail",
    "status.clipboardWatchRunning.title",
    "status.clipboardWatchRunning.detail",
    "status.clipboardWatchCompleted.title",
    "status.clipboardWatchCompleted.detail",
    "status.clipboardWatchBlocked.title",
    "status.clipboardWatchBlocked.detail",
    "status.clipboardDebugStoreReset.title",
    "status.clipboardDebugStoreReset.detail",
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


def parse_json(result: dict[str, Any]) -> dict[str, Any] | None:
    try:
        return json.loads(result["stdout"])
    except json.JSONDecodeError:
        return None


def helper_command(*args: str) -> list[str]:
    return [str(BUILT_APP_HELPER), *args]


def contains_raw_content(value: Any) -> bool:
    return RAW_FIXTURE in json.dumps(value, ensure_ascii=False, sort_keys=True)


def validate_real_records(records: list[dict[str, Any]], failures: list[dict[str, str]], context: str) -> dict[str, Any]:
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
    require(not restorable, f"{context}_real_records_restorable", ", ".join(restorable), failures)
    require(not fixture_owned, f"{context}_fixture_owned_found", ", ".join(fixture_owned), failures)
    require(not missing_redacted_fields, f"{context}_redacted_fields_missing", ", ".join(missing_redacted_fields), failures)
    return {
        "record_count": len(records),
        "raw_hits": raw_hits,
        "restorable": restorable,
        "fixture_owned": fixture_owned,
        "missing_redacted_fields": missing_redacted_fields,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}
    require(BUILT_APP_HELPER.exists(), "embedded_helper_missing", str(BUILT_APP_HELPER), failures)
    if failures:
        print(json.dumps({"ok": False, "suite": "p4f_clipboard_runtime_gate_checks", "observations": observations, "failures": failures}, ensure_ascii=False, indent=2, sort_keys=True))
        return 1

    workspace_store = WORKSPACE_STORE_DIRECTORY / "p4f-watch.json"
    ignore_check = run(["git", "check-ignore", str(workspace_store.relative_to(ROOT))], args.timeout)
    observations["workspace_store_boundary"] = {
        "ignored": ignore_check["ok"],
        "exists": workspace_store.exists(),
    }
    require(ignore_check["ok"], "workspace_store_not_ignored", str(workspace_store), failures)
    require(not workspace_store.exists(), "workspace_store_written", str(workspace_store), failures)

    preflight = run(helper_command("--recorder-preflight"), args.timeout)
    preflight_json = parse_json(preflight)
    require(preflight["ok"] and preflight_json is not None, "preflight_failed", preflight["stdout"] or preflight["stderr_tail"], failures)
    if preflight_json is not None:
        report = preflight_json.get("report", {})
        require(report.get("backend") in {"sandbox_application_support", "app_group"}, "preflight_backend_wrong", str(report), failures)
        require(report.get("workspace_store_used") is False, "preflight_workspace_used", str(report), failures)
        require(report.get("app_group_entitlement_enabled") is False, "preflight_app_group_enabled", str(report), failures)
        observations["preflight"] = {
            "backend": report.get("backend"),
            "app_group_writable": report.get("app_group_writable"),
        }

    watch = run(
        helper_command(
            "--recorder-watch",
            "--seconds",
            "3",
            "--store-name",
            "p4f-watch",
            "--write-fixture-sample",
            "--reset",
        ),
        args.timeout,
    )
    watch_json = parse_json(watch)
    require(watch["ok"] and watch_json is not None, "watch_failed", watch["stdout"] or watch["stderr_tail"], failures)
    if watch_json is not None:
        report = watch_json.get("report", {})
        records = report.get("records", [])
        require(watch_json.get("status") == "recorder_watch_completed", "watch_status_wrong", str(watch_json.get("status")), failures)
        require(report.get("stored_count", 0) >= 1, "watch_no_records", str(report), failures)
        observations["watch_records"] = validate_real_records(records, failures, "watch")
        require(not contains_raw_content(watch_json), "watch_output_raw_content_found", "raw fixture appeared in watch output", failures)

    excluded = run(
        helper_command(
            "--recorder-watch",
            "--seconds",
            "3",
            "--store-name",
            "p4f-excluded",
            "--write-fixture-sample",
            "--exclude-frontmost",
            "--reset",
        ),
        args.timeout,
    )
    excluded_json = parse_json(excluded)
    require(excluded["ok"] and excluded_json is not None, "excluded_watch_failed", excluded["stdout"] or excluded["stderr_tail"], failures)
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
        observations["excluded_records"] = validate_real_records(records, failures, "excluded")
        require(not contains_raw_content(excluded_json), "excluded_raw_content_found", "raw fixture appeared in excluded output", failures)

    cleanup_watch = run(helper_command("--recorder-reset", "--store-name", "p4f-watch"), args.timeout)
    cleanup_excluded = run(helper_command("--recorder-reset", "--store-name", "p4f-excluded"), args.timeout)
    require(cleanup_watch["ok"], "cleanup_watch_failed", cleanup_watch["stdout"] or cleanup_watch["stderr_tail"], failures)
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
    project_text = PROJECT.read_text(encoding="utf-8")
    runtime_text = RUNTIME_SERVICE.read_text(encoding="utf-8") if RUNTIME_SERVICE.exists() else ""
    app_entitlements = APP_ENTITLEMENTS.read_text(encoding="utf-8")
    helper_entitlements = HELPER_ENTITLEMENTS.read_text(encoding="utf-8")
    app_combined = f"{app_state_text}\n{panel_text}\n{runtime_text}\n{project_text}"

    required_symbols = [
        "ClipboardRecorderRuntimeService.swift",
        "ClipboardRecorderRuntimeService",
        "RecorderRuntimeState",
        "runClipboardRecorderPreflight",
        "runClipboardRecorderDebugWatch",
        "resetClipboardDebugStore",
        "importClipboardDebugStore(storeName:",
        "p4f-watch",
        "--recorder-preflight",
        "--recorder-watch",
        "--recorder-inspect",
        "--recorder-reset",
        "--exclude-frontmost",
        "Contents/Library/LoginItems",
        "Process()",
        "clipboard.runPreflight",
        "clipboard.runRedactedWatch",
        "clipboard.resetDebugStore",
        "clipboard.excludeFrontmost",
        "clipboard.runtimeGate",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in app_combined]
    require(not missing_symbols, "runtime_gate_symbols_missing", ", ".join(missing_symbols), failures)

    forbidden_runtime_hits = [
        needle
        for needle in ["NSPasteboard.general", "URLSession", "SecItem", "getenv(", "rawProviderOutput", "providerRawOutput"]
        if needle in app_combined
    ]
    require(not forbidden_runtime_hits, "app_forbidden_runtime_found", ", ".join(forbidden_runtime_hits), failures)
    require("com.apple.security.application-groups" not in app_entitlements, "app_group_entitlement_added_to_app", "P4-F must not enable App Group entitlement", failures)
    require("com.apple.security.application-groups" not in helper_entitlements, "app_group_entitlement_added_to_helper", "P4-F must not enable App Group entitlement", failures)
    observations["symbol_coverage"] = {
        "missing_symbols": missing_symbols,
        "forbidden_runtime_hits": forbidden_runtime_hits,
        "app_group_entitlement_absent": "com.apple.security.application-groups" not in app_entitlements + helper_entitlements,
    }

    output = {
        "ok": not failures,
        "suite": "p4f_clipboard_runtime_gate_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
