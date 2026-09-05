#!/usr/bin/env python3
"""Fail-closed P7-D checks for current Settings routes and Source List UI."""

from __future__ import annotations

import json
import re
from pathlib import Path

from current_architecture_gate_helpers import swift_code_only, swift_declaration_block


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CONTENT = APP / "Views" / "ContentView.swift"
SHELL = APP / "Features" / "Settings" / "SettingsShellView.swift"
SECTION_LIST = APP / "Features" / "Settings" / "SettingsSectionList.swift"
BLOCKS_APP = APP / "App" / "BlocksApp.swift"
APP_MODEL = APP / "App" / "AppModel.swift"
SETTINGS_VIEW = APP / "Views" / "SettingsView.swift"

EXPECTED_ROUTES = {
    ".general": "GeneralSettingsPane()",
    ".screenshot": "ScreenshotSettingsPane()",
    ".clipboard": "ClipboardSettingsPane(showPrivacySection: false)",
    ".clipboardPrivacy": "PrivacySettingsPane()",
    ".translation": "TranslationSettingsPane()",
    ".translationFavorites": "EmptyView()",
    ".shortcuts": "ShortcutSettingsPane()",
    ".providers": "ProviderSettingsPane()",
    ".agentCLI": "AgentCLISettingsPane()",
    ".hooks": "EmptyView()",
    ".dataAudit": "DataAuditSettingsPane()",
    ".permissions": "PermissionSettingsPane()",
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def route_contract(shell: str) -> dict[str, bool]:
    routes = swift_declaration_block(shell, "private var settingsRoutesContent: some View")
    code = swift_code_only(routes)
    result: dict[str, bool] = {}
    for case, pane in EXPECTED_ROUTES.items():
        match = re.search(rf"case {re.escape(case)}:\s*(.*?)(?=\s*case \.|\s*\}})", code, re.DOTALL)
        result[f"{case}_maps_exactly"] = match is not None and " ".join(match.group(1).split()) == pane
    declared_cases = set(re.findall(r"\bcase\s+(\.[A-Za-z][A-Za-z0-9]*)\s*:", code))
    result["route_set_is_exact"] = declared_cases == set(EXPECTED_ROUTES)
    result["legacy_privacy_mapping_absent"] = "ClipboardSettingsPane(showPrivacySection: true)" not in code
    return result


def main() -> int:
    failures: list[dict[str, str]] = []
    required = [CONTENT, SHELL, SECTION_LIST, BLOCKS_APP, APP_MODEL]
    for path in required:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})

    content, shell, section_list, blocks_app, app_model = map(read, required)
    content_code = swift_code_only(content)
    app_model_code = swift_code_only(app_model)
    routes = route_contract(shell)
    checks = {
        "retired_settings_view_absent": not SETTINGS_VIEW.exists(),
        "main_window_reuses_navigation_shell": "SettingsNavigationShell(initialSection: initialSection)" in content_code,
        "source_list_sidebar": all(
            token in content_code
            for token in ["SettingsSourceListBridge(", "NSOutlineViewDataSource", "NSOutlineViewDelegate"]
        ),
        "group_rows_not_selectable": all(
            token in content_code
            for token in ["isGroupItem item:", "shouldSelectItem item:", "item is SettingsSidebarRouteNode"]
        ),
        "brand_is_above_source_list": "SettingsSidebarBrandHeader()" in swift_declaration_block(
            content, "private struct SettingsNativeSidebar: View"
        ),
        "command_routes_to_main_window": "appModel.openMainWindow(section: .settings)" in swift_code_only(blocks_app),
        "main_window_opener_exists": "func openMainWindow(section: AppSection)" in app_model_code,
        "settings_modes_are_current": all(
            token in swift_code_only(section_list)
            for token in [f"case {case.removeprefix('.')}" for case in EXPECTED_ROUTES]
        ),
        "route_contract": all(routes.values()),
        "retired_sidebar_views_absent": all(token not in content for token in ["SidebarSectionButton", "SidebarIconBadge"]),
    }
    for name, ok in checks.items():
        if not ok:
            failures.append({"code": "contract_missing", "detail": name})

    mutations = {
        "rejects_extra_clipboard_pane": not route_contract(shell.replace(
            "case .clipboard:\n            ClipboardSettingsPane(showPrivacySection: false)",
            "case .clipboard:\n            ClipboardSettingsPane(showPrivacySection: false)\n            ProviderSettingsPane()", 1,
        ))[".clipboard_maps_exactly"],
        "rejects_missing_final_route": not route_contract(shell.replace(
            "case .permissions:\n            PermissionSettingsPane()",
            "", 1,
        ))["route_set_is_exact"],
        "rejects_selectable_group": "item is SettingsSidebarRouteNode" not in swift_code_only(content.replace(
            "item is SettingsSidebarRouteNode", "item is SettingsSidebarGroupNode", 1,
        )),
        "rejects_removed_main_window_command": "appModel.openMainWindow(section: .settings)" not in swift_code_only(blocks_app.replace(
            "appModel.openMainWindow(section: .settings)", "appModel.showSettingsSection()", 1,
        )),
    }
    if not all(mutations.values()):
        failures.append({"code": "mutation_bypass", "detail": ", ".join(k for k, v in mutations.items() if not v)})

    print(json.dumps({
        "ok": not failures,
        "suite": "p7d_settings_routes_sidebar_visual_checks",
        "checked_files": [rel(path) for path in [*required, SETTINGS_VIEW]],
        "route_contract": routes,
        "mutation_adversaries_fail_closed": mutations,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
