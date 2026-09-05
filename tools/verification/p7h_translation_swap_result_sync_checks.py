#!/usr/bin/env python3
"""P7-H language swap, debounce, and translation revision checks."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PANEL = ROOT / "apps/Blocks/BlocksApp/Views/TranslationFloatingPanelView.swift"
MODEL = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationPanelSessionModel.swift"
RUNTIME = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationServiceRuntime.swift"
TESTS = ROOT / "apps/Blocks/BlocksAppTests/TranslationStoreTests.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    open_index = source.find("{", start)
    if open_index < 0:
        return ""
    depth = 0
    for index in range(open_index, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


def main() -> int:
    panel = read(PANEL)
    model = read(MODEL)
    runtime = read(RUNTIME)
    tests = read(TESTS)
    swap = block(model, "func swapLanguagesAndRun()")
    debounce = block(model, "func scheduleAutomaticTranslation(")
    start = block(runtime, "func start(")
    checks = {
        "swap_updates_both_languages_and_runs": all(
            symbol in swap
            for symbol in [
                "guard let sourceLanguage else { return }",
                "let previousTarget = targetLanguage",
                "self.sourceLanguage = previousTarget",
                "targetLanguage = sourceLanguage",
                "runImmediately()",
            ]
        )
        and "model.swapLanguagesAndRun()" in panel
        and "testLanguageSwapUsesOneImmediateTranslationRun" in tests,
        "automatic_translation_uses_single_debounce_owner": (
            "autoTranslationTask?.cancel()" in debounce
            and "runCoordinator.cancelCurrent()" in debounce
            and "Task.sleep(for: delay)" in debounce
            and "self?.runImmediately()" in debounce
        ),
        "coordinator_revisions_cancel_and_reject_stale_results": (
            "private var revision: UInt64" in runtime
            and "cancelTasks(incrementRevision: true)" in start
            and "guard revision == requestRevision else { return }" in runtime
        ),
        "four_service_order_test": (
            "testRunCoordinatorPreservesServiceOrderAcrossOutOfOrderCompletionAndFailure" in tests
            and '["slow", "failed", "fast", "medium"]' in tests
        ),
        "all_failure_stability_test": (
            "testRunCoordinatorCompletesStableSessionWhenAllServicesFail" in tests
            and "XCTAssertEqual(finalSnapshot?.successfulResults, [])" in tests
        ),
        "debounce_ownership_test": (
            "testUserSourceUpdateOwnsItsDebounceWithoutViewSideEffects" in tests
            and 'XCTAssertEqual(plugin.requestedTexts, ["latest"])' in tests
        ),
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7h_translation_swap_result_sync_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
