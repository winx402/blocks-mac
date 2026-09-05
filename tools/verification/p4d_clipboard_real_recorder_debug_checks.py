#!/usr/bin/env python3
"""P4-D clipboard real recorder debug-path checks for Blocks."""

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
CORE = ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRecorderFoundation.swift"
HELPER = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "main.swift"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardHistoryView.swift"
WORKSPACE_STORE_DIRECTORY = ROOT / "apps" / "Blocks" / "RuntimeClipboardRecorder"
BUILT_HELPER = (
    ROOT
    / "DerivedData"
    / "Blocks"
    / "Build"
    / "Products"
    / "Debug"
    / "BlocksLoginItemHelper.app"
    / "Contents"
    / "MacOS"
    / "BlocksLoginItemHelper"
)

RAW_FIXTURE = "blocks p4d low sensitive fixture"
LANGUAGES = ["zh-Hans", "en", "ja"]


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


def parse_json_result(result: dict[str, Any]) -> dict[str, Any] | None:
    try:
        return json.loads(result["stdout"])
    except json.JSONDecodeError:
        return None


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def is_store_ignored(path: Path, timeout: int) -> bool:
    result = run(["git", "check-ignore", str(path.relative_to(ROOT))], timeout)
    return result["ok"]


def contains_raw_content(value: Any) -> bool:
    serialized = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return RAW_FIXTURE in serialized


