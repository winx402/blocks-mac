#!/usr/bin/env python3
"""P7-E clipboard position and automatic-paste static checks."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"
SUPPORT = APP / "Services/FloatingPanelSupport.swift"
PRESENTER = APP / "Services/ClipboardHistoryPanelPresenter.swift"
AUTO_PASTE = APP / "Services/ClipboardAutoPasteCoordinator.swift"
APP_MODEL = APP / "App/AppModel.swift"
INTERACTION = APP / "Features/Clipboard/Panel/ClipboardPanelInteractionCoordinator.swift"
POINTER_SURFACE = APP / "Features/Clipboard/Records/ClipboardRecordPointerSurface.swift"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    support = text(SUPPORT)
    presenter = text(PRESENTER)
    auto_paste = text(AUTO_PASTE)
    app_model = text(APP_MODEL)
    interaction = text(INTERACTION)
    pointer_surface = text(POINTER_SURFACE)
    app_sources = "\n".join(text(path) for path in APP.rglob("*.swift"))
    checks = {
        "sources_present": all([support, presenter, auto_paste, app_model, interaction, pointer_surface]),
        "bottom_width_from_visible_frame": "width: visibleFrame.width" in support and "floatingPanel.clipboard.bottom.height" in support,
        "side_height_from_visible_frame": "height: max(420, visibleFrame.height)" in support,
        "clipboard_save_only_bottom": "guard position == .bottom else" in support,
        "resize_delegate_clamps": "windowWillResize" in presenter and "windowDidResize" in presenter and "clipboardResizeSize" in presenter,
        "autopaste_coordinator_exists": "final class ClipboardAutoPasteCoordinator" in auto_paste,
        "accessibility_prompt_gate": "AXIsProcessTrustedWithOptions" in auto_paste,
        "cmd_v_event": ".maskCommand" in auto_paste and "virtualKey: 0x09" in auto_paste,
        "appmodel_autopaste_entrypoint": "func pasteClipboardRecord(recordID:" in app_model,
        "legacy_paste_activation_mode_removed": (
            "ClipboardPasteActivationMode" not in app_sources
            and "clipboard.panel.pasteActivationMode" not in app_sources
        ),
        "native_click_contract": (
            "NSPressGestureRecognizer" in pointer_surface
            and pointer_surface.count("NSClickGestureRecognizer") >= 2
            and "numberOfClicksRequired = 1" in pointer_surface
            and "numberOfClicksRequired = 2" in pointer_surface
            and "shouldRequireFailureOf" in pointer_surface
            and "case .singleClick:" in interaction
            and "return .selectAndOpenDetail" in interaction
            and "case .doubleClick:" in interaction
            and "return .perform(.paste)" in interaction
        ),
    }
    ok = all(checks.values())
    print(json.dumps({"ok": ok, "check": "p7e_clipboard_position_autopaste", "checks": checks}, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
