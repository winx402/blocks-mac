import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

#if LOCAL_OCR_PACKAGE
@testable import BlocksOCR
#else
@testable import Blocks
#endif

final class LocalVisionOCRServiceTests: XCTestCase {
    func testTimingSnapshotSinglePassAndSupportedCacheHit() async throws {
        let recorder = TimingSnapshotRecorder(); let clock = FakeOCRTimingClock()
        let adapter = RecordingLocalVisionOCRAdapter(supportedLanguages: ["en-US"], observations: [observation(text: "fixture", x: 0.1, y: 0.8)])
        let service = LocalVisionOCRService(adapter: adapter, timingClock: clock, timingObserver: { recorder.append($0) })
        _ = try await service.recognizeText(in: try makeImage())
        _ = try await service.recognizeText(in: try makeImage())
        let snapshots = recorder.values
        XCTAssertEqual(snapshots.count, 2); XCTAssertEqual(snapshots[0].terminal, .success); XCTAssertEqual(snapshots[0].requestCount, 1)
        XCTAssertEqual(snapshots[0].passes.map(\.ordinal), [1]); XCTAssertFalse(snapshots[0].supportedLanguagesCacheHit); XCTAssertTrue(snapshots[1].supportedLanguagesCacheHit)
        XCTAssertTrue(snapshots[0].passes.allSatisfy { $0.adapterTotalMilliseconds >= $0.unattributedMilliseconds })
    }

