#!/usr/bin/env python3
"""P7-D dynamic BCP-47 language controls and panel alignment checks."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PANEL = ROOT / "apps/Blocks/BlocksApp/Views/TranslationFloatingPanelView.swift"
MODEL = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationPanelSessionModel.swift"
STORE = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift"
LANGUAGE_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationLanguageSupport.swift"
CORE_MODELS = ROOT / "apps/Blocks/BlocksCore/TranslationModels.swift"
LEGACY_RESOLVER = ROOT / "apps/Blocks/BlocksApp/Support/TranslationLanguageResolver.swift"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
CATALOGS = [
    ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings",
    ROOT / "apps/Blocks/BlocksApp/Features/Translation/Resources/TranslationLocalizable.xcstrings",
]
LANGUAGES = ["zh-Hans", "en", "ja"]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def merged_strings() -> dict[str, object]:
    result: dict[str, object] = {}
    for catalog in CATALOGS:
        if catalog.exists():
            result.update(json.loads(text(catalog)).get("strings", {}))
    return result


def main() -> int:
    failures: list[dict[str, str]] = []
    panel = text(PANEL)
    model = text(MODEL)
    store = text(STORE)
    language_support = text(LANGUAGE_SUPPORT)
    core_models = text(CORE_MODELS)
    project = text(PROJECT)

    required_files = [
        PANEL,
        MODEL,
        STORE,
        LANGUAGE_SUPPORT,
        CORE_MODELS,
        *CATALOGS,
    ]
    for path in required_files:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    panel_symbols = [
        "private var targetLanguageSections: TranslationLanguageMenuSections",
        "model.supportedLanguages",
        "private var sourceLanguageSections: TranslationLanguageMenuSections",
        "model.supportedSourceLanguages",
        "TranslationLanguagePreferences.menuSections(",
        'L10n.string("translation.language.common")',
        'L10n.string("translation.language.all")',
        'L10n.string("translation.panel.sourceLanguage")',
        'L10n.string("translation.panel.targetLanguage")',
        '"translation.panel.sourceLanguage"',
        '"translation.panel.targetLanguage"',
        ".localizedName(for: language)",
        ".frame(maxWidth: .infinity)",
    ]
    missing_panel = [symbol for symbol in panel_symbols if symbol not in panel]
    require(
        not missing_panel,
        "missing_dynamic_language_controls",
        ", ".join(missing_panel),
        failures,
    )

    model_symbols = [
        "var supportedLanguages: [TranslationLanguageTag]",
        "translationStore.supportedLanguages",
        "var supportedSourceLanguages: [TranslationLanguageTag]",
        "translationStore.supportedSourceLanguages",
    ]
    missing_model = [symbol for symbol in model_symbols if symbol not in model]
    require(
        not missing_model,
        "panel_model_not_using_registry_languages",
        ", ".join(missing_model),
        failures,
    )

    store_symbols = [
        "@Published private(set) var supportedSourceLanguages",
        "@Published private(set) var supportedLanguages",
        "enabledDescriptors.flatMap",
        r"\.supportedTargetLanguages",
        r"\.supportedSourceLanguages",
        "AppleLocalTranslationServiceAdapter.supportedLanguages()",
    ]
    missing_store = [symbol for symbol in store_symbols if symbol not in store]
    require(
        not missing_store,
        "registry_language_capabilities_missing",
        ", ".join(missing_store),
        failures,
    )

    language_symbols = [
        "TranslationLanguageTag",
        "localizedName(",
        "sortedOptions(",
        "defaultTargetKey",
    ]
    missing_language = [
        symbol for symbol in language_symbols
        if symbol not in language_support and symbol not in core_models
    ]
    require(
        not missing_language,
        "bcp47_language_contract_missing",
        ", ".join(missing_language),
        failures,
    )

    require(
        not LEGACY_RESOLVER.exists(),
        "legacy_language_resolver_restored",
        str(LEGACY_RESOLVER.relative_to(ROOT)),
        failures,
    )
    require(
        "TranslationLanguageResolver.swift" not in project,
        "legacy_language_resolver_project_reference",
        "The deleted single-result language resolver must not be part of the target.",
        failures,
    )

    strings = merged_strings()
    for key in [
        "language.auto",
        "translation.language.common",
        "translation.language.all",
        "translation.panel.source",
        "translation.panel.target",
        "translation.panel.swapLanguages",
    ]:
        entry = strings.get(key)
        missing_langs = [
            language
            for language in LANGUAGES
            if language not in (entry or {}).get("localizations", {})
        ]
        require(
            entry is not None and not missing_langs,
            "missing_localization",
            f"{key}:{','.join(missing_langs)}",
            failures,
        )

    print(json.dumps({
        "ok": not failures,
        "suite": "p7d_translation_auto_target_alignment_checks",
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
