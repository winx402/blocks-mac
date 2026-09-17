import Foundation
import XCTest
@testable import Blocks
@testable import BlocksCore

@MainActor
final class ClipboardManagementHostTests: XCTestCase {
    func testHostWirePreviewCommitExportAndDeleteUseIsolatedStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardManagementHost-\(UUID())")
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        defer { database.close(); try? FileManager.default.removeItem(at: root) }
        let repository = ClipboardRepository(database: database)
        let store = ClipboardStore(repository: repository)
        let access = ClipboardManagementAccessController(summaryAllowed: { true }, authorize: { _, _ in true })
        let service = ScreenshotActionHostService(executeHandler: { data, _ in
            do {
                let request = try JSONDecoder().decode(ActionBrokerRequest<ClipboardManagementActionInput>.self, from: data)
                let result = try await access.execute(request.payload) { try await store.executeManagement($0) }
                return try JSONEncoder().encode(ActionBrokerTerminalResponse.completed(
                    requestID: request.requestID, actionID: request.actionID, result: result
                ))
            } catch { return Data() }
        }, cancelHandler: { _ in false })
        func submit(_ input: ClipboardManagementActionInput) async throws -> ClipboardManagementResult {
            let request = ActionBrokerRequest(requestID: .make(), actionID: BlocksAction.clipboardManage.actionID, payload: input)
            let data = try JSONEncoder().encode(request)
            let response = await withCheckedContinuation { continuation in
                service.execute(data, outputFile: nil) { continuation.resume(returning: $0) }
            }
            let terminal = try JSONDecoder().decode(ActionBrokerTerminalResponse<ClipboardManagementResult>.self, from: response)
            XCTAssertEqual(terminal.status, .completed)
            return try XCTUnwrap(terminal.result)
        }
        let document = ClipboardImportDocument(pinboards: ["Migration fixture"], records: [
            .init(kind: "text", text: "Synthetic migration fixture", pinboard: "Migration fixture", tags: ["fixture"])
        ])
        let preview = try await submit(.init(operation: "import", document: document, dryRun: true))
        XCTAssertTrue(preview.dryRun)
        XCTAssertTrue(try repository.loadRecent(limit: 10).isEmpty)
        let imported = try await submit(.init(operation: "import", document: document))
        XCTAssertEqual(imported.counts.inserted, 1)
        let exported = try await submit(.init(operation: "export", all: true))
        XCTAssertEqual(exported.document?.records.first?.text, "Synthetic migration fixture")
        let id = try XCTUnwrap(repository.loadRecent(limit: 10).first?.id)
        let lease = try XCTUnwrap(store.recordActionLease(recordID: id))
        let deletion = try await submit(.init(operation: "delete", recordIDs: [id]))
        XCTAssertTrue(deletion.dryRun)
        XCTAssertTrue(store.isCurrentRecordActionLease(lease))
        let confirmed = try await submit(.init(operation: "delete", recordIDs: [id], confirmationToken: deletion.confirmationToken))
        XCTAssertFalse(confirmed.dryRun)
        XCTAssertFalse(store.isCurrentRecordActionLease(lease))
        XCTAssertNil(try repository.loadRecord(recordID: id))
    }

    func testCancelledImportWaitingForPastePermitNeverWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardManagementCancel-\(UUID())")
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        defer { database.close(); try? FileManager.default.removeItem(at: root) }
        let repository = ClipboardRepository(database: database)
        let store = ClipboardStore(repository: repository)
        let heldPermit = await store.recordCommitGate.acquire()
        let permit = try XCTUnwrap(heldPermit)
        let document = ClipboardImportDocument(records: [.init(kind: "text", text: "Never imported")])
        let task = Task { try await store.executeManagement(.init(operation: "import", document: document)) }
        await Task.yield()
        task.cancel()
        await store.recordCommitGate.release(permit)
        do { _ = try await task.value; XCTFail("Cancelled import unexpectedly committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try repository.loadRecent(limit: 10).isEmpty)
    }

    func testOversizedHostRequestNeverInvokesHandler() async throws {
        var calls = 0
        let service = ScreenshotActionHostService(executeHandler: { _, _ in calls += 1; return Data() },
                                                 cancelHandler: { _ in false })
        let data = Data(repeating: 0x20, count: ClipboardManagementLimits.maxDocumentBytes + 4 * 1024 * 1024 + 1)
        let response = await withCheckedContinuation { continuation in
            service.execute(data, outputFile: nil) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(calls, 0)
        let terminal = try JSONDecoder().decode(ActionBrokerTerminalResponse<JSONValue>.self, from: response)
        XCTAssertEqual(terminal.error?.code, "request_too_large")
    }

    func testManagementIsRegisteredButNotGrantedToPluginActions() {
        XCTAssertTrue(ActionRegistry.contains(BlocksAction.clipboardManage.rawValue))
        XCTAssertFalse(BlocksPluginHostActionRegistryV1.actionIDs.contains(BlocksAction.clipboardManage.rawValue))
    }
}