    func testTimingSnapshotTracksFallbackPassOrdinals() async throws {
        let recorder = TimingSnapshotRecorder()
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [[observation(text: "x", x: 0.1, y: 0.8, confidence: 0.1)], [observation(text: "better", x: 0.1, y: 0.8, confidence: 0.9)]])
        let service = LocalVisionOCRService(adapter: adapter, timingClock: FakeOCRTimingClock(), timingObserver: { recorder.append($0) })
        _ = try await service.recognizeText(in: try makeImage())
        let snapshot = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(snapshot.requestCount, 2); XCTAssertEqual(snapshot.passes.map(\.ordinal), [1, 2]); XCTAssertEqual(snapshot.passes.map(\.passKind), ["primary", "correction_fallback"])
    }

    func testTimingSnapshotRecordsFailureTerminal() async throws {
        let recorder = TimingSnapshotRecorder()
        let service = LocalVisionOCRService(adapter: FailingThenSuccessfulLanguagesOCRAdapter(supportedLanguages: ["en-US"], observations: []), timingClock: FakeOCRTimingClock(), timingObserver: { recorder.append($0) })
        do { _ = try await service.recognizeText(in: try makeImage()); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(recorder.values.first?.terminal, .failure)
    }

    func testTimingStagesUseInjectedClockAndConservePassTotal() async throws {
        let recorder = TimingSnapshotRecorder()
        let service = LocalVisionOCRService(
            adapter: StageTimingLocalVisionOCRAdapter(),
            timingClock: FakeOCRTimingClock(),
            timingObserver: { recorder.append($0) }
        )

        _ = try await service.recognizeText(in: try makeImage())

        let pass = try XCTUnwrap(recorder.values.first?.passes.first)
        XCTAssertGreaterThan(pass.requestConstructionMilliseconds, 0)
        XCTAssertGreaterThan(pass.queueWaitMilliseconds, 0)
        XCTAssertGreaterThan(pass.handlerConstructionMilliseconds, 0)
        XCTAssertGreaterThan(pass.performMilliseconds, 0)
        XCTAssertGreaterThan(pass.mappingMilliseconds, 0)
        XCTAssertEqual(
            pass.adapterTotalMilliseconds,
            pass.requestConstructionMilliseconds + pass.queueWaitMilliseconds
                + pass.handlerConstructionMilliseconds + pass.performMilliseconds
                + pass.mappingMilliseconds + pass.unattributedMilliseconds,
            accuracy: 0.0001
        )
    }

    func testTimingCancellationPublishesExactlyOneTerminalSnapshot() async throws {
        let recorder = TimingSnapshotRecorder()
        let adapter = ConcurrentTimingLocalVisionOCRAdapter(expectedStarts: 1)
        let service = LocalVisionOCRService(
            adapter: adapter,
            timingClock: FakeOCRTimingClock(),
            timingObserver: { recorder.append($0) }
        )
        let task = Task { try await service.recognizeText(in: try makeImage()) }

        await fulfillment(of: [adapter.started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }

        let snapshots = recorder.values
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].terminal, .cancelled)
    }

    func testTimingConcurrentSuccessAndCancellationEachPublishOnce() async throws {
        let recorder = TimingSnapshotRecorder()
        let adapter = ConcurrentTimingLocalVisionOCRAdapter()
        let service = LocalVisionOCRService(
            adapter: adapter,
            timingClock: FakeOCRTimingClock(),
            timingObserver: { recorder.append($0) }
        )
        let successfulToken = LocalVisionOCRRequestToken()
        let cancelledToken = LocalVisionOCRRequestToken()
        let image = try makeImage()
        let successful = Task { try await service.recognizeText(in: image, requestToken: successfulToken) }
        let cancelled = Task { try await service.recognizeText(in: image, requestToken: cancelledToken) }

        await fulfillment(of: [adapter.started], timeout: 1)
        adapter.complete(token: successfulToken)
        cancelledToken.cancel()
        _ = try await successful.value
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }

        let snapshots = recorder.values
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(Set(snapshots.map(\.recognitionID)).count, 2)
        XCTAssertEqual(snapshots.filter { $0.terminal == .success }.count, 1)
        XCTAssertEqual(snapshots.filter { $0.terminal == .cancelled }.count, 1)
    }
    func testLanguageConfigurationUsesOnlyPreferredSystemSupportedLanguages() async throws {
        let adapter = RecordingLocalVisionOCRAdapter(
            supportedLanguages: ["en-US", "fr-FR", "ja-JP", "zh-Hant"],
            observations: [observation(text: "fixture", x: 0.1, y: 0.8)]
        )
        let service = LocalVisionOCRService(adapter: adapter)

        _ = try await service.recognizeText(in: try makeImage())

        let configuration = try XCTUnwrap(adapter.lastConfiguration)
        XCTAssertEqual(configuration.recognitionLanguages, ["zh-Hant", "en-US", "ja-JP"])
        XCTAssertTrue(configuration.automaticallyDetectsLanguage)
        XCTAssertFalse(configuration.usesLanguageCorrection)

        _ = try await service.recognizeText(in: try makeImage())
        XCTAssertEqual(adapter.supportedLanguagesRequestCount, 1)
    }

    func testSupportedLanguagesFailureIsCachedWithoutVisionRequests() async throws {
        let adapter = FailingThenSuccessfulLanguagesOCRAdapter(
            supportedLanguages: ["en-US"],
            observations: [observation(text: "fixture", x: 0.1, y: 0.8)]
        )
        let recorder = TimingSnapshotRecorder()
        let service = LocalVisionOCRService(
            adapter: adapter,
            timingClock: FakeOCRTimingClock(),
            timingObserver: { recorder.append($0) }
        )
        let image = try makeImage()

        do {
            _ = try await service.recognizeText(in: image)
            XCTFail("Expected first supported-languages query to fail")
        } catch {
            // The cache retry behavior must not depend on the adapter error type.
        }

        do {
            _ = try await service.recognizeText(in: image)
            XCTFail("Expected cached supported-languages failure")
        } catch {
            // The second call must use the cached failure, not query Vision again.
        }
        XCTAssertEqual(adapter.supportedLanguagesRequestCount, 1)
        XCTAssertEqual(adapter.recognitionRequestCount, 0)
        XCTAssertEqual(recorder.values.map(\.supportedLanguagesCacheHit), [false, true])
    }

    func testConcurrentInitialSupportedLanguageResultsRemainPerCallBeforeFirstWriterCache() async throws {
        let adapter = ConcurrentInitialLanguagesOCRAdapter()
        let service = LocalVisionOCRService(adapter: adapter)
        let image = try makeImage()

        let first = Task { try await service.recognizeText(in: image) }
        await fulfillment(of: [adapter.firstQueryEntered], timeout: 1)
        let second = Task { try await service.recognizeText(in: image) }
        await fulfillment(of: [adapter.secondQueryEntered], timeout: 1)

        adapter.releaseFirstSuccess()
        let firstResult = try await first.value
        adapter.releaseSecondFailure()
        do {
            _ = try await second.value
            XCTFail("The second initial query must preserve its own failure")
        } catch {
            // Its failure must not be overwritten by the cache's first writer.
        }

        let cachedResult = try await service.recognizeText(in: image)
        XCTAssertEqual(firstResult.text, "fixture")
        XCTAssertEqual(cachedResult.text, "fixture")
        XCTAssertEqual(adapter.supportedLanguagesRequestCount, 2)
    }

    func testDataInputPassesImagePropertyOrientationToAdapter() async throws {
        let adapter = RecordingLocalVisionOCRAdapter(
            supportedLanguages: ["en-US"],
            observations: [observation(text: "fixture", x: 0.1, y: 0.8)]
        )
        let service = LocalVisionOCRService(adapter: adapter)
        let imageData = try makeImageData(orientation: .rightMirrored)

        _ = try await service.recognizeText(from: imageData)

        XCTAssertEqual(adapter.lastOrientation, .rightMirrored)
    }

    func testCGImageInputDefaultsOrientationToUp() async throws {
        let adapter = RecordingLocalVisionOCRAdapter(
            supportedLanguages: ["en-US"],
            observations: [observation(text: "fixture", x: 0.1, y: 0.8)]
        )
        let service = LocalVisionOCRService(adapter: adapter)

        _ = try await service.recognizeText(in: try makeImage())

        XCTAssertEqual(adapter.lastOrientation, .up)
    }

    func testTaskCancellationCancelsRequestTokenAndThrowsCancellationError() async throws {
        let adapter = CancellationHoldingLocalVisionOCRAdapter()
        let service = LocalVisionOCRService(adapter: adapter)
        let image = try makeImage()
        let task = Task {
            try await service.recognizeText(in: image)
        }

        await fulfillment(of: [adapter.started], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(adapter.didObserveCancellation)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testTallImageUsesOverlappingTilesAndDeduplicatesBoundaryLines() async throws {
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [
            [observation(text: "A", x: 0.1, y: 0.8), observation(text: "B", x: 0.1, y: 0.125)],
            [observation(text: "B", x: 0.1, y: 0.875), observation(text: "C", x: 0.1, y: 0.125)],
            [observation(text: "C", x: 0.1, y: 0.875), observation(text: "D", x: 0.1, y: 0.4)],
        ])
        var configuration = LocalVisionOCRConfiguration()
        configuration.maximumTileHeight = 4
        configuration.tileOverlap = 1
        let service = LocalVisionOCRService(adapter: adapter, configuration: configuration)

        let result = try await service.recognizeText(in: try makeImage(width: 2, height: 9))

        XCTAssertEqual(result.text, "A\nB\nC\nD")
        XCTAssertEqual(result.lineCount, 4)
        XCTAssertEqual(adapter.imageHeights, [4, 4, 3])
    }

    func testLowConfidencePrimaryUsesCorrectionFallbackOnlyWhenCoverageAndConfidenceImprove() async throws {
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [
            [observation(text: "截圏", x: 0.1, y: 0.8, confidence: 0.30)],
            [observation(text: "截图文字", x: 0.1, y: 0.8, confidence: 0.92)],
        ])
        let service = LocalVisionOCRService(adapter: adapter)

        let result = try await service.recognizeText(in: try makeImage())

        XCTAssertEqual(result.text, "截图文字")
        XCTAssertEqual(result.meanConfidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(adapter.requestConfigurations.map(\.usesLanguageCorrection), [false, true])
    }

    func testLowConfidenceFallbackCannotReplacePrimaryWithoutBetterCoverage() async throws {
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [
            [observation(text: "Blocks", x: 0.1, y: 0.8, confidence: 0.40)],
            [observation(text: "Blockz", x: 0.1, y: 0.8, confidence: 0.95)],
        ])
        let service = LocalVisionOCRService(adapter: adapter)

        let result = try await service.recognizeText(in: try makeImage())

        XCTAssertEqual(result.text, "Blocks")
        XCTAssertEqual(result.meanConfidence, 0.40, accuracy: 0.001)
    }

    func testLowConfidenceCorrectionFallbackIsNotLimitedByObservationCount() async throws {
        let lowConfidence = (0..<13).map {
            observation(
                text: "错\($0)",
                x: 0.02,
                y: 0.96 - CGFloat($0) * 0.06,
                confidence: 0.30
            )
        }
        let corrected = (0..<13).map {
            observation(
                text: "正确文字\($0)",
                x: 0.02,
                y: 0.96 - CGFloat($0) * 0.06,
                confidence: 0.92
            )
        }
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [lowConfidence, corrected])
        let service = LocalVisionOCRService(adapter: adapter)

        let result = try await service.recognizeText(in: try makeImage())

        XCTAssertTrue(result.text.contains("正确文字0"))
        XCTAssertEqual(adapter.requestConfigurations.map(\.usesLanguageCorrection), [false, true])
    }

    func testHighConfidenceChineseTextDoesNotTriggerJapanesePass() async throws {
        let adapter = RecordingLocalVisionOCRAdapter(
            supportedLanguages: ["zh-Hans", "en-US", "ja-JP"],
            observations: [
                observation(text: "截图", x: 0.1, y: 0.8, confidence: 0.95),
            ]
        )
        let service = LocalVisionOCRService(adapter: adapter)

        let result = try await service.recognizeText(in: try makeImage())

        XCTAssertEqual(result.text, "截图")
        XCTAssertEqual(adapter.recognitionRequestCount, 1)
    }

    func testTypicalVisionConfidenceForChineseDoesNotTriggerRecoveryPasses() async throws {
        let adapter = RecordingLocalVisionOCRAdapter(
            supportedLanguages: ["zh-Hans", "en-US", "ja-JP"],
            observations: [
                observation(text: "截图设置", x: 0.1, y: 0.8, confidence: 0.50),
                observation(text: "复制文字2026", x: 0.1, y: 0.6, confidence: 0.50),
            ]
        )
        let service = LocalVisionOCRService(adapter: adapter)

        let result = try await service.recognizeText(
            in: try makeImage(width: 1_600, height: 720)
        )

        XCTAssertEqual(result.lineCount, 2)
        XCTAssertEqual(adapter.recognitionRequestCount, 1)
    }

    func testLowConfidenceKanaTextUsesJapaneseRefinementWhenItImprovesCoverage() async throws {
        let adapter = SequencedLocalVisionOCRAdapter(
            supportedLanguages: ["zh-Hans", "ja-JP"],
            sequence: [
                [observation(text: "日本語テ", x: 0.1, y: 0.8, confidence: 0.75)],
                [observation(text: "日本語テスト", x: 0.1, y: 0.8, confidence: 0.92)],
            ]
        )
        let service = LocalVisionOCRService(adapter: adapter)

        let result = try await service.recognizeText(in: try makeImage())

        XCTAssertEqual(result.text, "日本語テスト")
        XCTAssertEqual(adapter.recognitionRequestCount, 2)
    }

    func testLowConfidenceKanjiTextUsesJapaneseRefinementWhenItRestoresKana() async throws {
        let adapter = SequencedLocalVisionOCRAdapter(
            supportedLanguages: ["zh-Hans", "ja-JP"],
            sequence: [
                [observation(text: "日本語設定", x: 0.1, y: 0.8, confidence: 0.55)],
                [observation(text: "日本語テスト設定", x: 0.1, y: 0.8, confidence: 0.92)],
            ]
        )
        var configuration = LocalVisionOCRConfiguration()
        configuration.fallbackConfidenceThreshold = 0
        let service = LocalVisionOCRService(
            adapter: adapter,
            configuration: configuration
        )

        let result = try await service.recognizeText(in: try makeImage())

        XCTAssertEqual(result.text, "日本語テスト設定")
        XCTAssertEqual(adapter.recognitionRequestCount, 2)
    }

    func testWideImageWithinMaximumHeightUsesSingleRecognitionRequest() async throws {
        var configuration = LocalVisionOCRConfiguration()
        configuration.maximumTileHeight = 20
        configuration.tileOverlap = 1
        configuration.fallbackConfidenceThreshold = 0
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [
            [observation(text: "A", x: 0.1, y: 0.8)],
        ])
        let service = LocalVisionOCRService(adapter: adapter, configuration: configuration)

        let result = try await service.recognizeText(in: try makeImage(width: 40, height: 4))

        XCTAssertEqual(result.lineCount, 1)
        XCTAssertEqual(adapter.imageSizes, [
            CGSize(width: 40, height: 4),
        ])
    }

    func testLowConfidenceLargeImageUsesBetterAdaptiveGridResult() async throws {
        var configuration = LocalVisionOCRConfiguration()
        configuration.fallbackConfidenceThreshold = 0
        configuration.adaptiveGridConfidenceThreshold = 0.90
        configuration.adaptiveGridMinimumWidth = 4
        configuration.adaptiveGridMinimumHeight = 4
        configuration.adaptiveGridOverlap = 0
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [
            [observation(text: "错", x: 0.1, y: 0.8, confidence: 0.30)],
            [observation(text: "左上正确", x: 0.1, y: 0.8, confidence: 0.90)],
            [observation(text: "右上正确", x: 0.1, y: 0.8, confidence: 0.90)],
            [observation(text: "左下正确", x: 0.1, y: 0.8, confidence: 0.90)],
            [observation(text: "右下正确", x: 0.1, y: 0.8, confidence: 0.90)],
        ])
        let service = LocalVisionOCRService(adapter: adapter, configuration: configuration)

        let result = try await service.recognizeText(in: try makeImage(width: 4, height: 4))

        XCTAssertTrue(result.text.contains("左上正确"))
        XCTAssertTrue(result.text.contains("右下正确"))
        XCTAssertEqual(adapter.imageSizes, [
            CGSize(width: 4, height: 4),
            CGSize(width: 2, height: 2),
            CGSize(width: 2, height: 2),
            CGSize(width: 2, height: 2),
            CGSize(width: 2, height: 2),
        ])
    }

    func testAdaptiveGridUsesOneRequestPerTileWithoutNestedRecovery() async throws {
        var configuration = LocalVisionOCRConfiguration()
        configuration.fallbackConfidenceThreshold = 0
        configuration.adaptiveGridConfidenceThreshold = 0.90
        configuration.adaptiveGridMinimumWidth = 4
        configuration.adaptiveGridMinimumHeight = 4
        configuration.adaptiveGridOverlap = 0
        let lowConfidenceTile = [
            observation(text: "low", x: 0.1, y: 0.8, confidence: 0.20),
        ]
        let adapter = SequencedLocalVisionOCRAdapter(sequence: [
            [observation(text: "baseline", x: 0.1, y: 0.8, confidence: 0.30)],
            lowConfidenceTile,
            lowConfidenceTile,
            lowConfidenceTile,
            lowConfidenceTile,
        ])
        let service = LocalVisionOCRService(adapter: adapter, configuration: configuration)

        _ = try await service.recognizeText(in: try makeImage(width: 4, height: 4))

        XCTAssertEqual(adapter.recognitionRequestCount, 5)
        XCTAssertEqual(adapter.requestConfigurations.map(\.usesLanguageCorrection), [
            false, false, false, false, false,
        ])
    }

    func testGeometricDeduplicationToleratesMinorRecognitionDifference() {
        let observations = [
            observation(text: "Blocks OCR", x: 0.1, y: 0.50, confidence: 0.70),
            observation(text: "Blocks 0CR", x: 0.1, y: 0.505, confidence: 0.93),
        ]

        let deduplicated = LocalVisionOCRService.deduplicatedObservations(observations)

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.text, "Blocks 0CR")
    }

    func testTallLatinBoxesDoNotTriggerJapaneseVerticalOrdering() {
        let boxes = [
            box(0, text: "A", x: 0.70, y: 0.18, width: 0.05, height: 0.22),
            box(1, text: "B", x: 0.30, y: 0.72, width: 0.05, height: 0.22),
            box(2, text: "C", x: 0.70, y: 0.72, width: 0.05, height: 0.22),
        ]

        XCTAssertEqual(LocalVisionOCRReadingOrder.orderedIndices(boxes), [1, 2, 0])
    }

    #if !LOCAL_OCR_PACKAGE
    @MainActor
    func testCoordinatorRunsInteractiveRequestBeforeQueuedStartupRecoveryWork() async throws {
        let adapter = HoldingPriorityLocalVisionOCRAdapter()
        let coordinator = LocalOCRCoordinator(
            service: LocalVisionOCRService(adapter: adapter)
        )
        let firstBackground = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 2, height: 2),
                context: .clipboardImage
            )
        }
        try await waitUntil { adapter.startedWidths == [2] }

        let startupRecovery = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 3, height: 2),
                context: .startupRecovery
            )
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 1
        }
        let interactive = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 4, height: 2),
                context: .editorRegion
            )
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 2
        }

        adapter.releaseNext(text: "first")
        try await waitUntil { adapter.startedWidths == [2, 4] }
        adapter.releaseNext(text: "interactive")
        try await waitUntil { adapter.startedWidths == [2, 4, 3] }
        adapter.releaseNext(text: "startup")

        _ = try await firstBackground.value
        let interactiveResult = try await interactive.value
        XCTAssertEqual(interactiveResult.text, "interactive")
        let startupResult = try await startupRecovery.value
        XCTAssertEqual(startupResult.text, "startup")
    }

    @MainActor
    func testTranslationScreenshotAdapterUsesSharedCoordinatorAndRunsBeforeQueuedPluginScreenshotWork() async throws {
        let adapter = HoldingPriorityLocalVisionOCRAdapter()
        let coordinator = LocalOCRCoordinator(service: LocalVisionOCRService(adapter: adapter))
        let firstBackground = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 2, height: 2),
                context: .clipboardImage
            )
        }
        try await waitUntil { adapter.startedWidths == [2] }

        let secondBackground = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 3, height: 2),
                context: .pluginScreenshot
            )
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 1
        }
        let translationImage = try makeImage(width: 4, height: 2)
        let translationAdapter = LocalVisionTranslationOCRAdapter(
            coordinator: coordinator
        )
        let interactive = Task {
            try await translationAdapter.recognizeText(
                in: TranslationScreenshotCapture(
                    image: NSImage(
                        cgImage: translationImage,
                        size: NSSize(width: 4, height: 2)
                    ),
                    cgImage: translationImage,
                    logicalRect: CGRect(x: 0, y: 0, width: 4, height: 2),
                    pixelSize: CGSize(width: 4, height: 2),
                    screen: nil
                ),
                requestToken: LocalVisionOCRRequestToken()
            )
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 2
        }

        adapter.releaseNext(text: "first")
        try await waitUntil { adapter.startedWidths == [2, 4] }
        adapter.releaseNext(text: "interactive")
        try await waitUntil { adapter.startedWidths == [2, 4, 3] }
        adapter.releaseNext(text: "second")

        _ = try await firstBackground.value
        let interactiveResult = try await interactive.value
        XCTAssertEqual(interactiveResult.text, "interactive")
        _ = try await secondBackground.value
    }

    @MainActor
    func testQueuedTranslationScreenshotCancellationDoesNotReachVisionOrBlockPluginWork() async throws {
        let adapter = HoldingPriorityLocalVisionOCRAdapter()
        let coordinator = LocalOCRCoordinator(
            service: LocalVisionOCRService(adapter: adapter)
        )
        let firstBackground = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 2, height: 2),
                context: .clipboardImage
            )
        }
        try await waitUntil { adapter.startedWidths == [2] }

        let plugin = Task {
            try await coordinator.recognizeText(
                in: try makeImage(width: 3, height: 2),
                context: .pluginScreenshot
            )
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 1
        }

        let translationImage = try makeImage(width: 4, height: 2)
        let translationToken = LocalVisionOCRRequestToken()
        let translationAdapter = LocalVisionTranslationOCRAdapter(
            coordinator: coordinator
        )
        let translation = Task {
            try await translationAdapter.recognizeText(
                in: TranslationScreenshotCapture(
                    image: NSImage(
                        cgImage: translationImage,
                        size: NSSize(width: 4, height: 2)
                    ),
                    cgImage: translationImage,
                    logicalRect: CGRect(x: 0, y: 0, width: 4, height: 2),
                    pixelSize: CGSize(width: 4, height: 2),
                    screen: nil
                ),
                requestToken: translationToken
            )
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 2
        }

        translationToken.cancel()
        do {
            _ = try await translation.value
            XCTFail("Expected queued translation OCR cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        try await waitUntil {
            await coordinator.pendingRequestCountForTesting() == 1
        }

        adapter.releaseNext(text: "first")
        try await waitUntil { adapter.startedWidths == [2, 3] }
        adapter.releaseNext(text: "plugin")

        _ = try await firstBackground.value
        let pluginResult = try await plugin.value
        XCTAssertEqual(pluginResult.text, "plugin")
        XCTAssertEqual(adapter.startedWidths, [2, 3])
    }
    #endif

    func testHorizontalReadingOrderGroupsRowsThenReadsLeftToRight() {
        let boxes = [
            box(0, text: "bottom-right", x: 0.32, y: 0.20, width: 0.35),
            box(1, text: "top-left", x: 0.10, y: 0.80, width: 0.35),
            box(2, text: "bottom-left", x: 0.10, y: 0.20, width: 0.35),
            box(3, text: "top-right", x: 0.32, y: 0.80, width: 0.35),
        ]

        XCTAssertEqual(
            LocalVisionOCRReadingOrder.orderedIndices(boxes),
            [1, 3, 2, 0]
        )
    }

    func testMultiColumnReadingOrderFinishesLeftColumnBeforeRightColumn() {
        let boxes = [
            box(0, text: "right-bottom", x: 0.70, y: 0.20),
            box(1, text: "left-top", x: 0.08, y: 0.82),
            box(2, text: "right-top", x: 0.70, y: 0.82),
            box(3, text: "left-bottom", x: 0.08, y: 0.20),
        ]

        XCTAssertEqual(
            LocalVisionOCRReadingOrder.orderedIndices(boxes),
            [1, 3, 2, 0]
        )
    }

    func testJapaneseVerticalReadingOrderUsesRightColumnsTopToBottom() {
        let boxes = [
            box(0, text: "左下", x: 0.30, y: 0.18, width: 0.05, height: 0.22),
            box(1, text: "右上", x: 0.72, y: 0.72, width: 0.05, height: 0.22),
            box(2, text: "左上", x: 0.30, y: 0.72, width: 0.05, height: 0.22),
            box(3, text: "右下", x: 0.72, y: 0.18, width: 0.05, height: 0.22),
        ]

        XCTAssertEqual(
            LocalVisionOCRReadingOrder.orderedIndices(boxes),
            [1, 3, 2, 0]
        )
    }

    func testRealVisionDiagnosticCorpus() async throws {
        let service = LocalVisionOCRService()
        let cases: [(name: String, lines: [String])] = [
            ("latin", ["Blocks OCR 2026", "Screenshot clipboard settings"]),
            ("simplified-chinese", ["积木工具 截图识别", "复制文字 2026"]),
            ("mixed", ["Blocks 截图 OCR 2026", "Clipboard 剪贴板 123"]),
            ("japanese", ["日本語 OCR テスト", "設定 123"]),
        ]

        for fixture in cases {
            let image = try makeTextImage(lines: fixture.lines)
            let started = ContinuousClock.now
            let result = try await service.recognizeText(in: image)
            let duration = started.duration(to: .now)
            print(
                "OCR_DIAGNOSTIC name=\(fixture.name) duration=\(duration) "
                    + "confidence=\(result.meanConfidence) text=\(result.text.debugDescription)"
            )
            XCTAssertEqual(
                normalizedOCRString(result.text),
                normalizedOCRString(fixture.lines.joined(separator: "\n")),
                fixture.name
            )
            XCTAssertLessThan(duration, .seconds(8), fixture.name)
        }
    }

    func testRealVisionSmallMixedLanguageInterfaceText() async throws {
        let expected = [
            "截图设置",
            "Blocks OCR 2026",
            "剪贴板 Clipboard",
            "翻译 Translation",
        ]
        let image = try makeTextImage(
            lines: expected,
            width: 1_405,
            height: 768,
            fontSize: 24
        )
        let started = ContinuousClock.now
        let result = try await LocalVisionOCRService().recognizeText(in: image)
        print(
            "OCR_SMALL_UI duration=\(started.duration(to: .now)) "
                + "confidence=\(result.meanConfidence) text=\(result.text.debugDescription)"
        )
        XCTAssertEqual(
            normalizedOCRString(result.text),
            normalizedOCRString(expected.joined(separator: "\n"))
        )
        XCTAssertLessThan(started.duration(to: .now), .seconds(8))
    }

    private static func observation(
        text: String,
        x: CGFloat,
        y: CGFloat,
        confidence: Float = 1
    ) -> LocalVisionOCRObservation {
        LocalVisionOCRObservation(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: 0.2, height: 0.08),
            confidence: confidence
        )
    }

    private func observation(
        text: String,
        x: CGFloat,
        y: CGFloat,
        confidence: Float = 1
    ) -> LocalVisionOCRObservation {
        Self.observation(text: text, x: x, y: y, confidence: confidence)
    }

    private func box(
        _ index: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.18,
        height: CGFloat = 0.08
    ) -> LocalVisionOCRLayoutBox {
        LocalVisionOCRLayoutBox(
            index: index,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            text: text
        )
    }

    private func makeImage(width: Int = 2, height: Int = 2) throws -> CGImage {
        if width != 2 || height != 2 {
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try XCTUnwrap(context.makeImage())
        }
        let bytes: [UInt8] = [
            255, 255, 255, 255,
            240, 240, 240, 255,
            240, 240, 240, 255,
            255, 255, 255, 255,
        ]
        let data = Data(bytes) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeTextImage(
        lines: [String],
        width: Int = 1_600,
        height: Int = 600,
        fontSize: CGFloat = 72
    ) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            NSString(string: line).draw(
                at: NSPoint(
                    x: 80,
                    y: CGFloat(height) - 140 - CGFloat(index) * 130
                ),
                withAttributes: attributes
            )
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeImageData(orientation: CGImagePropertyOrientation) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        let properties = [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary
        CGImageDestinationAddImage(destination, try makeImage(), properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true before timeout")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true before timeout")
    }

    private func normalizedOCRString(_ text: String) -> String {
        text.unicodeScalars
            .filter { !$0.properties.isWhitespace }
            .map(String.init)
            .joined()
    }
}

