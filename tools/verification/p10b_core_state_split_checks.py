#!/usr/bin/env python3
"""P10-B core state split checks for ProviderStore / TranslationStore."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
APP_MODEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "App" / "AppModel.swift"
APP_MODEL_DELEGATION = ROOT / "apps" / "Blocks" / "BlocksApp" / "App" / "AppModel+FeatureDelegation.swift"
PROVIDER_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Provider" / "ProviderStore.swift"
TRANSLATION_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Translation" / "TranslationStore.swift"
PROVIDER_COORDINATOR = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Provider" / "ProviderFeatureCoordinator.swift"
TRANSLATION_COORDINATOR = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Translation" / "TranslationFeatureCoordinator.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
VIEWS = [
    ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "TranslationHomeView.swift",
    ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "TranslationFloatingPanelView.swift",
    ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "ProviderSettingsPane.swift",
    ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "TranslationSettingsPane.swift",
]


FORBIDDEN_APPSTATE_PUBLISHED = [
    "translationProviderProfiles",
    "selectedTranslationProviderID",
    "llmProviderProfiles",
    "translationEngineProfiles",
    "ocrEngineProfiles",
    "selectedLLMProviderID",
    "selectedTranslationEngineID",
    "selectedOCREngineID",
    "translationPreview",
    "translationResult",
    "translationRuntimeResult",
    "providerAuditEvents",
    "providerKeychainLastResult",
    "providerUserSecretLastResult",
    "openAIConnectionLastResult",
    "providerRouteResolution",
]

FORBIDDEN_SURFACE_TOKENS = [
    "URLSession",
    "SecItem",
    "Authorization",
    "Bearer",
    "Process(",
    "getenv(",
    "NSPasteboard.general",
    "rawProviderOutput",
    "providerRawOutput",
]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    failures: list[dict[str, str]] = []
    observations: dict[str, object] = {}

    for path in [APP_MODEL, APP_MODEL_DELEGATION, PROVIDER_STORE, TRANSLATION_STORE, PROVIDER_COORDINATOR, TRANSLATION_COORDINATOR, PROJECT, *VIEWS]:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": str(path.relative_to(ROOT))})

    app_state = text(APP_STATE)
    app_model = text(APP_MODEL)
    app_model_delegation = text(APP_MODEL_DELEGATION)
    app_model_facade = app_model + "\n" + app_model_delegation
    provider_store = text(PROVIDER_STORE)
    translation_store = text(TRANSLATION_STORE)
    provider_coordinator = text(PROVIDER_COORDINATOR)
    translation_coordinator = text(TRANSLATION_COORDINATOR)
    project = text(PROJECT)

    required_provider_store = [
        "@MainActor",
        "final class ProviderStore: ObservableObject",
        "@Published var llmProviderProfiles",
        "@Published var ocrEngineProfiles",
        "@Published var providerAuditEvents",
        "@Published var providerKeychainLastResult",
        "@Published var providerUserSecretLastResult",
        "@Published var openAIConnectionLastResult",
        "@Published var providerRouteResolution",
        "private let providerAuditCapacity = 20",
        "func recordProviderAudit",
        "func clearProviderAuditEvents",
    ]
    missing_provider = [needle for needle in required_provider_store if needle not in provider_store]
    if missing_provider:
        failures.append({"code": "provider_store_contract_missing", "detail": ", ".join(missing_provider)})

    required_translation_store = [
        "@MainActor",
        "final class TranslationStore: ObservableObject",
        "@Published var translationProviderProfiles",
        "@Published var selectedTranslationProviderID",
        "@Published var translationEngineProfiles",
        "@Published var selectedTranslationEngineID",
        "@Published var translationPreview",
        "@Published var translationResult",
        "@Published var translationRuntimeResult",
        "auditRecorder: @escaping (ProviderAuditEvent) -> Void",
        "func resolveTranslationEngineRoute(",
        "func runTranslation(",
    ]
    missing_translation = [needle for needle in required_translation_store if needle not in translation_store]
    if missing_translation:
        failures.append({"code": "translation_store_contract_missing", "detail": ", ".join(missing_translation)})

    if "ProviderStore" in translation_store:
        failures.append({"code": "translation_store_strong_provider_reference", "detail": "TranslationStore.swift contains ProviderStore"})
    if re.search(r"@(Published|State)\s+.*ProviderUserSecretMaterial", translation_store):
        failures.append({"code": "secret_material_published", "detail": "ProviderUserSecretMaterial is published in TranslationStore"})
    if re.search(r"(let|var)\s+\w+\s*:\s*ProviderUserSecretMaterial", translation_store):
        failures.append({"code": "secret_material_stored", "detail": "ProviderUserSecretMaterial stored property in TranslationStore"})
    if "@Published var providerAuditEvents" in translation_store:
        failures.append({"code": "provider_audit_duplicate_source", "detail": "TranslationStore declares providerAuditEvents"})

    if APP_STATE.exists():
        failures.append({"code": "appstate_file_remaining", "detail": str(APP_STATE.relative_to(ROOT))})

    required_appmodel = [
        "let providerStore: ProviderStore",
        "let translationStore: TranslationStore",
        "providerStore.objectWillChange",
        "translationStore.objectWillChange",
        "func selectTranslationEngine",
        "func resolveTranslationEngineRoute",
        "func runTranslation",
        "func runOpenAIConnectionTest",
        "func clearProviderAuditEvents",
    ]
    missing_appmodel = [needle for needle in required_appmodel if needle not in app_model_facade]
    if missing_appmodel:
        failures.append({"code": "appmodel_facade_missing", "detail": ", ".join(missing_appmodel)})

    required_wrapper_delegation = [
        "let providerCoordinator: ProviderFeatureCoordinator",
        "let translationCoordinator: TranslationFeatureCoordinator",
        "translationCoordinator.selectTranslationEngine",
        "translationCoordinator.resolveTranslationEngineRoute",
        "translationCoordinator.runTranslation",
        "providerCoordinator.runOpenAIConnectionTest",
        "providerCoordinator.clearProviderAuditEvents",
    ]
    missing_delegation = [needle for needle in required_wrapper_delegation if needle not in app_model_facade]
    if missing_delegation:
        failures.append({"code": "appmodel_wrapper_delegation_missing", "detail": ", ".join(missing_delegation)})

    if "TranslationStore" in provider_coordinator:
        failures.append({"code": "provider_coordinator_translation_store_reference", "detail": "ProviderFeatureCoordinator must use narrow selected-provider closures"})
    if "ClipboardStore" in translation_coordinator:
        failures.append({"code": "translation_coordinator_clipboard_store_reference", "detail": "TranslationFeatureCoordinator must use a narrow payload-read closure"})

    required_coordinator_boundaries = [
        (provider_coordinator, "selectedProviderSummary: @escaping () -> String"),
        (provider_coordinator, "selectedProviderRequiresExternalTransfer: @escaping () -> Bool"),
        (provider_coordinator, "publishRouteResolution: @escaping (ProviderRouteResolution) -> Void"),
        (translation_coordinator, "readClipboardPayload: @escaping (String, ClipboardPayloadReadPurpose) -> ClipboardPayloadReadResult"),
    ]
    missing_boundaries = [needle for source, needle in required_coordinator_boundaries if needle not in source]
    if missing_boundaries:
        failures.append({"code": "feature_coordinator_narrow_boundary_missing", "detail": ", ".join(missing_boundaries)})

    route_status_key_count = sum(
        source.count("status.providerRouteResolution.title")
        for source in [provider_coordinator, translation_coordinator]
    )
    if "enum ProviderRouteStatusFormatter" not in provider_coordinator or route_status_key_count != 1:
        failures.append({"code": "provider_route_status_formatter_not_single_source", "detail": f"formatter/key count={route_status_key_count}"})

    direct_published = []
    for name in FORBIDDEN_APPSTATE_PUBLISHED:
        if re.search(rf"@Published\s+var\s+{re.escape(name)}\b", app_state):
            direct_published.append(name)
    if direct_published:
        failures.append({"code": "appstate_forbidden_published_state", "detail": ", ".join(direct_published)})

    appmodel_forbidden_published = []
    for name in FORBIDDEN_APPSTATE_PUBLISHED:
        if re.search(rf"@Published\s+var\s+{re.escape(name)}\b", app_model):
            appmodel_forbidden_published.append(name)
    if appmodel_forbidden_published:
        failures.append({"code": "appmodel_forbidden_feature_published_state", "detail": ", ".join(appmodel_forbidden_published)})

    views_combined = "\n".join(text(path) for path in VIEWS)
    required_view_bindings = [
        "@EnvironmentObject private var providerStore: ProviderStore",
        "@EnvironmentObject private var translationStore: TranslationStore",
    ]
    missing_view_bindings = [needle for needle in required_view_bindings if needle not in views_combined]
    if missing_view_bindings:
        failures.append({"code": "store_injection_missing_in_provider_translation_views", "detail": ", ".join(missing_view_bindings)})
    if "EnvironmentObject private var appState" in views_combined or "EnvironmentObject var appState" in views_combined:
        failures.append({"code": "old_appstate_environment_object_remaining", "detail": "Provider/Translation views should use direct stores"})

    project_required = [
        "ProviderStore.swift",
        "ProviderStore.swift in Sources",
        "TranslationStore.swift",
        "TranslationStore.swift in Sources",
        "AppModel+FeatureDelegation.swift",
        "AppModel+FeatureDelegation.swift in Sources",
    ]
    missing_project = [needle for needle in project_required if needle not in project]
    if missing_project:
        failures.append({"code": "xcode_target_missing_store", "detail": ", ".join(missing_project)})

    surface_hits: list[str] = []
    for path in [PROVIDER_STORE, TRANSLATION_STORE, *VIEWS]:
        source = text(path)
        for token in FORBIDDEN_SURFACE_TOKENS:
            if token in source:
                surface_hits.append(f"{path.relative_to(ROOT)} contains {token}")
    if surface_hits:
        failures.append({"code": "forbidden_runtime_token_in_store_or_view", "detail": "; ".join(surface_hits)})

    observations["appstate_lines"] = len(app_state.splitlines())
    observations["appmodel_lines"] = len(app_model.splitlines())
    observations["provider_store_lines"] = len(provider_store.splitlines())
    observations["translation_store_lines"] = len(translation_store.splitlines())
    observations["provider_coordinator_lines"] = len(provider_coordinator.splitlines())
    observations["translation_coordinator_lines"] = len(translation_coordinator.splitlines())
    observations["forbidden_published_checked"] = FORBIDDEN_APPSTATE_PUBLISHED

    output = {
        "ok": not failures,
        "suite": "p10b_core_state_split_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
