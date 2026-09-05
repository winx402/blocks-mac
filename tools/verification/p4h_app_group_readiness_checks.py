#!/usr/bin/env python3
"""P4-H App Group readiness gate checks for Blocks."""

from __future__ import annotations

from retired_p4_step5_cleanup_guard import main as _step5_retired_main

if __name__ == "__main__":
    raise SystemExit(_step5_retired_main(__file__))


import argparse
import json
import plistlib
import subprocess
import sys
import xml.parsers.expat
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardHistoryView.swift"
RUNTIME_SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardRecorderRuntimeService.swift"
HELPER_SOURCE = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "main.swift"
APP_ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Blocks.entitlements"
HELPER_ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksLoginItemHelper" / "BlocksLoginItemHelper.entitlements"
WORKSPACE_STORE_DIRECTORY = ROOT / "apps" / "Blocks" / "RuntimeClipboardRecorder"
BUILT_APP = ROOT / "DerivedData" / "Blocks" / "Build" / "Products" / "Debug" / "Blocks.app"
BUILT_HELPER_APP = (
    BUILT_APP
    / "Contents"
    / "Library"
    / "LoginItems"
    / "BlocksLoginItemHelper.app"
)
BUILT_HELPER = BUILT_HELPER_APP / "Contents" / "MacOS" / "BlocksLoginItemHelper"


