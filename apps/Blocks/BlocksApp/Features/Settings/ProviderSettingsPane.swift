import BlocksCore
import SwiftUI

private enum ProviderSettingsRoute: String {
    case overview
    case details
}

private enum ProviderDetailsFocusField: String, Hashable {
    case accountAlias = "settings.providers.details.account-alias"
    case baseURL = "settings.providers.details.base-url"
    case model = "settings.providers.details.model"
}

struct ProviderSettingsPane: View {
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var providerStore: ProviderStore
    @Environment(\.accessibilityVoiceOverEnabled)
    private var accessibilityVoiceOverEnabled
    @AppStorage("provider.api.keychainAccountAlias") private var apiKeychainAccountAlias = ""
    @AppStorage("provider.api.baseURL") private var apiBaseURL = ""
    @AppStorage("provider.api.modelName") private var apiModelName = ""
    @AppStorage("provider.api.secretLifecycleState") private var secretLifecycleStateRawValue = ProviderSecretLifecycleState.missing.rawValue
    @AppStorage("provider.api.storedSecretAccountAlias") private var storedSecretAccountAlias = ""
    @State private var apiBaseURLDraft = ""
    @State private var apiKeychainAccountAliasDraft = ""
    @State private var apiModelNameDraft = ""
    @State private var baseURLValidationFailed = false
    @FocusState private var focusedDetailsField: ProviderDetailsFocusField?
    @State private var secretCandidate = ""
    @State private var providerUserSecretStoreConfirmed = false
    @State private var externalTransferGranted = false
    @State private var externalTransferRevocationPersistenceFailed = false
    @State private var isRunningConnectionTest = false
    @State private var isRunningUserSecretGate = false
    @State private var showsUserSecretDeletionConfirmation = false
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var activeConnectionTestID: UUID?
    @SceneStorage("settings.provider.plannedLLM.expanded")
    private var showsPlannedLLM = false
    @SceneStorage("settings.provider.plannedOCR.expanded")
    private var showsPlannedOCR = false

    private var secretLifecycleState: ProviderSecretLifecycleState {
        let persisted = ProviderSecretLifecycleState(
            rawValue: secretLifecycleStateRawValue
        ) ?? .missing
        if persisted.hasStoredUserSecret,
           !hasStoredSecretForCurrentAlias {
            return .missing
        }
        return persisted
    }

    private var normalizedStoredSecretAccountAlias: String {
        ProviderSettingsPersistence.normalizedAccountAlias(storedSecretAccountAlias)
    }

    private var hasStoredSecretForCurrentAlias: Bool {
        ProviderSettingsPersistence.hasStoredSecret(
            lifecycleStateRawValue: secretLifecycleStateRawValue,
            storedAccountAlias: normalizedStoredSecretAccountAlias,
            currentAccountAlias: apiKeychainAccountAlias
        )
    }

    private var providerConnectionReadiness: ProviderConnectionReadiness {
        ProviderConnectionReadiness.make(
            apiKeychainAccountAlias: apiKeychainAccountAlias,
            apiBaseURL: apiBaseURL,
            apiModelName: apiModelName,
            secretLifecycleState: secretLifecycleState
        )
    }

    private var cancelledAliasMigrationRecoveryNoticeState:
        ProviderCancelledAliasMigrationRecoveryNoticeState {
        providerStore.cancelledAliasMigrationRecoveryNoticeState
    }

    private var canStoreProviderUserSecret: Bool {
        !secretCandidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKeychainAccountAliasDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && providerUserSecretStoreConfirmed
            && cancelledAliasMigrationRecoveryNoticeState == .absent
    }

    private var cancelledAliasMigrationRecoveryNotice:
        ProviderCancelledAliasMigrationRecoveryNotice? {
        guard case let .valid(notice) = cancelledAliasMigrationRecoveryNoticeState
        else { return nil }
        return notice
    }

    private var credentialFeedback: SettingsFeedbackDescriptor? {
        switch cancelledAliasMigrationRecoveryNoticeState {
        case .absent:
            return nil
        case let .valid(notice):
            return SettingsFeedbackDescriptor(
                kind: .warning,
                title: L10n.string("settings.providerCancelledAliasMigration.title"),
                detail: L10n.format(
                    "settings.providerCancelledAliasMigration.detail",
                    notice.destinationAlias
                )
            )
        case .malformed:
            return SettingsFeedbackDescriptor(
                kind: .error,
                title: L10n.string("settings.providerCancelledAliasMigrationMalformed.title"),
                detail: L10n.string("settings.providerCancelledAliasMigrationMalformed.detail")
            )
        }
    }

