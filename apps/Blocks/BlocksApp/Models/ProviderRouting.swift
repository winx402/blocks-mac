import Foundation

enum ProviderAuditID {
    static func make(
        prefix: String,
        uuid: UUID = UUID()
    ) -> String {
        "\(prefix)_\(uuid.uuidString.lowercased())"
    }

    static func make(
        prefix: String,
        uuidString: String
    ) -> String {
        guard let uuid = UUID(uuidString: uuidString) else {
            return "\(prefix)_\(uuidString.lowercased())"
        }
        return make(prefix: prefix, uuid: uuid)
    }

    /// Keeps the compact identifier already used by the UI while the full
    /// UUID remains the identity carried by audit and plugin boundaries.
    static func display(_ auditID: String) -> String {
        guard let separator = auditID.lastIndex(of: "_") else {
            return auditID
        }
        let uuidStart = auditID.index(after: separator)
        guard let uuid = UUID(
            uuidString: String(auditID[uuidStart...])
        ) else {
            return auditID
        }
        return "\(auditID[...separator])\(uuid.uuidString.prefix(8).lowercased())"
    }
}

enum ProviderErrorCode: String, Codable, CaseIterable, Equatable {
    case missingConfiguration = "missing_configuration"
    case missingSecret = "missing_secret"
    case invalidBaseURL = "invalid_base_url"
    case unauthorized
    case forbidden
    case rateLimited = "rate_limited"
    case timeout
    case networkError = "network_error"
    case invalidResponse = "invalid_response"
    case providerUnavailable = "provider_unavailable"
    case unsupportedCapability = "unsupported_capability"
    case confirmationRequired = "confirmation_required"

    var localizedTitle: String {
        L10n.string("provider.error.\(rawValue).title")
    }

    var localizedDetail: String {
        L10n.string("provider.error.\(rawValue).detail")
    }
}

struct ProviderRouteRequest: Codable, Equatable {
    let capability: AICapabilityDomain
    let profileID: String
    let executionMode: AICapabilityExecutionMode
    let providerSummary: String
    let configured: Bool
    let implemented: Bool
    let localOnly: Bool
    let requiresKeychainSecret: Bool
    let requiresExternalTransfer: Bool
    let preflightErrorCode: ProviderErrorCode?
    let keychainAccountAlias: String
    let externalTransferConfirmed: Bool

    init(
        capability: AICapabilityDomain,
        profileID: String,
        executionMode: AICapabilityExecutionMode,
        providerSummary: String,
        configured: Bool,
        implemented: Bool,
        localOnly: Bool,
        requiresKeychainSecret: Bool,
        requiresExternalTransfer: Bool,
        preflightErrorCode: ProviderErrorCode? = nil,
        keychainAccountAlias: String = "",
        externalTransferConfirmed: Bool = false
    ) {
        self.capability = capability
        self.profileID = profileID
        self.executionMode = executionMode
        self.providerSummary = providerSummary
        self.configured = configured
        self.implemented = implemented
        self.localOnly = localOnly
        self.requiresKeychainSecret = requiresKeychainSecret
        self.requiresExternalTransfer = requiresExternalTransfer
        self.preflightErrorCode = preflightErrorCode
        self.keychainAccountAlias = keychainAccountAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.externalTransferConfirmed = externalTransferConfirmed
    }

    init(
        profile: AICapabilityProfile,
        keychainAccountAlias: String = "",
        externalTransferConfirmed: Bool = false
    ) {
        self.init(
            capability: profile.domain,
            profileID: profile.id,
            executionMode: profile.executionMode,
            providerSummary: profile.localizedSummary,
            configured: profile.configured,
            implemented: profile.implemented,
            localOnly: profile.localOnly,
            requiresKeychainSecret: profile.requiresKeychainSecret,
            requiresExternalTransfer: profile.requiresExternalTransfer,
            keychainAccountAlias: keychainAccountAlias,
            externalTransferConfirmed: externalTransferConfirmed
        )
    }
}

struct ProviderRouteResolution: Codable, Equatable, Identifiable {
    let id: String
    let ok: Bool
    let capability: AICapabilityDomain
    let profileID: String
    let executionMode: AICapabilityExecutionMode
    let providerSummary: String
    let confirmationLevel: String
    let errorCode: ProviderErrorCode?
    let auditID: String
    let warnings: [String]

    var localizedStatusTitle: String {
        errorCode?.localizedTitle ?? L10n.string("provider.route.ready.title")
    }

    var localizedStatusDetail: String {
        errorCode?.localizedDetail ?? L10n.string("provider.route.ready.detail")
    }
}

struct ProviderRouteSummary: Codable, Equatable {
    let capability: AICapabilityDomain
    let profileID: String
    let executionMode: AICapabilityExecutionMode
    let providerSummary: String
    let confirmationLevel: String
    let errorCode: ProviderErrorCode?
    let auditID: String

    init(resolution: ProviderRouteResolution) {
        capability = resolution.capability
        profileID = resolution.profileID
        executionMode = resolution.executionMode
        providerSummary = resolution.providerSummary
        confirmationLevel = resolution.confirmationLevel
        errorCode = resolution.errorCode
        auditID = resolution.auditID
    }
}

struct ProviderRuntimeGateResult: Codable, Equatable {
    let ready: Bool
    let errorCode: ProviderErrorCode?

    static let ready = ProviderRuntimeGateResult(ready: true, errorCode: nil)

    static func blocked(_ errorCode: ProviderErrorCode) -> ProviderRuntimeGateResult {
        ProviderRuntimeGateResult(ready: false, errorCode: errorCode)
    }
}

struct ProviderExternalTransferTarget: Codable, Equatable, Sendable {
    let normalizedBaseURL: String
    let modelName: String
    let keychainAccountAlias: String
    let credentialRevision: UInt64

    init?(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        credentialRevision: UInt64
    ) {
        guard let normalizedBaseURL = ProviderRuntimeGate
            .normalizedProviderBaseURL(baseURL) else {
            return nil
        }
        let normalizedModelName = modelName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedAccountAlias = keychainAccountAlias
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelName.isEmpty,
              !normalizedAccountAlias.isEmpty else {
            return nil
        }
        self.normalizedBaseURL = normalizedBaseURL
        self.modelName = normalizedModelName
        self.keychainAccountAlias = normalizedAccountAlias
        self.credentialRevision = credentialRevision
    }
}

struct ProviderExternalTransferGrant: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let target: ProviderExternalTransferTarget
    /// Identifies one authorization epoch. It deliberately changes even when
    /// the same destination is re-authorized after revoke.
    let generation: UInt64

    init(target: ProviderExternalTransferTarget, generation: UInt64) {
        version = Self.currentVersion
        self.target = target
        self.generation = generation
    }
}

/// Captures one explicit external-transfer confirmation. Async confirmation
/// flows must carry this value across suspension points so a later user
/// revocation wins over their stale completion.
struct ProviderExternalTransferAuthorizationIntent: Equatable, Sendable {
    fileprivate let epoch: UUID
}

/// Persists the one credential mutation which an explicit confirmation may
/// authorize. It contains no credential material.
private struct ProviderExternalTransferAuthorizationIntentMutationBinding:
    Codable,
    Equatable,
    Sendable
{
    static let currentVersion = 1

    let version: Int
    let epoch: UUID
    let credentialRevision: UInt64

    init?(epoch: UUID, credentialRevision: UInt64) {
        guard credentialRevision > 0 else { return nil }
        version = Self.currentVersion
        self.epoch = epoch
        self.credentialRevision = credentialRevision
    }
}

/// Records the narrow crash boundary where Security.framework has moved a
/// credential to a new account alias but UserDefaults has not yet committed
/// the matching routing state.  It intentionally contains no secret material.
struct ProviderPendingAliasMigrationJournal: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let sourceAlias: String
    let destinationAlias: String
    let credentialRevision: UInt64

    init?(
        sourceAlias: String,
        destinationAlias: String,
        credentialRevision: UInt64
    ) {
        let source = ProviderSettingsPersistence.normalizedAccountAlias(sourceAlias)
        let destination = ProviderSettingsPersistence.normalizedAccountAlias(destinationAlias)
        guard !source.isEmpty,
              !destination.isEmpty,
              source != destination,
              credentialRevision > 0 else {
            return nil
        }
        version = Self.currentVersion
        self.sourceAlias = source
        self.destinationAlias = destination
        self.credentialRevision = credentialRevision
    }
}

