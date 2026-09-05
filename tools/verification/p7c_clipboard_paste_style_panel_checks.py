#!/usr/bin/env python3
"""P7-C Paste-style clipboard floating panel checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardFloatingPanelView.swift"
PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardHistoryPanelPresenter.swift"
SUPPORT = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "FloatingPanelSupport.swift"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": completed.stdout[-2400:],
        "stderr_tail": completed.stderr[-2400:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    panel = text(PANEL)
    presenter = text(PRESENTER)
    support = text(SUPPORT)

    required_symbols = [
        "pasteStyleTray",
        "ClipboardFloatingRecordCard",
        "ScrollView(.horizontal",
        "LazyHStack",
        "frame(width: 180",
        "clipboard.panel.pasteStyle",
        "clipboard.panel.hoverHint",
        "hoverDetailOverlay",
        "ClipboardFloatingDetailCard",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in panel]
    require(not missing_symbols, "missing_paste_style_symbols", ", ".join(missing_symbols), failures)
    require(
        "FloatingPanelFrameStore.clipboardFrame" in presenter
        and "visibleFrame.width - margin * 2" in support
        and "floatingPanel.clipboard.bottom.height" in support
        and "guard position == .bottom else" in support,
        "bottom_tray_size_not_updated",
        "Bottom clipboard panel should be full-width and persist height only after P7-E.",
        failures,
    )

    forbidden = ["URLSession", "Process(", "getenv(", "SecItem", "Authorization", "Bearer", "NSPasteboard.general"]
    forbidden_hits = [needle for needle in panel if False]
    forbidden_hits = [needle for needle in forbidden if needle in panel]
    require(not forbidden_hits, "forbidden_clipboard_panel_runtime", ", ".join(forbidden_hits), failures)

    localizable = json.loads(text(LOCALIZABLE))
    required_keys = ["clipboard.panel.pasteStyle", "clipboard.panel.hoverHint"]
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localizable.get("strings", {}).get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [lang for lang in LANGUAGES if lang not in entry.get("localizations", {})]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(not missing_l10n, "missing_localization", ", ".join(missing_l10n), failures)

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"] or build["stdout_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    report = {
        "ok": not failures,
        "suite": "p7c_clipboard_paste_style_panel_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