    private var credentialDeletionAlias: String {
        cancelledAliasMigrationRecoveryNotice?.destinationAlias
            ?? normalizedStoredSecretAccountAlias
    }

    private var openAITestConnectionReady: Bool {
        !apiKeychainAccountAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasStoredSecretForCurrentAlias
    }

    private var canRunOpenAITestConnection: Bool {
        openAITestConnectionReady
            && externalTransferGranted
            && !isRunningConnectionTest
    }

    private var connectionConfigurationFingerprint: ProviderConnectionConfigurationFingerprint {
        ProviderConnectionConfigurationFingerprint(
            baseURL: apiBaseURL,
            modelName: apiModelName,
            keychainAccountAlias: apiKeychainAccountAlias,
            credentialRevision: providerStore.providerCredentialRevision
        )
    }

    private var connectionFeedback: SettingsFeedbackDescriptor? {
        if isRunningConnectionTest {
            return SettingsFeedbackDescriptor(
                kind: .information,
                title: L10n.string("settings.providerConnectionTesting.title"),
                detail: L10n.string("settings.providerConnectionTesting.detail")
            )
        }
        if externalTransferRevocationPersistenceFailed {
            return SettingsFeedbackDescriptor(
                kind: .error,
                title: L10n.string(
                    "settings.providerExternalTransferRevocationFailed.title"
                ),
                detail: L10n.string(
                    "settings.providerExternalTransferRevocationFailed.detail"
                )
            )
        }
        guard let result = providerStore.openAIConnectionLastResult else {
            return nil
        }
        return SettingsFeedbackDescriptor(
            kind: result.ok ? .success : .error,
            title: result.ok
                ? L10n.string("settings.providerConnectionSucceeded.title")
                : L10n.string("settings.providerConnectionFailed.title"),
            detail: result.status.localizedSettingsDetail
        )
    }

    private var routeBinding: Binding<String> {
        routeStateStore.secondaryRouteBinding(
            for: .providers,
            default: ProviderSettingsRoute.overview.rawValue
        )
    }

    private var route: ProviderSettingsRoute {
        get {
            ProviderSettingsRoute(rawValue: routeBinding.wrappedValue)
                ?? .overview
        }
        nonmutating set {
            routeBinding.wrappedValue = newValue.rawValue
        }
    }