/// A durable, low-sensitivity recovery boundary after a cancelled alias
/// migration may have committed in Security.framework. It never contains
/// credential material and deliberately identifies only the item to remove.
struct ProviderCancelledAliasMigrationRecoveryNotice: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let sourceAlias: String
    let destinationAlias: String
    let credentialRevision: UInt64

    init?(
        sourceAlias: String,
        destinationAlias: String,
        credentialRevision: UInt64
    ) {
        guard let canonical = ProviderPendingAliasMigrationJournal(
            sourceAlias: sourceAlias,
            destinationAlias: destinationAlias,
            credentialRevision: credentialRevision
        ) else {
            return nil
        }
        version = Self.currentVersion
        self.sourceAlias = canonical.sourceAlias
        self.destinationAlias = canonical.destinationAlias
        self.credentialRevision = canonical.credentialRevision
    }
}

enum ProviderCancelledAliasMigrationRecoveryNoticeState: Equatable {
    case absent
    case valid(ProviderCancelledAliasMigrationRecoveryNotice)
    case malformed
}

/// Records the crash boundary for an ordinary same-alias credential mutation.
/// It intentionally contains only the mutation identity, never secret bytes.
enum ProviderPendingCredentialMutationKind: String, Codable, Sendable {
    case save
    case delete
}

struct ProviderPendingCredentialMutationJournal: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let kind: ProviderPendingCredentialMutationKind
    let alias: String
    let credentialRevision: UInt64

    init?(
        kind: ProviderPendingCredentialMutationKind,
        alias: String,
        credentialRevision: UInt64
    ) {
        let normalizedAlias = ProviderSettingsPersistence.normalizedAccountAlias(alias)
        guard !normalizedAlias.isEmpty, credentialRevision > 0 else { return nil }
        version = Self.currentVersion
        self.kind = kind
        self.alias = normalizedAlias
        self.credentialRevision = credentialRevision
    }
}

/// Records a user cancellation which won the race with a non-cancellable
/// Security.framework mutation. It carries only the exact recovery-journal
/// identity, never credential material.
enum ProviderPendingCredentialCancellationTombstoneKind: String, Codable, Sendable {
    case credentialMutation
    case aliasMigration
}

struct ProviderPendingCredentialCancellationTombstone: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let kind: ProviderPendingCredentialCancellationTombstoneKind
    let credentialMutation: ProviderPendingCredentialMutationJournal?
    let aliasMigration: ProviderPendingAliasMigrationJournal?

    init?(credentialMutation: ProviderPendingCredentialMutationJournal) {
        version = Self.currentVersion
        kind = .credentialMutation
        self.credentialMutation = credentialMutation
        aliasMigration = nil
    }

    init?(aliasMigration: ProviderPendingAliasMigrationJournal) {
        version = Self.currentVersion
        kind = .aliasMigration
        credentialMutation = nil
        self.aliasMigration = aliasMigration
    }

    func matches(_ journal: ProviderPendingCredentialMutationJournal) -> Bool {
        kind == .credentialMutation && credentialMutation == journal
    }

    func matches(_ journal: ProviderPendingAliasMigrationJournal) -> Bool {
        kind == .aliasMigration && aliasMigration == journal
    }

    var isValid: Bool {
        switch kind {
        case .credentialMutation:
            guard let credentialMutation, aliasMigration == nil else { return false }
            return ProviderPendingCredentialCancellationTombstone(
                credentialMutation: credentialMutation
            ) == self
        case .aliasMigration:
            guard let aliasMigration, credentialMutation == nil else { return false }
            return ProviderPendingCredentialCancellationTombstone(
                aliasMigration: aliasMigration
            ) == self
        }
    }
}

enum ProviderPendingCredentialCancellationTombstoneConsumption: Equatable {
    case notCancelled
    case consumed
    case blocked
}

struct ProviderRuntimeGate {
    static func validateOpenAICompatible(
        baseURL: String,
        modelName: String,
        keychainAccountAlias: String,
        externalTransferConfirmed: Bool
    ) -> ProviderRuntimeGateResult {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = keychainAccountAlias.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty, !trimmedModel.isEmpty else {
            return .blocked(.missingConfiguration)
        }
        guard isAllowedProviderBaseURL(trimmedBaseURL) else {
            return .blocked(.invalidBaseURL)
        }
        guard !trimmedAlias.isEmpty else {
            return .blocked(.missingSecret)
        }
        guard externalTransferConfirmed else {
            return .blocked(.confirmationRequired)
        }
        return .ready
    }

    static func isAllowedProviderBaseURL(_ value: String) -> Bool {
        normalizedProviderBaseURL(value) != nil
    }

    static func normalizedProviderBaseURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host
        else {
            return nil
        }

        // URLComponents may expose an invalid or overflowing explicit port
        // as nil. Inspect the original authority before normalization so
        // `https://host:`, `:0`, and oversized ports cannot silently become
        // the default HTTPS port.
        switch explicitPort(in: trimmed) {
        case .absent:
            break
        case let .value(rawPort):
            guard
                !rawPort.isEmpty,
                rawPort.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let port = Int(rawPort),
                (1...65_535).contains(port)
            else {
                return nil
            }
        case .malformed:
            return nil
        }

        // Credentials and URL parameters are not provider configuration. In
        // particular, do not normalize them away: callers must be able to
        // reject the original value before it can reach persistent storage.
        guard
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }

        guard scheme == "https" || (scheme == "http" && isLiteralLoopbackHost(host)) else {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path == "/" ? "" : path
        return components.string
    }

    private enum ExplicitPort {
        case absent
        case value(String)
        case malformed
    }

    private static func explicitPort(in value: String) -> ExplicitPort {
        guard let schemeDelimiter = value.range(of: "://") else {
            return .malformed
        }
        let afterScheme = value[schemeDelimiter.upperBound...]
        let authorityEnd = afterScheme.firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard !authority.isEmpty else { return .malformed }

        // Credentials are rejected separately. Keeping this extraction local
        // to the authority makes bracketed IPv6 ports unambiguous.
        let hostAndPort = authority.split(
            separator: "@",
            omittingEmptySubsequences: false
        ).last ?? authority
        if hostAndPort.first == "[" {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else {
                return .malformed
            }
            let suffix = hostAndPort[hostAndPort.index(after: closingBracket)...]
            guard !suffix.isEmpty else { return .absent }
            guard suffix.first == ":" else { return .malformed }
            return .value(String(suffix.dropFirst()))
        }

        guard let colon = hostAndPort.lastIndex(of: ":") else {
            return .absent
        }
        guard colon != hostAndPort.startIndex else { return .malformed }
        return .value(String(hostAndPort[hostAndPort.index(after: colon)...]))
    }

    private static func isLiteralLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "::1"
            || normalized == "127.0.0.1"
    }
}

enum ProviderSettingsPersistence {
    // This is the process-wide linearization point for external-transfer
    // admission and every change which invalidates that admission.  Keep this
    // synchronous: it must never be held across a suspension point.
    private static let externalTransferAdmissionLock = NSRecursiveLock()
    static let baseURLKey = "provider.api.baseURL"
    static let modelNameKey = "provider.api.modelName"
    static let accountAliasKey = "provider.api.keychainAccountAlias"
    static let storedSecretAccountAliasKey = "provider.api.storedSecretAccountAlias"
    static let secretLifecycleStateKey = "provider.api.secretLifecycleState"
    static let credentialRevisionKey = "provider.api.credentialRevision"
    static let pendingAliasMigrationJournalKey =
        "provider.api.pendingAliasMigration.v1"
    static let pendingCredentialMutationJournalKey =
        "provider.api.pendingCredentialMutation.v1"
    static let pendingCredentialCancellationTombstoneKey =
        "provider.api.pendingCredentialCancellation.v1"
    static let cancelledAliasMigrationRecoveryNoticeKey =
        "provider.api.cancelledAliasMigrationRecoveryNotice.v1"
    static let externalTransferGrantKey =
        "translation.runtime.externalGrant.v1"
    static let externalTransferGrantGenerationKey =
        "translation.runtime.externalGrantGeneration.v2"
    static let externalTransferRevokedThroughGenerationKey =
        "translation.runtime.externalGrantRevokedThroughGeneration.v1"
    static let externalTransferAuthorizationIntentEpochKey =
        "translation.runtime.externalAuthorizationIntentEpoch.v1"
    static let externalTransferAuthorizationIntentMutationBindingKey =
        "translation.runtime.externalAuthorizationIntentMutationBinding.v1"
    static let legacyExternalTransferEnabledKey =
        "translation.runtime.externalEnabled"

