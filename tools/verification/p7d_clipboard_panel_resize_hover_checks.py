#!/usr/bin/env python3
"""P7-D clipboard floating-panel resize and position checks.

This legacy gate intentionally covers geometry/persistence only. Primary-click
semantics live in P13-C, where the AppKit pointer surface is checked directly.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    support = text(SUPPORT)
    presenter = text(PRESENTER)
    checks = {
        "sources_present": bool(support and presenter),
        "bottom_panel_uses_visible_frame_width": (
            "width: visibleFrame.width" in support
            and "floatingPanel.clipboard.bottom.height" in support
        ),
        "side_panel_uses_visible_frame_height": "height: max(420, visibleFrame.height)" in support,
        "bottom_resize_is_height_only": (
            "case .bottom:" in support
            and "width: frame.width" in support
            and "clipboardBottomHeight(proposedHeight: proposedSize.height" in support
        ),
        "side_resize_is_width_only": (
            "case .left, .right:" in support
            and "clipboardSideWidth(proposedWidth: proposedSize.width" in support
            and "height: frame.height" in support
        ),
        "only_bottom_height_is_persisted": (
            "static func saveClipboard" in support
            and "guard position == .bottom else" in support
            and "clipboardBottomHeightKey" in support
        ),
        "presenter_clamps_and_persists_resize": (
            "func windowWillResize" in presenter
            and "func windowDidResize" in presenter
            and "FloatingPanelFrameStore.clipboardResizeSize" in presenter
            and "FloatingPanelFrameStore.saveClipboard" in presenter
            and "FloatingPanelFrameStore.saveClipboardSideWidth" in presenter
        ),
    }
    ok = all(checks.values())
    print(json.dumps({"ok": ok, "suite": "p7d_clipboard_panel_resize_hover_checks", "checks": checks}, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
