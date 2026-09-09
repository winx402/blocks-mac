import BlocksCore
import XCTest
@testable import Blocks

@MainActor
final class ClipboardRecencyPublicationTests: XCTestCase {
    func testCommittedPromotionRejectsAHistorySnapshotCapturedBeforeCommit() async throws {
        let fixture = try RecencyPublicationFixture()
        defer { fixture.close() }
        let reads = RecencyHistoryPublicationBarrier()
        let store = ClipboardStore(
            repository: fixture.repository,
            historyReadPublicationHooks: reads.hooks
        )
        store.records = fixture.initialRecords
        var eventCount = 0
        store.configurePluginEventDispatcher { envelope in
            eventCount += 1
            return .allowed(envelope)
        }

        store.refreshSearchResult(query: "")
        await fulfillment(of: [reads.captured], timeout: 3)
        defer { reads.release() }
        XCTAssertEqual(reads.snapshot?.loadedRecords?.first?.id, fixture.front.id)

        let update = await store.commitCopyEvent(
            recordID: fixture.target.id,
            source: .plugin,
            at: fixture.target.createdAt
        )
        XCTAssertTrue(update.persisted)
        XCTAssertEqual(store.records.first?.id, fixture.target.id)
        await fulfillment(of: [reads.freshReadCompleted], timeout: 3)

        // The old callback is deliberately delivered after the newer read has
        // published. Waiting for its completion proves it cannot undo promotion.
        reads.release()
        await fulfillment(of: [reads.capturedReadCompleted], timeout: 3)
        let persisted = try XCTUnwrap(fixture.repository.loadRecord(recordID: fixture.target.id))
        XCTAssertGreaterThan(persisted.lastCopiedAt, fixture.front.lastCopiedAt)
        XCTAssertEqual(update.promotedAt, persisted.lastCopiedAt)
        XCTAssertEqual(store.records.first?.id, fixture.target.id)
        XCTAssertEqual(store.records.first?.lastCopiedAt, persisted.lastCopiedAt)
        XCTAssertEqual(store.currentSearchResult.query, "")
        XCTAssertEqual(store.currentSearchResult.records.first?.id, fixture.target.id)
        XCTAssertEqual(store.currentSearchResult.records.first?.lastCopiedAt, persisted.lastCopiedAt)
        XCTAssertEqual(eventCount, 1)
    }

    func testPromotionPreservesQueryAndFilterChangedWhileCommitIsPending() async throws {
        let fixture = try RecencyPublicationFixture()
        defer { fixture.close() }
        let reads = RecencyHistoryPublicationBarrier()
        let mutation = RecencyMutationBarrier()
        defer { mutation.release(); reads.release() }
        let store = ClipboardStore(
            repository: fixture.repository,
            recordMutationPipelineHooks: .init(beforeMutation: { kind in
                if kind == .markCopied { mutation.waitBeforeMutation() }
            }),
            historyReadPublicationHooks: reads.hooks
        )
        store.records = fixture.initialRecords
        let promotion = Task {
            await store.commitCopyEvent(recordID: fixture.target.id, source: .plugin)
        }
        await fulfillment(of: [mutation.entered], timeout: 3)

        // This read really completes against the pre-commit database, but its
        // new query/filter must survive the successful mutation's invalidation.
        store.filterState.format = .image
        store.refreshSearchResult(query: "target", limit: 7)
        await fulfillment(of: [reads.captured], timeout: 3)
        XCTAssertEqual(reads.snapshot?.resultSet.query, "target")
        mutation.release()
        let update = await promotion.value
        XCTAssertTrue(update.persisted)
        await fulfillment(of: [reads.freshReadCompleted], timeout: 3)
        reads.release()
        await fulfillment(of: [reads.capturedReadCompleted], timeout: 3)

        let persisted = try XCTUnwrap(fixture.repository.loadRecord(recordID: fixture.target.id))
        XCTAssertEqual(store.records.first?.id, fixture.target.id)
        XCTAssertEqual(store.records.first?.lastCopiedAt, persisted.lastCopiedAt)
        XCTAssertEqual(store.currentSearchResult.query, "target")
        XCTAssertEqual(store.filterState.format, .image)
        XCTAssertTrue(store.currentSearchResult.records.isEmpty, "the latest image filter excludes text records")
    }

    func testLoadedPromotionDoesNotWaitForReplacementHistoryRead() async throws {
        let fixture = try RecencyPublicationFixture()
        defer { fixture.close() }
        let reads = RecencyHistoryPublicationBarrier()
        defer { reads.release() }
        let store = ClipboardStore(
            repository: fixture.repository,
            historyReadPublicationHooks: reads.hooks
        )
        store.records = fixture.initialRecords
        let returned = expectation(description: "loaded promotion returned while replacement read is suspended")
        var update: ClipboardRecordRecencyUpdate?
        let promotion = Task {
            update = await store.commitCopyEvent(
                recordID: fixture.target.id,
                source: .panelPaste,
                shouldPublishPluginEvent: { false }
            )
            returned.fulfill()
        }
        await fulfillment(of: [reads.captured, returned], timeout: 3)
        XCTAssertEqual(update?.persisted, true)
        XCTAssertEqual(store.records.first?.id, fixture.target.id)
        XCTAssertEqual(store.currentSearchResult.records.first?.id, fixture.target.id)
        XCTAssertEqual(store.records.first?.lastCopiedAt, update?.promotedAt)

        reads.release()
        await promotion.value
        await fulfillment(of: [reads.capturedReadCompleted], timeout: 3)
    }

