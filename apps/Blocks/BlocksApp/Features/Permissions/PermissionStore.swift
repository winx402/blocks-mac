import Combine
import Foundation
import BlocksCore
import OSLog

@MainActor
protocol PermissionSnapshotProviding {
    func initialSnapshot() -> PermissionStateSnapshot
    func snapshot() async -> PermissionStateSnapshot
}

@MainActor
protocol PermissionAccessRequesting {
    @discardableResult func requestScreenRecordingAccess() -> Bool
    @discardableResult func requestAccessibilityAccess() -> Bool
    @discardableResult func requestInputMonitoringAccess() -> Bool
}

@MainActor
protocol PermissionAssistPresenting {
    func present(kind: PermissionAssistKind, onRefresh: @escaping () -> Void)
}

@MainActor
protocol PermissionSystemActioning {
    func openScreenRecordingSettings()
    func revealCurrentAppInFinder()
    func restartForPermissionRefresh(
        completion: @escaping (PermissionRestartResult) -> Void
    )
}

@MainActor
protocol PermissionSystemPromptGating: AnyObject {
    func claimSystemPrompt(for kind: PermissionAssistKind) -> Bool
}

@MainActor
final class PermissionSystemPromptGate: PermissionSystemPromptGating {
    static let processLifetimeShared = PermissionSystemPromptGate()

    private var promptedKinds = Set<PermissionAssistKind>()

    func claimSystemPrompt(for kind: PermissionAssistKind) -> Bool {
        promptedKinds.insert(kind).inserted
    }
}

@MainActor
final class PermissionStore: ObservableObject {
    typealias RecoveryWait = @MainActor (Duration) async -> Void

    @Published private(set) var permissionSnapshot: PermissionStateSnapshot
    @Published private(set) var recoveryState: PermissionRecoveryState?

    private let snapshotProvider: PermissionSnapshotProviding
    private let accessRequester: PermissionAccessRequesting
    private let assistPresenter: PermissionAssistPresenting
    private let systemActions: PermissionSystemActioning
    private let systemPromptGate: PermissionSystemPromptGating
    private let recoveryTickets: PermissionRecoveryPersisting
    private let recoveryWait: RecoveryWait
    private let processID: Int32
    private static let logger = Logger(subsystem: "app.blocks", category: "PermissionRecovery")
    private var refreshTask: Task<Void, Never>?
    private var restartWatchdogTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var afterSnapshotPublished: (() -> Void)?

    init(
        snapshotProvider: PermissionSnapshotProviding? = nil,
        accessRequester: PermissionAccessRequesting? = nil,
        assistPresenter: PermissionAssistPresenting? = nil,
        systemActions: PermissionSystemActioning? = nil,
        systemPromptGate: PermissionSystemPromptGating? = nil,
        recoveryTickets: PermissionRecoveryPersisting? = nil,
        recoveryWait: @escaping RecoveryWait = { duration in
            try? await Task.sleep(for: duration)
        },
        processID: Int32 = getpid()
    ) {
        let resolvedSnapshotProvider = snapshotProvider ?? DefaultPermissionSnapshotProvider()
        self.snapshotProvider = resolvedSnapshotProvider
        self.accessRequester = accessRequester ?? DefaultPermissionAccessRequester()
        self.assistPresenter = assistPresenter ?? DefaultPermissionAssistPresenter()
        self.systemActions = systemActions ?? DefaultPermissionSystemActions()
        self.systemPromptGate = systemPromptGate ?? PermissionSystemPromptGate.processLifetimeShared
        self.recoveryTickets = recoveryTickets ?? UserDefaultsPermissionRecoveryTicketStore.shared
        self.recoveryWait = recoveryWait
        self.processID = processID
        self.permissionSnapshot = resolvedSnapshotProvider.initialSnapshot()
        refreshPermissionState()
    }

    func refreshPermissionState() {
        // Recovery owns this same generation-fenced sampling path. A passive
        // activation/assist callback must not start a competing task.
        guard recoveryState?.isInFlight != true else { return }
        startPermissionRefresh()
    }

    func refreshPermissionState(afterSnapshotPublished: @escaping () -> Void) {
        self.afterSnapshotPublished = afterSnapshotPublished
        refreshPermissionState()
    }

