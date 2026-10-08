#!/usr/bin/env python3
"""P7-C automatic translation and unified stacked-panel checks."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
TRANSLATION_LOCALIZABLE = APP / "Features" / "Translation" / "Resources" / "TranslationLocalizable.xcstrings"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
PANEL_LAYOUT = APP / "Features" / "Translation" / "Panel" / "TranslationPanelContentLayout.swift"
SOURCE_EDITOR = APP / "Features" / "Translation" / "TranslationSourceTextEditor.swift"
SESSION_MODEL = APP / "Features" / "Translation" / "TranslationPanelSessionModel.swift"
RUNTIME = APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
PRESENTER = APP / "Services" / "TranslationPanelPresenter.swift"
STORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationStoreTests.swift"
ENTRY_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationEntryBridgeTests.swift"

LANGUAGES = ["zh-Hans", "en", "ja"]


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument(
        "--skip-build", action="store_true",
        help="Run static contracts only; do not invoke the no-launch app build.",
    )
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}
    for path in [
        LOCALIZABLE,
        TRANSLATION_LOCALIZABLE,
        PANEL,
        PANEL_LAYOUT,
        SOURCE_EDITOR,
        SESSION_MODEL,
        RUNTIME,
        PRESENTER,
        STORE_TESTS,
        ENTRY_TESTS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    panel = text(PANEL)
    panel_layout = text(PANEL_LAYOUT)
    editor = text(SOURCE_EDITOR)
    session = text(SESSION_MODEL)
    runtime = text(RUNTIME)
    presenter = text(PRESENTER)
    tests = text(STORE_TESTS)
    entry_tests = text(ENTRY_TESTS)
    combined = "\n".join([panel, panel_layout, session, runtime, presenter])

    required_symbols = [
        "func scheduleAutomaticTranslation(delay: Duration = .milliseconds(800))",
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
        all(symbol not in panel for symbol in [
            '"translation.runButton"', '"translation.cancel"',
            "actions.cancelTranslation()", "model.cancel()",
        ]),
        "manual_run_or_cancel_button_still_present",
        "The session owns automatic translation; the panel must not restore translate or cancel controls.",
        failures,
    )
    automatic_run = session.partition("func scheduleAutomaticTranslation(")[2].partition(
        "@discardableResult"
    )[0]
    immediate_run = session.partition("func runImmediately()")[2].partition(
        "private func startResolvedRun("
    )[0]
    publish_change = editor.partition("private func publishTextChange(")[2].partition(
        "func shouldApplyModelText("
    )[0]
    marked_commit = editor.partition("private func updateMarkedTextCommitState(")[2].partition(
        "private func publishCompositionState("
    )[0]
    require(
        "delay: Duration = .milliseconds(450)" not in session
        and "guard !isSourceComposingText else" in automatic_run
        and automatic_run.find("guard !isSourceComposingText else") < automatic_run.find("Task.sleep(for: delay)")
        and "guard !isSourceComposingText else" in immediate_run
        and immediate_run.find("guard !isSourceComposingText else") < immediate_run.find("TranslationTargetResolver.resolveDirection")
        and "func updateSourceCompositionState(_ isComposing: Bool)" in session
        and "if isComposing || automaticTranslationPending" in session
        and "onCompositionChange:" in panel
        and "model.updateSourceCompositionState($0)" in panel
        and "!textView.isUpdatingComposition" in publish_change
        and "!textView.isComposingText" in publish_change
        and publish_change.find("!textView.isComposingText") < publish_change.find("publishCommittedTextIfNeeded")
        and "publishCompositionState(true)" in marked_commit
        and "self.publishCommittedTextIfNeeded(from: textView)" in marked_commit
        and marked_commit.find("self.publishCommittedTextIfNeeded(from: textView)") < marked_commit.find("self.publishCompositionState(false)"),
        "automatic_translation_debounce_ime_contract_invalid",
        "Use an 800 ms debounce; suspend queued and immediate runs while IME text is marked, then publish committed text before resuming composition.",
        failures,
    )
    layout_view = panel_layout.partition("struct TranslationPanelContentLayout<")[2]
    compact_layout = re.sub(r"\s+", "", layout_view)
    require(
        "fixedControlsDivider()resultsViewport" in compact_layout
        and "sourceContent(sourceEditorHeight)" in layout_view
        and "private var resultsViewport: some View" in layout_view
        and "openingEditorHeight ?? preferredEditorHeight" in layout_view
        and "TranslationResultsScrollPhaseBridge(" not in layout_view
        and "scrollCoordinator" not in layout_view
        and "sourceExpanded" not in panel + session,
        "fixed_source_results_viewport_contract_invalid",
        "Keep the opening source editor height and language controls fixed above the separate result ScrollView; result scrolling must not collapse the source editor.",
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
        and "testSourceInteractionDebounceWaits800MillisecondsAfterLatestEdit" in tests
        and "testSourceInteractionCompositionSuspendsQueuedAndImmediateRuns" in tests
        and "testSourceInteractionCancelledCompositionResumesUnchangedCommittedText" in tests
        and "testUserSourceUpdateOwnsItsDebounceWithoutViewSideEffects" in tests
        and "testNewRevisionRejectsLateResultFromPreviousSession" in tests
        and "testSourceEditorCompositionSuspendsSynchronouslyAndEndsAfterCommittedText" in entry_tests
        and "testSourceEditorCompositionCancellationResumesEvenWhenTextIsUnchanged" in entry_tests,
        "automatic_translation_tests_missing",
        "800 ms latest-edit debounce, IME suspension/commit/cancellation, model ownership, and stale-result rejection require AppTests.",
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

    if args.skip_build:
        observations["app_build"] = {"skipped": True, "reason": "--skip-build"}
    else:
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
