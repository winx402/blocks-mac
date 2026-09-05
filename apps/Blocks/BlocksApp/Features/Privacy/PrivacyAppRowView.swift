import AppKit
import BlocksCore
import SwiftUI

struct PrivacyAppRowView: View {
    let app: PrivacyAppInstance
    let duplicateRequiresConfirmation: Bool
    let mutationState: PrivacyPolicyMutationState
    let mutationSubjectID: String?
    let canRetryMutation: Bool
    let setPolicy: (PrivacyPolicyStatus, Bool) -> Void
    let retryMutation: () -> Void
    let cancelPendingMutation: () -> Void

    @State private var pendingDuplicatePolicy: PrivacyPolicyStatus?
    @State private var loadedIcon: NSImage?
    @State private var iconLoadRequestID = UUID()
    @State private var iconWorkItem: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                iconView

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName)
                        .font(.subheadline.weight(.medium))
                    if duplicateRequiresConfirmation || app.identityIssue != .none {
                        Text(app.bundleIdentifier ?? L10n.string("privacy.noBundleIdentifier"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .help(app.pathSummary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)

            Spacer(minLength: 12)

            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                Text(app.policyStatus.localizedTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(app.policyStatus.tint)

                if app.identityIssue != .none {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(app.identityIssue.localizedTitle)
                        .accessibilityLabel(app.identityIssue.localizedTitle)
                }

                Group {
                    switch displayedMutationState {
                    case .saving?:
                        ProgressView()
                            .controlSize(.small)
                    case .failed?, .unsupported?:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    default:
                        Color.clear
                    }
                }
                .frame(width: 14, height: 14)
                .help(displayedMutationState?.localizedTitle ?? "")
                .accessibilityLabel(displayedMutationState?.localizedTitle ?? "")

                Menu {
                    if displayedMutationState == .failed,
                       canRetryMutation {
                        Button(L10n.string("privacy.retry")) {
                            retryMutation()
                        }
                        Divider()
                    }
                    ForEach(PrivacyPolicyStatus.allCases) { policy in
                        Button(policy.localizedTitle) {
                            if duplicateRequiresConfirmation {
                                pendingDuplicatePolicy = policy
                                setPolicy(policy, false)
                            } else {
                                setPolicy(policy, false)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(
                            width: BlocksVisualTokens.Control.compactHeight,
                            height: BlocksVisualTokens.Control.compactHeight
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(L10n.string("privacy.menu.policy"))
                .accessibilityLabel(L10n.string("privacy.menu.policy"))
                .confirmationDialog(
                    L10n.string("privacy.duplicate.confirm"),
                    isPresented: duplicateConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    if let pendingDuplicatePolicy {
                        Button(pendingDuplicatePolicy.localizedTitle) {
                            setPolicy(pendingDuplicatePolicy, true)
                            self.pendingDuplicatePolicy = nil
                        }
                    }
                    Button(L10n.string("common.cancel"), role: .cancel) {
                        pendingDuplicatePolicy = nil
                        cancelPendingMutation()
                    }
                }
            }
        }
        .padding(.vertical, BlocksVisualTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
        .onAppear(perform: loadIcon)
        .onChange(of: app.pathHash) { _, _ in
            loadIcon()
        }
        .onDisappear {
            iconWorkItem?.cancel()
        }
    }

    private var duplicateConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDuplicatePolicy != nil },
            set: { isPresented in
                if !isPresented, pendingDuplicatePolicy != nil {
                    pendingDuplicatePolicy = nil
                    cancelPendingMutation()
                }
            }
        )
    }

    @ViewBuilder
    private var iconView: some View {
        if let loadedIcon {
            Image(nsImage: loadedIcon)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: iconName)
                .frame(width: 28, height: 28)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
        }
    }

    private var iconName: String {
        switch app.iconState {
        case .pending:
            return "app.dashed"
        case .loaded:
            return "app.fill"
        case .failed:
            return "exclamationmark.app"
        case .unsupported:
            return "questionmark.app"
        }
    }

    private var iconColor: Color {
        switch app.iconState {
        case .pending:
            return .secondary
        case .loaded:
            return .accentColor
        case .failed:
            return .orange
        case .unsupported:
            return .secondary
        }
    }

    private var displayedMutationState: PrivacyPolicyMutationState? {
        mutationSubjectID == app.id ? mutationState : nil
    }

    private var accessibilityLabel: String {
        "\(app.displayName), \(app.bundleIdentifier ?? L10n.string("privacy.noBundleIdentifier")), \(app.policyStatus.localizedTitle), \(app.identityIssue.localizedTitle)"
    }

    private var accessibilityValue: String {
        guard let displayedMutationState else {
            return "\(app.policyStatus.localizedTitle), \(app.identityIssue.localizedTitle)"
        }
        return "\(app.policyStatus.localizedTitle), \(app.identityIssue.localizedTitle), \(displayedMutationState.localizedTitle)"
    }

    private func loadIcon() {
        iconWorkItem?.cancel()
        loadedIcon = nil
        let requestID = UUID()
        iconLoadRequestID = requestID
        let app = app
        let workItem = DispatchWorkItem {
            let icon = SystemAppIconProvider.icon(for: app)
            DispatchQueue.main.async {
                guard iconLoadRequestID == requestID else {
                    return
                }
                loadedIcon = icon
            }
        }
        iconWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

private extension PrivacyPolicyStatus {
    var localizedTitle: String {
        switch self {
        case .defaultPolicy:
            return L10n.string("privacy.policy.default")
        case .allowed:
            return L10n.string("privacy.policy.allowed")
        case .restricted:
            return L10n.string("privacy.policy.restricted")
        }
    }

    var tint: Color {
        switch self {
        case .defaultPolicy:
            return .secondary
        case .allowed:
            return .green
        case .restricted:
            return .orange
        }
    }
}

private extension PrivacyIdentityIssue {
    var localizedTitle: String {
        switch self {
        case .none:
            return L10n.string("privacy.identity.verified")
        case .duplicateBundleID:
            return L10n.string("privacy.identity.duplicateBundleID")
        case .missingBundleID:
            return L10n.string("privacy.identity.missingBundleID")
        case .unreadableBundle:
            return L10n.string("privacy.identity.unreadableApp")
        case .unsupported:
            return L10n.string("privacy.identity.unsupported")
        }
    }
}

private extension PrivacyPolicyMutationState {
    var localizedTitle: String {
        switch self {
        case .pending:
            return L10n.string("privacy.mutation.pending")
        case .saving:
            return L10n.string("privacy.mutation.saving")
        case .saved:
            return L10n.string("privacy.mutation.saved")
        case .failed:
            return L10n.string("privacy.mutation.failed")
        case .retry:
            return L10n.string("privacy.mutation.retry")
        case .cancel:
            return L10n.string("privacy.mutation.cancel")
        case .unsupported:
            return L10n.string("privacy.mutation.unsupported")
        }
    }
}
