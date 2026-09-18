import Foundation
import XCTest
@testable import Blocks
@testable import BlocksCore

@MainActor
final class CLIModuleAccessTests: XCTestCase {
    private func withPolicy(_ body: (CLIModuleAccessPolicy, UserDefaults) async throws -> Void) async throws {
        let name = "CLIModuleAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(CLIModuleAccessPolicy(defaults: defaults), defaults)
    }

    func testFreshPolicyDefaultsClosedAndPersistsOnlyExplicitModule() async throws {
        try await withPolicy { policy, defaults in
            XCTAssertTrue(policy.actions.isEmpty)
            XCTAssertTrue(CLIModule.allCases.allSatisfy { !policy.isEnabled($0) })
            policy.setEnabled(true, for: .clipboard)
            XCTAssertEqual(policy.actions.map(\.actionID), [BlocksAction.clipboardManage.actionID])
            let restored = CLIModuleAccessPolicy(defaults: defaults)
            XCTAssertTrue(restored.isEnabled(.clipboard))
            XCTAssertFalse(restored.isEnabled(.screenshot))
            XCTAssertFalse(restored.isEnabled(.translationSources))
            XCTAssertFalse(restored.isEnabled(.plugins))
            XCTAssertNil(CLIModule.module(for: ActionID(rawValue: "feedback.list")!))
            XCTAssertNil(CLIModule.module(for: ActionID(rawValue: "privacy.policy.get")!))
        }
    }

    func testHostListReadsLivePolicyAndModulesRemainIndependent() async throws {
        try await withPolicy { policy, _ in
            let service = ScreenshotActionHostService(executeHandler: { _, _ in Data() },
                cancelHandler: { _ in false }, moduleAccess: policy)
            func list() async throws -> [ActionID] {
                let bytes = await withCheckedContinuation { continuation in
                    service.listActions { continuation.resume(returning: $0) }
                }
                return try JSONDecoder().decode(CLIActionListResponse.self, from: bytes).actions.map(\.actionID)
            }
            let empty = try await list()
            XCTAssertTrue(empty.isEmpty)
            policy.setEnabled(true, for: .screenshot)
            policy.setEnabled(true, for: .clipboard)
            let both = try await list()
            XCTAssertTrue(both.contains(BlocksAction.clipboardManage.actionID))
            XCTAssertTrue(both.contains(BlocksAction.screenshotCapture.actionID))
            policy.setEnabled(false, for: .clipboard)
            let screenshotOnly = try await list()
            XCTAssertFalse(screenshotOnly.contains(BlocksAction.clipboardManage.actionID))
            XCTAssertTrue(screenshotOnly.contains(BlocksAction.screenshotCapture.actionID))
            XCTAssertFalse(screenshotOnly.contains(BlocksAction.translationSourceManage.actionID))
        }
    }

    func testDisabledHostModuleNeverInvokesBusinessHandler() async throws {
        try await withPolicy { policy, _ in
            var calls = 0
            let service = ScreenshotActionHostService(executeHandler: { _, _ in calls += 1; return Data() },
                cancelHandler: { _ in false }, moduleAccess: policy)
            for action in BlocksAction.allCases {
                let request = ActionBrokerRequest(requestID: .make(), actionID: action.actionID, payload: JSONValue.object([:]))
                let data = try JSONEncoder().encode(request)
                let response = await submit(service, data)
                let terminal = try JSONDecoder().decode(ActionBrokerTerminalResponse<JSONValue>.self, from: response)
                XCTAssertEqual(terminal.error?.code, "module_disabled", action.rawValue)
            }
            XCTAssertEqual(calls, 0)
        }
    }

    func testRevocationWhileAwaitingFullContentConsentDoesNotReadAfterReenable() async throws {
        try await withPolicy { policy, _ in
            policy.setEnabled(true, for: .clipboard)
            let consentEntered = expectation(description: "consent entered")
            var consent: CheckedContinuation<Bool, Never>?
            var fullReads = 0
            let access = ClipboardManagementAccessController(summaryAllowed: { true }, authorize: { _, _ in
                await withCheckedContinuation { continuation in
                    consent = continuation
                    consentEntered.fulfill()
                }
            })
            let request = ActionBrokerRequest(requestID: .make(), actionID: BlocksAction.clipboardManage.actionID,
                payload: ClipboardManagementActionInput(operation: "export", all: true))
            let data = try JSONEncoder().encode(request)
            let service = ScreenshotActionHostService(executeHandler: { _, _ in
                do {
                    let result = try await access.execute(request.payload) { input in
                        if !input.dryRun { fullReads += 1 }
                        var result = ClipboardManagementResult(operation: input.operation, dryRun: input.dryRun)
                        result.confirmationToken = "synthetic-private-token"
                        return result
                    }
                    return try JSONEncoder().encode(ActionBrokerTerminalResponse.completed(
                        requestID: request.requestID, actionID: request.actionID, result: result))
                } catch { return Data() }
            }, cancelHandler: { _ in false }, moduleAccess: policy)
            let task = Task { await submit(service, data) }
            await fulfillment(of: [consentEntered], timeout: 2)
            policy.setEnabled(false, for: .clipboard)
            service.revokeModule(.clipboard)
            policy.setEnabled(true, for: .clipboard)
            consent?.resume(returning: true)
            let response = await task.value
            XCTAssertEqual(fullReads, 0)
            let terminal = try JSONDecoder().decode(ActionBrokerTerminalResponse<JSONValue>.self, from: response)
            XCTAssertEqual(terminal.error?.code, "module_disabled")
        }
    }

