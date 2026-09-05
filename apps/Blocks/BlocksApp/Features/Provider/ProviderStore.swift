import Combine
import Foundation

struct ProviderAuditToken: Equatable, Sendable {
    fileprivate let id: UUID
}

typealias ProviderAuditTokenSource = @Sendable () -> ProviderAuditToken

private final class ProviderAuditEpochSource: @unchecked Sendable {
    private let lock = NSLock()
    private var id = UUID()

    func capture() -> ProviderAuditToken {
        lock.lock()
        defer { lock.unlock() }
        return ProviderAuditToken(id: id)
    }

    func advance() {
        lock.lock()
        id = UUID()
        lock.unlock()
    }

    func matches(_ token: ProviderAuditToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.id == id
    }
}

/// Owns all Security.framework and credential-revision work on one serial queue.
/// The contained service/defaults are deliberately never exposed across queues.
private final class ProviderKeychainWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blocks.provider-keychain")
    private let service: ProviderKeychainService
    private let defaults: UserDefaults

    init(service: ProviderKeychainService, defaults: UserDefaults) {
        self.service = service
        self.defaults = defaults
    }

    func performKeychainGate(
        action: ProviderKeychainGateAction,
        alias: String
    ) async -> Result<ProviderKeychainOperationResult, Error> {
        await onWorker {
            Result {
                _ = try self.resolvePendingCredentialRecovery()
                try self.requireNoCancelledAliasMigrationRecoveryNotice()
                return try self.service.perform(action: action, alias: alias)
            }
        }
    }

    func performUserSecretGate(
        action: ProviderUserSecretAction,
        alias: String,
        secret: String?,
        replacingAlias: String?,
        authorizationIntent:
            ProviderExternalTransferAuthorizationIntent?
    ) async -> Result<(ProviderUserSecretOperationResult, UInt64?), Error> {
        await onWorker {
            Result {
                _ = try self.resolvePendingCredentialRecovery()
                let recoveryNotice = try self.cancelledAliasMigrationRecoveryNotice(
                    permitting: action,
                    alias: alias
                )
                if action == .saveOrReplace,
                   let replacingAlias,
                   ProviderSettingsPersistence.normalizedAccountAlias(
                       replacingAlias
                   ) != ProviderSettingsPersistence.normalizedAccountAlias(
                       self.defaults.string(
                           forKey: ProviderSettingsPersistence
                               .storedSecretAccountAliasKey
                       ) ?? ""
                   ) {
                    throw ProviderCredentialMutationError
                        .aliasMigrationRecoveryRequired
                }
                let mutation = try self.performPreparedUserSecretMutation(
                    action: action,
                    alias: alias,
                    secret: secret,
                    replacingAlias: replacingAlias,
                    authorizationIntent: authorizationIntent
                )
                if let recoveryNotice,
                   mutation.0.ok,
                   !ProviderSettingsPersistence
                    .settleCancelledAliasMigrationRecoveryNotice(
                        matching: recoveryNotice,
                        defaults: self.defaults
                    ) {
                    throw ProviderCredentialMutationError
                        .cancelledAliasMigrationRecoveryRequired
                }
                return mutation
            }
        }
    }

    private func performPreparedUserSecretMutation(
        action: ProviderUserSecretAction,
        alias: String,
        secret: String?,
        replacingAlias: String?,
        authorizationIntent:
            ProviderExternalTransferAuthorizationIntent?
    ) throws -> (ProviderUserSecretOperationResult, UInt64?) {
        let revision: UInt64?
        switch action {
        case .saveOrReplace, .deleteStored:
            guard let preparedRevision =
                ProviderSettingsPersistence.prepareCredentialMutation(
                    preserving: authorizationIntent,
                    defaults: defaults
                )
            else {
                throw ProviderCredentialMutationError
                    .revocationPersistenceUnavailable
            }
            revision = preparedRevision
        case .verifyStored, .verifyMissing:
            revision = nil
        }
        let aliasMigrationJournal: ProviderPendingAliasMigrationJournal?
        if action == .saveOrReplace,
           let replacingAlias,
           ProviderSettingsPersistence.normalizedAccountAlias(replacingAlias)
                != ProviderSettingsPersistence.normalizedAccountAlias(alias) {
            guard let preparedRevision = revision else {
                throw ProviderCredentialMutationError
                    .revocationPersistenceUnavailable
            }
            guard !ProviderSettingsPersistence.normalizedAccountAlias(alias).isEmpty,
                  !ProviderSettingsPersistence.normalizedAccountAlias(replacingAlias).isEmpty,
                  !(secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let pending = ProviderSettingsPersistence.beginPendingAliasMigration(
                      sourceAlias: replacingAlias,
                      destinationAlias: alias,
                      credentialRevision: preparedRevision,
                      preserving: authorizationIntent,
                      defaults: defaults
                  ) else {
                if !ProviderSettingsPersistence
                    .isCredentialMutationAuthorizationCurrent(
                        authorizationIntent,
                        credentialRevision: preparedRevision,
                        defaults: defaults
                    ) {
                    throw ProviderCredentialMutationError
                        .aliasMigrationRecoveryRequired
                }
                throw ProviderCredentialMutationError.aliasMigrationPersistenceUnavailable
            }
            aliasMigrationJournal = pending
        } else {
            aliasMigrationJournal = nil
        }
        let credentialMutationJournal: ProviderPendingCredentialMutationJournal?
        if aliasMigrationJournal == nil,
           let revision,
           let kind = (action == .saveOrReplace
               ? ProviderPendingCredentialMutationKind.save
               : action == .deleteStored
               ? ProviderPendingCredentialMutationKind.delete
               : nil) {
            guard let pending = ProviderSettingsPersistence
                .beginPendingCredentialMutation(
                    kind: kind,
                    alias: alias,
                    credentialRevision: revision,
                    preserving: authorizationIntent,
                    defaults: defaults
                ) else {
                if !ProviderSettingsPersistence
                    .isCredentialMutationAuthorizationCurrent(
                        authorizationIntent,
                        credentialRevision: revision,
                        defaults: defaults
                    ) {
                    throw ProviderCredentialMutationError
                        .credentialMutationRecoveryRequired
                }
                throw ProviderCredentialMutationError.credentialMutationPersistenceUnavailable
            }
            credentialMutationJournal = pending
        } else {
            credentialMutationJournal = nil
        }
        if let revision,
           !ProviderSettingsPersistence.isCredentialMutationAuthorizationCurrent(
               authorizationIntent,
               credentialRevision: revision,
               defaults: defaults
           ) {
            throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
        }
        let result = try service.performUserSecret(
            action: action,
            alias: alias,
            secret: secret,
            replacingAlias: replacingAlias,
            credentialRevision: revision
        )
        if let journal = aliasMigrationJournal {
            guard result.ok else {
                let recoveryState = service.aliasMigrationRecoveryState(for: journal)
                guard recoveryState == .notCommitted
                    || recoveryState == .destinationConflict,
                      ProviderSettingsPersistence
                        .abandonPendingAliasMigrationAsMissingSecret(
                            matching: journal,
                            preserving: authorizationIntent,
                            defaults: defaults
                        ) else {
                    throw ProviderCredentialMutationError.aliasMigrationRecoveryRequired
                }
                return (result, revision)
            }
            guard ProviderSettingsPersistence.completePendingAliasMigration(
                journal,
                preserving: authorizationIntent,
                defaults: defaults
            ) else {
                throw ProviderCredentialMutationError.aliasMigrationRecoveryRequired
            }
        } else if let journal = credentialMutationJournal {
            switch service.credentialMutationRecoveryState(for: journal) {
            case .committed:
                guard ProviderSettingsPersistence.completePendingCredentialMutation(
                    journal,
                    preserving: authorizationIntent,
                    defaults: defaults
                ) else {
                    throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
                }
            case .notCommitted:
                guard ProviderSettingsPersistence
                    .abandonPendingCredentialMutationAsMissingSecret(
                        matching: journal,
                        preserving: authorizationIntent,
                        defaults: defaults
                    ) else {
                    throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
                }
            case .inconsistent:
                throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
            }
        }
        return (result, revision)
    }

    func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error> {
        await onWorker {
            Result {
                _ = try self.resolvePendingCredentialRecovery()
                try self.requireNoCancelledAliasMigrationRecoveryNotice()
                return try self.service.readUserSecretForProviderCall(alias: alias)
            }
        }
    }

    func recoverPendingCredentialRecovery() async -> Result<UInt64?, Error> {
        await onWorker { Result { try self.resolvePendingCredentialRecovery() } }
    }

    private func resolvePendingCredentialRecovery() throws -> UInt64? {
        let aliasMigrationRevision = try resolvePendingAliasMigration()
        let credentialMutationRevision = try resolvePendingCredentialMutation()
        return credentialMutationRevision ?? aliasMigrationRevision
    }

    private func requireNoCancelledAliasMigrationRecoveryNotice() throws {
        switch ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeState(
            defaults: defaults
        ) {
        case .absent:
            return
        case .valid, .malformed:
            throw ProviderCredentialMutationError.cancelledAliasMigrationRecoveryRequired
        }
    }

    private func cancelledAliasMigrationRecoveryNotice(
        permitting action: ProviderUserSecretAction,
        alias: String
    ) throws -> ProviderCancelledAliasMigrationRecoveryNotice? {
        switch ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeState(
            defaults: defaults
        ) {
        case .absent:
            return nil
        case .malformed:
            throw ProviderCredentialMutationError.cancelledAliasMigrationRecoveryRequired
        case let .valid(notice):
            guard (action == .deleteStored || action == .verifyMissing),
                  ProviderSettingsPersistence.normalizedAccountAlias(alias)
                    == notice.destinationAlias else {
                throw ProviderCredentialMutationError.cancelledAliasMigrationRecoveryRequired
            }
            return notice
        }
    }

    private func resolvePendingAliasMigration() throws -> UInt64? {
        let journal: ProviderPendingAliasMigrationJournal? =
            try ProviderSettingsPersistence.withExternalTransferAdmission {
            guard ProviderSettingsPersistence.hasPendingAliasMigration(
                defaults: defaults
            ) else {
                return nil
            }
            guard let journal = ProviderSettingsPersistence.pendingAliasMigration(
                defaults: defaults
            ) else {
                throw ProviderCredentialMutationError.aliasMigrationRecoveryRequired
            }
            return journal
        }
        guard let journal else { return nil }

        switch ProviderSettingsPersistence
            .consumePendingCredentialCancellationTombstone(
                matching: journal,
                defaults: defaults
            ) {
        case .consumed:
            return journal.credentialRevision
        case .blocked:
            throw ProviderCredentialMutationError.aliasMigrationRecoveryRequired
        case .notCancelled:
            break
        }

        // Security.framework queries must run outside the admission lock so a
        // UI revocation can invalidate a suspended operation immediately.
        switch service.aliasMigrationRecoveryState(for: journal) {
        case .committed:
            guard ProviderSettingsPersistence.completePendingAliasMigration(
                journal,
                defaults: defaults
            ) else {
                throw ProviderCredentialMutationError.aliasMigrationPersistenceUnavailable
            }
        case .notCommitted, .destinationConflict:
            guard ProviderSettingsPersistence
                .abandonPendingAliasMigrationAsMissingSecret(
                    matching: journal,
                    defaults: defaults
                ) else {
                throw ProviderCredentialMutationError.aliasMigrationPersistenceUnavailable
            }
        case .inconsistent:
            throw ProviderCredentialMutationError.aliasMigrationRecoveryRequired
        }
        return journal.credentialRevision
    }

    private func resolvePendingCredentialMutation() throws -> UInt64? {
        let journal: ProviderPendingCredentialMutationJournal? =
            try ProviderSettingsPersistence.withExternalTransferAdmission {
            guard ProviderSettingsPersistence.hasPendingCredentialMutation(
                defaults: defaults
            ) else { return nil }
            guard let journal = ProviderSettingsPersistence.pendingCredentialMutation(
                defaults: defaults
            ) else {
                throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
            }
            return journal
        }
        guard let journal else { return nil }

        switch ProviderSettingsPersistence
            .consumePendingCredentialCancellationTombstone(
                matching: journal,
                defaults: defaults
            ) {
        case .consumed:
            return journal.credentialRevision
        case .blocked:
            throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
        case .notCancelled:
            break
        }

        // As above, classify Keychain state outside the short defaults lock.
        switch service.credentialMutationRecoveryState(for: journal) {
        case .committed:
            guard ProviderSettingsPersistence.completePendingCredentialMutation(
                journal,
                defaults: defaults
            ) else {
                throw ProviderCredentialMutationError.credentialMutationPersistenceUnavailable
            }
        case .notCommitted:
            guard ProviderSettingsPersistence
                .abandonPendingCredentialMutationAsMissingSecret(
                    matching: journal,
                    defaults: defaults
                ) else {
                throw ProviderCredentialMutationError.credentialMutationPersistenceUnavailable
            }
        case .inconsistent:
            throw ProviderCredentialMutationError.credentialMutationRecoveryRequired
        }
        return journal.credentialRevision
    }

    private func onWorker<T>(
        _ operation: @escaping () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }
}