def helper_command(*args: str) -> list[str]:
    return [
        str(BUILT_HELPER),
        *args,
    ]


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
    require(BUILT_HELPER.exists(), "built_helper_missing", str(BUILT_HELPER), failures)
    if failures:
        output = {
            "ok": False,
            "suite": "p4d_clipboard_real_recorder_debug_checks",
            "observations": observations,
            "failures": failures,
        }
        print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
        return 1

    workspace_store_path = WORKSPACE_STORE_DIRECTORY / "p4d-watch.json"
    workspace_excluded_store_path = WORKSPACE_STORE_DIRECTORY / "p4d-excluded.json"
    observations["workspace_store_boundary"] = {
        "p4d_watch_ignored": is_store_ignored(workspace_store_path, args.timeout),
        "p4d_excluded_ignored": is_store_ignored(workspace_excluded_store_path, args.timeout),
        "p4d_watch_exists": workspace_store_path.exists(),
        "p4d_excluded_exists": workspace_excluded_store_path.exists(),
    }
    require(observations["workspace_store_boundary"]["p4d_watch_ignored"], "watch_store_not_ignored", str(workspace_store_path), failures)
    require(observations["workspace_store_boundary"]["p4d_excluded_ignored"], "excluded_store_not_ignored", str(workspace_excluded_store_path), failures)
    require(not workspace_store_path.exists(), "watch_store_written_to_workspace", str(workspace_store_path), failures)
    require(not workspace_excluded_store_path.exists(), "excluded_store_written_to_workspace", str(workspace_excluded_store_path), failures)

    reset = run(helper_command("--recorder-reset", "--store-name", "p4d-watch"), args.timeout)
    reset_json = parse_json_result(reset)
    require(reset["ok"] and reset_json is not None, "watch_reset_failed", reset["stdout"] or reset["stderr_tail"], failures)

    watch = run(
        helper_command(
            "--recorder-watch",
            "--seconds",
            "3",
            "--store-name",
            "p4d-watch",
            "--write-fixture-sample",
            "--reset",
        ),
        args.timeout,
    )
    watch_json = parse_json_result(watch)
    require(watch["ok"] and watch_json is not None, "watch_command_failed", watch["stdout"] or watch["stderr_tail"], failures)
    if watch_json is not None:
        report = watch_json.get("report", {})
        records = report.get("records", [])
        require(watch_json.get("status") == "recorder_watch_completed", "watch_status_unexpected", str(watch_json.get("status")), failures)
        require(report.get("stored_count", 0) >= 1, "watch_no_records_stored", json.dumps(report, ensure_ascii=False), failures)
        require(report.get("observed_change_count", 0) >= 1, "watch_no_change_observed", json.dumps(report, ensure_ascii=False), failures)
        observations["watch_records"] = validate_records(records, failures, "watch")
        require(not contains_raw_content(watch_json), "watch_output_raw_content_found", "raw fixture string appeared in helper output", failures)

    inspect = run(helper_command("--recorder-inspect", "--store-name", "p4d-watch"), args.timeout)
    inspect_json = parse_json_result(inspect)
    require(inspect["ok"] and inspect_json is not None, "inspect_command_failed", inspect["stdout"] or inspect["stderr_tail"], failures)
    if inspect_json is not None:
        report = inspect_json.get("report", {})
        records = report.get("records", [])
        require(report.get("record_count", 0) >= 1, "inspect_no_records", json.dumps(report, ensure_ascii=False), failures)
        require(report.get("real_event_count", 0) >= 1, "inspect_no_real_events", json.dumps(report, ensure_ascii=False), failures)
        observations["inspect_records"] = validate_records(records, failures, "inspect")
        require(not contains_raw_content(inspect_json), "inspect_output_raw_content_found", "raw fixture string appeared in inspect output", failures)

    excluded = run(
        helper_command(
            "--recorder-watch",
            "--seconds",
            "3",
            "--store-name",
            "p4d-excluded",
            "--write-fixture-sample",
            "--exclude-frontmost",
            "--reset",
        ),
        args.timeout,
    )
    excluded_json = parse_json_result(excluded)
    require(excluded["ok"] and excluded_json is not None, "excluded_watch_failed", excluded["stdout"] or excluded["stderr_tail"], failures)
    if excluded_json is not None:
        report = excluded_json.get("report", {})
        records = report.get("records", [])
        require(report.get("stored_count", 0) >= 1, "excluded_no_records_stored", json.dumps(report, ensure_ascii=False), failures)
        require(report.get("skipped_count", 0) >= 1, "excluded_no_snapshot_skipped", json.dumps(report, ensure_ascii=False), failures)
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
        require(not not_excluded, "excluded_record_flags_missing", ", ".join(not_excluded), failures)
        require(not non_empty_types, "excluded_record_read_types", ", ".join(non_empty_types), failures)
        observations["excluded_records"] = validate_records(records, failures, "excluded")
        require(not contains_raw_content(excluded_json), "excluded_output_raw_content_found", "raw fixture string appeared in excluded output", failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "clipboard.debugImportNote",
        "clipboard.importDebugStore",
        "status.clipboardDebugImportFailed.detail",
        "status.clipboardDebugImportFailed.title",
        "status.clipboardDebugImported.detail",
        "status.clipboardDebugImported.title",
    ]
    missing_keys = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in LANGUAGES)
    ]
    require(not missing_keys, "localization_missing", ", ".join(missing_keys), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing_keys}

    core_text = CORE.read_text(encoding="utf-8")
    helper_text = HELPER.read_text(encoding="utf-8")
    app_state_text = APP_STATE.read_text(encoding="utf-8")
    panel_text = PANEL.read_text(encoding="utf-8")

    required_core_symbols = [
        "applicationGroupIdentifier",
        "debugDirectory()",
        "ClipboardRecorderWatchReport",
        "appendRecords(",
        "inspect(storeName:",
        "reset(storeName:",
        "real_user_events_not_restorable",
    ]
    missing_core_symbols = [needle for needle in required_core_symbols if needle not in core_text]
    require(not missing_core_symbols, "core_symbols_missing", ", ".join(missing_core_symbols), failures)

    required_helper_symbols = [
        "--recorder-watch",
        "--recorder-inspect",
        "--recorder-reset",
        "redactedPasteboardRecord",
        "writeLowSensitivePasteboardFixture",
        "NSPasteboard.general",
    ]
    missing_helper_symbols = [needle for needle in required_helper_symbols if needle not in helper_text]
    require(not missing_helper_symbols, "helper_symbols_missing", ", ".join(missing_helper_symbols), failures)

    required_app_symbols = [
        "importClipboardDebugStore()",
        "ClipboardRecorderStore.load",
        "ClipboardRecorderStore.debugDirectory",
        "clipboard.importDebugStore",
        "clipboard.debugImportNote",
    ]
    app_combined = f"{app_state_text}\n{panel_text}"
    missing_app_symbols = [needle for needle in required_app_symbols if needle not in app_combined]
    require(not missing_app_symbols, "app_debug_import_symbols_missing", ", ".join(missing_app_symbols), failures)

    forbidden_app_runtime = ["NSPasteboard", "URLSession", "Process(", "SecItem", "getenv(", "rawProviderOutput"]
    app_forbidden_hits = [needle for needle in forbidden_app_runtime if needle in app_combined]
    require(not app_forbidden_hits, "app_runtime_or_secret_boundary_broken", ", ".join(app_forbidden_hits), failures)

    forbidden_helper_runtime = ["URLSession", "Process(", "SecItem", "getenv(", "secretValue", "rawProviderOutput", "providerRawOutput"]
    helper_forbidden_hits = [needle for needle in forbidden_helper_runtime if needle in helper_text]
    require(not helper_forbidden_hits, "helper_forbidden_runtime_found", ", ".join(helper_forbidden_hits), failures)
    observations["symbol_coverage"] = {
        "missing_core_symbols": missing_core_symbols,
        "missing_helper_symbols": missing_helper_symbols,
        "missing_app_symbols": missing_app_symbols,
        "app_forbidden_hits": app_forbidden_hits,
        "helper_forbidden_hits": helper_forbidden_hits,
    }

    output = {
        "ok": not failures,
        "suite": "p4d_clipboard_real_recorder_debug_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
