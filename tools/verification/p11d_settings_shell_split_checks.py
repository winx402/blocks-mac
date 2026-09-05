#!/usr/bin/env python3
"""Fail-closed P11-D checks for the single-window Settings architecture."""

from __future__ import annotations

import json
import re
from pathlib import Path

from current_architecture_gate_helpers import swift_code_only, swift_declaration_block


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
BLOCKS_APP = APP / "App" / "BlocksApp.swift"
APP_MODEL = APP / "App" / "AppModel.swift"
CONTENT = APP / "Views" / "ContentView.swift"
SHELL = APP / "Features" / "Settings" / "SettingsShellView.swift"
SECTION_LIST = APP / "Features" / "Settings" / "SettingsSectionList.swift"
SETTINGS_VIEW = APP / "Views" / "SettingsView.swift"
PANE_FILES = [
    APP / "Features" / "Settings" / name
    for name in [
        "GeneralSettingsPane.swift", "ClipboardSettingsPane.swift", "ShortcutSettingsPane.swift",
        "PermissionSettingsPane.swift", "ProviderSettingsPane.swift", "TranslationSettingsPane.swift",
        "AgentCLISettingsPane.swift", "HooksSettingsPane.swift", "DataAuditSettingsPane.swift",
        "ClipboardTagManagementSection.swift",
    ]
]
PRIVACY_PANE = APP / "Features" / "Privacy" / "PrivacySettingsPane.swift"
SCREENSHOT_PANE = APP / "Features" / "Screenshot" / "Settings" / "ScreenshotSettingsPane.swift"
TRANSLATION_FAVORITES_PANE = APP / "Features" / "Translation" / "TranslationFavoritesPane.swift"

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


def window_scene_count(source: str) -> int:
    return len(re.findall(r"^\s*Window\s*\(", swift_code_only(source), re.MULTILINE))


def route_contract(shell: str) -> dict[str, bool]:
    routes = swift_declaration_block(shell, "private var settingsRoutesContent: some View")
    code = swift_code_only(routes)
    checks: dict[str, bool] = {}
    for case, pane in EXPECTED_ROUTES.items():
        match = re.search(rf"case {re.escape(case)}:\s*(.*?)(?=\s*case \.|\s*\}})", code, re.DOTALL)
        checks[f"{case}_exact_pane"] = match is not None and " ".join(match.group(1).split()) == pane
    declared_cases = set(re.findall(r"\bcase\s+(\.[A-Za-z][A-Za-z0-9]*)\s*:", code))
    checks["route_set_is_exact"] = declared_cases == set(EXPECTED_ROUTES)
    checks["removed_compatibility_mapping_absent"] = "ClipboardSettingsPane(showPrivacySection: true)" not in code
    return checks


def direct_sensitive_api_hits(paths: list[Path], sources: list[str]) -> dict[str, list[str]]:
    """Inspect executable Swift only; literals/comments cannot become pane API hits."""
    patterns = {
        "url_session": r"\bURLSession\s*(?:\.shared|\()",
        "keychain": r"\bSecItem(?:Add|CopyMatching|Update|Delete)\s*\(",
        "pasteboard": r"\bNSPasteboard\s*\.\s*general\b",
        "provider_secret_call": r"\breadUserSecretForProviderCall\s*\(",
        "clipboard_runtime": r"\bClipboardRecorderRuntimeService\s*\(",
        "login_item_helper": r"\bBlocksLoginItemHelper\s*\(",
    }
    hits: dict[str, list[str]] = {}
    for path, source in zip(paths, sources, strict=True):
        code = swift_code_only(source)
        found = [name for name, pattern in patterns.items() if re.search(pattern, code)]
        if found:
            hits[rel(path)] = found
    return hits


