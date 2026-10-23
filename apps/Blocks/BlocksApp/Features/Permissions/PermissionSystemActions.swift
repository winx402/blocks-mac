import AppKit
import BlocksCore
import OSLog

enum PermissionRestartResult: Equatable {
    /// A separate launcher has accepted the handoff. The app has not quit yet.
    case scheduled
    case failed(PermissionRestartFailure)
}

@MainActor
struct DefaultPermissionSnapshotProvider: PermissionSnapshotProviding {
    typealias UnitTestHostCheck = @MainActor () -> Bool
    typealias LiveInitialSnapshot = @MainActor () -> PermissionStateSnapshot
    typealias LiveSnapshot = @MainActor () async -> PermissionStateSnapshot

    private let isUnitTestHost: UnitTestHostCheck
    private let unitTestSnapshot: PermissionStateSnapshot
    private let liveInitialSnapshot: LiveInitialSnapshot
    private let liveSnapshot: LiveSnapshot

    init(
        isUnitTestHost: @escaping UnitTestHostCheck = {
            BlocksRuntimeEnvironment.isUnitTestHost
        },
        unitTestSnapshot: PermissionStateSnapshot? = nil,
        liveInitialSnapshot: @escaping LiveInitialSnapshot = {
            PermissionStateService.initialSnapshot()
        },
        liveSnapshot: @escaping LiveSnapshot = {
            await PermissionStateService.snapshot()
        }
    ) {
        self.isUnitTestHost = isUnitTestHost
        self.unitTestSnapshot = unitTestSnapshot ?? Self.makeUnitTestSnapshot()
        self.liveInitialSnapshot = liveInitialSnapshot
        self.liveSnapshot = liveSnapshot
    }

    func initialSnapshot() -> PermissionStateSnapshot {
        guard !isUnitTestHost() else { return unitTestSnapshot }
        return liveInitialSnapshot()
    }

    func snapshot() async -> PermissionStateSnapshot {
        guard !isUnitTestHost() else { return unitTestSnapshot }
        return await liveSnapshot()
    }

    private static func makeUnitTestSnapshot() -> PermissionStateSnapshot {
        let capturedAt = Date()
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let appPath = Bundle.main.bundleURL.path
        func diagnostic(
            _ kind: PermissionDiagnosticKind,
            hasUsageDescription: Bool = true
        ) -> PermissionDiagnosticSnapshot {
            PermissionDiagnosticSnapshot(
                kind: kind,
                granted: false,
                bundleID: bundleID,
                appPath: appPath,
                signatureKind: "unknown",
                teamID: nil,
                hasUsageDescription: hasUsageDescription,
                lastCheckedAt: capturedAt,
                recommendedAction: .requestInSystemSettings,
                matchingRunningAppPaths: [],
                identityIssue: .none
            )
        }
        return PermissionStateSnapshot(
            screenRecording: diagnostic(
                .screenRecording,
                hasUsageDescription:
                    Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") != nil
            ),
            accessibility: diagnostic(.accessibility),
            inputMonitoring: diagnostic(.inputMonitoring),
            capturedAt: capturedAt
        )
    }
}

@MainActor
struct DefaultPermissionAccessRequester: PermissionAccessRequesting {
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        PermissionStateService.requestScreenRecordingAccess()
    }

    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        PermissionStateService.requestAccessibilityAccess()
    }

    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        PermissionStateService.requestInputMonitoringAccess()
    }
}

@MainActor
final class DefaultPermissionAssistPresenter: PermissionAssistPresenting {
    private let presenter: PermissionAssistPanelPresenter

    init(presenter: PermissionAssistPanelPresenter? = nil) {
        self.presenter = presenter ?? PermissionAssistPanelPresenter()
    }

    func present(kind: PermissionAssistKind, onRefresh: @escaping () -> Void) {
        presenter.present(kind: kind, onFlowEnded: onRefresh)
    }
}

@MainActor
final class PermissionRestartSafety {
    typealias Prepare = @MainActor () async throws -> Void
    typealias Resume = @MainActor () async -> Void

    static let shared = PermissionRestartSafety()

    fileprivate final class Attempt {
        let prepare: Prepare
        let resume: Resume

        init(prepare: @escaping Prepare, resume: @escaping Resume) {
            self.prepare = prepare
            self.resume = resume
        }
    }

    private var prepare: Prepare?
    private var resume: Resume?
    private var activeAttempt: Attempt?
    fileprivate var hasActiveAttempt: Bool { activeAttempt != nil }

