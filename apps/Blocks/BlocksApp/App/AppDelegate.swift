import AppKit
import BlocksCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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

    func applicationWillTerminate(_ notification: Notification) {
        AppTerminationCoordinator.shared.finalizeTerminationResourcesIfNeeded()
        ClipboardBrokerDataTransport.finalizeRoot()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.requestTermination()
    }
}
