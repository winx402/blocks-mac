#!/usr/bin/env python3
"""P8-G settings shell redesign checks using current Step 4C facts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_SECTION = ROOT / "apps/Blocks/BlocksApp/Models/AppSection.swift"
CONTENT_VIEW = ROOT / "apps/Blocks/BlocksApp/Views/ContentView.swift"
SETTINGS_DIR = ROOT / "apps/Blocks/BlocksApp/Features/Settings"
LOCALIZABLE = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"
STEP4C_PRD = ROOT / "docs/项目管理库/003_架构升级/step_4/PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_RECORD = ROOT / "docs/项目管理库/003_架构升级/step_4/开发记录-Step4C-3-SettingsShell-v0.md"


REQUIRED_KEYS = [
    "sidebar.subtitle",
    "sidebar.group.tools",
    "sidebar.group.system",
    "sidebar.group.intelligence",
    "sidebar.group.data",
    "sidebar.group.app",
    "settings.general.title",
    "settings.navigation.accessibilityLabel",
    "menu.agentCLI",
    "menu.hooks",
    "menu.dataAudit",
    "settings.backToClipboard",
    "settings.agentCLI.title",
    "settings.agentCLI.detail",
    "settings.hooks.title",
    "settings.hooks.detail",
    "settings.dataAudit.title",
    "settings.dataAudit.detail",
]

REQUIRED_SETTINGS_FILES = [
    "SettingsShellView.swift",
    "SettingsSectionList.swift",
    "GeneralSettingsPane.swift",
    "ClipboardSettingsPane.swift",
    "ShortcutSettingsPane.swift",
    "PermissionSettingsPane.swift",
    "ProviderSettingsPane.swift",
    "TranslationSettingsPane.swift",
    "AgentCLISettingsPane.swift",
    "HooksSettingsPane.swift",
    "DataAuditSettingsPane.swift",
]


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path, failures: list[dict[str, str]]) -> str:
    if not path.exists():
        failures.append({"code": "missing_file", "detail": rel(path)})
        return ""
    return path.read_text(encoding="utf-8")


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def check_sidebar(content: str, failures: list[dict[str, str]]) -> None:
    require("ForEach(AppSection.allCases)" not in content, "sidebar_all_cases_regression", "sidebar still renders AppSection.allCases directly", failures)
    require(
        "SettingsSidebarSourceListModel" in content
        and "SettingsSourceListBridge" in content
        and "NSOutlineViewDataSource" in content,
        "sidebar_grouped_source_list_missing",
        "Settings sidebar must use the grouped AppKit source-list bridge.",
        failures,
    )

    for section in [".screenshot", ".clipboardSettings", ".translationSettings", ".translationFavorites", ".shortcuts", ".permissions", ".providers", ".agentCLI", ".hooks", ".dataAudit", ".settings"]:
        require(section in content, "sidebar_visible_section_missing", section, failures)

    require(
        "appModel.selectedSection == .clipboardPrivacy" in content
        and "? .clipboardSettings" in content,
        "clipboard_child_selection_missing",
        "clipboard child selection mapping",
        failures,
    )
    require(
        'localizationKey: "sidebar.group.tools"' in content
        and 'localizationKey: "sidebar.group.system"' in content
        and 'localizationKey: "sidebar.group.intelligence"' in content
        and 'localizationKey: "sidebar.group.data"' in content
        and 'localizationKey: "sidebar.group.app"' in content,
        "sidebar_group_structure_missing",
        "The source list must expose the five approved localized groups.",
        failures,
    )
    require(
        "isGroupItem item:" in content
        and "shouldSelectItem item:" in content
        and "item is SettingsSidebarRouteNode" in content,
        "sidebar_group_ax_selection_contract_missing",
        "Group headings must be represented as source-list groups and excluded from selection.",
        failures,
    )
    require(
        "scrollRowToVisible" in content
        and "viewportDidChange" in content,
        "sidebar_selection_visibility_missing",
        "External routes and sidebar resize must keep the selected route visible.",
        failures,
    )


def check_routes(app_section: str, content: str, settings_combined: str, shell: str, failures: list[dict[str, str]]) -> None:
    for case in ["case agentCLI", "case hooks", "case dataAudit"]:
        require(case in app_section, "app_section_route_missing", case, failures)

    require(
        "SettingsShellView(mode: appModel.selectedSection.settingsViewMode)" in content,
        "content_route_missing",
        "central SettingsShellView route",
        failures,
    )
    require(
        "case .settings:" in app_section
        and 'L10n.string("settings.general.title")' in app_section,
        "settings_general_sidebar_title_missing",
        "The internal settings route must be presented as General in the sidebar.",
        failures,
    )
    for route in ["case .agentCLI:", "case .hooks:", "case .dataAudit:"]:
        require(route in content, "content_route_missing", route, failures)

    require("SettingsView(mode:" not in content, "legacy_settings_wrapper_active", "ContentView must route directly to SettingsShellView", failures)
    for mode in ["case agentCLI", "case hooks", "case dataAudit"]:
        require(mode in settings_combined, "settings_mode_missing", mode, failures)

    require("settings.backToClipboard" in shell, "clipboard_privacy_back_action_missing", "clipboard privacy back action", failures)
    require("appModel.selectedSection = .clipboardSettings" in shell, "clipboard_privacy_back_target_missing", "clipboard privacy back target", failures)
    require(".navigationTitle(mode.title)" in shell, "native_settings_title_missing", "native navigation title", failures)
    require("case .agentCLI:" in shell and "AgentCLISettingsPane(" in shell, "agent_cli_pane_mapping_missing", "Agent CLI pane route", failures)
    require("case .hooks:" in shell and "HooksSettingsPane()" in shell, "hooks_pane_mapping_missing", "Hooks pane route", failures)
    require("case .dataAudit:" in shell and "DataAuditSettingsPane()" in shell, "data_audit_pane_mapping_missing", "Data Audit pane route", failures)


def check_section_surface(section_list: str, failures: list[dict[str, str]]) -> None:
    require("SettingsTableSection" not in section_list, "legacy_settings_table_section_present", "SettingsTableSection must not coexist with the single settings section contract.", failures)
    match = re.search(r"struct SettingsSection<Content: View, HeaderActions: View>: View \{(.*?)\n\}\n\nextension SettingsSection", section_list, re.S)
    require(match is not None, "settings_section_body_missing", "SettingsSection body", failures)
    section_body = match.group(1) if match else ""
    require(len(re.findall(r"\bstruct SettingsSectionHeader\b", section_list)) == 1, "settings_section_header_not_unique", "Exactly one SettingsSectionHeader component is required.", failures)
    require(len(re.findall(r"\bstruct SettingsSection<", section_list)) == 1, "settings_section_not_unique", "Exactly one SettingsSection component is required.", failures)
    require(len(re.findall(r"\bstruct SettingsRowShell<", section_list)) == 1, "settings_row_shell_not_unique", "Exactly one SettingsRowShell component is required.", failures)
    require(".glassSurface" not in section_body, "settings_section_glass_surface_regression", "Settings shell section wrapper should not become card-in-card glass", failures)
    require(
        ".blocksSurface(.section)" in section_body,
        "settings_section_fill_missing",
        "SettingsSection must own the shared .section surface.",
        failures,
    )


def check_localization(failures: list[dict[str, str]]) -> None:
    data = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    strings = data.get("strings", {})
    missing = []
    for key in REQUIRED_KEYS:
        item = strings.get(key)
        if not item:
            missing.append(key)
            continue
        localizations = item.get("localizations", {})
        for locale in ["zh-Hans", "en", "ja"]:
            value = localizations.get(locale, {}).get("stringUnit", {}).get("value", "")
            if not value:
                missing.append(f"{key}:{locale}")
    require(not missing, "missing_localization", ", ".join(missing), failures)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.parse_args()

    failures: list[dict[str, str]] = []
    checked = [APP_SECTION, CONTENT_VIEW, LOCALIZABLE, STEP4C_PRD, STEP4C_RECORD]
    checked.extend(SETTINGS_DIR / name for name in REQUIRED_SETTINGS_FILES)

    app_section = read(APP_SECTION, failures)
    content = read(CONTENT_VIEW, failures)
    shell = read(SETTINGS_DIR / "SettingsShellView.swift", failures)
    section_list = read(SETTINGS_DIR / "SettingsSectionList.swift", failures)
    settings_combined = "\n".join(read(SETTINGS_DIR / name, failures) for name in REQUIRED_SETTINGS_FILES)

    check_sidebar(content, failures)
    check_routes(app_section, content, settings_combined, shell, failures)
    check_section_surface(section_list, failures)
    check_localization(failures)

    print(json.dumps({
        "ok": not failures,
        "suite": "p8g_settings_shell_redesign_checks",
        "failures": failures,
        "observations": {
            "checked_files": [rel(path) for path in checked],
            "current_evidence": {
                "prd": rel(STEP4C_PRD),
                "development_record": rel(STEP4C_RECORD),
                "settings_shell": rel(SETTINGS_DIR / "SettingsShellView.swift"),
            },
            "baseline_reference": {
                "legacy_sources_used_for_ok": False,
                "note": "Blocking checks use current Step 4C settings shell and pane files.",
            },
        },
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
