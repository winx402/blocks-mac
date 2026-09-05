#!/usr/bin/env python3
"""P14-B unified screenshot selection and capture-path checks."""

from __future__ import annotations

import json
import re
from pathlib import Path

from current_architecture_gate_helpers import swift_code_only


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
SELECTION = APP / "Features/Screenshot/Capture/ScreenshotSelectionController.swift"
OVERLAY = APP / "Features/Screenshot/Capture/ScreenshotSelectionOverlay.swift"
COORDINATE_BRIDGE = APP / "Features/Screenshot/Capture/ScreenshotCoordinateBridge.swift"
TOOLBAR = APP / "Features/Screenshot/Capture/ScreenshotSelectionToolbar.swift"
LOCALIZABLE = APP / "Features/Screenshot/Resources/ScreenshotLocalizable.xcstrings"
COUNTDOWN = APP / "Features/Screenshot/Capture/ScreenshotCaptureCountdownController.swift"
CAPTURE = APP / "Features/Screenshot/Capture/ScreenCaptureKitAdapter.swift"
WINDOW_VISIBILITY = APP / "Features/Screenshot/Capture/ScreenshotWindowVisibility.swift"
EDITING_CONTEXT = APP / "Features/Screenshot/Capture/ScreenshotEditingContextBuilder.swift"
STORE = APP / "Features/Screenshot/ScreenshotStore.swift"
COORDINATOR = APP / "Features/Screenshot/ScreenshotFeatureCoordinator.swift"
CORE_PLAN = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotCapturePlan.swift"
CORE_CONTRACTS = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotCaptureContracts.swift"
CORE_PLAN_TESTS = ROOT / "apps/Blocks/BlocksScreenshotCoreTests/ScreenshotCapturePlanTests.swift"
CORE_TESTS = ROOT / "apps/Blocks/BlocksScreenshotCoreTests/ScreenshotSelectionReducerTests.swift"
APP_TESTS = ROOT / "apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift"
OLD_REGION = APP / "Services/RegionSelectionController.swift"
OLD_WINDOW = APP / "Services/WindowSelectionController.swift"
OLD_CAPTURE = APP / "Services/ScreenshotCaptureService.swift"
HOME = APP / "Views/ScreenshotHomeView.swift"
MENU = APP / "Views/MenuBarCommandsView.swift"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def closure_block(source: str, marker: str) -> str:
    """Return one exact Swift closure, ignoring braces in comments/strings."""
    code = swift_code_only(source)
    if code.count(marker) != 1:
        return ""
    start = code.index(marker)
    opening = code.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ""


