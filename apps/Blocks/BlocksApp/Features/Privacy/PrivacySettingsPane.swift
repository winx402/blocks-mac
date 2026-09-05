import BlocksCore
import SwiftUI

struct PrivacySettingsPane: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        PrivacySettingsPaneContent(store: appModel.privacyStore)
            .onAppear {
                appModel.privacyStore.loadAppsIfNeeded()
            }
    }
}

private struct PrivacySettingsPaneContent: View {
    @ObservedObject var store: PrivacyStore

    var body: some View {
        let visibleApps = store.visibleApps

        SettingsSection(title: L10n.string("privacy.title")) {
            SettingsActionRow(
                title: L10n.string("privacy.capturePolicy.title"),
                detail: L10n.string("privacy.capturePolicy.detail")
            ) {
                BlocksCompactIconButton(
                    systemImage: "arrow.clockwise",
                    label: L10n.string("privacy.refresh")
                ) {
                    store.loadApps()
                }
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("privacy.search.title"),
                detail: L10n.string("privacy.search.detail")
            ) {
                TextField(L10n.string("privacy.search.placeholder"), text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("privacy.filters.title"),
                detail: L10n.format("privacy.filters.detail", visibleApps.count, store.restrictedRuleCount)
            ) {
                HStack(spacing: 8) {
                    Picker(L10n.string("privacy.filter.policy"), selection: $store.policyFilter) {
                        Text(L10n.string("privacy.filter.all")).tag(PrivacyPolicyStatus?.none)
                        ForEach(PrivacyPolicyStatus.allCases) { policy in
                            Text(policy.shortTitle).tag(PrivacyPolicyStatus?.some(policy))
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(L10n.string("privacy.filter.identity"), selection: $store.identityFilter) {
                        Text(L10n.string("privacy.filter.all")).tag(PrivacyIdentityIssue?.none)
                        ForEach(PrivacyIdentityIssue.allCases) { issue in
                            Text(issue.shortTitle).tag(PrivacyIdentityIssue?.some(issue))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }

        SettingsSection(title: L10n.string("privacy.discoveredApps")) {
            if store.capturePolicyAvailability != .ready {
                SettingsFormRow(
                    title: store.capturePolicyAvailability.localizedTitle,
                    detail: store.localizedErrorMessage ?? L10n.string("privacy.mutation.detail")
                ) {
                    if store.capturePolicyAvailability == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                }
            } else if visibleApps.isEmpty {
                SettingsFormRow(
                    title: emptyTitle,
                    detail: L10n.string("privacy.empty.noRows")
                ) {
                    Image(systemName: "rectangle.stack.badge.minus")
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleApps) { app in
                        PrivacyAppRowView(
                            app: app,
                            duplicateRequiresConfirmation: app.bundleIdentifier.map { store.duplicateBundleCount($0) > 1 } ?? false,
                            mutationState: store.mutationState,
                            mutationSubjectID: store.mutationSubjectID,
                            canRetryMutation: store.canRetryLastMutation,
                            setPolicy: { policy, confirmed in
                                store.setPolicy(for: app, policy: policy, confirmed: confirmed)
                            },
                            retryMutation: {
                                store.retryLastMutation()
                            },
                            cancelPendingMutation: {
                                store.cancelPendingMutation()
                            }
                        )
                        if app.id != visibleApps.last?.id {
                            SettingsRowDivider()
                        }
                    }
                }
            }
        }

    }

    private var emptyTitle: String {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.string("privacy.empty.noApps")
            : L10n.string("privacy.empty.noMatches")
    }
}

private extension PrivacyPolicyStatus {
    var shortTitle: String {
        switch self {
        case .defaultPolicy:
            return L10n.string("privacy.policy.default")
        case .allowed:
            return L10n.string("privacy.policy.allowed")
        case .restricted:
            return L10n.string("privacy.policy.restricted")
        }
    }
}

private extension PrivacyIdentityIssue {
    var shortTitle: String {
        switch self {
        case .none:
            return L10n.string("privacy.identity.verified")
        case .duplicateBundleID:
            return L10n.string("privacy.identity.duplicateBundle")
        case .missingBundleID:
            return L10n.string("privacy.identity.missingBundle")
        case .unreadableBundle:
            return L10n.string("privacy.identity.unreadable")
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

private extension PrivacyPolicyAvailability {
    var localizedTitle: String {
        switch self {
        case .loading:
            return L10n.string("privacy.mutation.pending")
        case .ready:
            return L10n.string("privacy.mutation.saved")
        case .failed:
            return L10n.string("privacy.mutation.failed")
        }
    }
}
