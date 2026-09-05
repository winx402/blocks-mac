#!/usr/bin/env python3
"""P7-M unified translation settings and favorites product checks."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TRANSLATION_PANEL = ROOT / "apps/Blocks/BlocksApp/Views/TranslationFloatingPanelView.swift"
SETTINGS_SHELL = ROOT / "apps/Blocks/BlocksApp/Features/Settings/SettingsShellView.swift"
TRANSLATION_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/TranslationSettingsPane.swift"
HOOKS_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/HooksSettingsPane.swift"
TRANSLATION_SOURCE_MANAGEMENT = ROOT / "apps/Blocks/BlocksApp/Features/Translation/Integration/TranslationSourceManagementService.swift"
TRANSLATION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift"
COMMUNITY_SOURCES = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationCommunityWebAdapters.swift"
FAVORITES = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationFavoritesPane.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationFeatureCoordinator.swift"
CLIPBOARD = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift"
CLIPBOARD_COPY_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator+CopyActions.swift"
CONTENT = ROOT / "apps/Blocks/BlocksApp/Views/ContentView.swift"
LEGACY_HOME = ROOT / "apps/Blocks/BlocksApp/Views/TranslationHomeView.swift"
PANEL_COMPONENTS = ROOT / "apps/Blocks/BlocksApp/Features/Translation/Panel/TranslationFloatingPanelComponents.swift"
CATALOGS = [
    ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings",
    ROOT / "apps/Blocks/BlocksApp/Features/Translation/Resources/TranslationLocalizable.xcstrings",
]
LANGUAGES = ["zh-Hans", "en", "ja"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def merged_strings() -> dict[str, object]:
    result: dict[str, object] = {}
    for catalog in CATALOGS:
        if catalog.exists():
            result.update(json.loads(read(catalog)).get("strings", {}))
    return result


def main() -> int:
    panel = read(TRANSLATION_PANEL)
    panel_components = read(PANEL_COMPONENTS)
    panel_sources = "\n".join([panel, panel_components])
    settings_shell = read(SETTINGS_SHELL)
    translation_settings = read(TRANSLATION_SETTINGS)
    hooks_settings = read(HOOKS_SETTINGS)
    translation_source_management = read(TRANSLATION_SOURCE_MANAGEMENT)
    store = read(TRANSLATION_STORE)
    community_sources = read(COMMUNITY_SOURCES)
    favorites = read(FAVORITES)
    app_model = read(APP_MODEL)
    coordinator = read(COORDINATOR)
    clipboard = "\n".join([read(CLIPBOARD), read(CLIPBOARD_COPY_ACTIONS)])
    content = read(CONTENT)
    visible_sources = "\n".join(
        [panel, settings_shell, translation_settings, favorites, content]
    )
    strings = merged_strings()
    forbidden_visible_terms = ["P3-B", "P5-", "P7-"]

    required_localization = [
        "translation.panel.diagnostics",
        "translation.services.title",
        "translation.ocr.defaultService",
        "translation.plugin.title",
        "translation.favorite.title",
        "translation.favorite.exportMarkdown",
        "translation.favorite.exportJSON",
        "translation.favorite.retranslate",
        "settings.shortcuts.detail",
        "settings.providers.detail",
        "settings.translation.detail",
    ]
    localized = True
    for key in required_localization:
        entry = strings.get(key)
        localized = localized and entry is not None and all(
            language in (entry or {}).get("localizations", {})
            for language in LANGUAGES
        )

    checks = {
        "translation_diagnostics_collapsed": (
            "@State private var diagnosticsExpanded = false" in panel_sources
            and "if hasDiagnostics && diagnosticsExpanded" in panel_sources
            and "diagnosticsExpanded.toggle()" in panel_sources
            and "translation.panel.diagnostics" in panel_sources
        ),
        "stable_multi_service_results": (
            "Array(resultStates.enumerated())" in panel
            and "TranslationPanelResultStateReader(" in panel
            and "TranslationResultCard(" in panel
            and "maximumCount: 4" in store
        ),
        "settings_routes_are_product_categories": (
            "SettingsShellView(mode:" in content
            and "case .translation:" in settings_shell
            and "case .translationFavorites:" in settings_shell
            and "case .providers:" in settings_shell
            and "case .shortcuts:" in settings_shell
        ),
        "translation_settings_cover_services_ocr_and_plugins": all(
            symbol in "\n".join(
                [translation_settings, hooks_settings, translation_source_management]
            )
            for symbol in [
                "translation.services.title",
                "translation.services.enabledCount",
                "TranslationServiceSettingsSnapshot",
                "translation.services.group.enabled",
                "translation.services.group.free",
                "translation.services.group.requiresConfiguration",
                "SettingsBooleanSwitch",
                "translation.services.configureFirst",
                "TranslationServiceEnablementPolicy",
                "translation.ocr.defaultService",
                "translation.plugin.title",
                "translation.settings.plugins.manage",
                "appModel.openMainWindow(section: .hooks)",
                "func preparePluginInstallation(",
                "testSource(",
                "uninstallPlugin(",
            ]
        ),
        "translation_service_catalog_order_is_stable": (
            "private var catalogServices" in translation_settings
            and "translationStore.availableServices" in translation_settings
            and "private var enabledServicesInResultOrder" in translation_settings
            and "TranslationServiceSettingsSnapshot(" in translation_settings
            and "TranslationServiceOrderDragSource(" in translation_settings
            and "beginDraggingSession(" in panel_sources
            and "performDragOperation(" in panel_sources
            and "TranslationServiceOrderDragCoordinator()" in translation_settings
            and "moveEnabledSource(" in translation_settings
            and ".onDrop(" not in translation_settings
            and ".draggable(" not in translation_settings
            and ".dropDestination(" not in translation_settings
            and "let enabled = translationStore.enabledServiceIDs.compactMap" not in translation_settings
        ),
        "translation_native_drag_session_uses_appkit_lifecycle": (
            "mouseDown(with event:" in panel_sources
            and "mouseDragged(with event:" in panel_sources
            and "hypot(" in panel_sources
            and "beginDraggingSession(" in panel_sources
            and "draggingUpdated(" in panel_sources
            and "performDragOperation(" in panel_sources
            and "TranslationServiceOrderDragPayload.decode(" in panel_sources
            and "from: sender.draggingPasteboard" in panel_sources
            and "TranslationServiceOrderDragCoordinator" in panel_sources
            and (
                "dragCoordinator.commit(" in panel_sources
                or "dragCoordinator?.commit(" in panel_sources
            )
            and "DropDelegate" not in panel_sources
        ),
        "translation_copy_uses_clipboard_history_pipeline": (
            "ClipboardExplicitTextCopyOutcome" in coordinator
            and "source: .translationResult" in app_model
            and "func copyExplicitText(" in clipboard
            and "ClipboardExplicitTextSnapshotFactory.make(" in clipboard
            and "clipboardStore.commitCopyEvent(" in clipboard
        ),
        "community_sources_have_explicit_connection_test": (
            "func testCommunityService(" in store
            and "serviceID: String" in store
            and "translation.community.connectionTest" in translation_settings
            and "communityServiceTestingIDs" in translation_settings
        ),
        "community_web_sources_are_explicit_and_opt_in": (
            "case myMemory" in community_sources
            and "case googleWeb" in community_sources
            and "case tencentWeb" in community_sources
            and "static let productionAvailable" in community_sources
            and ".myMemory" in community_sources
            and ".googleWeb" in community_sources
            and ".tencentWeb" in community_sources
            and "case deepLWeb" in community_sources
            and "TranslationCommunityWebDisclosureStore" in translation_settings
            and "service.kind == .communityWeb" in translation_settings
        ),
        "favorites_page_supports_export_and_retranslate": all(
            symbol in favorites
            for symbol in [
                "translationStore.exportFavoritesMarkdown()",
                "translationStore.exportFavoritesJSON()",
                "action: retranslate",
                "onRetranslate(favorite)",
            ]
        ),
        "favorite_retranslation_routes_to_session_coordinator": (
            "TranslationFavoritesPane { favorite in" in settings_shell
            and "appModel.showTranslationFavorite(favorite)" in settings_shell
            and "translationCoordinator.reopenFavorite(favorite)" in app_model
            and "func reopenFavorite(_ favorite: TranslationFavorite)" in coordinator
        ),
        "localization": localized,
        "legacy_single_result_ui_removed": (
            not LEGACY_HOME.exists()
            and "TranslationRuntimeResultView" not in panel_sources
        ),
        "no_engineering_stage_copy_in_core_views": not any(
            term in visible_sources for term in forbidden_visible_terms
        ),
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7m_translation_settings_productization_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