def main() -> int:
    failures: list[dict[str, str]] = []
    for path in [
        SELECTION, OVERLAY, COORDINATE_BRIDGE, TOOLBAR, LOCALIZABLE, COUNTDOWN, CAPTURE,
        WINDOW_VISIBILITY, EDITING_CONTEXT, STORE, COORDINATOR,
        CORE_PLAN, CORE_CONTRACTS, CORE_PLAN_TESTS, CORE_TESTS, APP_TESTS, PROJECT, MENU,
    ]:
        if not path.exists():
            failures.append({"code": "missing_file", "path": rel(path)})

    if HOME.exists():
        failures.append({"code": "legacy_screenshot_home_remaining", "path": rel(HOME)})

    for path in [OLD_REGION, OLD_WINDOW, OLD_CAPTURE]:
        if path.exists():
            failures.append({"code": "legacy_capture_file_remaining", "path": rel(path)})

    selection = text(SELECTION)
    overlay = text(OVERLAY)
    coordinate_bridge = text(COORDINATE_BRIDGE)
    toolbar = text(TOOLBAR)
    localizable = text(LOCALIZABLE)
    countdown = text(COUNTDOWN)
    capture = text(CAPTURE)
    store = text(STORE)
    coordinator = text(COORDINATOR)
    core_plan = text(CORE_PLAN)
    core_contracts = text(CORE_CONTRACTS)
    core_plan_tests = text(CORE_PLAN_TESTS)
    core_tests = text(CORE_TESTS)
    app_tests = text(APP_TESTS)
    project = text(PROJECT)
    home = text(HOME)
    menu = text(MENU)

    if "runModal()" in store or "runModal()" in coordinator:
        failures.append({
            "code": "screenshot_flow_blocks_main_actor_with_modal_alert",
            "path": rel(STORE if "runModal()" in store else COORDINATOR),
        })
    for token in [
        "final class ScreenshotApplicationContextRestorer",
        "applicationContext.restoreOnce()",
        "applicationContextSuspender",
    ]:
        if token not in store:
            failures.append({
                "code": "screenshot_application_context_restoration_missing",
                "path": rel(STORE),
                "detail": token,
            })
    if "windows.forEach { $0.orderFront" in store or "makeKeyAndOrderFront(nil)" in store:
        failures.append({
            "code": "screenshot_completion_can_resurface_blocks_main_window",
            "path": rel(STORE),
        })
    for token in [
        "await Task.yield()",
        "Task.sleep(for: .milliseconds(80))",
        "previousFrontmostApplication.activate(options: [.activateAllWindows])",
    ]:
        if token not in store:
            failures.append({
                "code": "screenshot_external_application_restoration_incomplete",
                "path": rel(STORE),
                "detail": token,
            })
    if "orderOut(nil)" in store:
        failures.append({
            "code": "screenshot_launch_hides_blocks_settings_window",
            "path": rel(STORE),
        })
    for token in ["ownWindowIDs", "ownBundleID", "ownProcessID"]:
        if token not in capture:
            failures.append({
                "code": "screenshot_blocks_window_exclusion_missing",
                "path": rel(CAPTURE),
                "detail": token,
            })
    editor_completion = closure_block(
        store,
        "completion: { [weak self] outcome in",
    )
    editor_completion_defer = closure_block(editor_completion, "defer {")
    if not (
        editor_completion
        and editor_completion_defer
        and "applicationContext.restoreOnce()" in editor_completion_defer
        and "clearActiveEditorApplicationContext(ifMatching: applicationContext)"
            in editor_completion_defer
        and "switch outcome" in editor_completion
        and "finalOutputCoordinator.finalize(" in editor_completion
        and editor_completion.index("defer {")
            < editor_completion.index("switch outcome")
    ):
        failures.append({
            "code": "screenshot_editor_completion_context_restoration_not_deferred",
            "path": rel(STORE),
        })

    try:
        localizable_strings = json.loads(localizable).get("strings", {})
    except json.JSONDecodeError as error:
        localizable_strings = {}
        failures.append({
            "code": "screenshot_localizable_invalid",
            "path": rel(LOCALIZABLE),
            "detail": str(error),
        })

    required_selection = [
        "final class ScreenshotSelectionController",
        "ScreenshotSelectionReducer",
        "case window(UInt32)",
        "case region(CGRect)",
        "case display(UInt32)",
        "case allDisplays",
        "func mouseDown(globalPoint:",
        "func mouseDragged(globalPoint:",
        "func mouseUp(globalPoint:",
        "resolvedRegionForCurrentGesture()",
        "event.keyCode == 3",
        "event.keyCode == 48",
        "event.keyCode == 49",
        "drawMagnifier(in:",
        "candidate.frame.cgRect",
        "hintState(for:",
        "drawDashedCaptureBorder",
        "pendingFrozenResult",
        "isFrozenSnapshotReady",
        "windowLocked = false",
        "currentDisplay: currentDisplay",
        "capturePlanner.outputScale",
        "shouldConsumeSelectionKeyEvent",
        "canCycleWindowCandidate",
        "var coreValue: ScreenshotWindowCandidate",
        "visibleHitRegions",
        "containsVisibleHitPoint",
        "guard !cycle.isEmpty",
        "retainedSelectionSurfaceWindowIDs",
        "clearRetainedSelectionSurfaceWindowIDs",
        "dismissSelectionSurfaces",
        "showSelectionSurfaces",
        "panel.alphaValue = 0",
        "surfaces.forEach",
        "SelectionSurfacesCommitted",
        "ScreenshotSelectionHandoffFrame",
        "prepareHandoffFrame(from context:",
        "releaseSelectionVisualResources",
    ]
    missing_selection = [token for token in required_selection if token not in selection]
    if missing_selection:
        failures.append({
            "code": "smart_selection_contract_missing",
            "path": rel(SELECTION),
            "detail": ", ".join(missing_selection),
        })

    required_overlay = [
        ".nonactivatingPanel",
        "acceptsFirstMouse",
        "controller?.mouseDown",
        "controller?.mouseDragged",
        "controller?.mouseUp",
        "ScreenshotSelectionCanvasView",
        "ScreenshotSelectionEventView",
        "defaultHitSurfaceAlpha",
        "override func hitTest",
    ]
    missing_overlay = [token for token in required_overlay if token not in overlay]
    if missing_overlay:
        failures.append({
            "code": "nonactivating_selection_overlay_missing",
            "path": rel(OVERLAY),
            "detail": ", ".join(missing_overlay),
        })

    toolbar_surface = toolbar + "\n" + selection
    required_toolbar = [
        "ScreenshotSelectionToolbarPlacement",
        "ScreenshotSelectionToolbarDragHandle",
        "setRegionGestureActive",
        "ignoresMouseEvents = active",
        "parametersChanged",
        "setAccessibilityLabel",
        "setAccessibilityValue",
        "setAccessibilitySelected",
        "screenshot.selection.dragHandle",
        "keyboardMoveDelta(for:",
        "setAccessibilityRole(.button)",
        "accessibilityPerformPress",
    ]
    missing_toolbar = [token for token in required_toolbar if token not in toolbar_surface]
    if missing_toolbar:
        failures.append({
            "code": "selection_toolbar_contract_missing",
            "path": rel(TOOLBAR),
            "detail": ", ".join(missing_toolbar),
        })

    selection_accessibility_contract = {
        "toolbar_drag_handle_hit_target": "var controlHeight: CGFloat { BlocksVisualTokens.Control.compactHeight }" in toolbar
        and "var dragHandleSize: CGFloat { BlocksVisualTokens.Control.standardHeight }" in toolbar
        and "var dragHandleVisualSize: CGFloat { controlHeight }" in toolbar
        and "dragHandle.widthAnchor.constraint(equalToConstant: presentation.dragHandleSize)" in toolbar
        and "dragHandle.heightAnchor.constraint(equalToConstant: presentation.dragHandleSize)" in toolbar,
        "region_drag_uses_specific_hint": "if case .regionDrawing = state { return }" not in selection
        and 'case .regionDrawing: key = "screenshot.selection.hint.regionDrawing"' in selection,
        "magnifier_is_96_points": "magnifierSize = CGSize(width: 96, height: 96)" in selection,
        "ready_and_window_hints_cover_shortcuts": all(
            all(
                shortcut in localization.get("stringUnit", {}).get("value", "")
                for shortcut in ["Space", "Tab", "F", "Shift+F"]
            )
            for key in ["screenshot.selection.hint.ready", "screenshot.selection.hint.window"]
            for localization in localizable_strings.get(key, {}).get("localizations", {}).values()
        ) and all(
            localizable_strings.get(key, {}).get("localizations")
            for key in ["screenshot.selection.hint.ready", "screenshot.selection.hint.window"]
        ),
        "legacy_region_hint_removed": "screenshot.selection.hint.region" not in localizable_strings,
    }
    for code, passed in selection_accessibility_contract.items():
        if not passed:
            failures.append({
                "code": code,
                "path": rel(
                    TOOLBAR if code == "toolbar_drag_handle_hit_target"
                    else LOCALIZABLE if code in {
                        "ready_and_window_hints_cover_shortcuts",
                        "legacy_region_hint_removed",
                    }
                    else SELECTION
                ),
            })

    countdown_surface = countdown + "\n" + overlay
    required_countdown = [
        "ScreenshotCaptureCountdownController",
        "ScreenshotCaptureCountdownPanel",
        "BlocksAppKitGlassSurfaceView",
        "role: .hud",
        "isCancelKeyCode",
        ".nonactivatingPanel",
    ]
    missing_countdown = [token for token in required_countdown if token not in countdown_surface]
    if missing_countdown:
        failures.append({
            "code": "cancellable_countdown_missing",
            "path": rel(COUNTDOWN),
            "detail": ", ".join(missing_countdown),
        })

    if store.count("guard sessionGate.begin()") != 2 or "private let sessionGate" not in store:
        failures.append({
            "code": "shared_gui_action_session_gate_missing",
            "path": rel(STORE),
        })
    if "private let sessionGate" in coordinator:
        failures.append({
            "code": "coordinator_only_session_gate_remaining",
            "path": rel(COORDINATOR),
        })

    required_regressions = [
        "public func outputScale(",
        "testWindowPlanUsesExactWindowFrame",
        "testFInitializesCurrentDisplaySoPointerUpCapturesWithoutMouseMove",
        "testRegionOutputScaleUsesEveryIntersectingDisplayInsteadOfRegionCenter",
        "testFixedPixelRegionResolvesScaleOscillationOnMixedDPIDisplays",
        "testStoreSessionGateRejectsGUIStartWhileActionCaptureIsActive",
        "testSelectionKeyRoutingExcludesToolbarAndRegionGestureRejectsCandidateCycling",
        "testCaptureCountdownCancellationCleansStateForNextRun",
        "testLiveOverlayRoutesHostedMouseEventsIntoRegionCapture",
        "testLiveOverlayRoutesHostedWindowClickIntoWindowCapture",
        "testCoordinateBridgeConvertsQuartzWindowFrameIntoAppKitSelectionFrame",
        "testCoordinateBridgeMapsDisplaysAboveAndBelowThePrimaryScreen",
        "testRegionSlicesUseTopLeftPixelCoordinates",
        "testWindowCaptureRequestUsesNativeSingleWindowGeometry",
        "testSelectionCandidateUsesTheSameExactFrameForHighlightAndCapture",
        "testToolbarKeyboardMoveUsesPhysicalArrowKeyCodesAndClampedPlacement",
        "testWindowVisibilityExcludesCoveredCandidatesAndKeepsExactFrame",
        "testWindowVisibilityRequiresAtLeastAnEightPointHitRegion",
        "testWindowVisibilityIgnoresBlocksAndSystemOverlaysWithoutOccludingAppWindows",
        "testWindowSurfaceClassifierKeepsAppWindowsAndFloatersButRejectsTransientAndSystemSurfaces",
        "testWindowVisibilityOnlyHitsExposedRegionOfPartiallyCoveredWindow",
        "testWindowVisibilityUsesCGWindowOrderForSameLayerOverlap",
        "testWindowVisibilityKeepsSelectableWindowLikeSurfacesWithVisibleRegions",
        "testWindowCandidateHitTestingAndTabUseOnlyVisibleRegions",
        "testRequiredEditingContextFailureThrowsCaptureError",
    ]
    regression_surface = core_plan + "\n" + core_plan_tests + "\n" + core_tests + "\n" + app_tests
    missing_regressions = [token for token in required_regressions if token not in regression_surface]
    if missing_regressions:
        failures.append({
            "code": "smart_selection_regression_coverage_missing",
            "path": rel(APP_TESTS),
            "detail": ", ".join(missing_regressions),
        })

    if "planRegion(window.frame, displays: displays)" not in core_plan:
        failures.append({
            "code": "window_capture_plan_uses_content_frame",
            "path": rel(CORE_PLAN),
        })

    required_capture = [
        "import BlocksScreenshotCore",
        "final class ScreenCaptureKitAdapter",
        "ScreenshotCapturePlanner",
        "func capture(\n        intent:",
        "plan: ScreenshotCapturePlan",
        "ScreenshotImageCompositor.compose(",
        "SCScreenshotManager.captureImage",
        "ScreenshotWindowVisibility",
        "ScreenshotWindowSurfaceClassifier",
        "selectionCandidates(",
        "CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)",
        "orderedFrontToBack",
        "isOccluding",
        "window.windowLayer",
        "role.isSelectable",
        "role.isOccluding",
        "selectionSurfaceWindowIDs",
        "let isBlocksOwnedSurface",
        "isBlocksOwnedSurface",
        "Bundle.main.bundleIdentifier",
        "ProcessInfo.processInfo.processIdentifier",
        "captureSurfaceHandoff(",
        "selectionSurfaceWindowIDs: selectionController.selectionSurfaceWindowIDs",
        "let initialOwnApplication = captureExcludedApplication(in: content)",
        "else if let initialOwnApplication",
        "captureExclusion = .application(initialOwnApplication)",
        "excludingApplications: [application]",
        "resolvedCaptureExclusion(in:",
        "var usesInitialFrozenCatalog = selectionController.parameters.freezesFrame",
        "content: content",
        "captureContent.windows.map",
        "captureFreshDisplaySnapshots(",
        "captureWindowFromDisplaySnapshot(",
        "snapshotsForCaptureContext(",
        "if selectedFrozenSnapshot != nil",
        "let delayedContent = try await loadShareableContent()",
        "makeDisplayGeometryContext(for:",
        "displayScope: .displayID(displayID)",
        "frozenSnapshotProvider:",
        "showsCursor: showsCursor",
        "selectionController.consumeResultFrozenSnapshot()",
        "planner.planWindow(",
        "frame: windowCandidate.frame.selectionRect",
        "compatibleFrozenImages(",
        "liveDescriptors: windowContext.descriptors",
        "availableSnapshots: frozenSnapshots",
        "expectedDisplays: displayDescriptors",
        "displayDescriptors: descriptors",
        "descriptors.sorted(by:",
        "Frozen display pixels are unavailable.",
        "displayScope: ScreenshotDisplayScope",
        "requiresEditingContext: Bool",
        "editingContextUnavailable",
        "interactiveEditingContextRequirement",
        "selectionController.prepareHandoffFrame(",
    ]
    missing_capture = [token for token in required_capture if token not in capture]
    if missing_capture:
        failures.append({
            "code": "unified_capture_adapter_missing",
            "path": rel(CAPTURE),
            "detail": ", ".join(missing_capture),
        })
    if re.search(r"excludingDesktopWindows\s*\(\s*true\b", capture) is None:
        failures.append({
            "code": "unified_capture_adapter_missing",
            "path": rel(CAPTURE),
            "detail": "SCShareableContent must exclude desktop windows.",
        })

    if "CGContext(" in capture:
        failures.append({
            "code": "capture_adapter_reimplements_pixel_compositing",
            "path": rel(CAPTURE),
            "detail": "ScreenCaptureKitAdapter must delegate orientation and placement to ScreenshotImageCompositor.",
        })

    finish_branch = selection.partition(
        "private func finish(_ result: ScreenshotSelectionResult)"
    )[2].partition("private func drawDimensions")[0]
    for forbidden in [
        "candidates.removeAll()",
        "displays.removeAll()",
        "frozenSnapshots.removeAll()",
        "frozenDisplayDescriptors.removeAll()",
    ]:
        if forbidden in finish_branch:
            failures.append({
                "code": "selection_visual_resources_released_before_editor_handoff",
                "path": rel(SELECTION),
                "detail": forbidden,
            })

    window_selection_branch = capture.partition("case let .window(windowID):")[2].partition("case let .region(rect):")[0]
    required_window_capture = [
        "if let selectedFrozenSnapshot",
        "let delayedContent = try await loadShareableContent()",
        "captureWindowFromDisplaySnapshot(",
        "planner.planWindow(",
        "compatibleFrozenImages(",
        "liveDescriptors: windowContext.descriptors",
    ]
    missing_window_capture = [
        token for token in required_window_capture if token not in window_selection_branch
    ]
    if missing_window_capture or "captureFrozenWindow(" in window_selection_branch:
        failures.append({
            "code": "window_capture_does_not_share_display_snapshot",
            "path": rel(CAPTURE),
            "detail": ", ".join(missing_window_capture) or "legacy frozen window branch remains",
        })

    required_candidate_contract = [
        "public let frame",
        "public let visibleHitRegions",
        "frame: ScreenshotSelectionRect",
        "visibleHitRegions: [ScreenshotSelectionRect]",
    ]
    missing_candidate_contract = [
        token for token in required_candidate_contract if token not in core_contracts
    ]
    if missing_candidate_contract:
        failures.append({
            "code": "window_candidate_geometry_contract_missing",
            "path": rel(CORE_CONTRACTS),
            "detail": ", ".join(missing_candidate_contract),
        })

    required_coordinate_bridge = [
        "struct ScreenshotCoordinateBridge",
        "struct ScreenshotDisplayGeometry",
        "selectionRect(fromQuartzRect rect:",
        "quartzRect(fromSelectionRect rect:",
        "struct ScreenshotWindowCaptureRequest",
    ]
    missing_coordinate_bridge = [
        token for token in required_coordinate_bridge if token not in coordinate_bridge
    ]
    if missing_coordinate_bridge:
        failures.append({
            "code": "explicit_screenshot_coordinate_bridge_missing",
            "path": rel(COORDINATE_BRIDGE),
            "detail": ", ".join(missing_coordinate_bridge),
        })

    forbidden_capture = [
        "captureFrozenWindow(",
        "configuration.ignoreShadowsDisplay",
        "SCContentFilter(display: display, including: [window])",
        "ScreenshotDesktopPoint",
        "ScreenshotDesktopRect",
        "includesWindowShadow",
        "captureFrame",
        "activeFrame(includesShadow:",
        "shadowOutsetPoints",
    ]
    remaining_capture = [
        token for token in forbidden_capture
        if token in capture or token in selection or token in core_plan
    ]
    if remaining_capture:
        failures.append({
            "code": "legacy_or_ambiguous_capture_path_remaining",
            "path": rel(CAPTURE),
            "detail": ", ".join(remaining_capture),
        })

    if "let frozenSnapshots = await captureDisplaySnapshots" in capture:
        failures.append({
            "code": "selection_overlay_blocked_by_eager_freeze_capture",
            "path": rel(CAPTURE),
        })

    required_project = [
        "ScreenshotSelectionController.swift in Sources",
        "ScreenshotSelectionOverlay.swift in Sources",
        "ScreenshotSelectionToolbar.swift in Sources",
        "ScreenshotCaptureCountdownController.swift in Sources",
        "ScreenshotCoordinateBridge.swift in Sources",
        "ScreenCaptureKitAdapter.swift in Sources",
        "ScreenshotWindowVisibility.swift in Sources",
        "ScreenshotEditingContextBuilder.swift in Sources",
        "BlocksScreenshotCore.framework in Frameworks",
        "D00600000000000000000002 /* BlocksScreenshotCore */",
    ]
    missing_project = [token for token in required_project if token not in project]
    if missing_project:
        failures.append({
            "code": "unified_capture_target_membership_missing",
            "path": rel(PROJECT),
            "detail": ", ".join(missing_project),
        })

    legacy_tokens = [
        "startScreenshot(mode:",
        "menu.screenshotRegion",
        "menu.screenshotWindow",
        "menu.screenshotFullscreen",
        "recentCaptures",
        "event.clickCount == 2",
        "regionAdjusting",
    ]
    legacy_surface = home + "\n" + menu + "\n" + selection
    remaining_surface = [token for token in legacy_tokens if token in legacy_surface]
    if remaining_surface:
        failures.append({
            "code": "legacy_screenshot_surface_remaining",
            "path": rel(HOME),
            "detail": ", ".join(remaining_surface),
        })

    payload = {
        "gate": "P14-B",
        "status": "pass" if not failures else "fail",
        "failures": failures,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
