// Disposable UI probe only: real Sparkle standard window + production Blocks
// coordinator/presenter, synthetic drains. No download, installation or Helper.
import AppKit
import BlocksCore
import Sparkle

@MainActor final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()
    var isQuitting = false
}
enum SelectionHelperUpdatePreparationFailure: Error { case helperNotPaired }
enum SelectionAgentServiceFailure: Error { case keychainUnavailable }

@MainActor final class UpdateRecoveryProbe: NSObject, NSApplicationDelegate {
    private var driver: SPUStandardUserDriver!
    private var coordinator: AppUpdateCoordinator!
    private var attempts = 0
    private var installs = 0
    private var events: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        item.submenu = appMenu
        let resume = NSMenuItem(title: "Continue Prepared Update", action: #selector(resumeUpdate), keyEquivalent: "r")
        resume.target = self
        appMenu.addItem(resume)
        appMenu.addItem(withTitle: "Close Update Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Update Recovery Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        let configuration = AppUpdateConfiguration(
            isOfficialDistribution: false, isLocalDevelopment: false, isUnitTestHost: true,
            bundleIdentifier: Bundle.main.bundleIdentifier, feedURLString: nil,
            publicKey: nil, allowsAutomaticInstallation: false)
        coordinator = AppUpdateCoordinator(configuration: configuration, preparationPresenter: AppUpdatePreparationWindow())
        coordinator.configureInstallationSafety(prepareForUpdate: { [self] in
            attempts += 1
            record("prepare")
            let delay = Bundle.main.object(forInfoDictionaryKey: "ProbeDelay") as? Double ?? 3
            try await Task.sleep(for: .seconds(delay))
            if Bundle.main.object(forInfoDictionaryKey: "ProbeScenario") as? String == "broker" {
                let failures: [ActionBrokerUpdateError] = [
                    .connectionUnavailable, .timedOut, .preparationRejected, .untrustedPeer,
                    .unsupportedPeer, .busy, .preparationInProgress, .requiresApproval, .serviceDidNotStop,
                ]
                if attempts <= failures.count {
                    let error = failures[attempts - 1]
                    record("failure-" + error.rawValue)
                    throw ApplicationLifecycleCoordinator.ParticipantDrainError(
                        participantID: "actionBroker", underlying: error)
                }
                return
            }
            if attempts == 1 {
                throw ApplicationLifecycleCoordinator.ParticipantDrainError(
                    participantID: "helper", underlying: SelectionHelperUpdatePreparationFailure.helperNotPaired)
            }
            if attempts == 2 {
                throw ApplicationLifecycleCoordinator.ParticipantDrainError(
                    participantID: "actionBroker", underlying: ActionBrokerUpdateError.busy)
            }
        }, resumeAfterCancelledUpdate: { [self] in record("resume") })
        driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        Task { [self] in
            let choice = await driver.showReadyToInstallAndRelaunch()
            guard choice == .install else { return }
            record("standard-install-click")
            driver.dismissUpdateInstallation()
            coordinator.postponeInstallation { [self] in
                installs += 1
                record("saved-install-continuation")
            }
        }
        record("ready")
    }

    @objc private func resumeUpdate() { coordinator.retryInstallationPreparation() }

    private func record(_ event: String) {
        events.append(event)
        guard let marker = Bundle.main.object(forInfoDictionaryKey: "ProbeMarker") as? String else { return }
        let data = try! JSONSerialization.data(withJSONObject: [
            "events": events, "attempts": attempts, "installs": installs,
            "isRealUpgrade": false,
        ], options: [.sortedKeys])
        try! data.write(to: URL(fileURLWithPath: marker), options: .atomic)
    }
}

@main enum ProbeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = UpdateRecoveryProbe()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
