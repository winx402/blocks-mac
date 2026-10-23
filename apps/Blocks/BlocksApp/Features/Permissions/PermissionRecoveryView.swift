import AppKit
import SwiftUI

/// Recovery is owned by PermissionStore, not by the lifetime of this sheet.
/// Reopening the App resumes the ticket before this view is presented.
struct PermissionRecoveryView: View {
    @EnvironmentObject private var store: PermissionStore
    @Environment(\.dismiss) private var dismiss
    let onRestartRequested: () -> Void

    var body: some View {
        SettingsSheetScaffold(
            title: L10n.string("settings.permissionRecovery.flowTitle"),
            detail: L10n.string("settings.permissionRecovery.processOnly"),
            systemImage: "checkmark.shield",
            preferredHeight: 460
        ) {
            if let state = store.recoveryState {
                VStack(alignment: .leading, spacing: 16) {
                    Text(permissionTitle(state.kind)).font(.headline)
                    Label(
                        L10n.string("settings.permissionRecovery.stage.\(state.stage.rawValue)"),
                        systemImage: state.stage == .recovered ? "checkmark.circle.fill" : "info.circle"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("permissionRecovery.stage")
                    if state.isInFlight { ProgressView().controlSize(.small) }
                    if state.stage == .needsReauthorization {
                        Text(L10n.string("settings.permissionRecovery.readd"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        PermissionDragDropCard()
                        HStack {
                            Button(L10n.string("settings.permissionRecovery.openSettings")) {
                                openSettings(for: state.kind)
                            }
                            Button(L10n.string("settings.permissionShowInFinder")) {
                                store.revealCurrentAppInFinder()
                            }
                        }
                    }
                    if state.stage == .restartFailed {
                        Text(L10n.string("settings.permissionRecovery.keptOpen"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L10n.string("settings.permissionRecovery.helperSeparate"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button(L10n.string("common.close")) { dismiss() }
                .disabled(store.recoveryState?.isInFlight == true)
            Button(L10n.string("settings.permissionRefresh")) { store.recheckPermissionRecovery() }
                .disabled(store.recoveryState?.isInFlight != false)
            if store.recoveryState?.canRestart == true {
                Button(L10n.string("settings.permissionRecovery.reopenCheck")) {
                    onRestartRequested()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(store.recoveryState?.isInFlight == true)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                // This is detection only: it never prompts, resets TCC or
                // retries a launch. Store fences it during an active recovery.
                store.refreshPermissionState()
            }
        }
    }

    private func permissionTitle(_ kind: PermissionDiagnosticKind) -> String {
        switch kind {
        case .screenRecording: L10n.string("settings.screenRecording")
        case .accessibility: L10n.string("permission.assist.blocksAccessibility.title")
        case .inputMonitoring: L10n.string("permission.assist.inputMonitoring.title")
        }
    }

    private func openSettings(for kind: PermissionDiagnosticKind) {
        let anchor: String
        switch kind {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
