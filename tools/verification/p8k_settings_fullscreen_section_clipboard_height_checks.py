#!/usr/bin/env python3
"""P8-K current clipboard bottom-panel ownership and height checks."""

from __future__ import annotations

import argparse
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
PRESENTER = APP / "Services" / "ClipboardHistoryPanelPresenter.swift"
WINDOW_ROLE = APP / "Services" / "FloatingPanelSupport.swift"
LAYOUT = APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def body_of(source: str, declaration: str) -> str:
    start = source.find(declaration)
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    return ""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.parse_args(argv)
    presenter, role, layout = (read(path) for path in [PRESENTER, WINDOW_ROLE, LAYOUT])
    style = body_of(presenter, "enum ClipboardHistoryPanelStyle")
    failures: list[str] = []

    for flag in [".resizable", ".fullSizeContentView", ".nonactivatingPanel"]:
        require(flag in style, f"ClipboardHistoryPanelStyle must include {flag}.", failures)
    require(".titled" not in style, "ClipboardHistoryPanelStyle must remain titleless.", failures)
    require("ClipboardHistoryPanelStyle.mask" in presenter,
            "Panel construction must use ClipboardHistoryPanelStyle.mask.", failures)
    require("panel.isMovable = false" in role and "panel.isMovableByWindowBackground = false" in role,
            "Clipboard panel role must reject background dragging.", failures)
    require("ClipboardTopBorderResizeView" in presenter and "mouseDragged" in presenter,
            "Top-edge resize ownership is required.", failures)
    require("func windowWillResize" in presenter and "clipboardResizeSize(" in presenter,
            "System resizing must be clamped by clipboardResizeSize.", failures)
    require("anchorPanel(panel, preservingBottomHeight: panel.frame.height)" in presenter,
            "Bottom panel must re-anchor while resizing.", failures)
    require("FloatingPanelFrameStore.saveClipboard(frame: panel.frame, position: currentPosition)" in presenter,
            "Bottom panel height must be persisted after resize.", failures)

    bottom = body_of(layout, "private var decoratedContent")
    require(".blocksSurface(" in bottom and ".panel" in bottom,
            "Bottom panel must use the shared panel surface.", failures)
    for token in ["BlocksVisualTokens.CornerRadius.large", "bottomLeadingRadius: 0",
                  "bottomTrailingRadius: 0",
                  "contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14)"]:
        require(token in bottom, f"Bottom flush surface must be tokenized: {token}", failures)
    require("cornerRadius: 16" not in bottom and "RoundedRectangle(cornerRadius:" not in bottom,
            "Bottom flush surface must not introduce literal rounded corners.", failures)

    if failures:
        print("P8-K checks failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("P8-K checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
