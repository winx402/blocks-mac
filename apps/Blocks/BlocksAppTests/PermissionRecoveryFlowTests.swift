import Combine
import Foundation
import XCTest
@testable import Blocks

@MainActor
final class PermissionRecoveryFlowTests: XCTestCase {
    func testOfficialSignedDeniedCheckOffersRestartForEachSelectedPermissionWithoutPrompting() async {
        for kind in [PermissionDiagnosticKind.screenRecording, .accessibility, .inputMonitoring] {
            let fixture = makeFixture()
            await waitUntil { fixture.provider.calls == 1 }

            fixture.store.beginPermissionRecovery(for: kind)
            await waitUntil { fixture.store.recoveryState?.stage == .restartSuggested }

            XCTAssertEqual(fixture.store.recoveryState?.kind, kind)
            XCTAssertEqual(fixture.provider.calls, 4, "One initial sample and three bounded recovery samples")
            XCTAssertEqual(fixture.actions.restartCount, 0)
            XCTAssertEqual(fixture.requester.requestCount, 0)
            XCTAssertEqual(fixture.store.permissionSnapshot.diagnostic(for: kind).signatureKind, "signed")
            fixture.tickets.clear()
        }
    }

    func testPassingCheckRecoversOnlySelectedPermissionAndDoesNotRestart() async {
        let fixture = makeFixture()
        await waitUntil { fixture.provider.calls == 1 }
        fixture.provider.value = snapshot(accessibility: true, postEvent: false)

        fixture.store.beginPermissionRecovery(for: .accessibility)
        await waitUntil { fixture.store.recoveryState?.stage == .recovered }

        XCTAssertEqual(fixture.provider.calls, 2)
        XCTAssertFalse(fixture.store.permissionSnapshot.screenRecordingGranted)
        XCTAssertFalse(fixture.store.permissionSnapshot.inputMonitoringGranted)
        XCTAssertEqual(fixture.store.permissionSnapshot.postEventAccessGranted, false)
        XCTAssertEqual(fixture.actions.restartCount, 0)
        XCTAssertEqual(fixture.requester.requestCount, 0)
        fixture.tickets.clear()
    }

    func testFixedCertificateAndAdHocHaveSameRecoveryEligibility() async {
        for signature in ["signed-no-team", "adhoc", "unknown"] {
            let fixture = makeFixture(initial: snapshot(signature: signature))
            await waitUntil { fixture.provider.calls == 1 }
            fixture.store.beginPermissionRecovery(for: .screenRecording)
            await waitUntil { fixture.store.recoveryState?.stage == .restartSuggested }
            XCTAssertTrue(fixture.store.recoveryState?.canRestart == true)
            fixture.tickets.clear()
        }
    }

    func testDuplicateRecoveryAndPassiveRefreshShareOneFlightAndRunRetainedCompletionOnce() async {
        let provider = ControlledRecoverySnapshotProvider(initial: snapshot())
        let actions = RecoverySystemActions()
        let requester = RecoveryAccessRequester()
        let tickets = isolatedTickets()
        let store = makeStore(provider: provider, requester: requester, actions: actions, tickets: tickets)
        await waitUntil { provider.calls == 1 }
        provider.finish(0, with: snapshot())
        await waitUntil { provider.returned.contains(0) }

        store.beginPermissionRecovery(for: .accessibility)
        await waitUntil { provider.calls == 2 }
        var callbackCount = 0
        store.beginPermissionRecovery(for: .inputMonitoring)
        store.restartPermissionRecovery()
        store.requestAccessibilityPermissionAssist()
        store.requestInputMonitoringPermissionAssist()
        store.refreshPermissionState { callbackCount += 1 }
        store.refreshPermissionState()
        await Task.yield()

        XCTAssertEqual(provider.calls, 2)
        XCTAssertEqual(store.recoveryState?.kind, .accessibility)
        XCTAssertEqual(actions.restartCount, 0)
        XCTAssertEqual(requester.requestCount, 0)
        provider.finish(1, with: snapshot(accessibility: true))
        await waitUntil { store.recoveryState?.stage == .recovered }
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(provider.calls, 2)
        tickets.clear()
    }