private enum ProviderCredentialMutationError: Error {
    case revocationPersistenceUnavailable
    case aliasMigrationPersistenceUnavailable
    case aliasMigrationRecoveryRequired
    case credentialMutationPersistenceUnavailable
    case credentialMutationRecoveryRequired
    case cancelledAliasMigrationRecoveryRequired
}

enum ProviderConnectionExecutionOutcome {
    case published(OpenAIConnectionTestResult)
    case publicationRejected
}

struct ProviderConnectionConfigurationFingerprint: Equatable {
    let baseURL: String
    let modelName: String
    let keychainAccountAlias: String
    let credentialRevision: UInt64

    init(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        credentialRevision: UInt64 = 0
    ) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.keychainAccountAlias = keychainAccountAlias
        self.credentialRevision = credentialRevision
    }
}

@MainActor
final class ProviderStore: ObservableObject {
    @Published var llmProviderProfiles: [LLMProviderProfile]
    @Published var ocrEngineProfiles: [OCREngineProfile]
    @Published var selectedLLMProviderID: String
    @Published var selectedOCREngineID: String
    @Published var providerAuditEvents: [ProviderAuditEvent] = []
    @Published var providerKeychainLastResult: ProviderKeychainOperationResult?
    @Published var providerUserSecretLastResult: ProviderUserSecretOperationResult?
    @Published var openAIConnectionLastResult: OpenAIConnectionTestResult?
    @Published var providerRouteResolution: ProviderRouteResolution?
    @Published private(set) var providerCredentialRevision: UInt64
    @Published private(set) var cancelledAliasMigrationRecoveryNoticeState:
        ProviderCancelledAliasMigrationRecoveryNoticeState

