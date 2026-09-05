import AppKit
import BlocksCore
import SwiftUI

@MainActor
final class TranslationOpenAIServiceEditorSaveSession {
    private var sessionID = UUID()
    private var activeAuthorizationIntent:
        ProviderExternalTransferAuthorizationIntent?
    private var saveCompleted = false

    func begin(
        defaults: UserDefaults = .standard
    ) -> (sessionID: UUID, authorizationIntent: ProviderExternalTransferAuthorizationIntent) {
        let authorizationIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        activeAuthorizationIntent = authorizationIntent
        saveCompleted = false
        return (sessionID, authorizationIntent)
    }

    func isCurrent(
        sessionID: UUID,
        authorizationIntent: ProviderExternalTransferAuthorizationIntent,
        confirmsSecretStorage: Bool,
        confirmsExternalTransfer: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        self.sessionID == sessionID
            && !Task.isCancelled
            && confirmsSecretStorage
            && confirmsExternalTransfer
            && ProviderSettingsPersistence
                .isExternalTransferAuthorizationIntentCurrent(
                    authorizationIntent,
                    defaults: defaults
                )
    }

    func owns(sessionID: UUID) -> Bool {
        self.sessionID == sessionID
    }

    func finishSuccess() {
        saveCompleted = true
        activeAuthorizationIntent = nil
    }

    var shouldInvalidateOnDisappear: Bool {
        !saveCompleted
    }

    @discardableResult
    func invalidate(
        defaults: UserDefaults = .standard
    ) -> Bool? {
        sessionID = UUID()
        saveCompleted = false
        guard let authorizationIntent = activeAuthorizationIntent else {
            return nil
        }
        activeAuthorizationIntent = nil
        return ProviderSettingsPersistence
            .invalidateExternalTransferAuthorizationIntent(
                ifCurrent: authorizationIntent,
                defaults: defaults
            )
    }
}

struct TranslationOpenAIServiceEditorInteractionPolicy {
    let formDisabled: Bool
    let cancelDisabled: Bool
    let saveDisabled: Bool
    let interactiveDismissDisabled: Bool

    init(isSaving: Bool, canSave: Bool) {
        formDisabled = isSaving
        cancelDisabled = false
        saveDisabled = !canSave || isSaving
        interactiveDismissDisabled = false
    }
}

private struct TranslationOpenAIServiceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel

    let onSaved: () -> Void

    @State private var accountAlias =
        UserDefaults.standard.string(
            forKey: "provider.api.keychainAccountAlias"
        ) ?? ""
    @State private var baseURL =
        UserDefaults.standard.string(
            forKey: "provider.api.baseURL"
        ) ?? ""
    @State private var modelName =
        UserDefaults.standard.string(
            forKey: "provider.api.modelName"
        ) ?? ""
    @State private var secret = ""
    @State private var confirmsSecretStorage = false
    @State private var confirmsExternalTransfer = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var saveSession = TranslationOpenAIServiceEditorSaveSession()
    @State private var savingTask: Task<Void, Never>?

    private var canSave: Bool {
        !accountAlias.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && !baseURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && !modelName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && !secret.isEmpty
            && confirmsSecretStorage
            && confirmsExternalTransfer
    }

    var body: some View {
        let interactionPolicy = TranslationOpenAIServiceEditorInteractionPolicy(
            isSaving: isSaving,
            canSave: canSave
        )
        SettingsSheetScaffold(
            title: L10n.string(
                "translation.service.openAICompatible"
            ),
            detail: L10n.string(
                "translation.services.profile.externalDataNotice"
            ),
            systemImage: "sparkles"
        ) {
            VStack(spacing: 0) {
                SettingsTextFieldRow(
                    title: L10n.string(
                        "settings.providerKeychainAccount"
                    ),
                    text: $accountAlias
                )
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title: L10n.string("settings.providerBaseURL"),
                    text: $baseURL
                )
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title: L10n.string("settings.providerModel"),
                    text: $modelName
                )
                SettingsRowDivider()
                SettingsFormRow(
                    title: L10n.string(
                        "settings.providerSecretCandidate"
                    )
                ) {
                    SecureField(
                        L10n.string("settings.providerSecretCandidate"),
                        text: $secret
                    )
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        L10n.string("settings.providerSecretCandidate")
                    )
                }
                SettingsRowDivider()
                SettingsFormRow(
                    title: L10n.string(
                        "settings.providerUserSecretConfirmStore"
                    )
                ) {
                    SettingsCheckbox(
                        L10n.string("settings.providerUserSecretConfirmStore"),
                        isOn: $confirmsSecretStorage
                    )
                    .labelsHidden()
                }
                SettingsRowDivider()
                SettingsFormRow(
                    title: L10n.string(
                        "translation.runtime.externalTransfer"
                    )
                ) {
                    SettingsCheckbox(
                        L10n.string("translation.runtime.externalTransfer"),
                        isOn: $confirmsExternalTransfer
                    )
                    .labelsHidden()
                }
            }
            .disabled(interactionPolicy.formDisabled)
            .textFieldStyle(.roundedBorder)
            SettingsFeedbackSlot(
                feedback: errorMessage.map {
                    SettingsFeedbackDescriptor(
                        kind: .error,
                        title: L10n.string(
                            "translation.services.profile.saveFailed"
                        ),
                        detail: $0
                    )
                }
            )
        } actions: {
            Button(L10n.string("common.cancel")) {
                invalidateSavingSession()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(interactionPolicy.cancelDisabled)
            Button(L10n.string("common.save")) {
                guard !isSaving else { return }
                let saveOperation = saveSession.begin()
                isSaving = true
                savingTask = Task { @MainActor in
                    await save(
                        sessionID: saveOperation.sessionID,
                        authorizationIntent: saveOperation.authorizationIntent
                    )
                    guard saveSession.owns(sessionID: saveOperation.sessionID) else {
                        return
                    }
                    isSaving = false
                    savingTask = nil
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(interactionPolicy.saveDisabled)
        }
        .interactiveDismissDisabled(
            interactionPolicy.interactiveDismissDisabled
        )
        .onDisappear {
            guard saveSession.shouldInvalidateOnDisappear else { return }
            invalidateSavingSession()
        }
    }

    private func save(
        sessionID: UUID,
        authorizationIntent: ProviderExternalTransferAuthorizationIntent
    ) async {
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ) else {
            return
        }
        guard confirmsSecretStorage, confirmsExternalTransfer else {
            errorMessage = L10n.string(
                "translation.services.profile.saveFailed"
            )
            return
        }
        let normalizedAlias = accountAlias.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalizedURL = ProviderRuntimeGate.normalizedProviderBaseURL(baseURL) else {
            errorMessage = L10n.string("translation.services.profile.saveFailed")
            return
        }
        let normalizedModel = modelName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let defaults = UserDefaults.standard
        let previousAlias = ProviderSettingsPersistence.normalizedAccountAlias(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ) ?? ""
        )
        let outcome = await appModel.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: normalizedAlias,
            secretCandidate: secret,
            replacingAccountAlias: previousAlias.isEmpty
                ? nil
                : previousAlias,
            authorizationIntent: authorizationIntent
        )
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ),
              outcome.operationSucceeded,
              outcome.lifecycleRawValue
                == ProviderSecretLifecycleState.userSecretStored.rawValue,
              confirmsSecretStorage,
              confirmsExternalTransfer,
              ProviderSettingsPersistence
                .isExternalTransferAuthorizationIntentCurrent(
                    authorizationIntent,
                    defaults: defaults
                ) else {
            errorMessage = L10n.string(
                "translation.services.profile.saveFailed"
            )
            return
        }
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ),
              ProviderSettingsPersistence.saveProviderAccountAlias(
            normalizedAlias,
            preserving: authorizationIntent,
            defaults: defaults
        ) != nil else {
            errorMessage = L10n.string(
                "translation.services.profile.saveFailed"
            )
            return
        }
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ) else {
            return
        }
        defaults.set(
            outcome.lifecycleRawValue,
            forKey: "provider.api.secretLifecycleState"
        )
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ) else {
            return
        }
        defaults.set(
            normalizedAlias,
            forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
        )
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ),
              ProviderSettingsPersistence.saveProviderBaseURL(
            normalizedURL,
            preserving: authorizationIntent,
            defaults: defaults
        ) != nil,
              isSaveSessionCurrent(
                  sessionID,
                  authorizationIntent: authorizationIntent
              ),
              ProviderSettingsPersistence.saveProviderModelName(
                  normalizedModel,
                  preserving: authorizationIntent,
                  defaults: defaults
              ) != nil else {
            errorMessage = L10n.string(
                "translation.services.profile.saveFailed"
            )
            return
        }
        guard isSaveSessionCurrent(
            sessionID,
            authorizationIntent: authorizationIntent
        ),
              let target = ProviderSettingsPersistence
                  .currentExternalTransferTarget(defaults: defaults),
              ProviderSettingsPersistence.issueExternalTransferGrant(
                  for: target,
                  authorizationIntent: authorizationIntent,
                  defaults: defaults
              ) else {
            errorMessage = L10n.string(
                "translation.services.profile.saveFailed"
            )
            return
        }
        saveSession.finishSuccess()
        onSaved()
        dismiss()
    }

    private func isSaveSessionCurrent(
        _ sessionID: UUID,
        authorizationIntent: ProviderExternalTransferAuthorizationIntent
    ) -> Bool {
        saveSession.isCurrent(
            sessionID: sessionID,
            authorizationIntent: authorizationIntent,
            confirmsSecretStorage: confirmsSecretStorage,
            confirmsExternalTransfer: confirmsExternalTransfer
        )
    }

    private func invalidateSavingSession() {
        savingTask?.cancel()
        savingTask = nil
        isSaving = false
        _ = saveSession.invalidate()
    }
}