    func testLatePassiveResultCannotOverwriteRecoverySnapshotOrOutcome() async {
        let provider = ControlledRecoverySnapshotProvider(initial: snapshot())
        let tickets = isolatedTickets()
        let store = makeStore(provider: provider, actions: RecoverySystemActions(), tickets: tickets)
        await waitUntil { provider.calls == 1 }
        store.beginPermissionRecovery(for: .screenRecording)
        await waitUntil { provider.calls == 2 }
        let granted = snapshot(screenRecording: true, capturedAt: Date(timeIntervalSince1970: 2))
        provider.finish(1, with: granted)
        await waitUntil { store.recoveryState?.stage == .recovered }

        provider.finish(0, with: snapshot(capturedAt: Date(timeIntervalSince1970: 1)))
        await waitUntil { provider.returned.contains(0) }
        await Task.yield()
        XCTAssertEqual(store.permissionSnapshot, granted)
        XCTAssertEqual(store.recoveryState?.stage, .recovered)
        tickets.clear()
    }

    func testFailedHandoffClearsTicketKeepsAppAndIgnoresDuplicateCallback() async {
        let fixture = makeFixture()
        await suggestRestart(fixture)
        fixture.store.restartPermissionRecovery()
        XCTAssertEqual(fixture.store.recoveryState?.stage, .restarting)
        XCTAssertNil(fixture.store.pendingPermissionRecoveryKind, "The writing process cannot consume its own ticket")
        fixture.store.restartPermissionRecovery()
        XCTAssertEqual(fixture.actions.restartCount, 1)

        fixture.actions.complete(.failed)
        fixture.actions.complete(.scheduled)
        XCTAssertEqual(fixture.store.recoveryState?.stage, .restartFailed)
        XCTAssertNil(fixture.tickets.pendingTicket(for: 202))
        XCTAssertEqual(fixture.actions.restartCount, 1)
        XCTAssertEqual(fixture.requester.requestCount, 0)
        fixture.tickets.clear()
    }

    func testScheduledHandoffIsNotRecoveryAndCannotBeConsumedBySameProcess() async {
        let fixture = makeFixture()
        await suggestRestart(fixture)
        fixture.store.restartPermissionRecovery()
        fixture.actions.complete(.scheduled)
        await waitUntil { fixture.wait.watchdogStarted }

        XCTAssertEqual(fixture.store.recoveryState?.stage, .restartScheduled)
        XCTAssertTrue(fixture.store.recoveryState?.isInFlight == true)
        XCTAssertFalse(fixture.store.resumePendingPermissionRecovery())
        fixture.store.beginPermissionRecovery(for: .inputMonitoring)
        fixture.store.restartPermissionRecovery()
        XCTAssertEqual(fixture.actions.restartCount, 1)
        XCTAssertEqual(fixture.tickets.pendingTicket(for: 202)?.kind, .screenRecording)

        let sameProcessStore = makeStore(
            provider: ImmediateRecoverySnapshotProvider(value: snapshot(screenRecording: true)),
            actions: RecoverySystemActions(),
            tickets: fixture.tickets,
            processID: 101
        )
        XCTAssertNil(sameProcessStore.pendingPermissionRecoveryKind)
        XCTAssertFalse(sameProcessStore.resumePendingPermissionRecovery())
        XCTAssertEqual(fixture.tickets.pendingTicket(for: 202)?.kind, .screenRecording)
        fixture.tickets.clear()
        fixture.wait.releaseWatchdog()
    }

    func testCancelledExitReturnsFailureAndClearsTicketWithoutAutomaticallyRestarting() async {
        let fixture = makeFixture()
        await suggestRestart(fixture)
        fixture.store.restartPermissionRecovery()
        fixture.actions.complete(.scheduled)
        await waitUntil { fixture.wait.watchdogStarted }
        fixture.wait.releaseWatchdog()
        await waitUntil { fixture.store.recoveryState?.stage == .restartFailed }

        XCTAssertTrue(fixture.store.recoveryState?.canRestart == true)
        XCTAssertNil(fixture.tickets.pendingTicket(for: 202))
        XCTAssertEqual(fixture.actions.restartCount, 1)
        XCTAssertFalse(fixture.store.permissionSnapshot.screenRecordingGranted)
        fixture.tickets.clear()
    }

