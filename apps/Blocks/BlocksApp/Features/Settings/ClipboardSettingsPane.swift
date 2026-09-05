import BlocksCore
import SwiftUI

struct ClipboardSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @EnvironmentObject private var clipboardStore: ClipboardStore
    @AppStorage("clipboard.panel.position") private var clipboardPanelPositionRawValue = FloatingPanelPosition.bottom.rawValue
    @AppStorage("clipboard.policy.cleanupMode") private var clipboardCleanupModeRawValue = ClipboardCleanupMode.count.rawValue
    @AppStorage("clipboard.policy.retention") private var clipboardPolicyRetentionRawValue = ClipboardRetentionPolicy.days30.rawValue
    @AppStorage("clipboard.policy.maxItems") private var clipboardPolicyMaxItems = 500
    @AppStorage("clipboard.policy.preserveFavorite") private var clipboardPolicyPreserveFavorite = true
    @AppStorage(ClipboardPanelSettings.Keys.filterClearDelay) private var clipboardFilterClearDelayRawValue = ClipboardFilterClearDelay.seconds30.rawValue
    @AppStorage(ClipboardPanelSettings.Keys.rememberSearch) private var clipboardFilterRememberSearch = false
    @AppStorage(ClipboardPanelSettings.Keys.showActiveFilterLabels) private var clipboardFilterShowActiveLabels = true
    @AppStorage(ClipboardPanelSettings.Keys.itemFontSize) private var clipboardItemFontSizeRawValue = Double(ClipboardPanelSettings.defaultItemFontSize)
    @State private var clearUnfavoritedConfirmationPresented = false
    @State private var policyConfirmationPresented = false
    @State private var pendingPolicyToken: ClipboardPolicyConfirmationToken?
    @State private var pendingPolicyDeleteCount = 0
    @State private var cleanupModeDraft: ClipboardCleanupMode
    @State private var cleanupRetentionDraft: ClipboardRetentionPolicy
    @State private var cleanupMaxItemsDraft: Int
    @State private var cleanupPreserveFavoriteDraft: Bool
    @SceneStorage("settings.clipboard.tagManagement.newTagDraft")
    private var tagManagementNewTagDraft = ""

    private static let rootRouteToken = "root"
    private static let tagManagementRouteToken = "tags"

    let showPrivacySection: Bool

    init(showPrivacySection: Bool = false) {
        self.showPrivacySection = showPrivacySection
        let defaults = UserDefaults.standard
        _cleanupModeDraft = State(initialValue: ClipboardCleanupMode(
            rawValue: defaults.string(forKey: "clipboard.policy.cleanupMode") ?? ClipboardCleanupMode.count.rawValue
        ) ?? .count)
        _cleanupRetentionDraft = State(initialValue: ClipboardRetentionPolicy(
            rawValue: defaults.string(forKey: "clipboard.policy.retention") ?? ClipboardRetentionPolicy.days30.rawValue
        ) ?? .days30)
        _cleanupMaxItemsDraft = State(initialValue: defaults.object(forKey: "clipboard.policy.maxItems") == nil
            ? 500
            : max(1, defaults.integer(forKey: "clipboard.policy.maxItems")))
        _cleanupPreserveFavoriteDraft = State(initialValue: defaults.object(forKey: "clipboard.policy.preserveFavorite") == nil
            ? true
            : defaults.bool(forKey: "clipboard.policy.preserveFavorite"))
    }

    private var clipboardPanelPosition: Binding<FloatingPanelPosition> {
        Binding {
            FloatingPanelPosition(rawValue: clipboardPanelPositionRawValue) ?? .bottom
        } set: { position in
            clipboardPanelPositionRawValue = position.rawValue
        }
    }

    private var routeToken: Binding<String> {
        routeStateStore.secondaryRouteBinding(
            for: .clipboard,
            default: Self.rootRouteToken
        )
    }

    private var showsTagManagement: Bool {
        routeToken.wrappedValue == Self.tagManagementRouteToken
    }

    private func setTagManagementVisible(_ isVisible: Bool) {
        routeToken.wrappedValue = isVisible
            ? Self.tagManagementRouteToken
            : Self.rootRouteToken
    }

    private var clipboardFilterClearDelay: Binding<ClipboardFilterClearDelay> {
        Binding {
            ClipboardFilterClearDelay(rawValue: clipboardFilterClearDelayRawValue) ?? .seconds30
        } set: { delay in
            clipboardFilterClearDelayRawValue = delay.rawValue
        }
    }

    private var clipboardCleanupMode: ClipboardCleanupMode {
        ClipboardCleanupMode(rawValue: clipboardCleanupModeRawValue) ?? .count
    }

    private var clipboardPolicyRetention: ClipboardRetentionPolicy {
        ClipboardRetentionPolicy(rawValue: clipboardPolicyRetentionRawValue) ?? .days30
    }

    private var cleanupModeSelection: Binding<ClipboardCleanupMode> {
        Binding(
            get: { cleanupModeDraft },
            set: { applyClipboardCleanupPolicy(cleanupMode: $0) }
        )
    }

    private var cleanupRetentionSelection: Binding<ClipboardRetentionPolicy> {
        Binding(
            get: { cleanupRetentionDraft },
            set: { applyClipboardCleanupPolicy(retentionPolicy: $0) }
        )
    }

    private var cleanupMaxItemsSelection: Binding<Int> {
        Binding(
            get: { cleanupMaxItemsDraft },
            set: { applyClipboardCleanupPolicy(maxItems: $0) }
        )
    }

    private var cleanupPreserveFavoriteSelection: Binding<Bool> {
        Binding(
            get: { cleanupPreserveFavoriteDraft },
            set: { applyClipboardCleanupPolicy(preserveFavorite: $0) }
        )
    }

    private var clipboardItemFontSize: Binding<Double> {
        Binding {
            Double(ClipboardPanelSettings.clampItemFontSize(CGFloat(clipboardItemFontSizeRawValue)))
        } set: { value in
            clipboardItemFontSizeRawValue = Double(ClipboardPanelSettings.clampItemFontSize(CGFloat(value)))
        }
    }

    private func applyClipboardCleanupPolicy(
        cleanupMode: ClipboardCleanupMode? = nil,
        retentionPolicy: ClipboardRetentionPolicy? = nil,
        maxItems: Int? = nil,
        preserveFavorite: Bool? = nil
    ) {
        let proposedMode = cleanupMode ?? cleanupModeDraft
        let proposedRetention = retentionPolicy ?? cleanupRetentionDraft
        let proposedMaxItems = maxItems ?? cleanupMaxItemsDraft
        let proposedPreserveFavorite = preserveFavorite ?? cleanupPreserveFavoriteDraft
        cleanupModeDraft = proposedMode
        cleanupRetentionDraft = proposedRetention
        cleanupMaxItemsDraft = proposedMaxItems
        cleanupPreserveFavoriteDraft = proposedPreserveFavorite
        guard appModel.previewClipboardCleanupPolicy(
            cleanupMode: proposedMode,
            retentionPolicy: proposedRetention,
            maxItems: proposedMaxItems,
            preserveFavorite: proposedPreserveFavorite,
            completion: { result in
                switch result {
                case let .preview(deleteCount, token), let .stale(deleteCount, token):
                    pendingPolicyDeleteCount = deleteCount
                    pendingPolicyToken = token
                    policyConfirmationPresented = true
                case .committed:
                    cleanupModeDraft = proposedMode
                    cleanupRetentionDraft = proposedRetention
                    cleanupMaxItemsDraft = proposedMaxItems
                    cleanupPreserveFavoriteDraft = proposedPreserveFavorite
                case .failed, .rejectedWhileBusy:
                    cleanupModeDraft = clipboardCleanupMode
                    cleanupRetentionDraft = clipboardPolicyRetention
                    cleanupMaxItemsDraft = clipboardPolicyMaxItems
                    cleanupPreserveFavoriteDraft = clipboardPolicyPreserveFavorite
                }
            }
        ) else {
            cleanupModeDraft = clipboardCleanupMode
            cleanupRetentionDraft = clipboardPolicyRetention
            cleanupMaxItemsDraft = clipboardPolicyMaxItems
            cleanupPreserveFavoriteDraft = clipboardPolicyPreserveFavorite
            return
        }
    }

    private func restoreCommittedPolicyDraft() {
        cleanupModeDraft = clipboardCleanupMode
        cleanupRetentionDraft = clipboardPolicyRetention
        cleanupMaxItemsDraft = clipboardPolicyMaxItems
        cleanupPreserveFavoriteDraft = clipboardPolicyPreserveFavorite
    }

    private func cancelPendingPolicyPreview() {
        guard clipboardStore.cleanupMutationState == .previewing
                || clipboardStore.cleanupMutationState == .awaitingConfirmation else {
            return
        }
        appModel.cancelClipboardCleanupPolicyPreview()
        pendingPolicyToken = nil
        pendingPolicyDeleteCount = 0
        restoreCommittedPolicyDraft()
    }

    var body: some View {
        Group {
            if showPrivacySection {
                privacyContent
            } else {
                content
            }
        }
        .confirmationDialog(
            L10n.string("clipboard.policy.confirm.title"),
            isPresented: Binding(
                get: { policyConfirmationPresented },
                set: { isPresented in
                    policyConfirmationPresented = isPresented
                    if !isPresented {
                        let dismissedToken = pendingPolicyToken
                        Task { @MainActor in
                            await Task.yield()
                            guard !policyConfirmationPresented,
                                  pendingPolicyToken == dismissedToken else { return }
                            cancelPendingPolicyPreview()
                        }
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("clipboard.policy.confirm.delete"), role: .destructive) {
                guard let pendingPolicyToken else { return }
                appModel.confirmClipboardCleanupPolicy(
                    token: pendingPolicyToken
                ) { result in
                    switch result {
                    case let .stale(deleteCount, token):
                        pendingPolicyDeleteCount = deleteCount
                        self.pendingPolicyToken = token
                        policyConfirmationPresented = true
                    case .committed:
                        self.pendingPolicyToken = nil
                        pendingPolicyDeleteCount = 0
                    case .failed, .rejectedWhileBusy:
                        self.pendingPolicyToken = nil
                        pendingPolicyDeleteCount = 0
                        restoreCommittedPolicyDraft()
                    case .preview:
                        break
                    }
                }
            }
            Button(L10n.string("clipboard.policy.confirm.keep"), role: .cancel) {
                cancelPendingPolicyPreview()
            }
        } message: {
            Text(L10n.format("clipboard.policy.confirm.message", pendingPolicyDeleteCount))
        }
        .confirmationDialog(
            L10n.string("clipboard.policy.clearUnfavorited"),
            isPresented: $clearUnfavoritedConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("clipboard.policy.clearUnfavorited"), role: .destructive) {
                // The confirmation can outlive the row that opened it. Recheck
                // at submission time so a pending/active policy mutation is
                // neither queued nor reported as a generic clear failure.
                guard clipboardStore.cleanupMutationState == .idle else {
                    return
                }
                appModel.clearUnfavoritedClipboardSummaries()
            }
            .disabled(clipboardStore.cleanupMutationState != .idle)
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("clipboard.policy.clearUnfavorited.confirmation"))
        }
        .onDisappear {
            cancelPendingPolicyPreview()
        }
    }

    private var repositoryStateSummary: ClipboardRepositoryStateSummary {
        clipboardStore.repositoryStateSummary()
    }

    private var pendingAttachmentCleanupFeedback: SettingsFeedbackDescriptor? {
        Self.pendingAttachmentCleanupFeedback(count: clipboardStore.pendingAttachmentCleanupCount)
    }

    static func pendingAttachmentCleanupFeedback(count: Int) -> SettingsFeedbackDescriptor? {
        guard count > 0 else { return nil }
        return SettingsFeedbackDescriptor(
            kind: .warning,
            title: L10n.format("clipboard.sidecarCleanup.pending.title", count),
            detail: L10n.format("clipboard.sidecarCleanup.pending.detail", count)
        )
    }

    @ViewBuilder
    private var content: some View {
        VStack(
            alignment: .leading,
            spacing: BlocksVisualTokens.Spacing.xl
        ) {
        if showsTagManagement {
            SettingsSecondaryPageHeader(
                title: L10n.string("settings.clipboardTags"),
                backTitle: L10n.string("common.back")
            ) {
                setTagManagementVisible(false)
                routeStateStore.restoreSecondaryRoute(
                    for: .clipboard,
                    anchorID: SettingsSecondaryRouteAnchor.clipboardTags
                )
            }
            ClipboardTagManagementSection(
                tagStore: clipboardStore.tagStore,
                onOpenScreenshotSettings: appModel.openScreenshotTagSettings,
                newTagName: $tagManagementNewTagDraft
            )
        } else {
        SettingsSection(title: L10n.string("settings.clipboard.feature")) {
            SettingsFormRow(
                title: L10n.string("settings.clipboard.feature.enabled"),
                detail: L10n.string("settings.clipboard.feature.enabled.detail")
            ) {
                SettingsBooleanSwitch(L10n.string("settings.clipboard.feature.enabled"), isOn: Binding(
                    get: { appModel.featureAvailabilityStore.clipboardEnabled },
                    set: { appModel.setClipboardFeatureEnabled($0) }
                ))
            }
        }

        Group {
        SettingsSection(
            title: L10n.string("settings.clipboardPolicy")
        ) {
            SettingsSegmentedRow(
                title: L10n.string("settings.clipboardPolicyCleanupMethod"),
                selection: cleanupModeSelection,
                controlWidth: 220
            ) {
                ForEach(ClipboardCleanupMode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }

            SettingsRowDivider()

            if cleanupModeDraft == .time {
                SettingsFormRow(
                    title: L10n.string("settings.clipboardPolicyRetention"),
                    detail: L10n.string("settings.clipboardPolicyRetentionDetail")
                ) {
                    Picker(L10n.string("settings.clipboardPolicyRetention"), selection: cleanupRetentionSelection) {
                        ForEach(ClipboardRetentionPolicy.allCases) { policy in
                            Text(policy.localizedTitle).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            } else {
                SettingsFormRow(
                    title: L10n.string("settings.clipboardPolicyMaxItemsLabel"),
                    detail: L10n.string("settings.clipboardPolicyMaxItemsDetail")
                ) {
                    Picker(L10n.string("settings.clipboardPolicyMaxItemsLabel"), selection: cleanupMaxItemsSelection) {
                        Text("200").tag(200)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                        Text("2000").tag(2000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.clipboardPolicyPreserveFavorite"),
                detail: appModel.clipboardPolicySummary(
                    cleanupMode: cleanupModeDraft,
                    retentionPolicy: cleanupRetentionDraft,
                    maxItems: cleanupMaxItemsDraft,
                    preserveFavorite: cleanupPreserveFavoriteDraft
                )
            ) {
                SettingsBooleanSwitch(
                    L10n.string("settings.clipboardPolicyPreserveFavorite"),
                    isOn: cleanupPreserveFavoriteSelection
                )
            }

            SettingsFeedbackSlot(feedback: pendingAttachmentCleanupFeedback)

        }
        .disabled(clipboardStore.cleanupMutationInProgress)

        SettingsSection(
            title: L10n.string("settings.clipboardPanelDisplay")
        ) {
            SettingsFormRow(
                title: L10n.string("settings.clipboardPanelItemFontSize"),
                detail: L10n.string("settings.clipboardPanelItemFontSizeDetail")
            ) {
                HStack(spacing: 10) {
                    Slider(
                        value: clipboardItemFontSize,
                        in: Double(ClipboardPanelSettings.minItemFontSize)...Double(ClipboardPanelSettings.maxItemFontSize),
                        step: 1
                    )
                    .frame(width: 160)
                    Text("\(Int(clipboardItemFontSize.wrappedValue)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.clipboardPanelPosition"),
                detail: L10n.string("settings.clipboardPanelPositionNote")
            ) {
                Picker(L10n.string("settings.clipboardPanelPosition"), selection: clipboardPanelPosition) {
                    ForEach(FloatingPanelPosition.allCases) { position in
                        Text(position.localizedTitle)
                            .tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }

        SettingsSection(
            title: L10n.string("settings.clipboardFilterBehavior")
        ) {
            SettingsFormRow(
                title: L10n.string("settings.clipboardFilterClearDelay"),
                detail: L10n.string("settings.clipboardFilterBehaviorNote")
            ) {
                Picker(L10n.string("settings.clipboardFilterClearDelay"), selection: clipboardFilterClearDelay) {
                    ForEach(ClipboardFilterClearDelay.allCases) { delay in
                        Text(delay.localizedTitle)
                            .tag(delay)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.clipboardFilterRememberSearch"),
                detail: L10n.string("settings.clipboardFilterRememberSearchDetail")
            ) {
                SettingsBooleanSwitch(
                    L10n.string("settings.clipboardFilterRememberSearch"),
                    isOn: $clipboardFilterRememberSearch
                )
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.clipboardFilterShowActiveLabels"),
                detail: L10n.string("settings.clipboardFilterShowActiveLabelsDetail")
            ) {
                SettingsBooleanSwitch(
                    L10n.string("settings.clipboardFilterShowActiveLabels"),
                    isOn: $clipboardFilterShowActiveLabels
                )
            }
        }

        SettingsSection(title: L10n.string("settings.clipboardTags")) {
            SettingsNavigationRow(
                title: L10n.string("settings.clipboardTags"),
                detail: L10n.string("settings.clipboardTags.detail"),
                value: String(clipboardStore.tagStore.tags.count),
                action: { setTagManagementVisible(true) }
            )
            .id(SettingsSecondaryRouteAnchor.clipboardTags)
        }

        SettingsSection(
            title: L10n.string("settings.clipboardPrivacyEntry")
        ) {
            SettingsNavigationRow(
                title: L10n.string("menu.clipboardPrivacy"),
                detail: L10n.string("settings.clipboardPrivacyEntryNote"),
                action: { appModel.selectedSection = .clipboardPrivacy }
            )
        }

        SettingsSection(title: L10n.string("settings.dangerZone")) {
            SettingsDangerRow(
                title: L10n.string("clipboard.policy.clearUnfavorited"),
                detail: L10n.string("clipboard.policy.clearUnfavorited.detail"),
                actionTitle: L10n.string("clipboard.policy.clearUnfavorited"),
                action: { clearUnfavoritedConfirmationPresented = true }
            )
        }
        .disabled(clipboardStore.cleanupMutationState != .idle)
        }
        .disabled(!appModel.featureAvailabilityStore.clipboardEnabled)
        }
        }
        .navigationTitle(
            showsTagManagement
                ? L10n.string("settings.clipboardTags")
                : L10n.string("settings.clipboard.title")
        )
    }

    @ViewBuilder
    private var privacyContent: some View {
        PrivacySettingsPane()
    }
}
