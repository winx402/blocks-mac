#!/usr/bin/env python3
"""P7-C automatic translation and unified stacked-panel checks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
TRANSLATION_LOCALIZABLE = APP / "Features" / "Translation" / "Resources" / "TranslationLocalizable.xcstrings"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
PANEL_LAYOUT = APP / "Features" / "Translation" / "Panel" / "TranslationPanelContentLayout.swift"
SESSION_MODEL = APP / "Features" / "Translation" / "TranslationPanelSessionModel.swift"
RUNTIME = APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
PRESENTER = APP / "Services" / "TranslationPanelPresenter.swift"
STORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationStoreTests.swift"

LANGUAGES = ["zh-Hans", "en", "ja"]


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
    for path in [
        LOCALIZABLE,
        TRANSLATION_LOCALIZABLE,
        PANEL,
        PANEL_LAYOUT,
        SESSION_MODEL,
        RUNTIME,
        PRESENTER,
        STORE_TESTS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    panel = text(PANEL)
    panel_layout = text(PANEL_LAYOUT)
    session = text(SESSION_MODEL)
    runtime = text(RUNTIME)
    presenter = text(PRESENTER)
    tests = text(STORE_TESTS)
    combined = "\n".join([panel, panel_layout, session, runtime, presenter])

    required_symbols = [
        "func scheduleAutomaticTranslation(delay: Duration = .milliseconds(450))",
        "autoTranslationTask?.cancel()",
        "runCoordinator.cancelCurrent()",
        "guard !Task.isCancelled else { return }",
        "self?.runImmediately()",
        "updateSourceTextFromUser",
        "var shouldRunOnPresentation: Bool",
        "if model.shouldRunOnPresentation",
        "model.runImmediately()",
        "ScrollView",
        "sourceSection",
        "languageBar",
        "resultsSection",
        "Array(resultStates.enumerated())",
        "TranslationPanelResultStateReader(",
        ".nonactivatingPanel",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(
        not missing_symbols,
        "automatic_session_panel_contract_missing",
        ", ".join(missing_symbols),
        failures,
    )
    require(
        "translation.runButton" not in panel
        and "Button(L10n.string(\"translation.runButton\")" not in panel,
        "manual_run_button_still_present",
        "The unified session owns automatic translation; the result panel must not restore a second manual run path.",
        failures,
    )
    require(
        "model.scheduleAutomaticTranslation()" not in panel,
        "view_retains_debounce_side_effect",
        "User edits must schedule through TranslationPanelSessionModel updates; the view may only trigger the initial immediate run.",
        failures,
    )
    require(
        "TranslationFloatingPanelComponents" not in combined
        and "TranslationSplitPanel" not in combined,
        "retired_split_panel_present",
        "The old split-panel component tree must not coexist with the unified stacked session panel.",
        failures,
    )
    require(
        "testAutomaticTranslationDebounceRunsOnlyLatestInput" in tests
        and "testUserSourceUpdateOwnsItsDebounceWithoutViewSideEffects" in tests
        and "testNewRevisionRejectsLateResultFromPreviousSession" in tests,
        "automatic_translation_tests_missing",
        "Debounce ownership, latest-input execution, and stale-result rejection require AppTests.",
        failures,
    )

    forbidden = [
        "URLSession",
        "Process(",
        "getenv(",
        "SecItem",
        "Authorization",
        "Bearer",
        "NSPasteboard.general",
    ]
    panel_hits = [symbol for symbol in forbidden if symbol in panel + "\n" + presenter]
    require(
        not panel_hits,
        "forbidden_translation_panel_runtime",
        ", ".join(panel_hits),
        failures,
    )

    localized_strings: dict[str, Any] = {}
    for catalog in [LOCALIZABLE, TRANSLATION_LOCALIZABLE]:
        if catalog.exists():
            localized_strings.update(
                json.loads(catalog.read_text(encoding="utf-8")).get("strings", {})
            )
    required_keys = [
        "translation.panel.autoTranslate",
        "translation.panel.autoTranslateDetail",
        "translation.panel.running",
        "translation.panel.runningDetail",
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

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p7c-translation")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {
        "ok": build["ok"],
        "returncode": build["returncode"],
        "mode": build["mode"],
    }
    observations["localization"] = {
        "checked": len(required_keys),
        "missing": missing_l10n,
    }

    report = {
        "ok": not failures,
        "suite": "p7c_translation_auto_split_panel_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