    init(prepare: Prepare? = nil, resume: Resume? = nil) {
        self.prepare = prepare
        self.resume = resume
    }

    /// AppModel installs full reversible lifecycle coverage. Missing setup is
    /// deliberately a failure; a restart must never fall back to ordinary quit.
    func configure(prepare: @escaping Prepare, resume: @escaping Resume) {
        guard activeAttempt == nil else { return }
        self.prepare = prepare
        self.resume = resume
    }

    fileprivate func reserveAttempt() -> Attempt? {
        guard activeAttempt == nil, let prepare, let resume else { return nil }
        let attempt = Attempt(prepare: prepare, resume: resume)
        activeAttempt = attempt
        return attempt
    }

    fileprivate func releaseAttempt(_ attempt: Attempt) {
        guard activeAttempt === attempt else { return }
        activeAttempt = nil
    }
}

@MainActor
struct DefaultPermissionSystemActions: PermissionSystemActioning {
    typealias Relauncher = @MainActor (URL, pid_t, @escaping @Sendable (pid_t?, Error?) -> Void) -> Void
    typealias HandoffCanceller = @MainActor (pid_t) async -> Bool
    typealias HandoffCommitter = @MainActor (pid_t) -> Bool

    private let relauncher: Relauncher
    private let cancelHandoff: HandoffCanceller
    private let commitHandoff: HandoffCommitter
    private let applicationTerminator: @MainActor () -> Void
    private let bundleURL: URL
    private let processID: pid_t
    private let safety: PermissionRestartSafety
    private let terminationCoordinator: AppTerminationCoordinator
    private let preparationTimeoutNanoseconds: UInt64
    private let handoffTimeoutNanoseconds: UInt64
    private let restartGate = PermissionRestartGate()

    init(
        relauncher: @escaping Relauncher = { bundleURL, processID, completion in
            PermissionRelaunchProcess.launch(
                bundleURL: bundleURL,
                parentProcessID: processID,
                completion: completion
            )
        },
        applicationTerminator: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        },
        bundleURL: URL = Bundle.main.bundleURL,
        processID: pid_t = getpid(),
        safety: PermissionRestartSafety? = nil,
        terminationCoordinator: AppTerminationCoordinator? = nil,
        preparationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        handoffTimeoutNanoseconds: UInt64 = 15_000_000_000,
        cancelHandoff: @escaping HandoffCanceller = { parentProcessID in
            await PermissionRelaunchProcess.cancelOwnedHandoff(parentProcessID: parentProcessID)
        },
        commitHandoff: @escaping HandoffCommitter = { parentProcessID in
            PermissionRelaunchProcess.commitOwnedHandoff(parentProcessID: parentProcessID)
        }
    ) {
        self.relauncher = relauncher
        self.cancelHandoff = cancelHandoff
        self.commitHandoff = commitHandoff
        self.applicationTerminator = applicationTerminator
        self.bundleURL = bundleURL
        self.processID = processID
        self.safety = safety ?? .shared
        self.terminationCoordinator = terminationCoordinator ?? .shared
        self.preparationTimeoutNanoseconds = min(preparationTimeoutNanoseconds, 5_000_000_000)
        self.handoffTimeoutNanoseconds = handoffTimeoutNanoseconds
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func restartForPermissionRefresh(
        completion: @escaping (PermissionRestartResult) -> Void
    ) {
        guard let requestID = restartGate.enqueue(completion) else { return }
        guard !terminationCoordinator.isQuitting else {
            restartGate.resolve(.failed(.recoveryConflict), requestID: requestID)
            return
        }
        guard let attempt = safety.reserveAttempt() else {
            restartGate.resolve(
                .failed(safety.hasActiveAttempt ? .recoveryConflict : .componentNotReady),
                requestID: requestID
            )
            return
        }
        let restartHandler = PermissionRestartHandler(
            terminator: applicationTerminator,
            restartGate: restartGate,
            requestID: requestID,
            parentProcessID: processID,
            safety: safety,
            attempt: attempt,
            terminationCoordinator: terminationCoordinator,
            preparationTimeoutNanoseconds: preparationTimeoutNanoseconds,
            handoffTimeoutNanoseconds: handoffTimeoutNanoseconds,
            cancelHandoff: cancelHandoff,
            commitHandoff: commitHandoff
        )
        restartHandler.start(relauncher: relauncher, bundleURL: bundleURL)
    }
}