private final class FakeOCRTimingClock: LocalVisionOCRTimingClock, @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    func nowNanoseconds() -> UInt64 { lock.withLock { value += 1_000_000; return value } }
}

private final class TimingSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var snapshots: [LocalVisionOCRTimingSnapshot] = []
    var values: [LocalVisionOCRTimingSnapshot] { lock.withLock { snapshots } }
    func append(_ value: LocalVisionOCRTimingSnapshot) { lock.withLock { snapshots.append(value) } }
}

private final class StageTimingLocalVisionOCRAdapter: LocalVisionOCRAdapter {
    func supportedRecognitionLanguages() throws -> [String] { ["en-US"] }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        [LocalVisionOCRObservation(text: "fixture", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1))]
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingContext: LocalVisionOCRPassTimingContext?
    ) async throws -> [LocalVisionOCRObservation] {
        if let timingContext {
            let construction = timingContext.nowNanoseconds()
            timingContext.measureRequestConstruction(from: construction)
            let queue = timingContext.nowNanoseconds()
            timingContext.measureQueue(from: queue)
            let handler = timingContext.nowNanoseconds()
            timingContext.measureHandler(from: handler)
            let perform = timingContext.nowNanoseconds()
            timingContext.measurePerform(from: perform)
            let mapping = timingContext.nowNanoseconds()
            timingContext.measureMapping(from: mapping)
        }
        try requestToken.checkCancellation()
        return [LocalVisionOCRObservation(text: "fixture", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1))]
    }
}

