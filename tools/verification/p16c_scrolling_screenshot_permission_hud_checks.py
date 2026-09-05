#!/usr/bin/env python3
"""P16-C Input Monitoring, HUD, and localization gate."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def main() -> int:
    failures: list[dict[str, object]] = []
    permission = read("apps/Blocks/BlocksApp/Features/Permissions/PermissionStateService.swift")
    model = read("apps/Blocks/BlocksApp/Features/Permissions/PermissionDiagnostics.swift")
    settings = read("apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift")
    capture = "\n".join(read(f"apps/Blocks/BlocksApp/Features/Screenshot/Capture/{name}.swift") for name in (
        "ScrollingScreenshotCaptureCoordinator",
        "ScrollingScreenshotCaptureScheduling",
        "ScrollingScreenshotCaptureTermination",
    ))
    capture_support = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotCaptureSupport.swift")
    adapter = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScreenCaptureKitAdapter.swift")
    selection_controller = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScreenshotSelectionController.swift")
    hud = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotHUD.swift")
    selection = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScreenshotSelectionOverlay.swift")
    toolbar = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScreenshotSelectionToolbar.swift")
    countdown = read("apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScreenshotCaptureCountdownController.swift")
    localizations = read("apps/Blocks/BlocksApp/Features/Screenshot/Resources/ScreenshotLocalizable.xcstrings")
    app_localizations = read("apps/Blocks/BlocksApp/Resources/Localizable.xcstrings")
    tests = read("apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift")
    scrolling_tests = read("apps/Blocks/BlocksAppTests/ScrollingScreenshotAppTests.swift")
    app_delegate = read("apps/Blocks/BlocksApp/App/AppDelegate.swift")
    broker = read("apps/Blocks/BlocksActionBroker/main.swift")

    required = {
        "permission_api": (permission, ["CGPreflightListenEventAccess()", "CGRequestListenEventAccess()"]),
        "independent_permission": (model + tests, ["case inputMonitoring", "inputMonitoringGranted", "testInputMonitoringPermissionStateIsIndependentFromAccessibility"]),
        "hard_gate": (
            capture + adapter + selection_controller + toolbar + hud + tests,
            [
                "ScreenshotCaptureError.inputMonitoringPermissionMissing",
                "ScreenshotCaptureError.screenRecordingPermissionMissing",
                "CGPreflightListenEventAccess()",
                "CGPreflightScreenCaptureAccess()",
                "inputMonitoringPermissionProvider",
                "screenRecordingPermissionProvider",
                "updateReadyStartEnabled",
                "testScrollingSelectionRejectsMissingInputMonitoringBeforeReadySurface",
                "testScrollingSelectionRejectsMissingScreenRecordingBeforeReadySurface",
            ],
        ),
        "target_app_restore": (adapter + tests, ["preferredScrollingTargetWindowID", "scrollingTargetApplication", "testScrollingTargetPrefersFrontmostVisibleWindowUnderSelectionCenter"]),
        "settings_entry": (settings, ["permission.assist.inputMonitoring.title", "requestInputMonitoring"]),
        "hud": (hud, ["ScreenshotDesignTokens.hudSize", "ignoresMouseEvents = true", "isMovableByWindowBackground = true", "beginSheetModal", "requiresApplicationActivation = false", "ScrollingScreenshotHUDPresentation", "accumulatedWidth", "phaseTitle", "dimensionText", "warningText", "accessibilityLabel", "@FocusState", "ScreenshotAccessibilityAnnouncer.announce", "case .recovering"]),
        "unified_scrolling_controls": (
            hud + toolbar + selection_controller + tests,
            [
                "BlocksCompactControlGroup",
                "ScreenshotToolbarIconButton",
                "ScrollingScreenshotStatusSummary",
                "final class ScrollingScreenshotHUDController",
                "case ready",
                "func showReady(",
                "func transitionToCapturing(",
                "struct ScrollingScreenshotHUDView",
                "ScreenshotDesignTokens.hudSize",
                "ScreenshotScrollingCommand.start",
                "ScreenshotScrollingCommand.reselect",
                "ScreenshotScrollingCommand.cancel",
                "ScreenshotScrollingCommand.finish",
                "presentation.commands",
                "testScrollingReadyAndCapturingUseTheSameHUDControllerAndPanel",
                "testScrollingCommandsShareOneVisualSemanticModel",
                "testScrollingHUDUsesTheSharedSemanticSurfaceAndFirstMouseHost",
                "acceptsFirstMouse(for event: NSEvent?)",
                "ScreenshotFirstMouseHostingView",
                ".blocksSurface(.hud",
                "BlocksSurfaceRole.hud.appKitMaterial",
                "isCheckingResume",
            ],
        ),
        "escape_and_resume_behavior": (
            capture + capture_support + scrolling_tests + tests,
            [
                "isCancelKeyCode(event.keyCode)",
                "keyCode == 53",
                "testScrollingCaptureEscapeUsesPhysicalKeyCode",
                "testResumeCheckingUsesLoadingStateAndDisablesRepeatedResume",
                "screenshot.scrolling.resumeChecking",
            ],
        ),
        "nonactivating_launch": (
            broker,
            [
                "configuration.activates = false",
            ],
        ),
        "selection_accessibility": (selection + toolbar + hud, ["screenshot.selection.accessibility.canvas", "screenshot.selection.accessibility.toolbar", "becomeFirstResponder", "ScrollingScreenshotHUDFocusPolicy.focusAfterConfigurationChange(", "focusedUIElementChanged", "ScreenshotAccessibilityAnnouncer.announce"]),
        "countdown_accessibility": (countdown, ["screenshot.countdown.accessibility.label", "screenshot.countdown.accessibility.value", "setAccessibilityLabel", "setAccessibilityValue", "valueChanged", "ScreenshotAccessibilityAnnouncer.announce"]),
        "hud_ui_tests": (tests, ["testScrollingHUDSeparatesPrimaryStateWarningAndPixelDimensions", "testSmartSelectionSurfaceExposesInstructionsAndKeyboardFocus", "testCaptureCountdownUsesNonactivatingPanelAndEscapeCancellation"]),
        "localized_states": (localizations, ["screenshot.scrolling.capturing", "screenshot.scrolling.recovering", "screenshot.scrolling.paused", "screenshot.scrolling.possibleEnd", "screenshot.scrolling.resumeChecking", "screenshot.scrolling.dimensions", "screenshot.selection.accessibility.canvas", "screenshot.selection.accessibility.toolbar", "screenshot.countdown.accessibility.label", "screenshot.countdown.accessibility.value", '"en"', '"ja"', '"zh-Hans"']),
        "localized_permission": (app_localizations, ["permission.assist.inputMonitoring.title", "permission.assist.inputMonitoring.detail"]),
    }
    for name, (source, markers) in required.items():
        missing = [marker for marker in markers if marker not in source]
        if missing:
            failures.append({"check": name, "missing": missing})
    if "NSApp.activate" in hud:
        failures.append({"check": "scrolling_hud_must_not_activate_blocks"})
    if "NSApp.activate" in app_delegate:
        failures.append({"check": "app_launch_must_not_unconditionally_activate_settings_window"})
    if 'controller.state.warning ?? L10n.string("screenshot.scrolling.capturing")' in hud:
        failures.append({"check": "hud_warning_must_not_replace_primary_state"})
    if "ScreenshotControlMetrics" in hud + selection + toolbar:
        failures.append({"check": "screenshot_design_tokens_not_shared"})
    if "ScreenshotSelectionCommandButton" in toolbar:
        failures.append({"check": "scrolling_ready_must_not_keep_a_second_button_system"})
    if "ScreenshotToolbarGroup" in hud + toolbar:
        failures.append({"check": "screenshot_private_toolbar_group_remaining"})
    for legacy in [
        "ScrollingScreenshotReadyHUDView",
        "ScrollingScreenshotReadyHUDModel",
        "ScrollingScreenshotReadyHUDPresentation",
        "case scrollingReady",
    ]:
        if legacy in hud + toolbar + selection_controller:
            failures.append({"check": "scrolling_ready_second_surface_remaining", "token": legacy})
    if hud.count("struct ScrollingScreenshotHUDView") != 1:
        failures.append({"check": "scrolling_hud_root_component_identity_is_not_unique"})

    print(json.dumps({
        "gate": "P16-C",
        "status": "fail" if failures else "pass",
        "failures": failures,
        "observations": {"permission": "input-monitoring-independent", "hud_minimum_hit_target": 36},
    }, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
