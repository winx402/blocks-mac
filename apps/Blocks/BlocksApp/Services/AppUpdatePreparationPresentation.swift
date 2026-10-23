import AppKit
import BlocksCore

/// Only allowlisted classifications cross into UI/logs. Never display an
/// arbitrary underlying error (which may contain paths, endpoints or content).
struct AppUpdatePreparationFailure: Equatable {
    enum Reason: String {
        case helperNotPaired = "helper_not_paired"
        case helperKeyUnavailable = "helper_key_unavailable"
        case helperUnavailable = "helper_unavailable"
        case helperBusy = "helper_busy"
        case brokerMigration = "broker_migration"
        case brokerUnavailable = "broker_unavailable"
        case brokerBusy = "broker_busy"
        case brokerUntrusted = "broker_untrusted"
        case brokerUnsupported = "broker_unsupported"
        case brokerTimeout = "broker_timeout"
        case brokerRejected = "broker_rejected"
        case brokerRecovery = "broker_recovery"
        case brokerApproval = "broker_approval"
        case brokerShutdown = "broker_shutdown"
        case database = "database"
        case busy = "busy"
        case other = "other"
    }

    let participant: String
    let reason: Reason
    var message: String { L10n.string("updates.preparation.\(reason.rawValue)") }

    init(error: Error) {
        let drain = error as? ApplicationLifecycleCoordinator.ParticipantDrainError
        let underlying = drain?.underlying ?? error
        let knownParticipants: Set<String> = [
            "app", "shortcuts", "cliInstallation", "helper", "actionBroker",
            "clipboard", "translation", "provider", "screenshot", "plugins", "database",
        ]
        participant = drain.map { knownParticipants.contains($0.participantID) ? $0.participantID : "other" } ?? "app"
        if let helper = underlying as? SelectionHelperUpdatePreparationFailure {
            switch helper {
            case .helperNotPaired: reason = .helperNotPaired
            case .preparationUnavailable, .preparationRejected: reason = .helperUnavailable
            }
        } else if underlying as? SelectionAgentServiceFailure == .keychainUnavailable {
            reason = .helperKeyUnavailable
        } else if participant == "helper" {
            if let admission = underlying as? ApplicationOperationAdmissionGate.AdmissionError,
               case .busy = admission {
                reason = .helperBusy
            } else {
                reason = .helperUnavailable
            }
        } else if let broker = underlying as? ActionBrokerUpdateError {
            switch broker {
            case .legacyRegistrationRequiresMigration: reason = .brokerMigration
            case .busy: reason = .brokerBusy
            case .untrustedPeer: reason = .brokerUntrusted
            case .unsupportedPeer: reason = .brokerUnsupported
            case .connectionUnavailable: reason = .brokerUnavailable
            case .timedOut: reason = .brokerTimeout
            case .preparationRejected: reason = .brokerRejected
            case .preparationInProgress, .invalidRecoveryState: reason = .brokerRecovery
            case .requiresApproval: reason = .brokerApproval
            case .serviceDidNotStop: reason = .brokerShutdown
            }
        } else if participant == "actionBroker" {
            if let admission = underlying as? ApplicationOperationAdmissionGate.AdmissionError,
               case .busy = admission {
                reason = .brokerBusy
            } else if underlying is ApplicationOperationAdmissionGate.AdmissionError {
                reason = .brokerRecovery
            } else {
                reason = .brokerUnavailable
            }
        } else if participant == "database" {
            reason = .database
        } else if let admission = underlying as? ApplicationOperationAdmissionGate.AdmissionError,
                  case .busy = admission {
            reason = .busy
        } else {
            reason = .other
        }
    }
}

enum AppUpdatePreparationPresentation: Equatable {
    case preparing
    case failed(AppUpdatePreparationFailure)
}

@MainActor
protocol AppUpdatePreparationPresenting: AnyObject {
    func show(_ state: AppUpdatePreparationPresentation,
              retry: @escaping () -> Void, later: @escaping () -> Void)
    func dismiss()
}

/// Sparkle has already consumed its Install button by this stage. This small
/// app-owned window replaces that inert window, not Sparkle's update engine.
/// No modal run loop: preparation/recovery and normal app interaction continue.
@MainActor
final class AppUpdatePreparationWindow: NSObject, AppUpdatePreparationPresenting, NSWindowDelegate {
    private var window: NSWindow?
    private var heading: NSTextField?
    private var detail: NSTextField?
    private var progress: NSProgressIndicator?
    private var retryButton: NSButton?
    private var laterButton: NSButton?
    private var retryAction: (() -> Void)?
    private var laterAction: (() -> Void)?
    private var canDefer = false

    func show(_ state: AppUpdatePreparationPresentation,
              retry: @escaping () -> Void, later: @escaping () -> Void) {
        if window == nil { makeWindow() }
        retryAction = retry
        laterAction = later
        switch state {
        case .preparing:
            canDefer = false
            heading?.stringValue = L10n.string("updates.preparation.title")
            detail?.stringValue = L10n.string("updates.status.waiting")
            progress?.isHidden = false
            progress?.startAnimation(nil)
        case let .failed(failure):
            canDefer = true
            heading?.stringValue = L10n.string("updates.preparation.paused")
            detail?.stringValue = failure.message
            progress?.stopAnimation(nil)
            progress?.isHidden = true
        }
        retryButton?.isEnabled = canDefer
        laterButton?.isEnabled = canDefer
        window?.standardWindowButton(.closeButton)?.isEnabled = canDefer
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        retryAction = nil
        laterAction = nil
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canDefer else { return false }
        laterAction?()
        return false
    }

    @objc private func retry() { retryAction?() }
    @objc private func later() { laterAction?() }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.string("updates.title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("updates.preparation")
        let heading = NSTextField(labelWithString: "")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.setAccessibilityIdentifier("updates.preparation.heading")
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 13)
        detail.setAccessibilityIdentifier("updates.preparation.detail")
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        let later = NSButton(title: L10n.string("updates.preparation.later"), target: self, action: #selector(later))
        later.setAccessibilityIdentifier("updates.preparation.later")
        let retry = NSButton(title: L10n.string("updates.preparation.retry"), target: self, action: #selector(retry))
        retry.keyEquivalent = "\r"
        retry.setAccessibilityIdentifier("updates.preparation.retry")
        let spacer = NSView()
        let actions = NSStackView(views: [progress, spacer, later, retry])
        actions.orientation = .horizontal
        actions.spacing = 10
        let content = NSStackView(views: [heading, detail, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        if let root = window.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
                content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
                content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
                detail.widthAnchor.constraint(equalTo: content.widthAnchor),
                actions.widthAnchor.constraint(equalTo: content.widthAnchor),
                detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
            ])
        }
        window.center()
        self.window = window
        self.heading = heading
        self.detail = detail
        self.progress = progress
        retryButton = retry
        laterButton = later
    }
}
