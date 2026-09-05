#!/usr/bin/env python3
"""P7-I clipboard tray visual structure checks."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift"
VIEW_EXTRACTED = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelHeader.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelLayout.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPanelFocusCoordinator.swift",
]
HOVER_DETAIL = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift"
HOVER_DETAIL_SOURCES = [
    HOVER_DETAIL,
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardHoverTracking.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardHoverDetailPanel.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardFloatingDetailCard.swift",
]
FILTER_BAR = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift"
FILTER_BAR_SOURCES = [
    FILTER_BAR,
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Filters/ClipboardTagFilterChips.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Filters/ClipboardFilterControls.swift",
]
RECORD_VIEWS = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift"
RECORD_VIEW_SOURCES = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordPreviewViews.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordMenus.swift",
    RECORD_VIEWS,
]
WIDTH_HANDLE = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardCardWidthResizeHandle.swift"
PANEL_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift"
LOCALIZABLE = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"
LANGUAGES = ["zh-Hans", "en", "ja"]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    view = "\n".join(text(path) for path in [VIEW, *VIEW_EXTRACTED])
    module = "\n".join(text(path) for path in [VIEW, *VIEW_EXTRACTED, *HOVER_DETAIL_SOURCES, *FILTER_BAR_SOURCES, *RECORD_VIEW_SOURCES, WIDTH_HANDLE, PANEL_SETTINGS])
    record_views = "\n".join(text(path) for path in RECORD_VIEW_SOURCES)
    bottom_card_section = record_views.split("struct ClipboardFloatingRecordCard", 1)[1] if "struct ClipboardFloatingRecordCard" in record_views else ""
    strings = json.loads(text(LOCALIZABLE)).get("strings", {})
    required_keys = [
        "clipboard.panel.title",
        "clipboard.searchPlaceholder",
        "clipboard.panel.keyboardHint",
        "clipboard.panel.empty",
        "clipboard.panel.emptyDetail",
        "clipboard.panel.openMainWindow",
        "clipboard.pauseRecorder",
        "clipboard.resumeRecorder",
        "common.close",
        "menu.settings",
    ]
    localization_missing: list[str] = []
    for key in required_keys:
        localizations = strings.get(key, {}).get("localizations", {})
        for language in LANGUAGES:
            if language not in localizations:
                localization_missing.append(f"{key}:{language}")

    checks = {
        "search_in_header": "struct ClipboardPanelHeader" in view and "private var searchBar" in view and "bottomHeader" in view and "sideHeader" in view,
        "horizontal_tray": "ScrollView(.horizontal" in view and "LazyHStack(alignment: .center" in view,
        "adaptive_content_cards": "cardWidth: bottomRecordCardWidth" in view
        and "cardHeight: cardHeight" in view
        and "bottomRecordCardHeight" in view
        and "ClipboardDirectContentPreview" in module,
        "enterable_following_detail": "isHovered" in view
        and "ClipboardRecordFramePreferenceKey" in module
        and "ClipboardHoverDetailPanelCoordinator" in module
        and "ClipboardHoverTrackingView" in module
        and "recordScreenFrames()" in module
        and "convertToScreen" in module
        and "handleMouseMoved" in module
        and "detailPanelFrame" in module
        and "detailBridgeScreenFrame" in module
        and "ClipboardPanelFocusCoordinator" in module
        and "ClipboardPanelKeyboardCommandRouter" in module
        and "ClipboardHoverDetailPanelContainer" in module
        and "override func acceptsFirstMouse(for event: NSEvent?) -> Bool" in module
        and "window?.makeKey()" not in module
        and "return false" in module,
        "filter_hierarchy_visible": "ClipboardFilterIslandButton" in module
        and "ClipboardFilterMenuGroup" in module
        and "islandIconSize" in module
        and "islandTextSize" in module
        and "filterOptionButtonLabel" in module,
        "filter_is_click_controlled": "ClipboardFilterClickGroup" in module
        and "collapseExpandedFilterGroupIfCurrent" in module
        and "filterHoverDismissTask" not in module
        and "scheduleFilterGroupDismiss" not in module
        and "handleFilterHover" not in module
        and "onHoverChange" not in module,
        "filter_option_hit_area": "filterOptionButtonLabel" in module
        and ".frame(minHeight: 28" in module
        and ".contentShape(Capsule" in module,
        "kind_tinted_cards_with_kind_icons": "clipboardCardBackgroundTint" in module
        and "record.kind.cardTint" in module
        and "record.kind.cardBorderTint" in module
        and "ClipboardRecordFormatIcon" in bottom_card_section
        and "recordKind.formatFilterIcon" in module,
        "no_visible_hover_instruction": 'L10n.string("clipboard.panel.hoverHint")' not in module,
        "compact_footer": "metadataSlotHeight: CGFloat = 14" in module
        and "cardFooterSlotHeight: CGFloat = 14" in module
        and "cardVerticalPadding: CGFloat = 6" in module
        and "ClipboardCardMetaLabel" in module,
        "paste_activation_high_priority": "highPriorityGesture(TapGesture(count: 2)" in module
        and "simultaneousGesture(TapGesture(count: 1)" in module
        and "scheduleSingleClickActivation" in module,
        "localization_complete": not localization_missing,
    }
    failures = [{"code": key, "detail": "missing expected tray visual structure"} for key, ok in checks.items() if not ok]
    if localization_missing:
        failures.append({"code": "missing_localization", "detail": ", ".join(localization_missing)})

    print(json.dumps({
        "ok": not failures,
        "suite": "p7i_clipboard_tray_visual_structure_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