private final class ConcurrentTimingLocalVisionOCRAdapter: LocalVisionOCRAdapter {
    private struct Pending {
        let token: LocalVisionOCRRequestToken
        let continuation: CheckedContinuation<[LocalVisionOCRObservation], Error>
    }

    let started: XCTestExpectation
    private let lock = NSLock()
    private var pending: [Pending] = []

    init(expectedStarts: Int = 2) {
        started = XCTestExpectation(description: "OCR requests reached adapter")
        started.expectedFulfillmentCount = expectedStarts
    }

    func supportedRecognitionLanguages() throws -> [String] { ["en-US"] }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try await waitForTerminal(requestToken)
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingContext: LocalVisionOCRPassTimingContext?
    ) async throws -> [LocalVisionOCRObservation] {
        if let timingContext {
            let start = timingContext.nowNanoseconds()
            timingContext.measureRequestConstruction(from: start)
            let queue = timingContext.nowNanoseconds()
            timingContext.measureQueue(from: queue)
            let handler = timingContext.nowNanoseconds()
            timingContext.measureHandler(from: handler)
            let perform = timingContext.nowNanoseconds()
            timingContext.measurePerform(from: perform)
            let mapping = timingContext.nowNanoseconds()
            timingContext.measureMapping(from: mapping)
        }
        return try await waitForTerminal(requestToken)
    }

    func complete(token: LocalVisionOCRRequestToken) {
        let continuation = lock.withLock { () -> CheckedContinuation<[LocalVisionOCRObservation], Error>? in
            guard let index = pending.firstIndex(where: { $0.token === token }) else { return nil }
            return pending.remove(at: index).continuation
        }
        continuation?.resume(returning: [LocalVisionOCRObservation(text: "fixture", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1))])
    }

    private func waitForTerminal(
        _ token: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending.append(Pending(token: token, continuation: continuation)) }
            _ = token.addCancellationHandler { [weak self] in self?.cancel(token: token) }
            started.fulfill()
        }
    }

    private func cancel(token: LocalVisionOCRRequestToken) {
        let continuation = lock.withLock { () -> CheckedContinuation<[LocalVisionOCRObservation], Error>? in
            guard let index = pending.firstIndex(where: { $0.token === token }) else { return nil }
            return pending.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class SequencedLocalVisionOCRAdapter: LocalVisionOCRAdapter {
    private let lock = NSLock()
    private let supportedLanguages: [String]
    private var sequence: [[LocalVisionOCRObservation]]
    private var heights: [Int] = []
    private var sizes: [CGSize] = []
    private var configurations: [LocalVisionOCRRequestConfiguration] = []

    init(
        supportedLanguages: [String] = ["en-US"],
        sequence: [[LocalVisionOCRObservation]]
    ) {
        self.supportedLanguages = supportedLanguages
        self.sequence = sequence
    }

    var imageHeights: [Int] { lock.withLock { heights } }
    var imageSizes: [CGSize] { lock.withLock { sizes } }
    var requestConfigurations: [LocalVisionOCRRequestConfiguration] { lock.withLock { configurations } }

    var recognitionRequestCount: Int { lock.withLock { configurations.count } }

    func supportedRecognitionLanguages() throws -> [String] { supportedLanguages }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try requestToken.checkCancellation()
        return lock.withLock {
            heights.append(image.height)
            sizes.append(CGSize(width: image.width, height: image.height))
            configurations.append(configuration)
            return sequence.isEmpty ? [] : sequence.removeFirst()
        }
    }
}

private final class RecordingLocalVisionOCRAdapter: LocalVisionOCRAdapter {
    private let lock = NSLock()
    private let supportedLanguages: [String]
    private let observations: [LocalVisionOCRObservation]
    private var configuration: LocalVisionOCRRequestConfiguration?
    private var orientation: CGImagePropertyOrientation?
    private var supportedLanguageRequests = 0
    private var recognitionRequests = 0

    init(
        supportedLanguages: [String],
        observations: [LocalVisionOCRObservation]
    ) {
        self.supportedLanguages = supportedLanguages
        self.observations = observations
    }

    var lastConfiguration: LocalVisionOCRRequestConfiguration? {
        lock.withLock { configuration }
    }

    var lastOrientation: CGImagePropertyOrientation? {
        lock.withLock { orientation }
    }

    var supportedLanguagesRequestCount: Int {
        lock.withLock { supportedLanguageRequests }
    }

    var recognitionRequestCount: Int {
        lock.withLock { recognitionRequests }
    }

    func supportedRecognitionLanguages() throws -> [String] {
        lock.withLock { supportedLanguageRequests += 1 }
        return supportedLanguages
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        lock.withLock {
            self.configuration = configuration
            self.orientation = orientation
            recognitionRequests += 1
        }
        try requestToken.checkCancellation()
        return observations
    }
}

private final class FailingThenSuccessfulLanguagesOCRAdapter: LocalVisionOCRAdapter {
    private let lock = NSLock()
    private let supportedLanguages: [String]
    private let observations: [LocalVisionOCRObservation]
    private var supportedLanguageRequests = 0
    private var recognitionRequests = 0

    init(
        supportedLanguages: [String],
        observations: [LocalVisionOCRObservation]
    ) {
        self.supportedLanguages = supportedLanguages
        self.observations = observations
    }

    var supportedLanguagesRequestCount: Int {
        lock.withLock { supportedLanguageRequests }
    }

    var recognitionRequestCount: Int {
        lock.withLock { recognitionRequests }
    }

    func supportedRecognitionLanguages() throws -> [String] {
        let attempt = lock.withLock { () -> Int in
            supportedLanguageRequests += 1
            return supportedLanguageRequests
        }
        guard attempt > 1 else {
            throw LocalVisionOCRError.fixtureFailed("supported_languages_fixture_failure")
        }
        return supportedLanguages
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try requestToken.checkCancellation()
        lock.withLock { recognitionRequests += 1 }
        return observations
    }
}

private final class ConcurrentInitialLanguagesOCRAdapter: LocalVisionOCRAdapter {
    let firstQueryEntered = XCTestExpectation(description: "First supported-languages query entered")
    let secondQueryEntered = XCTestExpectation(description: "Second supported-languages query entered")
    private let lock = NSLock()
    private let firstGate = DispatchSemaphore(value: 0)
    private let secondGate = DispatchSemaphore(value: 0)
    private var queryCount = 0

    var supportedLanguagesRequestCount: Int { lock.withLock { queryCount } }

    func supportedRecognitionLanguages() throws -> [String] {
        let ordinal = lock.withLock { () -> Int in
            queryCount += 1
            return queryCount
        }
        switch ordinal {
        case 1:
            firstQueryEntered.fulfill()
            guard firstGate.wait(timeout: .now() + 1) == .success else {
                throw LocalVisionOCRError.fixtureFailed("first_supported_languages_timeout")
            }
            return ["en-US"]
        case 2:
            secondQueryEntered.fulfill()
            guard secondGate.wait(timeout: .now() + 1) == .success else {
                throw LocalVisionOCRError.fixtureFailed("second_supported_languages_timeout")
            }
            throw LocalVisionOCRError.fixtureFailed("controlled_supported_languages_failure")
        default:
            throw LocalVisionOCRError.fixtureFailed("unexpected_supported_languages_query")
        }
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try requestToken.checkCancellation()
        return [LocalVisionOCRObservation(
            text: "fixture",
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1)
        )]
    }

    func releaseFirstSuccess() { firstGate.signal() }
    func releaseSecondFailure() { secondGate.signal() }
}