    private let providerRouter: ProviderRouter
    private let providerKeychainWorker: ProviderKeychainWorker
    private let openAIConnectionService: OpenAICompatibleConnectionService
    private let llmProviderAdapter: LLMProviderAdapter
    private let defaults: UserDefaults
    private let providerAuditCapacity = 20
    private var activeOpenAIConnectionConfiguration: ProviderConnectionConfigurationFingerprint?
    private let providerAuditEpochSource = ProviderAuditEpochSource()
    /// Internal deterministic test seam.  It runs after transport has returned
    /// and immediately before the final publication gate.
    var openAIConnectionFinalPublicationHook: (() -> Void)?

    init(
        catalog: AICapabilityCatalog = AICapabilityCatalog.defaults(),
        providerRouter: ProviderRouter = ProviderRouter(),
        providerKeychainService: ProviderKeychainService = ProviderKeychainService(),
        openAIConnectionService: OpenAICompatibleConnectionService = OpenAICompatibleConnectionService(),
        llmProviderAdapter: LLMProviderAdapter = LLMProviderMockAdapter(),
        defaults: UserDefaults = .standard,
        /// Keeps production startup recovery enabled while allowing isolated
        /// worker race tests to own the recovery timing deterministically.
        recoverPendingCredentialStateOnInitialization: Bool = true
    ) {
        self.llmProviderProfiles = catalog.llmProviders
        self.ocrEngineProfiles = catalog.ocrEngines
        self.selectedLLMProviderID = catalog.llmProviders.first?.id ?? "llm-mock-local"
        self.selectedOCREngineID = catalog.ocrEngines.first?.id ?? "ocr-mock-local"
        self.providerRouter = providerRouter
        self.providerKeychainWorker = ProviderKeychainWorker(
            service: providerKeychainService, defaults: defaults
        )
        self.openAIConnectionService = openAIConnectionService
        self.llmProviderAdapter = llmProviderAdapter
        self.defaults = defaults
        providerCredentialRevision = ProviderSettingsPersistence
            .credentialRevision(defaults: defaults)
        cancelledAliasMigrationRecoveryNoticeState = ProviderSettingsPersistence
            .cancelledAliasMigrationRecoveryNoticeState(defaults: defaults)
        if recoverPendingCredentialStateOnInitialization {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovery = await self.providerKeychainWorker
                    .recoverPendingCredentialRecovery()
                self.refreshCancelledAliasMigrationRecoveryNoticeState()
                guard case let .success(recoveredRevision) = recovery,
                      let recoveredRevision else {
                    return
                }
                let shouldInvalidateStaleState = ProviderSettingsPersistence
                    .withExternalTransferAdmission {
                        ProviderSettingsPersistence.credentialRevision(
                            defaults: self.defaults
                        ) == recoveredRevision
                            && ProviderSettingsPersistence.externalTransferGrant(
                                defaults: self.defaults
                            ) == nil
                    }
                guard shouldInvalidateStaleState else { return }
                self.providerCredentialRevision = recoveredRevision
                self.activeOpenAIConnectionConfiguration = nil
                self.openAIConnectionLastResult = nil
            }
        }
    }

    var selectedLLMProvider: LLMProviderProfile {
        llmProviderProfiles.first { $0.id == selectedLLMProviderID } ?? llmProviderProfiles[0]
    }

    var selectedOCREngine: OCREngineProfile {
        ocrEngineProfiles.first { $0.id == selectedOCREngineID } ?? ocrEngineProfiles[0]
    }

    @discardableResult
    func resolveProviderSettingsRoute(
        apiKeychainAccountAlias: String,
        externalTransferConfirmed: Bool
    ) -> ProviderRouteResolution {
        let provider = openAICompatibleLLMProvider()
        let resolution = providerRouter.resolve(
            ProviderRouteRequest(
                capability: provider.base.domain,
                profileID: provider.id,
                executionMode: provider.base.executionMode,
                providerSummary: provider.localizedSummary,
                configured: true,
                implemented: true,
                localOnly: provider.base.localOnly,
                requiresKeychainSecret: provider.base.requiresKeychainSecret,
                requiresExternalTransfer: provider.base.requiresExternalTransfer,
                keychainAccountAlias: apiKeychainAccountAlias,
                externalTransferConfirmed: externalTransferConfirmed
            )
        )
        providerRouteResolution = resolution
        recordProviderRouteResolution(resolution)
        return resolution
    }

    func validateProviderConnectionGate(summary: String, ready: Bool) -> Bool {
        ready
    }

    func activateOpenAIConnectionConfiguration(
        _ fingerprint: ProviderConnectionConfigurationFingerprint
    ) {
        activeOpenAIConnectionConfiguration = fingerprint
        openAIConnectionLastResult = nil
    }

    func isActiveOpenAIConnectionConfiguration(
        _ fingerprint: ProviderConnectionConfigurationFingerprint
    ) -> Bool {
        activeOpenAIConnectionConfiguration == fingerprint
    }

    func deactivateOpenAIConnectionConfiguration() {
        activeOpenAIConnectionConfiguration = nil
        openAIConnectionLastResult = nil
    }

    func providerAuditTokenSource() -> ProviderAuditTokenSource {
        let source = providerAuditEpochSource
        return { source.capture() }
    }

    func previewProviderSettingsConfirmation(providerSummary: String, requiresExternalTransfer: Bool) -> String {
        let auditID = ProviderAuditID.make(prefix: "pa_ui")
        recordProviderAudit(
            ProviderAuditEvent(
                id: auditID,
                createdAt: Date(),
                kind: .providerSettingsPreview,
                action: .settingsPreview,
                outcome: .previewed,
                confirmationLevel: requiresExternalTransfer ? .externalTransfer : .noneMock,
                auditID: auditID,
                warningCount: 1
            )
        )
        return auditID
    }

    func previewProviderSecretLifecycle(
        step: String,
        state: String,
        auditID: String,
        providerSummary: String
    ) {
        recordProviderAudit(
            ProviderAuditEvent(
                id: auditID,
                createdAt: Date(),
                kind: .keychainLifecyclePreview,
                action: .keychainLifecycle,
                outcome: .previewed,
                confirmationLevel: .preview,
                auditID: auditID,
                warningCount: 1
            )
        )
    }

    func performProviderKeychainGate(
        action: ProviderKeychainGateAction,
        accountAlias: String,
        providerSummary: String
    ) async -> ProviderKeychainGateUIOutcome {
        let auditID = ProviderAuditID.make(prefix: "kc_ui")
        switch await providerKeychainWorker.performKeychainGate(action: action, alias: accountAlias) {
        case let .success(result):
            providerKeychainLastResult = result
            recordProviderAudit(
                ProviderAuditEvent(
                    id: auditID,
                    createdAt: Date(),
                    kind: .keychainLifecyclePreview,
                    action: .keychainGate,
                    outcome: result.ok ? .completed : .failed,
                    confirmationLevel: .preview,
                    count: result.secretLength,
                    auditID: auditID,
                    warningCount: 1
                )
            )
            return ProviderKeychainGateUIOutcome(
                lifecycleRawValue: lifecycleStateRawValue(action: action, result: result),
                auditID: auditID,
                operationSucceeded: result.ok
            )
        case .failure:
            providerKeychainLastResult = nil
            recordProviderAudit(
                ProviderAuditEvent(
                    id: auditID,
                    createdAt: Date(),
                    kind: .keychainLifecyclePreview,
                    action: .keychainGate,
                    outcome: .failed,
                    confirmationLevel: .preview,
                    errorCode: .invalidResponse,
                    auditID: auditID,
                    warningCount: 1
                )
            )
            return ProviderKeychainGateUIOutcome(
                lifecycleRawValue: "missing",
                auditID: auditID,
                operationSucceeded: false
            )
        }
    }

    func performProviderUserSecretGate(
        action: ProviderUserSecretAction,
        accountAlias: String,
        secretCandidate: String? = nil,
        replacingAccountAlias: String? = nil,
        authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil
    ) async -> ProviderKeychainGateUIOutcome {
        let auditID = ProviderAuditID.make(prefix: "kc_user")
        let mutationResult = await providerKeychainWorker.performUserSecretGate(
            action: action,
            alias: accountAlias,
            secret: secretCandidate,
            replacingAlias: action == .saveOrReplace ? replacingAccountAlias : nil,
            authorizationIntent: authorizationIntent
        )
        refreshCancelledAliasMigrationRecoveryNoticeState()
        switch mutationResult {
        case let .success(mutation):
            let result = mutation.0
            providerUserSecretLastResult = result
            if let revision = mutation.1 {
                    providerCredentialRevision = revision
                    activeOpenAIConnectionConfiguration = nil
                    openAIConnectionLastResult = nil
            }
            recordProviderAudit(
                ProviderAuditEvent(
                    id: auditID,
                    createdAt: Date(),
                    kind: .userSecretKeychainGate,
                    action: .userSecretGate,
                    outcome: result.ok ? .completed : .failed,
                    confirmationLevel: .preview,
                    count: result.secretLength,
                    auditID: auditID,
                    warningCount: 2
                )
            )
            return ProviderKeychainGateUIOutcome(
                lifecycleRawValue: userSecretLifecycleStateRawValue(action: action, result: result),
                auditID: auditID,
                operationSucceeded: result.ok
            )
        case .failure:
            switch action {
            case .saveOrReplace, .deleteStored:
                providerCredentialRevision = ProviderSettingsPersistence
                    .credentialRevision(defaults: defaults)
                activeOpenAIConnectionConfiguration = nil
                openAIConnectionLastResult = nil
            case .verifyStored, .verifyMissing:
                break
            }
            providerUserSecretLastResult = nil
            recordProviderAudit(
                ProviderAuditEvent(
                    id: auditID,
                    createdAt: Date(),
                    kind: .userSecretKeychainGate,
                    action: .userSecretGate,
                    outcome: .failed,
                    confirmationLevel: .preview,
                    errorCode: .invalidResponse,
                    auditID: auditID,
                    warningCount: 1
                )
            )
            return ProviderKeychainGateUIOutcome(
                lifecycleRawValue: "missing",
                auditID: auditID,
                operationSucceeded: false
            )
        }
    }

    private func refreshCancelledAliasMigrationRecoveryNoticeState() {
        cancelledAliasMigrationRecoveryNoticeState = ProviderSettingsPersistence
            .cancelledAliasMigrationRecoveryNoticeState(defaults: defaults)
    }

    func previewProviderConnectionTest(
        summary: String,
        ready: Bool,
        providerSummary: String,
        requiresExternalTransfer: Bool
    ) {
        let auditID = ProviderAuditID.make(prefix: "pc_ui")
        var warnings = [L10n.string("providerAudit.warning.noProviderCall")]
        if !ready {
            warnings.append(L10n.string("providerAudit.warning.connectionNotExecuted"))
        }
        recordProviderAudit(
            ProviderAuditEvent(
                id: auditID,
                createdAt: Date(),
                kind: .providerConnectionPreview,
                action: .connectionPreview,
                outcome: ready ? .ready : .blocked,
                confirmationLevel: requiresExternalTransfer ? .externalTransfer : .noneMock,
                auditID: auditID,
                warningCount: warnings.count
            )
        )
    }

    func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String) -> String {
        let provider = openAICompatibleLLMProvider()
        let boundary = OpenAICompatibleProfileBoundary.make(
            provider: provider,
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias
        )
        let request = LLMProviderRequest(
            id: "llm_preview_openai_compatible",
            task: .translationPreview,
            providerProfileID: boundary.providerID,
            providerName: boundary.providerName,
            sourceSummary: L10n.format(
                "providerAudit.source.llmAdapterPreview",
                boundary.baseURLSummary,
                boundary.keychainAccountAlias
            ),
            characterCount: 128,
            outputFormat: .structuredJSON,
            confirmationLevel: "external_transfer",
            baseURLSummary: boundary.baseURLSummary,
            modelName: boundary.modelName,
            keychainAccountAlias: boundary.keychainAccountAlias
        )
        let response = llmProviderAdapter.makePreview(request: request)
        recordLLMAdapterResponse(response, kind: .llmAdapterPreview)
        return response.auditID
    }

    func runLLMMockAdapter() -> String {
        let provider = selectedLLMProvider
        let request = LLMProviderRequest(
            id: "llm_mock_summary_preview",
            task: .summaryPreview,
            providerProfileID: provider.id,
            providerName: provider.localizedName,
            sourceSummary: L10n.string("llmAdapter.task.summaryPreview"),
            characterCount: 64,
            outputFormat: .structuredJSON,
            confirmationLevel: "none_mock",
            baseURLSummary: "local",
            modelName: "mock",
            keychainAccountAlias: "none"
        )
        let response = llmProviderAdapter.runMock(request: request)
        recordLLMAdapterResponse(response, kind: .llmMockRun)
        return response.auditID
    }

    func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String) -> String {
        let provider = openAICompatibleLLMProvider()
        let preview = ProviderSecretInputPreview.makeSecretInputPreview(
            provider: provider,
            keychainAccountAlias: keychainAccountAlias,
            secretCharacterCount: secretCharacterCount
        )
        recordProviderAudit(
            ProviderAuditEvent(
                id: preview.id,
                createdAt: Date(),
                kind: .secretInputPreview,
                action: .secretInputPreview,
                outcome: .previewed,
                confirmationLevel: .preview,
                count: preview.characterCount,
                auditID: preview.auditID,
                warningCount: 1
            )
        )
        return preview.auditID
    }

    func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String) -> String {
        let provider = openAICompatibleLLMProvider()
        let boundary = OpenAICompatibleProfileBoundary.make(
            provider: provider,
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias
        )
        let draft = OpenAIConnectionPreviewDraft.makeConnectionPreview(boundary: boundary)
        recordProviderAudit(
            ProviderAuditEvent(
                id: draft.id,
                createdAt: Date(),
                kind: .openAIConnectionPreview,
                action: .openAIConnectionPreview,
                outcome: .previewed,
                confirmationLevel: .externalTransfer,
                auditID: draft.auditID,
                warningCount: 2
            )
        )
        return draft.auditID
    }

    func runOpenAIConnectionTest(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        configurationFingerprint: ProviderConnectionConfigurationFingerprint? = nil
    ) async -> OpenAIConnectionTestResult {
        switch await runOpenAIConnectionTestExecution(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            configurationFingerprint: configurationFingerprint
        ) {
        case let .published(result):
            return result
        case .publicationRejected:
            return publicationRejectedConnectionResult(
                profile: OpenAIConnectionTestProfile(
                    providerName: openAICompatibleLLMProvider().localizedName,
                    baseURL: baseURL,
                    modelName: modelName,
                    keychainAccountAlias: keychainAccountAlias,
                    timeoutSeconds: 60
                )
            )
        }
    }

    func runOpenAIConnectionTestExecution(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        configurationFingerprint: ProviderConnectionConfigurationFingerprint? = nil
    ) async -> ProviderConnectionExecutionOutcome {
        let auditToken = providerAuditEpochSource.capture()
        let provider = openAICompatibleLLMProvider()
        let externalTransferTarget = ProviderExternalTransferTarget(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            credentialRevision: providerCredentialRevision
        )
        let externalTransferGrant = ProviderSettingsPersistence
            .externalTransferGrant(defaults: defaults)
        let externalTransferAuthorized = externalTransferTarget.map {
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: $0,
                grant: externalTransferGrant,
                defaults: defaults
            )
        } ?? false
        let profile = OpenAIConnectionTestProfile(
            providerName: provider.localizedName,
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            timeoutSeconds: 60
        )
        let gate = ProviderRuntimeGate.validateOpenAICompatible(
            baseURL: baseURL,
            modelName: modelName,
            keychainAccountAlias: keychainAccountAlias,
            externalTransferConfirmed: externalTransferAuthorized
        )
        guard gate.ready else {
            let result = blockedConnectionResult(profile: profile, errorCode: gate.errorCode ?? .missingConfiguration)
            finishOpenAIConnectionTest(
                result,
                auditToken: auditToken,
                configurationFingerprint: configurationFingerprint
            )
            return .published(result)
        }

        guard let externalTransferTarget,
              ProviderSettingsPersistence.isExternalTransferAuthorized(
               target: externalTransferTarget,
               grant: externalTransferGrant,
               defaults: defaults
              ) else {
            let result = blockedConnectionResult(
                profile: profile,
                errorCode: .confirmationRequired
            )
            finishOpenAIConnectionTest(
                result,
                auditToken: auditToken,
                configurationFingerprint: configurationFingerprint
            )
            return .published(result)
        }

        do {
            let material = try await providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()
            guard ProviderSettingsPersistence.isExternalTransferAuthorized(
                   target: externalTransferTarget,
                  grant: externalTransferGrant,
                  defaults: defaults
                  ) else {
                return .publicationRejected
            }
            guard material.credentialRevision
                    == externalTransferTarget.credentialRevision else {
                let result = blockedConnectionResult(
                    profile: profile,
                    errorCode: .missingSecret
                )
                if ProviderSettingsPersistence.publishExternalTransfer(
                    target: externalTransferTarget,
                    grant: externalTransferGrant,
                    defaults: defaults,
                    publication: {
                        self.finishOpenAIConnectionTest(
                            result,
                            auditToken: auditToken,
                            configurationFingerprint: configurationFingerprint
                        )
                    }
                ) {
                    return .published(result)
                }
                return .publicationRejected
            }
            let result = await openAIConnectionService.testConnection(
                profile: profile,
                secretMaterial: material,
                authorizationCheck: {
                    return ProviderSettingsPersistence
                        .isExternalTransferAuthorized(
                            target: externalTransferTarget,
                            grant: externalTransferGrant,
                            defaults: defaults
                        )
                },
                admission: { start in
                    ProviderSettingsPersistence.admitExternalTransfer(
                        target: externalTransferTarget,
                        grant: externalTransferGrant,
                        defaults: self.defaults,
                        start: start
                    )
                }
            )
            openAIConnectionFinalPublicationHook?()
            if ProviderSettingsPersistence.publishExternalTransfer(
                target: externalTransferTarget,
                grant: externalTransferGrant,
                defaults: defaults,
                publication: {
                    self.finishOpenAIConnectionTest(
                        result,
                        auditToken: auditToken,
                        configurationFingerprint: configurationFingerprint
                    )
                }
            ) {
                // The redacted read state is only visible after the exact final
                // grant accepted the request's final publication.
                providerUserSecretLastResult = material.redactedResult
                return .published(result)
            }
            return .publicationRejected
        } catch {
            let result = openAIConnectionService.missingSecretResult(
                profile: profile,
                message: error.localizedDescription
            )
            if ProviderSettingsPersistence.publishExternalTransfer(
                target: externalTransferTarget,
                grant: externalTransferGrant,
                defaults: defaults,
                publication: {
                    self.finishOpenAIConnectionTest(
                        result,
                        auditToken: auditToken,
                        configurationFingerprint: configurationFingerprint
                    )
                }
            ) {
                return .published(result)
            }
            return .publicationRejected
        }
    }

    func clearProviderAuditEvents() {
        providerAuditEpochSource.advance()
        providerAuditEvents.removeAll()
    }

    func recordProviderAudit(_ event: ProviderAuditEvent) {
        providerAuditEvents.insert(event, at: 0)
        if providerAuditEvents.count > providerAuditCapacity {
            providerAuditEvents = Array(providerAuditEvents.prefix(providerAuditCapacity))
        }
    }

    func recordProviderRouteResolution(_ resolution: ProviderRouteResolution) {
        recordProviderAudit(
            ProviderAuditEvent(
                id: resolution.id,
                createdAt: Date(),
                kind: .providerRouteResolution,
                action: .routeResolution,
                outcome: resolution.ok ? .ready : .blocked,
                confirmationLevel: confirmationLevel(for: resolution.confirmationLevel),
                errorCode: resolution.errorCode,
                auditID: resolution.auditID,
                warningCount: 1
            )
        )
    }

    /// Records an audit that the translation adapter already accepted at its
    /// final external-transfer publication boundary. A later grant revocation
    /// must not erase that completed transfer; the audit epoch still prevents
    /// a delayed delivery from repopulating history after an explicit clear.
    func recordAcceptedTranslationRuntime(
        _ result: OpenAITranslationRuntimeResult,
        auditToken: ProviderAuditToken
    ) {
        guard providerAuditEpochSource.matches(auditToken) else {
            return
        }
        recordTranslationRuntime(result)
    }

    func recordTranslationRuntime(_ result: OpenAITranslationRuntimeResult) {
        recordProviderAudit(
            ProviderAuditEvent(
                id: result.auditID,
                createdAt: Date(),
                kind: .translationRuntime,
                action: .translationRuntime,
                outcome: result.ok ? .completed : .failed,
                confirmationLevel: .externalTransfer,
                count: result.textCharacterCount,
                errorCode: result.status.providerErrorCode,
                auditID: result.auditID,
                warningCount: 2 + result.warnings.count
            )
        )
    }

    private func recordLLMAdapterResponse(_ response: LLMProviderResponse, kind: ProviderAuditEventKind) {
        recordProviderAudit(
            ProviderAuditEvent(
                id: response.id,
                createdAt: response.createdAt,
                kind: kind,
                action: kind == .llmMockRun ? .mockRun : .adapterPreview,
                outcome: kind == .llmMockRun ? .completed : .previewed,
                confirmationLevel: confirmationLevel(for: response.confirmationLevel),
                auditID: response.auditID,
                warningCount: response.warnings.count
            )
        )
    }

    private func recordOpenAIConnectionTest(_ result: OpenAIConnectionTestResult) {
        recordProviderAudit(
            ProviderAuditEvent(
                id: result.auditID,
                createdAt: Date(),
                kind: .openAIConnectionTest,
                action: .connectionTest,
                outcome: result.ok ? .completed : .failed,
                confirmationLevel: .externalTransfer,
                count: result.responseTextCharacterCount,
                errorCode: result.status.providerErrorCode,
                auditID: result.auditID,
                warningCount: 2 + result.warnings.count
            )
        )
    }

    private func finishOpenAIConnectionTest(
        _ result: OpenAIConnectionTestResult,
        auditToken: ProviderAuditToken,
        configurationFingerprint: ProviderConnectionConfigurationFingerprint?
    ) {
        guard providerAuditEpochSource.matches(auditToken) else {
            return
        }
        recordOpenAIConnectionTest(result)
        guard let configurationFingerprint else {
            openAIConnectionLastResult = result
            return
        }
        guard activeOpenAIConnectionConfiguration == configurationFingerprint else {
            return
        }
        openAIConnectionLastResult = result
    }

    private func openAICompatibleLLMProvider() -> LLMProviderProfile {
        llmProviderProfiles.first { $0.base.executionMode == .openAICompatible } ?? selectedLLMProvider
    }

    private func confirmationLevel(
        for rawValue: String
    ) -> ProviderAuditConfirmationLevel {
        ProviderAuditConfirmationLevel(rawValue: rawValue) ?? .preview
    }

    private func blockedConnectionResult(
        profile: OpenAIConnectionTestProfile,
        errorCode: ProviderErrorCode
    ) -> OpenAIConnectionTestResult {
        let status: OpenAIConnectionStatus
        switch errorCode {
        case .missingConfiguration:
            status = .missingConfiguration
        case .invalidBaseURL:
            status = .invalidBaseURL
        case .confirmationRequired:
            status = .confirmationRequired
        case .missingSecret:
            status = .missingSecret
        case .unsupportedCapability:
            status = .unsupportedCapability
        default:
            status = .httpError
        }
        return OpenAIConnectionTestResult(
            ok: false,
            status: status,
            providerName: profile.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "OpenAI-compatible" : profile.providerName,
            baseURLSummary: summarizeBaseURL(profile.baseURL),
            modelName: sanitized(profile.modelName, fallback: "model-placeholder"),
            keychainAccountAlias: sanitized(profile.keychainAccountAlias, fallback: "account-alias-placeholder"),
            endpointSummary: "POST /v1/chat/completions",
            httpStatusCode: nil,
            durationMS: 0,
            requestID: nil,
            responseTextCharacterCount: nil,
            secretLength: nil,
            auditID: ProviderAuditID.make(prefix: "llm_test"),
            warnings: [errorCode.rawValue, "provider_call_not_executed"]
        )
    }

    private func publicationRejectedConnectionResult(
        profile: OpenAIConnectionTestProfile
    ) -> OpenAIConnectionTestResult {
        OpenAIConnectionTestResult(
            ok: false,
            status: .confirmationRequired,
            providerName: profile.providerName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? "OpenAI-compatible" : profile.providerName,
            baseURLSummary: summarizeBaseURL(profile.baseURL),
            modelName: sanitized(
                profile.modelName,
                fallback: "model-placeholder"
            ),
            keychainAccountAlias: sanitized(
                profile.keychainAccountAlias,
                fallback: "account-alias-placeholder"
            ),
            endpointSummary: "POST /v1/chat/completions",
            httpStatusCode: nil,
            durationMS: 0,
            requestID: nil,
            responseTextCharacterCount: nil,
            secretLength: nil,
            auditID: ProviderAuditID.make(prefix: "llm_test"),
            warnings: [
                ProviderErrorCode.confirmationRequired.rawValue,
                "result_publication_rejected",
                "provider_response_redacted",
            ]
        )
    }

    private func summarizeBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else {
            return "base-url-placeholder"
        }
        if let scheme = url.scheme {
            return "\(scheme)://\(host)"
        }
        return host
    }

    private func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func lifecycleStateRawValue(action: ProviderKeychainGateAction, result: ProviderKeychainOperationResult) -> String {
        guard result.ok else {
            return "missing"
        }
        switch action {
        case .saveTestSecret:
            return "test_secret_saved"
        case .rotateTestSecret:
            return "test_secret_rotated"
        case .deleteTestSecret, .verifyMissing:
            return "deleted_verified"
        }
    }

    private func userSecretLifecycleStateRawValue(action: ProviderUserSecretAction, result: ProviderUserSecretOperationResult) -> String {
        guard result.ok else {
            return "missing"
        }
        switch action {
        case .saveOrReplace, .verifyStored:
            return result.found ? "user_secret_stored" : "missing"
        case .deleteStored, .verifyMissing:
            return "user_secret_deleted_verified"
        }
    }
}
