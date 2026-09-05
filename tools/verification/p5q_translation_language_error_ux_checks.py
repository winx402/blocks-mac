#!/usr/bin/env python3
"""P5-Q BCP-47 language capability and localized error UX checks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
TRANSLATION_LOCALIZABLE = APP / "Features" / "Translation" / "Resources" / "TranslationLocalizable.xcstrings"
LANGUAGE_SUPPORT = APP / "Features" / "Translation" / "TranslationLanguageSupport.swift"
RUNTIME = APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
BUILT_INS = APP / "Features" / "Translation" / "TranslationBuiltInAdapters.swift"
PREPARATION = APP / "Features" / "Translation" / "AppleTranslationPreparationView.swift"
STORE = APP / "Features" / "Translation" / "TranslationStore.swift"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
PANEL_COMPONENTS = (
    APP
    / "Features"
    / "Translation"
    / "Panel"
    / "TranslationFloatingPanelComponents.swift"
)
PANEL_PRESENTER = APP / "Services" / "TranslationPanelPresenter.swift"
SELECTION_READER = (
    APP
    / "Features"
    / "Translation"
    / "Entry"
    / "AXSelectionReader.swift"
)
MODELS = CORE / "TranslationModels.swift"
STORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationStoreTests.swift"
CORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationCoreTests.swift"
ENTRY_TESTS = (
    ROOT
    / "apps"
    / "Blocks"
    / "BlocksAppTests"
    / "TranslationEntryBridgeTests.swift"
)

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": sanitize_text(completed.stdout),
        "stderr_tail": sanitize_text(completed.stderr[-1800:]),
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    p5p = run(
        [
            "python3",
            "tools/verification/p5p_translation_panel_polish_checks.py",
            "--timeout",
            str(args.timeout),
        ],
        args.timeout,
    )
    require(
        p5p["ok"],
        "p5p_regression_failed",
        p5p["stdout"] or p5p["stderr_tail"],
        failures,
    )
    observations["p5p_regression"] = p5p["ok"]

    for path in [
        LOCALIZABLE,
        TRANSLATION_LOCALIZABLE,
        LANGUAGE_SUPPORT,
        RUNTIME,
        BUILT_INS,
        PREPARATION,
        STORE,
        PANEL,
        PANEL_COMPONENTS,
        PANEL_PRESENTER,
        SELECTION_READER,
        MODELS,
        STORE_TESTS,
        CORE_TESTS,
        ENTRY_TESTS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    language_support = text(LANGUAGE_SUPPORT)
    runtime = text(RUNTIME)
    built_ins = text(BUILT_INS)
    preparation = text(PREPARATION)
    store = text(STORE)
    panel = text(PANEL)
    panel_components = text(PANEL_COMPONENTS)
    panel_presenter = text(PANEL_PRESENTER)
    selection_reader = text(SELECTION_READER)
    models = text(MODELS)
    tests = (
        text(STORE_TESTS)
        + "\n"
        + text(CORE_TESTS)
        + "\n"
        + text(ENTRY_TESTS)
    )
    combined = "\n".join(
        [
            language_support,
            runtime,
            built_ins,
            preparation,
            store,
            panel,
            panel_components,
            panel_presenter,
            selection_reader,
            models,
        ]
    )

    required_symbols = [
        "struct TranslationLanguageTag",
        "private static func canonicalize",
        "TranslationLanguagePreferences",
        "preferredTarget",
        "rememberFocusLanguage",
        "TranslationTargetResolver",
        "nativeLanguageKey",
        "focusLanguagesKey",
        "supportedSourceLanguages",
        "supportedLanguages",
        "refreshSupportedLanguages",
        "TranslationErrorPresentation",
        "translation.error.generic",
        "apple_language_download_required",
        "apple_language_pair_unsupported",
        "apple_translation_requires_macos_15",
        "LanguageAvailability",
        "request.direction.source == nil",
        "AppleTranslationFailureClassifier",
        "AppleTranslationReadinessPolicy",
        "enum AppleTranslationLanguagePairResolver",
        "static func directedPairs",
        "TranslationResultRecoveryOptions",
        "appKitMouseAnchor",
        "model.inputSource == .manual",
        "enum TranslationLocalizedFormat",
        "TranslationLocalizedFormat.ocrLines",
        "TranslationLocalizedFormat.duration",
        "static func httpStatus",
        "showsIndeterminateProgress: true",
        "notificationState.dismiss(",
        "Self.selectionReadingNotificationKey",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(
        not missing_symbols,
        "language_error_contract_missing",
        ", ".join(missing_symbols),
        failures,
    )
    require(
        "TranslationLanguageResolver" not in combined
        and "case chinese" not in models
        and "case english" not in models
        and "case japanese" not in models,
        "legacy_fixed_language_model_present",
        "The translation runtime must use canonical BCP-47 tags and service capabilities instead of a fixed three-language enum.",
        failures,
    )
    required_tests = [
        "testLanguageTagCanonicalizesCommonBCP47FormsAndRejectsSyntheticAuto",
        "testSupportedLanguagesFollowEnabledServiceCapabilities",
        "testLegacyDefaultTargetMigratesToNativeLanguageModel",
        "testSmartTargetTranslatesForeignLanguageIntoNativeLanguage",
        "testSmartTargetUsesRecentFocusLanguageForNativeSource",
        "testSmartTargetDoesNotInventTargetWithoutFocusLanguage",
        "testRunCoordinatorRejectsUnsupportedTargetBeforeCallingAdapter",
        "testPluginExecutionErrorsUseLocalizedUserFacingMessages",
        "testAppleTranslationFailureClassifierDoesNotCallInternalFailureDownload",
        "testAppleTranslationReadinessSeparatesDownloadFromNotReady",
        "testAppleLanguagePackResolverIncludesBothDirections",
        "testSelectionSkeletonUsesFrozenMouseAnchorBeforeHelperReturns",
        "testCompatibilitySelectionPreservesFrozenMouseAnchor",
        "testSelectionPanelIsCenteredOnResolvedScreen",
        "testTranslationEntryScreenContextPreservesFrozenDisplayAcrossAsyncWork",
        "testTranslationEntryScreenContextDoesNotOverrideExplicitCaptureScreen",
        "testEmptySelectionFailuresAreSilentButRuntimeFaultsRemainVisible",
        "testTranslationLocalizedNumericFormatsUseTypedIntegerContracts",
        "testCommunityConnectionTestUsesSelectedGoogleAdapter",
    ]
    missing_tests = [name for name in required_tests if name not in tests]
    require(
        not missing_tests,
        "language_error_behavior_tests_missing",
        ", ".join(missing_tests),
        failures,
    )

    localized_strings: dict[str, Any] = {}
    for catalog in [LOCALIZABLE, TRANSLATION_LOCALIZABLE]:
        if catalog.exists():
            localized_strings.update(
                json.loads(catalog.read_text(encoding="utf-8")).get("strings", {})
            )
    required_keys = [
        "translation.error.generic",
        "translation.error.languageDownloadRequired",
        "translation.error.languagePairUnsupported",
        "translation.error.languageUnavailable",
        "translation.error.appleRequiresMacOS15",
        "translation.error.sourceLanguageUndetermined",
        "translation.error.appleLanguageNotReady",
        "translation.error.appleRuntimeUnavailable",
        "translation.error.applePreparationFailed",
        "translation.notification.languageDownloadRequired",
        "translation.notification.languageNotReady",
        "translation.notification.languageUnsupported",
        "translation.notification.appleTranslationFailed",
        "translation.service.availability.available",
        "translation.service.availability.requires_configuration",
        "translation.service.availability.requires_download",
        "translation.service.availability.unsupported",
    ]
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localized_strings.get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [
            language
            for language in LANGUAGES
            if language not in entry.get("localizations", {})
        ]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(
        not missing_l10n,
        "missing_localization",
        ", ".join(missing_l10n),
        failures,
    )
    numeric_format_contracts = {
        "translation.error.inputTooLarge": 1,
        "translation.panel.diagnostics.durationValue": 1,
        "translation.screenshot.ocrLines": 1,
        "translation.community.error.httpStatus": 1,
        "translation.preview.characterCount": 1,
    }
    invalid_numeric_formats: list[str] = []
    for key, placeholder_count in numeric_format_contracts.items():
        entry = localized_strings.get(key)
        for language in LANGUAGES:
            value = (
                (entry or {})
                .get("localizations", {})
                .get(language, {})
                .get("stringUnit", {})
                .get("value", "")
            )
            if value.count("%lld") != placeholder_count or "%@" in value:
                invalid_numeric_formats.append(f"{key}:{language}:{value}")
    require(
        not invalid_numeric_formats,
        "translation_numeric_format_contract_invalid",
        "; ".join(invalid_numeric_formats),
        failures,
    )
    observations["localization"] = {
        "checked": len(required_keys),
        "missing": missing_l10n,
    }
    observations["language_model"] = "BCP-47 service capability intersection"
    require(
        "translation.notification.languageDownloadFailed"
        not in localized_strings,
        "blanket_language_download_failure_present",
        "Apple runtime failures must not be presented as language download failures.",
        failures,
    )

    report = {
        "ok": not failures,
        "suite": "p5q_translation_language_error_ux_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
