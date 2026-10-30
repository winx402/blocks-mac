import SwiftUI

/// Product setup states. A listening server or a stored key is not sufficient
/// to reach ready: only the controller's authenticated health can do that.
enum SelectionHelperSetupStep: Equatable {
    case checking, install, open, pair, permission, ready, repair, update, conflict

    init(state: SelectionHelperConnectionState, needsPairing: Bool) {
        switch state {
        case .checking, .connecting: self = .checking
        case .notInstalled: self = .install
        case .notRunning: self = .open
        case .notPaired: self = .pair
        case .missingAccessibilityPermission: self = .permission
        case .ready: self = .ready
        case .connectionFailed: self = needsPairing ? .pair : .repair
        case .versionOutdated: self = .update
        case .installationConflict: self = .conflict
        }
    }
}

/// Both settings panes pass the AppModel-owned controller. Presenting this
/// sheet is passive; opening a trusted Helper requires the user's button.
struct SelectionHelperSetupView: View {
    @ObservedObject var controller: SelectionHelperSettingsController
    @Environment(\.dismiss) private var dismiss

    private var step: SelectionHelperSetupStep {
        SelectionHelperSetupStep(state: controller.state, needsPairing: controller.needsPairing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("translation.selectionHelper.setup.title"))
                .font(.title2.weight(.semibold))
            Text(L10n.string("translation.selectionHelper.setup.detail"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("translation.selectionHelper.setup.step.\(stepKey)"))
                        .fixedSize(horizontal: false, vertical: true)
                    stepActions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            if let error = controller.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    if let failure = controller.lastPairingFailure {
                        Text(L10n.string("translation.selectionHelper.setup.failure.\(failureStageKey(failure))"))
                            .font(.callout.weight(.semibold))
                    }
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.lastPairingFailure == .keychainUnavailable {
                        Text(L10n.string("translation.selectionHelper.setup.partialPairing"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier("selectionHelper.setup.failure")
            }

            HStack {
                Button(L10n.string("translation.selectionHelper.recheck")) {
                    controller.refresh(allowLaunch: false)
                }
                .disabled(controller.isPairing)
                Spacer()
                Button(L10n.string("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            controller.refresh(allowLaunch: false)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                controller.refresh(allowLaunch: false)
            }
        }
    }

    @ViewBuilder private var stepActions: some View {
        switch step {
        case .checking:
            ProgressView().controlSize(.small)
        case .install, .update:
            Button(L10n.string("translation.selectionHelper.download")) { controller.openDownloadPage() }
        case .open, .pair:
            Text(L10n.string("translation.selectionHelper.setup.associationConsent"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("translation.selectionHelper.setup.connect")) { controller.connectAfterExplicitOptIn() }
                .disabled(controller.isPairing)
                .accessibilityIdentifier("selectionHelper.setup.connect")
        case .permission:
            Button(L10n.string("translation.selectionHelper.requestPermission")) {
                controller.requestAccessibilityPermission()
            }
        case .ready:
            Label(L10n.string("translation.selectionHelper.setup.ready"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .repair:
            Button(L10n.string("translation.selectionHelper.open")) { controller.openHelper() }
        case .conflict:
            EmptyView()
        }
    }

    private var stepKey: String {
        switch step {
        case .checking: "checking"
        case .install: "install"
        case .open: "open"
        case .pair: "pair"
        case .permission: "permission"
        case .ready: "ready"
        case .repair: "repair"
        case .update: "update"
        case .conflict: "conflict"
        }
    }

    private func failureStageKey(_ failure: SelectionAgentServiceFailure) -> String {
        switch failure {
        case .bootstrapUnavailable: "bootstrap"
        case .keychainUnavailable: "keychain"
        case .invalidPairingCode: "code"
        default: "connection"
        }
    }
}
