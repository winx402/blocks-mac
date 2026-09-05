#!/usr/bin/env python3
"""P7-L clipboard tray and autopaste experience gate checks."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift"
AUTO_PASTE = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift"
SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
VIEW = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift"
HOVER_DETAIL_SOURCES = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardDetailPresentationView.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardDetailPresentationLayer.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardDetailPanel.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardFloatingDetailCard.swift",
]
WIDTH_HANDLE = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardCardWidthResizeHandle.swift"
FILTER_BAR = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift"
FILTER_BAR_SOURCES = [
    FILTER_BAR,
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Filters/ClipboardTagFilterChips.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Filters/ClipboardFilterControls.swift",
]
RECORD_VIEWS = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift"
RECORD_VIEW_SOURCES = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardFloatingRecordRow.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardPanelRecordContent.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordPointerSurface.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordPreviewViews.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordMenus.swift",
    RECORD_VIEWS,
]
PANEL_SOURCES = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelHeader.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelLayout.swift",
]
STATE = ROOT / "apps/Blocks/BlocksApp/Stores/AppState.swift"
CLIPBOARD_CONTROLLER = ROOT / "apps/Blocks/BlocksApp/Stores/ClipboardController.swift"
CLIPBOARD_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift"
FEATURE_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift"
PASTE_ORCHESTRATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPasteOrchestrator.swift"
PANEL_INTERACTION = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelInteractionCoordinator.swift"
PANEL_RECORD_CONTENT = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardPanelRecordContent.swift"
PANEL_SESSION = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPanelSessionModel.swift"
LIVE_CAPTURE = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardLiveCaptureService.swift"
LOCALIZATION = ROOT / "apps/Blocks/BlocksApp/Support/ClipboardRecorder+Localization.swift"
PANEL_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift"
FILTERS = ROOT / "apps/Blocks/BlocksApp/Support/ClipboardFilters.swift"
PREVIEW = ROOT / "apps/Blocks/BlocksApp/Support/ClipboardRecordPreview.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def has_disambiguated_pointer_activation(source: str) -> bool:
    """Require AppKit's single click to wait for the double-click recognizer."""
    required = (
        "singleClickRecognizer = NSClickGestureRecognizer()",
        "doubleClickRecognizer = NSClickGestureRecognizer()",
        "singleClickRecognizer.numberOfClicksRequired = 1",
        "doubleClickRecognizer.numberOfClicksRequired = 2",
        "gestureRecognizer === singleClickRecognizer",
        "otherGestureRecognizer === doubleClickRecognizer",
        "onSingleClick()",
        "onDoubleClick()",
    )
    return all(token in source for token in required)


def has_click_controlled_filter_menu(source: str) -> bool:
    """Require a click-open menu and reject hover-driven filter expansion."""
    required = (
        "struct ClipboardFilterMenuGroup",
        "Menu {",
        ".menuStyle(.borderlessButton)",
        "ClipboardFilterIslandButton",
    )
    return all(token in source for token in required) and "onHover" not in source


def clipboard_experience_negative_fixtures() -> bool:
    """Small source-shaped mutations ensure key interaction guards stay meaningful."""
    pointer_fixture = "\n".join(
        (
            "singleClickRecognizer = NSClickGestureRecognizer()",
            "doubleClickRecognizer = NSClickGestureRecognizer()",
            "singleClickRecognizer.numberOfClicksRequired = 1",
            "doubleClickRecognizer.numberOfClicksRequired = 2",
            "gestureRecognizer === singleClickRecognizer",
            "otherGestureRecognizer === doubleClickRecognizer",
            "onSingleClick()",
            "onDoubleClick()",
        )
    )
    filter_fixture = "\n".join(
        (
            "struct ClipboardFilterMenuGroup {}",
            "Menu { Button(action: onSelectFormat) {} }",
            ".menuStyle(.borderlessButton)",
            "ClipboardFilterIslandButton()",
            ".blocksSurface(.interactive, cornerRadius: BlocksVisualTokens.CornerRadius.control)",
            ".blocksAnimation(.selection, value: hasActiveFilter)",
            "toggleFormatFilter clipboardStore.filterState.format == option ? .all : option",
        )
    )
    pointer_mutation = pointer_fixture.replace("otherGestureRecognizer === doubleClickRecognizer", "")
    filter_mutation = filter_fixture.replace("Menu {", "")
    return (
        has_disambiguated_pointer_activation(pointer_fixture)
        and not has_disambiguated_pointer_activation(pointer_mutation)
        and has_click_controlled_filter_menu(filter_fixture)
        and not has_click_controlled_filter_menu(filter_mutation)
    )


