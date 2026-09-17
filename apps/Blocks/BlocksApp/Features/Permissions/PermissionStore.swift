import Combine
import Foundation
import BlocksCore

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
    @Published private(set) var permissionSnapshot: PermissionStateSnapshot

    private let snapshotProvider: PermissionSnapshotProviding
    private let accessRequester: PermissionAccessRequesting
    private let assistPresenter: PermissionAssistPresenting
    private let systemActions: PermissionSystemActioning
    private let systemPromptGate: PermissionSystemPromptGating
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var afterSnapshotPublished: (() -> Void)?

    init(
        snapshotProvider: PermissionSnapshotProviding? = nil,
        accessRequester: PermissionAccessRequesting? = nil,
        assistPresenter: PermissionAssistPresenting? = nil,
        systemActions: PermissionSystemActioning? = nil,
        systemPromptGate: PermissionSystemPromptGating? = nil
    ) {
        let resolvedSnapshotProvider = snapshotProvider ?? DefaultPermissionSnapshotProvider()
        self.snapshotProvider = resolvedSnapshotProvider
        self.accessRequester = accessRequester ?? DefaultPermissionAccessRequester()
        self.assistPresenter = assistPresenter ?? DefaultPermissionAssistPresenter()
        self.systemActions = systemActions ?? DefaultPermissionSystemActions()
        self.systemPromptGate = systemPromptGate ?? PermissionSystemPromptGate.processLifetimeShared
        self.permissionSnapshot = resolvedSnapshotProvider.initialSnapshot()
        refreshPermissionState()
    }

    func refreshPermissionState() {
        startPermissionRefresh()
    }

    func refreshPermissionState(afterSnapshotPublished: @escaping () -> Void) {
        self.afterSnapshotPublished = afterSnapshotPublished
        startPermissionRefresh()
    }

    private func startPermissionRefresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        let snapshotProvider = snapshotProvider
        refreshTask = Task { [weak self] in
            let snapshot = await snapshotProvider.snapshot()
            guard
                !Task.isCancelled,
                let self,
                self.refreshGeneration == generation
            else {
                return
            }

            self.permissionSnapshot = snapshot
            guard
                !Task.isCancelled,
                self.refreshGeneration == generation
            else {
                return
            }
            self.refreshTask = nil
            let afterSnapshotPublished = self.afterSnapshotPublished
            self.afterSnapshotPublished = nil
            afterSnapshotPublished?()
        }
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