private struct TranslationServiceProfileEditorRequest: Identifiable {
    let id = UUID()
    let profile: TranslationServiceProfile?
    let fixedTemplateID: TranslationServiceTemplateID?
    let saveAndEnable: Bool

    init(
        profile: TranslationServiceProfile?,
        fixedTemplateID: TranslationServiceTemplateID? = nil,
        saveAndEnable: Bool = false
    ) {
        self.profile = profile
        self.fixedTemplateID = fixedTemplateID
        self.saveAndEnable = saveAndEnable
    }
}

private struct TranslationServiceRowFeedback: Equatable {
    let message: String
    let token: UUID
}

private enum TranslationSettingsRoute: String {
    case overview
    case services
    case languageResources
    case compatibilitySelection
}

enum TranslationPluginPermissionManifestResolver {
    static func decode(_ manifestJSON: String) -> BlocksNativePluginManifest? {
        try? JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: Data(manifestJSON.utf8)
        )
    }
}

enum TranslationPluginPermissionReviewPresentation {
    static func systemImage(hasValidManifest: Bool) -> String {
        hasValidManifest
            ? "checkmark.shield"
            : "exclamationmark.shield.fill"
    }
}

enum TranslationServiceSettingsDetail {
    static func text(
        for service: TranslationServiceDescriptor,
        isEnabled: Bool,
        enabledServiceIDs: [String]
    ) -> String {
        let status = L10n.string(
            "translation.service.availability.\(service.availability.rawValue)"
        )
        let kind = L10n.string(
            "translation.service.kind.\(service.kind.rawValue)"
        )
        if isEnabled,
           let order = enabledServiceIDs.firstIndex(of: service.id) {
            return L10n.format(
                "translation.services.rowDetail",
                kind,
                status,
                String(order + 1)
            )
        }
        guard service.availability == .available else {
            return "\(kind) · \(status)"
        }
        return "\(kind) · \(status)"
    }
}

enum TranslationServiceEnablementOutcome: Equatable {
    case disable
    case enable
    case requiresConfiguration
    case maximumReached
    case confirmCommunityRisk
}

enum TranslationServiceEnablementPolicy {
    static func resolve(
        requestedEnabled: Bool,
        enabledCount: Int,
        availability: TranslationServiceAvailability,
        kind: TranslationServiceKind,
        communityRiskAcknowledged: Bool
    ) -> TranslationServiceEnablementOutcome {
        guard requestedEnabled else { return .disable }
        guard enabledCount < 4 else { return .maximumReached }
        guard availability != .requiresConfiguration else {
            return .requiresConfiguration
        }
        if kind == .communityWeb, !communityRiskAcknowledged {
            return .confirmCommunityRisk
        }
        return .enable
    }
}

struct TranslationServiceSettingsSnapshot {
    let enabled: [TranslationServiceDescriptor]
    let freeDisabled: [TranslationServiceDescriptor]
    let configuredDisabled: [TranslationServiceDescriptor]
    let unconfiguredTemplates: [TranslationServiceTemplateDescriptor]

    init(
        services: [TranslationServiceDescriptor],
        enabledServiceIDs: [String],
        profiles: [TranslationServiceProfile]
    ) {
        let enabledIDs = Set(enabledServiceIDs)
        enabled = enabledServiceIDs.compactMap { id in
            services.first { $0.id == id }
        }
        freeDisabled = services.filter { service in
            !enabledIDs.contains(service.id)
                && (
                    service.kind == .appleLocal
                        || service.kind == .communityWeb
                )
        }
        configuredDisabled = services.filter { service in
            !enabledIDs.contains(service.id)
                && service.kind != .appleLocal
                && service.kind != .communityWeb
        }
        let configuredTemplateIDs = Set(profiles.map(\.templateID))
        unconfiguredTemplates =
            TranslationServiceTemplateCatalog.externalTemplates
            .filter { !configuredTemplateIDs.contains($0.id) }
    }
}

struct TranslationSettingsPane: View {
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var translationStore: TranslationStore
    @EnvironmentObject private var pluginManager: BlocksNativePluginManager

    private var sourceManagementService:
        TranslationSourceManagementService {
        appModel.translationSourceManagementService
    }

    @State private var nativeLanguage =
        TranslationLanguagePreferences.snapshot()
            .nativeLanguage.rawValue
    @State private var focusLanguageTags =
        TranslationLanguagePreferences.snapshot()
            .focusLanguages.map(\.rawValue)
    @AppStorage("translation.ocr.defaultServiceID")
    private var defaultOCRServiceID = Self.appleVisionOCRServiceID

    @State private var serviceProfileEditor:
        TranslationServiceProfileEditorRequest?
    @State private var serviceProfilePendingDeletion:
        TranslationServiceProfile?
    @State private var openAIServiceEditorPresented = false
    @State private var communityServicePendingEnable:
        TranslationServiceDescriptor?
    @State private var serviceProfileFeedbacks:
        [String: TranslationPluginFeedback] = [:]
    @State private var communityServiceFeedbacks:
        [String: TranslationPluginFeedback] = [:]
    @State private var communityServiceTestingIDs: Set<String> = []
    @ObservedObject private var languagePackController =
        AppleTranslationLanguagePackController.shared
    @State private var compatibilitySelectionBundleIDs =
        TranslationCompatibilitySelectionAuthorizationStore()
            .authorizedBundleIdentifiers.sorted()
    @State private var serviceRowFeedbacks:
        [String: TranslationServiceRowFeedback] = [:]
    @StateObject private var serviceOrderDragCoordinator =
        TranslationServiceOrderDragCoordinator()
    @State private var supportedLanguagesConsumerToken = UUID()

    private static let appleVisionOCRServiceID = "apple-vision"
    private static let rootRouteToken = "root"

    private var routeToken: Binding<String> {
        routeStateStore.secondaryRouteBinding(
            for: .translation,
            default: Self.rootRouteToken
        )
    }

    private var route: TranslationSettingsRoute {
        get {
            let token = routeToken.wrappedValue
            guard token != Self.rootRouteToken else { return .overview }
            return TranslationSettingsRoute(rawValue: token) ?? .overview
        }
        nonmutating set {
            routeToken.wrappedValue = newValue == .overview
                ? Self.rootRouteToken
                : newValue.rawValue
        }
    }

    var body: some View {
        contentWithCommunityConfirmation
            .navigationTitle(routeTitle)
    }

