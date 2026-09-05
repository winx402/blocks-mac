import Foundation

@MainActor
final class ShortcutFeatureCoordinator {
    private let store: ShortcutStore
    private var statusRecorder: (AppStatus) -> Void = { _ in }

    init(store: ShortcutStore) {
        self.store = store
    }

    func configure(
        statusRecorder: @escaping (AppStatus) -> Void,
        screenshotSmart: @escaping () -> Void,
        clipboardHistory: @escaping () -> Void,
        translationPanel: @escaping () -> Void,
        translationScreenshot: @escaping () -> Void,
        clipboardQuickPaste: @escaping (Int) -> Void
    ) {
        self.statusRecorder = statusRecorder
        store.configureActions(
            ShortcutActionHandlers(
                screenshotSmart: screenshotSmart,
                clipboardHistory: clipboardHistory,
                translationPanel: translationPanel,
                translationScreenshot: translationScreenshot,
                clipboardQuickPaste: clipboardQuickPaste
            )
        )
    }

    func registerDefaultShortcuts(force: Bool = false) {
        store.registerDefaultShortcuts(force: force)
    }

    func refreshShortcutRegistrations() {
        store.refreshShortcutRegistrations()
        statusRecorder(AppStatus(
            kind: store.failedShortcutCount == 0 ? .ready : .failed,
            title: L10n.string("status.shortcutsRefreshed.title"),
            detail: L10n.format(
                "status.shortcutsRefreshed.detail",
                store.registeredShortcutCount,
                store.disabledShortcutCount,
                store.failedShortcutCount
            )
        ))
    }
}
