#!/usr/bin/env python3
"""Fail-closed P7-B checks for the single-window Settings sidebar."""

from __future__ import annotations

import json
from pathlib import Path

from current_architecture_gate_helpers import swift_code_only, swift_declaration_block


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
BLOCKS_APP = APP / "App" / "BlocksApp.swift"
CONTENT = APP / "Views" / "ContentView.swift"
SHELL = APP / "Features" / "Settings" / "SettingsShellView.swift"
SECTION_LIST = APP / "Features" / "Settings" / "SettingsSectionList.swift"
SETTINGS_VIEW = APP / "Views" / "SettingsView.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def sidebar_contract(content: str) -> dict[str, bool]:
    native_view = swift_declaration_block(content, "final class SettingsSourceListNativeView: NSView")
    controller = swift_declaration_block(content, "private final class SettingsSourceListDataController: NSObject")
    clip_view = swift_declaration_block(content, "final class SettingsVerticalOnlyClipView: NSClipView")
    return {
        "source_list_bridge": "SettingsSourceListBridge(" in swift_code_only(content),
        "brand_above_source_list": "SettingsSidebarBrandHeader()" in swift_declaration_block(
            content, "private struct SettingsNativeSidebar: View"
        ),
        "group_rows_are_not_selectable": all(
            token in swift_code_only(controller)
            for token in ["isGroupItem item:", "shouldSelectItem item:", "item is SettingsSidebarRouteNode"]
        ),
        "group_headings_do_not_float": "outlineView.floatsGroupRows = false" in swift_code_only(native_view),
        "vertical_only_scrolling": all(
            token in swift_code_only(native_view + clip_view)
            for token in [
                "scrollView.hasHorizontalScroller = false",
                "scrollView.horizontalScrollElasticity = .none",
                "scrollView.contentView = SettingsVerticalOnlyClipView()",
                "constrained.origin.x = 0",
            ]
        ),
        "vertical_indicator_hidden": "scrollView.hasVerticalScroller = false" in swift_code_only(native_view),
        "selection_visibility_is_maintained": all(
            token in swift_code_only(native_view)
            for token in ["scrollRowToVisible", "viewportDidChange", "scheduleSelectionVisibility"]
        ),
    }


def main() -> int:
    failures: list[dict[str, str]] = []
    required = [BLOCKS_APP, CONTENT, SHELL, SECTION_LIST]
    for path in required:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})

    blocks_app, content, shell, section_list = map(read, required)
    code = swift_code_only(content)
    contracts = sidebar_contract(content)
    shell_code = swift_code_only(shell)
    section_code = swift_code_only(section_list)

    checks = {
        "retired_settings_scene_absent": not SETTINGS_VIEW.exists() and "Settings {" not in swift_code_only(blocks_app),
        "single_main_window_uses_content_shell": (
            'Window(L10n.string("app.name"), id: "main")' in blocks_app
            and "ContentView(" in blocks_app
            and "SettingsNavigationShell(initialSection: initialSection)" in code
        ),
        "native_split_view": "NavigationSplitView" in code
        and ".navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 248)" in content,
        "sidebar_contract": all(contracts.values()),
        "detail_uses_current_shell": "SettingsShellView(mode: appModel.selectedSection.settingsViewMode)" in code,
        "detail_is_top_anchored": ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)" in shell_code,
        "current_settings_components": all(
            token in section_code
            for token in ["struct SettingsSection<", "struct SettingsRowShell<", "struct SettingsValueColumn<", ".blocksSurface(.section)"]
        ),
        "retired_components_absent": all(
            token not in content + shell + section_list
            for token in ["SettingsTableSection", ".settingsSection", "SidebarIconBadge", ".padding(.top, 42)"]
        ),
    }
    for name, ok in checks.items():
        if not ok:
            failures.append({"code": "contract_missing", "detail": name})

    mutations = {
        "rejects_floating_group_headings": not sidebar_contract(
            content.replace("outlineView.floatsGroupRows = false", "outlineView.floatsGroupRows = true", 1)
        )["group_headings_do_not_float"],
        "rejects_horizontal_elasticity": not sidebar_contract(
            content.replace("scrollView.horizontalScrollElasticity = .none", "scrollView.horizontalScrollElasticity = .automatic", 1)
        )["vertical_only_scrolling"],
        "rejects_removed_shared_value_column": "struct SettingsValueColumn<" not in swift_code_only(
            section_list.replace("struct SettingsValueColumn<", "struct RetiredSettingsValueColumn<", 1)
        ),
    }
    if not all(mutations.values()):
        failures.append({"code": "mutation_bypass", "detail": ", ".join(k for k, v in mutations.items() if not v)})

    print(json.dumps({
        "ok": not failures,
        "suite": "p7b_settings_sidebar_stability_checks",
        "checked_files": [rel(path) for path in [*required, SETTINGS_VIEW]],
        "contracts": contracts,
        "mutation_adversaries_fail_closed": mutations,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