    private var routeTitle: String {
        switch route {
        case .overview:
            L10n.string("settings.translation.title")
        case .services:
            L10n.string("translation.services.manage")
        case .languageResources:
            L10n.string("translation.languageResources.title")
        case .compatibilitySelection:
            L10n.string("translation.selection.compatibility.title")
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch route {
        case .overview:
            serviceSummarySection
            languageSection
            languageResourceSummarySection
            if DistributionChannel.current.supportsSelectionHelper {
                selectionHelperSection
            } else {
                selectionHelperUnavailableSection
            }
            compatibilitySelectionSummarySection
            ocrSection
            pluginSection
        case .services:
            serviceManagementContent
        case .languageResources:
            SettingsSecondaryPageHeader(
                title: L10n.string("translation.languageResources.title"),
                backTitle: L10n.string("common.back")
            ) {
                route = .overview
                restoreOverview(at: SettingsSecondaryRouteAnchor.translationLanguageResources)
            }
            languageResourceSection
        case .compatibilitySelection:
            SettingsSecondaryPageHeader(
                title: L10n.string("translation.selection.compatibility.title"),
                backTitle: L10n.string("common.back")
            ) {
                route = .overview
                restoreOverview(at: SettingsSecondaryRouteAnchor.translationCompatibility)
            }
            compatibilitySelectionSection
        }
    }

    private var contentWithLifecycle: some View {
        routedContent
            .task {
                translationStore.beginSupportedLanguagesConsumer(
                    token: supportedLanguagesConsumerToken
                )
                refreshLanguagePreferences()
                languagePackController.refresh(
                    preferences:
                        TranslationLanguagePreferences.snapshot()
                )
                appModel.selectionHelperSettingsController?.refresh()
                refreshCompatibilitySelectionAuthorizations()
                translationStore.refreshServiceRegistry()
                await sourceManagementService.reloadPluginSnapshot()
            }
            .onChange(of: defaultOCRServiceID) { _, _ in
                appModel.refreshTranslationPluginRuntime()
            }
            .onDisappear {
                translationStore.endSupportedLanguagesConsumer(
                    token: supportedLanguagesConsumerToken
                )
                languagePackController.cancelRefresh()
                serviceRowFeedbacks.removeAll()
            }
            .onReceive(
                languagePackController
                    .preparationController.$phase
            ) { _ in
                languagePackController
                    .synchronizePreparationPhase()
            }
    }

    private var contentWithServiceSheets: some View {
        contentWithLifecycle
            .sheet(item: $serviceProfileEditor) { request in
                TranslationServiceProfileEditorSheet(
                    existingProfile: request.profile,
                    fixedTemplateID: request.fixedTemplateID,
                    saveAndEnable: request.saveAndEnable,
                    onSaved: { profile in
                        serviceProfileFeedbacks[profile.id] =
                            request.saveAndEnable
                                ? .warning(
                                    L10n.string(
                                        "translation.services.profile.enabledNotValidated"
                                    )
                                )
                                : .success(
                                    L10n.string(
                                        "translation.services.profile.testSucceeded"
                                    )
                                )
                    }
                )
                .environmentObject(translationStore)
            }
            .sheet(isPresented: $openAIServiceEditorPresented) {
                TranslationOpenAIServiceEditorSheet {
                    translationStore.refreshServiceRegistry()
                }
                .environmentObject(appModel)
            }
    }

    private var contentWithServiceProfileDialog: some View {
        contentWithServiceSheets
            .confirmationDialog(
                L10n.string(
                    "translation.services.profile.deleteConfirmation"
                ),
                isPresented: Binding(
                    get: { serviceProfilePendingDeletion != nil },
                    set: {
                        if !$0 {
                            serviceProfilePendingDeletion = nil
                        }
                    }
                )
            ) {
                Button(
                    L10n.string(
                        "translation.services.profile.delete"
                    ),
                    role: .destructive
                ) {
                    guard let profile = serviceProfilePendingDeletion else {
                        return
                    }
                    deleteServiceProfile(profile)
                    serviceProfilePendingDeletion = nil
                }
                Button(L10n.string("common.cancel"), role: .cancel) {
                    serviceProfilePendingDeletion = nil
                }
            } message: {
                Text(serviceProfilePendingDeletion?.displayName ?? "")
            }
    }

    private var contentWithCommunityConfirmation: some View {
        contentWithServiceProfileDialog
            .alert(
                L10n.string(
                    "translation.community.confirmation.title"
                ),
                isPresented: Binding(
                    get: { communityServicePendingEnable != nil },
                    set: {
                        if !$0 {
                            communityServicePendingEnable = nil
                        }
                    }
                )
            ) {
                Button(
                    L10n.string(
                        "translation.community.confirmation.enable"
                    )
                ) {
                    guard let service =
                            communityServicePendingEnable else {
                        return
                    }
                    guard let source = TranslationCommunityWebSource(
                        rawValue: service.id
                    ) else {
                        return
                    }
                    TranslationCommunityWebDisclosureStore().acknowledge(
                        source: source
                    )
                    setServiceEnabled(
                        true,
                        service: service
                    )
                    communityServicePendingEnable = nil
                }
                Button(L10n.string("common.cancel"), role: .cancel) {
                    communityServicePendingEnable = nil
                }
            } message: {
                Text(
                    [
                        communityServicePendingEnable?.displayName,
                        L10n.string(
                            "translation.community.confirmation.detail"
                        ),
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                )
            }
    }

    private var serviceSummarySection: some View {
        SettingsSection(
            title: L10n.string("translation.services.title")
        ) {
            SettingsNavigationRow(
                title: L10n.string("translation.services.manage"),
                detail: nil,
                value: L10n.format(
                    "translation.services.enabledCount",
                    String(translationStore.enabledServiceIDs.count)
                )
            ) {
                route = .services
            }
            .id(SettingsSecondaryRouteAnchor.translationServices)
            .accessibilityIdentifier(
                "translation.settings.services.manage"
            )
        }
    }

    @ViewBuilder
    private var serviceManagementContent: some View {
        SettingsSecondaryPageHeader(
            title: L10n.string("translation.services.manage"),
            backTitle: L10n.string("translation.services.back")
        ) {
                route = .overview
                restoreOverview(at: SettingsSecondaryRouteAnchor.translationServices)
        }

        enabledServiceManagementSection
        freeDisabledServiceSection
        requiredConfigurationServiceSection
    }

    private var enabledServiceManagementSection: some View {
        SettingsSection(
            title: L10n.string("translation.services.group.enabled")
        ) {
            if enabledServicesInResultOrder.isEmpty {
                SettingsInlineFeedback(
                    kind: .warning,
                    title: L10n.string("translation.services.noneEnabled"),
                    detail: L10n.string(
                        "translation.services.noneEnabledDetail"
                    )
                )
            } else {
                ForEach(
                    Array(enabledServicesInResultOrder.enumerated()),
                    id: \.element.id
                ) { index, service in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    serviceRow(service, index: index)
                        .overlay(
                            alignment:
                                serviceOrderDragCoordinator
                                    .target?.placement == .after
                                ? .bottom
                                : .top
                        ) {
                            if serviceOrderDragCoordinator.target?
                                .destinationServiceID == service.id {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                }
            }
        }
    }

    private var freeDisabledServiceSection: some View {
        serviceCatalogSection(
            title: L10n.string("translation.services.group.free"),
            services: freeDisabledServices
        )
    }

    @ViewBuilder
    private func serviceCatalogSection(
        title: String,
        services: [TranslationServiceDescriptor]
    ) -> some View {
        SettingsSection(title: title) {
            if services.isEmpty {
                Text(L10n.string("translation.services.group.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(services.enumerated()), id: \.element.id) {
                    index,
                    service in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    serviceRow(service, index: index)
                }
            }
        }
    }

    private var requiredConfigurationServiceSection: some View {
        SettingsSection(
            title: L10n.string(
                "translation.services.group.requiresConfiguration"
            ),
            headerActions: {
                Button {
                    serviceProfileEditor =
                        TranslationServiceProfileEditorRequest(
                            profile: nil,
                            saveAndEnable: false
                        )
                } label: {
                    Label(
                        L10n.string(
                            "translation.services.addProfile"
                        ),
                        systemImage: "plus"
                    )
                }
                .controlSize(.small)
                .accessibilityIdentifier(
                    "translation.settings.service.add"
                )
            }
        ) {
            ForEach(
                Array(configuredDisabledServices.enumerated()),
                id: \.element.id
            ) { index, service in
                if index > 0 {
                    SettingsRowDivider()
                }
                serviceRow(service, index: index)
            }

            ForEach(
                Array(unconfiguredServiceTemplates.enumerated()),
                id: \.element.id
            ) { index, template in
                if !configuredDisabledServices.isEmpty || index > 0 {
                    SettingsRowDivider()
                }
                unconfiguredTemplateRow(template)
            }

            if !configuredDisabledServices.isEmpty
                || !unconfiguredServiceTemplates.isEmpty {
                SettingsRowDivider()
            }
            SettingsActionRow(
                title: L10n.string(
                    "translation.services.externalConfiguration"
                ),
                detail: L10n.string(
                    "translation.services.externalConfigurationDetail"
                )
            ) {
                Button {
                    appModel.selectedSection = .providers
                } label: {
                    Label(
                        L10n.string(
                            "translation.services.openProviderSettings"
                        ),
                        systemImage: "arrow.right.circle"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func unconfiguredTemplateRow(
        _ template: TranslationServiceTemplateDescriptor
    ) -> some View {
        let feedbackID = "template:\(template.id.rawValue)"
        SettingsStatusRow(
            title: template.displayName,
            detail: template.costKinds.map {
                L10n.string(
                    "translation.services.profile.cost.\($0.rawValue)"
                )
            }.joined(separator: " · "),
            status: serviceRowFeedbacks[feedbackID].map {
                SettingsRowStatus(kind: .warning, message: $0.message)
            }
        ) {
            BlocksCompactIconButton(
                systemImage: "gearshape",
                label: L10n.string(
                    "translation.services.profile.configuration"
                )
            ) {
                clearServiceRowFeedback(feedbackID)
                beginConfiguring(template)
            }
            .accessibilityIdentifier(
                "translation.settings.template.\(template.id.rawValue).configure"
            )

            SettingsBooleanSwitch(
                template.displayName,
                isOn: Binding(
                    get: { false },
                    set: { isEnabled in
                        switch TranslationServiceEnablementPolicy.resolve(
                            requestedEnabled: isEnabled,
                            enabledCount:
                                translationStore.enabledServiceIDs.count,
                            availability: .requiresConfiguration,
                            kind: .officialExternal,
                            communityRiskAcknowledged: true
                        ) {
                        case .requiresConfiguration:
                            showServiceRowFeedback(
                                feedbackID: feedbackID,
                                message: L10n.string(
                                    "translation.services.configureFirst"
                                )
                            )
                        case .maximumReached:
                            showMaximumServiceMessage(
                                feedbackID: feedbackID
                            )
                        case .disable, .enable,
                                .confirmCommunityRisk:
                            break
                        }
                    }
                )
            )
            .accessibilityIdentifier(
                "translation.settings.template.\(template.id.rawValue).enabled"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "translation.settings.template.\(template.id.rawValue)"
        )
    }

    @ViewBuilder
    private func serviceRow(
        _ service: TranslationServiceDescriptor,
        index: Int
    ) -> some View {
        let isEnabled = translationStore.enabledServiceIDs.contains(service.id)
        let profile = translationStore.serviceProfiles.first {
            $0.serviceID == service.id
        }
        let profileIsValidated = profile.map {
            translationStore.validatedServiceProfileIDs.contains($0.id)
        } ?? true
        SettingsStatusRow(
            title: service.displayName,
            detail: profile.map {
                serviceProfileDetail(
                    $0,
                    service: service,
                    isEnabled: isEnabled,
                    isValidated: profileIsValidated
                )
            } ?? serviceDetail(service, isEnabled: isEnabled),
            status: serviceRowFeedbacks[service.id].map {
                SettingsRowStatus(kind: .warning, message: $0.message)
            }
        ) {
            if isEnabled {
                TranslationServiceOrderDragSource(
                    serviceID: service.id,
                    displayName: "",
                    accessibilityName: accessibleActionLabel(
                        "translation.services.resultOrder.dragHint",
                        objectName: service.displayName
                    ),
                    coordinator:
                        serviceOrderDragCoordinator,
                    onPerformDrop: applyServiceOrderDrop,
                    canMoveUp: index > 0,
                    canMoveDown:
                        index < enabledServicesInResultOrder.count - 1,
                    onMoveUp: {
                        moveEnabledService(
                            service.id,
                            direction: .up
                        )
                    },
                    onMoveDown: {
                        moveEnabledService(
                            service.id,
                            direction: .down
                        )
                    }
                )
                .frame(width: 28, height: 28)
                .help(
                    L10n.string(
                        "translation.services.resultOrder.dragHint"
                    )
                )
                .contextMenu {
                    Button(
                        L10n.string("translation.services.moveUp")
                    ) {
                        moveEnabledService(
                            service.id,
                            direction: .up
                        )
                    }
                    .disabled(index == 0)

                    Button(
                        L10n.string("translation.services.moveDown")
                    ) {
                        moveEnabledService(
                            service.id,
                            direction: .down
                        )
                    }
                    .disabled(
                        index >= enabledServicesInResultOrder.count - 1
                    )
                }
            }

            if service.kind == .communityWeb, isEnabled {
                if communityServiceTestingIDs.contains(service.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(
                            width: BlocksVisualTokens.Control.compactHeight,
                            height: BlocksVisualTokens.Control.compactHeight
                        )
                        .accessibilityLabel(
                            L10n.string(
                                "translation.community.connectionTest"
                            )
                        )
                } else {
                    Menu {
                        Button(
                            L10n.string(
                                "translation.community.connectionTest"
                            )
                        ) {
                            testCommunityService(service)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12, weight: .medium))
                            .frame(
                                width:
                                    BlocksVisualTokens.Control
                                        .compactHeight,
                                height:
                                    BlocksVisualTokens.Control
                                        .compactHeight
                            )
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(
                        L10n.string(
                            "translation.community.connectionTest"
                        )
                    )
                }
            }

            if let profile {
                BlocksCompactIconButton(
                    systemImage: "checkmark.shield",
                    label: L10n.string(
                        "translation.services.profile.test"
                    )
                ) {
                    testServiceProfile(profile)
                }

                BlocksCompactIconButton(
                    systemImage: "gearshape",
                    label: L10n.string(
                        "translation.services.profile.configuration"
                    )
                ) {
                    clearServiceRowFeedback(service.id)
                    serviceProfileEditor =
                        TranslationServiceProfileEditorRequest(
                            profile: profile
                        )
                }
                .contextMenu {
                    Button(role: .destructive) {
                        serviceProfilePendingDeletion = profile
                    } label: {
                        Label(
                            L10n.string(
                                "translation.services.profile.delete"
                            ),
                            systemImage: "trash"
                        )
                    }
                }
                .accessibilityAction(
                    named: L10n.string(
                        "translation.services.profile.delete"
                    )
                ) {
                    serviceProfilePendingDeletion = profile
                }
            } else if service.id == "openai-compatible" {
                BlocksCompactIconButton(
                    systemImage: "gearshape",
                    label: L10n.string(
                        "translation.services.profile.configuration"
                    )
                ) {
                    clearServiceRowFeedback(service.id)
                    openAIServiceEditorPresented = true
                }
            }

            SettingsBooleanSwitch(
                service.displayName,
                isOn: Binding(
                    get: { isEnabled },
                    set: {
                        setServiceEnabled(
                            $0,
                            service: service
                        )
                    }
                )
            )
            .disabled(
                (
                    service.availability == .unsupported
                        && !isEnabled
                )
                    || (
                        service.kind == .plugin
                            && service.availability == .disabled
                            && !isEnabled
                    )
            )
            .accessibilityIdentifier(
                "translation.settings.service.\(service.id).enabled"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "translation.settings.service.\(service.id)"
        )
        .accessibilitySortPriority(Double(catalogServices.count - index))
        if let profile,
           let feedback = serviceProfileFeedbacks[profile.id] {
            SettingsInlineFeedback(
                kind: feedback.kind,
                title: feedback.title,
                detail: feedback.detail
            )
        } else if let feedback =
                    communityServiceFeedbacks[service.id] {
            SettingsInlineFeedback(
                kind: feedback.kind,
                title: feedback.title,
                detail: feedback.detail
            )
        }
    }

    private var languageSection: some View {
        SettingsSection(
            title: L10n.string("translation.languagePreferences")
        ) {
            SettingsFormRow(
                title: L10n.string("translation.language.native"),
                detail: L10n.string("translation.language.native.detail")
            ) {
                Picker(
                    L10n.string("translation.language.native"),
                    selection: $nativeLanguage
                ) {
                    ForEach(languageOptions, id: \.rawValue) { language in
                        Text(localizedLanguageName(language))
                            .tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
                .onChange(of: nativeLanguage) { _, value in
                    guard let language =
                        TranslationLanguageTag(value) else {
                        return
                    }
                    TranslationLanguagePreferences
                        .setNativeLanguage(language)
                    refreshLanguagePreferences()
                }
            }

            SettingsRowDivider()

            SettingsActionRow(
                title: L10n.string("translation.language.focus"),
                detail: L10n.string("translation.language.focus.detail")
            ) {
                Menu {
                    ForEach(availableFocusLanguageOptions, id: \.rawValue) {
                        language in
                        Button(localizedLanguageName(language)) {
                            addFocusLanguage(language)
                        }
                    }
                } label: {
                    Label(
                        L10n.string("translation.language.focus.add"),
                        systemImage: "plus"
                    )
                }
                .disabled(availableFocusLanguageOptions.isEmpty)
            }

            ForEach(
                Array(focusLanguages.enumerated()),
                id: \.element.rawValue
            ) { index, language in
                SettingsRowDivider()
                SettingsFormRow(
                    title: localizedLanguageName(language),
                    detail: index == 0
                        ? L10n.string(
                            "translation.language.focus.primary"
                        )
                        : nil
                ) {
                    HStack(spacing: 6) {
                        Button {
                            moveFocusLanguage(
                                at: index,
                                offset: -1
                            )
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help(
                            L10n.string(
                                "translation.language.focus.moveUp"
                            )
                        )
                        .accessibilityLabel(
                            accessibleActionLabel(
                                "translation.language.focus.moveUp",
                                objectName: localizedLanguageName(language)
                            )
                        )

                        Button {
                            moveFocusLanguage(
                                at: index,
                                offset: 1
                            )
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == focusLanguages.count - 1)
                        .help(
                            L10n.string(
                                "translation.language.focus.moveDown"
                            )
                        )
                        .accessibilityLabel(
                            accessibleActionLabel(
                                "translation.language.focus.moveDown",
                                objectName: localizedLanguageName(language)
                            )
                        )

                        Button(role: .destructive) {
                            removeFocusLanguage(language)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help(
                            L10n.string(
                                "translation.language.focus.remove"
                            )
                        )
                        .accessibilityLabel(
                            accessibleActionLabel(
                                "translation.language.focus.remove",
                                objectName: localizedLanguageName(language)
                            )
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var languageResourceSection: some View {
        SettingsSection(
            title: L10n.string(
                "translation.languageResources.title"
            )
        ) {
            if languagePackPairs.isEmpty {
                SettingsInlineFeedback(
                    kind: .information,
                    title: L10n.string(
                        "translation.languageResources.empty"
                    ),
                    detail: L10n.string(
                        "translation.languageResources.empty.detail"
                    )
                )
            } else {
                ForEach(
                    Array(languagePackPairs.enumerated()),
                    id: \.element.id
                ) { index, pair in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    SettingsFormRow(
                        title: languagePackTitle(pair),
                        detail: languagePackDetail(pair)
                    ) {
                        languagePackAction(pair)
                    }
                }
            }

            SettingsRowDivider()

            SettingsActionRow(
                title: L10n.string(
                    "translation.languageResources.system.title"
                ),
                detail: L10n.string(
                    "translation.languageResources.system.detail"
                )
            ) {
                Button(
                    L10n.string(
                        "translation.languageResources.system.open"
                    )
                ) {
                    openSystemTranslationLanguageSettings()
                }
            }

            SettingsRowDivider()

            SettingsActionRow(
                title: L10n.string(
                    "translation.dictionary.title"
                ),
                detail: L10n.string(
                    "translation.dictionary.detail"
                )
            ) {
                Button(
                    L10n.string(
                        "translation.dictionary.open"
                    )
                ) {
                    openSystemDictionary()
                }
            }
        }
    }

    private var languageResourceSummarySection: some View {
        SettingsSection(
            title: L10n.string("translation.languageResources.title")
        ) {
            SettingsNavigationRow(
                title: L10n.string("translation.languageResources.title"),
                detail: L10n.string("translation.languageResources.system.detail"),
                value: String(languagePackPairs.count)
            ) {
                route = .languageResources
            }
            .id(SettingsSecondaryRouteAnchor.translationLanguageResources)
        }
    }

    private var selectionHelperSection: some View {
        SettingsSection(
            title: L10n.string(
                "translation.selectionHelper.title"
            )
        ) {
            SettingsFormRow(
                title: L10n.string(
                    "translation.selectionHelper.status"
                ),
                detail: selectionHelperStateDetail
            ) {
                selectionHelperStatusActions
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string(
                    "translation.selectionHelper.shortcut"
                ),
                detail: L10n.string(
                    "translation.selectionHelper.shortcut.detail"
                )
            ) {
                Text(
                    ShortcutCommand.translationPanel
                        .keyEquivalent
                )
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if case .notPaired =
                selectionHelperController.state {
                SettingsRowDivider()
                SettingsFormRow(
                    title: L10n.string(
                        "translation.selectionHelper.pairingCode"
                    ),
                    detail: L10n.string(
                        "translation.selectionHelper.pairingCode.detail"
                    )
                ) {
                    HStack(spacing: 8) {
                        TextField(
                            "000000",
                            text: Binding(
                                get: { selectionHelperController.pairingCode },
                                set: { selectionHelperController.pairingCode = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 92)
                        .onChange(
                            of:
                                selectionHelperController
                                    .pairingCode
                        ) { _, value in
                            let normalized =
                                String(
                                    value
                                        .filter(\.isNumber)
                                        .prefix(6)
                                )
                            if normalized != value {
                                selectionHelperController
                                    .pairingCode =
                                    normalized
                            }
                        }

                        Button(
                            L10n.string(
                                "translation.selectionHelper.pair"
                            )
                        ) {
                            selectionHelperController.pair()
                        }
                        .disabled(
                            selectionHelperController
                                .pairingCode.count != 6
                        )
                    }
                }
            }

            if let error = selectionHelperController.lastError {
                SettingsRowDivider()
                SettingsInlineFeedback(
                    kind: .warning,
                    title: L10n.string(
                        "translation.selectionHelper.feedback"
                    ),
                    detail: error
                )
            }

        }
    }

    /// This pane is only rendered on Direct builds. The controller is owned by
    /// AppModel so the Permission and Translation panes observe one state.
    private var selectionHelperController: SelectionHelperSettingsController {
        guard let controller = appModel.selectionHelperSettingsController else {
            preconditionFailure("Selection Helper is unavailable in this channel")
        }
        return controller
    }

    private var selectionHelperUnavailableSection: some View {
        SettingsSection(
            title: L10n.string("translation.selectionHelper.title")
        ) {
            SettingsReadOnlyRow(
                title: L10n.string("release.storeCapability.title"),
                detail: L10n.string("release.storeCapability.selectionHelper")
            )
        }
    }

    private var compatibilitySelectionSummarySection: some View {
        SettingsSection(
            title: L10n.string("translation.selection.compatibility.title")
        ) {
            SettingsNavigationRow(
                title: L10n.string("translation.selection.compatibility.title"),
                detail: L10n.string("translation.selection.compatibility.detail"),
                value: String(compatibilitySelectionBundleIDs.count)
            ) {
                route = .compatibilitySelection
            }
            .id(SettingsSecondaryRouteAnchor.translationCompatibility)
        }
    }

    private func restoreOverview(at anchorID: String) {
        routeStateStore.restoreSecondaryRoute(for: .translation, anchorID: anchorID)
    }

    private var compatibilitySelectionSection: some View {
        SettingsSection(
            title: L10n.string("translation.selection.compatibility.title")
        ) {
            if compatibilitySelectionBundleIDs.isEmpty {
                SettingsStateView(
                    kind: .empty,
                    title: L10n.string("translation.selection.compatibility.empty"),
                    detail: L10n.string("translation.selection.compatibility.detail")
                )
            } else {
                ForEach(
                    Array(compatibilitySelectionBundleIDs.enumerated()),
                    id: \.element
                ) { index, bundleIdentifier in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    SettingsActionRow(
                        title: compatibilitySelectionApplicationName(
                            bundleIdentifier
                        ),
                        detail: bundleIdentifier
                    ) {
                        Button(
                            L10n.string(
                                "translation.selection.compatibility.revoke"
                            ),
                            role: .destructive
                        ) {
                            TranslationCompatibilitySelectionAuthorizationStore()
                                .revoke(
                                    bundleIdentifier: bundleIdentifier
                                )
                            refreshCompatibilitySelectionAuthorizations()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectionHelperStatusActions: some View {
        switch selectionHelperController.state {
        case .checking, .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    L10n.string(
                        "translation.selectionHelper.connecting"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .notInstalled:
            Button(
                L10n.string(
                    "translation.selectionHelper.download"
                )
            ) {
                selectionHelperController.openDownloadPage()
            }
        case .notRunning:
            HStack(spacing: 8) {
                Button(
                    L10n.string(
                        "translation.selectionHelper.open"
                    )
                ) {
                    selectionHelperController.openHelper()
                }
                Button(
                    L10n.string(
                        "translation.selectionHelper.recheck"
                    )
                ) {
                    selectionHelperController.refresh()
                }
            }
        case .installationConflict:
            Button(
                L10n.string(
                    "translation.selectionHelper.recheck"
                )
            ) {
                selectionHelperController.refresh()
            }
        case .notPaired:
            Button(
                L10n.string(
                    "translation.selectionHelper.open"
                )
            ) {
                selectionHelperController.openHelper()
            }
        case .missingAccessibilityPermission:
            HStack(spacing: 8) {
                Button(
                    L10n.string(
                        "translation.selectionHelper.requestPermission"
                    )
                ) {
                    selectionHelperController
                        .requestAccessibilityPermission()
                }
                Button(
                    L10n.string(
                        "translation.selectionHelper.openPermissionSettings"
                    )
                ) {
                    selectionHelperController
                        .openAccessibilitySettings()
                }
            }
        case .ready:
            HStack(spacing: 8) {
                Button(
                    L10n.string(
                        "translation.selectionHelper.recheck"
                    )
                ) {
                    selectionHelperController.refresh()
                }
                Button(
                    L10n.string(
                        "translation.selectionHelper.disconnect"
                    ),
                    role: .destructive
                ) {
                    selectionHelperController.disconnect()
                }
            }
        case .versionOutdated:
            Button(
                L10n.string(
                    "translation.selectionHelper.update"
                )
            ) {
                selectionHelperController.openDownloadPage()
            }
        case .connectionFailed:
            Button(
                L10n.string(
                    "translation.selectionHelper.recheck"
                )
            ) {
                selectionHelperController.refresh()
            }
        }
    }

    private var selectionHelperStateDetail: String {
        let suffix: String
        switch selectionHelperController.state {
        case .checking:
            suffix = "checking"
        case .notInstalled:
            suffix = "notInstalled"
        case .notRunning:
            suffix = "notRunning"
        case .installationConflict:
            suffix = "installationConflict"
        case .notPaired:
            suffix = "notPaired"
        case .connecting:
            suffix = "connecting"
        case .missingAccessibilityPermission:
            suffix = "missingPermission"
        case let .ready(version):
            return L10n.format(
                "translation.selectionHelper.state.ready",
                version
            )
        case .versionOutdated:
            suffix = "outdated"
        case .connectionFailed:
            suffix = "connectionFailed"
        }
        return L10n.string(
            "translation.selectionHelper.state.\(suffix)"
        )
    }

    private func refreshCompatibilitySelectionAuthorizations() {
        compatibilitySelectionBundleIDs =
            TranslationCompatibilitySelectionAuthorizationStore()
                .authorizedBundleIdentifiers.sorted()
    }

    private func compatibilitySelectionApplicationName(
        _ bundleIdentifier: String
    ) -> String {
        guard let applicationURL =
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else {
            return bundleIdentifier
        }
        return FileManager.default
            .displayName(atPath: applicationURL.path)
            .replacingOccurrences(
                of: ".app",
                with: ""
            )
    }

    @ViewBuilder
    private func languagePackAction(
        _ pair: AppleTranslationLanguagePair
    ) -> some View {
        let state = languagePackController.states[pair] ?? .checking
        switch state {
        case .checking, .awaitingSystemConfirmation,
             .installing, .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(languagePackStateTitle(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloadable, .failed:
            Button(
                L10n.string(
                    "translation.languagePack.download"
                )
            ) {
                languagePackController.prepare(
                    pair,
                    preferences:
                        TranslationLanguagePreferences.snapshot()
                )
            }
            .disabled(languagePackController.activePair != nil)
        case .installed:
            Label(
                L10n.string(
                    "translation.languagePack.installed"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .unsupported:
            Text(
                L10n.string(
                    "translation.languagePack.unsupported"
                )
            )
            .foregroundStyle(.secondary)
        }
    }

    private var ocrSection: some View {
        SettingsSection(
            title: L10n.string("translation.ocr.title")
        ) {
            SettingsFormRow(
                title: L10n.string("translation.ocr.defaultService"),
                detail: defaultOCRServiceDetail
            ) {
                Picker(
                    L10n.string("translation.ocr.defaultService"),
                    selection: $defaultOCRServiceID
                ) {
                    Text(L10n.string("translation.ocr.appleVision"))
                        .tag(Self.appleVisionOCRServiceID)
                    if selectedOCRPluginID != nil,
                       selectedOCRPlugin == nil {
                        Text(unavailableOCRSelectionTitle)
                            .tag(defaultOCRServiceID)
                    }
                    ForEach(enabledOCRPlugins) { plugin in
                        Text(plugin.displayName)
                            .tag("plugin:\(plugin.id)")
                            .disabled(
                                !plugin.isEnabled
                                    || plugin.approvalStatus != .approved
                            )
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }

            if selectedOCRPluginIsUnavailable {
                SettingsRowDivider()
                SettingsActionRow(
                    title: L10n.string(
                        "translation.plugin.runtimeUnavailable"
                    ),
                    detail: unavailableOCRSelectionDetail
                ) {
                    Button {
                        defaultOCRServiceID =
                            Self.appleVisionOCRServiceID
                    } label: {
                        Label(
                            L10n.string(
                                "translation.ocr.useAppleVision"
                            ),
                            systemImage: "text.viewfinder"
                        )
                    }
                }
            }
        }
    }

    private var pluginSection: some View {
        SettingsSection(
            title: L10n.string("translation.plugin.title")
        ) {
            SettingsNavigationRow(
                title: L10n.string("settings.hooks.title"),
                detail: L10n.string("settings.hooks.detail"),
                value: L10n.format(
                    "translation.plugin.enabledCount",
                    String(pluginManager.plugins.filter(\.isEnabled).count)
                )
            ) {
                appModel.openMainWindow(section: .hooks)
            }
            .accessibilityIdentifier(
                "translation.settings.plugins.manage"
            )
        }
    }

    private var enabledServicesInResultOrder:
        [TranslationServiceDescriptor] {
        serviceSettingsSnapshot.enabled
    }

    private var catalogServices: [TranslationServiceDescriptor] {
        translationStore.availableServices
    }

    private var freeDisabledServices:
        [TranslationServiceDescriptor]
    {
        serviceSettingsSnapshot.freeDisabled
    }

    private var configuredDisabledServices:
        [TranslationServiceDescriptor]
    {
        serviceSettingsSnapshot.configuredDisabled
    }

    private var unconfiguredServiceTemplates:
        [TranslationServiceTemplateDescriptor]
    {
        serviceSettingsSnapshot.unconfiguredTemplates
    }

    private var serviceSettingsSnapshot:
        TranslationServiceSettingsSnapshot
    {
        TranslationServiceSettingsSnapshot(
            services: catalogServices,
            enabledServiceIDs: translationStore.enabledServiceIDs,
            profiles: translationStore.serviceProfiles
        )
    }

    private var enabledOCRPlugins: [BlocksNativePluginMetadata] {
        pluginManager.plugins.filter {
            $0.capabilities.contains(.ocr)
        }
    }

    private var selectedOCRPluginID: String? {
        let prefix = TranslationPluginRuntimeSelection
            .pluginOCRServicePrefix
        guard defaultOCRServiceID.hasPrefix(prefix) else { return nil }
        let pluginID = String(defaultOCRServiceID.dropFirst(prefix.count))
        return pluginID.isEmpty ? nil : pluginID
    }

    private var selectedOCRPlugin: BlocksNativePluginMetadata? {
        guard let selectedOCRPluginID else { return nil }
        return enabledOCRPlugins.first { $0.id == selectedOCRPluginID }
    }

    private var selectedOCRPluginIsUnavailable: Bool {
        TranslationPluginRuntimeSelection.enabledOCRPluginID(
            preferredServiceID: defaultOCRServiceID,
            plugins: pluginManager.plugins
        ) == nil && selectedOCRPluginID != nil
    }

    private var unavailableOCRSelectionTitle: String {
        [
            selectedOCRPlugin?.displayName ?? selectedOCRPluginID ?? "",
            L10n.string("translation.plugin.runtimeUnavailable"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " — ")
    }

    private var unavailableOCRSelectionDetail: String {
        guard let plugin = selectedOCRPlugin else {
            return L10n.string("translation.plugin.runtimeUnavailable")
        }
        if !plugin.isEnabled {
            return L10n.string("translation.error.pluginDisabled")
        }
        if plugin.approvalStatus != .approved {
            return L10n.string("translation.error.pluginNotApproved")
        }
        return L10n.string("translation.plugin.runtimeUnavailable")
    }

    private var defaultOCRServiceDetail: String {
        if selectedOCRPluginIsUnavailable {
            return unavailableOCRSelectionDetail
        }
        return selectedOCRPlugin?.displayName
            ?? L10n.string("translation.ocr.appleVision")
    }

    private var languageOptions: [TranslationLanguageTag] {
        var values = Set(translationStore.supportedLanguages)
        for service in translationStore.availableServices {
            values.formUnion(service.supportedTargetLanguages)
        }
        for fallback in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt-BR"] {
            if let tag = TranslationLanguageTag(fallback) {
                values.insert(tag)
            }
        }
        if let current = TranslationLanguageTag(nativeLanguage) {
            values.insert(current)
        }
        values.formUnion(focusLanguages)
        return values.sorted {
            localizedLanguageName($0).localizedStandardCompare(localizedLanguageName($1))
                == .orderedAscending
        }
    }

    private func serviceDetail(
        _ service: TranslationServiceDescriptor,
        isEnabled: Bool
    ) -> String {
        let base = TranslationServiceSettingsDetail.text(
            for: service,
            isEnabled: isEnabled,
            enabledServiceIDs: translationStore.enabledServiceIDs
        )
        guard service.kind == .communityWeb else {
            return base
        }
        return [
            base,
            L10n.string("translation.community.service.detail"),
        ].joined(separator: " · ")
    }

    private func setServiceEnabled(
        _ enabled: Bool,
        service: TranslationServiceDescriptor
    ) {
        let communityRiskAcknowledged =
            TranslationCommunityWebSource(rawValue: service.id).map {
                TranslationCommunityWebDisclosureStore()
                    .isAcknowledged(source: $0)
            } ?? true
        switch TranslationServiceEnablementPolicy.resolve(
            requestedEnabled: enabled,
            enabledCount: translationStore.enabledServiceIDs.count,
            availability: service.availability,
            kind: service.kind,
            communityRiskAcknowledged: communityRiskAcknowledged
        ) {
        case .disable:
            clearServiceRowFeedback(service.id)
            updateServiceEnabled(
                false,
                serviceID: service.id
            )
        case .maximumReached:
            showMaximumServiceMessage(feedbackID: service.id)
        case .requiresConfiguration:
            showServiceRowFeedback(
                feedbackID: service.id,
                message: L10n.string(
                    "translation.services.configureFirst"
                )
            )
        case .enable:
            clearServiceRowFeedback(service.id)
            updateServiceEnabled(
                true,
                serviceID: service.id
            )
        case .confirmCommunityRisk:
            communityServicePendingEnable = service
        }
    }

    private func updateServiceEnabled(
        _ enabled: Bool,
        serviceID: String
    ) {
        Task {
            do {
                try await sourceManagementService.setSourceEnabled(
                    enabled,
                    sourceID: serviceID
                )
            } catch {
                showServiceRowFeedback(
                    feedbackID: serviceID,
                    message:
                        TranslationErrorPresentation.message(
                            for: error
                        )
                )
            }
        }
    }

    private func showMaximumServiceMessage(feedbackID: String) {
        showServiceRowFeedback(
            feedbackID: feedbackID,
            message: L10n.string(
                "translation.services.maximumReached.detail"
            )
        )
    }

    private func beginConfiguring(
        _ template: TranslationServiceTemplateDescriptor
    ) {
        serviceProfileEditor = TranslationServiceProfileEditorRequest(
            profile: nil,
            fixedTemplateID: template.id,
            saveAndEnable: false
        )
    }

    private func showServiceRowFeedback(
        feedbackID: String,
        message: String
    ) {
        let token = UUID()
        serviceRowFeedbacks[feedbackID] =
            TranslationServiceRowFeedback(
                message: message,
                token: token
            )
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard serviceRowFeedbacks[feedbackID]?.token == token else {
                return
            }
            serviceRowFeedbacks.removeValue(forKey: feedbackID)
        }
    }

    private func clearServiceRowFeedback(_ feedbackID: String) {
        serviceRowFeedbacks.removeValue(forKey: feedbackID)
    }

    private func applyServiceOrderDrop(
        _ target: TranslationResultOrderDragTarget
    ) {
        let remaining = translationStore.enabledServiceIDs.filter {
            $0 != target.sourceServiceID
        }
        guard let destinationIndex = remaining.firstIndex(
            of: target.destinationServiceID
        ) else {
            serviceOrderDragCoordinator.endSession()
            return
        }
        let beforeServiceID: String?
        switch target.placement {
        case .before:
            beforeServiceID = target.destinationServiceID
        case .after:
            let nextIndex = remaining.index(after: destinationIndex)
            beforeServiceID =
                nextIndex < remaining.endIndex
                ? remaining[nextIndex]
                : nil
        }
        sourceManagementService.moveEnabledSource(
            sourceID: target.sourceServiceID,
            before: beforeServiceID
        )
    }

    private enum EnabledServiceMoveDirection {
        case up
        case down
    }

    private func moveEnabledService(
        _ serviceID: String,
        direction: EnabledServiceMoveDirection
    ) {
        let serviceIDs = translationStore.enabledServiceIDs
        guard let index = serviceIDs.firstIndex(of: serviceID) else {
            return
        }
        let beforeServiceID: String?
        switch direction {
        case .up:
            guard index > serviceIDs.startIndex else { return }
            beforeServiceID = serviceIDs[serviceIDs.index(before: index)]
        case .down:
            let nextIndex = serviceIDs.index(after: index)
            guard nextIndex < serviceIDs.endIndex else { return }
            let followingIndex = serviceIDs.index(after: nextIndex)
            beforeServiceID =
                followingIndex < serviceIDs.endIndex
                    ? serviceIDs[followingIndex]
                    : nil
        }
        sourceManagementService.moveEnabledSource(
            sourceID: serviceID,
            before: beforeServiceID
        )
    }

    private func serviceProfileDetail(
        _ profile: TranslationServiceProfile,
        service: TranslationServiceDescriptor,
        isEnabled: Bool,
        isValidated: Bool
    ) -> String {
        let base = serviceDetail(service, isEnabled: isEnabled)
        guard let template =
                TranslationServiceTemplateCatalog.descriptor(
                    for: profile.templateID
                ) else {
            return base
        }
        let costs = template.costKinds.map {
            L10n.string(
                "translation.services.profile.cost.\($0.rawValue)"
            )
        }.joined(separator: " · ")
        let validation = L10n.string(
            isValidated
                ? "translation.services.profile.validated"
                : "translation.services.profile.notValidated"
        )
        let recipient = L10n.format(
            "translation.services.profile.dataRecipient",
            template.transmitsDataTo,
            template.verifiedOn
        )
        return [base, costs, validation, recipient]
            .joined(separator: " · ")
    }

    private func accessibleActionLabel(
        _ localizationKey: String,
        objectName: String
    ) -> String {
        "\(L10n.string(localizationKey)) — \(objectName)"
    }

    private func localizedLanguageName(_ tag: TranslationLanguageTag) -> String {
        Locale.current.localizedString(forIdentifier: tag.rawValue)
            ?? Locale.current.localizedString(forLanguageCode: tag.rawValue)
            ?? tag.rawValue
    }

    private var focusLanguages: [TranslationLanguageTag] {
        focusLanguageTags.compactMap { TranslationLanguageTag($0) }
    }

    private var languagePackPairs: [AppleTranslationLanguagePair] {
        guard let native = TranslationLanguageTag(nativeLanguage) else {
            return []
        }
        return AppleTranslationLanguagePairResolver.directedPairs(
            for: TranslationUserLanguagePreferenceSnapshot(
                nativeLanguage: native,
                focusLanguages: focusLanguages,
                recentlyUsedFocusLanguage: nil
            )
        )
    }

    private var availableFocusLanguageOptions:
        [TranslationLanguageTag] {
        languageOptions.filter { candidate in
            guard candidate.rawValue != nativeLanguage else {
                return false
            }
            return !focusLanguages.contains(where: {
                TranslationTargetResolver.isSameLanguage(
                    $0,
                    candidate
                )
            })
        }
    }

    private func refreshLanguagePreferences() {
        let snapshot = TranslationLanguagePreferences.snapshot()
        nativeLanguage = snapshot.nativeLanguage.rawValue
        focusLanguageTags =
            snapshot.focusLanguages.map(\.rawValue)
        languagePackController.refresh(preferences: snapshot)
    }

    private func persistFocusLanguages(
        _ languages: [TranslationLanguageTag]
    ) {
        TranslationLanguagePreferences.setFocusLanguages(languages)
        refreshLanguagePreferences()
    }

    private func addFocusLanguage(
        _ language: TranslationLanguageTag
    ) {
        persistFocusLanguages(focusLanguages + [language])
    }

    private func removeFocusLanguage(
        _ language: TranslationLanguageTag
    ) {
        persistFocusLanguages(
            focusLanguages.filter {
                !TranslationTargetResolver.isSameLanguage(
                    $0,
                    language
                )
            }
        )
    }

    private func moveFocusLanguage(at index: Int, offset: Int) {
        var languages = focusLanguages
        let destination = index + offset
        guard languages.indices.contains(index),
              languages.indices.contains(destination) else {
            return
        }
        languages.swapAt(index, destination)
        persistFocusLanguages(languages)
    }

    private func languagePackTitle(
        _ pair: AppleTranslationLanguagePair
    ) -> String {
        "\(localizedLanguageName(pair.source)) → "
            + localizedLanguageName(pair.target)
    }

    private func languagePackDetail(
        _ pair: AppleTranslationLanguagePair
    ) -> String {
        let state = languagePackController.states[pair] ?? .checking
        if case let .failed(message) = state {
            return message
        }
        return languagePackStateTitle(state)
    }

    private func languagePackStateTitle(
        _ state: AppleTranslationLanguagePackState
    ) -> String {
        let key: String
        switch state {
        case .checking:
            key = "checking"
        case .installed:
            key = "installed"
        case .downloadable:
            key = "downloadable"
        case .unsupported:
            key = "unsupported"
        case .awaitingSystemConfirmation:
            key = "awaitingConfirmation"
        case .installing:
            key = "installing"
        case .verifying:
            key = "verifying"
        case .failed:
            key = "failed"
        }
        return L10n.string("translation.languagePack.\(key)")
    }

    private func openSystemTranslationLanguageSettings() {
        guard let url = URL(
            string:
                "x-apple.systempreferences:com.apple.Localization-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openSystemDictionary() {
        let dictionaryURL = URL(
            fileURLWithPath:
                "/System/Applications/Dictionary.app",
            isDirectory: true
        )
        let configuration =
            NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
            at: dictionaryURL,
            configuration: configuration
        )
    }

    private func testServiceProfile(
        _ profile: TranslationServiceProfile
    ) {
        serviceProfileFeedbacks[profile.id] = nil
        Task {
            do {
                _ = try await sourceManagementService
                    .testServiceProfile(profile)
                serviceProfileFeedbacks[profile.id] = .success(
                    L10n.string(
                        "translation.services.profile.testSucceeded"
                    )
                )
            } catch {
                serviceProfileFeedbacks[profile.id] = .failure(
                    L10n.string(
                        "translation.services.profile.testFailed"
                    )
                )
            }
        }
    }

    private func testCommunityService(
        _ service: TranslationServiceDescriptor
    ) {
        guard service.kind == .communityWeb else { return }
        communityServiceFeedbacks[service.id] = nil
        communityServiceTestingIDs.insert(service.id)
        Task {
            defer {
                communityServiceTestingIDs.remove(service.id)
            }
            do {
                try await sourceManagementService
                    .testCommunitySource(
                    sourceID: service.id
                )
                communityServiceFeedbacks[service.id] = .success(
                    L10n.string(
                        "translation.community.connectionTestSucceeded"
                    ),
                    title: L10n.string(
                        "translation.community.connectionTestSucceededTitle"
                    )
                )
            } catch {
                communityServiceFeedbacks[service.id] = .failure(
                    TranslationErrorPresentation.message(for: error),
                    title: L10n.string(
                        "translation.community.connectionTestFailed"
                    )
                )
            }
        }
    }

    private func deleteServiceProfile(
        _ profile: TranslationServiceProfile
    ) {
        Task {
            do {
                try await translationStore.deleteServiceProfile(
                    id: profile.id
                )
                serviceProfileFeedbacks[profile.id] = nil
            } catch {
                serviceProfileFeedbacks[profile.id] = .failure(error)
            }
        }
    }
}

private struct TranslationPluginFeedback {
    let kind: SettingsInlineFeedbackKind
    let title: String
    let detail: String

    static func success(
        _ detail: String,
        title: String = L10n.string(
            "translation.plugin.operationSucceeded"
        )
    ) -> Self {
        Self(
            kind: .success,
            title: title,
            detail: detail
        )
    }

    static func failure(
        _ detail: String,
        title: String = L10n.string("translation.plugin.operationFailed")
    ) -> Self {
        Self(kind: .error, title: title, detail: detail)
    }

    static func failure(_ error: Error) -> Self {
        failure(
            TranslationPluginSettingsErrorPresentation.message(
                for: error
            )
        )
    }

    static func warning(_ detail: String) -> Self {
        Self(
            kind: .warning,
            title: L10n.string("translation.plugin.installedOnly"),
            detail: detail
        )
    }
}

private enum TranslationPluginSettingsErrorPresentation {
    static func message(
        for error: Error
    ) -> String {
        if let managerError = error as? BlocksNativePluginManagerError {
            switch managerError {
            case .operationInProgress:
                return L10n.string(
                    "translation.plugin.error.operationInProgress"
                )
            case .storageUnavailable:
                return L10n.string(
                    "translation.plugin.error.storage"
                )
            case .pendingInstallationMissing,
                 .pendingInstallationChanged:
                return L10n.string(
                    "translation.plugin.error.reviewAgain"
                )
            case let .missingRequiredSecret(secretID):
                return L10n.format(
                    "translation.plugin.error.missingSecret",
                    secretID
                )
            case let .missingRequiredConfiguration(fieldID):
                return L10n.format(
                    "translation.plugin.error.missingConfiguration",
                    fieldID
                )
            case .validationRequired:
                return L10n.string(
                    "translation.plugin.error.validationRequired"
                )
            case .reservedOfficialIdentifier:
                return L10n.string(
                    "translation.plugin.error.invalidPackage"
                )
            case .externalInstallationUnavailable:
                return L10n.string(
                    "release.storeCapability.externalPlugins"
                )
            case .managedRootIsSymbolicLink,
                 .installedPackageMissing,
                 .installedPathEscapesRoot,
                 .packageSnapshotIncomplete,
                 .fileWriteFailed,
                 .rollbackIncomplete,
                 .recoveryConflict:
                return L10n.string(
                    "translation.plugin.error.storage"
                )
            }
        }
        if error is BlocksNativePluginValidationError {
            return L10n.string(
                "translation.plugin.error.invalidPackage"
            )
        }
        if error is BlocksNativePluginSecretStoreError {
            return L10n.string(
                "translation.plugin.error.secretStorage"
            )
        }
        if let executionError = error as? BlocksNativePluginExecutionError {
            return TranslationErrorPresentation.message(
                code: TranslationPluginServiceErrorMapper.code(
                    for: executionError
                ),
                fallback: executionError.errorDescription
            )
        }
        return message(fallback: error.localizedDescription)
    }

    static func message(fallback _: String?) -> String {
        L10n.string("translation.plugin.error.generic")
    }
}