    func testNewProcessConsumesOnceAndChecksAutomaticallyWithoutRestartOrPrompt() async {
        for granted in [false, true] {
            let tickets = isolatedTickets()
            tickets.save(
                PermissionRecoveryTicket(kind: .inputMonitoring, stage: .restartScheduled),
                originatingProcessID: 101
            )
            let provider = ImmediateRecoverySnapshotProvider(value: snapshot(inputMonitoring: granted, processID: 202))
            let actions = RecoverySystemActions()
            let requester = RecoveryAccessRequester()
            let store = makeStore(provider: provider, requester: requester, actions: actions, tickets: tickets, processID: 202)

            XCTAssertEqual(store.pendingPermissionRecoveryKind, .inputMonitoring)
            XCTAssertTrue(store.resumePendingPermissionRecovery())
            XCTAssertEqual(store.recoveryState?.stage, .resumingAfterRestart)
            XCTAssertNil(store.pendingPermissionRecoveryKind)
            XCTAssertFalse(store.resumePendingPermissionRecovery())
            await waitUntil { store.recoveryState?.stage == (granted ? .recovered : .needsReauthorization) }

            XCTAssertEqual(store.recoveryState?.kind, .inputMonitoring)
            XCTAssertEqual(actions.restartCount, 0)
            XCTAssertEqual(requester.requestCount, 0)
            XCTAssertNil(tickets.pendingTicket(for: 303))
            tickets.clear()
        }
    }

    func testNewProcessCanResumeInterruptedHandoffWithoutClaimingRestartSuccess() async {
        let tickets = isolatedTickets()
        tickets.save(PermissionRecoveryTicket(kind: .accessibility, stage: .restarting), originatingProcessID: 101)
        let store = makeStore(
            provider: ImmediateRecoverySnapshotProvider(value: snapshot(processID: 202)),
            actions: RecoverySystemActions(),
            tickets: tickets,
            processID: 202
        )
        XCTAssertTrue(store.resumePendingPermissionRecovery())
        await waitUntil { store.recoveryState?.stage == .needsReauthorization }
        XCTAssertEqual(store.recoveryState?.kind, .accessibility)
        tickets.clear()
    }

    func testReauthorizationRecheckDoesNotRestartAndCanRecover() async {
        let tickets = isolatedTickets()
        tickets.save(PermissionRecoveryTicket(kind: .accessibility, stage: .restartScheduled), originatingProcessID: 101)
        let provider = ImmediateRecoverySnapshotProvider(value: snapshot(processID: 202))
        let actions = RecoverySystemActions()
        let store = makeStore(provider: provider, actions: actions, tickets: tickets, processID: 202)
        XCTAssertTrue(store.resumePendingPermissionRecovery())
        await waitUntil { store.recoveryState?.stage == .needsReauthorization }
        XCTAssertTrue(store.recoveryState?.canRestart == true,
                      "Re-adding the current app may require another explicit restart")
        store.recheckPermissionRecovery()
        await waitUntil { store.recoveryState?.stage == .needsReauthorization }
        XCTAssertEqual(actions.restartCount, 0)

        provider.value = snapshot(accessibility: true, postEvent: false, processID: 202)
        store.recheckPermissionRecovery()
        await waitUntil { store.recoveryState?.stage == .recovered }
        XCTAssertEqual(store.permissionSnapshot.postEventAccessGranted, false)
        XCTAssertEqual(actions.restartCount, 0)
        tickets.clear()
    }

    func testAXAndPostEventRemainIndependentInBothDirections() async {
        let fixture = makeFixture()
        await waitUntil { fixture.provider.calls == 1 }
        fixture.provider.value = snapshot(accessibility: false, postEvent: true)
        fixture.store.beginPermissionRecovery(for: .accessibility)
        await waitUntil { fixture.store.recoveryState?.stage == .restartSuggested }
        XCTAssertEqual(fixture.store.permissionSnapshot.postEventAccessGranted, true)
        XCTAssertFalse(fixture.store.permissionSnapshot.accessibilityGranted)

        fixture.provider.value = snapshot(accessibility: true, postEvent: false)
        fixture.store.recheckPermissionRecovery()
        await waitUntil { fixture.store.recoveryState?.stage == .recovered }
        XCTAssertTrue(fixture.store.permissionSnapshot.accessibilityGranted)
        XCTAssertEqual(fixture.store.permissionSnapshot.postEventAccessGranted, false)
        fixture.tickets.clear()
    }

