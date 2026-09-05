#!/usr/bin/env python3
"""P4-E clipboard recorder restore/preflight checks for Blocks."""

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
HELPER_SOURCE = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "main.swift"
SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "SettingsView.swift"
APP_ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Blocks.entitlements"
HELPER_ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "BlocksLoginItemHelper.entitlements"
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

LANGUAGES = ["zh-Hans", "en", "ja"]
RAW_FIXTURES = [
    "blocks fixture text",
    "blocks fixture rtf",
    "blocks fixture image",
    "https://example.com/blocks-fixture",
    "excluded fixture",
]
RESTORABLE_RECORDS = {
    "clip_fixture_text": "text",
    "clip_fixture_rich_text": "rich_text",
    "clip_fixture_image": "image",
    "clip_fixture_url": "url",
}


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
    return [str(BUILT_HELPER), *args]


def contains_raw_fixture(value: Any) -> bool:
    serialized = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return any(raw in serialized for raw in RAW_FIXTURES)


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
        print(json.dumps({"ok": False, "suite": "p4e_clipboard_recorder_restore_preflight_checks", "observations": observations, "failures": failures}, ensure_ascii=False, indent=2, sort_keys=True))
        return 1

    workspace_store = WORKSPACE_STORE_DIRECTORY / "p4e-restore.json"
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
        backend = report.get("backend")
        require(preflight_json.get("status") == "recorder_preflight", "preflight_status_wrong", str(preflight_json.get("status")), failures)
        require(backend in {"sandbox_application_support", "app_group"}, "preflight_backend_wrong", str(report), failures)
        require(report.get("workspace_store_used") is False, "preflight_workspace_used", str(report), failures)
        require(report.get("app_group_entitlement_enabled") is False, "preflight_app_group_entitlement_enabled", str(report), failures)
        observations["preflight"] = {
            "backend": backend,
            "app_group_writable": report.get("app_group_writable"),
            "directory_kind": report.get("directory_kind"),
        }

    fixture = run(
        helper_command(
            "--recorder-fixture",
            "--store-name",
            "p4e-restore",
            "--include-restorable-payloads",
            "--reset",
        ),
        args.timeout,
    )
    fixture_json = parse_json(fixture)
    require(fixture["ok"] and fixture_json is not None, "fixture_with_payloads_failed", fixture["stdout"] or fixture["stderr_tail"], failures)
    if fixture_json is not None:
        report = fixture_json.get("report", {})
        require(report.get("record_count") == 5, "fixture_record_count_wrong", str(report), failures)
        require(report.get("restorable_count") == 4, "fixture_restorable_count_wrong", str(report), failures)
        require(report.get("payload_count") == 4, "fixture_payload_count_wrong", str(report), failures)
        require(not contains_raw_fixture(fixture_json), "fixture_output_raw_content_found", "raw fixture content appeared in helper output", failures)
        observations["fixture"] = {
            "record_count": report.get("record_count"),
            "restorable_count": report.get("restorable_count"),
            "payload_count": report.get("payload_count"),
        }

    inspect = run(helper_command("--recorder-inspect", "--store-name", "p4e-restore"), args.timeout)
    inspect_json = parse_json(inspect)
    require(inspect["ok"] and inspect_json is not None, "inspect_failed", inspect["stdout"] or inspect["stderr_tail"], failures)
    if inspect_json is not None:
        report = inspect_json.get("report", {})
        require(report.get("record_count") == 5, "inspect_record_count_wrong", str(report), failures)
        require("payloads" not in report, "inspect_exposes_payloads", str(report), failures)
        require(not contains_raw_fixture(inspect_json), "inspect_raw_content_found", "raw fixture content appeared in inspect output", failures)

    restore_results: dict[str, Any] = {}
    for record_id, expected_kind in RESTORABLE_RECORDS.items():
        restored = run(
            helper_command("--recorder-restore", "--store-name", "p4e-restore", "--record-id", record_id),
            args.timeout,
        )
        restored_json = parse_json(restored)
        require(restored["ok"] and restored_json is not None, f"restore_{record_id}_failed", restored["stdout"] or restored["stderr_tail"], failures)
        if restored_json is None:
            continue
        report = restored_json.get("report", {})
        require(restored_json.get("status") == "recorder_restored", f"restore_{record_id}_status_wrong", str(restored_json.get("status")), failures)
        require(report.get("record_id") == record_id, f"restore_{record_id}_record_wrong", str(report), failures)
        require(report.get("kind") == expected_kind, f"restore_{record_id}_kind_wrong", str(report), failures)
        require(report.get("signature_sha256_12"), f"restore_{record_id}_signature_missing", str(report), failures)
        require(report.get("pasteboard_change_count_after", 0) > 0, f"restore_{record_id}_change_count_missing", str(report), failures)
        require(not contains_raw_fixture(restored_json), f"restore_{record_id}_raw_content_found", "raw fixture content appeared in restore output", failures)
        restore_results[record_id] = {
            "kind": report.get("kind"),
            "signature": report.get("signature_sha256_12"),
            "text_length": report.get("text_length"),
            "byte_count": report.get("byte_count"),
            "url_count": report.get("url_count"),
        }
    observations["restore_results"] = restore_results

    excluded_restore = run(
        helper_command("--recorder-restore", "--store-name", "p4e-restore", "--record-id", "clip_fixture_excluded"),
        args.timeout,
    )
    excluded_json = parse_json(excluded_restore)
    require(not excluded_restore["ok"] and excluded_json is not None, "excluded_restore_should_fail", excluded_restore["stdout"], failures)
    if excluded_json is not None:
        require(excluded_json.get("status") == "record_not_restorable", "excluded_restore_status_wrong", str(excluded_json), failures)

    missing_restore = run(
        helper_command("--recorder-restore", "--store-name", "p4e-restore", "--record-id", "missing-record"),
        args.timeout,
    )
    missing_json = parse_json(missing_restore)
    require(not missing_restore["ok"] and missing_json is not None, "missing_restore_should_fail", missing_restore["stdout"], failures)
    if missing_json is not None:
        require(missing_json.get("status") == "record_not_found", "missing_restore_status_wrong", str(missing_json), failures)

    cleanup = run(helper_command("--recorder-reset", "--store-name", "p4e-restore"), args.timeout)
    cleanup_json = parse_json(cleanup)
    require(cleanup["ok"] and cleanup_json is not None, "cleanup_failed", cleanup["stdout"] or cleanup["stderr_tail"], failures)
    if cleanup_json is not None:
        require(cleanup_json.get("status") == "recorder_reset", "cleanup_status_wrong", str(cleanup_json), failures)
        observations["cleanup"] = {"status": cleanup_json.get("status")}

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.clipboardRecorderDiagnostics",
        "settings.clipboardRecorderDiagnosticsNote",
        "settings.clipboardRecorderDebugOnly",
        "settings.clipboardRecorderAppGroupDisabled",
        "settings.clipboardRecorderLongRunningDisabled",
        "settings.clipboardRecorderRestoreFixturesOnly",
    ]
    missing_keys = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in LANGUAGES)
    ]
    require(not missing_keys, "localization_missing", ", ".join(missing_keys), failures)

    core_text = CORE.read_text(encoding="utf-8")
    helper_text = HELPER_SOURCE.read_text(encoding="utf-8")
    settings_text = SETTINGS.read_text(encoding="utf-8")
    app_entitlements = APP_ENTITLEMENTS.read_text(encoding="utf-8")
    helper_entitlements = HELPER_ENTITLEMENTS.read_text(encoding="utf-8")
    require("schemaVersion = \"0.2.0\"" in core_text, "schema_version_not_upgraded", "ClipboardRecorderStore schema should be 0.2.0", failures)
    for needle in ["ClipboardRecorderPayload", "payloads", "writeFixture(", "includePayloads"]:
        require(needle in core_text, "core_payload_symbol_missing", needle, failures)
    for needle in ["--recorder-preflight", "--recorder-restore", "--include-restorable-payloads", "restorePasteboard"]:
        require(needle in helper_text, "helper_restore_symbol_missing", needle, failures)
    for needle in ["settings.clipboardRecorderDiagnostics", "settings.clipboardRecorderDebugOnly", "settings.clipboardRecorderRestoreFixturesOnly"]:
        require(needle in settings_text, "settings_diagnostics_missing", needle, failures)
    require("com.apple.security.application-groups" not in app_entitlements, "app_group_entitlement_added_to_app", "P4-E must not enable App Group entitlement", failures)
    require("com.apple.security.application-groups" not in helper_entitlements, "app_group_entitlement_added_to_helper", "P4-E must not enable App Group entitlement", failures)
    observations["symbol_coverage"] = {
        "localization_missing": missing_keys,
        "app_group_entitlement_absent": "com.apple.security.application-groups" not in app_entitlements + helper_entitlements,
    }

    output = {
        "ok": not failures,
        "suite": "p4e_clipboard_recorder_restore_preflight_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