    private static func externalTransferWatermark(
        forKey key: String,
        defaults: UserDefaults
    ) -> UInt64? {
        guard let stored = defaults.object(forKey: key) else { return 0 }
        guard let number = stored as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            let value = number.int64Value
            guard value >= 0 else { return nil }
            return UInt64(value)
        case "C", "S", "I", "L", "Q":
            return number.uint64Value
        default:
            return nil
        }
    }

    private static func decodedExternalTransferGrant(
        defaults: UserDefaults
    ) -> ProviderExternalTransferGrant? {
        guard let data = defaults.data(forKey: externalTransferGrantKey),
              let grant = try? JSONDecoder().decode(
                  ProviderExternalTransferGrant.self,
                  from: data
              ),
              grant.version == ProviderExternalTransferGrant.currentVersion,
              grant.generation > 0 else {
            return nil
        }
        return grant
    }

    private static func currentExternalTransferAuthorizationIntentLocked(
        defaults: UserDefaults
    ) -> ProviderExternalTransferAuthorizationIntent {
        if let rawValue = defaults.string(
            forKey: externalTransferAuthorizationIntentEpochKey
        ), let epoch = UUID(uuidString: rawValue) {
            return ProviderExternalTransferAuthorizationIntent(epoch: epoch)
        }
        let epoch = UUID()
        defaults.set(
            epoch.uuidString,
            forKey: externalTransferAuthorizationIntentEpochKey
        )
        return ProviderExternalTransferAuthorizationIntent(epoch: epoch)
    }

    private enum ExternalTransferAuthorizationIntentMutationBindingState {
        case absent
        case valid(ProviderExternalTransferAuthorizationIntentMutationBinding)
        case malformed
    }

    private enum PendingCredentialCancellationTombstoneState {
        case absent
        case valid(ProviderPendingCredentialCancellationTombstone)
        case malformed
    }

    static func cancelledAliasMigrationRecoveryNoticeState(
        defaults: UserDefaults = .standard
    ) -> ProviderCancelledAliasMigrationRecoveryNoticeState {
        withExternalTransferAdmission {
            guard defaults.object(forKey: cancelledAliasMigrationRecoveryNoticeKey) != nil
            else { return .absent }
            guard let data = defaults.data(forKey: cancelledAliasMigrationRecoveryNoticeKey),
                  let notice = try? JSONDecoder().decode(
                      ProviderCancelledAliasMigrationRecoveryNotice.self,
                      from: data
                  ),
                  notice.version == ProviderCancelledAliasMigrationRecoveryNotice.currentVersion,
                  ProviderCancelledAliasMigrationRecoveryNotice(
                      sourceAlias: notice.sourceAlias,
                      destinationAlias: notice.destinationAlias,
                      credentialRevision: notice.credentialRevision
                  ) == notice else {
                return .malformed
            }
            return .valid(notice)
        }
    }

    @discardableResult
    static func settleCancelledAliasMigrationRecoveryNotice(
        matching expected: ProviderCancelledAliasMigrationRecoveryNotice,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard case let .valid(notice) =
                cancelledAliasMigrationRecoveryNoticeState(defaults: defaults),
                notice == expected,
                let data = defaults.data(forKey: cancelledAliasMigrationRecoveryNoticeKey)
            else { return false }
            defaults.removeObject(forKey: cancelledAliasMigrationRecoveryNoticeKey)
            guard defaults.synchronize() else {
                defaults.set(data, forKey: cancelledAliasMigrationRecoveryNoticeKey)
                _ = defaults.synchronize()
                return false
            }
            return true
        }
    }

    private static func pendingCredentialCancellationTombstoneStateLocked(
        defaults: UserDefaults
    ) -> PendingCredentialCancellationTombstoneState {
        guard defaults.object(forKey: pendingCredentialCancellationTombstoneKey) != nil
        else {
            return .absent
        }
        guard let data = defaults.data(
            forKey: pendingCredentialCancellationTombstoneKey
        ),
              let tombstone = try? JSONDecoder().decode(
                  ProviderPendingCredentialCancellationTombstone.self,
                  from: data
              ),
              tombstone.isValid else {
            return .malformed
        }
        return .valid(tombstone)
    }

    private static func isCancellationTombstonedLocked(
        _ journal: ProviderPendingCredentialMutationJournal,
        defaults: UserDefaults
    ) -> Bool {
        switch pendingCredentialCancellationTombstoneStateLocked(defaults: defaults) {
        case .absent:
            return false
        case .malformed:
            return true
        case let .valid(tombstone):
            return tombstone.matches(journal)
        }
    }

    private static func isCancellationTombstonedLocked(
        _ journal: ProviderPendingAliasMigrationJournal,
        defaults: UserDefaults
    ) -> Bool {
        switch pendingCredentialCancellationTombstoneStateLocked(defaults: defaults) {
        case .absent:
            return false
        case .malformed:
            return true
        case let .valid(tombstone):
            return tombstone.matches(journal)
        }
    }

    private static func externalTransferAuthorizationIntentMutationBindingStateLocked(
        defaults: UserDefaults
    ) -> ExternalTransferAuthorizationIntentMutationBindingState {
        guard defaults.object(
            forKey: externalTransferAuthorizationIntentMutationBindingKey
        ) != nil else {
            return .absent
        }
        guard let data = defaults.data(
            forKey: externalTransferAuthorizationIntentMutationBindingKey
        ),
              let binding = try? JSONDecoder().decode(
                  ProviderExternalTransferAuthorizationIntentMutationBinding.self,
                  from: data
              ),
              binding.version
                == ProviderExternalTransferAuthorizationIntentMutationBinding.currentVersion,
              ProviderExternalTransferAuthorizationIntentMutationBinding(
                  epoch: binding.epoch,
                  credentialRevision: binding.credentialRevision
              ) == binding else {
            return .malformed
        }
        return .valid(binding)
    }

    private static func clearExternalTransferAuthorizationIntentMutationBindingLocked(
        defaults: UserDefaults
    ) {
        // This is only called while rotating the intent. The old epoch is no
        // longer usable, so an explicit new confirmation can safely recover
        // from malformed old binding bytes without treating them as a grant.
        defaults.removeObject(
            forKey: externalTransferAuthorizationIntentMutationBindingKey
        )
    }

    private static func rotateExternalTransferAuthorizationIntentLocked(
        defaults: UserDefaults
    ) {
        defaults.set(
            UUID().uuidString,
            forKey: externalTransferAuthorizationIntentEpochKey
        )
        clearExternalTransferAuthorizationIntentMutationBindingLocked(
            defaults: defaults
        )
    }

    static func captureExternalTransferAuthorizationIntent(
        defaults: UserDefaults = .standard
    ) -> ProviderExternalTransferAuthorizationIntent {
        withExternalTransferAdmission {
            // Every explicit confirmation owns a unique operation epoch.
            // A later confirmation supersedes any older async completion even
            // when both began before a credential mutation reached its worker.
            clearExternalTransferAuthorizationIntentMutationBindingLocked(
                defaults: defaults
            )
            let intent = ProviderExternalTransferAuthorizationIntent(epoch: UUID())
            defaults.set(
                intent.epoch.uuidString,
                forKey: externalTransferAuthorizationIntentEpochKey
            )
            return intent
        }
    }

    static func isExternalTransferAuthorizationIntentCurrent(
        _ intent: ProviderExternalTransferAuthorizationIntent,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            currentExternalTransferAuthorizationIntentLocked(
                defaults: defaults
            ) == intent
        }
    }

    /// Invalidates only the captured intent still owned by the caller. It
    /// leaves an unrelated already-issued grant untouched, except when this
    /// intent owns a pending credential journal that must be tombstoned.
    @discardableResult
    static func invalidateExternalTransferAuthorizationIntent(
        ifCurrent intent: ProviderExternalTransferAuthorizationIntent,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard currentExternalTransferAuthorizationIntentLocked(
                defaults: defaults
            ) == intent else {
                return false
            }
            let binding: ProviderExternalTransferAuthorizationIntentMutationBinding?
            if case let .valid(currentBinding) =
                externalTransferAuthorizationIntentMutationBindingStateLocked(
                    defaults: defaults
                ), currentBinding.epoch == intent.epoch {
                binding = currentBinding
            } else {
                binding = nil
            }
            let pendingAliasJournal = pendingAliasMigration(defaults: defaults)
            let pendingCredentialJournal = pendingCredentialMutation(
                defaults: defaults
            )
            let tombstone: ProviderPendingCredentialCancellationTombstone?
            if let binding,
               let journal = pendingAliasJournal,
               pendingCredentialJournal == nil,
               credentialRevision(defaults: defaults)
                == binding.credentialRevision,
               journal.credentialRevision == binding.credentialRevision {
                tombstone = ProviderPendingCredentialCancellationTombstone(
                    aliasMigration: journal
                )
            } else if let binding,
                      pendingAliasJournal == nil,
                      let journal = pendingCredentialJournal,
                      credentialRevision(defaults: defaults)
                        == binding.credentialRevision,
                      journal.credentialRevision == binding.credentialRevision {
                tombstone = ProviderPendingCredentialCancellationTombstone(
                    credentialMutation: journal
                )
            } else {
                tombstone = nil
            }
            if let tombstone {
                guard let tombstoneData = try? JSONEncoder().encode(tombstone) else {
                    return false
                }
                defaults.set(
                    tombstoneData,
                    forKey: pendingCredentialCancellationTombstoneKey
                )
                // A cancellation that owns an in-flight journal must revoke
                // any visible authorization in the same admission turn. The
                // first synchronization includes the tombstone before the
                // intent rotates, so recovery can never mistake a committed
                // Security write for a user-approved stored credential.
                return revokeExternalTransferGrantLocked(
                    defaults: defaults,
                    invalidatingPendingAuthorizationIntents: true,
                    synchronize: { $0.synchronize() }
                )
            }
            rotateExternalTransferAuthorizationIntentLocked(defaults: defaults)
            // The in-memory epoch is already stale if this fails; returning
            // false prevents callers from treating the invalidation as durable.
            return defaults.synchronize()
        }
    }

    private static func advanceExternalTransferRevocationFenceLocked(
        defaults: UserDefaults,
        invalidatingPendingAuthorizationIntents: Bool
    ) {
        let storedGeneration = externalTransferWatermark(
            forKey: externalTransferGrantGenerationKey,
            defaults: defaults
        )
        let revokedThroughGeneration = externalTransferWatermark(
            forKey: externalTransferRevokedThroughGenerationKey,
            defaults: defaults
        )

        let nextRevokedThroughGeneration: UInt64
        if let storedGeneration, let revokedThroughGeneration {
            let currentGrantGeneration = decodedExternalTransferGrant(
                defaults: defaults
            )?.generation ?? 0
            let currentMaximum = max(
                max(storedGeneration, revokedThroughGeneration),
                currentGrantGeneration
            )
            nextRevokedThroughGeneration = currentMaximum == UInt64.max
                ? UInt64.max
                : currentMaximum + 1
        } else {
            // A malformed monotonic watermark cannot safely be interpreted as
            // zero. Permanently fail closed rather than risk reusing an epoch.
            nextRevokedThroughGeneration = UInt64.max
        }

        defaults.set(
            NSNumber(value: nextRevokedThroughGeneration),
            forKey: externalTransferRevokedThroughGenerationKey
        )
        defaults.set(
            NSNumber(value: nextRevokedThroughGeneration),
            forKey: externalTransferGrantGenerationKey
        )
        if invalidatingPendingAuthorizationIntents {
            rotateExternalTransferAuthorizationIntentLocked(defaults: defaults)
        }
    }

    private static func retireExternalTransferGrantLocked(
        defaults: UserDefaults
    ) {
        let storedGeneration = externalTransferWatermark(
            forKey: externalTransferGrantGenerationKey,
            defaults: defaults
        )
        let revokedThroughGeneration = externalTransferWatermark(
            forKey: externalTransferRevokedThroughGenerationKey,
            defaults: defaults
        )
        let coveredGeneration: UInt64
        if let storedGeneration, let revokedThroughGeneration {
            coveredGeneration = max(
                max(storedGeneration, revokedThroughGeneration),
                decodedExternalTransferGrant(defaults: defaults)?.generation
                    ?? 0
            )
        } else {
            coveredGeneration = UInt64.max
        }
        defaults.set(
            NSNumber(value: coveredGeneration),
            forKey: externalTransferRevokedThroughGenerationKey
        )
        defaults.set(
            NSNumber(value: coveredGeneration),
            forKey: externalTransferGrantGenerationKey
        )
        defaults.removeObject(forKey: externalTransferGrantKey)
        defaults.removeObject(forKey: legacyExternalTransferEnabledKey)
    }

    private static func stageExternalTransferRevocationLocked(
        defaults: UserDefaults
    ) {
        advanceExternalTransferRevocationFenceLocked(
            defaults: defaults,
            invalidatingPendingAuthorizationIntents: false
        )
        defaults.removeObject(forKey: externalTransferGrantKey)
        defaults.removeObject(forKey: legacyExternalTransferEnabledKey)
    }

    private static func revokeExternalTransferGrantLocked(
        defaults: UserDefaults,
        invalidatingPendingAuthorizationIntents: Bool,
        synchronize: (UserDefaults) -> Bool
    ) -> Bool {
        advanceExternalTransferRevocationFenceLocked(
            defaults: defaults,
            invalidatingPendingAuthorizationIntents:
                invalidatingPendingAuthorizationIntents
        )
        // If this first persistence attempt fails, the final synchronization
        // can still durably commit both the fence and the cleanup. In either
        // case the in-process fence is already fail-closed.
        _ = synchronize(defaults)
        defaults.removeObject(forKey: externalTransferGrantKey)
        defaults.removeObject(forKey: legacyExternalTransferEnabledKey)
        return synchronize(defaults)
    }

    private static func revokeForConfigurationChangeLocked(
        defaults: UserDefaults,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent?
    ) -> Bool {
        if let authorizationIntent {
            guard currentExternalTransferAuthorizationIntentLocked(
                defaults: defaults
            ) == authorizationIntent else {
                return false
            }
            return revokeExternalTransferGrantLocked(
                defaults: defaults,
                invalidatingPendingAuthorizationIntents: false,
                synchronize: { $0.synchronize() }
            )
        }
        return revokeExternalTransferGrantLocked(
            defaults: defaults,
            invalidatingPendingAuthorizationIntents: true,
            synchronize: { $0.synchronize() }
        )
    }

    @discardableResult
    static func saveProviderBaseURL(
        _ candidate: String,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> String? {
        withExternalTransferAdmission {
            guard let normalized = ProviderRuntimeGate.normalizedProviderBaseURL(candidate) else {
                return nil
            }
            let previous = defaults.string(forKey: baseURLKey).flatMap {
                ProviderRuntimeGate.normalizedProviderBaseURL($0)
            }
            if previous != normalized,
               !revokeForConfigurationChangeLocked(
                   defaults: defaults,
                   preserving: authorizationIntent
               ) {
                return nil
            }
            defaults.set(normalized, forKey: baseURLKey)
            return normalized
        }
    }

    static func storedProviderBaseURL(defaults: UserDefaults = .standard) -> String {
        withExternalTransferAdmission {
            guard let stored = defaults.string(forKey: baseURLKey) else { return "" }
            guard let normalized = ProviderRuntimeGate.normalizedProviderBaseURL(stored) else {
                defaults.removeObject(forKey: baseURLKey)
                _ = revokeExternalTransferGrant(defaults: defaults)
                return ""
            }
            defaults.set(normalized, forKey: baseURLKey)
            return normalized
        }
    }

    @discardableResult
    static func saveProviderModelName(
        _ candidate: String,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> String? {
        withExternalTransferAdmission {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let previous = defaults.string(forKey: modelNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if previous != normalized,
               !revokeForConfigurationChangeLocked(
                   defaults: defaults,
                   preserving: authorizationIntent
               ) {
                return nil
            }
            defaults.set(normalized, forKey: modelNameKey)
            return normalized
        }
    }

    @discardableResult
    static func saveProviderAccountAlias(
        _ candidate: String,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> String? {
        withExternalTransferAdmission {
            let normalized = normalizedAccountAlias(candidate)
            guard !normalized.isEmpty else { return nil }
            let previous = normalizedAccountAlias(defaults.string(forKey: accountAliasKey) ?? "")
            if previous != normalized,
               !revokeForConfigurationChangeLocked(
                   defaults: defaults,
                   preserving: authorizationIntent
               ) {
                return nil
            }
            defaults.set(normalized, forKey: accountAliasKey)
            return normalized
        }
    }

    static func credentialRevision(
        defaults: UserDefaults = .standard
    ) -> UInt64 {
        (defaults.object(forKey: credentialRevisionKey) as? NSNumber)?
            .uint64Value ?? 0
    }

    /// A UI-owned credential mutation may settle only while the exact
    /// confirmation that prepared its revision remains current. Recovery
    /// paths intentionally pass no intent and retain their crash-recovery
    /// behavior.
    private static func isCredentialMutationAuthorizationCurrentLocked(
        _ authorizationIntent: ProviderExternalTransferAuthorizationIntent?,
        credentialRevision: UInt64,
        defaults: UserDefaults
    ) -> Bool {
        guard let authorizationIntent else { return true }
        guard currentExternalTransferAuthorizationIntentLocked(
            defaults: defaults
        ) == authorizationIntent,
              case let .valid(binding) =
                externalTransferAuthorizationIntentMutationBindingStateLocked(
                    defaults: defaults
                ) else {
            return false
        }
        return binding.epoch == authorizationIntent.epoch
            && binding.credentialRevision == credentialRevision
    }

    /// Checks the exact confirmation/revision pair immediately before a
    /// worker starts a potentially blocking credential operation. It is not a
    /// lease across that operation: a later invalidation must still be able to
    /// win, leaving the pending journal for recovery.
    static func isCredentialMutationAuthorizationCurrent(
        _ authorizationIntent: ProviderExternalTransferAuthorizationIntent?,
        credentialRevision: UInt64,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            isCredentialMutationAuthorizationCurrentLocked(
                authorizationIntent,
                credentialRevision: credentialRevision,
                defaults: defaults
            )
        }
    }

    /// Invalidates every existing grant and durably advances the credential
    /// identity before a mutating Security.framework call may begin.  A
    /// failed Keychain mutation deliberately keeps the revocation: restoring
    /// a prior grant would make a crash boundary indistinguishable from a
    /// completed credential replacement.
    @discardableResult
    static func prepareCredentialMutation(
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> UInt64? {
        withExternalTransferAdmission {
            if let authorizationIntent {
                guard currentExternalTransferAuthorizationIntentLocked(
                    defaults: defaults
                ) == authorizationIntent else {
                    return nil
                }
                switch externalTransferAuthorizationIntentMutationBindingStateLocked(
                    defaults: defaults
                ) {
                case .absent:
                    break
                case .valid, .malformed:
                    // An intent owns at most one credential revision. A
                    // malformed binding is fail-closed rather than recoverable.
                    return nil
                }
            } else {
                // A credential change without the explicit confirmation which
                // owns it supersedes every suspended external-transfer grant.
                rotateExternalTransferAuthorizationIntentLocked(defaults: defaults)
            }
            let current = credentialRevision(defaults: defaults)
            guard current < UInt64.max else {
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return nil
            }
            let next = current + 1
            defaults.set(NSNumber(value: next), forKey: credentialRevisionKey)
            if let authorizationIntent {
                guard let binding =
                    ProviderExternalTransferAuthorizationIntentMutationBinding(
                        epoch: authorizationIntent.epoch,
                        credentialRevision: next
                    ),
                    let data = try? JSONEncoder().encode(binding) else {
                    stageExternalTransferRevocationLocked(defaults: defaults)
                    _ = defaults.synchronize()
                    return nil
                }
                defaults.set(
                    data,
                    forKey: externalTransferAuthorizationIntentMutationBindingKey
                )
            }
            // The next Security.framework mutation has not committed yet. If
            // the process terminates before its recovery journal is written,
            // a fresh process must not present the previous credential as
            // ready under the new revision. Keep the stored alias so the user
            // can still delete or replace the old Keychain item.
            defaults.set("missing", forKey: secretLifecycleStateKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            // The following Security.framework call may commit independently.
            // Do not let it start until the fail-closed revision/grant state is
            // visible to a fresh process.
            guard defaults.synchronize() else { return nil }
            return next
        }
    }

    static func currentExternalTransferTarget(
        defaults: UserDefaults = .standard
    ) -> ProviderExternalTransferTarget? {
        withExternalTransferAdmission { ProviderExternalTransferTarget(
            baseURL: defaults.string(forKey: baseURLKey) ?? "",
            modelName: defaults.string(forKey: modelNameKey) ?? "",
            keychainAccountAlias:
                defaults.string(forKey: accountAliasKey) ?? "",
            credentialRevision: credentialRevision(defaults: defaults)
        ) }
    }

    static func externalTransferGrant(
        defaults: UserDefaults = .standard
    ) -> ProviderExternalTransferGrant? {
        withExternalTransferAdmission {
            guard !hasPendingCredentialRecovery(defaults: defaults) else {
                retireExternalTransferGrantLocked(defaults: defaults)
                _ = defaults.synchronize()
                return nil
            }
            // The legacy Bool was not bound to any destination, model,
            // account, or credential generation. It cannot be upgraded.
            defaults.removeObject(forKey: legacyExternalTransferEnabledKey)
            guard defaults.object(forKey: externalTransferGrantKey) != nil else {
                return nil
            }
            guard let grant = decodedExternalTransferGrant(defaults: defaults),
                  let storedGeneration = externalTransferWatermark(
                      forKey: externalTransferGrantGenerationKey,
                      defaults: defaults
                  ),
                  let revokedThroughGeneration = externalTransferWatermark(
                      forKey: externalTransferRevokedThroughGenerationKey,
                      defaults: defaults
                  ),
                  grant.generation == storedGeneration,
                  grant.generation > revokedThroughGeneration else {
                retireExternalTransferGrantLocked(defaults: defaults)
                _ = defaults.synchronize()
                return nil
            }
            return grant
        }
    }

    static func isExternalTransferAuthorized(
        target: ProviderExternalTransferTarget,
        grant: ProviderExternalTransferGrant? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard !hasPendingCredentialRecovery(defaults: defaults) else {
                retireExternalTransferGrantLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            let effectiveGrant = grant ?? externalTransferGrant(defaults: defaults)
            guard effectiveGrant?.target == target,
                  currentExternalTransferTarget(defaults: defaults) == target else { return false }
            return externalTransferGrant(defaults: defaults) == effectiveGrant
        }
    }

    @discardableResult
    static func issueExternalTransferGrant(
        for target: ProviderExternalTransferTarget,
        authorizationIntent: ProviderExternalTransferAuthorizationIntent,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard currentExternalTransferAuthorizationIntentLocked(
                defaults: defaults
            ) == authorizationIntent,
                  !hasPendingCredentialRecovery(defaults: defaults) else {
                return false
            }
            switch externalTransferAuthorizationIntentMutationBindingStateLocked(
                defaults: defaults
            ) {
            case .absent:
                break
            case .valid(let binding):
                guard binding.epoch == authorizationIntent.epoch,
                      binding.credentialRevision == target.credentialRevision else {
                    return false
                }
            case .malformed:
                return false
            }
            guard let storedGeneration = externalTransferWatermark(
                      forKey: externalTransferGrantGenerationKey,
                      defaults: defaults
                  ),
                  let revokedThroughGeneration = externalTransferWatermark(
                      forKey: externalTransferRevokedThroughGenerationKey,
                      defaults: defaults
                  ) else {
                retireExternalTransferGrantLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            let storedGrantDataExists = defaults.object(
                forKey: externalTransferGrantKey
            ) != nil
            let currentGrant = decodedExternalTransferGrant(defaults: defaults)
            if storedGrantDataExists,
               currentGrant == nil
                || currentGrant?.generation != storedGeneration
                || (currentGrant?.generation ?? 0) <= revokedThroughGeneration {
                retireExternalTransferGrantLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            let previousGeneration = max(
                max(storedGeneration, revokedThroughGeneration),
                currentGrant?.generation ?? 0
            )
            guard previousGeneration < UInt64.max else {
                retireExternalTransferGrantLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            let nextGeneration = previousGeneration + 1
            guard currentExternalTransferTarget(defaults: defaults) == target,
                  let data = try? JSONEncoder().encode(
                      ProviderExternalTransferGrant(
                          target: target,
                          generation: nextGeneration
                      )
                  ) else {
                return false
            }
            // Persist the monotonic counter before making the grant visible.
            // If a process stops between these writes, strict equality on
            // read rejects the older grant rather than reviving it.
            defaults.set(
                NSNumber(value: nextGeneration),
                forKey: externalTransferGrantGenerationKey
            )
            defaults.set(data, forKey: externalTransferGrantKey)
            defaults.removeObject(forKey: legacyExternalTransferEnabledKey)
            rotateExternalTransferAuthorizationIntentLocked(defaults: defaults)
            return true
        }
    }

    /// For an uninterrupted synchronous confirmation handler only. Async
    /// flows must capture the intent before their first suspension and pass it
    /// to `issueExternalTransferGrant` after validating it again.
    @discardableResult
    static func issueExternalTransferGrantForImmediateConfirmation(
        for target: ProviderExternalTransferTarget,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let intent = captureExternalTransferAuthorizationIntent(
            defaults: defaults
        )
        return issueExternalTransferGrant(
            for: target,
            authorizationIntent: intent,
            defaults: defaults
        )
    }

    /// Advances a durable revocation fence before removing the grant. The
    /// first synchronization makes a delayed old grant harmless; the second
    /// confirms the complete cleanup under the app's existing UserDefaults
    /// persistence contract. Neither call claims OS power-loss atomicity.
    @discardableResult
    static func revokeExternalTransferGrant(
        defaults: UserDefaults = .standard,
        synchronize: (UserDefaults) -> Bool = { $0.synchronize() }
    ) -> Bool {
        withExternalTransferAdmission {
            revokeExternalTransferGrantLocked(
                defaults: defaults,
                invalidatingPendingAuthorizationIntents: true,
                synchronize: synchronize
            )
        }
    }

    static func pendingAliasMigration(
        defaults: UserDefaults = .standard
    ) -> ProviderPendingAliasMigrationJournal? {
        withExternalTransferAdmission {
            guard let data = defaults.data(forKey: pendingAliasMigrationJournalKey),
                  let journal = try? JSONDecoder().decode(
                      ProviderPendingAliasMigrationJournal.self,
                      from: data
                  ),
                  journal.version == ProviderPendingAliasMigrationJournal.currentVersion,
                  ProviderPendingAliasMigrationJournal(
                      sourceAlias: journal.sourceAlias,
                      destinationAlias: journal.destinationAlias,
                      credentialRevision: journal.credentialRevision
                  ) == journal else {
                return nil
            }
            return journal
        }
    }

    /// This returns true for invalid journal bytes as well: corrupted crash
    /// state must remain fail-closed until a recovery path can classify it.
    static func hasPendingAliasMigration(
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            defaults.object(forKey: pendingAliasMigrationJournalKey) != nil
        }
    }

    static func pendingCredentialMutation(
        defaults: UserDefaults = .standard
    ) -> ProviderPendingCredentialMutationJournal? {
        withExternalTransferAdmission {
            guard let data = defaults.data(forKey: pendingCredentialMutationJournalKey),
                  let journal = try? JSONDecoder().decode(
                      ProviderPendingCredentialMutationJournal.self,
                      from: data
                  ),
                  journal.version == ProviderPendingCredentialMutationJournal.currentVersion,
                  ProviderPendingCredentialMutationJournal(
                      kind: journal.kind,
                      alias: journal.alias,
                      credentialRevision: journal.credentialRevision
                  ) == journal else {
                return nil
            }
            return journal
        }
    }

    /// Invalid bytes are pending too.  A later recovery must classify them;
    /// admission cannot safely treat corruption as absence.
    static func hasPendingCredentialMutation(
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            defaults.object(forKey: pendingCredentialMutationJournalKey) != nil
        }
    }

    static func hasPendingCredentialRecovery(
        defaults: UserDefaults = .standard
    ) -> Bool {
        hasPendingAliasMigration(defaults: defaults)
            || hasPendingCredentialMutation(defaults: defaults)
    }

    /// Consumes only a cancellation proof for this exact journal. A stale
    /// tombstone from another session is deliberately ignored; malformed
    /// tombstone bytes remain fail-closed until they can be repaired.
    static func consumePendingCredentialCancellationTombstone(
        matching expected: ProviderPendingCredentialMutationJournal,
        defaults: UserDefaults = .standard
    ) -> ProviderPendingCredentialCancellationTombstoneConsumption {
        withExternalTransferAdmission {
            consumePendingCredentialCancellationTombstoneLocked(
                matching: expected,
                journalKey: pendingCredentialMutationJournalKey,
                defaults: defaults
            )
        }
    }

    static func consumePendingCredentialCancellationTombstone(
        matching expected: ProviderPendingAliasMigrationJournal,
        defaults: UserDefaults = .standard
    ) -> ProviderPendingCredentialCancellationTombstoneConsumption {
        withExternalTransferAdmission {
            guard case let .valid(tombstone) =
                pendingCredentialCancellationTombstoneStateLocked(defaults: defaults)
            else {
                switch pendingCredentialCancellationTombstoneStateLocked(
                    defaults: defaults
                ) {
                case .malformed:
                    return .blocked
                case .absent, .valid(_):
                    return .notCancelled
                }
            }
            guard tombstone.matches(expected) else { return .notCancelled }
            guard pendingAliasMigration(defaults: defaults) == expected,
                  credentialRevision(defaults: defaults)
                    == expected.credentialRevision,
                  let journalData = defaults.data(
                      forKey: pendingAliasMigrationJournalKey
                  ),
                  let tombstoneData = defaults.data(
                      forKey: pendingCredentialCancellationTombstoneKey
                  ),
                  let notice = ProviderCancelledAliasMigrationRecoveryNotice(
                      sourceAlias: expected.sourceAlias,
                      destinationAlias: expected.destinationAlias,
                      credentialRevision: expected.credentialRevision
                  ) else {
                return .blocked
            }
            switch cancelledAliasMigrationRecoveryNoticeState(defaults: defaults) {
            case .absent:
                guard let noticeData = try? JSONEncoder().encode(notice) else {
                    return .blocked
                }
                defaults.set(noticeData, forKey: cancelledAliasMigrationRecoveryNoticeKey)
            case let .valid(existing) where existing == notice:
                break
            case .valid, .malformed:
                return .blocked
            }
            defaults.set(
                expected.sourceAlias,
                forKey: storedSecretAccountAliasKey
            )
            defaults.set("missing", forKey: secretLifecycleStateKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            guard defaults.synchronize() else { return .blocked }
            defaults.removeObject(forKey: pendingAliasMigrationJournalKey)
            guard defaults.synchronize() else {
                defaults.set(journalData, forKey: pendingAliasMigrationJournalKey)
                defaults.set(
                    tombstoneData,
                    forKey: pendingCredentialCancellationTombstoneKey
                )
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return .blocked
            }
            defaults.removeObject(forKey: pendingCredentialCancellationTombstoneKey)
            if !defaults.synchronize() {
                // The journal has already been durably removed under a
                // missing lifecycle. Reinstating this no-secret marker keeps
                // a failed cleanup fail-closed without blocking a new save.
                defaults.set(
                    tombstoneData,
                    forKey: pendingCredentialCancellationTombstoneKey
                )
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
            }
            return .consumed
        }
    }

    private static func consumePendingCredentialCancellationTombstoneLocked(
        matching expected: ProviderPendingCredentialMutationJournal,
        journalKey: String,
        defaults: UserDefaults
    ) -> ProviderPendingCredentialCancellationTombstoneConsumption {
        let tombstoneState = pendingCredentialCancellationTombstoneStateLocked(
            defaults: defaults
        )
        guard case let .valid(tombstone) = tombstoneState else {
            switch tombstoneState {
            case .malformed:
                return .blocked
            case .absent, .valid(_):
                return .notCancelled
            }
        }
        guard tombstone.matches(expected) else { return .notCancelled }
        guard pendingCredentialMutation(defaults: defaults) == expected,
              credentialRevision(defaults: defaults) == expected.credentialRevision,
              let journalData = defaults.data(forKey: journalKey),
              let tombstoneData = defaults.data(
                  forKey: pendingCredentialCancellationTombstoneKey
              ) else {
            return .blocked
        }
        defaults.set("missing", forKey: secretLifecycleStateKey)
        stageExternalTransferRevocationLocked(defaults: defaults)
        guard defaults.synchronize() else { return .blocked }
        defaults.removeObject(forKey: journalKey)
        guard defaults.synchronize() else {
            defaults.set(journalData, forKey: journalKey)
            defaults.set(
                tombstoneData,
                forKey: pendingCredentialCancellationTombstoneKey
            )
            stageExternalTransferRevocationLocked(defaults: defaults)
            _ = defaults.synchronize()
            return .blocked
        }
        defaults.removeObject(forKey: pendingCredentialCancellationTombstoneKey)
        if !defaults.synchronize() {
            defaults.set(
                tombstoneData,
                forKey: pendingCredentialCancellationTombstoneKey
            )
            stageExternalTransferRevocationLocked(defaults: defaults)
            _ = defaults.synchronize()
        }
        return .consumed
    }

    @discardableResult
    static func beginPendingCredentialMutation(
        kind: ProviderPendingCredentialMutationKind,
        alias: String,
        credentialRevision: UInt64,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> ProviderPendingCredentialMutationJournal? {
        withExternalTransferAdmission {
            guard isCredentialMutationAuthorizationCurrentLocked(
                      authorizationIntent,
                      credentialRevision: credentialRevision,
                      defaults: defaults
                  ),
                  credentialRevision == self.credentialRevision(defaults: defaults),
                  let journal = ProviderPendingCredentialMutationJournal(
                      kind: kind,
                      alias: alias,
                      credentialRevision: credentialRevision
                  ),
                  let data = try? JSONEncoder().encode(journal) else {
                return nil
            }
            defaults.set(data, forKey: pendingCredentialMutationJournalKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            return defaults.synchronize() ? journal : nil
        }
    }

    /// Commits the defaults side before the worker returns to UI.  This is
    /// synchronous persistence within the app's single-process boundary; it
    /// is not a cross-process atomic transaction with Security.framework.
    @discardableResult
    static func completePendingCredentialMutation(
        _ journal: ProviderPendingCredentialMutationJournal,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard isCredentialMutationAuthorizationCurrentLocked(
                      authorizationIntent,
                      credentialRevision: journal.credentialRevision,
                      defaults: defaults
                  ),
                  pendingCredentialMutation(defaults: defaults) == journal,
                  !isCancellationTombstonedLocked(journal, defaults: defaults),
                  credentialRevision(defaults: defaults) == journal.credentialRevision else {
                return false
            }
            switch journal.kind {
            case .save:
                defaults.set(journal.alias, forKey: accountAliasKey)
                defaults.set(journal.alias, forKey: storedSecretAccountAliasKey)
                defaults.set("user_secret_stored", forKey: secretLifecycleStateKey)
            case .delete:
                defaults.removeObject(forKey: storedSecretAccountAliasKey)
                defaults.set("user_secret_deleted_verified", forKey: secretLifecycleStateKey)
            }
            stageExternalTransferRevocationLocked(defaults: defaults)
            guard defaults.synchronize() else { return false }
            defaults.removeObject(forKey: pendingCredentialMutationJournalKey)
            guard defaults.synchronize() else {
                if let data = try? JSONEncoder().encode(journal) {
                    defaults.set(data, forKey: pendingCredentialMutationJournalKey)
                }
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            return true
        }
    }

    /// A confirmed non-commit must not resurrect the prior grant.  Keep any
    /// stored alias as diagnostic identity while making the lifecycle missing.
    @discardableResult
    static func abandonPendingCredentialMutationAsMissingSecret(
        matching expected: ProviderPendingCredentialMutationJournal,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard isCredentialMutationAuthorizationCurrentLocked(
                      authorizationIntent,
                      credentialRevision: expected.credentialRevision,
                      defaults: defaults
                  ),
                  pendingCredentialMutation(defaults: defaults) == expected,
                  credentialRevision(defaults: defaults) == expected.credentialRevision,
                  let existingData = defaults.data(
                      forKey: pendingCredentialMutationJournalKey
                  ) else { return false }
            defaults.set("missing", forKey: secretLifecycleStateKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            guard defaults.synchronize() else { return false }
            defaults.removeObject(forKey: pendingCredentialMutationJournalKey)
            guard defaults.synchronize() else {
                defaults.set(existingData, forKey: pendingCredentialMutationJournalKey)
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            return true
        }
    }

    @discardableResult
    static func beginPendingAliasMigration(
        sourceAlias: String,
        destinationAlias: String,
        credentialRevision: UInt64,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> ProviderPendingAliasMigrationJournal? {
        withExternalTransferAdmission {
            guard isCredentialMutationAuthorizationCurrentLocked(
                      authorizationIntent,
                      credentialRevision: credentialRevision,
                      defaults: defaults
                  ),
                  credentialRevision == self.credentialRevision(defaults: defaults),
                  let journal = ProviderPendingAliasMigrationJournal(
                      sourceAlias: sourceAlias,
                      destinationAlias: destinationAlias,
                      credentialRevision: credentialRevision
                  ),
                  let data = try? JSONEncoder().encode(journal) else {
                return nil
            }
            defaults.set(data, forKey: pendingAliasMigrationJournalKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            return defaults.synchronize() ? journal : nil
        }
    }

    /// Commits the preference side of an alias migration.  If either durable
    /// write fails, restore the journal in memory and leave authorization
    /// revoked so a later launch can safely retry recovery.
    @discardableResult
    static func completePendingAliasMigration(
        _ journal: ProviderPendingAliasMigrationJournal,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard isCredentialMutationAuthorizationCurrentLocked(
                      authorizationIntent,
                      credentialRevision: journal.credentialRevision,
                      defaults: defaults
                  ),
                  pendingAliasMigration(defaults: defaults) == journal,
                  !isCancellationTombstonedLocked(journal, defaults: defaults),
                  credentialRevision(defaults: defaults) == journal.credentialRevision else {
                return false
            }
            defaults.set(journal.destinationAlias, forKey: accountAliasKey)
            defaults.set(journal.destinationAlias, forKey: storedSecretAccountAliasKey)
            defaults.set("user_secret_stored", forKey: secretLifecycleStateKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            guard defaults.synchronize() else { return false }

            defaults.removeObject(forKey: pendingAliasMigrationJournalKey)
            guard defaults.synchronize() else {
                if let data = try? JSONEncoder().encode(journal) {
                    defaults.set(data, forKey: pendingAliasMigrationJournalKey)
                }
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            return true
        }
    }

    /// Clears only a classified, non-committed journal.  The optional match
    /// prevents a concurrent recovery from clearing a different migration.
    @discardableResult
    static func clearPendingAliasMigration(
        matching expected: ProviderPendingAliasMigrationJournal? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            let existingData = defaults.data(forKey: pendingAliasMigrationJournalKey)
            guard existingData != nil else { return true }
            if let expected, pendingAliasMigration(defaults: defaults) != expected {
                return false
            }
            defaults.removeObject(forKey: pendingAliasMigrationJournalKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            guard defaults.synchronize() else {
                defaults.set(existingData, forKey: pendingAliasMigrationJournalKey)
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            return true
        }
    }

    /// Clears a recovery journal only after Security.framework has proved that
    /// its mutation did not commit.  The prior source alias remains available
    /// for a later explicit deletion, but its lifecycle cannot claim that the
    /// now-revoked credential revision is usable.
    @discardableResult
    static func abandonPendingAliasMigrationAsMissingSecret(
        matching expected: ProviderPendingAliasMigrationJournal,
        preserving authorizationIntent:
            ProviderExternalTransferAuthorizationIntent? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        withExternalTransferAdmission {
            guard isCredentialMutationAuthorizationCurrentLocked(
                      authorizationIntent,
                      credentialRevision: expected.credentialRevision,
                      defaults: defaults
                  ),
                  pendingAliasMigration(defaults: defaults) == expected,
                  credentialRevision(defaults: defaults) == expected.credentialRevision,
                  let existingData = defaults.data(
                      forKey: pendingAliasMigrationJournalKey
                  ) else {
                return false
            }
            defaults.set(expected.sourceAlias, forKey: storedSecretAccountAliasKey)
            defaults.set("missing", forKey: secretLifecycleStateKey)
            stageExternalTransferRevocationLocked(defaults: defaults)
            guard defaults.synchronize() else { return false }

            defaults.removeObject(forKey: pendingAliasMigrationJournalKey)
            guard defaults.synchronize() else {
                defaults.set(existingData, forKey: pendingAliasMigrationJournalKey)
                stageExternalTransferRevocationLocked(defaults: defaults)
                _ = defaults.synchronize()
                return false
            }
            return true
        }
    }

    /// Runs `action` at the same synchronous admission point used by all
    /// authorization-invalidating persistence changes.  Callers must not hop
    /// actors, await, or invoke UI/network callbacks from `action`.
    static func withExternalTransferAdmission<T>(_ action: () throws -> T) rethrows -> T {
        externalTransferAdmissionLock.lock()
        defer { externalTransferAdmissionLock.unlock() }
        return try action()
    }

    /// Atomically checks a target/grant and starts its already-created
    /// operation.  A false return proves that `start` was not called.
    static func admitExternalTransfer(
        target: ProviderExternalTransferTarget,
        grant: ProviderExternalTransferGrant? = nil,
        defaults: UserDefaults = .standard,
        start: () -> Bool
    ) -> Bool {
        withExternalTransferAdmission {
            isExternalTransferAuthorized(target: target, grant: grant, defaults: defaults)
                && start()
        }
    }

    /// Publishes a result only if the exact authorization captured before the
    /// external operation is still current.  `publication` must be tiny and
    /// synchronous: no actor hop, await, network, or keychain work.
    @discardableResult
    static func publishExternalTransfer(
        target: ProviderExternalTransferTarget,
        grant: ProviderExternalTransferGrant?,
        defaults: UserDefaults = .standard,
        publication: () -> Void
    ) -> Bool {
        withExternalTransferAdmission {
            guard isExternalTransferAuthorized(
                target: target,
                grant: grant,
                defaults: defaults
            ) else { return false }
            publication()
            return true
        }
    }

    static func normalizedAccountAlias(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasStoredSecret(
        lifecycleStateRawValue: String,
        storedAccountAlias savedAccountAlias: String,
        currentAccountAlias: String
    ) -> Bool {
        lifecycleStateRawValue == "user_secret_stored"
            && !savedAccountAlias.isEmpty
            && savedAccountAlias == normalizedAccountAlias(currentAccountAlias)
    }

    static func migratedStoredAccountAlias(
        lifecycleStateRawValue: String,
        storedAccountAlias: String,
        currentAccountAlias: String
    ) -> String? {
        let stored = normalizedAccountAlias(storedAccountAlias)
        if !stored.isEmpty {
            return stored
        }
        guard lifecycleStateRawValue == "user_secret_stored" else {
            return nil
        }
        let current = normalizedAccountAlias(currentAccountAlias)
        return current.isEmpty ? nil : current
    }
}

struct ProviderRouter {
    func resolve(_ request: ProviderRouteRequest) -> ProviderRouteResolution {
        if request.executionMode == .localMock, request.configured, request.implemented {
            return resolution(request, ok: true, confirmationLevel: "none_mock", errorCode: nil)
        }

        if let preflightErrorCode = request.preflightErrorCode {
            return resolution(
                request,
                ok: false,
                confirmationLevel: request.requiresExternalTransfer ? "external_transfer" : "none",
                errorCode: preflightErrorCode
            )
        }

        if request.executionMode == .openAICompatible || request.executionMode == .llmBacked {
            if !request.configured || !request.implemented {
                return resolution(
                    request,
                    ok: false,
                    confirmationLevel: request.requiresExternalTransfer ? "external_transfer" : "none",
                    errorCode: .missingConfiguration
                )
            }
            if request.requiresKeychainSecret, request.keychainAccountAlias.isEmpty {
                return resolution(request, ok: false, confirmationLevel: "external_transfer", errorCode: .missingSecret)
            }
            if request.requiresExternalTransfer, !request.externalTransferConfirmed {
                return resolution(request, ok: false, confirmationLevel: "external_transfer", errorCode: .confirmationRequired)
            }
            return resolution(request, ok: true, confirmationLevel: "external_transfer", errorCode: nil)
        }

        switch request.executionMode {
        case .liteLLMGateway, .localCLI, .dedicatedAPI, .appleVision, .multimodalLLM, .cloudOCR:
            return resolution(
                request,
                ok: false,
                confirmationLevel: request.requiresExternalTransfer ? "external_transfer" : "none",
                errorCode: .unsupportedCapability
            )
        case .localMock, .openAICompatible, .llmBacked:
            break
        }

        if request.requiresKeychainSecret, request.keychainAccountAlias.isEmpty {
            return resolution(request, ok: false, confirmationLevel: "external_transfer", errorCode: .missingSecret)
        }

        if !request.configured {
            return resolution(
                request,
                ok: false,
                confirmationLevel: request.requiresExternalTransfer ? "external_transfer" : "none",
                errorCode: .missingConfiguration
            )
        }

        return resolution(
            request,
            ok: false,
            confirmationLevel: request.requiresExternalTransfer ? "external_transfer" : "none",
            errorCode: .unsupportedCapability
        )
    }

    private func resolution(
        _ request: ProviderRouteRequest,
        ok: Bool,
        confirmationLevel: String,
        errorCode: ProviderErrorCode?
    ) -> ProviderRouteResolution {
        let id = UUID().uuidString
        var warnings = ["provider_route_only"]
        if request.requiresExternalTransfer {
            warnings.append("external_transfer_required")
        }
        if errorCode != nil {
            warnings.append("provider_call_not_executed")
        }

        return ProviderRouteResolution(
            id: id,
            ok: ok,
            capability: request.capability,
            profileID: request.profileID,
            executionMode: request.executionMode,
            providerSummary: request.providerSummary,
            confirmationLevel: confirmationLevel,
            errorCode: errorCode,
            auditID: ProviderAuditID.make(
                prefix: "provider_route",
                uuidString: id
            ),
            warnings: warnings
        )
    }
}

extension OpenAIConnectionStatus {
    var providerErrorCode: ProviderErrorCode? {
        switch self {
        case .success:
            nil
        case .missingConfiguration:
            .missingConfiguration
        case .confirmationRequired:
            .confirmationRequired
        case .missingSecret:
            .missingSecret
        case .invalidBaseURL:
            .invalidBaseURL
        case .unauthorized:
            .unauthorized
        case .forbidden:
            .forbidden
        case .rateLimited:
            .rateLimited
        case .serverError, .httpError:
            .providerUnavailable
        case .timeout:
            .timeout
        case .networkError:
            .networkError
        case .invalidResponse:
            .invalidResponse
        case .unsupportedCapability:
            .unsupportedCapability
        }
    }
}