    func testTicketStoresOnlyKindAndStageAndSurvivesRepositoryRecreation() throws {
        let suite = "PermissionRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = suite + ".ticket"
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UserDefaultsPermissionRecoveryTicketStore(defaults: defaults, key: key)
        let ticket = PermissionRecoveryTicket(kind: .screenRecording, stage: .restartScheduled)
        first.save(ticket, originatingProcessID: 101)
        let data = try XCTUnwrap(defaults.data(forKey: key))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(raw.keys), ["kind", "stage"])

        let recreated = UserDefaultsPermissionRecoveryTicketStore(defaults: defaults, key: key)
        XCTAssertNil(recreated.consume(for: 101), "Recreating the repository is not a new process")
        XCTAssertEqual(recreated.consume(for: 202), ticket)
        XCTAssertNil(recreated.consume(for: 202))
        recreated.clear()
    }

    func testUnsupportedOrMalformedPersistedStageIsDiscarded() throws {
        let suite = "PermissionRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = suite + ".ticket"
        defer { defaults.removePersistentDomain(forName: suite) }
        let tickets = UserDefaultsPermissionRecoveryTicketStore(defaults: defaults, key: key)
        defaults.set(try JSONEncoder().encode(PermissionRecoveryTicket(kind: .accessibility, stage: .recovered)), forKey: key)
        XCTAssertNil(tickets.pendingTicket(for: 202))
        XCTAssertNil(defaults.data(forKey: key))
        defaults.set(Data("invalid ticket".utf8), forKey: key)
        XCTAssertNil(tickets.pendingTicket(for: 202))
        XCTAssertNil(defaults.data(forKey: key))
        tickets.clear()
    }

    private func suggestRestart(_ fixture: Fixture) async {
        await waitUntil { fixture.provider.calls == 1 }
        fixture.store.beginPermissionRecovery(for: .screenRecording)
        await waitUntil { fixture.store.recoveryState?.stage == .restartSuggested }
    }

    private struct Fixture {
        let store: PermissionStore
        let provider: ImmediateRecoverySnapshotProvider
        let requester: RecoveryAccessRequester
        let actions: RecoverySystemActions
        let tickets: UserDefaultsPermissionRecoveryTicketStore
        let wait: RecoveryWaitController
    }

    private func makeFixture(initial: PermissionStateSnapshot? = nil) -> Fixture {
        let provider = ImmediateRecoverySnapshotProvider(value: initial ?? snapshot())
        let requester = RecoveryAccessRequester()
        let actions = RecoverySystemActions()
        let tickets = isolatedTickets()
        let wait = RecoveryWaitController()
        let store = makeStore(provider: provider, requester: requester, actions: actions, tickets: tickets, wait: wait.wait)
        return Fixture(store: store, provider: provider, requester: requester, actions: actions, tickets: tickets, wait: wait)
    }

    private func makeStore(
        provider: PermissionSnapshotProviding,
        requester: RecoveryAccessRequester? = nil,
        actions: RecoverySystemActions,
        tickets: PermissionRecoveryPersisting,
        wait: @escaping PermissionStore.RecoveryWait = { _ in await Task.yield() },
        processID: Int32 = 101
    ) -> PermissionStore {
        PermissionStore(
            snapshotProvider: provider,
            accessRequester: requester ?? RecoveryAccessRequester(),
            assistPresenter: RecoveryAssistPresenter(),
            systemActions: actions,
            systemPromptGate: PermissionSystemPromptGate(),
            recoveryTickets: tickets,
            recoveryWait: wait,
            processID: processID
        )
    }

    private func isolatedTickets() -> UserDefaultsPermissionRecoveryTicketStore {
        let suite = "PermissionRecoveryTests.\(UUID().uuidString)"
        return UserDefaultsPermissionRecoveryTicketStore(defaults: UserDefaults(suiteName: suite)!, key: suite + ".ticket")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for recovery transition", file: file, line: line)
    }

    private func snapshot(
        screenRecording: Bool = false,
        accessibility: Bool = false,
        inputMonitoring: Bool = false,
        postEvent: Bool? = nil,
        signature: String = "signed",
        processID: Int32? = 101,
        capturedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> PermissionStateSnapshot {
        func diagnostic(_ kind: PermissionDiagnosticKind, _ granted: Bool) -> PermissionDiagnosticSnapshot {
            PermissionDiagnosticSnapshot(
                kind: kind, granted: granted, bundleID: "app.blocks.app",
                appPath: "/Applications/Blocks.app", signatureKind: signature,
                teamID: signature == "signed" ? "KF86YN2FLJ" : nil,
                hasUsageDescription: true, lastCheckedAt: capturedAt,
                recommendedAction: granted ? .granted : .requestInSystemSettings,
                matchingRunningAppPaths: ["/Applications/Blocks.app"], identityIssue: .none
            )
        }
        return PermissionStateSnapshot(
            screenRecording: diagnostic(.screenRecording, screenRecording),
            accessibility: diagnostic(.accessibility, accessibility),
            inputMonitoring: diagnostic(.inputMonitoring, inputMonitoring),
            capturedAt: capturedAt, postEventAccessGranted: postEvent, sampledProcessID: processID
        )
    }
}

