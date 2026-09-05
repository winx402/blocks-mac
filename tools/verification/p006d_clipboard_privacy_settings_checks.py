#!/usr/bin/env python3
"""P006-D regression checks for Clipboard privacy and tag settings interactions."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
PRIVACY_STORE = APP / "Features" / "Privacy" / "PrivacyStore.swift"
PRIVACY_PANE = APP / "Features" / "Privacy" / "PrivacySettingsPane.swift"
PRIVACY_ROW = APP / "Features" / "Privacy" / "PrivacyAppRowView.swift"
TAG_SETTINGS = APP / "Features" / "Settings" / "ClipboardTagManagementSection.swift"
LIVE_CAPTURE = APP / "Services" / "ClipboardLiveCaptureService.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def require(failures: list[dict[str, str]], code: str, condition: bool, detail: str, path: Path) -> None:
    if not condition:
        failures.append({"code": code, "detail": detail, "path": str(path.relative_to(ROOT))})


def method_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    open_brace = source.find("{", start)
    if open_brace < 0:
        return ""

    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


def main() -> int:
    failures: list[dict[str, str]] = []
    store = read(PRIVACY_STORE)
    pane = read(PRIVACY_PANE)
    row = read(PRIVACY_ROW)
    tags = read(TAG_SETTINGS)
    live_capture = read(LIVE_CAPTURE)

    for path, source in ((PRIVACY_STORE, store), (PRIVACY_PANE, pane), (PRIVACY_ROW, row), (TAG_SETTINGS, tags), (LIVE_CAPTURE, live_capture)):
        require(failures, "required_file_missing", bool(source), "required P006-D implementation file is missing", path)

    snapshot_reload = method_block(store, "func reloadSnapshot()")
    require(
        failures,
        "capture_policy_availability_missing",
        all(term in store for term in ("PrivacyPolicyAvailability", "case loading", "case ready", "case failed", "capturePolicyAvailability", "canCaptureClipboard")),
        "policy reads must expose loading, ready, and failed capture availability",
        PRIVACY_STORE,
    )
    require(
        failures,
        "snapshot_failure_not_fail_closed",
        all(term in store for term in ("var canCaptureClipboard: Bool", "capturePolicyAvailability == .ready", "lastValidPolicySnapshot"))
        and "policySnapshot = PrivacyPolicySnapshot()" not in snapshot_reload,
        "snapshot failures must retain the last valid snapshot while canCaptureClipboard stays false until a fresh ready snapshot",
        PRIVACY_STORE,
    )
    require(
        failures,
        "retry_does_not_replay_command",
        all(term in store for term in ("pendingMutation", "retryLastMutation", "performMutation", "subject: subject", "policy: policy")),
        "retry must retain and replay the same subject and policy command",
        PRIVACY_STORE,
    )
    require(
        failures,
        "pending_mutation_cancel_not_real",
        all(term in store + row for term in ("func cancelPendingMutation", "mutationState == .pending", "cancelPendingMutation"))
        and "func cancelMutation" not in store,
        "cancel must only discard a pending confirmation before a repository write begins",
        PRIVACY_STORE,
    )
    require(
        failures,
        "privacy_io_runs_on_main_actor",
        all(term in store for term in ("DispatchQueue.global", "scanRequestID", "snapshotRequestID", "DispatchQueue.main.async")),
        "scan and snapshot work must run off-main and only publish the latest result on main",
        PRIVACY_STORE,
    )
    require(
        failures,
        "clipboard_policy_not_applied_before_isolated_observe",
        "ClipboardBroker" in live_capture
        and "observe(" in live_capture
        and "NSPasteboard.general" not in live_capture
        and any(
            token in live_capture
            for token in (
                "policy:",
                "capturePolicy",
                "policyProvider",
                "prefilterProvider",
                "prefilter:",
            )
        ),
        "live capture must pass the resolved fail-closed policy to the isolated broker before representation I/O",
        LIVE_CAPTURE,
    )
    require(
        failures,
        "icon_io_runs_on_main_actor",
        all(term in row for term in ("DispatchWorkItem", "DispatchQueue.global", "iconLoadRequestID", "SystemAppIconProvider.icon")),
        "row icon lookup must be cancellable, off-main, and latest-request-wins",
        PRIVACY_ROW,
    )
    require(
        failures,
        "error_code_exposed_to_user",
        "store.lastErrorCode" not in pane and "localizedErrorMessage" in store + pane,
        "UI must render localized error text rather than an internal error code",
        PRIVACY_PANE,
    )
    require(
        failures,
        "mutation_status_not_scoped_to_subject",
        "mutationSubjectID" in store + row
        and "mutationState" in store + row
        and ("mutationSubjectID == app.id" in row or "app.id == mutationSubjectID" in row),
        "saved and failed mutation state must be scoped to the affected app subject",
        PRIVACY_STORE,
    )
    require(
        failures,
        "filter_accessible_labels_missing",
        "privacy.filter.policy" in pane and "privacy.filter.identity" in pane and ".labelsHidden()" not in pane,
        "privacy filters need visible field labels",
        PRIVACY_PANE,
    )
    require(
        failures,
        "privacy_row_menu_not_independently_accessible",
        all(term in row for term in ("accessibilityElement(children: .contain)", "accessibilityLabel(accessibilityLabel)", "accessibilityLabel(L10n.string(\"privacy.menu.policy\"))")),
        "app summary and policy menu must be separate accessibility containers",
        PRIVACY_ROW,
    )
    confirmation = method_block(row, ".confirmationDialog(")
    require(
        failures,
        "duplicate_confirmation_can_change_selected_policy",
        "pendingDuplicatePolicy" in row
        and "setPolicy(pendingDuplicatePolicy, true)" in confirmation
        and "ForEach(PrivacyPolicyStatus.allCases)" not in confirmation,
        "duplicate-app confirmation must confirm the exact policy selected before the dialog opened",
        PRIVACY_ROW,
    )
    require(
        failures,
        "tag_outside_click_does_not_commit",
        all(term in tags for term in ("simultaneousGesture", "dismissSettingsTagEditOnOutsideTap", "commitSettingsTagEdit")),
        "clicking non-input tag-row content must commit and leave editing",
        TAG_SETTINGS,
    )
    require(
        failures,
        "tag_used_delete_confirmation_missing",
        all(term in tags for term in ("pendingDeleteTag", "tagUseCount", "clipboard.tags.delete.confirmTitle", "confirmationDialog")),
        "settings must confirm before deleting a tag currently used by records",
        TAG_SETTINGS,
    )
    require(
        failures,
        "tag_create_submission_incomplete",
        all(
            term in tags
            for term in (
                ".onSubmit(createNewTag)",
                ".disabled(",
                "newTagName.trimmingCharacters",
            )
        ),
        "new tag creation must submit on Return and disable empty names",
        TAG_SETTINGS,
    )
    require(
        failures,
        "tag_drag_focus_handoff_missing",
        all(term in tags for term in ("isSettingsTagDragging", "dismissSettingsTagEditOnOutsideTap", "handleSettingsTagPointerChanged")),
        "starting a drag must hand off focus from an active tag editor",
        TAG_SETTINGS,
    )

    payload = {
        "ok": not failures,
        "suite": "p006d_clipboard_privacy_settings_checks",
        "files": [str(path.relative_to(ROOT)) for path in (PRIVACY_STORE, PRIVACY_PANE, PRIVACY_ROW, TAG_SETTINGS, LIVE_CAPTURE)],
        "failures": failures,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