    var body: some View {
        content
            .transition(.opacity)
            .blocksAnimation(.selection, value: route.rawValue)
            .navigationTitle(
                route == .details
                    ? L10n.string("settings.providerDefault")
                    : L10n.string("settings.providerAI")
            )
            .confirmationDialog(
                L10n.string("settings.providerUserSecretDeleteConfirmationTitle"),
                isPresented: $showsUserSecretDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    L10n.string("settings.providerUserSecretDelete"),
                    role: .destructive
                ) {
                    runProviderUserSecretGate(action: .deleteStored)
                    showsUserSecretDeletionConfirmation = false
                }
                Button(L10n.string("common.cancel"), role: .cancel) {
                    showsUserSecretDeletionConfirmation = false
                }
            } message: {
                Text(
                    L10n.format(
                        "settings.providerUserSecretDeleteConfirmationDetail",
                        credentialDeletionAlias
                    )
                )
            }
            .onChange(of: connectionConfigurationFingerprint) { _, fingerprint in
                connectionTestTask?.cancel()
                activeConnectionTestID = nil
                isRunningConnectionTest = false
                providerStore.activateOpenAIConnectionConfiguration(fingerprint)
                synchronizeExternalTransferGrant()
            }
            .onAppear {
                apiBaseURL = ProviderSettingsPersistence.storedProviderBaseURL()
                if let migratedAlias = ProviderSettingsPersistence
                    .migratedStoredAccountAlias(
                        lifecycleStateRawValue: secretLifecycleStateRawValue,
                        storedAccountAlias: storedSecretAccountAlias,
                        currentAccountAlias: apiKeychainAccountAlias
                    ) {
                    storedSecretAccountAlias = migratedAlias
                }
                restoreProviderDetailsDraftIfNeeded()
                synchronizeExternalTransferGrant()
                restoreDetailsFocusIfRequested()
            }
            .onChange(of: focusedDetailsField) { previousField, focusedField in
                handleDetailsFocusChange(focusedField)
                if previousField == .baseURL, focusedField != .baseURL {
                    saveProviderBaseURLDraft()
                }
                if previousField == .model, focusedField != .model {
                    saveProviderModelNameDraft()
                }
            }
            .onChange(of: route) { previousRoute, currentRoute in
                if previousRoute == .details {
                    cacheProviderDetailsDraft()
                    discardSensitiveDrafts()
                    cleanupConnectionTestForRouteExit()
                }
                if currentRoute == .details {
                    restoreProviderDetailsDraftIfNeeded()
                }
            }
            .onChange(of: routeStateStore.focusRestorationRequest?.token) { _, _ in
                restoreDetailsFocusIfRequested()
            }
            .onDisappear {
                cacheProviderDetailsDraft()
                discardSensitiveDrafts()
                cleanupConnectionTestForRouteExit()
            }
    }

    @ViewBuilder
    private var content: some View {
        if route == .details {
            SettingsSecondaryPageHeader(
                title: L10n.string("settings.providerDefault"),
                backTitle: L10n.string("common.back")
            ) {
                route = .overview
                routeStateStore.restoreSecondaryRoute(
                    for: .providers,
                    anchorID: SettingsSecondaryRouteAnchor.providerDetails
                )
            }
        }

        if route == .overview {
            SettingsSection(title: L10n.string("settings.providerDefault")) {
                SettingsNavigationRow(
                    title: L10n.string("settings.providerDefault"),
                    detail: providerConnectionReadiness.summary,
                    value: providerConnectionReadiness.ready
                        ? L10n.string("translation.provider.configured")
                        : L10n.string("translation.provider.notConfigured")
                ) {
                    route = .details
                }
                .id(SettingsSecondaryRouteAnchor.providerDetails)
            }

            AICapabilitySettingsSection(
                title: L10n.string("settings.aiCapabilityGate"),
                detail: L10n.string("settings.aiCapabilityArchitectureNote"),
                profiles: providerStore.llmProviderProfiles.map(\.base),
                showsPlanned: $showsPlannedLLM
            )

            AICapabilitySettingsSection(
                title: L10n.string("settings.ocrEngines"),
                detail: nil,
                profiles: providerStore.ocrEngineProfiles.map(\.base),
                showsPlanned: $showsPlannedOCR
            )
        }

        if route == .details {
        SettingsSection(title: L10n.string("settings.providerConfiguration")) {
            SettingsFormRow(
                title: L10n.string("settings.providerKeychainAccount"),
                detail: L10n.string("settings.providerCredentialName.detail")
            ) {
                TextField(L10n.string("settings.providerKeychainAccountPlaceholder"), text: $apiKeychainAccountAliasDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedDetailsField, equals: .accountAlias)
                    .accessibilityIdentifier(ProviderDetailsFocusField.accountAlias.rawValue)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.providerBaseURL"),
                detail: baseURLValidationFailed
                    ? L10n.string("settings.providerConnectionFailure.address")
                    : L10n.string("settings.providerConnectionRequirement.apiBaseURL.detail")
            ) {
                TextField(L10n.string("settings.providerBaseURLPlaceholder"), text: $apiBaseURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedDetailsField, equals: .baseURL)
                    .accessibilityIdentifier(ProviderDetailsFocusField.baseURL.rawValue)
                    .onSubmit(saveProviderBaseURLDraft)
                    .onChange(of: apiBaseURLDraft) { _, _ in
                        baseURLValidationFailed = false
                        cacheProviderDetailsDraft()
                    }
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.providerModel"),
                detail: L10n.string("settings.providerConnectionRequirement.apiModel.detail")
            ) {
                TextField(L10n.string("settings.providerModelPlaceholder"), text: $apiModelNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedDetailsField, equals: .model)
                    .accessibilityIdentifier(ProviderDetailsFocusField.model.rawValue)
                    .onSubmit(saveProviderModelNameDraft)
                    .onChange(of: apiModelNameDraft) { _, _ in
                        cacheProviderDetailsDraft()
                    }
            }

        }

        SettingsSection(title: L10n.string("settings.providerCredential")) {
            SettingsFormRow(
                title: L10n.string("settings.providerSecretCandidate"),
                detail: L10n.string("settings.providerCredentialKey.detail")
            ) {
                SecureField(L10n.string("settings.providerSecretCandidatePlaceholder"), text: $secretCandidate)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.providerUserSecretConfirmStore"),
                detail: L10n.string("settings.providerNoSecretRead")
            ) {
                SettingsCheckbox(
                    L10n.string("settings.providerUserSecretConfirmStore"),
                    isOn: $providerUserSecretStoreConfirmed
                )
                .labelsHidden()
            }

            SettingsRowDivider()

            SettingsActionRow(
                title: L10n.string("settings.providerUserSecretSave"),
                detail: secretLifecycleState.localizedTitle
            ) {
                Button {
                    let secret = secretCandidate
                    let previousAlias = normalizedStoredSecretAccountAlias
                    isRunningUserSecretGate = true
                    Task { @MainActor in
                        let outcome = await appModel.performProviderUserSecretGate(
                            action: .saveOrReplace,
                            accountAlias: apiKeychainAccountAliasDraft,
                            secretCandidate: secret,
                            replacingAccountAlias: previousAlias.isEmpty ? nil : previousAlias
                        )
                        if outcome.operationSucceeded,
                           outcome.lifecycleRawValue == ProviderSecretLifecycleState.userSecretStored.rawValue {
                            commitStoredProviderAccountAlias(apiKeychainAccountAliasDraft, lifecycleRawValue: outcome.lifecycleRawValue)
                        }
                        secretCandidate = ""
                        providerUserSecretStoreConfirmed = false
                        isRunningUserSecretGate = false
                    }
                } label: {
                    Label(L10n.string("settings.providerUserSecretSave"), systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(!canStoreProviderUserSecret || isRunningUserSecretGate)

                if !credentialDeletionAlias.isEmpty,
                   cancelledAliasMigrationRecoveryNoticeState != .malformed {
                    Button(role: .destructive) {
                        showsUserSecretDeletionConfirmation = true
                    } label: {
                        Label(L10n.string("settings.providerUserSecretDelete"), systemImage: "trash")
                    }
                }
            }

            if let credentialFeedback {
                SettingsRowDivider()
                SettingsFeedbackSlot(feedback: credentialFeedback)
            }
        }

        SettingsSection(title: L10n.string("settings.providerConnection")) {
            SettingsToggleRow(
                title: L10n.string("settings.openAITestConnectionConfirmExternalTransfer"),
                detail: L10n.string(
                    "translation.services.profile.externalDataNotice"
                ),
                isOn: Binding(
                    get: { externalTransferGranted },
                    set: setExternalTransferGranted
                )
            )
            .disabled(!openAITestConnectionReady && !externalTransferGranted)

            SettingsRowDivider()

            SettingsActionRow(
                title: L10n.string("settings.openAITestConnectionRun"),
                detail: openAITestConnectionReady ? L10n.string("settings.openAITestConnectionLastResult") : L10n.string("settings.openAITestConnectionUnavailable")
            ) {
                Button {
                    let fingerprint = connectionConfigurationFingerprint
                    let testID = UUID()
                    connectionTestTask?.cancel()
                    providerStore.activateOpenAIConnectionConfiguration(fingerprint)
                    activeConnectionTestID = testID
                    isRunningConnectionTest = true
                    connectionTestTask = Task { @MainActor in
                        await appModel.runOpenAIConnectionTest(
                            baseURL: apiBaseURL,
                            modelName: apiModelName,
                            keychainAccountAlias: apiKeychainAccountAlias,
                            configurationFingerprint: fingerprint
                        )
                        guard !Task.isCancelled, activeConnectionTestID == testID else {
                            return
                        }
                        isRunningConnectionTest = false
                    }
                } label: {
                    Label(L10n.string("settings.openAITestConnectionRun"), systemImage: "network")
                }
                .disabled(!canRunOpenAITestConnection)
            }

            SettingsRowDivider()

            SettingsFeedbackSlot(feedback: connectionFeedback)
        }

        BlocksPluginUISlotHost(
            manager: appModel.translationPluginManager,
            runtime: appModel.pluginRuntimeCoordinator,
            slot: .providerDiagnosticCard,
            context: [
                "provider_count": .int(providerStore.llmProviderProfiles.count),
                "ocr_engine_count": .int(providerStore.ocrEngineProfiles.count),
                "connection_ready": .bool(providerConnectionReadiness.ready)
            ],
            protectedContext: [
                "base_url": .string(apiBaseURL),
                "model": .string(apiModelName),
                "keychain_alias": .string(apiKeychainAccountAlias)
            ],
            requiredDataPermission: .providerMetadata
        )

        }
    }

    private func runProviderUserSecretGate(action: ProviderUserSecretAction, secretCandidate: String? = nil) {
        let targetAlias = action == .deleteStored
            ? credentialDeletionAlias
            : apiKeychainAccountAlias
        guard !isRunningUserSecretGate else { return }
        isRunningUserSecretGate = true
        Task { @MainActor in
            await completeProviderUserSecretGate(
                action: action,
                targetAlias: targetAlias,
                secretCandidate: secretCandidate
            )
        }
    }

    private func completeProviderUserSecretGate(
        action: ProviderUserSecretAction,
        targetAlias: String,
        secretCandidate: String?
    ) async {
        let outcome = await appModel.performProviderUserSecretGate(
            action: action,
            accountAlias: targetAlias,
            secretCandidate: secretCandidate
        )
        if outcome.operationSucceeded {
            secretLifecycleStateRawValue = outcome.lifecycleRawValue
        }
        if outcome.operationSucceeded,
           action == .deleteStored,
           outcome.lifecycleRawValue
            == ProviderSecretLifecycleState.userSecretDeletedVerified.rawValue {
            storedSecretAccountAlias = ""
        }
        if outcome.operationSucceeded {
            synchronizeExternalTransferGrant()
        }
        isRunningUserSecretGate = false
    }

    private func saveProviderBaseURLDraft() {
        guard let savedBaseURL = ProviderSettingsPersistence.saveProviderBaseURL(
            apiBaseURLDraft
        ) else {
            baseURLValidationFailed = true
            cacheProviderDetailsDraft()
            return
        }
        baseURLValidationFailed = false
        apiBaseURL = savedBaseURL
        apiBaseURLDraft = savedBaseURL
        cacheProviderDetailsDraft()
    }

    private func saveProviderModelNameDraft() {
        guard let savedModelName = ProviderSettingsPersistence
            .saveProviderModelName(apiModelNameDraft) else {
            return
        }
        apiModelName = savedModelName
        apiModelNameDraft = savedModelName
        synchronizeExternalTransferGrant()
        cacheProviderDetailsDraft()
    }

    private func restoreProviderDetailsDraftIfNeeded() {
        guard route == .details,
              let draft = routeStateStore.providerDetailsDraft(
                  for: ProviderSettingsRoute.details.rawValue
              ) else {
            apiBaseURLDraft = apiBaseURL
            apiKeychainAccountAliasDraft = apiKeychainAccountAlias
            apiModelNameDraft = apiModelName
            return
        }
        apiBaseURLDraft = draft.apiBaseURLDraft
        baseURLValidationFailed = draft.baseURLValidationFailed
        apiKeychainAccountAliasDraft = draft.accountAliasDraft
        apiModelNameDraft = draft.modelNameDraft
    }

    private func handleDetailsFocusChange(
        _ focusedField: ProviderDetailsFocusField?
    ) {
        guard route == .details else { return }
        let routeToken = ProviderSettingsRoute.details.rawValue
        if let focusedField {
            routeStateStore.recordFocusTarget(
                focusedField.rawValue,
                for: .providers,
                routeToken: routeToken
            )
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard appModel.selectedSection.settingsViewMode == .providers,
                  route == .details,
                  focusedDetailsField == nil else {
                return
            }
            routeStateStore.clearFocusTarget(
                for: .providers,
                routeToken: routeToken
            )
        }
    }

    private func restoreDetailsFocusIfRequested() {
        guard let request = routeStateStore.focusRestorationRequest,
              request.mode == .providers else {
            return
        }
        routeStateStore.consumeFocusRestorationRequest(request)
        guard
              routeStateStore.shouldRestoreFocus(
                  for: request,
                  mode: .providers,
                  routeToken: ProviderSettingsRoute.details.rawValue,
                  voiceOverEnabled: accessibilityVoiceOverEnabled
              ),
              let field = ProviderDetailsFocusField(rawValue: request.target),
              route == .details else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard route == .details,
                  focusedDetailsField == nil else {
                return
            }
            focusedDetailsField = field
        }
    }

    private func cacheProviderDetailsDraft() {
        guard baseURLValidationFailed
                || apiBaseURLDraft != apiBaseURL
                || apiKeychainAccountAliasDraft != apiKeychainAccountAlias
                || apiModelNameDraft != apiModelName else {
            routeStateStore.clearProviderDetailsDraft(
                for: ProviderSettingsRoute.details.rawValue
            )
            return
        }
        routeStateStore.updateProviderDetailsDraft(
            ProviderDetailsRouteDraft(
                apiBaseURLDraft: apiBaseURLDraft,
                accountAliasDraft: apiKeychainAccountAliasDraft,
                modelNameDraft: apiModelNameDraft,
                baseURLValidationFailed: baseURLValidationFailed
            ),
            for: ProviderSettingsRoute.details.rawValue
        )
    }

    private func discardSensitiveDrafts() {
        secretCandidate = ""
        providerUserSecretStoreConfirmed = false
        showsUserSecretDeletionConfirmation = false
        apiKeychainAccountAliasDraft = apiKeychainAccountAlias
    }

    private func commitStoredProviderAccountAlias(
        _ alias: String,
        lifecycleRawValue: String
    ) {
        guard let savedAlias = ProviderSettingsPersistence.saveProviderAccountAlias(alias) else {
            return
        }
        apiKeychainAccountAlias = savedAlias
        apiKeychainAccountAliasDraft = savedAlias
        storedSecretAccountAlias = savedAlias
        secretLifecycleStateRawValue = lifecycleRawValue
        synchronizeExternalTransferGrant()
        cacheProviderDetailsDraft()
    }

    private func cleanupConnectionTestForRouteExit() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        activeConnectionTestID = nil
        isRunningConnectionTest = false
        providerStore.deactivateOpenAIConnectionConfiguration()
    }

    private func setExternalTransferGranted(_ isGranted: Bool) {
        guard isGranted else {
            let durablyRevoked = ProviderSettingsPersistence
                .revokeExternalTransferGrant()
            externalTransferGranted = false
            externalTransferRevocationPersistenceFailed = !durablyRevoked
            cleanupConnectionTestForRouteExit()
            return
        }
        let authorizationIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent()
        guard openAITestConnectionReady,
              let target = ProviderSettingsPersistence
                  .currentExternalTransferTarget(),
              ProviderSettingsPersistence.issueExternalTransferGrant(
                  for: target,
                  authorizationIntent: authorizationIntent
              ) else {
            externalTransferGranted = false
            return
        }
        externalTransferRevocationPersistenceFailed = false
        externalTransferGranted = true
    }

    private func synchronizeExternalTransferGrant() {
        let target = ProviderSettingsPersistence
            .currentExternalTransferTarget()
        if let grant = ProviderSettingsPersistence.externalTransferGrant(),
           grant.target != target {
            externalTransferRevocationPersistenceFailed =
                !ProviderSettingsPersistence.revokeExternalTransferGrant()
        }
        externalTransferGranted = target.map {
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: $0
            )
        } ?? false
    }

}

