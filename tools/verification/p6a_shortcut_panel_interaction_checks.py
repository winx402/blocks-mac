#!/usr/bin/env python3
"""P6-A shortcut and floating panel interaction checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
APP_MODEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "App" / "AppModel.swift"
MENU_VIEW = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "MenuBarCommandsView.swift"
SETTINGS_SHELL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "SettingsShellView.swift"
SHORTCUT_SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "ShortcutSettingsPane.swift"
TRANSLATION_PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "TranslationFloatingPanelView.swift"
TRANSLATION_PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "TranslationPanelPresenter.swift"
SHORTCUT_CONTROLLER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ShortcutController.swift"
SHORTCUT_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Shortcuts" / "ShortcutStore.swift"
CLIPBOARD_PREVIEW = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardTextPreviewService.swift"
STEP4C_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_2_DEVELOPMENT_RECORD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "开发记录-Step4C-2-ShortcutStore-v0.md"

LANGUAGES = ["zh-Hans", "en", "ja"]
SOURCE_REQUIRED_SYMBOLS = [
    "ShortcutController",
    "ShortcutStore",
    "ShortcutActionHandlers",
    "registerDefaultShortcuts",
    "showTranslationFloatingPanel",
    "TranslationPanelPresenter",
    "TranslationFloatingPanelView",
    "ClipboardTextPreviewService",
    "Option + D",
    "kVK_ANSI_D",
    "showClipboardFloatingPanel",
]
REQUIRED_LOCALIZATION_KEYS = [
    "translation.panel.title",
    "translation.panel.source",
    "translation.panel.target",
    "translation.panel.readClipboardOnOpen",
    "translation.panel.clipboardPrefilled",
    "translation.panel.emptyInput",
    "translation.panel.openMainWindow",
    "settings.shortcutStatus",
    "settings.shortcutRegistered",
    "settings.shortcutConflict",
    "settings.translationPanelReadClipboard",
    "settings.translationShortcutDefault",
]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": sanitize_text(completed.stdout),
        "stderr_tail": sanitize_text(completed.stderr[-2400:]),
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def missing_localizations(localizable: dict[str, Any], required_keys: list[str]) -> list[str]:
    missing: list[str] = []
    for key in required_keys:
        entry = localizable.get("strings", {}).get(key)
        if entry is None:
            missing.append(key)
            continue
        missing_langs = [lang for lang in LANGUAGES if lang not in entry.get("localizations", {})]
        if missing_langs:
            missing.append(f"{key}:{','.join(missing_langs)}")
    return missing


def gate_self_checks() -> list[str]:
    """Keep source and localization gates independent of clipboard-read behavior."""
    errors: list[str] = []
    clipboard_key = "translation.panel.readClipboardOnOpen"
    if clipboard_key in SOURCE_REQUIRED_SYMBOLS:
        errors.append("clipboard localization key is incorrectly required in Swift source")

    complete_fixture = {
        "strings": {
            key: {"localizations": {lang: {} for lang in LANGUAGES}}
            for key in REQUIRED_LOCALIZATION_KEYS
        }
    }
    if missing_localizations(complete_fixture, REQUIRED_LOCALIZATION_KEYS):
        errors.append("complete localization fixture unexpectedly failed")
    del complete_fixture["strings"][clipboard_key]["localizations"]["ja"]
    expected_mutation = [f"{clipboard_key}:ja"]
    if missing_localizations(complete_fixture, REQUIRED_LOCALIZATION_KEYS) != expected_mutation:
        errors.append("missing localization mutation did not fail precisely")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--skip-build", action="store_true", help="Skip ./script/build_and_run.sh --verify.")
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    if args.skip_build:
        observations["app_build"] = {"ok": True, "skipped": True}
    else:
        build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    for path in [TRANSLATION_PANEL, TRANSLATION_PRESENTER, SHORTCUT_CONTROLLER, SHORTCUT_STORE, CLIPBOARD_PREVIEW, STEP4C_PRD, STEP4C_2_DEVELOPMENT_RECORD]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    project_text = PROJECT.read_text(encoding="utf-8")
    for source_name in [
        "ShortcutController.swift",
        "TranslationPanelPresenter.swift",
        "TranslationFloatingPanelView.swift",
        "ClipboardTextPreviewService.swift",
        "ShortcutStore.swift",
    ]:
        require(f"{source_name} in Sources" in project_text, "missing_project_ref", source_name, failures)

    combined_paths = [
        APP_MODEL,
        MENU_VIEW,
        SETTINGS_SHELL,
        SHORTCUT_SETTINGS,
        TRANSLATION_PANEL,
        TRANSLATION_PRESENTER,
        SHORTCUT_CONTROLLER,
        SHORTCUT_STORE,
        CLIPBOARD_PREVIEW,
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in combined_paths if path.exists())
    missing_symbols = [symbol for symbol in SOURCE_REQUIRED_SYMBOLS if symbol not in combined]
    require(not missing_symbols, "missing_symbols", ", ".join(missing_symbols), failures)

    forbidden_in_shortcut_ui = ["SecItem", "Authorization", "Bearer", "codex exec", "Process("]
    forbidden_hits = [needle for needle in forbidden_in_shortcut_ui if needle in combined]
    require(not forbidden_hits, "forbidden_shortcut_panel_runtime", ", ".join(forbidden_hits), failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = REQUIRED_LOCALIZATION_KEYS
    missing_l10n = missing_localizations(localizable, required_keys)
    require(not missing_l10n, "missing_localization", ", ".join(missing_l10n), failures)
    self_check_errors = gate_self_checks()
    require(not self_check_errors, "gate_self_check_failed", "; ".join(self_check_errors), failures)
    observations["localization"] = {"checked": len(required_keys), "missing": missing_l10n}
    observations["gate_self_checks"] = {"errors": self_check_errors}
    observations["privacy_boundary"] = {"forbidden_hits": forbidden_hits}
    observations["current_evidence"] = {
        "prd": str(STEP4C_PRD.relative_to(ROOT)),
        "development_record": str(STEP4C_2_DEVELOPMENT_RECORD.relative_to(ROOT)),
    }
    observations["baseline_reference"] = {
        "legacy_story_used_for_ok": False,
        "note": "P6A Step 4C-2 checks use current PRD, current development record, and current code facts.",
    }

    prd_text = STEP4C_PRD.read_text(encoding="utf-8") if STEP4C_PRD.exists() else ""
    development_text = STEP4C_2_DEVELOPMENT_RECORD.read_text(encoding="utf-8") if STEP4C_2_DEVELOPMENT_RECORD.exists() else ""
    required_current_terms = ["Step 4C-2", "ShortcutStore", "P6A", "声明动作"]
    missing_current_terms = [term for term in required_current_terms if term not in prd_text and term not in development_text]
    require(not missing_current_terms, "current_evidence_missing_terms", ", ".join(missing_current_terms), failures)

    report = {
        "ok": not failures,
        "suite": "p6a_shortcut_panel_interaction_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