private final class CancellationHoldingLocalVisionOCRAdapter: LocalVisionOCRAdapter {
    let started = XCTestExpectation(description: "OCR adapter started")
    private let lock = NSLock()
    private var observedCancellation = false
    private var continuation: CheckedContinuation<[LocalVisionOCRObservation], Error>?

    var didObserveCancellation: Bool {
        lock.withLock { observedCancellation }
    }

    func supportedRecognitionLanguages() throws -> [String] {
        ["en-US"]
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            _ = requestToken.addCancellationHandler { [weak self] in
                self?.resumeCancellation()
            }
            started.fulfill()
        }
    }

    private func resumeCancellation() {
        let continuation = lock.withLock { () -> CheckedContinuation<[LocalVisionOCRObservation], Error>? in
            observedCancellation = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class HoldingPriorityLocalVisionOCRAdapter: LocalVisionOCRAdapter {
    private let lock = NSLock()
    private var widths: [Int] = []
    private var continuations: [CheckedContinuation<[LocalVisionOCRObservation], Error>] = []

    var startedWidths: [Int] { lock.withLock { widths } }

    func supportedRecognitionLanguages() throws -> [String] { ["en-US"] }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try requestToken.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                widths.append(image.width)
                continuations.append(continuation)
            }
        }
    }

    func releaseNext(text: String) {
        let continuation = lock.withLock { continuations.removeFirst() }
        continuation.resume(returning: [LocalVisionOCRObservation(
            text: text,
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.08),
            confidence: 1
        )])
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