def main() -> int:
    failures: list[dict[str, str]] = []
    pane_paths = [*PANE_FILES, PRIVACY_PANE, SCREENSHOT_PANE, TRANSLATION_FAVORITES_PANE]
    required = [BLOCKS_APP, APP_MODEL, CONTENT, SHELL, SECTION_LIST, *pane_paths]
    for path in required:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})
    blocks_app, app_model, content, shell, section_list = map(read, required[:5])
    pane_sources = [read(path) for path in pane_paths]
    app_code = swift_code_only(blocks_app)
    content_code = swift_code_only(content)
    app_model_code = swift_code_only(app_model)
    routes = route_contract(shell)
    sensitive_hits = direct_sensitive_api_hits(pane_paths, pane_sources)
    checks = {
        "settings_view_removed": not SETTINGS_VIEW.exists(),
        "only_main_window_scene": window_scene_count(blocks_app) == 1 and 'id: "main"' in blocks_app and "Settings {" not in app_code,
        "main_window_contains_content_view": "ContentView(" in app_code,
        "content_uses_shared_navigation_shell": "SettingsNavigationShell(initialSection: initialSection)" in content_code,
        "split_shell_owns_sidebar_and_detail": all(
            token in content_code
            for token in ["NavigationSplitView", "SettingsNativeSidebar(", "SettingsShellView(mode: appModel.selectedSection.settingsViewMode)"]
        ),
        "settings_command_opens_main_window": "appModel.openMainWindow(section: .settings)" in app_code,
        "app_model_main_opener_is_real": all(
            token in swift_code_only(swift_declaration_block(app_model, "func openMainWindow(section: AppSection)"))
            for token in ["selectedSection = section", "mainWindowNavigationGeneration", "mainWindowOpener?()"]
        ),
        "current_settings_components": all(
            token in swift_code_only(section_list)
            for token in ["struct SettingsSection<", "struct SettingsRowShell<", "struct SettingsValueColumn<", ".blocksSurface(.section)"]
        ),
        "route_contract": all(routes.values()),
        "pane_code_has_no_direct_sensitive_apis": not sensitive_hits,
        "retired_shell_mechanisms_absent": all(
            token not in content + shell + section_list
            for token in ["SettingsView(", "SettingsTableSection", ".settingsSection", "SidebarIconBadge", ".safeAreaInset(edge: .top", ".id(section)"]
        ),
    }
    for name, ok in checks.items():
        if not ok:
            failures.append({"code": "contract_missing", "detail": name})
    if sensitive_hits:
        failures.append({"code": "settings_pane_direct_sensitive_api", "detail": json.dumps(sensitive_hits, ensure_ascii=False)})

    mutations = {
        "rejects_extra_clipboard_pane": not route_contract(shell.replace(
            "case .clipboard:\n            ClipboardSettingsPane(showPrivacySection: false)",
            "case .clipboard:\n            ClipboardSettingsPane(showPrivacySection: false)\n            ProviderSettingsPane()", 1,
        ))[".clipboard_exact_pane"],
        "rejects_missing_final_route": not route_contract(shell.replace(
            "case .permissions:\n            PermissionSettingsPane()",
            "", 1,
        ))["route_set_is_exact"],
        "rejects_second_settings_scene": not (
            window_scene_count(blocks_app + "\nSettings { EmptyView() }") == 1
            and "Settings {" not in swift_code_only(blocks_app + "\nSettings { EmptyView() }")
        ),
        "ignores_authorization_string_but_rejects_api": (
            not direct_sensitive_api_hits([PANE_FILES[0]], ['let label = "Authorization" // Authorization'])
            and bool(direct_sensitive_api_hits([PANE_FILES[0]], ["let request = URLSession.shared.dataTask(with: url)"]))
        ),
        "rejects_removed_main_opener": "mainWindowOpener?()" not in swift_code_only(
            swift_declaration_block(app_model.replace("mainWindowOpener?()", "", 1), "func openMainWindow(section: AppSection)")
        ),
    }
    if not all(mutations.values()):
        failures.append({"code": "mutation_bypass", "detail": ", ".join(k for k, v in mutations.items() if not v)})

    print(json.dumps({
        "ok": not failures,
        "gate": "P11D",
        "checked_files": [rel(path) for path in [*required, SETTINGS_VIEW]],
        "route_contract": routes,
        "sensitive_api_hits": sensitive_hits,
        "mutation_adversaries_fail_closed": mutations,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