    private func startPermissionRefresh(recoveryFailureStage: PermissionRecoveryStage? = nil) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        let snapshotProvider = snapshotProvider
        let recoveryWait = recoveryWait
        let kind = recoveryFailureStage == nil ? nil : recoveryState?.kind
        refreshTask = Task { [weak self] in
            let attempts = kind == nil ? 1 : 3
            for attempt in 0..<attempts {
                let snapshot = await snapshotProvider.snapshot()
                guard !Task.isCancelled,
                      self?.publishSnapshot(snapshot, generation: generation) == true else {
                    return
                }
                let passed = kind.map { snapshot.diagnostic(for: $0).granted } ?? false
                if kind == nil || passed || attempt == attempts - 1 {
                    self?.finishPermissionRefresh(
                        generation: generation,
                        recoveryStage: kind == nil ? nil : (passed ? .recovered : recoveryFailureStage)
                    )
                    return
                }
                await recoveryWait(.milliseconds(450))
                guard !Task.isCancelled,
                      self?.refreshGeneration == generation else { return }
            }
        }
    }

    private func publishSnapshot(_ snapshot: PermissionStateSnapshot, generation: Int) -> Bool {
        guard refreshGeneration == generation else { return false }
        permissionSnapshot = snapshot
        guard refreshGeneration == generation else { return false }
        logSnapshot(snapshot)
        return true
    }

    private func finishPermissionRefresh(generation: Int, recoveryStage: PermissionRecoveryStage?) {
        guard refreshGeneration == generation else { return }
        refreshTask = nil
        if let kind = recoveryState?.kind {
            if let recoveryStage {
                setRecoveryState(kind: kind, stage: recoveryStage)
            } else if permissionSnapshot.diagnostic(for: kind).granted {
                setRecoveryState(kind: kind, stage: .recovered)
            } else if recoveryState?.stage == .recovered {
                setRecoveryState(kind: kind, stage: .needsReauthorization)
            }
        }
        guard refreshGeneration == generation else { return }
        let completion = afterSnapshotPublished
        afterSnapshotPublished = nil
        completion?()
    }

    /// Startup reads this before routing, then explicitly calls resume below.
    var pendingPermissionRecoveryKind: PermissionDiagnosticKind? {
        recoveryTickets.pendingTicket(for: processID)?.kind
    }

    func beginPermissionRecovery(for kind: PermissionDiagnosticKind) {
        guard recoveryState?.isInFlight != true else { return }
        setRecoveryState(kind: kind, stage: .checking)
        startPermissionRefresh(recoveryFailureStage: .restartSuggested)
    }

    /// Reauthorization remains a user action in System Settings. This only
    /// rechecks the selected main-App API and never issues another prompt.
    func recheckPermissionRecovery() {
        guard let state = recoveryState, !state.isInFlight else { return }
        let failureStage: PermissionRecoveryStage = state.stage == .needsReauthorization
            ? .needsReauthorization : .restartSuggested
        setRecoveryState(kind: state.kind, stage: .checking)
        startPermissionRefresh(recoveryFailureStage: failureStage)
    }

    /// Scheduled means handoff accepted, not a permission fix or completed exit.
    func restartPermissionRecovery() {
        guard let state = recoveryState, state.canRestart else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = nil
        recoveryTickets.save(
            PermissionRecoveryTicket(kind: state.kind, stage: .restarting),
            originatingProcessID: processID
        )
        setRecoveryState(kind: state.kind, stage: .restarting)
        systemActions.restartForPermissionRefresh { [weak self] result in
            guard let self,
                  self.refreshGeneration == generation,
                  self.recoveryState?.stage == .restarting else { return }
            switch result {
            case let .failed(failure):
                self.recoveryTickets.clear()
                self.setRecoveryState(kind: state.kind, stage: .restartFailed, failure: failure)
            case .scheduled:
                self.recoveryTickets.save(
                    PermissionRecoveryTicket(kind: state.kind, stage: .restartScheduled),
                    originatingProcessID: self.processID
                )
                self.setRecoveryState(kind: state.kind, stage: .restartScheduled)
                self.watchForCancelledExit(kind: state.kind, generation: generation)
            }
        }
    }

    /// Cancelling the presentation discards process-local failure feedback,
    /// never an in-flight restart or another process's persisted recovery.
    func cancelPermissionRecovery() {
        guard recoveryState?.isInFlight != true else { return }
        recoveryState = nil
    }

    /// Consume before awaiting: activation, scene recreation and callbacks can
    /// call this repeatedly, but only a new process may claim a written ticket.
    @discardableResult
    func resumePendingPermissionRecovery() -> Bool {
        guard recoveryState?.isInFlight != true,
              let ticket = recoveryTickets.consume(for: processID) else { return false }
        setRecoveryState(kind: ticket.kind, stage: .resumingAfterRestart)
        startPermissionRefresh(recoveryFailureStage: .needsReauthorization)
        return true
    }

    private func watchForCancelledExit(kind: PermissionDiagnosticKind, generation: Int) {
        restartWatchdogTask?.cancel()
        let recoveryWait = recoveryWait
        restartWatchdogTask = Task { [weak self] in
            // The existing separate launcher waits at most 15 seconds for
            // orderly quit. If we are still executing, no restart is proven.
            await recoveryWait(.seconds(16))
            guard !Task.isCancelled,
                  let self,
                  self.refreshGeneration == generation,
                  self.recoveryState?.stage == .restartScheduled else { return }
            self.recoveryTickets.clear()
            self.restartWatchdogTask = nil
            self.setRecoveryState(kind: kind, stage: .restartFailed, failure: .timedOut)
        }
    }

    private func setRecoveryState(
        kind: PermissionDiagnosticKind,
        stage: PermissionRecoveryStage,
        failure: PermissionRestartFailure? = nil
    ) {
        recoveryState = PermissionRecoveryState(kind: kind, stage: stage, failure: failure)
        let diagnostic = permissionSnapshot.diagnostic(for: kind)
        Self.logger.info("Permission recovery stage=\(stage.rawValue, privacy: .public) reason=\(failure?.rawValue ?? "none", privacy: .public) target=\(kind.rawValue, privacy: .public) pid=\(self.processID) installation=\(diagnostic.bundleID, privacy: .public) signature=\(diagnostic.signatureKind, privacy: .public) team=\(diagnostic.teamID ?? "none", privacy: .public)")
    }

    private func logSnapshot(_ snapshot: PermissionStateSnapshot) {
        let stage = recoveryState?.stage.rawValue ?? "passive"
        let postEvent = snapshot.postEventAccessGranted.map(String.init) ?? "not-sampled"
        Self.logger.info("Permission sample stage=\(stage, privacy: .public) pid=\(snapshot.sampledProcessID ?? self.processID) time=\(snapshot.capturedAt.timeIntervalSince1970) source=CGPreflightScreenCaptureAccess bool=\(snapshot.screenRecordingGranted) source=AXIsProcessTrusted bool=\(snapshot.accessibilityGranted) source=CGPreflightPostEventAccess bool=\(postEvent, privacy: .public) source=CGPreflightListenEventAccess bool=\(snapshot.inputMonitoringGranted)")
    }

    func openScreenRecordingSettings() {
        systemActions.openScreenRecordingSettings()
    }

    func revealCurrentAppInFinder() {
        systemActions.revealCurrentAppInFinder()
    }

    func restartForPermissionRefresh(
        completion: @escaping (PermissionRestartResult) -> Void
    ) {
        systemActions.restartForPermissionRefresh(completion: completion)
    }

    func requestScreenRecordingPermissionAssist(afterRefresh: (() -> Void)? = nil) {
        requestPermissionAssist(
            kind: .screenRecording,
            afterRefresh: afterRefresh,
            requestSystemAccess: accessRequester.requestScreenRecordingAccess
        )
    }

    func requestAccessibilityPermissionAssist(afterRefresh: (() -> Void)? = nil) {
        requestPermissionAssist(
            kind: .accessibility,
            afterRefresh: afterRefresh,
            requestSystemAccess: accessRequester.requestAccessibilityAccess
        )
    }

    func requestInputMonitoringPermissionAssist(afterRefresh: (() -> Void)? = nil) {
        requestPermissionAssist(
            kind: .inputMonitoring,
            afterRefresh: afterRefresh,
            requestSystemAccess: accessRequester.requestInputMonitoringAccess
        )
    }

    private func requestPermissionAssist(
        kind: PermissionAssistKind,
        afterRefresh: (() -> Void)?,
        requestSystemAccess: () -> Bool
    ) {
        guard recoveryState?.isInFlight != true else { return }
        // Calls can originate from feature retry paths. Mark the kind before
        // invoking the system API so a re-entrant request cannot stack another
        // macOS authorization prompt in this process lifetime.
        if systemPromptGate.claimSystemPrompt(for: kind) {
            _ = requestSystemAccess()
        }
        assistPresenter.present(kind: kind) { [weak self] in
            guard let self else { return }
            if let afterRefresh {
                self.refreshPermissionState(afterSnapshotPublished: afterRefresh)
            } else {
                self.refreshPermissionState()
            }
        }
    }
}