    func testFailedOrMissingPromotionDoesNotInvalidatePendingReadOrPublishAnEvent() async throws {
        for failsMutation in [true, false] {
            let fixture = try RecencyPublicationFixture()
            defer { fixture.close() }
            let reads = RecencyHistoryPublicationBarrier()
            defer { reads.release() }
            let store = ClipboardStore(
                repository: fixture.repository,
                recordMutationPipelineHooks: .init(shouldFailMutation: { _ in failsMutation }),
                historyReadPublicationHooks: reads.hooks
            )
            store.records = fixture.initialRecords
            var eventCount = 0
            store.configurePluginEventDispatcher { envelope in
                eventCount += 1
                return .allowed(envelope)
            }
            store.refreshSearchResult(query: "")
            await fulfillment(of: [reads.captured], timeout: 3)

            let update = await store.commitCopyEvent(
                recordID: failsMutation ? fixture.target.id : "missing-record",
                source: .plugin
            )
            XCTAssertFalse(update.persisted)
            XCTAssertNil(update.promotedAt)
            XCTAssertEqual(update.recordFound, failsMutation)
            reads.release()
            await fulfillment(of: [reads.capturedReadCompleted], timeout: 3)

            XCTAssertEqual(store.records.map(\.id), fixture.initialRecords.map(\.id))
            XCTAssertEqual(store.currentSearchResult.records.map(\.id), fixture.initialRecords.map(\.id))
            XCTAssertEqual(reads.completedGenerations, [reads.snapshot?.generation].compactMap { $0 })
            XCTAssertEqual(
                try fixture.repository.loadRecord(recordID: fixture.target.id)?.lastCopiedAt,
                fixture.target.lastCopiedAt
            )
            XCTAssertEqual(eventCount, 0)
        }
    }
}

@MainActor
private final class RecencyHistoryPublicationBarrier {
    let captured = XCTestExpectation(description: "real database snapshot captured before publication")
    let capturedReadCompleted = XCTestExpectation(description: "captured read finished its publication attempt")
    let freshReadCompleted = XCTestExpectation(description: "replacement read published")
    private(set) var snapshot: ClipboardHistoryReadSnapshot?
    private(set) var completedGenerations: [UInt64] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var didCompleteFreshRead = false

    var hooks: ClipboardHistoryReadPublicationHooks {
        .init(
            beforePublication: { [self] snapshot in
                guard self.snapshot == nil else { return }
                self.snapshot = snapshot
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    captured.fulfill()
                }
            },
            didComplete: { [self] generation in
                completedGenerations.append(generation)
                if generation == snapshot?.generation {
                    capturedReadCompleted.fulfill()
                } else if !didCompleteFreshRead {
                    didCompleteFreshRead = true
                    freshReadCompleted.fulfill()
                }
            }
        )
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class RecencyMutationBarrier: @unchecked Sendable {
    let entered = XCTestExpectation(description: "copy mutation queued before database commit")
    private let semaphore = DispatchSemaphore(value: 0)

    func waitBeforeMutation() {
        entered.fulfill()
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            XCTFail("test did not release the copy mutation barrier")
        }
    }

    func release() { semaphore.signal() }
}

private final class RecencyPublicationFixture {
    let root: URL
    let database: AppDatabase
    let repository: ClipboardRepository
    let target: ClipboardRecorderRecord
    let front: ClipboardRecorderRecord
    var initialRecords: [ClipboardRecorderRecord] { [front, target] }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardRecencyPublication-\(UUID().uuidString)",
            isDirectory: true
        )
        database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        repository = ClipboardRepository(database: database)
        target = Self.record(id: "target", timestamp: 1_700_000_000)
        front = Self.record(id: "front", timestamp: 1_700_000_100)
        for record in [target, front] {
            _ = try repository.insert(
                record: record,
                payload: .init(recordID: record.id, kind: .text, text: record.summary)
            )
        }
        // Avoid unrelated startup index maintenance issuing its own refresh.
        _ = try repository.rebuildPendingSearchDocuments(limit: 10)
    }

    func close() {
        database.close()
        try? FileManager.default.removeItem(at: root)
    }

    private static func record(id: String, timestamp: TimeInterval) -> ClipboardRecorderRecord {
        .init(
            id: id,
            createdAt: Date(timeIntervalSince1970: timestamp),
            changeCount: 1,
            kind: .text,
            formatSummary: .init(itemCount: 1, types: ["public.utf8-plain-text"], textLength: id.count),
            sourceApp: nil,
            signatureSHA256_12: "recency-\(id)",
            fixtureOwned: true,
            restorable: true,
            summary: id
        )
    }
}
