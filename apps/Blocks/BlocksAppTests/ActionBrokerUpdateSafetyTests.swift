import BlocksCore
import Combine
import ServiceManagement
import XCTest
@testable import Blocks

@MainActor
final class ActionBrokerUpdateSafetyTests: XCTestCase {
    func testHostRequestAdmissionWaitsForTrustedReplacementRegistration() {
        let lifecycle = ActionBrokerHostConnectionLifecycle()
        let first = lifecycle.beginConnection().generation
        XCTAssertFalse(lifecycle.requestServiceResume())
        XCTAssertFalse(lifecycle.didRegisterTrustedHost(for: first), "unacknowledged endpoint must stay closed")
        XCTAssertTrue(lifecycle.claimCompletion(for: first))
        XCTAssertTrue(lifecycle.didRegisterTrustedHost(for: first))
        XCTAssertTrue(lifecycle.requestServiceResume(), "an unchanged verified endpoint can resume immediately")
        _ = lifecycle.stop()
        XCTAssertFalse(lifecycle.requestServiceResume())
        let replacement = lifecycle.beginConnection().generation
        XCTAssertFalse(lifecycle.didRegisterTrustedHost(for: first), "stale acknowledgement must not reopen admission")
        XCTAssertTrue(lifecycle.claimCompletion(for: replacement))
        XCTAssertTrue(lifecycle.didRegisterTrustedHost(for: replacement))
    }

    func testBrokerCannotFreezeOneConnectionWhileAnotherRequestIsActive() throws {
        let gate = ActionBrokerUpdateAdmission()
        let token = UUID().uuidString
        let request = try XCTUnwrap(gate.begin())
        XCTAssertThrowsError(try gate.prepare(token: token))
        let otherConnection = try XCTUnwrap(gate.begin())
        otherConnection.release()
        request.release()
        try gate.prepare(token: token)
        XCTAssertNil(gate.begin())
        try gate.resume(token: token)
        XCTAssertNotNil(gate.begin())
        XCTAssertThrowsError(try gate.prepare(token: token), "late prepare must not undo a cancellation")
    }

    func testBusyOrUnsupportedBrokerNeverReachesServiceUnregister() async throws {
        for error in [ActionBrokerUpdateError.busy, .unsupportedPeer] {
            let fixture = BrokerServiceUpdateFixture()
            fixture.host.prepareError = error
            if case .unsupportedPeer = error { fixture.host.resumeError = error }
            let manager = fixture.makeManager()
            do {
                try await manager.prepareForApplicationUpdate()
                XCTFail("unsafe Broker was accepted")
            } catch { }
            XCTAssertEqual(fixture.unregisterCount, 0)
            XCTAssertEqual(fixture.status, .enabled)
            XCTAssertTrue(manager.isEnabled)
            await manager.resumeAfterCancelledApplicationUpdate()
            XCTAssertEqual(fixture.unregisterCount, 0)
            XCTAssertEqual(fixture.host.resumeTokens.count, 1)
            if case .unsupportedPeer = error { XCTAssertNotNil(try fixture.journal.load()) }
        }
    }

    func testWaitsForAsyncServiceRemovalAndPreservesEnabledIntentUntilRecovery() async throws {
        let fixture = BrokerServiceUpdateFixture()
        var finishUnregister: CheckedContinuation<Void, Never>?
        let unregisterStarted = expectation(description: "async unregister entered after idle proof")
        fixture.unregister = {
            await withCheckedContinuation { continuation in
                finishUnregister = continuation
                unregisterStarted.fulfill()
            }
            fixture.status = .notRegistered
            fixture.processes = []
        }
        defer { fixture.unregister = nil }
        let manager = fixture.makeManager()
        var finished = false
        let preparation = Task {
            try await manager.prepareForApplicationUpdate()
            finished = true
        }
        await fulfillment(of: [unregisterStarted], timeout: 1)
        XCTAssertFalse(finished)
        XCTAssertEqual(fixture.host.prepareTokens.count, 1)
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertTrue(manager.isEnabled, "temporary service withdrawal must not change the user's preference")
        finishUnregister?.resume()
        try await preparation.value
        XCTAssertFalse(manager.isServiceRegistered)
        XCTAssertTrue(manager.isEnabled)
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(fixture.registerCount, 1)
        XCTAssertEqual(fixture.status, .enabled)
        XCTAssertEqual(fixture.host.resumeTokens, fixture.host.prepareTokens)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(manager.state, .enabled)
    }

