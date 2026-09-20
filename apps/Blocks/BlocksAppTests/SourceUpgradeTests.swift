import Foundation
import XCTest
import BlocksCore
@testable import Blocks

@MainActor
final class SourceUpgradeTests: XCTestCase {
    private typealias Response = SourceUpgradeProtocol.Response
    private typealias Operation = SourceUpgradeProtocol.Request.Operation

    private func send(_ coordinator: SourceUpgradeCoordinator, _ operation: Operation,
                      session: UUID, token: UUID) async -> Response {
        await withCheckedContinuation { continuation in
            coordinator.handle(sessionID: session, request: .init(token: token, operation: operation)) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected state transition", file: file, line: line)
    }

    func testProbeHasNoLifecycleEffectsAndCommitRequiresPreparation() async {
        var calls = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true },
            prepare: { calls += 1 }, resume: { calls += 1 }, terminate: { calls += 1 })
        let session = UUID(), token = UUID()
        let probe = await send(coordinator, .probe, session: session, token: token)
        XCTAssertEqual(probe.status, .ready)
        let commit = await send(coordinator, .commit, session: session, token: token)
        XCTAssertEqual(commit.errorCode, "invalid_state")
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(coordinator.hasTransaction)
    }

    func testDisconnectBeforeQueuedPrepareRejectsLateSessionWithoutLifecycleEffects() async {
        var calls = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true },
            prepare: { calls += 1 }, resume: { calls += 1 }, terminate: { calls += 1 })
        let session = UUID(), token = UUID()
        coordinator.disconnected(sessionID: session)
        for operation: Operation in [.probe, .prepare, .commit, .cancel] {
            let response = await send(coordinator, operation, session: session, token: token)
            XCTAssertEqual(response.errorCode, "disconnected")
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.hasTransaction)
    }

    func testDisconnectedSessionHistoryExhaustionFailsClosedWithoutEviction() async {
        var calls = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true },
            prepare: { calls += 1 }, resume: {}, terminate: {})
        let firstSession = UUID()
        coordinator.disconnected(sessionID: firstSession)
        for _ in 1..<4096 { coordinator.disconnected(sessionID: UUID()) }
        let atCapacity = await send(coordinator, .prepare, session: UUID(), token: UUID())
        XCTAssertEqual(atCapacity.errorCode, "busy")
        let overflowSession = UUID()
        coordinator.disconnected(sessionID: overflowSession)
        for session in [firstSession, overflowSession, UUID()] {
            let response = await send(coordinator, .prepare, session: session, token: UUID())
            XCTAssertEqual(response.errorCode, "disconnected")
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(coordinator.hasTransaction)
    }

    func testTransactionBindsSessionAndTokenAndRejectsReplay() async {
        let session = UUID(), token = UUID()
        var resumes = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {},
            resume: { resumes += 1 }, terminate: {})
        let prepared = await send(coordinator, .prepare, session: session, token: token)
        XCTAssertEqual(prepared.status, .prepared)
        for operation: Operation in [.prepare, .commit, .cancel] {
            let wrongSession = await send(coordinator, operation, session: UUID(), token: token)
            XCTAssertEqual(wrongSession.errorCode, "busy")
            let wrongToken = await send(coordinator, operation, session: session, token: UUID())
            XCTAssertEqual(wrongToken.errorCode, "busy")
        }
        XCTAssertEqual(resumes, 0)
        coordinator.disconnected(sessionID: UUID())
        XCTAssertEqual(coordinator.phase, .prepared)
        let cancelled = await send(coordinator, .cancel, session: session, token: token)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(resumes, 1)
        let replay = await send(coordinator, .prepare, session: UUID(), token: token)
        XCTAssertEqual(replay.errorCode, "invalid_state")
    }

    func testCommitOnlyQuitsAfterMatchingSuccessfulWrite() async {
        let session = UUID(), token = UUID()
        var exits = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {}, resume: {},
                                                   terminate: { exits += 1 })
        _ = await send(coordinator, .prepare, session: session, token: token)
        coordinator.didCommit(sessionID: session, token: token)
        XCTAssertEqual(exits, 0)
        let committed = await send(coordinator, .commit, session: session, token: token)
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(exits, 0)
        coordinator.didCommit(sessionID: UUID(), token: token)
        coordinator.didCommit(sessionID: session, token: UUID())
        XCTAssertEqual(exits, 0)
        coordinator.didCommit(sessionID: session, token: token)
        coordinator.didCommit(sessionID: session, token: token)
        coordinator.disconnected(sessionID: session)
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(coordinator.phase, .terminated)
    }

    func testCommitWriteFailureDisconnectRecoversWithoutExit() async {
        let session = UUID(), token = UUID()
        var exits = 0, resumes = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {},
            resume: { resumes += 1 }, terminate: { exits += 1 })
        _ = await send(coordinator, .prepare, session: session, token: token)
        _ = await send(coordinator, .commit, session: session, token: token)
        coordinator.disconnected(sessionID: session)
        await waitFor { coordinator.phase == .idle }
        coordinator.didCommit(sessionID: session, token: token)
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(exits, 0)
    }

    func testCommitAcknowledgementOwnsDeadlineUntilTransportCompletion() async throws {
        let session = UUID(), token = UUID()
        var exits = 0, resumes = 0
        let coordinator = SourceUpgradeCoordinator(timeout: .milliseconds(100), canPrepare: { true },
            prepare: {}, resume: { resumes += 1 }, terminate: { exits += 1 })
        _ = await send(coordinator, .prepare, session: session, token: token)
        let response = await send(coordinator, .commit, session: session, token: token)
        XCTAssertEqual(response.status, .committed)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coordinator.phase, .committing)
        XCTAssertEqual(resumes, 0)
        coordinator.didCommit(sessionID: session, token: token)
        coordinator.didCommit(sessionID: session, token: token)
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(resumes, 0)
    }

    func testDisconnectWaitsForLatePrepareAndRecoveryBeforeNewOwner() async {
        let session = UUID(), token = UUID()
        var prepareContinuation: CheckedContinuation<Void, Never>?
        var resumeContinuation: CheckedContinuation<Void, Never>?
        var exits = 0, events: [String] = []
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {
            events.append("prepare")
            await withCheckedContinuation { prepareContinuation = $0 }
            events.append("prepared-late")
        }, resume: {
            XCTAssertFalse(Task.isCancelled)
            events.append("resume")
            await withCheckedContinuation { resumeContinuation = $0 }
            events.append("resumed")
        }, terminate: { exits += 1 })
        let pending = Task { await send(coordinator, .prepare, session: session, token: token) }
        await waitFor { prepareContinuation != nil }
        coordinator.disconnected(sessionID: session)
        let busy = await send(coordinator, .prepare, session: UUID(), token: UUID())
        XCTAssertEqual(busy.errorCode, "busy")
        XCTAssertEqual(events, ["prepare"])
        prepareContinuation?.resume()
        await waitFor { resumeContinuation != nil }
        XCTAssertTrue(coordinator.hasTransaction)
        let duringResume = await send(coordinator, .prepare, session: UUID(), token: UUID())
        XCTAssertEqual(duringResume.errorCode, "busy")
        coordinator.didCommit(sessionID: session, token: token)
        resumeContinuation?.resume()
        let failed = await pending.value
        XCTAssertEqual(failed.errorCode, "disconnected")
        XCTAssertEqual(events, ["prepare", "prepared-late", "resume", "resumed"])
        XCTAssertFalse(coordinator.hasTransaction)
        XCTAssertEqual(exits, 0)
    }

    func testPreparationFailureIsRedactedAndRecovers() async {
        var resumes = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {
            throw NSError(domain: "/Users/private/path", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "secret"])
        }, resume: { resumes += 1 }, terminate: { XCTFail("Must not quit") })
        let response = await send(coordinator, .prepare, session: UUID(), token: UUID())
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, "preparation_failed")
        XCTAssertEqual(resumes, 1)
        XCTAssertFalse(coordinator.hasTransaction)
    }

    func testCancelDuringPreparationThenLateOldMessagesCannotAffectNewOwner() async {
        var continuation: CheckedContinuation<Void, Never>?
        var prepares = 0, resumes = 0, exits = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {
            prepares += 1
            if prepares == 1 { await withCheckedContinuation { continuation = $0 } }
        }, resume: { resumes += 1 }, terminate: { exits += 1 })
        let oldSession = UUID(), oldToken = UUID()
        let preparing = Task { await send(coordinator, .prepare, session: oldSession, token: oldToken) }
        await waitFor { continuation != nil }
        let cancelFinished = expectation(description: "Cancellation resumes before replying")
        coordinator.handle(sessionID: oldSession, request: .init(token: oldToken, operation: .cancel)) {
            XCTAssertEqual($0.status, .cancelled)
            cancelFinished.fulfill()
        }
        XCTAssertTrue(coordinator.hasTransaction)
        continuation?.resume()
        let cancelledPreparation = await preparing.value
        XCTAssertEqual(cancelledPreparation.errorCode, "cancelled")
        await fulfillment(of: [cancelFinished], timeout: 1)
        let newSession = UUID(), newToken = UUID()
        _ = await send(coordinator, .prepare, session: newSession, token: newToken)
        coordinator.disconnected(sessionID: oldSession)
        coordinator.didCommit(sessionID: oldSession, token: oldToken)
        let lateCancel = await send(coordinator, .cancel, session: oldSession, token: oldToken)
        XCTAssertEqual(lateCancel.errorCode, "disconnected")
        XCTAssertEqual(coordinator.phase, .prepared)
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(exits, 0)
        _ = await send(coordinator, .cancel, session: newSession, token: newToken)
    }

    func testQuitAfterPreparationPreventsCommitAndDisconnectRecovery() async {
        var resumes = 0, exits = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {},
            resume: { resumes += 1 }, terminate: { exits += 1 })
        let session = UUID(), token = UUID()
        _ = await send(coordinator, .prepare, session: session, token: token)
        coordinator.beginQuit()
        coordinator.disconnected(sessionID: session)
        let committed = await send(coordinator, .commit, session: session, token: token)
        XCTAssertEqual(committed.errorCode, "quitting")
        coordinator.didCommit(sessionID: session, token: token)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(exits, 0)
    }

    func testTimeoutRecoversPreparedTransaction() async {
        var resumes = 0
        let coordinator = SourceUpgradeCoordinator(timeout: .milliseconds(30), canPrepare: { true },
            prepare: {}, resume: { resumes += 1 }, terminate: { XCTFail("Must not quit") })
        _ = await send(coordinator, .prepare, session: UUID(), token: UUID())
        await waitFor { coordinator.phase == .idle }
        XCTAssertEqual(resumes, 1)
    }

    func testOtherUpdaterOwnsLifecycleUntilRecoveryFinishes() async {
        var sparkleOwnsLifecycle = true, calls = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { !sparkleOwnsLifecycle },
            prepare: { calls += 1 }, resume: {}, terminate: {})
        let session = UUID(), token = UUID()
        let busy = await send(coordinator, .prepare, session: session, token: token)
        XCTAssertEqual(busy.errorCode, "busy")
        XCTAssertEqual(calls, 0)
        sparkleOwnsLifecycle = false
        let prepared = await send(coordinator, .prepare, session: session, token: token)
        XCTAssertEqual(prepared.status, .prepared)
        _ = await send(coordinator, .cancel, session: session, token: token)
    }

    func testQuitFencesLatePreparationAndRecovery() async {
        var continuation: CheckedContinuation<Void, Never>?
        var resumes = 0, exits = 0
        let coordinator = SourceUpgradeCoordinator(canPrepare: { true }, prepare: {
            await withCheckedContinuation { continuation = $0 }
        }, resume: { resumes += 1 }, terminate: { exits += 1 })
        let session = UUID(), token = UUID()
        let pending = Task { await send(coordinator, .prepare, session: session, token: token) }
        await waitFor { continuation != nil }
        coordinator.beginQuit()
        continuation?.resume()
        let failed = await pending.value
        XCTAssertEqual(failed.errorCode, "quitting")
        coordinator.didCommit(sessionID: session, token: token)
        let probe = await send(coordinator, .probe, session: session, token: UUID())
        XCTAssertEqual(probe.errorCode, "quitting")
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(exits, 0)
    }

    func testSynchronousLifecycleQuitFencePreventsParticipantResume() async throws {
        // Restore only the test-global admission fence for subsequent tests.
        defer { ApplicationOperationAdmissionGate.resumeAll() }
        let lifecycle = ApplicationLifecycleCoordinator(requiredParticipantIDs: ["remote"])
        var continuation: CheckedContinuation<Void, Never>?
        var resumes = 0
        try lifecycle.register(.init(id: "remote", pauseAndDrain: {
            await withCheckedContinuation { continuation = $0 }
        }, resume: { resumes += 1 }))
        let pending = Task { try await lifecycle.prepare() }
        await waitFor { continuation != nil }
        lifecycle.beginQuit()
        pending.cancel()
        continuation?.resume()
        do { try await pending.value; XCTFail("Quit must abort update") } catch {}
        await lifecycle.resumeAfterCancelledUpdate()
        XCTAssertEqual(resumes, 0)
    }

    func testCancelledBrokerPreparationResumesOnUncancelledTaskBeforeReleasingOwner() async throws {
        defer { ApplicationOperationAdmissionGate.resumeAll() }
        let lifecycle = ApplicationLifecycleCoordinator(requiredParticipantIDs: ["actionBroker"])
        var preparedReply: CheckedContinuation<Void, Never>?
        var resumeReply: CheckedContinuation<Void, Never>?
        var brokerPaused = false
        try lifecycle.register(.init(id: "actionBroker", pauseAndDrain: {
            brokerPaused = true
            // Models the broker closing admission before returning prepare ACK.
            await withCheckedContinuation { preparedReply = $0 }
            try Task.checkCancellation()
        }, resume: {
            do { try Task.checkCancellation() } catch {
                XCTFail("Remote lifecycle resume inherited cancelled prepare")
                return
            }
            await withCheckedContinuation { resumeReply = $0 }
            brokerPaused = false
        }))
        let coordinator = SourceUpgradeCoordinator(canPrepare: { lifecycle.state == .active },
            prepare: { try await lifecycle.prepare() },
            resume: { await lifecycle.resumeAfterCancelledUpdate() },
            terminate: { XCTFail("Cancelled transaction must not quit") })
        let session = UUID(), token = UUID()
        let pending = Task { await send(coordinator, .prepare, session: session, token: token) }
        await waitFor { preparedReply != nil }
        coordinator.disconnected(sessionID: session)
        preparedReply?.resume()
        await waitFor { resumeReply != nil }
        XCTAssertEqual(lifecycle.state, .resuming)
        XCTAssertTrue(coordinator.hasTransaction)
        XCTAssertTrue(brokerPaused)
        resumeReply?.resume()
        let response = await pending.value
        XCTAssertEqual(response.errorCode, "disconnected")
        XCTAssertFalse(brokerPaused)
        XCTAssertFalse(coordinator.hasTransaction)
        XCTAssertEqual(lifecycle.state, .active)
    }

    func testPreparedRecoveryDoesNotInheritCancelledCaller() async throws {
        defer { ApplicationOperationAdmissionGate.resumeAll() }
        let lifecycle = ApplicationLifecycleCoordinator(requiredParticipantIDs: ["remote"])
        var resumed = false
        try lifecycle.register(.init(id: "remote", pauseAndDrain: {}, resume: {
            do { try Task.checkCancellation() } catch {
                XCTFail("Prepared recovery inherited cancelled caller")
                return
            }
            resumed = true
        }))
        try await lifecycle.prepare()
        let recovery = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await lifecycle.resumeAfterCancelledUpdate()
        }
        await recovery.value
        XCTAssertTrue(resumed)
        XCTAssertEqual(lifecycle.state, .active)
    }

    func testQuitDuringTrackedRecoveryCancelsRemoteResumeAndSkipsLaterParticipants() async throws {
        defer { ApplicationOperationAdmissionGate.resumeAll() }
        let lifecycle = ApplicationLifecycleCoordinator(requiredParticipantIDs: ["producer", "remote"])
        var resumeContinuation: CheckedContinuation<Void, Never>?
        var resumed: [String] = []
        try lifecycle.register(.init(id: "producer", pauseAndDrain: {}, resume: {
            resumed.append("producer")
        }))
        try lifecycle.register(.init(id: "remote", pauseAndDrain: {}, resume: {
            await withCheckedContinuation { resumeContinuation = $0 }
            // Mirrors the remote command's cancellation check before sending.
            do { try Task.checkCancellation() } catch { return }
            resumed.append("remote")
        }))
        try await lifecycle.prepare()
        let recovery = Task { await lifecycle.resumeAfterCancelledUpdate() }
        await waitFor { resumeContinuation != nil }
        lifecycle.beginQuit()
        resumeContinuation?.resume()
        await recovery.value
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertEqual(lifecycle.state, .resuming)
        let gate = ApplicationOperationAdmissionGate(name: "quit-fence-test")
        XCTAssertNil(gate.begin())
    }
}
