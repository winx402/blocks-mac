#!/usr/bin/env python3
"""Static P15-C checks for the shared local OCR backend."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "apps/Blocks/BlocksApp/Features/OCR/LocalVisionOCRService.swift"
RECOGNIZER = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionTextRecognizer.swift"
QUEUE = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift"
TESTS = ROOT / "apps/Blocks/BlocksAppTests/LocalVisionOCRServiceTests.swift"
SCREENSHOT_CORE = ROOT / "apps/Blocks/BlocksScreenshotCore"
MANUAL_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Editor/ScreenshotManualOCRCoordinator.swift"
EDITOR_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Editor/ScreenshotEditorStore.swift"
EDITOR_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Editor/ScreenshotEditorView.swift"
EDITOR_OCR_VIEWS = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Editor/ScreenshotEditorOCRViews.swift"
PASTEBOARD_WRITER = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift"
APP_TESTS = ROOT / "apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift"
ACTION_TESTS = ROOT / "apps/Blocks/BlocksAppTests/ScreenshotHistoryActionServiceTests.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
TRANSLATION_COORDINATOR = (
    ROOT
    / "apps/Blocks/BlocksApp/Features/Translation/TranslationFeatureCoordinator.swift"
)
TRANSLATION_OCR_ADAPTER = (
    ROOT
    / "apps/Blocks/BlocksApp/Features/Translation/Entry/LocalVisionTranslationOCRAdapter.swift"
)


def require(
    condition: bool,
    failure: str,
    observation: str,
    failures: list[str],
    observations: list[str],
) -> None:
    if condition:
        observations.append(observation)
    else:
        failures.append(failure)


def source_slice(source: str, start_marker: str, end_marker: str) -> str:
    """Return one stable Swift declaration slice, or an empty string."""
    start = source.find(start_marker)
    if start < 0:
        return ""
    end = source.find(end_marker, start + len(start_marker))
    if end < 0:
        return ""
    return source[start:end]


def main() -> int:
    failures: list[str] = []
    observations: list[str] = []

    require(
        SERVICE.exists(),
        "backend.shared_service_missing",
        "backend.shared_service_present",
        failures,
        observations,
    )
    service = SERVICE.read_text(encoding="utf-8") if SERVICE.exists() else ""
    recognizer = RECOGNIZER.read_text(encoding="utf-8")
    queue = QUEUE.read_text(encoding="utf-8")
    tests = TESTS.read_text(encoding="utf-8") if TESTS.exists() else ""
    manual = MANUAL_COORDINATOR.read_text(encoding="utf-8") if MANUAL_COORDINATOR.exists() else ""
    editor_store = EDITOR_STORE.read_text(encoding="utf-8")
    editor_view = EDITOR_VIEW.read_text(encoding="utf-8")
    editor_ocr_views = EDITOR_OCR_VIEWS.read_text(encoding="utf-8")
    pasteboard_writer = PASTEBOARD_WRITER.read_text(encoding="utf-8")
    app_tests = APP_TESTS.read_text(encoding="utf-8")
    action_tests = ACTION_TESTS.read_text(encoding="utf-8")
    app_model = APP_MODEL.read_text(encoding="utf-8")
    translation_coordinator = TRANSLATION_COORDINATOR.read_text(encoding="utf-8")
    translation_ocr_adapter = TRANSLATION_OCR_ADAPTER.read_text(encoding="utf-8")
    app_model_init = source_slice(
        app_model,
        "    init(",
        "    private func configurePluginPlatform(",
    )
    plugin_configuration = source_slice(
        app_model,
        "    private func configurePluginPlatform(",
        "    private func configureFeatureCoordinators(",
    )
    translation_init = source_slice(
        translation_coordinator,
        "    init(",
        "    func configure(",
    )
    translation_adapter_init = source_slice(
        translation_ocr_adapter,
        "    init(coordinator:",
        "    init(recognize:",
    )
    manual_ocr_flow = source_slice(
        editor_store,
        "    private func performPendingManualOCRIfReady()",
        "    private func performManualOCR(",
    )

    for language in ("zh-Hans", "zh-Hant", "en-US", "ja-JP"):
        require(
            language in service,
            f"backend.language_missing:{language}",
            f"backend.language_present:{language}",
            failures,
            observations,
        )
    require(
        "automaticallyDetectsLanguage" in service,
        "backend.automatic_language_detection_missing",
        "backend.automatic_language_detection_present",
        failures,
        observations,
    )
    require(
        "var usesLanguageCorrection = false" in service
        and "fallbackConfidenceThreshold" in service
        and "meanConfidence" in service,
        "backend.primary_raw_and_confidence_fallback_missing",
        "backend.primary_raw_and_confidence_fallback_present",
        failures,
        observations,
    )
    require(
        "kCGImagePropertyOrientation" in service and ".up" in service,
        "backend.image_orientation_metadata_or_default_missing",
        "backend.image_orientation_metadata_and_default_present",
        failures,
        observations,
    )
    require(
        "withTaskCancellationHandler" in service
        and "Task.checkCancellation" in service
        and "request.cancel()" in service,
        "backend.cooperative_cancellation_missing",
        "backend.cooperative_cancellation_present",
        failures,
        observations,
    )
    require(
        "OperationQueue" in service and "maxConcurrentOperationCount" in service,
        "backend.vision_concurrency_limit_missing",
        "backend.vision_concurrency_limit_present",
        failures,
        observations,
    )
    logging_markers = ("Logger(", "os_log(", "NSLog(", "print(")
    require(
        not any(marker in service for marker in logging_markers),
        "backend.image_or_text_logging_surface_present",
        "backend.no_image_or_text_logging_surface",
        failures,
        observations,
    )
    require(
        "enum LocalVisionOCRReadingOrder" in service
        and "orderedIndices" in service
        and "verticalColumnOrder" in service
        and "horizontalColumns" in service,
        "backend.reading_order_pure_function_missing",
        "backend.reading_order_pure_function_present",
        failures,
        observations,
    )
    require(
        "LocalOCRCoordinator" in recognizer
        and "VNRecognizeTextRequest" not in recognizer,
        "backend.clipboard_recognizer_not_delegating_shared_coordinator",
        "backend.clipboard_recognizer_delegates_shared_coordinator",
        failures,
        observations,
    )
    require(
        "LocalOCRCoordinator" in queue
        and "LocalOCRRequestContext" in queue,
        "backend.clipboard_queue_shared_coordinator_injection_missing",
        "backend.clipboard_queue_shared_coordinator_injection_present",
        failures,
        observations,
    )
    require(
        "LocalOCRExecutionGate" in service
        and "case interactive" in service
        and "case userInitiated" in service
        and "case background" in service,
        "backend.shared_priority_scheduler_missing",
        "backend.shared_priority_scheduler_present",
        failures,
        observations,
    )
    require(
        len(re.findall(r"\bLocalVisionOCRService\s*\(", app_model)) == 1
        and re.search(
            r"let\s+localVisionOCRService\s*=\s*LocalVisionOCRService\s*\(\s*\)",
            app_model_init,
        )
        is not None
        and re.search(
            r"let\s+localOCRCoordinator\s*=\s*LocalOCRCoordinator\s*\(\s*"
            r"service:\s*localVisionOCRService\s*\)",
            app_model_init,
        )
        is not None
        and len(
            re.findall(
                r"ocrCoordinator:\s*localOCRCoordinator",
                app_model_init,
            )
        )
        >= 2
        and re.search(
            r"localOCRCoordinator:\s*localOCRCoordinator",
            app_model_init,
        )
        is not None
        and re.search(
            r"configurePluginPlatform\s*\(\s*ocrCoordinator:\s*"
            r"localOCRCoordinator\s*\)",
            app_model_init,
        )
        is not None,
        "backend.app_composition_does_not_own_one_shared_ocr_coordinator",
        "backend.app_composition_owns_one_shared_ocr_coordinator",
        failures,
        observations,
    )
    require(
        re.search(
            r"configurePluginPlatform\s*\(\s*ocrCoordinator:\s*"
            r"LocalOCRCoordinator\s*\)",
            plugin_configuration,
        )
        is not None
        and re.search(
            r"ocrCoordinator\.recognizeText\s*\([^)]*?"
            r"context:\s*\.pluginScreenshot",
            plugin_configuration,
            re.DOTALL,
        )
        is not None
        and "case .clipboardImage, .screenshotHistory, .startupRecovery, .pluginScreenshot:"
        in service,
        "backend.plugin_ocr_not_using_shared_background_coordinator",
        "backend.plugin_ocr_uses_shared_background_coordinator",
        failures,
        observations,
    )
    require(
        re.search(
            r"localOCRCoordinator:\s*LocalOCRCoordinator\?\s*=\s*nil",
            translation_init,
        )
        is not None
        and re.search(
            r"LocalVisionTranslationOCRAdapter\s*\(\s*coordinator:\s*"
            r"localOCRCoordinator\s*\?\?\s*LocalOCRCoordinator\s*\(\s*\)\s*\)",
            translation_init,
        )
        is not None
        and re.search(
            r"init\s*\(\s*coordinator:\s*LocalOCRCoordinator\s*=\s*"
            r"LocalOCRCoordinator\s*\(\s*\)\s*\)",
            translation_adapter_init,
        )
        is not None
        and re.search(
            r"coordinator\.recognizeText\s*\([^)]*?"
            r"context:\s*\.translationScreenshot",
            translation_adapter_init,
            re.DOTALL,
        )
        is not None
        and "case .editorRegion, .pinnedImage, .translationScreenshot:" in service,
        "backend.translation_ocr_not_using_shared_interactive_coordinator",
        "backend.translation_ocr_uses_shared_interactive_coordinator",
        failures,
        observations,
    )
    require(
        "mapToFullImage" in service
        and "deduplicatedObservations" in service
        and "normalizedSimilarity" in service,
        "backend.global_geometric_tile_merge_missing",
        "backend.global_geometric_tile_merge_present",
        failures,
        observations,
    )
    require(
        "prepareOCRRetry" in queue
        and "case .alreadyRunning" in queue
        and 'reason: "already_running"' in queue,
        "queue.atomic_retry_already_running_contract_missing",
        "queue.atomic_retry_already_running_contract_present",
        failures,
        observations,
    )
    require(
        "testRetryWhileRecordIsRunningReturnsAlreadyRunningWithoutRevertingDatabaseState"
        in action_tests,
        "queue.atomic_retry_already_running_test_missing",
        "queue.atomic_retry_already_running_test_present",
        failures,
        observations,
    )

    forbidden_core_imports = []
    for source in SCREENSHOT_CORE.glob("*.swift"):
        text = source.read_text(encoding="utf-8")
        for module in ("Vision", "AppKit", "SQLite3", "BlocksCore"):
            if f"import {module}" in text:
                forbidden_core_imports.append(f"{source.name}:{module}")
    require(
        not forbidden_core_imports,
        "backend.screenshot_core_forbidden_dependencies:"
        + ",".join(forbidden_core_imports),
        "backend.screenshot_core_dependency_boundary_clean",
        failures,
        observations,
    )

    for test_name in (
        "testLanguageConfigurationUsesOnlyPreferredSystemSupportedLanguages",
        "testDataInputPassesImagePropertyOrientationToAdapter",
        "testCGImageInputDefaultsOrientationToUp",
        "testTaskCancellationCancelsRequestTokenAndThrowsCancellationError",
        "testHorizontalReadingOrderGroupsRowsThenReadsLeftToRight",
        "testMultiColumnReadingOrderFinishesLeftColumnBeforeRightColumn",
        "testJapaneseVerticalReadingOrderUsesRightColumnsTopToBottom",
        "testLowConfidencePrimaryUsesCorrectionFallbackOnlyWhenCoverageAndConfidenceImprove",
        "testGeometricDeduplicationToleratesMinorRecognitionDifference",
        "testTallLatinBoxesDoNotTriggerJapaneseVerticalOrdering",
        "testCoordinatorRunsInteractiveRequestBeforeQueuedStartupRecoveryWork",
        "testTranslationScreenshotAdapterUsesSharedCoordinatorAndRunsBeforeQueuedPluginScreenshotWork",
        "testQueuedTranslationScreenshotCancellationDoesNotReachVisionOrBlockPluginWork",
    ):
        require(
            test_name in tests,
            f"backend.test_missing:{test_name}",
            f"backend.test_present:{test_name}",
            failures,
            observations,
        )

    manual_markers = (
        "ScreenshotManualOCRCoordinator",
        "claimTerminal(requestID:",
        "timeoutTask",
        "recognitionTask?.cancel()",
        "revision:",
        "case timedOut",
    )
    require(
        all(marker in manual for marker in manual_markers),
        "manual.coordinator_contract_missing",
        "manual.coordinator_first_terminal_revision_contract_present",
        failures,
        observations,
    )
    require(
        "cachedOutputRequest()" in manual_ocr_flow
        and "Self.processOutput(request, using: processor)" in manual_ocr_flow
        and "self.document.renderRevision == request.revision" in manual_ocr_flow
        and "self.performManualOCR(" in manual_ocr_flow
        and "image: image" in manual_ocr_flow
        and "manualOCRCoordinator.invalidate" in editor_store,
        "manual.editor_render_or_revision_integration_missing",
        "manual.editor_uses_final_render_and_revision_guard",
        failures,
        observations,
    )
    require(
        "let writer = ClipboardPasteboardWriter()" in editor_store
        and "Task { @MainActor" in editor_store
        and "_ = try await writer.writePlainText(text)" in editor_store
        and "func copyManualOCRText(\n        pasteboard: any ClipboardPasteboardWriting"
        in editor_store
        and "ClipboardBrokerClient.shared" in pasteboard_writer
        and "func writePreparedItems(" in pasteboard_writer
        and "lease = try await broker.write(request)" in pasteboard_writer
        and "ClipboardPasteboardWriteFailure" not in editor_store + pasteboard_writer
        and "snapshotItems()" not in editor_store + pasteboard_writer
        and "NSPasteboard.general" not in editor_store + pasteboard_writer,
        "manual.copy_safe_writer_or_failure_check_missing",
        "manual.copy_uses_async_broker_with_explicit_test_injection",
        failures,
        observations,
    )
    require(
        "ScreenshotManualOCRResultPanel" in editor_view
        and "ScreenshotManualOCRProgressOverlay" in editor_view
        and "ScreenshotManualOCRPanelLayout.size(for:" in editor_view
        and "ScreenshotFloatingPanelLayout.frame" in editor_view
        and "ScreenshotDesignTokens.ocrPanelSize" in editor_ocr_views
        and "case .result, .failed:" in editor_ocr_views,
        "manual.result_or_locking_ui_missing",
        "manual.result_edit_copy_close_and_locking_ui_present",
        failures,
        observations,
    )
    for test_name in (
        "testManualOCRPublishesOnlyMatchingRevisionResult",
        "testManualOCRCancellationWinsOverLateRecognition",
        "testManualOCRTimeoutRetainsRegionForRetry",
        "testManualOCRTimeoutUnlocksWithoutWaitingForUncooperativeRecognizerAndDropsLateResult",
        "testEditorManualOCRUsesCompositedSelectedRegionAndPixelRevisionInvalidatesResult",
        "testEditorManualOCRClickRecognizesEntireCurrentCrop",
        "testEditorManualOCRCopyFailureDoesNotRollbackAndReportsFailure",
    ):
        require(
            test_name in app_tests,
            f"manual.test_missing:{test_name}",
            f"manual.test_present:{test_name}",
            failures,
            observations,
        )

    if not failures:
        selected_tests = [
            "LocalVisionOCRServiceTests",
            "ScreenshotAppStateTests/testManualOCRPublishesOnlyMatchingRevisionResult",
            "ScreenshotAppStateTests/testManualOCRCancellationWinsOverLateRecognition",
            "ScreenshotAppStateTests/testManualOCRTimeoutRetainsRegionForRetry",
            "ScreenshotAppStateTests/testManualOCRTimeoutUnlocksWithoutWaitingForUncooperativeRecognizerAndDropsLateResult",
            "ScreenshotAppStateTests/testEditorManualOCRUsesCompositedSelectedRegionAndPixelRevisionInvalidatesResult",
            "ScreenshotAppStateTests/testEditorManualOCRClickRecognizesEntireCurrentCrop",
            "ScreenshotAppStateTests/testEditorManualOCRCopyFailureDoesNotRollbackAndReportsFailure",
            "ScreenshotHistoryActionServiceTests/testRetryWhileRecordIsRunningReturnsAlreadyRunningWithoutRevertingDatabaseState",
        ]
        command = [
            "xcodebuild",
            "-project",
            "apps/Blocks/Blocks.xcodeproj",
            "-derivedDataPath",
            "/tmp/blocks-p15c-derived-data",
            "-scheme",
            "BlocksAppTests",
            "-destination",
            "platform=macOS",
            "CODE_SIGNING_ALLOWED=NO",
        ]
        command.extend(
            f"-only-testing:BlocksAppTests/{test}" for test in selected_tests
        )
        command.extend(["test", "-quiet"])
        try:
            completed = subprocess.run(
                command,
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=240,
                check=False,
            )
            if completed.returncode == 0:
                observations.append("xctest.shared_and_manual_ocr_pass")
            else:
                output = (
                    completed.stdout + "\n" + completed.stderr
                ).strip().splitlines()
                failures.append("xctest.failed:" + " | ".join(output[-15:]))
        except subprocess.TimeoutExpired:
            failures.append("xctest.timeout:240s")

    payload = {
        "gate": "P15-C",
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