    func testRecoveryRequiringUserApprovalKeepsTicketAndDoesNotClaimEnabled() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let manager = fixture.makeManager()
        try await manager.prepareForApplicationUpdate()
        fixture.registrationRequiresApproval = true
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(manager.state, .requiresApproval)
        XCTAssertFalse(manager.isServiceRegistered)
        XCTAssertTrue(manager.isEnabled, "saved intent is distinct from actual registration")
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty)
    }

    func testFailedUnregisterKeepsOldServiceAndResumesItsAdmission() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.unregister = { throw ActionBrokerUpdateError.serviceDidNotStop }
        let manager = fixture.makeManager()
        do { try await manager.prepareForApplicationUpdate(); XCTFail("unregister failure was hidden") }
        catch { }
        XCTAssertEqual(fixture.status, .enabled)
        XCTAssertEqual(fixture.processes, [77])
        XCTAssertNotNil(try fixture.journal.load())
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(fixture.registerCount, 0)
        XCTAssertEqual(fixture.host.resumeTokens, fixture.host.prepareTokens)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(manager.state, .enabled)
    }

    func testNewAppRestoresPreviouslyEnabledBrokerFromRecoveryJournal() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.status = .notRegistered
        fixture.processes = []
        let ticket = ActionBrokerUpdateRecoveryTicket(processID: 77)
        try fixture.journal.save(ticket)
        let started = expectation(description: "new host starts after journal recovery")
        fixture.host.didStart = { started.fulfill() }
        let manager = fixture.makeManager()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(fixture.registerCount, 1)
        XCTAssertEqual(fixture.host.resumeTokens, [ticket.token])
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(manager.state, .enabled)
    }

    func testQuitDuringStartupRecoveryPreservesJournalAndFencesLateCompletion() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let ticket = ActionBrokerUpdateRecoveryTicket(processID: 77)
        try fixture.journal.save(ticket)
        let entered = expectation(description: "remote recovery suspended")
        var release: CheckedContinuation<Void, Never>?
        fixture.host.onResume = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let manager = fixture.makeManager()
        await fulfillment(of: [entered], timeout: 1)
        manager.beginApplicationQuit()
        try await manager.prepareForApplicationUpdate(stopService: false)
        release?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.host.localResumeCount, 0)
    }

    func testDisabledPreferenceAndOrdinaryOfficialQuitDoNotToggleRegistration() async throws {
        let disabled = BrokerServiceUpdateFixture()
        disabled.status = .notRegistered
        disabled.processes = []
        let manager = disabled.makeManager()
        try await manager.prepareForApplicationUpdate()
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(disabled.unregisterCount, 0)
        XCTAssertEqual(disabled.registerCount, 0)
        XCTAssertFalse(manager.isEnabled)

        let enabled = BrokerServiceUpdateFixture()
        let ordinaryQuit = enabled.makeManager()
        try await ordinaryQuit.prepareForApplicationUpdate(stopService: false)
        XCTAssertEqual(enabled.unregisterCount, 0)
        XCTAssertTrue(enabled.host.prepareTokens.isEmpty)
        await ordinaryQuit.resumeAfterCancelledApplicationUpdate()
        XCTAssertTrue(ordinaryQuit.isEnabled)
    }

    func testLingeringUnregisteredBrokerFailsClosedWithoutKillingIt() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.status = .notRegistered
        fixture.processes = [77]
        let manager = fixture.makeManager()
        do { try await manager.prepareForApplicationUpdate(); XCTFail("lingering binary was ignored") }
        catch { }
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.processes, [77])
        await manager.resumeAfterCancelledApplicationUpdate()
    }
}

@MainActor
private final class BrokerServiceUpdateFixture {
    var status: SMAppService.Status = .enabled
    var processes: [Int32] = [77]
    var registerCount = 0
    var unregisterCount = 0
    var registrationRequiresApproval = false
    var unregister: (() async throws -> Void)?
    let host = BrokerServiceUpdateHost()
    let journal = ActionBrokerUpdateRecoveryJournal()

    func makeManager() -> ActionBrokerServiceManager {
        let control = ActionBrokerServiceControl(status: { self.status }, register: {
            self.registerCount += 1
            if self.registrationRequiresApproval {
                self.status = .requiresApproval
                throw ActionBrokerUpdateError.requiresApproval
            }
            self.status = .enabled
            self.processes = [88]
        }, unregister: {
            self.unregisterCount += 1
            self.status = .notRegistered
            self.processes = []
        }, unregisterAndWait: {
            self.unregisterCount += 1
            if let unregister = self.unregister { try await unregister() }
            else { self.status = .notRegistered; self.processes = [] }
        })
        return ActionBrokerServiceManager(service: control, host: host,
            retryScheduler: { _, _ in AnyCancellable {} }, updateRecoveryJournal: journal,
            runningBrokerProcessIDs: { self.processes }, processHasExited: { !self.processes.contains($0) })
    }
}

@MainActor
private final class BrokerServiceUpdateHost: ActionBrokerHosting {
    var onResume: (() async -> Void)?
    var localResumeCount = 0
    var prepareError: Error?
    var resumeError: Error?
    var prepareTokens: [String] = []
    var resumeTokens: [String] = []
    var didStart: (() -> Void)?
    func start(completion: @escaping (Result<Void, Error>) -> Void, onInvalidated: @escaping () -> Void) {
        completion(.success(())); didStart?()
    }
    func stop() {}
    func pauseAndDrainForApplicationUpdate() async throws {}
    func resumeAfterCancelledApplicationUpdate() { localResumeCount += 1 }
    func prepareBrokerForApplicationUpdate(token: String) async throws -> Int32 {
        prepareTokens.append(token)
        if let prepareError { throw prepareError }
        return 77
    }
    func resumeBrokerAfterCancelledApplicationUpdate(token: String) async throws {
        resumeTokens.append(token)
        await onResume?()
        if let resumeError { throw resumeError }
    }
}