def main() -> int:
    presenter = read(PRESENTER)
    support = read(SUPPORT)
    view = read(VIEW)
    state = read(STATE)
    clipboard_store = read(CLIPBOARD_STORE)
    feature_coordinator = read(FEATURE_COORDINATOR) + "\n" + read(FEATURE_COORDINATOR.with_name("ClipboardFeatureCoordinator+CapturePersistence.swift"))
    paste_orchestrator = read(PASTE_ORCHESTRATOR)
    panel_interaction = read(PANEL_INTERACTION)
    live_capture = read(LIVE_CAPTURE)
    localization = read(LOCALIZATION)
    auto_paste = read(AUTO_PASTE)
    module = "\n".join(read(path) for path in [
        PRESENTER,
        AUTO_PASTE,
        SUPPORT,
        VIEW,
        *HOVER_DETAIL_SOURCES,
        WIDTH_HANDLE,
        *FILTER_BAR_SOURCES,
        *PANEL_SOURCES,
        *RECORD_VIEW_SOURCES,
        STATE,
        CLIPBOARD_CONTROLLER,
        CLIPBOARD_STORE,
        FEATURE_COORDINATOR,
        FEATURE_COORDINATOR.with_name("ClipboardFeatureCoordinator+CapturePersistence.swift"),
        PASTE_ORCHESTRATOR,
        PANEL_INTERACTION,
        PANEL_RECORD_CONTENT,
        PANEL_SESSION,
        LIVE_CAPTURE,
        LOCALIZATION,
        PANEL_SETTINGS,
        FILTERS,
        PREVIEW,
    ])
    record_views = "\n".join(read(path) for path in RECORD_VIEW_SOURCES)
    preview_source = read(PREVIEW)
    hover_detail = "\n".join(read(path) for path in HOVER_DETAIL_SOURCES)
    panel_settings = read(PANEL_SETTINGS)
    filter_controls = read(FILTER_BAR_SOURCES[2])
    clipboard_runtime = "\n".join(
        (
            state,
            clipboard_store,
            feature_coordinator,
            paste_orchestrator,
            panel_interaction,
        )
    )
    bottom_card_section = record_views.split("struct ClipboardFloatingRecordCard", 1)[1] if "struct ClipboardFloatingRecordCard" in record_views else ""
    checks = {
        "bottom_panel_is_fixed_system_resizable": all(
            token in presenter
            for token in (
                "ClipboardHistoryPanelStyle.mask",
                ".resizable",
                ".fullSizeContentView",
                ".nonactivatingPanel",
                "BlocksFloatingPanelWindowRole.transientNonactivatingUtility.apply(to: panel)",
            )
        )
        and ".titled," not in presenter.split("enum ClipboardHistoryPanelStyle", 1)[1].split("}", 1)[0]
        and "panel.isMovable = false" in support
        and "panel.isMovableByWindowBackground = false" in support,
        "bottom_panel_full_width_height_only": "x: visibleFrame.minX" in support
        and "width: visibleFrame.width" in support
        and "floatingPanel.clipboard.bottom.height" in support
        and "clipboardBottomMaxHeight" in support,
        "bottom_panel_top_edge_resize": "ClipboardTopBorderResizeView" in presenter
        and "ClipboardPanelContentContainer" in presenter
        and "addCursorRect" in presenter
        and "mouseDragged" in presenter
        and "NSCursor.resizeUpDown" in presenter
        and "safeAreaLayoutGuide.topAnchor" in presenter
        and "topResizeView.topAnchor.constraint(equalTo: topAnchor)" not in presenter,
        "bottom_visual_is_tray_first": "pasteStyleTray" in module
        and "LazyHStack" in module
        and "ClipboardFloatingRecordCard" in module,
        "bottom_visual_is_flush_glass": ".blocksSurface(" in module
        and ".floatingPanel" in module
        and "UnevenRoundedRectangle" in module
        and "bottomLeadingRadius: 0" in module
        and "bottomTrailingRadius: 0" in module,
        "bottom_visual_has_compact_spacing": "contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14)" in module
        and ".padding(.top, 5)" in module
        and ".padding(.bottom, 2)" in module,
        "bottom_visual_adapts_to_height": ".frame(maxHeight: 126)" not in module
        and "GeometryReader" in module
        and "bottomRecordCardHeight" in module
        and "bottomRecordCardBodyLineLimit" in module
        and "bottomTrayMinHeight" in module
        and "bottomCardMaxHeight" in module
        and "layoutPriority(1)" in module,
        "hover_detail_not_default_sidebar": ".popover(isPresented:" not in view
        and "ClipboardDetailPanelCoordinator" in module
        and "ClipboardDetailPresentationOverlay" in module
        and "ClipboardFloatingDetailCard" in module,
        "double_click_paste_path": "ClipboardRecordPointerSurface" in record_views
        and has_disambiguated_pointer_activation(record_views)
        and "TapGesture(count: 2)" not in record_views
        and "case .doubleClick:" in panel_interaction
        and "return .perform(.paste)" in panel_interaction
        and "clipboardHistoryPanelPresenter.authorizePasteAction" in feature_coordinator,
        "bottom_card_width_is_user_resizable": "clipboard.panel.bottom.cardWidth" in module
        and "ClipboardCardWidthResizeHandle" in module
        and "NSCursor.resizeLeftRight" in module
        and "NSTrackingArea" in module
        and "mouseEntered" in module
        and "mouseMoved" in module
        and "hitTest(_ point" in module
        and "cursorIsPushed" in module
        and "showResizeCursor()" in module
        and "resetResizeCursor()" in module
        and "NSCursor.pop()" in module
        and "viewWillMove(toWindow newWindow" in module
        and "mouseDragged" in module
        and "dragStartWidth" in module
        and "clipboard.panel.cardWidthResize.help" in module
        and "width.isFinite" in module
        and "bottomCardMinWidth" in panel_settings
        and "bottomCardMaxWidth" in panel_settings
        and "180" in panel_settings
        and "520" in panel_settings,
        "live_pasteboard_capture_service": (
            "final class ClipboardLiveCaptureService" in live_capture
            and "ClipboardBroker" in live_capture
            and "observe(" in live_capture
            and "ClipboardLiveCaptureSnapshot" in live_capture
            and "NSPasteboard.general" not in live_capture
            and "DispatchQueue(" not in live_capture
            and any(
                marker in live_capture
                for marker in ("latestPending", "pendingObservation", "latestObservation")
            )
        ),
        "clipboard_store_owns_live_payloads": "func readPayload(recordID:" in clipboard_store
        and "payloadCache" in clipboard_store
        and "func ingestLiveCapture(_ snapshot: ClipboardLiveCaptureSnapshot)" in feature_coordinator
        and "ingestLiveCaptureAsync(" in feature_coordinator,
        "preview_uses_real_payload": "func preview(metadata: ClipboardPinnedItemMetadata? = nil, payload: ClipboardRecorderPayload? = nil)" in preview_source
        and "previewBody(payload: payload)" in preview_source
        and "previewImage(payload: payload)" in preview_source
        and "previewImage(payload:" in preview_source
        and "urlDisplaySummary(payload:" in preview_source
        and "fileDisplayName(payload:" in preview_source
        and "ClipboardRecorderFixture.payloads()[id]" not in preview_source,
        "paste_uses_payload_argument": "readPayloadForAction(" in paste_orchestrator
        and "purpose: .paste" in paste_orchestrator
        and "payload: payloadResult.payload" in paste_orchestrator
        and "copyToPasteboard(" in paste_orchestrator
        and "record.fixtureOwned" not in paste_orchestrator,
        "single_click_detail_double_click_paste": "ClipboardPanelActivationDecision.resolve" in panel_interaction
        and "case .singleClick:" in panel_interaction
        and "return .selectAndOpenDetail" in panel_interaction
        and "onPerform(.singleClick, .detailOpen)" in panel_interaction
        and "case .doubleClick:" in panel_interaction
        and "return .perform(.paste)" in panel_interaction
        and "onSingleClick: { onPrimaryActivation(recordID, source, .singleClick) }" in record_views
        and "onDoubleClick: { onPrimaryActivation(recordID, source, .doubleClick) }" in record_views,
        "activation_gestures_are_explicit_and_disambiguated": has_disambiguated_pointer_activation(record_views)
        and ".simultaneousGesture(" not in record_views
        and "TapGesture(count: 2)" not in record_views
        and "NSApp.currentEvent?.clickCount" not in record_views,
        "hover_detail_has_enterable_bridge": "ClipboardDetailPanelCoordinator" in hover_detail
        and "ClipboardDetailPanelPlacement.frame(" in hover_detail
        and "ClipboardDetailPanelContainer" in hover_detail
        and "panel.isMovable = false" in hover_detail
        and "acceptsFirstMouse" in hover_detail
        and "focusCoordinator?.windowBecameKey(.detail" in hover_detail
        and "ClipboardHoverTrackingView" not in hover_detail
        and "ClipboardHoverDetailPanelCoordinator" not in hover_detail,
        "filter_click_controlled_no_hover_expand": has_click_controlled_filter_menu(filter_controls),
        "filter_hover_expand_removed": "filterHoverDismissTask" not in read(FILTER_BAR)
        and "scheduleFilterGroupDismiss" not in read(FILTER_BAR)
        and "handleFilterHover" not in read(FILTER_BAR),
        "filter_visual_hierarchy": "ClipboardFilterIslandButton" in module
        and "activeTitle ?? group.localizedTitle" in module
        and "ClipboardFilterBarLayout.islandIconSize" in module
        and "ClipboardFilterBarLayout.islandTextSize" in module
        and ".blocksFont(size: ClipboardFilterBarLayout.islandTextSize, weight: .semibold)" in module
        and ".blocksSurface(" in module
        and "BlocksVisualTokens.CornerRadius.control" in module
        and ".blocksAnimation(.selection, value: isExpanded || hasActiveFilter)" in module,
        "filter_option_toggle_off": "toggleFormatFilter" in view
        and "toggleTimeFilter" in view
        and "toggleSourceFilter" in view
        and "clipboardStore.filterState.format == option ? .all : option" in view
        and "clipboardStore.filterState.time == option ? .all : option" in view
        and "clipboardStore.filterState.sourceFilterKey == sourceKey ? nil : sourceKey" in view
        and "menuOption(" in filter_controls
        and "sourceMenuOption(" in filter_controls
        and "onSelectFormat(option)" in filter_controls
        and "onSelectTime(option)" in filter_controls
        and "onSelectSource(source.key)" in filter_controls,
        "interaction_negative_fixtures": clipboard_experience_negative_fixtures(),
        "bottom_cards_use_type_tint_without_kind_icon": "ClipboardRecordFormatIcon" in bottom_card_section
        and "ClipboardDirectContentPreview" in bottom_card_section
        and "ClipboardRecordDensityMetrics" in bottom_card_section
        and "ClipboardContentThumbnail" not in bottom_card_section,
        "direct_content_preview_visible": "ClipboardDirectContentPreview" in module
        and "Image(nsImage: image)" in module
        and "preview.body" in module
        and "scaledToFit" in module
        and "func preview(for record:" in clipboard_store
        and "previewSnapshots[record.id]" in clipboard_store,
        "autopaste_failure_types": "ClipboardPasteAttempt" in clipboard_runtime
        and "case notAuthorized" in auto_paste
        and "case targetApplicationUnavailable" in auto_paste
        and "recordCopiedFallback(.targetApplicationUnavailable)" in clipboard_runtime
        and "failureReason = .notAuthorized" in clipboard_runtime,
        "no_real_clipboard_content_logging": "Authorization" not in view
        and "Bearer" not in view
        and "raw response" not in view.lower(),
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7l_clipboard_experience_gate_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
