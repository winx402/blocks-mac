import Combine
import Foundation

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
final class PermissionStore: ObservableObject {
    @Published private(set) var permissionSnapshot: PermissionStateSnapshot

    private let snapshotProvider: PermissionSnapshotProviding
    private let accessRequester: PermissionAccessRequesting
    private let assistPresenter: PermissionAssistPresenting
    private let systemActions: PermissionSystemActioning
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var afterSnapshotPublished: (() -> Void)?

    init(
        snapshotProvider: PermissionSnapshotProviding? = nil,
        accessRequester: PermissionAccessRequesting? = nil,
        assistPresenter: PermissionAssistPresenting? = nil,
        systemActions: PermissionSystemActioning? = nil
    ) {
        let resolvedSnapshotProvider = snapshotProvider ?? DefaultPermissionSnapshotProvider()
        self.snapshotProvider = resolvedSnapshotProvider
        self.accessRequester = accessRequester ?? DefaultPermissionAccessRequester()
        self.assistPresenter = assistPresenter ?? DefaultPermissionAssistPresenter()
        self.systemActions = systemActions ?? DefaultPermissionSystemActions()
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
        _ = accessRequester.requestScreenRecordingAccess()
        assistPresenter.present(kind: .screenRecording) { [weak self] in
            guard let self else { return }
            if let afterRefresh {
                self.refreshPermissionState(afterSnapshotPublished: afterRefresh)
            } else {
                self.refreshPermissionState()
            }
        }
    }

    func requestAccessibilityPermissionAssist(afterRefresh: (() -> Void)? = nil) {
        _ = accessRequester.requestAccessibilityAccess()
        assistPresenter.present(kind: .accessibility) { [weak self] in
            guard let self else { return }
            if let afterRefresh {
                self.refreshPermissionState(afterSnapshotPublished: afterRefresh)
            } else {
                self.refreshPermissionState()
            }
        }
    }

    func requestInputMonitoringPermissionAssist(afterRefresh: (() -> Void)? = nil) {
        _ = accessRequester.requestInputMonitoringAccess()
        assistPresenter.present(kind: .inputMonitoring) { [weak self] in
            guard let self else { return }
            if let afterRefresh {
                self.refreshPermissionState(afterSnapshotPublished: afterRefresh)
            } else {
                self.refreshPermissionState()
            }
        }
    }
}
