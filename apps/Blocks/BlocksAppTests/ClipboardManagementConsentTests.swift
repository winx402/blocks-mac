import AppKit
import Foundation
import XCTest
@testable import Blocks
@testable import BlocksCore

@MainActor
final class ClipboardManagementConsentTests: XCTestCase {
    func testSummaryDisabledRejectsBeforeAnyRepositoryQuery() async throws {
        let controller = ClipboardManagementAccessController(summaryAllowed: { false })
        for operation in ["list", "search", "pinboard_list"] {
            var called = false
            await assertCode("summary_access_denied") {
                _ = try await controller.execute(.init(operation: operation)) { input in
                    called = true
                    return .init(operation: input.operation)
                }
            }
            XCTAssertFalse(called)
        }
    }

    func testSummaryRevokedOnReturnDoesNotLeakMetadata() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var allowed = true
        let controller = ClipboardManagementAccessController(summaryAllowed: { allowed })
        await assertCode("summary_access_denied") {
            _ = try await controller.execute(.init(operation: "list")) { input in
                let result = try fixture.repository.executeManagement(input)
                XCTAssertFalse(result.records.isEmpty)
                allowed = false
                return result
            }
        }
    }

    func testShowAndExportDenialNeverPerformsFullReadOrExposesPreparationDocument() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        for operation in ["show", "export"] {
            var calls: [ClipboardManagementActionInput] = []
            let controller = ClipboardManagementAccessController(authorize: { input, snapshot in
                XCTAssertTrue(input.dryRun)
                XCTAssertNil(input.confirmationToken)
                XCTAssertNil(snapshot.document)
                XCTAssertNil(snapshot.confirmationToken)
                return false
            })
            await assertCode("full_content_access_denied") {
                _ = try await controller.execute(.init(operation: operation, recordIDs: [fixture.id], confirmationToken: "untrusted")) { input in
                    calls.append(input)
                    return try fixture.repository.executeManagement(input)
                }
            }
            XCTAssertEqual(calls.count, 1)
            XCTAssertTrue(calls[0].dryRun)
            XCTAssertNil(calls[0].confirmationToken)
        }
    }

    func testFullReadDryRunNeverPromptsOrReturnsDocumentTokenOrDisabledSummaries() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var prompts = 0
        let controller = ClipboardManagementAccessController(summaryAllowed: { false }, authorize: { _, _ in
            prompts += 1
            return true
        })
        for operation in ["show", "export"] {
            let result = try await controller.execute(.init(operation: operation, dryRun: true, recordIDs: [fixture.id], confirmationToken: "untrusted")) {
                try fixture.repository.executeManagement($0)
            }
            XCTAssertNil(result.document)
            XCTAssertNil(result.confirmationToken)
            XCTAssertTrue(result.records.isEmpty)
            XCTAssertTrue(result.pinboards.isEmpty)
            XCTAssertEqual(result.counts.selected, 1)
        }
        XCTAssertEqual(prompts, 0)
    }

    func testApprovalRevalidatesPrivateTokenAndIsNeverReusable() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var prompts = 0
        var inputs: [ClipboardManagementActionInput] = []
        let controller = ClipboardManagementAccessController(authorize: { _, _ in prompts += 1; return true })
        for _ in 0..<2 {
            let result = try await controller.execute(.init(operation: "export", all: true, confirmationToken: "external-token")) { input in
                inputs.append(input)
                return try fixture.repository.executeManagement(input)
            }
            XCTAssertEqual(result.document?.records.first?.text, "consent fixture")
            XCTAssertNil(result.confirmationToken)
        }
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(inputs.count, 4)
        XCTAssertNil(inputs[0].confirmationToken)
        XCTAssertNotNil(inputs[1].confirmationToken)
        XCTAssertNotEqual(inputs[1].confirmationToken, "external-token")
        XCTAssertTrue(inputs[0].dryRun)
        XCTAssertFalse(inputs[1].dryRun)
    }

    func testChangedSelectionDuringApprovalFailsTokenRevalidation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let controller = ClipboardManagementAccessController(authorize: { _, _ in
            _ = try? fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "text", text: "added while waiting")
            ])))
            return true
        })
        await assertCode("revision_conflict") {
            _ = try await controller.execute(.init(operation: "export", all: true)) {
                try fixture.repository.executeManagement($0)
            }
        }
    }

    func testApprovedFullReadWithSummariesOffReturnsOnlyConsentedContentAndCounts() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let controller = ClipboardManagementAccessController(summaryAllowed: { false }, authorize: { _, snapshot in
            XCTAssertTrue(snapshot.records.isEmpty)
            XCTAssertTrue(snapshot.pinboards.isEmpty)
            XCTAssertNil(snapshot.document)
            return true
        })
        let result = try await controller.execute(.init(operation: "show", recordIDs: [fixture.id])) {
            try fixture.repository.executeManagement($0)
        }
        XCTAssertEqual(result.document?.records.first?.text, "consent fixture")
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.pinboards.isEmpty)
        XCTAssertNil(result.confirmationToken)
    }

    func testCancellationAfterWriteCommitDoesNotMisreportCommittedWriteAsCancelled() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let controller = ClipboardManagementAccessController(summaryAllowed: { false })
        let task = Task { @MainActor in
            try await controller.execute(.init(operation: "import", document: .init(records: [
                .init(kind: "text", text: "committed before cancellation")
            ]))) { input in
                let result = try fixture.repository.executeManagement(input)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
        }
        let result = try await task.value
        XCTAssertEqual(result.counts.inserted, 1)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).count, 2)
    }

    func testCommittedWriteWithRevokedSummariesReturnsCountsNotCancellation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var allowed = true
        let controller = ClipboardManagementAccessController(summaryAllowed: { allowed })
        let result = try await controller.execute(.init(operation: "import", document: .init(records: [
            .init(kind: "text", text: "committed", pinboard: "Private board", tags: ["private tag"])
        ]))) { input in
            var result = try fixture.repository.executeManagement(input)
            // Defensive stripping also covers unexpected future Core documents.
            result.document = .init(records: [.init(kind: "text", text: "never return")])
            allowed = false
            return result
        }
        XCTAssertEqual(result.counts.inserted, 1)
        XCTAssertNil(result.document)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.pinboards.isEmpty)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).count, 2)
    }

    func testConcurrentRequestRejectedAndCancelledApprovalCannotAuthorizeNextRequest() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let entered = expectation(description: "first fake prompt")
        var lateAnswer: CheckedContinuation<Bool, Never>?
        var prompts = 0
        var fullReads = 0
        let controller = ClipboardManagementAccessController(authorize: { _, _ in
            prompts += 1
            if prompts > 1 { return false }
            return await withCheckedContinuation { lateAnswer = $0; entered.fulfill() }
        })
        let first = Task { @MainActor in
            try await controller.execute(.init(operation: "export", all: true)) { input in
                if !input.dryRun { fullReads += 1 }
                return try fixture.repository.executeManagement(input)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await assertCode("full_content_confirmation_busy") {
            _ = try await controller.execute(.init(operation: "export", all: true)) {
                try fixture.repository.executeManagement($0)
            }
        }
        first.cancel()
        await assertCode("full_content_cancelled") { _ = try await first.value }
        lateAnswer?.resume(returning: true)
        await assertCode("full_content_access_denied") {
            _ = try await controller.execute(.init(operation: "export", all: true)) { input in
                if !input.dryRun { fullReads += 1 }
                return try fixture.repository.executeManagement(input)
            }
        }
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(fullReads, 0)
    }

    func testWaiterTimesOutEvenWhenInjectedAuthorizerIgnoresCancellation() async throws {
        let waiter = ClipboardManagementConsentWaiter()
        var lateAnswer: CheckedContinuation<Bool, Never>?
        await assertCode("full_content_confirmation_timeout") {
            _ = try await waiter.wait(timeoutNanoseconds: 10_000_000) {
                await withCheckedContinuation { lateAnswer = $0 }
            }
        }
        lateAnswer?.resume(returning: true)
    }

    func testPresenterRequiresWindowWithoutActivatingOrShowingAnything() async throws {
        var presented = false
        let presenter = ClipboardManagementConsentPresenter(windowProvider: { nil }, sheetPresenter: { _, _, _ in presented = true })
        await assertCode("full_content_requires_visible_window") {
            _ = try await presenter.present(.init(operation: "export", all: true), snapshot: .init(operation: "export"))
        }
        XCTAssertFalse(presented)
    }

    func testFakeSheetDefaultsToCancelAndWindowCloseDenies() async throws {
        // This window is never ordered front and the injected presenter never
        // displays an alert. No real user approval or user-data access occurs.
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var dismissed = 0
        let presenter = ClipboardManagementConsentPresenter(windowProvider: { window }, sheetPresenter: { alert, _, _ in
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        }, sheetDismisser: { _, _ in dismissed += 1 })
        let result = try await presenter.present(.init(operation: "export", all: true), snapshot: .init(operation: "export"))
        XCTAssertFalse(result)
        XCTAssertEqual(dismissed, 1)
    }

    func testScopeDescriptionIncludesSelectorsAndBoundsUntrustedValues() {
        let input = ClipboardManagementActionInput(operation: "export", recordIDs: ["a", "b", "c", "d"],
            query: "hello\nALLOW\u{202E}" + String(repeating: "x", count: 300), pinboardID: "board", tag: "tag")
        let description = ClipboardManagementConsentPresenter.scopeDescription(input, count: 7)
        XCTAssertTrue(description.contains("export"))
        XCTAssertTrue(description.contains("7"))
        XCTAssertTrue(description.contains("4"))
        XCTAssertTrue(description.contains("board"))
        XCTAssertTrue(description.contains("tag"))
        XCTAssertFalse(description.contains("\nALLOW"))
        XCTAssertFalse(description.contains("\u{202E}"))
        XCTAssertFalse(description.contains(String(repeating: "x", count: 161)))
    }

    func testDeliveryBarrierRejectsReadsCancelledOrSummaryRevokedAfterAccessReturns() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let cases: [(String, Bool)] = [
            ("list", true), ("search", true), ("pinboard_list", true),
            ("show", true), ("export", true),
            ("list", false), ("search", false), ("pinboard_list", false)
        ]
        for (operation, cancel) in cases {
            var allowed = true
            var release: CheckedContinuation<Void, Never>?
            let ready = expectation(description: "delivery barrier \(operation) \(cancel)")
            let controller = ClipboardManagementAccessController(summaryAllowed: { allowed }, authorize: { _, _ in true })
            let fullRead = ["show", "export"].contains(operation)
            let input = ClipboardManagementActionInput(operation: operation,
                recordIDs: fullRead ? [fixture.id] : [], query: operation == "search" ? "consent" : nil)
            let delivery = Task { @MainActor in
                let result = try await controller.execute(input) { try fixture.repository.executeManagement($0) }
                await withCheckedContinuation { release = $0; ready.fulfill() }
                return try ClipboardManagementAccessController.prepareForDelivery(result, input: input, summaryAllowed: allowed)
            }
            await fulfillment(of: [ready], timeout: 2)
            if cancel { delivery.cancel() } else { allowed = false }
            release?.resume()
            await assertCode(cancel ? "full_content_cancelled" : "summary_access_denied") {
                _ = try await delivery.value
            }
        }
    }

    func testDeliveryBarrierKeepsCommittedWriteCountsAfterCancellationAndSummaryRevocation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var allowed = true
        var release: CheckedContinuation<Void, Never>?
        var expectedToken: String?
        var expectedIDs: [String] = []
        let ready = expectation(description: "committed write delivery barrier")
        let controller = ClipboardManagementAccessController(summaryAllowed: { allowed })
        let input = ClipboardManagementActionInput(operation: "import", document: .init(records: [
            .init(kind: "text", text: "delivery fixture", pinboard: "Private delivery board", tags: ["private"])
        ]))
        let delivery = Task { @MainActor in
            var result = try await controller.execute(input) { try fixture.repository.executeManagement($0) }
            XCTAssertFalse(result.records.isEmpty)
            XCTAssertFalse(result.pinboards.isEmpty)
            expectedToken = result.confirmationToken
            expectedIDs = result.mutatedRecordIDs
            // A defensive terminal scrub also excludes unexpected payloads.
            result.document = input.document
            result.warnings = ["private metadata"]
            await withCheckedContinuation { release = $0; ready.fulfill() }
            return try ClipboardManagementAccessController.prepareForDelivery(result, input: input, summaryAllowed: allowed)
        }
        await fulfillment(of: [ready], timeout: 2)
        allowed = false
        delivery.cancel()
        release?.resume()
        let result = try await delivery.value
        XCTAssertEqual(result.counts.inserted, 1)
        XCTAssertFalse(result.dryRun)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.pinboards.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(result.document)
        XCTAssertEqual(result.confirmationToken, expectedToken)
        XCTAssertEqual(result.mutatedRecordIDs, expectedIDs)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).count, 2)
    }

    private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                            _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch { XCTAssertEqual((error as? ClipboardManagementError)?.code, code, file: file, line: line) }
    }

    private struct Fixture {
        let root: URL
        let database: AppDatabase
        let repository: ClipboardRepository
        let id: String
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardConsentTests.\(UUID())")
            database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
            repository = ClipboardRepository(database: database)
            let inserted = try repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "text", text: "consent fixture", pinboard: "Fixture board", tags: ["fixture tag"])
            ])))
            id = try XCTUnwrap(inserted.records.first?.id)
        }
        func close() { database.close(); try? FileManager.default.removeItem(at: root) }
    }
}
