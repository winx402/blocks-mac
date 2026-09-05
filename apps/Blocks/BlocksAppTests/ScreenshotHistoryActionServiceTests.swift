import AppKit
import BlocksCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Blocks

@MainActor
final class ScreenshotHistoryActionServiceTests: XCTestCase {
    func testHistoryQueryUsesOpaqueKeysetCursorWithoutDuplicates() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "third", seed: 3, createdAt: Date(timeIntervalSince1970: 30), fixture: fixture)
        try commit(recordID: "second", seed: 2, createdAt: Date(timeIntervalSince1970: 20), fixture: fixture)
        try commit(recordID: "first", seed: 1, createdAt: Date(timeIntervalSince1970: 10), fixture: fixture)
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: nil)

        let firstPage = try await service.query(try ScreenshotHistoryQueryActionInput(limit: 2))
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let secondPage = try await service.query(try ScreenshotHistoryQueryActionInput(cursor: cursor, limit: 2))

        XCTAssertEqual(firstPage.items.map(\.recordID), ["third", "second"])
        XCTAssertEqual(secondPage.items.map(\.recordID), ["first"])
        XCTAssertTrue(Set(firstPage.items.map(\.recordID)).isDisjoint(with: secondPage.items.map(\.recordID)))
        XCTAssertNil(secondPage.nextCursor)
    }

    func testSearchCursorCannotBeReusedForAnotherQuery() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        for index in 0..<2 {
            let id = "needle-\(index)"
            try commit(recordID: id, seed: UInt8(index + 10), createdAt: Date(timeIntervalSince1970: Double(20 - index)), fixture: fixture)
        }
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: nil)
        let page = try await service.search(try ScreenshotHistorySearchActionInput(query: "Screenshot", limit: 1))
        let cursor = try XCTUnwrap(page.nextCursor)

        await XCTAssertThrowsErrorAsync(
            try await service.search(
                try ScreenshotHistorySearchActionInput(query: "Different", cursor: cursor, limit: 1)
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotHistoryActionServiceError, .invalidCursor)
        }
    }

    func testHistoryReturnsBoundedOCRSummaryAndRequiresExplicitFullText() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "ocr", seed: 20, createdAt: Date(), fixture: fixture, ocrState: .pending)
        let document = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: "ocr"))
        let text = String(repeating: "local text ", count: 30)
        XCTAssertTrue(try fixture.repository.updateOCRResult(
            recordID: "ocr",
            revision: document.revision,
            text: text,
            state: .succeeded
        ))
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: nil)

        let restricted = try await service.query(try ScreenshotHistoryQueryActionInput(limit: 24))
        let full = try await service.query(try ScreenshotHistoryQueryActionInput(limit: 24, includeOCR: true))

        XCTAssertEqual(restricted.items.first?.ocrSummary.count, 160)
        XCTAssertNil(restricted.items.first?.ocr)
        XCTAssertEqual(full.items.first?.ocr, text)
        XCTAssertEqual(full.items.first?.pixelSize, ScreenshotPixelDimensions(width: 2, height: 2))
    }

    func testOCRRetryRejectsUserEditedTextLock() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "locked", seed: 30, createdAt: Date(), fixture: fixture, ocrState: .pending)
        _ = try fixture.repository.saveDetailEdit(
            command: ClipboardDetailEditCommand(
                recordID: "locked",
                expectedContentRevision: 1,
                editableKind: .imageOCRText,
                draft: ClipboardDetailDraft(text: "user correction"),
                purpose: "detailEditSave"
            )
        )
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: nil)

        await XCTAssertThrowsErrorAsync(
            try await service.retry(ScreenshotOCRRetryActionInput(recordID: "locked"))
        ) { error in
            XCTAssertEqual(error as? ScreenshotHistoryActionServiceError, .ocrLocked)
        }
    }

    func testExternalScreenshotCommitStartsAutomaticOCRDrain() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "automatic", seed: 31, createdAt: Date(), fixture: fixture, ocrState: .pending)
        let recognizer = MockClipboardVisionTextRecognizer(scriptedResults: [.succeeded("automatic OCR")])
        let queue = ClipboardVisionOCRQueue(repository: fixture.repository, recognizer: recognizer)
        let store = ClipboardStore(repository: fixture.repository, ocrQueue: queue)

        store.refreshRepositoryStateAfterExternalCommit()

        try await waitUntil {
            try fixture.repository.loadSearchDocument(recordID: "automatic")?.ocrState == .succeeded
        }
        XCTAssertEqual(
            try fixture.repository.loadSearchDocument(recordID: "automatic")?.ocrText,
            "automatic OCR"
        )
    }

    func testRetrySchedulesTheRequestedRecordInsteadOfAnOlderPendingRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "older", seed: 32, createdAt: Date(timeIntervalSince1970: 10), fixture: fixture, ocrState: .pending)
        try commit(recordID: "target", seed: 33, createdAt: Date(timeIntervalSince1970: 20), fixture: fixture, ocrState: .pending)
        let recognizer = MockClipboardVisionTextRecognizer(scriptedResults: [.succeeded("target OCR")])
        let queue = ClipboardVisionOCRQueue(repository: fixture.repository, recognizer: recognizer)
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: queue)

        _ = try await service.retry(ScreenshotOCRRetryActionInput(recordID: "target"))

        try await waitUntil {
            try fixture.repository.loadSearchDocument(recordID: "target")?.ocrState == .succeeded
        }
        XCTAssertEqual(try fixture.repository.loadSearchDocument(recordID: "target")?.ocrText, "target OCR")
        XCTAssertEqual(try fixture.repository.loadSearchDocument(recordID: "older")?.ocrState, .pending)
    }

    func testRetryWhileRecordIsRunningReturnsAlreadyRunningWithoutRevertingDatabaseState() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "running", seed: 34, createdAt: Date(), fixture: fixture, ocrState: .pending)
        let recognizer = MockClipboardVisionTextRecognizer(scriptedResults: [.runningHold("running")])
        let queue = ClipboardVisionOCRQueue(repository: fixture.repository, recognizer: recognizer)
        let revision = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: "running")?.revision)

        let processing = Task {
            await queue.processQueued(recordID: "running", revision: revision)
        }
        try await waitUntil {
            guard recognizer.runningHoldCount == 1 else { return false }
            return (try? fixture.repository.loadSearchDocument(recordID: "running"))?.ocrState == .running
        }

        let retry = await queue.retryOCR(recordID: "running")

        XCTAssertEqual(retry, .skipped(recordID: "running", reason: "already_running"))
        XCTAssertEqual(try fixture.repository.loadSearchDocument(recordID: "running")?.ocrState, .running)
        recognizer.releaseRunningHold(text: "finished")
        let processingResult = await processing.value
        XCTAssertEqual(processingResult, .completed(recordID: "running"))
        let completedDocument = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: "running"))
        XCTAssertEqual(completedDocument.ocrAttemptCount, 1)
        XCTAssertEqual(completedDocument.ocrState, .succeeded)
    }

    func testActionRetryWhileRecordIsRunningReturnsStructuredAlreadyRunning() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "action-running", seed: 35, createdAt: Date(), fixture: fixture, ocrState: .pending)
        let recognizer = MockClipboardVisionTextRecognizer(scriptedResults: [.runningHold("running")])
        let queue = ClipboardVisionOCRQueue(repository: fixture.repository, recognizer: recognizer)
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: queue)
        let revision = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: "action-running")?.revision)
        let processing = Task {
            await queue.processQueued(recordID: "action-running", revision: revision)
        }
        try await waitUntil {
            guard recognizer.runningHoldCount == 1 else { return false }
            return (try? fixture.repository.loadSearchDocument(recordID: "action-running"))?.ocrState == .running
        }

        await XCTAssertThrowsErrorAsync(
            try await service.retry(ScreenshotOCRRetryActionInput(recordID: "action-running"))
        ) { error in
            XCTAssertEqual(error as? ScreenshotHistoryActionServiceError, .alreadyRunning)
        }
        XCTAssertEqual(try fixture.repository.loadSearchDocument(recordID: "action-running")?.ocrState, .running)

        recognizer.releaseRunningHold(text: "finished")
        _ = await processing.value
    }

    func testCancelledOCRIgnoresLateRecognizerSuccessAndReturnsRecordToPending() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "cancelled-ocr", seed: 36, createdAt: Date(), fixture: fixture, ocrState: .pending)
        let recognizer = MockClipboardVisionTextRecognizer(scriptedResults: [.runningHold("late success")])
        let queue = ClipboardVisionOCRQueue(repository: fixture.repository, recognizer: recognizer)
        let revision = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: "cancelled-ocr")?.revision)

        let processing = Task {
            await queue.processQueued(recordID: "cancelled-ocr", revision: revision)
        }
        try await waitUntil {
            guard recognizer.runningHoldCount == 1 else { return false }
            return (try? fixture.repository.loadSearchDocument(recordID: "cancelled-ocr"))?.ocrState == .running
        }

        processing.cancel()
        recognizer.releaseRunningHold(text: "late success")

        let processingResult = await processing.value
        XCTAssertEqual(
            processingResult,
            .skipped(recordID: "cancelled-ocr", reason: "cancelled")
        )
        let document = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: "cancelled-ocr"))
        XCTAssertEqual(document.ocrState, .pending)
        XCTAssertNil(document.ocrText)
    }

    func testCancelledOCRSchedulerDoesNotPublishLateRecognizerSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commit(recordID: "cancelled-scheduler", seed: 37, createdAt: Date(), fixture: fixture, ocrState: .pending)
        let recognizer = MockClipboardVisionTextRecognizer(scriptedResults: [.runningHold("late success")])
        let queue = ClipboardVisionOCRQueue(repository: fixture.repository, recognizer: recognizer)
        var updateCount = 0
        let scheduler = ClipboardOCRScheduler(queue: queue) { _ in
            updateCount += 1
        }

        scheduler.schedule(context: .clipboardImage, quietDelay: 0)
        try await waitUntil {
            guard recognizer.runningHoldCount == 1 else { return false }
            return (try? fixture.repository.loadSearchDocument(recordID: "cancelled-scheduler"))?.ocrState == .running
        }

        scheduler.shutdown()
        recognizer.releaseRunningHold(text: "late success")
        try await waitUntil {
            (try? fixture.repository.loadSearchDocument(recordID: "cancelled-scheduler"))?.ocrState == .pending
        }

        XCTAssertEqual(updateCount, 0)
    }

    func testExportWritesExactPNGAndJPEGToProvidedFileHandle() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let originalPNG = try commit(recordID: "export", seed: 40, createdAt: Date(), fixture: fixture)
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: nil)

        let pngURL = fixture.root.appendingPathComponent("export.png")
        FileManager.default.createFile(atPath: pngURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let pngHandle = try FileHandle(forWritingTo: pngURL)
        let pngResult = try await service.export(
            ScreenshotHistoryExportActionInput(recordID: "export", format: .png),
            outputFile: pngHandle
        )
        try pngHandle.close()
        XCTAssertEqual(try Data(contentsOf: pngURL), originalPNG)
        XCTAssertEqual(pngResult.bytesWritten, Int64(originalPNG.count))

        let jpegURL = fixture.root.appendingPathComponent("export.jpg")
        FileManager.default.createFile(atPath: jpegURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let jpegHandle = try FileHandle(forWritingTo: jpegURL)
        let jpegResult = try await service.export(
            ScreenshotHistoryExportActionInput(recordID: "export", format: .jpeg),
            outputFile: jpegHandle
        )
        try jpegHandle.close()
        let jpeg = try Data(contentsOf: jpegURL)
        XCTAssertEqual(jpegResult.bytesWritten, Int64(jpeg.count))
        XCTAssertNotNil(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertNotEqual(jpeg, originalPNG)
    }

    func testExportCancellationAfterTemporaryWritePreservesExistingOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = try commit(recordID: "cancelled-export", seed: 42, createdAt: Date(), fixture: fixture)
        let writer = SuspendedHistoryExportTemporaryFileWriter()
        let service = ScreenshotHistoryActionService(
            repository: fixture.repository,
            ocrQueue: nil,
            temporaryFileWriter: { data, url in
                try await writer.write(data, to: url)
            }
        )
        let outputURL = fixture.root.appendingPathComponent("cancelled-export.png")
        let previousData = Data("existing output must survive cancellation".utf8)
        try previousData.write(to: outputURL)
        let outputFile = try FileHandle(forWritingTo: outputURL)
        defer { try? outputFile.close() }

        let export = Task {
            try await service.export(
                ScreenshotHistoryExportActionInput(recordID: "cancelled-export", format: .png),
                outputFile: outputFile
            )
        }
        await writer.waitUntilStarted()
        export.cancel()
        await writer.resume()

        await XCTAssertThrowsErrorAsync(try await export.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), previousData)
        XCTAssertNotEqual(try Data(contentsOf: outputURL), png)
    }

    func testOlderConcurrentExportCannotReplaceNewerExportForSameOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let olderPNG = try commit(recordID: "older-export", seed: 43, createdAt: Date(), fixture: fixture)
        let newerPNG = try commit(recordID: "newer-export", seed: 44, createdAt: Date(), fixture: fixture)
        let writer = FirstHistoryExportTemporaryWriteSuspender()
        let service = ScreenshotHistoryActionService(
            repository: fixture.repository,
            ocrQueue: nil,
            temporaryFileWriter: { data, url in
                try await writer.write(data, to: url)
            }
        )
        let outputURL = fixture.root.appendingPathComponent("concurrent-export.png")
        try Data("old output".utf8).write(to: outputURL)
        let olderHandle = try FileHandle(forWritingTo: outputURL)
        let newerHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? olderHandle.close()
            try? newerHandle.close()
        }

        let olderExport = Task {
            try await service.export(
                ScreenshotHistoryExportActionInput(recordID: "older-export", format: .png),
                outputFile: olderHandle
            )
        }
        await writer.waitUntilFirstWriteStarted()
        let newerResult = try await service.export(
            ScreenshotHistoryExportActionInput(recordID: "newer-export", format: .png),
            outputFile: newerHandle
        )
        XCTAssertEqual(newerResult.bytesWritten, Int64(newerPNG.count))

        await writer.resumeFirstWrite()
        await XCTAssertThrowsErrorAsync(try await olderExport.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), newerPNG)
        XCTAssertNotEqual(try Data(contentsOf: outputURL), olderPNG)
    }

    func testStatusRetryAndExportRejectOrdinaryClipboardImages() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try commitOrdinaryImage(recordID: "ordinary", seed: 41, fixture: fixture)
        let service = ScreenshotHistoryActionService(repository: fixture.repository, ocrQueue: nil)

        await XCTAssertThrowsErrorAsync(
            try await service.status(ScreenshotOCRStatusActionInput(recordIDs: ["ordinary"]))
        ) { error in
            XCTAssertEqual(error as? ScreenshotHistoryActionServiceError, .recordNotFound)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.retry(ScreenshotOCRRetryActionInput(recordID: "ordinary"))
        ) { error in
            XCTAssertEqual(error as? ScreenshotHistoryActionServiceError, .recordNotFound)
        }

        let outputURL = fixture.root.appendingPathComponent("ordinary.png")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        await XCTAssertThrowsErrorAsync(
            try await service.export(
                ScreenshotHistoryExportActionInput(recordID: "ordinary", format: .png),
                outputFile: output
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotHistoryActionServiceError, .recordNotFound)
        }
        try output.close()

        let history = try await service.query(try ScreenshotHistoryQueryActionInput(limit: 24))
        let search = try await service.search(
            try ScreenshotHistorySearchActionInput(query: "Ordinary image", limit: 24)
        )
        XCTAssertFalse(history.items.contains(where: { $0.recordID == "ordinary" }))
        XCTAssertFalse(search.items.contains(where: { $0.recordID == "ordinary" }))
    }

    func testActionHostRejectsConcurrentDuplicateRequestIDWithoutReplacingCancellationTracking() async throws {
        let requestID = try XCTUnwrap(ActionRequestID(rawValue: "duplicate-request"))
        let requestData = try JSONEncoder().encode(ActionBrokerRequest(
            requestID: requestID,
            actionID: BlocksAction.screenshotHistoryQuery.actionID,
            payload: JSONValue.object([:])
        ))
        let firstHandlerStarted = expectation(description: "first request handler starts")
        let secondRequestRejected = expectation(description: "second request is rejected")
        let firstRequestReplied = expectation(description: "first request replies after cancellation")
        let cancellationCompleted = expectation(description: "cancellation waits for the first request")
        let thirdRequestReplied = expectation(description: "third request executes after cleanup")
        let cancellationGate = ActionHostCancellationGate()
        var handlerInvocationCount = 0
        var firstHandlerObservedCancellation = false
        var firstReplyDelivered = false
        let host: BlocksActionHostXPCProtocol = ScreenshotActionHostService(
            executeHandler: { _, _ in
                handlerInvocationCount += 1
                if handlerInvocationCount == 1 {
                    firstHandlerStarted.fulfill()
                    await cancellationGate.wait()
                    firstHandlerObservedCancellation = Task.isCancelled
                    return Data("first-cancelled".utf8)
                }
                return Data("third-completed".utf8)
            },
            cancelHandler: { _ in
                await cancellationGate.release()
                return true
            }
        )

        host.execute(requestData, outputFile: nil) { data in
            XCTAssertEqual(data, Data("first-cancelled".utf8))
            firstReplyDelivered = true
            firstRequestReplied.fulfill()
        }
        await fulfillment(of: [firstHandlerStarted], timeout: 1)

        host.execute(requestData, outputFile: nil) { data in
            let response = try? JSONDecoder().decode(
                ActionBrokerTerminalResponse<JSONValue>.self,
                from: data
            )
            XCTAssertEqual(response?.status, .failed)
            XCTAssertEqual(response?.requestID, requestID)
            XCTAssertEqual(response?.actionID, BlocksAction.screenshotHistoryQuery.actionID)
            XCTAssertEqual(response?.error?.code, "duplicate_request_id")
            secondRequestRejected.fulfill()
        }
        await fulfillment(of: [secondRequestRejected], timeout: 1)
        XCTAssertEqual(handlerInvocationCount, 1)

        host.cancel(requestID.rawValue) { cancelled in
            XCTAssertTrue(cancelled)
            XCTAssertTrue(firstReplyDelivered)
            cancellationCompleted.fulfill()
        }
        await fulfillment(of: [firstRequestReplied, cancellationCompleted], timeout: 1)
        XCTAssertTrue(firstHandlerObservedCancellation)

        host.execute(requestData, outputFile: nil) { data in
            XCTAssertEqual(data, Data("third-completed".utf8))
            thirdRequestReplied.fulfill()
        }
        await fulfillment(of: [thirdRequestReplied], timeout: 1)
        XCTAssertEqual(handlerInvocationCount, 2)
    }

    @discardableResult
    private func commit(
        recordID: String,
        seed: UInt8,
        createdAt: Date,
        fixture: Fixture,
        ocrState: ClipboardOCRState = .notRequired
    ) throws -> Data {
        let png = pngData(seed: seed)
        let record = ClipboardRecorderRecord(
            id: recordID,
            createdAt: createdAt,
            changeCount: Int(seed) + 1,
            kind: .image,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.png"],
                byteCount: png.count
            ),
            sourceApp: ClipboardRecorderSourceApp(
                bundleIdentifier: "app.blocks.tests",
                localizedName: "Blocks Tests",
                sourceAppIsCandidate: true
            ),
            signatureSHA256: String(repeating: "0", count: 64),
            signatureSHA256_12: String(repeating: "0", count: 12),
            fixtureOwned: false,
            restorable: true,
            summary: "Screenshot"
        )
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: png,
                ocrState: ocrState
            )
        )
        return try XCTUnwrap(
            fixture.repository.readPayload(recordID: recordID)?.pngData
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocks-action-tests-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        return Fixture(
            root: root,
            database: database,
            repository: ClipboardRepository(
                database: database,
                blobStore: BlobStore(directory: database.environment.blobDirectory)
            )
        )
    }

    private func commitOrdinaryImage(
        recordID: String,
        seed: UInt8,
        fixture: Fixture
    ) throws {
        let png = pngData(seed: seed)
        let record = ClipboardRecorderRecord(
            id: recordID,
            createdAt: Date(),
            changeCount: Int(seed) + 1,
            kind: .image,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.png"],
                byteCount: png.count
            ),
            sourceApp: nil,
            signatureSHA256: String(repeating: "1", count: 64),
            signatureSHA256_12: String(repeating: "1", count: 12),
            fixtureOwned: false,
            restorable: true,
            summary: "Ordinary image"
        )
        _ = try fixture.repository.insert(
            record: record,
            payload: ClipboardRecorderPayload(
                recordID: recordID,
                kind: .image,
                pngData: png
            )
        )
    }

    private func pngData(seed: UInt8) -> Data {
        let pixels = Data((0..<4).flatMap { index -> [UInt8] in
            let offset = UInt8(index * 3)
            return [seed &+ offset, seed &+ offset &+ 1, seed &+ offset &+ 2, 255]
        })
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: () throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition did not become true before timeout")
    }
}

private struct Fixture {
    let root: URL
    let database: AppDatabase
    let repository: ClipboardRepository

    func close() {
        database.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor SuspendedHistoryExportTemporaryFileWriter {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func write(_: Data, to _: URL) async throws {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FirstHistoryExportTemporaryWriteSuspender {
    private var isFirstWrite = true
    private var firstWriteStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func write(_ data: Data, to url: URL) async throws {
        if isFirstWrite {
            isFirstWrite = false
            firstWriteStarted = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        try data.write(to: url)
    }

    func waitUntilFirstWriteStarted() async {
        while !firstWriteStarted {
            await Task.yield()
        }
    }

    func resumeFirstWrite() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ActionHostCancellationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
