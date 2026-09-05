#!/usr/bin/env python3
"""P5-A unified translation session skeleton checks for Blocks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build, run_controlled_subprocess
from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
TRANSLATION_LOCALIZABLE = APP / "Features" / "Translation" / "Resources" / "TranslationLocalizable.xcstrings"
COORDINATOR = APP / "Features" / "Translation" / "TranslationFeatureCoordinator.swift"
COORDINATOR_SELECTION = (
    APP
    / "Features"
    / "Translation"
    / "TranslationFeatureCoordinator+Selection.swift"
)
SESSION_MODEL = APP / "Features" / "Translation" / "TranslationPanelSessionModel.swift"
RUNTIME = APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
BUILT_INS = APP / "Features" / "Translation" / "TranslationBuiltInAdapters.swift"
SELECTION_READER = APP / "Features" / "Translation" / "Entry" / "AXSelectionReader.swift"
SCREENSHOT_CAPTURE = APP / "Features" / "Translation" / "Entry" / "TranslationScreenshotCaptureProvider.swift"
SCREENSHOT_OCR = APP / "Features" / "Translation" / "Entry" / "LocalVisionTranslationOCRAdapter.swift"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
PRESENTER = APP / "Services" / "TranslationPanelPresenter.swift"
MODELS = CORE / "TranslationModels.swift"
ENTRY_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationEntryBridgeTests.swift"

LANGUAGES = ["zh-Hans", "en", "ja"]


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

    if args.skip_build:
        observations["app_build"] = {"ok": True, "skipped": True}
    else:
        build = run_blocks_no_launch_build(ROOT, args.timeout, "p5a")
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {
            "ok": build["ok"],
            "returncode": build["returncode"],
            "mode": build["mode"],
        }

    # Keep the existing clipboard-panel boundary as a regression prerequisite,
    # but do not launch the application from a static gate.
    p4b = run(
        [
            "python3",
            "tools/verification/p4b_clipboard_panel_checks.py",
            "--timeout",
            str(args.timeout),
            "--skip-build",
        ],
        args.timeout,
    )
    require(
        p4b["ok"],
        "p4b_regression_failed",
        p4b["stdout"] or p4b["stderr_tail"],
        failures,
    )
    observations["p4b_regression"] = p4b["ok"]

    paths = [
        PROJECT,
        LOCALIZABLE,
        TRANSLATION_LOCALIZABLE,
        COORDINATOR,
        COORDINATOR_SELECTION,
        SESSION_MODEL,
        RUNTIME,
        BUILT_INS,
        SELECTION_READER,
        SCREENSHOT_CAPTURE,
        SCREENSHOT_OCR,
        PANEL,
        PRESENTER,
        MODELS,
        ENTRY_TESTS,
    ]
    for path in paths:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    project = text(PROJECT)
    expected_project_refs = [
        "TranslationModels.swift",
        "TranslationFeatureCoordinator.swift",
        "TranslationFeatureCoordinator+Selection.swift",
        "TranslationPanelSessionModel.swift",
        "TranslationServiceRuntime.swift",
        "TranslationBuiltInAdapters.swift",
        "AXSelectionReader.swift",
        "TranslationScreenshotCaptureProvider.swift",
        "LocalVisionTranslationOCRAdapter.swift",
        "TranslationFloatingPanelView.swift",
        "TranslationPanelPresenter.swift",
    ]
    missing_project_refs = [name for name in expected_project_refs if name not in project]
    require(
        not missing_project_refs,
        "project_refs_missing",
        ", ".join(missing_project_refs),
        failures,
    )

    coordinator = "\n".join([
        text(COORDINATOR),
        text(COORDINATOR_SELECTION),
    ])
    session = text(SESSION_MODEL)
    runtime = text(RUNTIME)
    models = text(MODELS)
    presenter = text(PRESENTER)
    panel = text(PANEL)
    entry_tests = text(ENTRY_TESTS)
    smart_entry_start = coordinator.find("func showSmartSelectionPanel()")
    smart_entry_end = coordinator.find("func showManualPanel()")
    smart_entry = (
        coordinator[smart_entry_start:smart_entry_end]
        if smart_entry_start >= 0 and smart_entry_end > smart_entry_start
        else ""
    )
    combined = "\n".join(
        [
            coordinator,
            session,
            runtime,
            text(BUILT_INS),
            text(SELECTION_READER),
            text(SCREENSHOT_CAPTURE),
            text(SCREENSHOT_OCR),
            models,
            presenter,
            panel,
        ]
    )
    required_symbols = [
        "struct TranslationInput",
        "struct TranslationSessionSnapshot",
        "struct TranslationResultSnapshot",
        "protocol TranslationServiceAdapter",
        "final class TranslationServiceRegistry",
        "final class TranslationRunCoordinator",
        "final class TranslationPanelSessionModel",
        "final class TranslationFeatureCoordinator",
        "func showSmartSelectionPanel()",
        "func showManualPanel()",
        "func showScreenshotTranslation()",
        "func showClipboardRecord(recordID:",
        "captureFrontmostTarget()",
        "freezeSelectionRequest(",
        "readSelection(from: request)",
        "source: .selection,",
        "source: .manual,",
        "source: .screenshotOCR",
        "source: .clipboardRecord",
        "TranslationSessionPanel",
        ".nonactivatingPanel",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(
        not missing_symbols,
        "unified_translation_symbols_missing",
        ", ".join(missing_symbols),
        failures,
    )

    require(
        "AX remains the primary path" in coordinator
        and "captureFrontmostTarget()" in smart_entry
        and "reader.freezeSelectionRequest(" in smart_entry
        and "requestID: invocationID.uuidString" in smart_entry
        and "AXSelectionElementReadToken" in text(SELECTION_READER)
        and "reader.readSelection(from: request)" in smart_entry
        and smart_entry.find("present(")
            < smart_entry.find("reader.readSelection(from: request)")
        and "NSPasteboard.general" not in smart_entry
        and "TranslationCompatibilitySelectionAuthorizationStore" in coordinator
        and "TranslationCompatibilitySelectionService" in coordinator,
        "strict_ax_selection_contract_missing",
        (
            "Smart selection must freeze the Helper request before presenting "
            "the skeleton. Compatibility copy is allowed only through the "
            "explicit per-application authorization service."
        ),
        failures,
    )
    require(
        "TranslationProviderProfile" not in combined
        and "TranslationEngineProfile" not in combined
        and "MockTranslation" not in combined
        and "TranslationMock" not in combined,
        "legacy_translation_runtime_present",
        "Production translation must use the unified service registry and must not retain provider/engine or mock runtime branches.",
        failures,
    )
    require(
        "testAXSelectionReaderReturnsPermissionFailureWithoutReadingElement" in entry_tests
        and "testAXSelectionReaderRejectsSecureTextField" in entry_tests
        and "testAXSelectionReaderNeverReadsBlocksOwnWindow" in entry_tests
        and "testAXSelectionReadRequestFreezesFocusedElementBeforeDeferredAttributeRead"
            in entry_tests
        and "testSelectionPanelSkeletonUsesFrozenElementAndPinnedSessionSurvivesNextEntry"
            in entry_tests
        and "testCompatibilitySelectionRestoresClipboardBeforeReturningText"
            in entry_tests
        and "testCompatibilitySelectionDoesNotOverwriteNewExternalClipboard"
            in entry_tests
        and "testScreenshotTranslationRequestsRegionWithoutEditingContext" in entry_tests
        and "testTranslationCapturePurposeUsesCleanNonPersistentOverlayOnlyPolicy" in entry_tests,
        "entry_behavior_tests_missing",
        "Strict AX failure handling and non-persistent screenshot translation require executable AppTests.",
        failures,
    )

    localized_strings: dict[str, Any] = {}
    for catalog in [LOCALIZABLE, TRANSLATION_LOCALIZABLE]:
        if catalog.exists():
            localized_strings.update(
                json.loads(catalog.read_text(encoding="utf-8")).get("strings", {})
            )
    required_keys = [
        "translation.title",
        "translation.panel.title",
        "translation.panel.source",
        "translation.panel.target",
        "translation.source.manual",
        "translation.source.selection",
        "translation.source.screenshot",
        "translation.shortcut.screenshot",
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
        "localization_missing",
        ", ".join(missing_l10n),
        failures,
    )
    observations["localization"] = {
        "checked": len(required_keys),
        "missing": missing_l10n,
    }
    observations["retired_contracts"] = [
        "implicit clipboard prefill",
        "TranslationProviderProfile",
        "TranslationEngineProfile",
        "production mock result",
    ]

    report = {
        "ok": not failures,
        "suite": "p5a_translation_skeleton_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
