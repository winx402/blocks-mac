#!/usr/bin/env python3
"""P7-C settings navigation and standalone settings checks for current Step 4C files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CONTENT = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ContentView.swift"
APP_SECTION = ROOT / "apps" / "Blocks" / "BlocksApp" / "Models" / "AppSection.swift"
SETTINGS_VIEW = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "SettingsView.swift"
SETTINGS_DIR = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings"
BLOCKS_APP = ROOT / "apps" / "Blocks" / "BlocksApp" / "App" / "BlocksApp.swift"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
STEP4C_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_RECORD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "开发记录-Step4C-3-SettingsShell-v0.md"
LANGUAGES = ["zh-Hans", "en", "ja"]


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def text(path: Path, failures: list[dict[str, str]]) -> str:
    if not path.exists():
        failures.append({"code": "missing_file", "detail": rel(path)})
        return ""
    return path.read_text(encoding="utf-8")


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.parse_args()

    failures: list[dict[str, str]] = []
    content = text(CONTENT, failures)
    app_section = text(APP_SECTION, failures)
    settings_view = SETTINGS_VIEW.read_text(encoding="utf-8") if SETTINGS_VIEW.exists() else ""
    blocks_app = text(BLOCKS_APP, failures)
    section_list = text(SETTINGS_DIR / "SettingsSectionList.swift", failures)
    shell = text(SETTINGS_DIR / "SettingsShellView.swift", failures)
    permission = text(SETTINGS_DIR / "PermissionSettingsPane.swift", failures)
    text(STEP4C_PRD, failures)
    text(STEP4C_RECORD, failures)

    required_content_symbols = [
        "BlocksSidebarView",
        "SidebarSectionButton",
        ".frame(width: 224",
        ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)",
        "SettingsShellView(mode: .general)",
        "SettingsShellView(mode: .shortcuts)",
        "SettingsShellView(mode: .providers)",
        "SettingsShellView(mode: .permissions)",
    ]
    missing_content = [symbol for symbol in required_content_symbols if symbol not in content]
    require(not missing_content, "missing_stable_split_symbols", ", ".join(missing_content), failures)
    require("NavigationSplitView" not in content, "navigation_split_still_present", "ContentView should use stable manual split for this bugfix.", failures)
    require("List(selection: $appState.selectedSection)" not in content, "native_list_still_present", "Sidebar List should not control P7-C main navigation height.", failures)
    require(not SETTINGS_VIEW.exists(), "settings_view_wrapper_remaining", "SettingsView.swift must be deleted in Step 5.", failures)
    require("SettingsShellView(mode: .all)" in blocks_app, "settings_scene_direct_shell_missing", "Settings scene should use SettingsShellView directly.", failures)

    required_sections = [
        "case shortcuts",
        "case providers",
        "case permissions",
        "menu.shortcuts",
        "menu.providers",
        "menu.permissions",
    ]
    missing_sections = [symbol for symbol in required_sections if symbol not in app_section]
    require(not missing_sections, "missing_standalone_sections", ", ".join(missing_sections), failures)

    required_settings_symbols = [
        "enum SettingsViewMode",
        "case general",
        "case shortcuts",
        "case providers",
        "case permissions",
        "case .general:",
        "case .shortcuts:",
        "case .providers:",
        "case .permissions:",
        "GeneralSettingsPane()",
        "ShortcutSettingsPane()",
        "ProviderSettingsPane()",
        "PermissionSettingsPane()",
        "PermissionDragDropCard",
        "Bundle.main.bundleURL",
        ".onDrag",
    ]
    settings_combined = "\n".join([settings_view, section_list, shell, permission])
    missing_settings = [symbol for symbol in required_settings_symbols if symbol not in settings_combined]
    require(not missing_settings, "missing_settings_mode_symbols", ", ".join(missing_settings), failures)

    localizable = json.loads(text(LOCALIZABLE, failures))
    required_keys = [
        "menu.shortcuts",
        "menu.providers",
        "menu.permissions",
        "settings.permissionDrag.title",
        "settings.permissionDrag.detail",
        "settings.permissionDrag.badge",
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

    report: dict[str, Any] = {
        "ok": not failures,
        "suite": "p7c_settings_navigation_provider_shortcuts_checks",
        "failures": failures,
        "observations": {
            "checked_files": [rel(path) for path in [CONTENT, APP_SECTION, BLOCKS_APP, SETTINGS_VIEW, SETTINGS_DIR / "SettingsShellView.swift", SETTINGS_DIR / "SettingsSectionList.swift", SETTINGS_DIR / "PermissionSettingsPane.swift", LOCALIZABLE, STEP4C_PRD, STEP4C_RECORD]],
            "current_evidence": {
                "settings_shell": rel(SETTINGS_DIR / "SettingsShellView.swift"),
                "permission_pane": rel(SETTINGS_DIR / "PermissionSettingsPane.swift"),
            },
            "baseline_reference": {
                "legacy_sources_used_for_ok": False,
            },
        },
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