private struct AICapabilitySettingsSection: View {
    let title: String
    let detail: String?
    let profiles: [AICapabilityProfile]
    @Binding var showsPlanned: Bool

    private var availableProfiles: [AICapabilityProfile] {
        profiles.filter(\.implemented)
    }

    private var plannedProfiles: [AICapabilityProfile] {
        profiles.filter { !$0.implemented }
    }

    var body: some View {
        SettingsSection(title: title) {
            if let detail {
                SettingsSectionNote(text: detail)
            }

            ForEach(Array(availableProfiles.enumerated()), id: \.element.id) { index, profile in
                if index > 0 || detail != nil {
                    SettingsRowDivider()
                }
                AICapabilityProfileRow(profile: profile)
            }

            if !plannedProfiles.isEmpty {
                if !availableProfiles.isEmpty || detail != nil {
                    SettingsRowDivider()
                }
                DisclosureGroup(isExpanded: $showsPlanned) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(plannedProfiles.enumerated()), id: \.element.id) { index, profile in
                            if index > 0 { SettingsRowDivider() }
                            AICapabilityProfileRow(profile: profile)
                        }
                    }
                    .padding(.top, BlocksVisualTokens.Spacing.xs)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.aiCapabilityPlanned"))
                            .font(.body)
                        Text(
                            L10n.format(
                                "settings.aiCapabilityPlannedDetail",
                                Int64(plannedProfiles.count)
                            )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, BlocksVisualTokens.Spacing.sm)
                .blocksAnimation(.reveal, value: showsPlanned)
            }
        }
    }
}

