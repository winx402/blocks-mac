#!/usr/bin/env python3
"""P8-L Clipboard bottom panel height-anchor checks."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
FLOATING_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
CLIPBOARD_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift"
CLIPBOARD_VIEW = ROOT / "apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift"
CLIPBOARD_VIEW_EXTRACTED = [
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelHeader.swift",
    ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Panel/ClipboardPanelLayout.swift",
]
ARCHIVED_ACCEPTANCE = ROOT / "docs/项目管理库/000_归档/2026-07-05_项目视图改造前/实施记录/acceptance"
P8K_RECORD = ARCHIVED_ACCEPTANCE / "p8-k-settings-fullscreen-section-clipboard-height-record.md"
P8L_RECORD = ARCHIVED_ACCEPTANCE / "p8-l-clipboard-bottom-height-anchor-record.md"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def function_body(source: str, name: str) -> str:
    marker = f"static func {name}"
    start = source.find(marker)
    if start < 0:
        return ""
    brace = source.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]
    return ""


def method_body(source: str, name: str) -> str:
    marker = f"func {name}"
    start = source.find(marker)
    if start < 0:
        marker = f"private func {name}"
        start = source.find(marker)
    if start < 0:
        return ""
    brace = source.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]
    return ""


def check_frame_store(failures: list[str]) -> None:
    support = read(FLOATING_SUPPORT)
    bottom_frame = function_body(support, "clipboardBottomFrame(\n        visibleFrame")
    save_clipboard = function_body(support, "saveClipboard")

    require(bottom_frame, "Missing pure clipboardBottomFrame(visibleFrame:height:) helper.", failures)
    require("x: visibleFrame.minX" in bottom_frame, "Bottom helper must anchor x to visibleFrame.minX.", failures)
    require("y: visibleFrame.minY" in bottom_frame, "Bottom helper must anchor y to visibleFrame.minY.", failures)
    require("width: visibleFrame.width" in bottom_frame, "Bottom helper must anchor width to visibleFrame.width.", failures)
    require(
        "height: clipboardBottomHeight(proposedHeight: height, visibleFrame: visibleFrame)" in bottom_frame,
        "Bottom helper must clamp only the height input.",
        failures,
    )

    require("private static let clipboardBottomMinHeight: CGFloat = 260" in support, "Clipboard bottom min height must be 260.", failures)
    require("private static let clipboardBottomMaxHeight: CGFloat = 430" in support, "Clipboard bottom max height must be 430.", failures)
    require("startHeight" not in support and "translationY" not in support, "Custom drag-height helper must be removed.", failures)

    require('private static let clipboardBottomHeightKey = "floatingPanel.clipboard.bottom.height"' in support, "Clipboard height key missing.", failures)
    require(save_clipboard, "saveClipboard(frame:position:) missing.", failures)
    require("UserDefaults.standard.set(frame.height, forKey: clipboardBottomHeightKey)" in save_clipboard, "Clipboard save path must persist frame.height only.", failures)
    require("frame.minX" not in save_clipboard and "frame.minY" not in save_clipboard and "frame.width" not in save_clipboard, "Clipboard save path must not persist position or width.", failures)


def check_presenter(failures: list[str]) -> None:
    presenter = read(CLIPBOARD_PRESENTER)
    will_resize = method_body(presenter, "windowWillResize")
    did_resize = method_body(presenter, "windowDidResize")
    end_resize = method_body(presenter, "windowDidEndLiveResize")
    move = method_body(presenter, "windowDidMove")
    anchored = method_body(presenter, "anchoredFrame")

    require("private var isApplyingAnchoredFrame = false" in presenter, "Presenter needs a re-entrant anchor guard.", failures)
    require("bottomResizeStartHeight" not in presenter, "Custom drag resize state must be removed.", failures)
    require(anchored, "Presenter must have a centralized anchoredFrame helper.", failures)
    require("FloatingPanelFrameStore.clipboardBottomFrame(screen: screen, height: height)" in anchored, "anchoredFrame must use clipboardBottomFrame for bottom mode.", failures)

    require("resizeBottomPanel" not in presenter and "translationY" not in presenter, "Custom drag resize path must be removed.", failures)
    require(will_resize, "windowWillResize method missing.", failures)
    require("FloatingPanelFrameStore.clipboardResizeSize(" in will_resize, "windowWillResize must clamp to fixed width and height range.", failures)
    require("ClipboardTopBorderResizeView" in presenter, "Presenter must install a top-border AppKit resize overlay for the transparent bottom panel.", failures)
    require("ClipboardPanelContentContainer" in presenter, "Clipboard hosting view must be wrapped with an AppKit container that overlays the resize hit view.", failures)
    require(
        "override func sendEvent(_ event: NSEvent)" in presenter
        and "applyTopBorderResize" not in method_body(presenter, "sendEvent"),
        "Clipboard NSPanel.sendEvent may route quick-paste keys, but must not own resize behavior.",
        failures,
    )
    require("addCursorRect" in presenter, "Top-border resize overlay must register a cursor rect.", failures)
    require("mouseDragged" in presenter, "Top-border resize overlay must handle mouse dragging directly.", failures)
    require("NSCursor.resizeUpDown" in presenter, "Top-border resize hover must advertise vertical resize with the system cursor.", failures)
    require("safeAreaLayoutGuide.topAnchor" in presenter, "Top-border resize overlay must align to the visible content/safe-area top edge.", failures)
    require("topResizeView.topAnchor.constraint(equalTo: topAnchor)" not in presenter, "Top-border resize overlay must not stay pinned to the transparent window/container top.", failures)
    require("onTopBorderResize" in presenter and "onTopBorderResizeEnded" in presenter, "Top-border resize must flow through presenter-owned geometry and persistence callbacks.", failures)
    require(did_resize, "windowDidResize method missing.", failures)
    require("currentPosition == .bottom" in did_resize, "windowDidResize must only re-anchor bottom mode.", failures)
    require("anchorPanel(panel, preservingBottomHeight: panel.frame.height)" in did_resize, "windowDidResize must preserve current system-resized height.", failures)

    require(end_resize, "windowDidEndLiveResize method missing.", failures)
    require("anchorPanel(panel, preservingBottomHeight: panel.frame.height)" in end_resize, "Live resize end must preserve current height and re-anchor bottom.", failures)
    require("CGRect(" not in end_resize, "windowDidEndLiveResize must not hand-build bottom CGRects.", failures)

    require(move, "windowDidMove method missing.", failures)
    require("!isApplyingAnchoredFrame" in move, "windowDidMove must not fight anchor re-application.", failures)
    require("anchorPanel(panel)" in move, "windowDidMove must clamp back to the bottom anchor.", failures)
    require("anchorFrame.size.height" not in presenter, "Presenter must not mutate anchorFrame height ad hoc.", failures)


def check_panel_window_and_view(failures: list[str]) -> None:
    presenter = read(CLIPBOARD_PRESENTER)
    view = "\n".join(read(path) for path in [CLIPBOARD_VIEW, *CLIPBOARD_VIEW_EXTRACTED])

    require(
        "styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]" in presenter,
        "Clipboard panel must use resizable non-activating system chrome.",
        failures,
    )
    require(".borderless" not in presenter, "Clipboard panel must no longer be borderless.", failures)
    require("standardWindowButton" in presenter and "isHidden = true" in presenter, "Standard window buttons must be hidden.", failures)
    require("panel.isMovable = false" in presenter, "Clipboard panel must not be movable.", failures)
    require("panel.isMovableByWindowBackground = false" in presenter, "Clipboard panel must not move through window background dragging.", failures)
    require("onResizeHeightChanged" not in view and "onResizeHeightEnded" not in view, "Clipboard view must not expose custom resize callbacks.", failures)
    require("resizeHandle" not in view, "Clipboard view must not render a custom resize handle.", failures)
    require("DragGesture(minimumDistance: 2)" not in view, "Clipboard height must not use a custom drag gesture.", failures)
    require(
        ".blocksSurface(" in view
        and ".floatingPanel" in view
        and "UnevenRoundedRectangle(" in view
        and "bottomLeadingRadius: 0" in view
        and "bottomTrailingRadius: 0" in view,
        "Bottom clipboard panel must use the shared flush-bottom floating-panel surface.",
        failures,
    )
    require(
        "contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14)" in view,
        "Bottom clipboard panel bottom padding must stay compact.",
        failures,
    )
    require(".padding(.vertical, 5)" not in view, "Bottom tray must not keep symmetric vertical padding.", failures)
    require(".padding(.bottom, 2)" in view, "Bottom tray should keep only a small bottom inset.", failures)
    require(".frame(maxHeight: 126)" not in view, "Bottom tray must not keep a fixed 126pt height.", failures)
    require("GeometryReader" in view and "bottomRecordCardHeight" in view, "Bottom tray must compute card height from available panel height.", failures)
    require("bottomRecordCardBodyLineLimit" in view, "Bottom record cards must adapt text capacity as their height grows.", failures)
    require("bottomTrayMinHeight" in view and "bottomCardMaxHeight" in view, "Bottom tray/card height clamps must be explicit.", failures)
    require("layoutPriority(1)" in view, "Bottom tray must receive the remaining panel height instead of leaving empty space.", failures)


def check_docs(failures: list[str]) -> None:
    p8k = read(P8K_RECORD)
    p8l = read(P8L_RECORD) if P8L_RECORD.exists() else ""

    require("reopened_by_p8l" in p8k, "P8-K record must mark the old clipboard height pass as reopened by P8-L.", failures)
    require("P8-L" in p8l and "visibleFrame.minY" in p8l, "P8-L acceptance record must document the bottom-anchor invariant.", failures)
    require("关闭重开后高度保持" in p8l, "P8-L record must cover close/reopen height persistence.", failures)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.parse_args(argv)

    failures: list[str] = []
    check_frame_store(failures)
    check_presenter(failures)
    check_panel_window_and_view(failures)
    check_docs(failures)

    if failures:
        print("P8-L checks failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("P8-L checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
