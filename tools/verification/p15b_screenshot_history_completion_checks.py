#!/usr/bin/env python3
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    source = ROOT / path
    return source.read_text(encoding="utf-8") if source.exists() else ""


coordinator = read(
    "apps/Blocks/BlocksApp/Features/Screenshot/Output/ScreenshotFinalOutputCoordinator.swift"
)
history = read(
    "apps/Blocks/BlocksApp/Features/Screenshot/Output/ScreenshotHistoryCoordinator.swift"
)
store = read("apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift")
editor = read("apps/Blocks/BlocksApp/Features/Screenshot/Editor/ScreenshotEditorStore.swift")
pasteboard = read(
    "apps/Blocks/BlocksApp/Features/Screenshot/Output/ScreenshotPasteboardWriter.swift"
)
live_capture = read("apps/Blocks/BlocksApp/Services/ClipboardLiveCaptureService.swift")
autopaste = read("apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift")
tests = read("apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift")
broker_protocol = read("apps/Blocks/BlocksCore/ClipboardBrokerProtocol.swift")
broker_app_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted((ROOT / "apps/Blocks/BlocksApp").rglob("*.swift"))
    if "ClipboardBroker" in path.read_text(encoding="utf-8")
)

required = {
    "independent_sinks": (
        coordinator,
        ["ScreenshotFinalOutputCoordinator", "pasteboardStatus", "archiveStatus", "isTerminal"],
    ),
    "atomic_repository_adapter": (
        history,
        ["ScreenshotHistoryCommitRequest", "commitScreenshotHistory", "automaticallyRecognizesText"],
    ),
    "terminal_integration": (
        store,
        [
            "completion: @escaping (ScreenshotEditorOutcome) async -> Void",
            "case let .completed(image)",
            "let result = await self.finalOutputCoordinator.finalize",
            "recordFinalOutputStatus",
        ],
    ),
    "editor_does_not_own_final_copy": (
        editor,
        ["onComplete(image.nsImage)", "case .complete"],
    ),
    "self_write_is_consumed_once": (
        pasteboard + live_capture + autopaste + broker_protocol + broker_app_sources,
        [
            "ClipboardPasteboardWriteLease",
            "generation",
            "validate",
            "observe",
        ],
    ),
    "isolated_screenshot_pasteboard": (
        pasteboard + broker_protocol + broker_app_sources + tests,
        [
            "ClipboardBroker",
            "await",
            "testScreenshotPasteboardFailure",
            "DoesNotRollback",
            "testScreenshotPasteboardPermissionFailurePreventsPublicationAndRemovesArtifact",
        ],
    ),
    "single_finalized_artifact": (
        coordinator + history + pasteboard + tests,
        [
            "FinalizedScreenshotArtifact",
            "Task.detached",
            "artifact: FinalizedScreenshotArtifact",
            "testFinalOutputEncodesOneArtifactOffMainActorAndSharesItAcrossSinks",
        ],
    ),
    "behavior_tests": (
        tests,
        [
            "testFinalOutputKeepsPasteboardAndHistoryFailuresIndependent",
            "testFinalOutputStillCompletesWhenBothSinksFail",
            "testFinalOutputArchivesScreenshotOriginAndPreservesAutomaticOCRPreference",
            "testFinalOutputTreatsDisabledClipboardArchiveAsIgnoredInsteadOfFailure",
            "testStoreWritesHistoryOnlyAfterCompletedEditorOutcome",
            "testEditorCompletionWaitsForFinalOutputBeforeReturning",
            "testStoreDoesNotWriteHistoryForCancelledEditorOutcome",
            "testNoEditorActionCommitsHistoryWithoutRequiringClipboardCopy",
            "testScreenshotPasteboard",
        ],
    ),
}

failures = []
for name, (source, markers) in required.items():
    missing = [marker for marker in markers if marker not in source]
    if missing:
        failures.append({"check": name, "missing": missing})

for forbidden in (
    "snapshotItems()",
    "replaceItems(originalItems)",
    "rollbackSucceeded",
    "NSPasteboard.general",
):
    if forbidden in pasteboard + autopaste:
        failures.append({
            "check": "isolated_screenshot_pasteboard",
            "forbidden": forbidden,
        })

available_test_names = set(re.findall(r"\bfunc\s+(test\w+)\s*\(", tests))


def matching_test_name(*fragments: str) -> str | None:
    return next(
        (
            name for name in sorted(available_test_names)
            if all(fragment in name for fragment in fragments)
        ),
        None,
    )


required_test_names = [
    "testFinalOutputKeepsPasteboardAndHistoryFailuresIndependent",
    "testFinalOutputStillCompletesWhenBothSinksFail",
    "testFinalOutputArchivesScreenshotOriginAndPreservesAutomaticOCRPreference",
    "testFinalOutputTreatsDisabledClipboardArchiveAsIgnoredInsteadOfFailure",
    "testFinalOutputReportsUnavailableHistoryRepository",
    "testStoreWritesHistoryOnlyAfterCompletedEditorOutcome",
    "testEditorCompletionWaitsForFinalOutputBeforeReturning",
    "testStoreDoesNotWriteHistoryForCancelledEditorOutcome",
    "testNoEditorActionCommitsHistoryWithoutRequiringClipboardCopy",
    "testScreenshotPasteboardPermissionFailurePreventsPublicationAndRemovesArtifact",
    "testFinalOutputEncodesOneArtifactOffMainActorAndSharesItAcrossSinks",
]
dynamic_test_names = [
    matching_test_name("ScreenshotPasteboardFailure", "DoesNotRollback"),
]
missing_test_names = [
    name for name in required_test_names
    if name not in available_test_names
] + [
    "test*ScreenshotPasteboardFailure*DoesNotRollback*"
    for name in dynamic_test_names
    if name is None
]
if missing_test_names:
    failures.append({"check": "behavior_test_names", "missing": missing_test_names})

test_names = required_test_names + [
    name for name in dynamic_test_names if name is not None
]
command = [
    "xcodebuild",
    "-project",
    "apps/Blocks/Blocks.xcodeproj",
    "-derivedDataPath",
    "/tmp/blocks-p15b-derived-data",
    "-scheme",
    "BlocksAppTests",
    "-destination",
    "platform=macOS",
    "CODE_SIGNING_ALLOWED=NO",
]
for test_name in test_names:
    command.append(
        f"-only-testing:BlocksAppTests/ScreenshotAppStateTests/{test_name}"
    )
command.extend(["test", "-quiet"])

test_result = None
if not failures:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=240,
            check=False,
        )
        test_result = "pass" if completed.returncode == 0 else "fail"
        if completed.returncode != 0:
            output = (completed.stdout + "\n" + completed.stderr).strip().splitlines()
            failures.append({"check": "xctest", "tail": output[-30:]})
    except subprocess.TimeoutExpired:
        test_result = "timeout"
        failures.append({"check": "xctest_timeout", "seconds": 240})

print(json.dumps({
    "gate": "P15-B",
    "status": "fail" if failures else "pass",
    "failures": failures,
    "observations": {
        "xctest": test_result,
        "terminal_rule": "completed_only",
        "sink_rule": "pasteboard_clipboard_archive_independent",
    },
}, ensure_ascii=False, indent=2))
raise SystemExit(1 if failures else 0)