struct AICapabilityProfileRow: View {
    let profile: AICapabilityProfile

    var body: some View {
        SettingsFormRow(
            title: profile.localizedName,
            detail: profileDetail
        ) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
    }

    private var profileDetail: String {
        ([profile.localizedSummary] + profile.boundaryTags)
            .joined(separator: " ")
    }

    private var statusTitle: String {
        if !profile.implemented {
            return L10n.string("settings.aiCapabilityNotImplemented")
        }
        return profile.configured
            ? L10n.string("translation.provider.configured")
            : L10n.string("translation.provider.notConfigured")
    }

    private var statusSymbol: String {
        if !profile.implemented {
            return "clock"
        }
        return profile.configured
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        if !profile.implemented {
            return .secondary
        }
        return profile.configured ? .green : .orange
    }
}

struct ProviderConnectionReadiness {
    let ready: Bool
    let summary: String

    static func make(
        apiKeychainAccountAlias: String,
        apiBaseURL: String,
        apiModelName: String,
        secretLifecycleState: ProviderSecretLifecycleState
    ) -> ProviderConnectionReadiness {
        let hasAlias = !apiKeychainAccountAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBaseURL = ProviderRuntimeGate.normalizedProviderBaseURL(apiBaseURL) != nil
        let hasModel = !apiModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let dryRunReady = hasAlias && hasBaseURL && hasModel && secretLifecycleState.hasStoredUserSecret
        return ProviderConnectionReadiness(
            ready: dryRunReady,
            summary: dryRunReady
                ? L10n.string("settings.providerConnectionReadyDryRun")
                : L10n.string("settings.providerConnectionBlockedAPI")
        )
    }
}