    func testRevocationPreservesAlreadyCommittedMutationOutcome() async throws {
        try await withPolicy { policy, _ in
            policy.setEnabled(true, for: .clipboard)
            let committed = expectation(description: "synthetic write committed")
            var finish: CheckedContinuation<Void, Never>?
            let request = ActionBrokerRequest(requestID: .make(), actionID: BlocksAction.clipboardManage.actionID,
                payload: ClipboardManagementActionInput(operation: "import"))
            let service = ScreenshotActionHostService(executeHandler: { _, _ in
                await withCheckedContinuation { continuation in finish = continuation; committed.fulfill() }
                return (try? JSONEncoder().encode(ActionBrokerTerminalResponse.completed(
                    requestID: request.requestID, actionID: request.actionID, result: JSONValue.object(["committed": .bool(true)])))) ?? Data()
            }, cancelHandler: { _ in false }, moduleAccess: policy)
            let bytes = try JSONEncoder().encode(request)
            let task = Task { await submit(service, bytes) }
            await fulfillment(of: [committed], timeout: 2)
            policy.setEnabled(false, for: .clipboard)
            service.revokeModule(.clipboard)
            finish?.resume()
            let response = await task.value
            let terminal = try JSONDecoder().decode(ActionBrokerTerminalResponse<JSONValue>.self, from: response)
            XCTAssertEqual(terminal.status, .completed)
        }
    }

    func testOrdinaryCancellationIsNotMisreportedAsModuleDisabled() async throws {
        try await withPolicy { policy, _ in
            policy.setEnabled(true, for: .clipboard)
            let entered = expectation(description: "read started")
            let request = ActionBrokerRequest(requestID: .make(), actionID: BlocksAction.clipboardManage.actionID,
                payload: ClipboardManagementActionInput(operation: "list"))
            let service = ScreenshotActionHostService(executeHandler: { _, _ in
                entered.fulfill()
                do { try await Task.sleep(for: .seconds(10)) } catch {}
                return (try? JSONEncoder().encode(ActionBrokerTerminalResponse<JSONValue>.cancelled(
                    requestID: request.requestID, actionID: request.actionID,
                    code: "request_cancelled", message: "The request was cancelled."))) ?? Data()
            }, cancelHandler: { _ in false }, moduleAccess: policy)
            let bytes = try JSONEncoder().encode(request)
            let task = Task { await submit(service, bytes) }
            await fulfillment(of: [entered], timeout: 2)
            let accepted = await withCheckedContinuation { continuation in
                service.cancel(request.requestID.rawValue) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(accepted)
            let terminal = try JSONDecoder().decode(ActionBrokerTerminalResponse<JSONValue>.self, from: await task.value)
            XCTAssertEqual(terminal.status, .cancelled)
            XCTAssertEqual(terminal.error?.code, "request_cancelled")
            XCTAssertTrue(policy.isEnabled(.clipboard))
        }
    }

    private func submit(_ service: ScreenshotActionHostService, _ data: Data) async -> Data {
        await withCheckedContinuation { continuation in
            service.execute(data, outputFile: nil) { continuation.resume(returning: $0) }
        }
    }

    func testPluginRevocationDuringSnapshotLoadPreventsSynchronousMutation() async throws {
        // An unavailable in-memory manager plus an injected snapshot wait never
        // opens the user's plugin directories, keychain, or settings.
        let manager = BlocksNativePluginManager(storageUnavailableBecause: NSError(domain: "Synthetic", code: 1))
        let loading = expectation(description: "snapshot suspended")
        var resume: CheckedContinuation<Void, Never>?
        let service = PluginDevelopmentService(pluginManager: manager,
            runtime: BlocksPluginRuntimeCoordinator(manager: manager), loadSnapshot: {
                await withCheckedContinuation { continuation in resume = continuation; loading.fulfill() }
            })
        let requestID = ActionRequestID.make()
        let task = Task {
            try await service.execute(.init(operation: .clearLogs, pluginID: "synthetic.plugin", confirmed: true),
                requestID: requestID)
        }
        await fulfillment(of: [loading], timeout: 2)
        XCTAssertTrue(service.cancel(requestID.rawValue))
        resume?.resume()
        do { _ = try await task.value; XCTFail("Revoked request continued after snapshot loading") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