@MainActor
private final class ImmediateRecoverySnapshotProvider: PermissionSnapshotProviding {
    var value: PermissionStateSnapshot
    private(set) var calls = 0
    init(value: PermissionStateSnapshot) { self.value = value }
    func initialSnapshot() -> PermissionStateSnapshot { value }
    func snapshot() async -> PermissionStateSnapshot {
        calls += 1
        return value
    }
}

@MainActor
private final class ControlledRecoverySnapshotProvider: PermissionSnapshotProviding {
    private let initial: PermissionStateSnapshot
    private var continuations: [Int: CheckedContinuation<PermissionStateSnapshot, Never>] = [:]
    private(set) var calls = 0
    private(set) var returned = Set<Int>()
    init(initial: PermissionStateSnapshot) { self.initial = initial }
    func initialSnapshot() -> PermissionStateSnapshot { initial }
    func snapshot() async -> PermissionStateSnapshot {
        let ordinal = calls
        calls += 1
        let value = await withCheckedContinuation { continuations[ordinal] = $0 }
        returned.insert(ordinal)
        return value
    }
    func finish(_ ordinal: Int, with value: PermissionStateSnapshot) {
        continuations.removeValue(forKey: ordinal)?.resume(returning: value)
    }
}

@MainActor
private final class RecoveryAccessRequester: PermissionAccessRequesting {
    private(set) var requestCount = 0
    func requestScreenRecordingAccess() -> Bool { requestCount += 1; return false }
    func requestAccessibilityAccess() -> Bool { requestCount += 1; return false }
    func requestInputMonitoringAccess() -> Bool { requestCount += 1; return false }
}

@MainActor
private struct RecoveryAssistPresenter: PermissionAssistPresenting {
    func present(kind: PermissionAssistKind, onRefresh: @escaping () -> Void) {}
}

@MainActor
private final class RecoverySystemActions: PermissionSystemActioning {
    private(set) var restartCount = 0
    private var completion: ((PermissionRestartResult) -> Void)?
    func openScreenRecordingSettings() {}
    func revealCurrentAppInFinder() {}
    func restartForPermissionRefresh(completion: @escaping (PermissionRestartResult) -> Void) {
        restartCount += 1
        self.completion = completion
    }
    func complete(_ result: PermissionRestartResult) { completion?(result) }
}

@MainActor
private final class RecoveryWaitController {
    private var watchdog: CheckedContinuation<Void, Never>?
    private(set) var watchdogStarted = false
    func wait(_ duration: Duration) async {
        if duration == .seconds(16) {
            await withCheckedContinuation {
                watchdog = $0
                watchdogStarted = true
            }
        } else {
            await Task.yield()
        }
    }
    func releaseWatchdog() {
        watchdog?.resume()
        watchdog = nil
    }
}