enum ProviderSecretLifecycleState: String {
    case missing
    case testSecretSaved = "test_secret_saved"
    case testSecretRotated = "test_secret_rotated"
    case placeholderSaved = "placeholder_saved"
    case placeholderUpdated = "placeholder_updated"
    case deletedVerified = "deleted_verified"
    case userSecretStored = "user_secret_stored"
    case userSecretDeletedVerified = "user_secret_deleted_verified"

    var localizedTitle: String {
        switch self {
        case .missing:
            L10n.string("settings.providerSecretMissing")
        case .testSecretSaved, .testSecretRotated, .placeholderSaved,
             .placeholderUpdated, .deletedVerified,
             .userSecretDeletedVerified:
            L10n.string("settings.providerSecretMissing")
        case .userSecretStored:
            L10n.string("settings.providerUserSecretStored")
        }
    }

    var hasStoredUserSecret: Bool {
        switch self {
        case .userSecretStored:
            true
        case .missing, .testSecretSaved, .testSecretRotated, .placeholderSaved, .placeholderUpdated, .deletedVerified, .userSecretDeletedVerified:
            false
        }
    }
}

extension OpenAIConnectionStatus {
    var localizedSettingsDetail: String {
        switch self {
        case .success:
            L10n.string("settings.providerConnectionSucceeded.detail")
        case .missingConfiguration:
            L10n.string("settings.providerConnectionBlockedAPI")
        case .confirmationRequired:
            L10n.string("settings.providerConnectionFailure.confirmation")
        case .missingSecret, .unauthorized, .forbidden:
            L10n.string("settings.providerConnectionFailure.credential")
        case .invalidBaseURL:
            L10n.string("settings.providerConnectionFailure.address")
        case .rateLimited:
            L10n.string("settings.providerConnectionFailure.rateLimit")
        case .timeout, .networkError:
            L10n.string("settings.providerConnectionFailure.network")
        case .serverError, .invalidResponse, .httpError:
            L10n.string("settings.providerConnectionFailure.service")
        case .unsupportedCapability:
            L10n.string("settings.providerConnectionFailure.capability")
        }
    }
}
