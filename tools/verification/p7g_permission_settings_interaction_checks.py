#!/usr/bin/env python3
"""P7-G permission and settings interaction rework checks."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from permission_gate_helpers import (
    permission_assist_completion_checks,
    permission_assist_contract_mutations_fail_closed,
    permission_assist_generation_checks,
    permission_assist_owner_chain_checks,
    permission_request_chain_checks,
    permission_request_chain_mutations_fail_closed,
    permission_request_overload_adversary_fails_closed,
)


ROOT = Path(__file__).resolve().parents[2]
APP_SECTION = ROOT / "apps/Blocks/BlocksApp/Models/AppSection.swift"
CONTENT = ROOT / "apps/Blocks/BlocksApp/Views/ContentView.swift"
SETTINGS_SHELL = ROOT / "apps/Blocks/BlocksApp/Features/Settings/SettingsShellView.swift"
PERMISSION_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
APP_MODEL_DELEGATION = ROOT / "apps/Blocks/BlocksApp/App/AppModel+FeatureDelegation.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
PERMISSION_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift"
PERMISSION_DIAGNOSTICS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionDiagnostics.swift"
PERMISSION_STATE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStateService.swift"
PERMISSION_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPanelView.swift"
PERMISSION_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift"
FLOATING_PANEL_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
CLIPBOARD = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift"
CLIPBOARD_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift"
CLIPBOARD_AUTOPASTE = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift"
CLIPBOARD_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift"
CLIPBOARD_PASTE_ORCHESTRATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPasteOrchestrator.swift"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
INFO_PLIST = ROOT / "apps/Blocks/BlocksApp/Resources/Info.plist"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"
LANGUAGES = ["zh-Hans", "en", "ja"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def contains(text: str, *needles: str) -> bool:
    return all(needle in text for needle in needles)


def selection_helper_status_row_contract(permission_settings: str) -> bool:
    struct_match = re.search(
        r"private struct SelectionHelperPermissionStatusRow: View \{(?P<body>.*?)\n\}",
        permission_settings,
        re.DOTALL,
    )
    if struct_match is None:
        return False

    status_row_match = re.search(
        r"SettingsStatusRow\(\n"
        r"\s*title: L10n\.string\(\"translation\.selectionHelper\.title\"\),\n"
        r"\s*detail: (?P<detail>[^,\n]+),\n"
        r"\s*status: (?P<status>[^\n]+)\n"
        r"\s*\) \{",
        struct_match.group("body"),
    )
    return (
        status_row_match is not None
        and status_row_match.group("detail").strip() == "nil"
        and status_row_match.group("status").strip() == "status"
    )


def main() -> int:
    app_section = read(APP_SECTION)
    content = read(CONTENT)
    settings_shell = read(SETTINGS_SHELL)
    permission_settings = read(PERMISSION_SETTINGS)
    app_model = read(APP_MODEL) + "\n" + read(APP_MODEL_DELEGATION)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    permission_store = read(PERMISSION_STORE)
    permission_actions = read(PERMISSION_ACTIONS)
    diagnostics = read(PERMISSION_DIAGNOSTICS)
    state_service = read(PERMISSION_STATE)
    assist_view = read(PERMISSION_VIEW)
    presenter = read(PERMISSION_PRESENTER)
    floating_panel_support = read(FLOATING_PANEL_SUPPORT)
    clipboard = read(CLIPBOARD)
    clipboard_store = read(CLIPBOARD_STORE)
    clipboard_autopaste = read(CLIPBOARD_AUTOPASTE)
    clipboard_coordinator = "\n".join([
        read(CLIPBOARD_COORDINATOR),
        read(CLIPBOARD_PASTE_ORCHESTRATOR),
    ])
    clipboard_runtime = "\n".join([clipboard, clipboard_autopaste])
    project = read(PROJECT)
    info_plist = read(INFO_PLIST)
    strings = json.loads(read(STRINGS))
    request_chain = permission_request_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    request_chain_mutations = permission_request_chain_mutations_fail_closed(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    request_chain_overload_adversary = permission_request_overload_adversary_fails_closed(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    owner_chain = permission_assist_owner_chain_checks(presenter, floating_panel_support, assist_view)
    generation = permission_assist_generation_checks(presenter)
    completion = permission_assist_completion_checks(presenter, permission_store)
    contract_mutations = permission_assist_contract_mutations_fail_closed(
        presenter,
        floating_panel_support,
        assist_view,
        permission_store,
    )
    selection_helper_status_row_mutation = permission_settings.replace(
        "detail: nil,",
        "detail: stateDetail,",
        1,
    )

    checks: dict[str, bool] = {
        "settings_sidebar_current_groups": contains(
            content,
            "enum SettingsSidebarGroupID",
            "case tools",
            "case system",
            "case intelligence",
            "case data",
            "case app",
            "SettingsSidebarGroupDescriptor(",
            "id: .tools",
            "localizationKey: \"sidebar.group.tools\"",
            "id: .system",
            "localizationKey: \"sidebar.group.system\"",
            "id: .app",
            "localizationKey: \"sidebar.group.app\"",
        ),
        "settings_sidebar_categories": contains(
            app_section,
            "case screenshot",
            "case clipboardSettings",
            "case translationSettings",
            "case shortcuts",
            "case providers",
            "case permissions",
            "case settings",
        ),
        "clipboard_translation_are_settings_routes": contains(
            content,
            "case .clipboardSettings:",
            ".clipboard",
            "case .translationSettings:",
            ".translation",
        )
        and contains(
            settings_shell,
            "case .clipboard:",
            "ClipboardSettingsPane(showPrivacySection: false)",
            "case .translation:",
            "TranslationSettingsPane()",
        )
        and "case clipboard\n" not in app_section
        and "case translation\n" not in app_section,
        "screen_capture_usage_description": "INFOPLIST_FILE = BlocksApp/Resources/Info.plist;" in project
        and "<key>NSScreenCaptureUsageDescription</key>" in info_plist,
        "permission_diagnostic_snapshot": contains(
            diagnostics,
            "struct PermissionDiagnosticSnapshot",
            "kind",
            "granted",
            "bundleID",
            "appPath",
            "signatureKind",
            "teamID",
            "hasUsageDescription",
            "recommendedAction",
        ),
        "screen_recording_request_recover": contains(
            state_service,
            "CGRequestScreenCaptureAccess()",
            "SecCodeCopySigningInformation",
        )
        and "stableSigningRecommended" in diagnostics
        and "revealCurrentAppInFinder" in app_model
        and all(value for name, value in request_chain.items() if name.startswith("screen_")),
        "accessibility_request_path": contains(
            state_service,
            "AXIsProcessTrustedWithOptions",
            "kAXTrustedCheckOptionPrompt",
        )
        and all(value for name, value in request_chain.items() if name.startswith("accessibility_")),
        "request_chain_mutations_fail_closed": all(request_chain_mutations.values()),
        "request_chain_overload_adversary_fails_closed": all(
            request_chain_overload_adversary.values()
        ),
        "settings_permission_cards": contains(
            permission_settings,
            "PermissionDiagnosticRow",
            "permissionStore.permissionSnapshot.screenRecording",
            "permissionStore.permissionSnapshot.accessibility",
            "settings.permissionRequestScreenRecording",
            "settings.permissionRequestAccessibility",
            "settings.permissionShowInFinder",
        ),
        "selection_helper_status_row_contract": selection_helper_status_row_contract(
            permission_settings
        ),
        "selection_helper_status_row_detail_mutation_fails_closed": not selection_helper_status_row_contract(
            selection_helper_status_row_mutation
        ),
        "permission_assist_state_machine": contains(
            presenter,
            "enum PermissionAssistSessionState",
            "openingSystemSettings",
            "waitingForSettingsWindow",
            "guiding",
            "checkingPermission",
            "granted",
            "failed",
            "cancelled",
            "timedOut",
            "settingsLaunchGraceSeconds",
            "flowTimeoutSeconds",
        ),
        "permission_assist_position_and_drag": contains(
            presenter,
            "visibleWindowFrame()",
            "canPlaceRight",
            "arrowDirection = canPlaceRight ? .left : .right",
            "onCompleted",
        )
        and all(owner_chain.values()),
        "permission_assist_generation_contract": all(generation.values()),
        "permission_assist_completion_contract": all(completion.values()),
        "permission_assist_contract_mutations_fail_closed": all(contract_mutations.values()),
        "clipboard_paste_attempt_model": contains(
            clipboard_autopaste,
            "enum ClipboardPasteAttemptState",
            "enum ClipboardPasteFailureReason",
            "struct ClipboardPasteAttempt",
            "pasteboardChangeCountBefore",
        )
        and "@Published var pasteAttempt" in clipboard_store
        and contains(
            clipboard_coordinator,
            "pasteTargetContextForCurrentAction()",
            "clipboardHistoryPanelPresenter.targetContextForPaste()",
            "clipboardHistoryPanelPresenter.targetContextForDirectAction()",
            "clipboardStore.pasteAttempt = ClipboardPasteAttempt(",
            "clipboardHistoryPanelPresenter.releasePanelForPaste(sessionID:",
        ),
        "clipboard_paste_target_and_failure_types": contains(
            clipboard_runtime,
            "com.apple.SystemSettings",
            "com.apple.systempreferences",
            "targetApplicationUnavailable",
            "pasteEventFailed",
            "makePasteShortcut",
        )
        and contains(
            clipboard_coordinator,
            "failureReason = .notAuthorized",
            "recordPasteFailure(.targetApplicationUnavailable",
            "recordPasteFailure(.eventCreationFailed",
        ),
    }

    localization_keys = [
        "settings.present",
        "settings.permissionDiagnostic.status",
        "settings.permissionDiagnostic.bundleID",
        "settings.permissionDiagnostic.appPath",
        "settings.permissionDiagnostic.signature",
        "settings.permissionDiagnostic.teamID",
        "settings.permissionDiagnostic.none",
        "settings.permissionDiagnostic.usageDescription",
        "settings.permissionDiagnostic.recommendedAction",
        "settings.permissionRequestScreenRecording",
        "settings.permissionRequestAccessibility",
        "settings.permissionCompleted",
        "settings.permissionShowInFinder",
        "settings.permissionActionGranted",
        "settings.permissionActionRequest",
        "settings.permissionActionReopen",
        "settings.permissionActionStableSigning",
        "permission.assist.completed",
        "permission.assist.notGrantedAfterCheck",
        "permission.assist.state.opening",
        "permission.assist.state.waiting",
        "permission.assist.state.guiding",
        "permission.assist.state.checking",
        "permission.assist.state.granted",
        "permission.assist.state.failed",
        "permission.assist.state.cancelled",
        "permission.assist.state.timedOut",
        "status.clipboardPasteFailed.payloadUnavailable",
        "status.clipboardPasteFailed.unsupportedPayload",
        "status.clipboardPasteFailed.targetUnavailable",
        "status.clipboardPasteFailed.eventFailed",
    ]
    missing_localizations: dict[str, list[str]] = {}
    for key in localization_keys:
        entry = strings.get("strings", {}).get(key)
        missing = [lang for lang in LANGUAGES if lang not in (entry or {}).get("localizations", {})]
        if entry is None or missing:
            missing_localizations[key] = missing or LANGUAGES
    checks["localization_coverage"] = not missing_localizations

    stale_patterns = [
        r"case clipboard\s*(?:\n|$)",
        r"case translation\s*(?:\n|$)",
        r"selectedSection = \.clipboard\b",
        r"selectedSection = \.translation\b",
        r"section: \.clipboard\b",
        r"section: \.translation\b",
    ]
    stale_matches = [pattern for pattern in stale_patterns if re.search(pattern, "\n".join([app_section, content, app_model, settings_shell]))]
    checks["old_clipboard_translation_tool_routes_removed"] = not stale_matches

    failures = [
        {"code": name}
        for name, ok in checks.items()
        if not ok
    ]
    if missing_localizations:
        failures.append({"code": "missing_localizations", "detail": missing_localizations})
    if stale_matches:
        failures.append({"code": "stale_tool_route_patterns", "detail": stale_matches})

    print(json.dumps({
        "ok": not failures,
        "suite": "p7g_permission_settings_interaction_checks",
        "checks": checks,
        "failures": failures,
        "permission_request_chain": request_chain,
        "permission_request_chain_mutations": request_chain_mutations,
        "permission_request_chain_overload_adversary": request_chain_overload_adversary,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
