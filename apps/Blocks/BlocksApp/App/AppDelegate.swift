import AppKit
import BlocksCore
import OSLog

/// Bridges the existing composition-root store to launch, in either ordering.
/// The weak attachment must not create a second AppModel or retain scene state.
@MainActor
final class ShortcutApplicationLaunchCoordinator {
    private weak var shortcutStore: ShortcutStore?
    private var launchCompleted = false
    private(set) var initializationTask: Task<Void, Never>?

    func attach(_ store: ShortcutStore) {
        guard shortcutStore !== store else { return }
        shortcutStore = store
        if launchCompleted { initializeAttachedStore() }
    }

    func applicationDidFinishLaunching() {
        guard !launchCompleted else { return }
        launchCompleted = true
        initializeAttachedStore()
    }

    func cancelInitialization() {
        initializationTask?.cancel()
    }

    private func initializeAttachedStore() {
        guard let shortcutStore else { return }
        initializationTask?.cancel()
        initializationTask = Task { @MainActor [weak shortcutStore] in
            await shortcutStore?.initializeShortcutsAfterApplicationLaunch()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let shortcutLaunchCoordinator = ShortcutApplicationLaunchCoordinator()
    private static let shortcutLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blocks.app",
        category: "global-shortcut"
    )

    static func attachShortcutStoreForApplicationLaunch(_ store: ShortcutStore) {
        shortcutLaunchCoordinator.attach(store)
    }
    private let mainWindowPresentationCoordinator =
        MainWindowPresentationCoordinator()
    private var restorationObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard restorationObserver == nil else { return }
        restorationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mainWindowPresentationCoordinator
                    .applicationDidFinishRestoringWindows()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shortcutLogger.notice("stage=application-launch-completed running=\(NSApp.isRunning, privacy: .public)")
        Self.shortcutLaunchCoordinator.applicationDidFinishLaunching()
        NSApp.setActivationPolicy(.regular)
        mainWindowPresentationCoordinator.applicationDidFinishLaunching()
        guard BlocksRuntimeEnvironment.isUnitTestHost else { return }
        NSApp.windows
            .filter {
                $0.isVisible
                    && $0.parent == nil
                    && $0.level == .normal
                    && !($0 is NSPanel)
            }
            .forEach { window in
                window.animationBehavior = .none
                window.orderOut(nil)
            }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AppTerminationCoordinator.shared.isQuitting else {
            NSApp.hide(nil)
            return
        }
        mainWindowPresentationCoordinator.applicationDidBecomeActive()
    }

    func attachMainWindow(_ window: NSWindow) {
        guard !AppTerminationCoordinator.shared.isQuitting else {
            window.orderOut(nil)
            return
        }
        mainWindowPresentationCoordinator.attachMainWindow(window)
    }

    func detachMainWindow(_ window: NSWindow) {
        mainWindowPresentationCoordinator.detachMainWindow(window)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.shortcutLaunchCoordinator.cancelInitialization()
        if let restorationObserver {
            NotificationCenter.default.removeObserver(restorationObserver)
            self.restorationObserver = nil
        }
        AppTerminationCoordinator.shared.finalizeTerminationResourcesIfNeeded()
        ClipboardBrokerDataTransport.finalizeRoot()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.requestTermination()
    }
}
