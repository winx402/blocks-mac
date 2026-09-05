#!/usr/bin/env python3
"""P7-I clipboard bottom tray window behavior checks."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift"
SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
VIEW = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift"
VIEW_EXTRACTED = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelHeader.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelLayout.swift",
]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    presenter = text(PRESENTER)
    support = text(SUPPORT)
    view = "\n".join(text(path) for path in [VIEW, *VIEW_EXTRACTED])
    checks = {
        "system_resizable_panel": "styleMask: [.titled, .resizable, .fullSizeContentView]" in presenter and ".borderless" not in presenter,
        "standard_buttons_hidden": "standardWindowButton" in presenter and "isHidden = true" in presenter,
        "resize_delegate_clamps": "windowWillResize" in presenter and "clipboardResizeSize" in presenter,
        "live_resize_reanchors": "windowDidResize" in presenter and "anchorPanel(panel, preservingBottomHeight: panel.frame.height)" in presenter,
        "not_movable": "panel.isMovable = false" in presenter and "panel.isMovableByWindowBackground = false" in presenter,
        "transparent_panel": "panel.backgroundColor = .clear" in presenter and "panel.isOpaque = false" in presenter,
        "bottom_anchor_full_width": "x: visibleFrame.minX" in support and "y: visibleFrame.minY" in support and "width: visibleFrame.width" in support,
        "bottom_height_only_persistence": "floatingPanel.clipboard.bottom.height" in support and "guard position == .bottom else" in support,
        "side_width_persistence": "floatingPanel.clipboard.side.width" in support
        and "clipboardSideMinWidth: CGFloat = 390" in support
        and "clipboardSideMaxWidth: CGFloat = 560" in support
        and "clipboardSideWidth(proposedWidth:" in support
        and "saveClipboardSideWidth" in support,
        "height_range": "clipboardBottomMinHeight: CGFloat = 260" in support and "clipboardBottomMaxHeight: CGFloat = 430" in support,
        "top_edge_resize_hit_test": "ClipboardTopBorderResizeView" in presenter
        and "ClipboardPanelContentContainer" in presenter
        and "addCursorRect" in presenter
        and "mouseDragged" in presenter
        and "NSCursor.resizeUpDown" in presenter
        and "safeAreaLayoutGuide.topAnchor" in presenter
        and "topResizeView.topAnchor.constraint(equalTo: topAnchor)" not in presenter,
        "top_edge_resize_persists_height": "onTopBorderResizeEnded" in presenter and "saveClipboard(frame: panel.frame, position: currentPosition)" in presenter,
        "bottom_glass_is_flush": "bottomAnchoredGlassPanel" in view and ".glassPanel(cornerRadius: position == .bottom" not in view,
        "bottom_tray_spacing_is_compact": "bottomPadding: 6" in view and ".padding(.vertical, 5)" not in view and ".padding(.bottom, 2)" in view,
        "bottom_tray_height_is_adaptive": ".frame(maxHeight: 126)" not in view
        and "GeometryReader" in view
        and "bottomRecordCardHeight" in view
        and "bottomRecordCardBodyLineLimit" in view
        and "bottomTrayMinHeight" in view
        and "bottomCardMaxHeight" in view
        and "layoutPriority(1)" in view,
        "side_edge_resize_hit_test": "ClipboardSideBorderResizeView" in presenter
        and "NSCursor.resizeLeftRight" in presenter
        and "onSideBorderResize" in presenter
        and "onSideBorderResizeEnded" in presenter,
        "side_row_height_resize_is_view_scoped": "ClipboardSideRowHeightResizeHandle" in view
        and "sideRowHeight" in view
        and "clipboard.panel.side.rowHeight" in text(ROOT / "apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift")
        and "sideRowHeightDragValue" in view
        and "previewSideRowHeight" in view
        and "commitSideRowHeight" in view
        and "transaction.disablesAnimations = true" in view,
        "no_custom_bottom_height_handle": "onResizeHeightChanged" not in view,
        "no_custom_bottom_drag_resize_presenter": "resizeBottomPanel" not in presenter,
    }
    failures = [{"code": key, "detail": "missing expected fixed bottom tray behavior"} for key, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7i_clipboard_bottom_tray_window_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
