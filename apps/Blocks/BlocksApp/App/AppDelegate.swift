import AppKit
import BlocksCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
