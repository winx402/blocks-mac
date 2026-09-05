#!/usr/bin/env python3
"""P5-B unified multi-service result and production-no-mock checks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text
from verification_build_helpers import run_controlled_subprocess


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
RUNTIME = APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
STORE = APP / "Features" / "Translation" / "TranslationStore.swift"
SESSION_MODEL = APP / "Features" / "Translation" / "TranslationPanelSessionModel.swift"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
CORE_MODELS = ROOT / "apps" / "Blocks" / "BlocksCore" / "TranslationModels.swift"
STORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationStoreTests.swift"
CORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationCoreTests.swift"


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = run_controlled_subprocess(command, cwd=ROOT, timeout=timeout)
    if completed["timed_out"]:
        return {
            "ok": False,
            "returncode": completed["returncode"],
            "stdout": sanitize_text(completed["stdout"]),
            "stderr_tail": f"command timed out after {timeout}s",
            "timed_out": True,
        }
    return {
        "ok": completed["ok"],
        "returncode": completed["returncode"],
        "stdout": sanitize_text(completed["stdout"]),
        "stderr_tail": sanitize_text(completed["stderr"][-1800:]),
        "timed_out": False,
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--skip-build", "--no-build", action="store_true", dest="skip_build")
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    p5a = run(
        [
            "python3",
            "tools/verification/p5a_translation_skeleton_checks.py",
            "--timeout",
            str(args.timeout),
            *( ["--skip-build"] if args.skip_build else [] ),
        ],
        args.timeout,
    )
    require(
        p5a["ok"],
        "p5a_regression_failed",
        p5a["stdout"] or p5a["stderr_tail"],
        failures,
    )
    observations["p5a_regression"] = p5a["ok"]

    for path in [
        RUNTIME,
        STORE,
        SESSION_MODEL,
        PANEL,
        CORE_MODELS,
        STORE_TESTS,
        CORE_TESTS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    runtime = text(RUNTIME)
    store = text(STORE)
    session = text(SESSION_MODEL)
    panel = text(PANEL)
    models = text(CORE_MODELS)
    store_tests = text(STORE_TESTS)
    core_tests = text(CORE_TESTS)
    production = "\n".join([runtime, store, session, panel, models])

    required_symbols = [
        "case waiting",
        "case running",
        "case streaming",
        "case succeeded",
        "case failed",
        "case cancelled",
        "adapters.map",
        "serviceTasks",
        "guard revision == requestRevision",
        "func retry(serviceID:",
        "func cancelCurrent()",
        "Array(resultStates.enumerated())",
        "TranslationPanelResultStateReader(",
        "TranslationResultCard(",
        "orderedAdapters(serviceIDs:",
        ".prefix(max(0, maximumCount))",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in production]
    require(
        not missing_symbols,
        "multi_result_contract_missing",
        ", ".join(missing_symbols),
        failures,
    )
    require(
        "MockTranslation" not in production
        and "TranslationMock" not in production
        and "mock-result" not in production
        and "generateMockResult" not in production,
        "production_mock_runtime_present",
        "Mock translation is test-only and must not be registered or rendered in production.",
        failures,
    )

    required_tests = [
        "testProductionRegistryContainsBuiltInsAndNoMockService",
        "testEnabledComparisonGroupKeepsConfigurationOrderAndCapsAtFour",
        "testRunCoordinatorPreservesServiceOrderAcrossOutOfOrderCompletionAndFailure",
        "testRunCoordinatorCompletesStableSessionWhenAllServicesFail",
        "testNewRevisionRejectsLateResultFromPreviousSession",
        "testAutomaticTranslationDebounceRunsOnlyLatestInput",
        "testSessionPreservesConfiguredResultOrderInsteadOfCompletionOrder",
    ]
    all_tests = store_tests + "\n" + core_tests
    missing_tests = [name for name in required_tests if name not in all_tests]
    require(
        not missing_tests,
        "multi_result_behavior_tests_missing",
        ", ".join(missing_tests),
        failures,
    )

    observations["contract"] = {
        "production_mock": False,
        "maximum_comparison_services": 4,
        "ordered_results": True,
        "revision_gated": True,
    }
    report = {
        "ok": not failures,
        "suite": "p5b_translation_mock_result_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
