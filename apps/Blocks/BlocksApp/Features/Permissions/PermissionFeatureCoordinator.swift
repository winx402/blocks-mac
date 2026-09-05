import Foundation

@MainActor
final class PermissionFeatureCoordinator {
    private let store: PermissionStore
    private let assistPresenter: PermissionAssistPresenting
    private var afterPermissionRefresh: () -> Void = {}

    convenience init(
        store: PermissionStore,
        assistPanelPresenter: PermissionAssistPanelPresenter
    ) {
        self.init(
            store: store,
            assistPresenter: DefaultPermissionAssistPresenter(presenter: assistPanelPresenter)
        )
    }

    init(
        store: PermissionStore,
        assistPresenter: PermissionAssistPresenting
    ) {
        self.store = store
        self.assistPresenter = assistPresenter
    }

    var accessibilityGranted: Bool {
        store.permissionSnapshot.accessibilityGranted
    }

    var inputMonitoringGranted: Bool {
        store.permissionSnapshot.inputMonitoringGranted
    }

    func configure(afterPermissionRefresh: @escaping () -> Void) {
        self.afterPermissionRefresh = afterPermissionRefresh
    }

    func refreshPermissionState() {
        store.refreshPermissionState()
    }

    func openScreenRecordingSettings() {
        store.openScreenRecordingSettings()
    }

    func revealCurrentAppInFinder() {
        store.revealCurrentAppInFinder()
    }

    func restartForPermissionRefresh(
        completion: @escaping (PermissionRestartResult) -> Void
    ) {
        store.restartForPermissionRefresh(completion: completion)
    }

    func requestScreenRecordingPermissionAssist() {
        store.requestScreenRecordingPermissionAssist { [weak self] in
            self?.afterPermissionRefresh()
        }
    }

    func requestAccessibilityPermissionAssist() {
        store.requestAccessibilityPermissionAssist { [weak self] in
            self?.afterPermissionRefresh()
        }
    }

    func requestInputMonitoringPermissionAssist() {
        store.requestInputMonitoringPermissionAssist { [weak self] in
            self?.afterPermissionRefresh()
        }
    }

    func presentAccessibilityAssist(onRefresh: @escaping () -> Void) {
        assistPresenter.present(kind: .accessibility) { [weak self] in
            guard let self else {
                return
            }
            self.store.refreshPermissionState(afterSnapshotPublished: onRefresh)
        }
    }
}