@MainActor
private final class PermissionRestartGate {
    private var requestID: UUID?
    private var result: PermissionRestartResult?
    private var isRecovering = false
    private var callbacks: [(PermissionRestartResult) -> Void] = []

    /// Returns a token only for the first request. Concurrent taps receive the
    /// same eventual result rather than a premature success indication.
    func enqueue(_ completion: @escaping (PermissionRestartResult) -> Void) -> UUID? {
        if isRecovering {
            completion(.failed(.recoveryConflict))
            return nil
        }
        if let result {
            completion(result)
            return nil
        }
        callbacks.append(completion)
        guard requestID == nil else { return nil }
        let requestID = UUID()
        self.requestID = requestID
        return requestID
    }

    func resolve(_ result: PermissionRestartResult, requestID: UUID) {
        guard self.requestID == requestID else { return }
        self.result = result == .scheduled ? result : nil
        if case .failed = result {
            self.requestID = nil
            isRecovering = false
        }
        let callbacks = self.callbacks
        self.callbacks.removeAll()
        callbacks.forEach { $0(result) }
    }

    func markRecovering(requestID: UUID) {
        guard self.requestID == requestID else { return }
        isRecovering = true
    }
}

@MainActor
private final class PermissionRestartHandler {
    private enum Phase: Equatable { case preparing, launching, handedOff, recovering, finished }
    private static let logger = Logger(subsystem: "app.blocks", category: "PermissionRestart")
    private let terminator: @MainActor () -> Void
    private let restartGate: PermissionRestartGate
    private let requestID: UUID
    private let parentProcessID: pid_t
    private let safety: PermissionRestartSafety
    private let attempt: PermissionRestartSafety.Attempt
    private let terminationCoordinator: AppTerminationCoordinator
    private let preparationTimeoutNanoseconds: UInt64
    private let handoffTimeoutNanoseconds: UInt64
    private let cancelHandoff: DefaultPermissionSystemActions.HandoffCanceller
    private let commitHandoff: DefaultPermissionSystemActions.HandoffCommitter
    private var phase: Phase = .preparing
    private var preparationHasFinished = false
    private var preparationTask: Task<Void, Never>?
    private var preparationDeadline: Task<Void, Never>?
    private var handoffDeadline: Task<Void, Never>?
    private var recoveryIsRunning = false
    private var failureWasReported = false
    private var ownsPreparedRestart = false
    private var handoffWasStarted = false
    private var failureReason: PermissionRestartFailure = .unknown

    init(
        terminator: @escaping @MainActor () -> Void,
        restartGate: PermissionRestartGate,
        requestID: UUID,
        parentProcessID: pid_t,
        safety: PermissionRestartSafety,
        attempt: PermissionRestartSafety.Attempt,
        terminationCoordinator: AppTerminationCoordinator,
        preparationTimeoutNanoseconds: UInt64,
        handoffTimeoutNanoseconds: UInt64,
        cancelHandoff: @escaping DefaultPermissionSystemActions.HandoffCanceller,
        commitHandoff: @escaping DefaultPermissionSystemActions.HandoffCommitter
    ) {
        self.terminator = terminator
        self.restartGate = restartGate
        self.requestID = requestID
        self.parentProcessID = parentProcessID
        self.safety = safety
        self.attempt = attempt
        self.terminationCoordinator = terminationCoordinator
        self.preparationTimeoutNanoseconds = preparationTimeoutNanoseconds
        self.handoffTimeoutNanoseconds = handoffTimeoutNanoseconds
        self.cancelHandoff = cancelHandoff
        self.commitHandoff = commitHandoff
    }

