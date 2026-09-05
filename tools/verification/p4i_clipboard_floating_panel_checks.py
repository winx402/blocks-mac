#!/usr/bin/env python3
"""P4-I clipboard floating panel checks for Blocks."""

from __future__ import annotations

from retired_p4_step5_cleanup_guard import main as _step5_retired_main

if __name__ == "__main__":
    raise SystemExit(_step5_retired_main(__file__))


import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
MENU_VIEW = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "MenuBarCommandsView.swift"
SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "SettingsView.swift"
PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardHistoryPanelPresenter.swift"
POSITION = ROOT / "apps" / "Blocks" / "BlocksApp" / "Models" / "FloatingPanelPosition.swift"
PANEL_VIEW = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardFloatingPanelView.swift"
SHORTCUT_CONTROLLER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ShortcutController.swift"
STORY = ROOT / "docs" / "项目管理库" / "实施记录" / "stories" / "p4-i-clipboard-floating-panel.md"

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-2400:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p4b = run(["python3", "tools/verification/p4b_clipboard_panel_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p4b["ok"], "p4b_regression_failed", p4b["stdout"] or p4b["stderr_tail"], failures)
    observations["p4b_regression"] = p4b["ok"]

    for path in [PRESENTER, POSITION, PANEL_VIEW, STORY]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    project_text = PROJECT.read_text(encoding="utf-8")
    required_project_refs = [
        "ClipboardHistoryPanelPresenter.swift in Sources",
        "FloatingPanelPosition.swift in Sources",
        "ClipboardFloatingPanelView.swift in Sources",
    ]
    observations["project_refs"] = {"checked": len(required_project_refs)}
    for ref in required_project_refs:
        require(ref in project_text, "missing_project_ref", ref, failures)

    combined = "\n".join(path.read_text(encoding="utf-8") for path in [APP_STATE, MENU_VIEW, SETTINGS, PRESENTER, PANEL_VIEW, SHORTCUT_CONTROLLER] if path.exists())
    required_symbols = [
        "ClipboardHistoryPanelPresenter",
        "FloatingPanelPosition",
        "showClipboardFloatingPanel",
        "clipboard.panel.position",
        "Option + V",
        "ClipboardFloatingPanelView",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(not missing_symbols, "missing_symbols", ", ".join(missing_symbols), failures)

    forbidden = ["URLSession", "Process(", "getenv(", "SecItem"]
    panel_text = "\n".join(path.read_text(encoding="utf-8") for path in [PRESENTER, PANEL_VIEW] if path.exists())
    forbidden_hits = [needle for needle in forbidden if needle in panel_text]
    if "NSPasteboard.general" in panel_text:
        require(
            "ClipboardAutoPasteCoordinator" in panel_text
            and "record.fixtureOwned, record.restorable" in panel_text
            and "AXIsProcessTrustedWithOptions" in panel_text,
            "unsafe_pasteboard_runtime",
            "NSPasteboard.general is allowed only in P7-E fixture-owned auto-paste coordinator.",
            failures,
        )
    require(not forbidden_hits, "forbidden_panel_runtime", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {"forbidden_panel_runtime": forbidden_hits}

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "clipboard.panel.title",
        "clipboard.panel.openMainWindow",
        "clipboard.panel.position",
        "clipboard.panel.position.bottom",
        "clipboard.panel.position.left",
        "clipboard.panel.position.right",
        "clipboard.panel.empty",
        "clipboard.panel.localOnly",
        "settings.clipboardPanelPosition",
        "settings.clipboardPanelPositionNote",
    ]
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
    observations["localization"] = {"checked": len(required_keys), "missing": missing_l10n}

    report = {
        "ok": not failures,
        "suite": "p4i_clipboard_floating_panel_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
