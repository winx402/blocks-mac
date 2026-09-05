#!/usr/bin/env python3
"""Fail-closed P7-E checks for Settings scrolling and layout contracts."""

from __future__ import annotations

import json
from pathlib import Path

from current_architecture_gate_helpers import swift_code_only, swift_declaration_block


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CONTENT = APP / "Views" / "ContentView.swift"
SHELL = APP / "Features" / "Settings" / "SettingsShellView.swift"
SECTION_LIST = APP / "Features" / "Settings" / "SettingsSectionList.swift"
SCREENSHOT_PANE = APP / "Features" / "Screenshot" / "Settings" / "ScreenshotSettingsPane.swift"
CLIPBOARD_PANE = APP / "Features" / "Settings" / "ClipboardSettingsPane.swift"
TRANSLATION_PANE = APP / "Features" / "Settings" / "TranslationSettingsPane.swift"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def scroll_contract(content: str, shell: str) -> dict[str, bool]:
    source_list = swift_declaration_block(content, "final class SettingsSourceListNativeView: NSView")
    clip_view = swift_declaration_block(content, "final class SettingsVerticalOnlyClipView: NSClipView")
    source_code = swift_code_only(source_list + clip_view)
    shell_code = swift_code_only(shell)
    return {
        "sidebar_vertical_scroll_is_available": all(
            token in source_code for token in ["scrollView.documentView = outlineView", "scrollView.contentView = SettingsVerticalOnlyClipView()"]
        ),
        "sidebar_vertical_indicators_hidden": "scrollView.hasVerticalScroller = false" in source_code,
        "sidebar_horizontal_scroll_and_elasticity_off": all(
            token in source_code
            for token in ["scrollView.hasHorizontalScroller = false", "scrollView.horizontalScrollElasticity = .none", "constrained.origin.x = 0"]
        ),
        "sidebar_group_headings_not_floating": "outlineView.floatsGroupRows = false" in source_code,
        "detail_vertical_scroll_is_available": "ScrollView {" in shell_code,
        "detail_indicators_hidden": ".scrollIndicators(.hidden)" in shell_code,
        "detail_width_is_profile_bounded": "maxWidth: mode.layoutProfile.maximumWidth" in shell_code,
        "detail_padding_uses_tokens": "BlocksVisualTokens.Layout.settingsPageHorizontalPadding" in shell_code,
    }


def secondary_route_contract(
    shell: str,
    screenshot: str,
    clipboard: str,
    translation: str,
) -> dict[str, bool]:
    shell_code = swift_code_only(shell)
    screenshot_code = swift_code_only(screenshot)
    clipboard_code = swift_code_only(clipboard)
    translation_code = swift_code_only(translation)
    return {
        "shell_keys_scroll_by_secondary_route": all(
            token in shell_code
            for token in ["secondaryRouteTokens[mode]", "scrollRestorationID(for: mode)"]
        ),
        "screenshot_uses_shared_secondary_route": all(
            token in screenshot_code
            for token in ["secondaryRouteBinding", "for: .screenshot", "routeToken.wrappedValue"]
        ),
        "clipboard_uses_shared_secondary_route": all(
            token in clipboard_code
            for token in ["secondaryRouteBinding", "for: .clipboard", "routeToken.wrappedValue"]
        ),
        "translation_uses_shared_secondary_route": all(
            token in translation_code
            for token in [
                "secondaryRouteBinding", "for: .translation", "routeToken.wrappedValue",
                "newValue == .overview", "newValue.rawValue",
            ]
        ),
        "stable_route_tokens_are_declared": all(
            token in screenshot
            for token in ['rootRouteToken = "root"', 'watermarkRouteToken = "watermarks"']
        ) and all(
            token in clipboard
            for token in ['rootRouteToken = "root"', 'tagManagementRouteToken = "tags"']
        ),
        "retired_scene_route_state_is_absent": all(
            token not in screenshot + clipboard + translation
            for token in [
                'settings.screenshot.watermarkLibrary',
                'settings.clipboard.tagManagement")',
                'settings.translation.route',
                "routeRawValue",
            ]
        ),
    }


def main() -> int:
    failures: list[dict[str, str]] = []
    required = [
        CONTENT, SHELL, SECTION_LIST, SCREENSHOT_PANE, CLIPBOARD_PANE,
        TRANSLATION_PANE,
    ]
    for path in required:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})
    content, shell, section_list, screenshot, clipboard, translation = map(read, required)
    contracts = scroll_contract(content, shell)
    secondary_routes = secondary_route_contract(
        shell, screenshot, clipboard, translation,
    )
    checks = {
        "scroll_contract": all(contracts.values()),
        "secondary_route_contract": all(secondary_routes.values()),
        "current_shared_components": all(
            token in swift_code_only(section_list)
            for token in ["struct SettingsSection<", "struct SettingsRowShell<", "struct SettingsValueColumn<", ".blocksSurface(.section)"]
        ),
        "retired_visual_literals_absent": all(
            token not in content + shell + section_list
            for token in ["SidebarIconBadge", "SettingsTableSection", ".settingsSection", ".padding(.top, 42)", ".safeAreaInset(edge: .top", ".id(section)"]
        ),
    }
    for name, ok in checks.items():
        if not ok:
            failures.append({"code": "contract_missing", "detail": name})

    mutations = {
        "rejects_visible_vertical_indicator": not scroll_contract(content.replace(
            "scrollView.hasVerticalScroller = false", "scrollView.hasVerticalScroller = true", 1,
        ), shell)["sidebar_vertical_indicators_hidden"],
        "rejects_horizontal_elasticity": not scroll_contract(content.replace(
            "scrollView.horizontalScrollElasticity = .none", "scrollView.horizontalScrollElasticity = .automatic", 1,
        ), shell)["sidebar_horizontal_scroll_and_elasticity_off"],
        "rejects_floating_group_headings": not scroll_contract(content.replace(
            "outlineView.floatsGroupRows = false", "outlineView.floatsGroupRows = true", 1,
        ), shell)["sidebar_group_headings_not_floating"],
        "rejects_unbounded_detail_width": not scroll_contract(content, shell.replace(
            "maxWidth: mode.layoutProfile.maximumWidth", "maxWidth: .infinity", 1,
        ))["detail_width_is_profile_bounded"],
        "rejects_screenshot_private_route_state": not secondary_route_contract(
            shell,
            screenshot.replace(
                "routeStateStore.secondaryRouteBinding",
                "Binding.constant",
                1,
            ),
            clipboard,
            translation,
        )["screenshot_uses_shared_secondary_route"],
        "rejects_clipboard_private_route_state": not secondary_route_contract(
            shell,
            screenshot,
            clipboard.replace(
                "routeStateStore.secondaryRouteBinding",
                "Binding.constant",
                1,
            ),
            translation,
        )["clipboard_uses_shared_secondary_route"],
        "rejects_translation_private_route_state": not secondary_route_contract(
            shell,
            screenshot,
            clipboard,
            translation.replace(
                "routeStateStore.secondaryRouteBinding",
                "Binding.constant",
                1,
            ),
        )["translation_uses_shared_secondary_route"],
    }
    if not all(mutations.values()):
        failures.append({"code": "mutation_bypass", "detail": ", ".join(k for k, v in mutations.items() if not v)})

    print(json.dumps({
        "ok": not failures,
        "suite": "p7e_settings_visual_scroll_checks",
        "checked_files": [rel(path) for path in required],
        "scroll_contract": contracts,
        "secondary_route_contract": secondary_routes,
        "mutation_adversaries_fail_closed": mutations,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