    func start(relauncher: @escaping DefaultPermissionSystemActions.Relauncher, bundleURL: URL) {
        log("preparing")
        preparationDeadline = Task { @MainActor [self] in
            do { try await Task.sleep(nanoseconds: preparationTimeoutNanoseconds) }
            catch { return }
            guard phase == .preparing else { return }
            fail(stage: "preparation_timeout", reason: .timedOut)
        }
        // Do not use a task group for this deadline: a non-cooperative prepare
        // would make the group's implicit child join unbounded.
        preparationTask = Task { @MainActor [self] in
            let preparationFailure: PermissionRestartFailure?
            do {
                try Task.checkCancellation()
                try await attempt.prepare()
                try Task.checkCancellation()
                preparationFailure = nil
            } catch {
                preparationFailure = PermissionRestartFailure(preparationError: error)
            }
            preparationHasFinished = true
            preparationTask = nil
            if phase == .recovering {
                beginRecovery()
                return
            }
            guard phase == .preparing else { return }
            preparationDeadline?.cancel()
            preparationDeadline = nil
            if let preparationFailure {
                fail(stage: "preparation_failed", reason: preparationFailure)
                return
            }
            guard !terminationCoordinator.isQuitting else {
                fail(stage: "quit_conflict", reason: .recoveryConflict)
                return
            }
            phase = .launching
            handoffWasStarted = true
            log("prepared")
            relauncher(bundleURL, parentProcessID) { [self] childProcessID, error in
                let didStart = error == nil
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        complete(childProcessID: childProcessID, didStart: didStart)
                    }
                } else {
                    Task { @MainActor in
                        complete(childProcessID: childProcessID, didStart: didStart)
                    }
                }
            }
        }
    }

    func complete(childProcessID: pid_t?, didStart: Bool) {
        guard phase == .launching else { return }
        guard didStart,
              let childProcessID,
              childProcessID > 0,
              childProcessID != parentProcessID else {
            fail(stage: "handoff_failed", reason: .launchFailed)
            return
        }
        guard terminationCoordinator.armPreparedRestart() else {
            fail(stage: "quit_conflict", reason: .recoveryConflict)
            return
        }
        ownsPreparedRestart = true
        guard commitHandoff(parentProcessID) else {
            fail(stage: "handoff_commit_failed", reason: .launchFailed)
            return
        }
        phase = .handedOff
        log("handoff_ready", childProcessID: childProcessID)
        handoffDeadline = Task { @MainActor [self] in
            do { try await Task.sleep(nanoseconds: handoffTimeoutNanoseconds) }
            catch { return }
            guard phase == .handedOff else { return }
            // This is recovery, not a second quit request. The launcher also
            // times out without opening the app while this PID still exists.
            fail(stage: "handoff_timeout", reason: .timedOut)
        }
        restartGate.resolve(.scheduled, requestID: requestID)
        terminator()
    }

    private func fail(stage: String, reason: PermissionRestartFailure) {
        guard phase != .recovering, phase != .finished else { return }
        failureReason = reason
        phase = .recovering
        restartGate.markRecovering(requestID: requestID)
        preparationDeadline?.cancel()
        preparationDeadline = nil
        handoffDeadline?.cancel()
        handoffDeadline = nil
        preparationTask?.cancel()
        if ownsPreparedRestart {
            _ = terminationCoordinator.beginPreparedRestartRecovery()
        }
        log(stage)
        if preparationHasFinished {
            beginRecovery()
        } else {
            // Cancellation cannot prove an uncooperative participant has stopped.
            // Report the bounded failure now, but keep both safety and AppModel
            // ownership until the real prepare returns and can be resumed.
            reportFailureIfNeeded()
        }
    }

    private func beginRecovery() {
        guard phase == .recovering, preparationHasFinished, !recoveryIsRunning else { return }
        recoveryIsRunning = true
        Task { @MainActor [self] in
            if handoffWasStarted {
                while !(await cancelHandoff(parentProcessID)) {
                    // A false result is an unproven exit, not permission to
                    // reopen producers, drop ownership or start another launch.
                    log("launcher_cancel_timeout")
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                log("launcher_cancel_confirmed")
            }
            if ownsPreparedRestart {
                _ = terminationCoordinator.cancelPreparedRestart()
                ownsPreparedRestart = false
            }
            // A manual Quit wins over a reversible restart. Never ask business
            // services to reopen after its synchronous quit fence is committed.
            if !terminationCoordinator.isQuitting { await attempt.resume() }
            recoveryIsRunning = false
            phase = .finished
            safety.releaseAttempt(attempt)
            log(terminationCoordinator.isQuitting ? "quit_committed" : "recovered")
            reportFailureIfNeeded()
        }
    }

    private func reportFailureIfNeeded() {
        guard !failureWasReported else { return }
        failureWasReported = true
        restartGate.resolve(.failed(failureReason), requestID: requestID)
    }

    private func log(_ stage: String, childProcessID: pid_t = 0) {
        Self.logger.info("Permission restart stage=\(stage, privacy: .public) reason=\(self.failureReason.rawValue, privacy: .public) parent_pid=\(self.parentProcessID, privacy: .public) launcher_pid=\(childProcessID, privacy: .public)")
    }
}
