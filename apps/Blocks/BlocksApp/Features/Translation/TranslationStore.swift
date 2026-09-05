import BlocksCore
import Foundation
import OSLog

enum TranslationFavoriteErrorPresentation {
    static var userMessage: String {
        L10n.string("translation.favorite.operationFailedDetail")
    }
}

enum TranslationServiceProfileMutationError: Error, LocalizedError {
    case rollbackFailed
    case configurationChangedDuringValidation
    case mutationInProgress

    var errorDescription: String? {
        switch self {
        case .rollbackFailed:
            "The translation service change could not be completed safely. No service was enabled; review the stored configuration before retrying."
        case .configurationChangedDuringValidation:
            "The translation service changed while it was being verified. Verify the current configuration again."
        case .mutationInProgress:
            "Another change to this translation service is still in progress."
        }
    }
}

/// Main-thread state facade for translation configuration and immutable
/// favorites. Translation execution lives in per-panel
/// `TranslationRunCoordinator` instances; there is intentionally no legacy
/// single-result/mock runtime in this store.
@MainActor
final class TranslationStore: ObservableObject {
    private static let favoriteLogger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationFavorites"
    )

    @Published private(set) var availableServices: [TranslationServiceDescriptor] = []
    @Published private(set) var enabledServiceIDs: [String] = [] {
        didSet {
            guard enabledServiceIDs != oldValue else { return }
            enabledServiceOrderRevision &+= 1
        }
    }
    @Published private(set) var serviceProfiles: [TranslationServiceProfile] = []
    @Published private(set) var serviceProfileErrorMessage: String?
    @Published private(set) var isLoadingServiceProfiles = false
    @Published private(set) var validatedServiceProfileIDs: Set<String> = []
    @Published private(set) var supportedSourceLanguages: [TranslationLanguageTag] = []
    @Published private(set) var supportedLanguages: [TranslationLanguageTag] = []
    @Published private(set) var favoriteSummaries: [TranslationFavoriteSummary] = []
    @Published private(set) var favoriteTotalCount = 0
    @Published private(set) var selectedFavorite: TranslationFavorite?
    @Published private(set) var favoriteErrorMessage: String?
    @Published private(set) var isLoadingFavorites = false
    @Published private(set) var isLoadingMoreFavorites = false
    @Published private(set) var favoriteHasMore = false
    @Published private(set) var isLoadingFavoriteDetail = false

    private let serviceRegistry: TranslationServiceRegistry
    private let favoriteWorker: TranslationFavoriteRepositoryWorker?
    private let serviceProfileRepository: TranslationServiceProfileRepository?
    private let serviceCredentialStore:
        any TranslationServiceCredentialStoring
    private let officialTransport: any TranslationOfficialHTTPTransport
    private let officialServiceExecutionGate:
        TranslationOfficialServiceExecutionGate
    private let serviceProfileRefreshLoader:
        (@Sendable () async throws -> TranslationOfficialServiceProfileBatch)?
    private let defaults: UserDefaults
    private var builtInAdapters: [any TranslationServiceAdapter]
    private var communityWebAdapters:
        [any TranslationServiceAdapter]
    private var officialProfileAdapters:
        [String: any TranslationServiceAdapter] = [:]
    private var pluginAdapters: [String: any TranslationServiceAdapter] = [:]
    private let appleSupportedLanguagesProvider:
        @Sendable () async -> [TranslationLanguageTag]
    private var languageRefreshTask: Task<Void, Never>?
    private var supportedLanguageGeneration: UInt64 = 0
    private var refreshedAppleLanguageGeneration: UInt64?
    private var supportedLanguageConsumerTokens: Set<UUID> = []
    private var favoriteListTask: Task<Void, Never>?
    private var favoriteDetailTask: Task<Void, Never>?
    private var serviceProfileTask: Task<Void, Never>?
    private var serviceProfileMutationGenerations: [String: UInt64] = [:]
    // Connection validation is deliberately separate from the display/runtime
    // gate so an explicitly requested test can run while a profile is
    // disabled. Keeping one gate per profile lets a configuration mutation
    // revoke the in-flight validation lease without disturbing other profiles.
    private var serviceProfileValidationGates:
        [String: TranslationOfficialServiceExecutionGate] = [:]
    private var mutatingServiceProfileIDs: Set<String> = []
    private var enabledServiceOrderRevision: UInt64 = 0
    private var favoriteQuery = ""

    private static let favoritePageSize = 100

    init(
        providerKeychainService: ProviderKeychainService = ProviderKeychainService(),
        translationRuntimeService: OpenAITranslationRuntimeService = OpenAITranslationRuntimeService(),
        readProviderSecret: ((String) throws -> ProviderUserSecretMaterial)? = nil,
        favoriteRepository: TranslationFavoriteRepository? = nil,
        serviceProfileRepository: TranslationServiceProfileRepository? = nil,
        serviceCredentialStore: any TranslationServiceCredentialStoring =
            TranslationServiceCredentialStore(),
        officialTransport: any TranslationOfficialHTTPTransport =
            URLSessionTranslationOfficialHTTPTransport(),
        communityWebTransport:
            any TranslationCommunityWebHTTPTransport =
                URLSessionTranslationCommunityWebHTTPTransport(),
        defaults: UserDefaults = .standard,
        serviceRegistry: TranslationServiceRegistry? = nil,
        appleRuntimeController: AppleTranslationRuntimeController? = nil,
        officialServiceExecutionGate:
            TranslationOfficialServiceExecutionGate =
                TranslationOfficialServiceExecutionGate(),
        serviceProfileRefreshLoader:
            (@Sendable () async throws -> TranslationOfficialServiceProfileBatch)? = nil,
        appleSupportedLanguagesProvider:
            @escaping @Sendable () async -> [TranslationLanguageTag] = {
                await AppleLocalTranslationServiceAdapter.supportedLanguages()
            }
    ) {
        let registry = serviceRegistry ?? TranslationServiceRegistry()
        let appleRuntime = appleRuntimeController ?? AppleTranslationRuntimeController()
        self.serviceRegistry = registry
        favoriteWorker = favoriteRepository.map(
            TranslationFavoriteRepositoryWorker.init(repository:)
        )
        self.serviceProfileRepository = serviceProfileRepository
        self.serviceCredentialStore = serviceCredentialStore
        self.officialTransport = officialTransport
        self.officialServiceExecutionGate = officialServiceExecutionGate
        self.serviceProfileRefreshLoader = serviceProfileRefreshLoader
        self.defaults = defaults
        self.appleSupportedLanguagesProvider = appleSupportedLanguagesProvider
        let communityDisclosureStore =
            TranslationCommunityWebDisclosureStore(defaults: defaults)
        builtInAdapters = [
            AppleLocalTranslationServiceAdapter(runtimeController: appleRuntime),
            OpenAICompatibleTranslationServiceAdapter(
                runtimeService: translationRuntimeService,
                providerKeychainService: providerKeychainService,
                defaults: defaults,
                configuration: {
                    OpenAITranslationServiceConfiguration.current(defaults: defaults)
                },
                readProviderSecret: readProviderSecret
            ),
        ]
        communityWebAdapters =
            TranslationCommunityWebSource.productionAvailable.map {
                TranslationCommunityWebServiceAdapter(
                    source: $0,
                    transport: communityWebTransport,
                    disclosureStore: communityDisclosureStore
                )
            }
        publishRegistry()
        let persistedServiceIDs = defaults.object(
            forKey: Self.enabledServicesDefaultsKey
        ) == nil
            ? nil
            : defaults.stringArray(forKey: Self.enabledServicesDefaultsKey)
        let normalizedEnabledServiceIDs = Self.normalizedEnabledServiceIDs(
            persistedServiceIDs,
            availableServices: availableServices
        )
        enabledServiceIDs = normalizedEnabledServiceIDs.filter { serviceID in
            guard let source = TranslationCommunityWebSource(
                rawValue: serviceID
            ) else {
                return true
            }
            return communityDisclosureStore.isAcknowledged(source: source)
        }
        publishRegistry()
        if persistedServiceIDs == nil
            || enabledServiceIDs != normalizedEnabledServiceIDs {
            defaults.set(enabledServiceIDs, forKey: Self.enabledServicesDefaultsKey)
        }
        rebuildSupportedLanguageFallback()
        refreshFavorites()
        refreshServiceProfiles()
    }

    deinit {
        languageRefreshTask?.cancel()
        favoriteListTask?.cancel()
        favoriteDetailTask?.cancel()
        serviceProfileTask?.cancel()
    }

    var enabledServices: [TranslationServiceDescriptor] {
        enabledServiceIDs.compactMap { serviceID in
            availableServices.first { $0.id == serviceID }
        }
    }

    func adaptersForEnabledServices(
        appleRuntimeController: AppleTranslationRuntimeController? = nil
    ) -> [any TranslationServiceAdapter] {
        serviceRegistry.orderedAdapters(
            serviceIDs: enabledServiceIDs,
            maximumCount: 4
        )
        .filter { $0.descriptor.availability == .available }
        .map { adapter in
            guard adapter.descriptor.id == "apple-local",
                  let appleRuntimeController else {
                return adapter
            }
            return AppleLocalTranslationServiceAdapter(
                runtimeController: appleRuntimeController
            )
        }
    }

    func refreshServiceRegistry() {
        publishRegistry()
        enabledServiceIDs = Self.normalizedEnabledServiceIDs(
            enabledServiceIDs,
            availableServices: availableServices
        )
        defaults.set(enabledServiceIDs, forKey: Self.enabledServicesDefaultsKey)
        rebuildSupportedLanguageFallback()
    }

    func refreshServiceProfiles() {
        serviceProfileTask?.cancel()
        guard let serviceProfileRepository else {
            serviceProfiles = []
            officialProfileAdapters = [:]
            serviceProfileErrorMessage = nil
            isLoadingServiceProfiles = false
            refreshServiceRegistry()
            return
        }
        let credentialStore = serviceCredentialStore
        let serviceProfileRefreshLoader = self.serviceProfileRefreshLoader
        isLoadingServiceProfiles = true
        serviceProfileTask = Task { [weak self] in
            do {
                let batch: TranslationOfficialServiceProfileBatch
                if let serviceProfileRefreshLoader {
                    batch = try await serviceProfileRefreshLoader()
                } else {
                    batch = try await Task.detached(
                        priority: .utility
                    ) {
                        let loadResult = try serviceProfileRepository
                            .listRecoveringInvalidRows()
                        let profiles = loadResult.profiles
                        return TranslationOfficialServiceProfileBatch(
                            profiles: profiles,
                            preparations:
                                TranslationOfficialServiceProfilePreparer
                                .prepare(
                                    profiles: profiles,
                                    credentialStore: credentialStore
                                ),
                            loadIssues: loadResult.issues
                        )
                    }.value
                }
                try Task.checkCancellation()
                guard let self else { return }
                let profiles = batch.profiles
                let previousProfilesByID = Dictionary(
                    uniqueKeysWithValues: self.serviceProfiles.map {
                        ($0.id, $0)
                    }
                )
                let refreshedProfileIDs = Set(profiles.map(\.id))
                for profileID in previousProfilesByID.keys
                    where !refreshedProfileIDs.contains(profileID) {
                    self.serviceProfileValidationGates
                        .removeValue(forKey: profileID)?
                        .invalidate(profileID: profileID)
                    self.officialServiceExecutionGate.deactivate(
                        profileID: profileID
                    )
                }
                serviceProfiles = profiles
                let persistedValidatedProfileIDs = Self
                    .validatedProfileIDs(
                        profiles: profiles,
                        defaults: defaults
                    )
                let validatedProfileIDs = Set(
                    profiles.compactMap { profile -> String? in
                        guard persistedValidatedProfileIDs
                            .contains(profile.id) else {
                            return nil
                        }
                        if profile.templateID == .libreTranslate,
                           Self.cachedLibreCapabilities(
                               for: profile,
                               defaults: self.defaults
                           ) == nil {
                            return nil
                        }
                        return profile.id
                    }
                )
                validatedServiceProfileIDs = validatedProfileIDs
                officialProfileAdapters = Dictionary(
                    uniqueKeysWithValues: batch.preparations.compactMap {
                        preparation -> (
                            String,
                            any TranslationServiceAdapter
                        )? in
                        guard !self.mutatingServiceProfileIDs.contains(
                            preparation.profile.id
                        ) else {
                            return nil
                        }
                        if let previousProfile = previousProfilesByID[
                            preparation.profile.id
                        ], previousProfile != preparation.profile {
                            // A refresh that observes a persisted profile
                            // replacement must revoke both the display adapter
                            // and any explicit connection validation before a
                            // new token can be admitted.
                            self.serviceProfileValidationGates
                                .removeValue(forKey: preparation.profile.id)?
                                .invalidate(
                                    profileID: preparation.profile.id
                                )
                            self.officialServiceExecutionGate.invalidate(
                                profileID: preparation.profile.id
                            )
                        }
                        let shouldActivate = self.enabledServiceIDs.contains(
                            preparation.profile.serviceID
                        ) && TranslationOfficialServiceAdapter.isRunnable(
                            profile: preparation.profile,
                            credentialState: preparation.credentialState
                        )
                        if shouldActivate {
                            guard self.officialServiceExecutionGate.activate(
                                profileID: preparation.profile.id
                            ) else {
                                return nil
                            }
                        } else {
                            // A registry adapter may still describe this
                            // profile for Settings, but it must never retain
                            // admission while the service is disabled.
                            self.officialServiceExecutionGate.deactivate(
                                profileID: preparation.profile.id
                            )
                        }
                        let adapter = self.makeOfficialProfileAdapter(
                            profile: preparation.profile,
                            credentialState: preparation.credentialState,
                            libreCapabilities:
                                Self.cachedLibreCapabilities(
                                    for: preparation.profile,
                                    defaults: self.defaults
                                )
                        )
                        return (
                            preparation.profile.serviceID,
                            adapter as any TranslationServiceAdapter
                        )
                    }
                )
                let runnableProfileServiceIDs = Set(
                    profiles.compactMap { profile -> String? in
                        guard self.officialProfileAdapters[
                                profile.serviceID
                              ]?.descriptor.availability == .available else {
                            return nil
                        }
                        return profile.serviceID
                    }
                )
                let availableProfileIDs = Set(
                    profiles.map(\.serviceID)
                )
                enabledServiceIDs.removeAll {
                    $0.hasPrefix("profile:")
                        && (
                            !availableProfileIDs.contains($0)
                                || !runnableProfileServiceIDs.contains($0)
                        )
                }
                defaults.set(
                    enabledServiceIDs,
                    forKey: Self.enabledServicesDefaultsKey
                )
                isLoadingServiceProfiles = false
                let credentialErrors = batch.preparations.compactMap {
                    preparation -> String? in
                    guard let message =
                        preparation.credentialState.errorMessage else {
                        return nil
                    }
                    return "\(preparation.profile.displayName): \(message)"
                }
                let profileErrors = batch.loadIssues.map {
                    "\($0.profileID): \($0.message)"
                } + credentialErrors
                serviceProfileErrorMessage = profileErrors.isEmpty
                    ? nil
                    : String(profileErrors.joined(separator: "\n").prefix(512))
                refreshServiceRegistry()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoadingServiceProfiles = false
                serviceProfileErrorMessage = String(
                    error.localizedDescription.prefix(512)
                )
                // Preserve the last known-good registry and enabled ordering
                // when SQLite itself is temporarily unavailable. Replacing a
                // read failure with an empty snapshot would turn a transient
                // storage problem into persistent user-configuration loss.
            }
        }
    }

    @discardableResult
    func saveServiceProfile(
        _ profile: TranslationServiceProfile,
        credentials: [String: String],
        credentialFieldIDsToDelete: Set<String> = []
    ) async throws -> TranslationServiceProfile {
        guard let serviceProfileRepository else {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_profile_storage_unavailable",
                message: L10n.string("translation.error.generic")
            )
        }
        let credentialStore = serviceCredentialStore
        let template = profile.templateID
        let normalizedCredentials = credentials.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let credentialFieldIDs = Set(
            TranslationServiceTemplateCatalog.credentialFieldIDs(
                for: template
            )
        )
        let requiredCredentialFieldIDs = Set(
            TranslationServiceTemplateCatalog.credentialFieldIDs(
                for: template,
                requiredOnly: true
            )
        )
        guard Set(normalizedCredentials.keys).isSubset(
            of: credentialFieldIDs
        ),
        credentialFieldIDsToDelete.isSubset(of: credentialFieldIDs),
        credentialFieldIDsToDelete
            .isDisjoint(with: requiredCredentialFieldIDs),
        credentialFieldIDsToDelete.isDisjoint(
            with: Set(
                normalizedCredentials.compactMap {
                    $0.value.isEmpty ? nil : $0.key
                }
            )
        ) else {
            throw TranslationOfficialAdapterError
                .missingConfiguration("credential")
        }
        let credentialFieldIDsToSave = Set(
            normalizedCredentials.compactMap {
                $0.value.isEmpty ? nil : $0.key
            }
        )
        let mutatedCredentialFieldIDs = credentialFieldIDsToSave
            .union(credentialFieldIDsToDelete)
        let mutationSnapshot = try beginServiceProfileMutation(
            profileID: profile.id,
            serviceID: profile.serviceID
        )

        do {
            let mutationTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let previousProfile: TranslationServiceProfile?
                do {
                    previousProfile = try serviceProfileRepository.profile(
                        id: profile.id
                    )
                } catch TranslationServiceProfileRepositoryError
                    .profileNotFound(_) {
                    previousProfile = nil
                }
                var previousCredentials: [String: String?] = [:]
                for fieldID in mutatedCredentialFieldIDs.sorted() {
                    try Task.checkCancellation()
                    previousCredentials.updateValue(
                        try credentialStore.value(
                            profileID: profile.id,
                            fieldID: fieldID
                        ),
                        forKey: fieldID
                    )
                }
                try Task.checkCancellation()
                let savedProfile = try serviceProfileRepository.save(profile)
                do {
                    try Task.checkCancellation()
                    for fieldID in mutatedCredentialFieldIDs.sorted() {
                        try Task.checkCancellation()
                        if credentialFieldIDsToDelete.contains(fieldID) {
                            try credentialStore.delete(
                                profileID: profile.id,
                                fieldID: fieldID
                            )
                        } else if let value = normalizedCredentials[fieldID] {
                            try credentialStore.save(
                                value,
                                profileID: profile.id,
                                fieldID: fieldID
                            )
                        }
                    }
                    try Task.checkCancellation()
                    return savedProfile
                } catch {
                    var rollbackSucceeded = true
                    for (fieldID, previousValue) in previousCredentials {
                        do {
                            if let previousValue {
                                try credentialStore.save(
                                    previousValue,
                                    profileID: profile.id,
                                    fieldID: fieldID
                                )
                            } else {
                                try credentialStore.delete(
                                    profileID: profile.id,
                                    fieldID: fieldID
                                )
                            }
                        } catch {
                            rollbackSucceeded = false
                        }
                    }
                    do {
                        if let previousProfile {
                            _ = try serviceProfileRepository.save(
                                previousProfile,
                                now: previousProfile.updatedAt
                            )
                        } else {
                            try serviceProfileRepository.delete(
                                id: profile.id
                            )
                        }
                    } catch {
                        rollbackSucceeded = false
                    }
                    guard rollbackSucceeded else {
                        throw TranslationServiceProfileMutationError
                            .rollbackFailed
                    }
                    throw error
                }
            }
            let saved = try await withTaskCancellationHandler {
                try await mutationTask.value
            } onCancel: {
                mutationTask.cancel()
            }
            endServiceProfileMutation(
                profileID: profile.id,
                generation: mutationSnapshot.generation
            )
            removeCachedLibreCapabilities(profileID: profile.id)
            installSavedServiceProfile(saved)
            refreshServiceProfiles()
            return saved
        } catch {
            if !Self.isRollbackFailure(error) {
                restoreServiceProfileMutation(mutationSnapshot)
            }
            endServiceProfileMutation(
                profileID: profile.id,
                generation: mutationSnapshot.generation
            )
            refreshServiceProfiles()
            throw error
        }
    }

    func configuredCredentialFieldIDs(
        for profile: TranslationServiceProfile
    ) async throws -> Set<String> {
        let credentialStore = serviceCredentialStore
        let fieldIDs = TranslationServiceTemplateCatalog
            .credentialFieldIDs(for: profile.templateID)
        return try await Task.detached(priority: .utility) {
            var configured: Set<String> = []
            for fieldID in fieldIDs {
                if try credentialStore.contains(
                    profileID: profile.id,
                    fieldID: fieldID
                ) {
                    configured.insert(fieldID)
                }
            }
            return configured
        }.value
    }

    func deleteServiceProfile(id: String) async throws {
        guard let serviceProfileRepository else {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_profile_storage_unavailable",
                message: L10n.string("translation.error.generic")
            )
        }
        let profile = try await Task.detached(priority: .userInitiated) {
            try serviceProfileRepository.profile(id: id)
        }.value
        let mutationSnapshot = try beginServiceProfileMutation(
            profileID: profile.id,
            serviceID: profile.serviceID
        )
        let credentialStore = serviceCredentialStore
        do {
            try await Task.detached(priority: .userInitiated) {
                let credentialIDs = TranslationServiceTemplateCatalog
                    .credentialFieldIDs(for: profile.templateID)
                var previousCredentials: [String: String] = [:]
                for fieldID in credentialIDs {
                    if let value = try credentialStore.value(
                        profileID: id,
                        fieldID: fieldID
                    ) {
                        previousCredentials[fieldID] = value
                    }
                }
                do {
                    for fieldID in credentialIDs {
                        try credentialStore.delete(
                            profileID: id,
                            fieldID: fieldID
                        )
                    }
                    try serviceProfileRepository.delete(id: id)
                } catch {
                    var rollbackSucceeded = true
                    for (fieldID, value) in previousCredentials {
                        do {
                            try credentialStore.save(
                                value,
                                profileID: id,
                                fieldID: fieldID
                            )
                        } catch {
                            rollbackSucceeded = false
                        }
                    }
                    guard rollbackSucceeded else {
                        throw TranslationServiceProfileMutationError
                            .rollbackFailed
                    }
                    throw error
                }
            }.value
            endServiceProfileMutation(
                profileID: profile.id,
                generation: mutationSnapshot.generation
            )
            removeCachedLibreCapabilities(profileID: profile.id)
            refreshServiceProfiles()
        } catch {
            if !Self.isRollbackFailure(error) {
                restoreServiceProfileMutation(mutationSnapshot)
            }
            endServiceProfileMutation(
                profileID: profile.id,
                generation: mutationSnapshot.generation
            )
            refreshServiceProfiles()
            throw error
        }
    }

    func connectionTest(
        profile: TranslationServiceProfile
    ) async throws -> String {
        guard !mutatingServiceProfileIDs.contains(profile.id) else {
            throw TranslationServiceProfileMutationError
                .mutationInProgress
        }
        let expectedMutationGeneration =
            serviceProfileMutationGenerations[profile.id, default: 0]
        let credentialStore = serviceCredentialStore
        let credentialState = await Task.detached(priority: .utility) {
            TranslationOfficialServiceProfilePreparer.credentialState(
                for: profile,
                credentialStore: credentialStore
            )
        }.value
        try Task.checkCancellation()
        guard !mutatingServiceProfileIDs.contains(profile.id),
              serviceProfileMutationGenerations[
                profile.id,
                default: 0
              ] == expectedMutationGeneration else {
            throw TranslationServiceProfileMutationError
                .configurationChangedDuringValidation
        }
        let globallyAdmitted = enabledServiceIDs.contains(profile.serviceID)
            && TranslationOfficialServiceAdapter.isRunnable(
                profile: profile,
                credentialState: credentialState
            )
        if !globallyAdmitted {
            officialServiceExecutionGate.deactivate(profileID: profile.id)
        }
        // Validation is an explicit one-shot action, not a registry
        // admission. Its gate remains isolated so a disabled profile cannot
        // borrow or reopen the global execution generation. The captured
        // token is also the mutation revocation boundary for both transport
        // admission and result publication.
        let validationExecutionGate = validationExecutionGate(
            for: profile.id
        )
        let validationExecutionToken = validationExecutionGate.token(
            for: profile.id
        )
        let adapter = makeOfficialProfileAdapter(
            profile: profile,
            credentialState: credentialState,
            libreCapabilities: nil,
            executionGate: validationExecutionGate,
            executionToken: validationExecutionToken
        )
        let discoveredLibreCapabilities:
            LibreTranslateCapabilitySnapshot?
        let translatedText: String
        if profile.templateID == .libreTranslate {
            let snapshot =
                try await adapter.discoverLibreCapabilities()
            discoveredLibreCapabilities = snapshot
            translatedText = try await adapter
                .validateLibreCapabilities(snapshot)
        } else {
            discoveredLibreCapabilities = nil
            let request = TranslationServiceRequest(
                sessionID: "connection-test",
                input: TranslationInput(
                    source: .manual,
                    text: "Hello"
                ),
                direction: TranslationLanguageDirection(
                    source: TranslationLanguageTag("en"),
                    target: TranslationLanguageTag("zh-Hans")!
                )
            )
            var completedText: String?
            for try await event in adapter.translate(request) {
                if case let .completed(text, _, _) = event {
                    completedText = text
                }
            }
            guard let completedText else {
                throw TranslationOfficialAdapterError.invalidResponse
            }
            translatedText = completedText
        }
        guard let serviceProfileRepository else {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_profile_storage_unavailable",
                message: L10n.string("translation.error.generic")
            )
        }
        let currentProfile = try await Task.detached(
            priority: .userInitiated
        ) {
            try serviceProfileRepository.profile(id: profile.id)
        }.value
        guard !mutatingServiceProfileIDs.contains(profile.id),
              serviceProfileMutationGenerations[
                profile.id,
                default: 0
              ] == expectedMutationGeneration,
              currentProfile == profile else {
            throw TranslationServiceProfileMutationError
                .configurationChangedDuringValidation
        }
        if let discoveredLibreCapabilities {
            try cacheLibreCapabilities(
                discoveredLibreCapabilities,
                for: profile
            )
            officialProfileAdapters[profile.serviceID] =
                makeOfficialProfileAdapter(
                    profile: profile,
                    credentialState: credentialState,
                    libreCapabilities: discoveredLibreCapabilities,
                )
        }
        markServiceProfileValidated(profile)
        refreshServiceRegistry()
        return translatedText
    }

    func testCommunityService(
        serviceID: String,
        testText: String? = nil
    ) async throws {
        guard let descriptor = availableServices.first(where: {
            $0.id == serviceID
        }),
        descriptor.kind == .communityWeb,
        let adapter = serviceRegistry.adapter(serviceID: serviceID)
        else {
            throw TranslationServiceAdapterError.unavailable(
                code: "community_service_unavailable",
                message: L10n.string(
                    "translation.community.error.invalidRequest"
                )
            )
        }

        let request = TranslationServiceRequest(
            sessionID: "community-connection-test",
            input: TranslationInput(
                source: .manual,
                text: testText.flatMap { value in
                    value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty ? nil : value
                } ?? "Hello"
            ),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            )
        )
        var completedText: String?
        for try await event in adapter.translate(request) {
            if case let .completed(text, _, _) = event {
                completedText = text
            }
        }
        guard completedText?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false else {
            throw TranslationCommunityWebError.invalidResponse
        }
    }

    func replacePluginAdapters(
        _ adapters: [any TranslationServiceAdapter],
        snapshotIsAuthoritative: Bool = false
    ) {
        pluginAdapters = Dictionary(
            uniqueKeysWithValues: adapters.map { ($0.descriptor.id, $0) }
        )
        if snapshotIsAuthoritative {
            let installedPluginServiceIDs = Set(pluginAdapters.keys)
            enabledServiceIDs.removeAll {
                $0.hasPrefix("plugin:")
                    && !installedPluginServiceIDs.contains($0)
            }
            defaults.set(
                enabledServiceIDs,
                forKey: Self.enabledServicesDefaultsKey
            )
        }
        refreshServiceRegistry()
    }

    func removePluginService(pluginID: String) {
        let serviceID = pluginID.hasPrefix("plugin:")
            ? pluginID
            : "plugin:\(pluginID)"
        guard enabledServiceIDs.contains(serviceID) else { return }
        enabledServiceIDs.removeAll { $0 == serviceID }
        defaults.set(
            enabledServiceIDs,
            forKey: Self.enabledServicesDefaultsKey
        )
        rebuildSupportedLanguageFallback()
    }

    func setServiceEnabled(_ enabled: Bool, serviceID: String) {
        if serviceID.hasPrefix("profile:") {
            setOfficialProfileServiceEnabled(
                enabled,
                serviceID: serviceID
            )
            return
        }
        guard let descriptor = availableServices.first(where: {
            $0.id == serviceID
        }) else {
            return
        }
        var next = enabledServiceIDs.filter { $0 != serviceID }
        if enabled {
            guard descriptor.availability == .available else {
                return
            }
            guard next.count < 4 else { return }
            next.append(serviceID)
        }
        guard next != enabledServiceIDs else { return }
        enabledServiceIDs = next
        defaults.set(next, forKey: Self.enabledServicesDefaultsKey)
        rebuildSupportedLanguageFallback()
    }

    private func setOfficialProfileServiceEnabled(
        _ enabled: Bool,
        serviceID: String
    ) {
        guard let profile = serviceProfiles.first(where: {
            $0.serviceID == serviceID
        }) else {
            let profileID = String(serviceID.dropFirst("profile:".count))
            officialServiceExecutionGate.invalidate(profileID: profileID)
            officialProfileAdapters[serviceID] = nil
            let disabledServiceIDs = enabledServiceIDs.filter {
                $0 != serviceID
            }
            if disabledServiceIDs != enabledServiceIDs {
                enabledServiceIDs = disabledServiceIDs
                defaults.set(
                    disabledServiceIDs,
                    forKey: Self.enabledServicesDefaultsKey
                )
            }
            refreshServiceRegistry()
            return
        }

        var next = enabledServiceIDs.filter { $0 != serviceID }
        guard enabled else {
            // This must happen before the persisted disabled state or registry
            // can expose the retained adapter again.
            officialServiceExecutionGate.invalidate(profileID: profile.id)
            if next != enabledServiceIDs {
                enabledServiceIDs = next
                defaults.set(next, forKey: Self.enabledServicesDefaultsKey)
            }
            refreshServiceRegistry()
            return
        }

        guard !enabledServiceIDs.contains(serviceID) else {
            return
        }
        let currentPreparation = officialProfilePreparation(for: profile)
        guard next.count < 4,
              let preparation = currentPreparation,
              TranslationOfficialServiceAdapter.isRunnable(
                  profile: preparation.profile,
                  credentialState: preparation.credentialState
              ) else {
            // An attempted enable without a runnable current profile is also
            // fail-closed: old adapters/tokens stay unusable.
            officialServiceExecutionGate.invalidate(profileID: profile.id)
            if let preparation = currentPreparation {
                officialProfileAdapters[serviceID] =
                    makeOfficialProfileAdapter(
                        profile: preparation.profile,
                        credentialState: preparation.credentialState,
                        libreCapabilities: Self.cachedLibreCapabilities(
                            for: preparation.profile,
                            defaults: defaults
                        )
                    )
            } else {
                officialProfileAdapters[serviceID] = nil
            }
            refreshServiceRegistry()
            return
        }

        // Even if a refresh created a display-only adapter while the service
        // was disabled, this revokes that token before a fresh adapter exists.
        officialServiceExecutionGate.invalidate(profileID: profile.id)
        guard officialServiceExecutionGate.activate(profileID: profile.id)
        else {
            officialProfileAdapters[serviceID] =
                makeOfficialProfileAdapter(
                    profile: preparation.profile,
                    credentialState: preparation.credentialState,
                    libreCapabilities: Self.cachedLibreCapabilities(
                        for: preparation.profile,
                        defaults: defaults
                    )
                )
            refreshServiceRegistry()
            return
        }

        let adapter = makeOfficialProfileAdapter(
            profile: preparation.profile,
            credentialState: preparation.credentialState,
            libreCapabilities: Self.cachedLibreCapabilities(
                for: preparation.profile,
                defaults: defaults
            )
        )
        guard adapter.descriptor.availability == .available else {
            officialServiceExecutionGate.invalidate(profileID: profile.id)
            officialProfileAdapters[serviceID] = adapter
            refreshServiceRegistry()
            return
        }
        officialProfileAdapters[serviceID] = adapter
        next.append(serviceID)
        enabledServiceIDs = next
        defaults.set(next, forKey: Self.enabledServicesDefaultsKey)
        refreshServiceRegistry()
    }

    func moveEnabledService(serviceID: String, before destinationServiceID: String?) {
        guard let sourceIndex = enabledServiceIDs.firstIndex(of: serviceID) else {
            return
        }
        var next = enabledServiceIDs
        next.remove(at: sourceIndex)
        if let destinationServiceID,
           let destinationIndex = next.firstIndex(of: destinationServiceID) {
            next.insert(serviceID, at: destinationIndex)
        } else {
            next.append(serviceID)
        }
        guard next != enabledServiceIDs else { return }
        enabledServiceIDs = next
        defaults.set(next, forKey: Self.enabledServicesDefaultsKey)
    }

    @discardableResult
    func setEnabledServiceOrder(_ orderedServiceIDs: [String]) -> Bool {
        guard orderedServiceIDs.count <= 4,
              Set(orderedServiceIDs).count == orderedServiceIDs.count,
              Set(orderedServiceIDs) == Set(enabledServiceIDs) else {
            return false
        }
        guard orderedServiceIDs != enabledServiceIDs else { return true }
        enabledServiceIDs = orderedServiceIDs
        defaults.set(
            orderedServiceIDs,
            forKey: Self.enabledServicesDefaultsKey
        )
        return true
    }

    /// Publishes a synchronous, deterministic capability fallback immediately.
    /// Apple system language discovery is deliberately deferred until a UI
    /// consumer calls `ensureSupportedLanguagesRefreshed()`.
    private func rebuildSupportedLanguageFallback() {
        languageRefreshTask?.cancel()
        languageRefreshTask = nil
        supportedLanguageGeneration &+= 1
        refreshedAppleLanguageGeneration = nil
        let enabledDescriptors = enabledServices
        let explicitlySupported = enabledDescriptors.flatMap(
            \.supportedTargetLanguages
        )
        let explicitlySupportedSources = enabledDescriptors.flatMap(
            \.supportedSourceLanguages
        )
        let hasUnrestrictedExternalService = enabledDescriptors.contains {
            $0.kind != .appleLocal && $0.supportedTargetLanguages.isEmpty
        }
        let hasUnrestrictedExternalSource = enabledDescriptors.contains {
            $0.kind != .appleLocal && $0.supportedSourceLanguages.isEmpty
        }
        let includesAppleLocal = enabledDescriptors.contains {
            $0.kind == .appleLocal
        }
        var baseLanguages = explicitlySupported
        if includesAppleLocal || hasUnrestrictedExternalService {
            baseLanguages.append(contentsOf: TranslationLanguagePreferences.commonOptions)
        }
        var baseSourceLanguages = explicitlySupportedSources
        if includesAppleLocal || hasUnrestrictedExternalSource {
            baseSourceLanguages.append(
                contentsOf: TranslationLanguagePreferences.commonOptions
            )
        }
        supportedLanguages = TranslationLanguagePreferences.sortedOptions(
            baseLanguages
        )
        supportedSourceLanguages = TranslationLanguagePreferences.sortedOptions(
            baseSourceLanguages
        )
        ensureSupportedLanguagesRefreshed()
    }

    /// Registers an actual language-list consumer. Re-registering the same
    /// token is intentionally a no-op so independent panels cannot release
    /// each other's demand.
    func beginSupportedLanguagesConsumer(token: UUID) {
        guard supportedLanguageConsumerTokens.insert(token).inserted else {
            return
        }
        ensureSupportedLanguagesRefreshed()
    }

    /// Releases a language-list consumer and invalidates any in-flight result
    /// when the last consumer leaves.
    func endSupportedLanguagesConsumer(token: UUID) {
        guard supportedLanguageConsumerTokens.remove(token) != nil,
              supportedLanguageConsumerTokens.isEmpty else {
            return
        }
        languageRefreshTask?.cancel()
        languageRefreshTask = nil
        supportedLanguageGeneration &+= 1
        refreshedAppleLanguageGeneration = nil
    }

    /// Starts Apple language discovery only while an actual language-list
    /// consumer is registered. A generation can own at most one provider
    /// request.
    func ensureSupportedLanguagesRefreshed() {
        let generation = supportedLanguageGeneration
        guard !supportedLanguageConsumerTokens.isEmpty,
              enabledServices.contains(where: { $0.kind == .appleLocal }),
              refreshedAppleLanguageGeneration != generation,
              languageRefreshTask == nil else {
            return
        }
        let fallbackTargets = supportedLanguages
        let fallbackSources = supportedSourceLanguages
        let provider = appleSupportedLanguagesProvider
        languageRefreshTask = Task { [weak self] in
            let appleLanguages = await provider()
            guard !Task.isCancelled,
                  let self,
                  self.supportedLanguageGeneration == generation,
                  self.enabledServices.contains(where: {
                      $0.kind == .appleLocal
                  }) else {
                return
            }
            self.supportedLanguages = TranslationLanguagePreferences.sortedOptions(
                fallbackTargets + appleLanguages
            )
            self.supportedSourceLanguages =
                TranslationLanguagePreferences.sortedOptions(
                    fallbackSources + appleLanguages
                )
            self.refreshedAppleLanguageGeneration = generation
            self.languageRefreshTask = nil
        }
    }

    @discardableResult
    func saveFavorite(
        session: TranslationSessionSnapshot
    ) async throws -> TranslationFavorite {
        guard let favoriteWorker else {
            throw TranslationServiceAdapterError.unavailable(
                code: "translation_favorites_unavailable",
                message: L10n.string("translation.favorite.unavailable")
            )
        }
        let favorite = try await favoriteWorker.save(session: session)
        refreshFavorites(query: favoriteQuery)
        return favorite
    }

    func refreshFavorites(query: String = "") {
        guard let favoriteWorker else {
            favoriteSummaries = []
            favoriteTotalCount = 0
            favoriteErrorMessage = L10n.string("translation.favorite.unavailable")
            isLoadingFavorites = false
            isLoadingMoreFavorites = false
            favoriteHasMore = false
            return
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        favoriteQuery = normalizedQuery
        favoriteListTask?.cancel()
        isLoadingFavorites = true
        isLoadingMoreFavorites = false
        favoriteListTask = Task { [weak self] in
            do {
                let summaries = try await favoriteWorker.loadSummaries(
                    query: normalizedQuery,
                    limit: Self.favoritePageSize + 1
                )
                let totalCount = try await favoriteWorker.count()
                try Task.checkCancellation()
                guard let self, favoriteQuery == normalizedQuery else {
                    return
                }
                isLoadingFavorites = false
                favoriteHasMore = summaries.count > Self.favoritePageSize
                favoriteSummaries = Array(
                    summaries.prefix(Self.favoritePageSize)
                )
                favoriteTotalCount = totalCount
                favoriteErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                Self.favoriteLogger.error(
                    "Favorite list load failed: \(String(describing: error), privacy: .private)"
                )
                isLoadingFavorites = false
                isLoadingMoreFavorites = false
                favoriteHasMore = false
                favoriteSummaries = []
                favoriteTotalCount = 0
                favoriteErrorMessage =
                    TranslationFavoriteErrorPresentation.userMessage
            }
        }
    }

    func loadMoreFavorites() {
        guard favoriteHasMore,
              !isLoadingFavorites,
              !isLoadingMoreFavorites,
              let favoriteWorker else {
            return
        }
        let query = favoriteQuery
        let offset = favoriteSummaries.count
        favoriteListTask?.cancel()
        isLoadingMoreFavorites = true
        favoriteListTask = Task { [weak self] in
            do {
                let summaries = try await favoriteWorker.loadSummaries(
                    query: query,
                    limit: Self.favoritePageSize + 1,
                    offset: offset
                )
                try Task.checkCancellation()
                guard let self,
                      favoriteQuery == query,
                      favoriteSummaries.count == offset else {
                    return
                }
                let page = summaries.prefix(Self.favoritePageSize)
                let existingIDs = Set(favoriteSummaries.map(\.id))
                favoriteSummaries.append(
                    contentsOf: page.filter {
                        !existingIDs.contains($0.id)
                    }
                )
                favoriteHasMore = summaries.count > Self.favoritePageSize
                isLoadingMoreFavorites = false
                favoriteErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                Self.favoriteLogger.error(
                    "Favorite page load failed: \(String(describing: error), privacy: .private)"
                )
                isLoadingMoreFavorites = false
                favoriteErrorMessage =
                    TranslationFavoriteErrorPresentation.userMessage
            }
        }
    }

    func loadFavorite(id: String) {
        guard let favoriteWorker else {
            selectedFavorite = nil
            isLoadingFavoriteDetail = false
            return
        }
        favoriteDetailTask?.cancel()
        isLoadingFavoriteDetail = true
        favoriteDetailTask = Task { [weak self] in
            do {
                let favorite = try await favoriteWorker.load(id: id)
                try Task.checkCancellation()
                guard let self else { return }
                isLoadingFavoriteDetail = false
                guard favorite?.id == id else {
                    selectedFavorite = nil
                    favoriteErrorMessage = L10n.string(
                        "translation.favorite.unavailable"
                    )
                    return
                }
                selectedFavorite = favorite
                favoriteErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                Self.favoriteLogger.error(
                    "Favorite detail load failed: \(String(describing: error), privacy: .private)"
                )
                isLoadingFavoriteDetail = false
                selectedFavorite = nil
                favoriteErrorMessage =
                    TranslationFavoriteErrorPresentation.userMessage
            }
        }
    }

    @discardableResult
    func deleteFavorite(id: String) async -> Bool {
        guard let favoriteWorker else { return false }
        do {
            let deleted = try await favoriteWorker.delete(id: id)
            if selectedFavorite?.id == id {
                selectedFavorite = nil
            }
            refreshFavorites(query: favoriteQuery)
            return deleted
        } catch {
            Self.favoriteLogger.error(
                "Favorite delete failed: \(String(describing: error), privacy: .private)"
            )
            favoriteErrorMessage =
                TranslationFavoriteErrorPresentation.userMessage
            return false
        }
    }

    func exportFavoritesJSON() async throws -> Data {
        guard let favoriteWorker else { return Data("[]".utf8) }
        return try await favoriteWorker.exportJSON()
    }

    func exportFavoritesMarkdown() async throws -> Data {
        guard let favoriteWorker else { return Data() }
        return try await favoriteWorker.exportMarkdown()
    }

    private func publishRegistry() {
        let concreteAdapters =
            builtInAdapters
            + officialProfileAdapters.values.sorted {
                $0.descriptor.id < $1.descriptor.id
            }
            + pluginAdapters.values.sorted {
                $0.descriptor.id < $1.descriptor.id
            }
            + communityWebAdapters
        let concreteIDs = Set(concreteAdapters.map(\.descriptor.id))
        let pendingAdapters: [any TranslationServiceAdapter] =
            enabledServiceIDs.compactMap { serviceID in
                guard serviceID.hasPrefix("plugin:"),
                      !concreteIDs.contains(serviceID) else {
                    return nil
                }
                return TranslationUnavailablePersistedPluginServiceAdapter(
                    serviceID: serviceID
                ) as any TranslationServiceAdapter
            }
        serviceRegistry.replaceAdapters(concreteAdapters + pendingAdapters)
        availableServices = serviceRegistry.descriptors
    }

    private static let enabledServicesDefaultsKey = "translation.services.enabledIDs"
    private static let validatedProfilesDefaultsKey =
        "translation.services.validatedProfileRevisions"
    private static let libreCapabilitiesDefaultsKeyPrefix =
        "translation.services.libreCapabilities."

    private static func cachedLibreCapabilities(
        for profile: TranslationServiceProfile,
        defaults: UserDefaults
    ) -> LibreTranslateCapabilitySnapshot? {
        guard profile.templateID == .libreTranslate,
              let data = defaults.data(
                  forKey: libreCapabilitiesDefaultsKeyPrefix + profile.id
              ),
              data.count
                <= LibreTranslateCapabilitySnapshot.maximumEncodedBytes,
              let snapshot = try? JSONDecoder().decode(
                  LibreTranslateCapabilitySnapshot.self,
                  from: data
              ),
              let validated = try? snapshot.validated(
                  for: profile
              ) else {
            return nil
        }
        return validated
    }

    private func cacheLibreCapabilities(
        _ snapshot: LibreTranslateCapabilitySnapshot,
        for profile: TranslationServiceProfile
    ) throws {
        let validated = try snapshot.validated(for: profile)
        let data = try JSONEncoder().encode(validated)
        guard data.count
                <= LibreTranslateCapabilitySnapshot.maximumEncodedBytes else {
            throw TranslationOfficialAdapterError.responseTooLarge
        }
        defaults.set(
            data,
            forKey: Self.libreCapabilitiesDefaultsKeyPrefix + profile.id
        )
    }

    private func removeCachedLibreCapabilities(profileID: String) {
        defaults.removeObject(
            forKey: Self.libreCapabilitiesDefaultsKeyPrefix + profileID
        )
    }

    static func normalizedEnabledServiceIDs(
        _ candidate: [String]?,
        availableServices: [TranslationServiceDescriptor]
    ) -> [String] {
        let availableIDs = Set(availableServices.map(\.id))
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: availableServices.map { ($0.id, $0) }
        )
        var seen: Set<String> = []
        guard let candidate else {
            if availableServices.contains(where: {
                $0.id == "apple-local" && $0.availability == .available
            }) {
                return ["apple-local"]
            }
            return availableServices.first(where: {
                $0.availability == .available
            }).map { [$0.id] } ?? []
        }
        let normalized = candidate.filter { serviceID in
            let isAvailable = availableIDs.contains(serviceID)
            let isPendingPlugin = serviceID.hasPrefix("plugin:")
            let isPendingProfile = serviceID.hasPrefix("profile:")
            guard (isAvailable || isPendingPlugin || isPendingProfile)
                    && seen.insert(serviceID).inserted else {
                return false
            }
            if serviceID == "openai-compatible",
               descriptorsByID[serviceID]?.availability != .available {
                return false
            }
            return true
        }
        return Array(normalized.prefix(4))
    }

    private func markServiceProfileValidated(
        _ profile: TranslationServiceProfile
    ) {
        var revisions = defaults.dictionary(
            forKey: Self.validatedProfilesDefaultsKey
        ) as? [String: Double] ?? [:]
        revisions[profile.id] = profile.updatedAt.timeIntervalSince1970
        defaults.set(
            revisions,
            forKey: Self.validatedProfilesDefaultsKey
        )
        validatedServiceProfileIDs.insert(profile.id)
    }

    private func officialProfilePreparation(
        for profile: TranslationServiceProfile
    ) -> TranslationOfficialServiceProfilePreparation? {
        TranslationOfficialServiceProfilePreparer.prepare(
            profiles: [profile],
            credentialStore: serviceCredentialStore
        ).first
    }

    private func makeOfficialProfileAdapter(
        profile: TranslationServiceProfile,
        credentialState: TranslationOfficialCredentialState,
        libreCapabilities: LibreTranslateCapabilitySnapshot?
    ) -> TranslationOfficialServiceAdapter {
        makeOfficialProfileAdapter(
            profile: profile,
            credentialState: credentialState,
            libreCapabilities: libreCapabilities,
            executionGate: officialServiceExecutionGate
        )
    }

    private func makeOfficialProfileAdapter(
        profile: TranslationServiceProfile,
        credentialState: TranslationOfficialCredentialState,
        libreCapabilities: LibreTranslateCapabilitySnapshot?,
        executionGate: TranslationOfficialServiceExecutionGate,
        executionToken: TranslationOfficialServiceExecutionGate.Token? = nil
    ) -> TranslationOfficialServiceAdapter {
        TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: credentialState,
            credentialStore: serviceCredentialStore,
            transport: officialTransport,
            libreCapabilities: libreCapabilities,
            executionGate: executionGate,
            executionToken: executionToken ?? executionGate.token(for: profile.id)
        )
    }

    private func validationExecutionGate(
        for profileID: String
    ) -> TranslationOfficialServiceExecutionGate {
        if let gate = serviceProfileValidationGates[profileID] {
            return gate
        }
        let gate = TranslationOfficialServiceExecutionGate()
        serviceProfileValidationGates[profileID] = gate
        return gate
    }

    private func installSavedServiceProfile(
        _ profile: TranslationServiceProfile
    ) {
        guard let preparation = officialProfilePreparation(for: profile) else {
            return
        }
        serviceProfiles.removeAll { $0.id == profile.id }
        serviceProfiles.append(profile)
        serviceProfiles.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id < $1.id
        }
        // Saving a profile never silently enables it. Keep the freshly
        // installed Settings adapter closed until an explicit enable rebuilds
        // it with a new admitted generation.
        officialServiceExecutionGate.deactivate(profileID: profile.id)
        officialProfileAdapters[profile.serviceID] =
            makeOfficialProfileAdapter(
                profile: profile,
                credentialState: preparation.credentialState,
                libreCapabilities: Self.cachedLibreCapabilities(
                    for: profile,
                    defaults: defaults
                )
            )
        refreshServiceRegistry()
    }

    private func invalidateServiceProfileValidation(id: String) {
        var revisions = defaults.dictionary(
            forKey: Self.validatedProfilesDefaultsKey
        ) as? [String: Double] ?? [:]
        revisions[id] = nil
        defaults.set(
            revisions,
            forKey: Self.validatedProfilesDefaultsKey
        )
        validatedServiceProfileIDs.remove(id)
    }

    @discardableResult
    private func beginServiceProfileMutation(
        profileID: String,
        serviceID: String
    ) throws -> TranslationServiceProfileMutationSnapshot {
        guard mutatingServiceProfileIDs.insert(profileID).inserted else {
            throw TranslationServiceProfileMutationError
                .mutationInProgress
        }
        // Revoke validation before any profile/credential mutation begins.
        // `invalidate` advances the profile generation under the gate lock,
        // then cancels admitted operations outside it, so a stale test cannot
        // start transport or publish after this point.
        serviceProfileValidationGates.removeValue(forKey: profileID)?
            .invalidate(profileID: profileID)
        officialServiceExecutionGate.invalidate(profileID: profileID)
        serviceProfileTask?.cancel()
        let enabledServiceIDsBeforeMutation = enabledServiceIDs
        let validationRevisionsBeforeMutation = defaults.dictionary(
            forKey: Self.validatedProfilesDefaultsKey
        ) as? [String: Double] ?? [:]
        let wasValidatedBeforeMutation =
            validatedServiceProfileIDs.contains(profileID)
        let generation =
            serviceProfileMutationGenerations[profileID, default: 0]
                &+ 1
        serviceProfileMutationGenerations[profileID] = generation
        enabledServiceIDs.removeAll { $0 == serviceID }
        defaults.set(
            enabledServiceIDs,
            forKey: Self.enabledServicesDefaultsKey
        )
        invalidateServiceProfileValidation(id: profileID)
        rebuildSupportedLanguageFallback()
        return TranslationServiceProfileMutationSnapshot(
            profileID: profileID,
            serviceID: serviceID,
            generation: generation,
            enabledServiceIDs: enabledServiceIDsBeforeMutation,
            enabledServiceOrderRevision: enabledServiceOrderRevision,
            validationRevision:
                validationRevisionsBeforeMutation[profileID],
            wasValidated: wasValidatedBeforeMutation
        )
    }

    private func restoreServiceProfileMutation(
        _ snapshot: TranslationServiceProfileMutationSnapshot
    ) {
        guard serviceProfileMutationGenerations[
            snapshot.profileID,
            default: 0
        ] == snapshot.generation,
        mutatingServiceProfileIDs.contains(snapshot.profileID) else {
            return
        }
        let candidateEnabledServiceIDs: [String]
        if enabledServiceOrderRevision
            == snapshot.enabledServiceOrderRevision {
            candidateEnabledServiceIDs = snapshot.enabledServiceIDs
        } else {
            candidateEnabledServiceIDs =
                enabledServiceIDsByRestoringMutatedService(
                    from: snapshot
                )
        }
        let profile = serviceProfiles.first { $0.id == snapshot.profileID }
        let preparation = profile.flatMap {
            officialProfilePreparation(for: $0)
        }
        let shouldRestoreEnabledService = candidateEnabledServiceIDs.contains(
            snapshot.serviceID
        )
        var restoredRunnableAdapter = !shouldRestoreEnabledService
        if let profile,
           profile.serviceID == snapshot.serviceID,
           let preparation {
            if shouldRestoreEnabledService,
               TranslationOfficialServiceAdapter.isRunnable(
                   profile: preparation.profile,
                   credentialState: preparation.credentialState
               ),
               officialServiceExecutionGate.activate(profileID: profile.id) {
                officialProfileAdapters[snapshot.serviceID] =
                    makeOfficialProfileAdapter(
                        profile: preparation.profile,
                        credentialState: preparation.credentialState,
                        libreCapabilities: Self.cachedLibreCapabilities(
                            for: preparation.profile,
                            defaults: defaults
                        )
                    )
                restoredRunnableAdapter = true
            } else {
                // Keep an accurately described settings adapter, but leave its
                // gate closed until an explicit successful enable rebuilds it.
                officialProfileAdapters[snapshot.serviceID] =
                    makeOfficialProfileAdapter(
                        profile: preparation.profile,
                        credentialState: preparation.credentialState,
                        libreCapabilities: Self.cachedLibreCapabilities(
                            for: preparation.profile,
                            defaults: defaults
                        )
                    )
            }
        } else {
            officialProfileAdapters[snapshot.serviceID] = nil
            restoredRunnableAdapter = false
        }
        let restoredEnabledServiceIDs: [String]
        if restoredRunnableAdapter {
            restoredEnabledServiceIDs = candidateEnabledServiceIDs
        } else {
            restoredEnabledServiceIDs = candidateEnabledServiceIDs.filter {
                $0 != snapshot.serviceID
            }
        }
        if restoredEnabledServiceIDs != enabledServiceIDs {
            enabledServiceIDs = restoredEnabledServiceIDs
            defaults.set(
                restoredEnabledServiceIDs,
                forKey: Self.enabledServicesDefaultsKey
            )
        }
        var revisions = defaults.dictionary(
            forKey: Self.validatedProfilesDefaultsKey
        ) as? [String: Double] ?? [:]
        revisions[snapshot.profileID] = (
            restoredRunnableAdapter || !shouldRestoreEnabledService
        ) ? snapshot.validationRevision : nil
        defaults.set(
            revisions,
            forKey: Self.validatedProfilesDefaultsKey
        )
        if snapshot.wasValidated,
           restoredRunnableAdapter || !shouldRestoreEnabledService {
            validatedServiceProfileIDs.insert(snapshot.profileID)
        } else {
            validatedServiceProfileIDs.remove(snapshot.profileID)
        }
        if shouldRestoreEnabledService, !restoredRunnableAdapter {
            let errorMessage = preparation?.credentialState.errorMessage
                ?? L10n.string("translation.error.generic")
            serviceProfileErrorMessage = "\(snapshot.profileID): \(errorMessage)"
        }
        refreshServiceRegistry()
    }

    private func enabledServiceIDsByRestoringMutatedService(
        from snapshot: TranslationServiceProfileMutationSnapshot
    ) -> [String] {
        guard snapshot.enabledServiceIDs.contains(snapshot.serviceID),
              !enabledServiceIDs.contains(snapshot.serviceID),
              enabledServiceIDs.count < 4,
              let originalIndex = snapshot.enabledServiceIDs.firstIndex(
                of: snapshot.serviceID
              ) else {
            return enabledServiceIDs
        }

        var restored = enabledServiceIDs
        let successors = snapshot.enabledServiceIDs[
            snapshot.enabledServiceIDs.index(after: originalIndex)...
        ]
        if let successorIndex = successors.lazy.compactMap({
            restored.firstIndex(of: $0)
        }).first {
            restored.insert(snapshot.serviceID, at: successorIndex)
            return restored
        }

        let predecessors = snapshot.enabledServiceIDs[..<originalIndex]
            .reversed()
        if let predecessorIndex = predecessors.lazy.compactMap({
            restored.firstIndex(of: $0)
        }).first {
            restored.insert(
                snapshot.serviceID,
                at: restored.index(after: predecessorIndex)
            )
            return restored
        }

        restored.insert(
            snapshot.serviceID,
            at: min(originalIndex, restored.endIndex)
        )
        return restored
    }

    private static func isRollbackFailure(_ error: Error) -> Bool {
        guard let mutationError =
            error as? TranslationServiceProfileMutationError else {
            return false
        }
        if case .rollbackFailed = mutationError {
            return true
        }
        return false
    }

    private func endServiceProfileMutation(
        profileID: String,
        generation: UInt64
    ) {
        guard serviceProfileMutationGenerations[
            profileID,
            default: 0
        ] == generation else {
            return
        }
        mutatingServiceProfileIDs.remove(profileID)
    }

    private static func validatedProfileIDs(
        profiles: [TranslationServiceProfile],
        defaults: UserDefaults
    ) -> Set<String> {
        let revisions = defaults.dictionary(
            forKey: validatedProfilesDefaultsKey
        ) as? [String: Double] ?? [:]
        return Set(profiles.compactMap { profile in
            guard let revision = revisions[profile.id],
                  abs(
                      revision
                        - profile.updatedAt.timeIntervalSince1970
                  ) < 0.000_001 else {
                return nil
            }
            return profile.id
        })
    }
}

private struct TranslationServiceProfileMutationSnapshot {
    let profileID: String
    let serviceID: String
    let generation: UInt64
    let enabledServiceIDs: [String]
    let enabledServiceOrderRevision: UInt64
    let validationRevision: Double?
    let wasValidated: Bool
}
