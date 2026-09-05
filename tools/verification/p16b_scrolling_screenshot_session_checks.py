#!/usr/bin/env python3
"""P16-B scrolling session, recovery, and terminal-state gate."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from collections import Counter
from contextlib import nullcontext
from pathlib import Path

from verification_build_helpers import run_controlled_subprocess, run_controlled_xcode_test


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"
SESSION = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotSessionCoordinator.swift"
SESSION_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotSessionSupport.swift"
VISION_ALIGNER = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotVisionAligner.swift"
CAPTURE = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotCaptureCoordinator.swift"
SCHEDULING = CAPTURE.with_name("ScrollingScreenshotCaptureScheduling.swift")
TERMINATION = CAPTURE.with_name("ScrollingScreenshotCaptureTermination.swift")
CAPTURE_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScrollingScreenshotCaptureSupport.swift"
FRAME_SOURCE = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Capture/ScreenCaptureKitScrollingFrameSource.swift"
TESTS = ROOT / "apps/Blocks/BlocksAppTests/ScrollingScreenshotAppTests.swift"


def validate_test_results(summary: dict, tree: dict, expected: set[str]) -> dict:
    """A successful runner is not proof that every requested test ran."""
    cases: list[tuple[str, str]] = []

    def visit(value: object) -> None:
        if isinstance(value, dict):
            identifier = value.get("nodeIdentifier", "")
            if value.get("nodeType") == "Test Case" and isinstance(identifier, str) and identifier.startswith("ScrollingScreenshotAppTests/"):
                cases.append((identifier.split("/", 1)[1].removesuffix("()"), value.get("result", "")))
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(tree)
    names = [name for name, _ in cases]
    counts = Counter(result for _, result in cases)
    allowed_skips = {"testNearEffectiveLimitResourceProfile", "testNearEffectiveLimitHistoryCommitResourceProfile"}
    unexpected_results = [name for name, result in cases if result != "Passed" and not (result == "Skipped" and name in allowed_skips)]
    checks = {
        "expected_cases_present": bool(expected) and set(names) == expected,
        "no_duplicate_cases": len(names) == len(set(names)),
        "only_resource_opt_in_skips": not unexpected_results,
        "summary_matches_cases": (
            summary.get("totalTestCount") == len(cases)
            and summary.get("passedTests") == counts["Passed"]
            and summary.get("skippedTests") == counts["Skipped"]
            and summary.get("failedTests") == 0
        ),
    }
    return {"ok": all(checks.values()), "checks": checks, "case_count": len(cases),
            "skipped": sorted(name for name, result in cases if result == "Skipped"),
            "missing": sorted(expected - set(names)), "unexpected_results": unexpected_results}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static-only", action="store_true", help="Check source contracts without building or launching a test host.")
    parser.add_argument("--derived-data", type=Path, help="Reuse an explicit test-build cache; never the installed App directory.")
    args = parser.parse_args()
    failures: list[dict[str, object]] = []
    runtime: dict[str, object] = {"status": "not_run"}
    checks = {
        SESSION: [
            "actor ScrollingScreenshotSessionCoordinator",
            "removeAbandonedSessions",
            "Task.checkCancellation()",
            "invalidCompositeCoverage",
            "hasContiguousCoverage(",
            "private struct DeferredFooter",
            "func finishEditing(",
            "func retryCleanup()",
            "func resourceMetrics()",
        ],
        CAPTURE: [
            "latestRuntimeState.acceptsFinishAction", "latestRuntimeState",
            "frameSettleDelay",
            "recoverySampleDelay",
            "motionSampleInterval",
            "frameDemands: [UInt64: ScrollingScreenshotFrameDemand]",
            "scheduleRecoverySample()",
            "latestCaptureRequestSequence", "markFrameEvaluated(through:",
            ".resumeValidation",
            "func finishFromAction", "func cancelFromAction",
        ],
        SCHEDULING: [
            "extension ScrollingScreenshotCaptureCoordinator",
            "func startFrameSourceStartDeadline(", "func startFirstCompleteFrameWatchdog(",
            "func installScrollMonitor(", "func startActiveHealthMonitoring(",
            "func scheduleMotionSampleIfNeeded(", "func scheduleSettledFrameEvaluation(",
            "captureInputIntent", "hasPendingCaptureAttempt",
            "func resetPossibleEndWork(", "func cancelPossibleEndResetWork(",
        ],
        TERMINATION: [
            "extension ScrollingScreenshotCaptureCoordinator",
            "func requestFinish(", "func requestCancel(", "func cancelConfirmed(",
            "func fail(", "waitForFramePipelineDrain", "func stopFrameSourceBounded(",
            "func completeFrameSourceStop(", "func teardownSurfaces(",
        ],
        CAPTURE_SUPPORT: [
            "struct ScrollingFrameSamplingGate", "struct ScrollingScreenshotTerminalGate",
            "var acceptsFinishAction: Bool", "mutating func apply(_ snapshot:", "case .recovering",
            "shouldIngestIncomingFrameImmediately",
            "acceptsCallback(generation:", "markFinalizing(generation:",
            "markEditing(generation:", "claim(", "ScrollingScreenshotHealthChecker",
            "enum ScrollingScreenshotFrameDemand", "func issueFrameDemand(",
            "frameSource.requestFrame(generation: generation, requestID: requestID)",
            "frameSource.cancelFrameRequests(", "func waitForFramePipelineDrain(",
            "case .leftMouseDragged", "requiresPointerInsideSelection",
        ],
        SESSION_SUPPORT: [
            "enum ScrollingScreenshotSessionError", "struct ScrollingScreenshotResourceSampler",
            "struct ScrollingScreenshotRuntimeSnapshot", "enum ScrollingScreenshotIngestEvent",
            "enum ScrollingScreenshotCompositeSupport", "posixPermissions: 0o600",
            "static func hasContiguousCoverage",
        ],
        VISION_ALIGNER: [
            "struct ScrollingScreenshotVisionAligner", "VNTranslationalImageRegistrationRequest",
            "horizontalShift:", "confidence:",
        ],
        FRAME_SOURCE: [
            "final class ScrollingFrameBridgeBuffer", "frameCapacity", "pendingFrames",
            "func begin(generation:", "func offer(", "func request(generation:",
            "requestID:", "func cancelRequests(", "func cancelFrameRequests(",
            "func invalidate(generation:", "SCFrameStatus.complete", "queueDepth = 6",
        ],
        TESTS: [
            "testDiskBackedSessionAssemblesTopToBottomPixelsAndCleansSecureStrips",
            "testFinalizationKeepsSessionIdentityUntilEditorTerminalWins",
            "testCancellationRequiresConfirmationAndDeletesAllTemporaryContent",
            "testActionFinishIsAcceptedOnlyWhileCaptureCanBeFinalized",
            "testCaptureInputIntentSamplesEitherWheelDirectionAndSupportedKeyboardWithoutReadingText",
            "testKeyboardScrollingDoesNotRequirePointerInsideSelection",
            "testFrameSamplingGateSeedsImmediatelyThenRequiresCaptureInput",
            "testFrameBridgeBufferSeedsImmediatelyThenWaitsForAFreshRequestedSurface",
            "testFrameBridgeBufferDeliversOrderedFutureFramesForQueuedDemands",
            "testFrameBridgeBufferCancelsCoalescedDemandWithoutConsumingAFutureFrame",
            "testPauseCancelsPendingFrameSourceRequestsBeforeResume",
            "testFrameBridgeBufferRejectsOldGenerationAfterNewStreamStarts",
            "testTerminalGateUsesFirstTerminalAndMakesOldSessionStructuredStale",
            "testVisionAlignerProducesConsensusForTranslatedViewport",
            "testVisionAlignerRejectsReverseViewportMovement",
            "testReverseFramesRecoverAutomaticallyWithoutAppendingInvalidContent",
            "testThirdUnresolvedReverseFramePausesAndResumeRestartsRecoveryBudget",
            "testResumeAnchorValidationStaysPausedUntilLastConsistentAnchorIsReestablished",
            "testResumeHealthCheckerIsInjectableAndReceivesFrozenCaptureGeometry",
            "testCleanupFailureIsDiagnosableAndCanBeRetriedWithoutLosingSessionState",
            "testResourceMetricsExposeRSSDiskAndStageDurationsWithoutPaths",
            "testReturningToLastAcceptedFrameCompletesRecoveryWithoutStartingEndCountdown",
            "testInsufficientOverlapUsesStableRecoveryBudgetBeforePausing",
            "testBufferedFramesFromOneGestureConsumeOneRecoveryAttempt",
            "testLaterStableFrameInOneGestureRecoversWithoutPausing",
            "testThirdGestureChecksLaterStableFrameBeforeCommittingPause",
            "testMediumLongImageFinalizationCompletesWithinResourceBudget",
            "testNearEffectiveLimitResourceProfile",
            "testNearEffectiveLimitHistoryCommitResourceProfile",
            "testBrowserRenderedFramesStitchWithoutMissingOrDuplicatedSeams",
            "testBrowserRenderedPageDownSequenceMatchesIndependentGroundTruthPixelForPixel",
            "testFixedHeaderAndFooterPixelsAreEachStoredOnce",
            "testLateFixedFooterThenDynamicFooterLeavesNoTransparentGap",
            "testScrollingHUDAndSelectionPanelsDoNotRequireApplicationActivation",
        ],
    }
    for path, markers in checks.items():
        source = path.read_text(encoding="utf-8") if path.exists() else ""
        missing = [marker for marker in markers if marker not in source]
        if missing:
            failures.append({"check": str(path.relative_to(ROOT)), "missing": missing})

    capture_source = CAPTURE.read_text(encoding="utf-8") if CAPTURE.exists() else ""
    session_source = SESSION.read_text(encoding="utf-8") if SESSION.exists() else ""
    capture_support_source = CAPTURE_SUPPORT.read_text(encoding="utf-8") if CAPTURE_SUPPORT.exists() else ""
    scheduling_source = SCHEDULING.read_text(encoding="utf-8") if SCHEDULING.exists() else ""
    termination_source = TERMINATION.read_text(encoding="utf-8") if TERMINATION.exists() else ""
    capture_implementation = "\n".join([capture_source, scheduling_source, termination_source])
    if "case .reverse:" in capture_implementation or "scrollIntent(for:" in capture_implementation:
        failures.append({"check": "input_must_not_directly_pause_from_direction"})
    if "maximumAutomaticRecoveryAttempts = 3" not in session_source:
        failures.append({"check": "automatic_recovery_budget", "expected": 3})
    if len(capture_source.splitlines()) > 700 or len(session_source.splitlines()) > 600:
        failures.append({"check": "scrolling_coordinators_must_keep_support_responsibilities_split"})
    if len(scheduling_source.splitlines()) > 700 or len(termination_source.splitlines()) > 700:
        failures.append({"check": "scrolling_capture_extensions_must_remain_bounded"})
    if "struct ScrollingScreenshotTerminalGate" in capture_implementation or "struct ScrollingScreenshotResourceSampler" in session_source:
        failures.append({"check": "scrolling_support_types_must_not_drift_back_into_coordinators"})
    if "struct ScrollingScreenshotTerminalGate" not in capture_support_source:
        failures.append({"check": "capture_support_module_missing_terminal_gate"})
    motion_source = scheduling_source.split("private func scheduleMotionSampleIfNeeded()", 1)[-1].split(
        "private func scheduleSettledFrameEvaluation()", 1
    )[0]
    settled_source = scheduling_source.split("private func scheduleSettledFrameEvaluation()", 1)[-1].split(
        "func scheduleRecoverySample", 1
    )[0]
    if "guard !isManuallyPaused, motionSamplingTask == nil" not in motion_source:
        failures.append({"check": "continuous_input_must_use_bounded_motion_sampling"})
    if "settledFrameEvaluationTask?.cancel()" not in settled_source:
        failures.append({"check": "continuous_input_must_also_capture_settled_frame"})
    demand_source = capture_support_source.split("func issueFrameDemand", 1)[-1].split(
        "func waitForFramePipelineDrain", 1
    )[0]
    if "frameDemands.count < Self.maximumPendingFrameDemands" not in demand_source \
            or "frameDemands[requestID] = demand" not in demand_source:
        failures.append({"check": "frame_demand_must_use_bounded_request_identity_map"})
    receive_source = capture_support_source.split("private func process(", 1)[-1].split(
        "func issueFrameDemand", 1
    )[0]
    if "frameDemands.removeValue(forKey: requestID)" not in receive_source:
        failures.append({"check": "completed_frame_must_match_exact_request_identity"})
    if "frameDemands.removeFirst()" in receive_source:
        failures.append({"check": "completed_frame_must_not_consume_unrelated_fifo_demand"})
    if "removePendingDemands" not in demand_source or "cancelFrameRequests" not in demand_source:
        failures.append({"check": "coalesced_frame_demands_must_cancel_source_requests"})
    frame_source = FRAME_SOURCE.read_text(encoding="utf-8") if FRAME_SOURCE.exists() else ""
    if "pendingFrames" not in frame_source or "frameCapacity: Int = 4" not in frame_source:
        failures.append({"check": "frame_source_must_retain_bounded_bridge_frames"})
    if "$0.sequence > request.minimumSequence" not in frame_source \
            or "$0.sequence > lastDeliveredSequence" not in frame_source:
        failures.append({"check": "frame_source_must_deliver_ordered_post_demand_surfaces"})

    if not failures and not args.static_only:
        try:
            derived_context = nullcontext(str(args.derived_data.resolve())) if args.derived_data else tempfile.TemporaryDirectory(prefix="blocks-p16b-")
            with derived_context as derived:
                command = [
                        "xcodebuild", "-quiet", "-project", str(PROJECT),
                        "-scheme", "BlocksAppTests", "-derivedDataPath", derived,
                        "-destination", "platform=macOS,arch=arm64", "CODE_SIGNING_ALLOWED=NO",
                        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build-for-testing",
                    ]
                result = run_controlled_subprocess(command, cwd=ROOT, timeout=300, termination_grace_seconds=8)
                build_attempts = [result]
                cleanup = result.get("process_cleanup", {})
                if result.get("returncode") == 70 and cleanup.get("status") == "target_group_residual_cleaned" and cleanup.get("child_returncode") == 0:
                    # Cleanup is confirmed terminal. Retry once in the same
                    # cache; the first result stays failed in the evidence.
                    result = run_controlled_subprocess(command, cwd=ROOT, timeout=300, termination_grace_seconds=8)
                    build_attempts.append(result)
                runtime = {"status": "build_failed", "build_attempts": build_attempts}
                if not result["ok"]:
                    failures.append({"check": "scrolling_app_build_for_testing"})
                else:
                    runtime["status"] = "preparing_tests"
                    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True, timeout=15).strip()
                    if not re.fullmatch(r"\d+(?:\.\d+)*", sdk):
                        raise ValueError("Unexpected macOS SDK version")
                    # Explicitly match the requested SDK/architecture. Reused
                    # caches may also contain opt-in or diagnostic copies;
                    # they must never become the default test configuration.
                    runs = list((Path(derived) / "Build/Products").glob(f"BlocksAppTests_*_macosx{sdk}-arm64.xctestrun"))
                    if len(runs) != 1:
                        raise ValueError("Expected exactly one BlocksAppTests xctestrun")
                    bundle = Path(tempfile.mkdtemp(prefix="blocks-p16b-results-")) / "tests.xcresult"
                    test_result = run_controlled_xcode_test([
                        "xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(runs[0]),
                        "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(bundle),
                        "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                        "-default-test-execution-time-allowance", "60",
                        "-maximum-test-execution-time-allowance", "120",
                        "-only-testing:BlocksAppTests/ScrollingScreenshotAppTests",
                    ], cwd=ROOT, timeout=300, termination_grace_seconds=8)
                    runtime = {"status": "test_failed", "build_attempts": build_attempts, "result_bundle": str(bundle), "runner": test_result}
                    if not test_result["ok"]:
                        failures.append({"check": "scrolling_app_xctest"})
                    else:
                        runtime["status"] = "validating_results"
                        summary = json.loads(subprocess.check_output([
                            "xcrun", "xcresulttool", "get", "test-results", "summary",
                            "--path", str(bundle), "--compact",
                        ], text=True, timeout=30))
                        runtime["summary"] = summary
                        tree = json.loads(subprocess.check_output([
                            "xcrun", "xcresulttool", "get", "test-results", "tests",
                            "--path", str(bundle), "--compact",
                        ], text=True, timeout=30))
                        expected = set(re.findall(r"^    func (test\w+)\(", TESTS.read_text(encoding="utf-8"), re.MULTILINE))
                        validation = validate_test_results(summary, tree, expected)
                        runtime["case_validation"] = validation
                        if not validation["ok"]:
                            failures.append({"check": "scrolling_app_xctest_results_incomplete"})
                        else:
                            runtime["status"] = "completed"
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            runtime["failed_phase"] = runtime["status"]
            runtime["status"] = "runner_error"
            failures.append({"check": "scrolling_app_runner_error", "detail": str(error)})

    print(json.dumps({
        "gate": "P16-B",
        "status": "fail" if failures else "pass",
        "failures": failures,
        "verification_scope": "static_only" if args.static_only else "static_and_scrolling_xctest",
        "runtime": runtime,
        "observations": {
            "terminal_rule": "first-terminal-wins-with-generation-isolation",
            "frame_queue": "bounded-post-demand-bridge-with-exact-request-identity",
        },
    }, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
