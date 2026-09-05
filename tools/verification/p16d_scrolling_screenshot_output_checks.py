#!/usr/bin/env python3
"""P16-D delayed output, cleanup, and tall-image OCR gate."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def main() -> int:
    failures: list[dict[str, object]] = []
    capture = read("apps/Blocks/BlocksApp/Models/ScreenshotCapture.swift")
    store = read("apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift")
    editor = read("apps/Blocks/BlocksApp/Features/Screenshot/Editor/ScreenshotEditorStore.swift")
    ocr = read("apps/Blocks/BlocksApp/Features/OCR/LocalVisionOCRService.swift")
    tests = read("apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift")
    app_tests = read("apps/Blocks/BlocksAppTests/ScrollingScreenshotAppTests.swift")
    ocr_tests = read("apps/Blocks/BlocksAppTests/LocalVisionOCRServiceTests.swift")

    required = {
        "deferred_capture_contract": (capture + store, [
            "defersOutputUntilEditorCompletion",
            "scrollingSessionID",
            "capture.editingContext == nil",
            "!capture.defersOutputUntilEditorCompletion",
            "capture.editingContext?.supportsRangeExpansion != true",
            "finishDeferredScrollingSession",
            "finishScrollingEditingSession",
        ]),
        "editor_terminal_contract": (editor, ["allowsDirectImageCopy = !capture.defersOutputUntilEditorCompletion", "closesAfterSuccessfulSave = capture.defersOutputUntilEditorCompletion"]),
        "exactly_once_test": (tests, [
            "testScrollingCaptureDefersClipboardAndHistoryUntilEditorCompletes",
            "testScrollingEditorCompletionTerminatesUnderlyingSessionExactlyOnce",
            "testScrollingEditorDiscardTerminatesUnderlyingSessionWithoutOutput",
        ]),
        "finalized_artifact_reuse": (tests, ["testFinalOutputEncodesOneArtifactOffMainActorAndSharesItAcrossSinks"]),
        "pasteboard_handoff_lifecycle": (tests, [
            "testScreenshotPasteboardArtifactStorePreservesNewestPreviousLaunchHandoffAtInitialization",
            "testScreenshotPasteboardNextWriteRemovesPreviousHandoffFile",
            "testScreenshotPasteboardCleanupDiagnosticDoesNotExposeArtifactPath",
        ]),
        "gui_file_permissions": (tests, ["testEditorSecureFileWriterCreatesPrivateFileAndPreservesExistingPermissions"]),
        "secure_cleanup_test": (app_tests, ["testDiskBackedSessionAssemblesTopToBottomPixelsAndCleansSecureStrips", "testCancellationRequiresConfirmationAndDeletesAllTemporaryContent"]),
        "tall_ocr": (ocr + ocr_tests, ["maximumTileHeight", "tileOverlap", "testTallImageUsesOverlappingTilesAndDeduplicatesBoundaryLines"]),
    }
    for name, (source, markers) in required.items():
        missing = [marker for marker in markers if marker not in source]
        if missing:
            failures.append({"check": name, "missing": missing})

    if not failures:
        selected = [
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testScrollingCaptureDefersClipboardAndHistoryUntilEditorCompletes",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testScrollingEditorCompletionTerminatesUnderlyingSessionExactlyOnce",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testScrollingEditorDiscardTerminatesUnderlyingSessionWithoutOutput",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testFinalOutputEncodesOneArtifactOffMainActorAndSharesItAcrossSinks",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testScreenshotPasteboardArtifactStorePreservesNewestPreviousLaunchHandoffAtInitialization",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testScreenshotPasteboardNextWriteRemovesPreviousHandoffFile",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testScreenshotPasteboardCleanupDiagnosticDoesNotExposeArtifactPath",
            "-only-testing:BlocksAppTests/ScreenshotAppStateTests/testEditorSecureFileWriterCreatesPrivateFileAndPreservesExistingPermissions",
            "-only-testing:BlocksAppTests/ScrollingScreenshotAppTests",
            "-only-testing:BlocksAppTests/LocalVisionOCRServiceTests/testTallImageUsesOverlappingTilesAndDeduplicatesBoundaryLines",
        ]
        with tempfile.TemporaryDirectory(prefix="blocks-p16d-") as derived:
            result = subprocess.run(
                [
                    "xcodebuild", "-quiet", "-project", str(PROJECT),
                    "-scheme", "BlocksAppTests", "-derivedDataPath", derived,
                    "-destination", "platform=macOS", "CODE_SIGNING_ALLOWED=NO", "test",
                    *selected,
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=300,
                check=False,
            )
        if result.returncode:
            failures.append({"check": "output_xctest", "tail": result.stdout.splitlines()[-40:]})

    print(json.dumps({
        "gate": "P16-D",
        "status": "fail" if failures else "pass",
        "failures": failures,
        "observations": {"pre_editor_sinks": 0, "completed_sink_commits": 1, "temporary_permissions": "0600"},
    }, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