LANGUAGES = ["zh-Hans", "en", "ja"]
APP_GROUP_IDENTIFIER = "group.app.blocks.app"
REQUIRED_LOCALIZABLE_KEYS = [
    "clipboard.runtimeSharingMode",
    "clipboard.runtimeSharingMode.notChecked",
    "clipboard.runtimeSharingMode.sandboxIsolated",
    "clipboard.runtimeSharingMode.appGroupShared",
    "clipboard.runtimeProvisioning",
    "clipboard.runtimeProvisioning.notChecked",
    "clipboard.runtimeProvisioning.adHocWithoutAppGroup",
    "clipboard.runtimeProvisioning.appGroupAvailable",
    "clipboard.runtimeProvisioning.entitlementWithoutContainer",
    "clipboard.runAppGroupReadiness",
    "status.clipboardAppGroupReadiness.title",
    "status.clipboardAppGroupReadiness.detail",
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
        "stderr": completed.stderr,
        "stderr_tail": completed.stderr[-1600:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def parse_json(text: str) -> dict[str, Any] | None:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def helper_command(*args: str) -> list[str]:
    return [str(BUILT_HELPER), *args]


def extract_entitlements(bundle_path: Path, timeout: int) -> tuple[dict[str, Any], str]:
    result = run(["codesign", "-dvvv", "--entitlements", ":-", str(bundle_path)], timeout)
    combined = f"{result['stdout']}\n{result['stderr']}"
    start = combined.find("<?xml")
    if start == -1:
        start = combined.find("<plist")
    if start == -1:
        return {}, combined
    end = combined.find("</plist>", start)
    if end == -1:
        return {}, combined
    raw_plist = combined[start : end + len("</plist>")].encode("utf-8")
    try:
        return plistlib.loads(raw_plist), combined
    except (plistlib.InvalidFileException, xml.parsers.expat.ExpatError):
        return {}, combined


def has_application_groups(entitlements_text: str | dict[str, Any]) -> bool:
    if isinstance(entitlements_text, str):
        return "com.apple.security.application-groups" in entitlements_text
    return "com.apple.security.application-groups" in entitlements_text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    require(BUILT_APP.exists(), "built_app_missing", str(BUILT_APP), failures)
    require(BUILT_HELPER.exists(), "embedded_helper_missing", str(BUILT_HELPER), failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}
    if failures:
        print(json.dumps({"ok": False, "suite": "p4h_app_group_readiness_checks", "observations": observations, "failures": failures}, ensure_ascii=False, indent=2, sort_keys=True))
        return 1

    app_entitlements_text = APP_ENTITLEMENTS.read_text(encoding="utf-8")
    helper_entitlements_text = HELPER_ENTITLEMENTS.read_text(encoding="utf-8")
    app_signed_entitlements, app_codesign_output = extract_entitlements(BUILT_APP, args.timeout)
    helper_signed_entitlements, helper_codesign_output = extract_entitlements(BUILT_HELPER_APP, args.timeout)
    observations["signed_entitlements"] = {
        "app_keys": sorted(app_signed_entitlements.keys()),
        "helper_keys": sorted(helper_signed_entitlements.keys()),
    }
    require(app_signed_entitlements.get("com.apple.security.app-sandbox") is True, "app_sandbox_missing", app_codesign_output[-1600:], failures)
    require(helper_signed_entitlements.get("com.apple.security.app-sandbox") is True, "helper_sandbox_missing", helper_codesign_output[-1600:], failures)
    require(not has_application_groups(app_entitlements_text), "app_group_enabled_in_app_source", "P4-H must not enable App Group entitlement in source entitlements.", failures)
    require(not has_application_groups(helper_entitlements_text), "app_group_enabled_in_helper_source", "P4-H must not enable App Group entitlement in source entitlements.", failures)
    require(not has_application_groups(app_signed_entitlements), "app_group_enabled_in_app_signature", str(app_signed_entitlements), failures)
    require(not has_application_groups(helper_signed_entitlements), "app_group_enabled_in_helper_signature", str(helper_signed_entitlements), failures)

    preflight = run(helper_command("--recorder-preflight"), args.timeout)
    preflight_json = parse_json(preflight["stdout"])
    require(preflight["ok"] and preflight_json is not None, "preflight_failed", preflight["stdout"] or preflight["stderr_tail"], failures)
    if preflight_json is not None:
        report = preflight_json.get("report", {})
        expected_warnings = {
            "app_group_not_configured_for_ad_hoc_signing",
            "app_group_container_unavailable",
            "using_sandbox_application_support",
        }
        warnings = set(report.get("warnings", []))
        require(report.get("app_group_identifier") == APP_GROUP_IDENTIFIER, "app_group_identifier_wrong", str(report), failures)
        require(report.get("app_group_entitlement_enabled") is False, "app_group_entitlement_enabled", str(report), failures)
        require(report.get("app_group_container_available") is False, "app_group_container_available", str(report), failures)
        require(report.get("app_group_writable") is False, "app_group_writable", str(report), failures)
        require(report.get("app_group_candidate_status") == "not_configured_for_app_group", "app_group_candidate_status_wrong", str(report), failures)
        require(report.get("sharing_mode") == "sandbox_isolated", "sharing_mode_wrong", str(report), failures)
        require(report.get("provisioning_assessment") == "ad_hoc_without_app_group", "provisioning_assessment_wrong", str(report), failures)
        require(expected_warnings.issubset(warnings), "preflight_warnings_missing", str(sorted(expected_warnings - warnings)), failures)
        observations["preflight"] = {
            "backend": report.get("backend"),
            "app_group_candidate_status": report.get("app_group_candidate_status"),
            "sharing_mode": report.get("sharing_mode"),
            "provisioning_assessment": report.get("provisioning_assessment"),
            "warnings": sorted(warnings),
        }

    workspace_store = WORKSPACE_STORE_DIRECTORY / "p4h-readiness.json"
    ignore_check = run(["git", "check-ignore", str(workspace_store.relative_to(ROOT))], args.timeout)
    observations["workspace_store_boundary"] = {
        "ignored": ignore_check["ok"],
        "exists": workspace_store.exists(),
    }
    require(ignore_check["ok"], "workspace_store_not_ignored", str(workspace_store), failures)
    require(not workspace_store.exists(), "workspace_store_written", str(workspace_store), failures)

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
    helper_text = HELPER_SOURCE.read_text(encoding="utf-8")
    app_combined = f"{app_state_text}\n{panel_text}\n{runtime_text}"
    required_symbols = [
        "runClipboardAppGroupReadinessPreflight",
        "sharingModeDisplayName",
        "provisioningAssessmentDisplayName",
        "clipboard.runAppGroupReadiness",
        "clipboard.runtimeSharingMode",
        "clipboard.runtimeProvisioning",
        "SecTaskCopyValueForEntitlement",
        "appGroupContainerAvailable",
        "provisioningAssessment",
    ]
    missing_symbols = [
        needle
        for needle in required_symbols
        if needle not in (helper_text if needle == "SecTaskCopyValueForEntitlement" else f"{app_combined}\n{helper_text}")
    ]
    require(not missing_symbols, "app_group_readiness_symbols_missing", ", ".join(missing_symbols), failures)
    forbidden_app_hits = [
        needle
        for needle in ["NSPasteboard.general", "URLSession", "SecItem", "getenv(", "rawProviderOutput", "providerRawOutput"]
        if needle in app_combined
    ]
    require(not forbidden_app_hits, "app_forbidden_runtime_found", ", ".join(forbidden_app_hits), failures)
    observations["symbol_coverage"] = {
        "missing_symbols": missing_symbols,
        "forbidden_app_hits": forbidden_app_hits,
    }

    output = {
        "ok": not failures,
        "suite": "p4h_app_group_readiness_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
