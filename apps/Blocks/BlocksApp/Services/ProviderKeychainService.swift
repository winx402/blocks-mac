import CryptoKit
import Foundation
import BlocksCore
import Security

enum ProviderKeychainGateAction: String {
    case saveTestSecret = "save_test_secret"
    case rotateTestSecret = "rotate_test_secret"
    case deleteTestSecret = "delete_test_secret"
    case verifyMissing = "verify_missing"
}

enum ProviderUserSecretAction: String {
    case saveOrReplace = "save_or_replace"
    case verifyStored = "verify_stored"
    case deleteStored = "delete_stored"
    case verifyMissing = "verify_missing"
}

struct ProviderKeychainOperationResult: Codable {
    let ok: Bool
    let step: String
    let service: String
    let account: String
    let osStatus: Int
    let found: Bool
    let secretLength: Int?
    let secretSHA256_12: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case ok
        case step
        case service
        case account
        case osStatus = "os_status"
        case found
        case secretLength = "secret_length"
        case secretSHA256_12 = "secret_sha256_12"
        case message
    }
}

struct ProviderKeychainRoundtripReport: Codable {
    let ok: Bool
    let service: String
    let account: String
    let steps: [ProviderKeychainOperationResult]
    let warnings: [String]
}

struct ProviderUserSecretOperationResult: Codable {
    let ok: Bool
    let step: String
    let service: String
    let account: String
    let osStatus: Int
    let found: Bool
    let secretLength: Int?
    let message: String

    enum CodingKeys: String, CodingKey {
        case ok
        case step
        case service
        case account
        case osStatus = "os_status"
        case found
        case secretLength = "secret_length"
        case message
    }
}

struct ProviderUserSecretMaterial {
    let redactedResult: ProviderUserSecretOperationResult
    let credentialRevision: UInt64
    private let secret: String

    init(
        redactedResult: ProviderUserSecretOperationResult,
        credentialRevision: UInt64,
        secret: String
    ) {
        self.redactedResult = redactedResult
        self.credentialRevision = credentialRevision
        self.secret = secret
    }

    var secretLength: Int {
        secret.count
    }

    func withSecret<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(secret)
    }
}

/// The credential identity and secret are committed by one SecItem mutation.
/// A grant whose revision predates this envelope therefore cannot authorize a
/// newly written secret, even if the process exits before preferences flush.
struct ProviderStoredUserSecretEnvelope: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let credentialRevision: UInt64
    let secret: String

    init(credentialRevision: UInt64, secret: String) {
        version = Self.currentVersion
        self.credentialRevision = credentialRevision
        self.secret = secret
    }
}

struct ProviderUserSecretRoundtripReport: Codable {
    let ok: Bool
    let service: String
    let account: String
    let steps: [ProviderUserSecretOperationResult]
    let warnings: [String]
}

enum ProviderKeychainServiceError: Error, LocalizedError, Equatable {
    case aliasMissing
    case secretMissing
    case userSecretNotFound
    case credentialRevisionMissing
    case userSecretRequiresResave

    var errorDescription: String? {
        switch self {
        case .aliasMissing:
            "Keychain account alias is required."
        case .secretMissing:
            "A non-empty provider secret is required."
        case .userSecretNotFound:
            "Provider secret was not found in Keychain."
        case .credentialRevisionMissing:
            "Provider credential revision is required."
        case .userSecretRequiresResave:
            "Provider secret must be saved again before use."
        }
    }
}

enum ProviderAliasMigrationRecoveryState: Equatable {
    case committed
    case notCommitted
    /// Both aliases still contain items. Since the Keychain account update is
    /// atomic, this is the non-destructive outcome when the destination
    /// account already existed and Security.framework rejected the move.
    case destinationConflict
    case inconsistent
}

enum ProviderCredentialMutationRecoveryState: Equatable {
    case committed
    case notCommitted
    case inconsistent
}

protocol ProviderKeychainSecurityAPI {
    func add(_ query: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
}

private struct SystemProviderKeychainSecurityAPI: ProviderKeychainSecurityAPI {
    func add(_ query: CFDictionary) -> OSStatus { SecItemAdd(query, nil) }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }
}

struct ProviderKeychainService {
    static let defaultService = BlocksRuntimeIdentity.providerKeychainService
    static let fixtureSecretV1 = "blocks-p5g-low-sensitive-test-secret-v1"
    static let fixtureSecretV2 = "blocks-p5g-low-sensitive-test-secret-v2"

    let service: String
    private let securityAPI: any ProviderKeychainSecurityAPI

    init(
        service: String = ProviderKeychainService.defaultService,
        securityAPI: any ProviderKeychainSecurityAPI = SystemProviderKeychainSecurityAPI()
    ) {
        self.service = service
        self.securityAPI = securityAPI
    }

    func perform(action: ProviderKeychainGateAction, alias: String) throws -> ProviderKeychainOperationResult {
        let account = try accountName(alias: alias)
        switch action {
        case .saveTestSecret:
            _ = deleteRaw(account: account)
            let addStatus = addRaw(account: account, secret: Self.fixtureSecretV1)
            guard addStatus == errSecSuccess else {
                return result(
                    ok: false,
                    step: action.rawValue,
                    account: account,
                    osStatus: addStatus,
                    found: false,
                    secret: nil,
                    message: "Keychain add failed."
                )
            }
            return readResult(step: action.rawValue, account: account, expectedSecret: Self.fixtureSecretV1)
        case .rotateTestSecret:
            let updateStatus = updateRaw(account: account, secret: Self.fixtureSecretV2)
            guard updateStatus == errSecSuccess else {
                return result(
                    ok: false,
                    step: action.rawValue,
                    account: account,
                    osStatus: updateStatus,
                    found: false,
                    secret: nil,
                    message: "Keychain update failed."
                )
            }
            return readResult(step: action.rawValue, account: account, expectedSecret: Self.fixtureSecretV2)
        case .deleteTestSecret:
            let status = deleteRaw(account: account)
            return result(
                ok: status == errSecSuccess || status == errSecItemNotFound,
                step: action.rawValue,
                account: account,
                osStatus: status,
                found: false,
                secret: nil,
                message: status == errSecSuccess ? "Keychain item deleted." : "Keychain item already missing."
            )
        case .verifyMissing:
            let read = readRaw(account: account)
            return result(
                ok: read.status == errSecItemNotFound,
                step: action.rawValue,
                account: account,
                osStatus: read.status,
                found: read.data != nil,
                secret: read.data.flatMap(secretString),
                message: read.status == errSecItemNotFound ? "Keychain item is missing." : "Keychain item still exists."
            )
        }
    }

    func fixtureRoundtrip(alias: String) -> ProviderKeychainRoundtripReport {
        let account: String
        do {
            account = try accountName(alias: alias)
        } catch {
            return ProviderKeychainRoundtripReport(
                ok: false,
                service: service,
                account: "",
                steps: [
                    result(
                        ok: false,
                        step: "alias_validation",
                        account: "",
                        osStatus: errSecParam,
                        found: false,
                        secret: nil,
                        message: error.localizedDescription
                    )
                ],
                warnings: ["low_sensitive_fixture_only"]
            )
        }

        var steps: [ProviderKeychainOperationResult] = []
        defer {
            _ = deleteRaw(account: account)
        }

        let preDeleteStatus = deleteRaw(account: account)
        steps.append(
            result(
                ok: preDeleteStatus == errSecSuccess || preDeleteStatus == errSecItemNotFound,
                step: "pre_delete_existing",
                account: account,
                osStatus: preDeleteStatus,
                found: false,
                secret: nil,
                message: "Previous test item cleared or absent."
            )
        )

        let addStatus = addRaw(account: account, secret: Self.fixtureSecretV1)
        steps.append(
            result(
                ok: addStatus == errSecSuccess,
                step: "add",
                account: account,
                osStatus: addStatus,
                found: addStatus == errSecSuccess,
                secret: addStatus == errSecSuccess ? Self.fixtureSecretV1 : nil,
                message: "Added v1 low-sensitive test secret."
            )
        )
        steps.append(readResult(step: "read_after_add", account: account, expectedSecret: Self.fixtureSecretV1))

        let updateStatus = updateRaw(account: account, secret: Self.fixtureSecretV2)
        steps.append(
            result(
                ok: updateStatus == errSecSuccess,
                step: "update",
                account: account,
                osStatus: updateStatus,
                found: updateStatus == errSecSuccess,
                secret: updateStatus == errSecSuccess ? Self.fixtureSecretV2 : nil,
                message: "Updated to v2 low-sensitive test secret."
            )
        )
        steps.append(readResult(step: "read_after_update", account: account, expectedSecret: Self.fixtureSecretV2))

        let deleteStatus = deleteRaw(account: account)
        steps.append(
            result(
                ok: deleteStatus == errSecSuccess,
                step: "delete",
                account: account,
                osStatus: deleteStatus,
                found: false,
                secret: nil,
                message: "Deleted low-sensitive test secret."
            )
        )

        let missingRead = readRaw(account: account)
        steps.append(
            result(
                ok: missingRead.status == errSecItemNotFound,
                step: "missing_read",
                account: account,
                osStatus: missingRead.status,
                found: missingRead.data != nil,
                secret: missingRead.data.flatMap(secretString),
                message: "Verified missing after delete."
            )
        )

        return ProviderKeychainRoundtripReport(
            ok: steps.allSatisfy(\.ok),
            service: service,
            account: account,
            steps: steps,
            warnings: ["low_sensitive_fixture_only"]
        )
    }

    func performUserSecret(
        action: ProviderUserSecretAction,
        alias: String,
        secret: String? = nil,
        replacingAlias: String? = nil,
        credentialRevision: UInt64? = nil
    ) throws -> ProviderUserSecretOperationResult {
        let account = try userAccountName(alias: alias)
        switch action {
        case .saveOrReplace:
            let normalized = try normalizedSecret(secret)
            guard let credentialRevision else {
                throw ProviderKeychainServiceError.credentialRevisionMissing
            }
            let encodedSecret = try JSONEncoder().encode(
                ProviderStoredUserSecretEnvelope(
                    credentialRevision: credentialRevision,
                    secret: normalized
                )
            )
            if let replacingAlias {
                let previousAccount = try userAccountName(alias: replacingAlias)
                if previousAccount != account {
                    return replaceUserSecretAccount(
                        previousAccount: previousAccount,
                        account: account,
                        secretData: encodedSecret,
                        secretLength: normalized.count
                    )
                }
            }
            let updateStatus = updateRaw(
                account: account,
                secretData: encodedSecret
            )
            if updateStatus == errSecSuccess {
                return verifiedUserSecretSave(
                    action: action,
                    account: account,
                    secret: normalized
                )
            }
            guard updateStatus == errSecItemNotFound else {
                return userResult(
                    ok: false,
                    step: action.rawValue,
                    account: account,
                    osStatus: updateStatus,
                    found: false,
                    secretLength: nil,
                    message: "Existing provider secret could not be updated."
                )
            }
            let addStatus = addRaw(
                account: account,
                secretData: encodedSecret
            )
            guard addStatus == errSecSuccess else {
                return userResult(
                    ok: false,
                    step: action.rawValue,
                    account: account,
                    osStatus: addStatus,
                    found: false,
                    secretLength: nil,
                    message: "Provider secret save failed."
                )
            }
            return verifiedUserSecretSave(
                action: action,
                account: account,
                secret: normalized
            )
        case .verifyStored:
            let status = existsRaw(account: account)
            return userResult(
                ok: status == errSecSuccess,
                step: action.rawValue,
                account: account,
                osStatus: status,
                found: status == errSecSuccess,
                secretLength: nil,
                message: status == errSecSuccess ? "Provider secret exists." : "Provider secret is missing."
            )
        case .deleteStored:
            let status = deleteRaw(account: account)
            return userResult(
                ok: status == errSecSuccess || status == errSecItemNotFound,
                step: action.rawValue,
                account: account,
                osStatus: status,
                found: false,
                secretLength: nil,
                message: status == errSecSuccess ? "Provider secret deleted." : "Provider secret already missing."
            )
        case .verifyMissing:
            let status = existsRaw(account: account)
            return userResult(
                ok: status == errSecItemNotFound,
                step: action.rawValue,
                account: account,
                osStatus: status,
                found: status == errSecSuccess,
                secretLength: nil,
                message: status == errSecItemNotFound ? "Provider secret is missing." : "Provider secret still exists."
            )
        }
    }

    func readUserSecretForProviderCall(alias: String) throws -> ProviderUserSecretMaterial {
        let account = try userAccountName(alias: alias)
        let read = readRaw(account: account)
        guard read.status == errSecSuccess, let data = read.data else {
            throw ProviderKeychainServiceError.userSecretNotFound
        }
        guard let envelope = try? JSONDecoder().decode(
                  ProviderStoredUserSecretEnvelope.self,
                  from: data
              ),
              envelope.version == ProviderStoredUserSecretEnvelope.currentVersion,
              !envelope.secret.isEmpty else {
            throw ProviderKeychainServiceError.userSecretRequiresResave
        }
        return ProviderUserSecretMaterial(
            redactedResult: userResult(
                ok: true,
                step: "read_for_provider_call",
                account: account,
                osStatus: read.status,
                found: true,
                secretLength: envelope.secret.count,
                message: "Provider secret read for short-lived provider call."
            ),
            credentialRevision: envelope.credentialRevision,
            secret: envelope.secret
        )
    }

    /// Classifies only the two unambiguous outcomes of a crash during a
    /// Security.framework account-alias update.  It never returns secret data
    /// and deliberately leaves ambiguous or access-denied items untouched.
    func aliasMigrationRecoveryState(
        for journal: ProviderPendingAliasMigrationJournal
    ) -> ProviderAliasMigrationRecoveryState {
        guard let sourceAccount = try? userAccountName(alias: journal.sourceAlias),
              let destinationAccount = try? userAccountName(alias: journal.destinationAlias) else {
            return .inconsistent
        }
        let source = readRaw(account: sourceAccount)
        let destination = readRaw(account: destinationAccount)

        switch (source.status, destination.status) {
        case (errSecItemNotFound, errSecSuccess):
            guard isValidMigrationEnvelope(
                destination.data,
                credentialRevision: journal.credentialRevision
            ) else {
                return .inconsistent
            }
            return .committed
        case (errSecSuccess, errSecItemNotFound):
            return .notCommitted
        case (errSecSuccess, errSecSuccess):
            return .destinationConflict
        default:
            return .inconsistent
        }
    }

    /// Classifies a same-alias mutation without exposing secret material.  A
    /// save commits only when its revision envelope is exactly present; a
    /// delete commits only when the item is absent.
    func credentialMutationRecoveryState(
        for journal: ProviderPendingCredentialMutationJournal
    ) -> ProviderCredentialMutationRecoveryState {
        guard let account = try? userAccountName(alias: journal.alias) else {
            return .inconsistent
        }
        let read = readRaw(account: account)
        switch journal.kind {
        case .save:
            switch read.status {
            case errSecSuccess:
                return isValidMigrationEnvelope(
                    read.data,
                    credentialRevision: journal.credentialRevision
                ) ? .committed : .inconsistent
            case errSecItemNotFound:
                return .notCommitted
            default:
                return .inconsistent
            }
        case .delete:
            switch read.status {
            case errSecItemNotFound:
                return .committed
            case errSecSuccess:
                return .notCommitted
            default:
                return .inconsistent
            }
        }
    }

    private func isValidMigrationEnvelope(
        _ data: Data?,
        credentialRevision: UInt64? = nil
    ) -> Bool {
        guard let data,
              let envelope = try? JSONDecoder().decode(
                  ProviderStoredUserSecretEnvelope.self,
                  from: data
              ),
              envelope.version == ProviderStoredUserSecretEnvelope.currentVersion,
              !envelope.secret.isEmpty else {
            return false
        }
        return credentialRevision.map { envelope.credentialRevision == $0 } ?? true
    }

    func userSecretRoundtrip(alias: String, secret: String, replacementSecret: String) -> ProviderUserSecretRoundtripReport {
        let account: String
        do {
            account = try userAccountName(alias: alias)
        } catch {
            return ProviderUserSecretRoundtripReport(
                ok: false,
                service: service,
                account: "",
                steps: [
                    userResult(
                        ok: false,
                        step: "alias_validation",
                        account: "",
                        osStatus: errSecParam,
                        found: false,
                        secretLength: nil,
                        message: error.localizedDescription
                    )
                ],
                warnings: ["low_sensitive_dummy_secret_only"]
            )
        }

        var steps: [ProviderUserSecretOperationResult] = []
        defer {
            _ = deleteRaw(account: account)
        }

        let preDeleteStatus = deleteRaw(account: account)
        steps.append(
            userResult(
                ok: preDeleteStatus == errSecSuccess || preDeleteStatus == errSecItemNotFound,
                step: "pre_delete_existing",
                account: account,
                osStatus: preDeleteStatus,
                found: false,
                secretLength: nil,
                message: "Previous provider secret cleared or absent."
            )
        )

        do {
            steps.append(try performUserSecret(
                action: .saveOrReplace,
                alias: alias,
                secret: secret,
                credentialRevision: 1
            ))
            steps.append(try performUserSecret(action: .verifyStored, alias: alias))
            steps.append(try performUserSecret(
                action: .saveOrReplace,
                alias: alias,
                secret: replacementSecret,
                credentialRevision: 2
            ))
            steps.append(try performUserSecret(action: .verifyStored, alias: alias))
            steps.append(try performUserSecret(action: .deleteStored, alias: alias))
            steps.append(try performUserSecret(action: .verifyMissing, alias: alias))
        } catch {
            steps.append(
                userResult(
                    ok: false,
                    step: "roundtrip_error",
                    account: account,
                    osStatus: errSecParam,
                    found: false,
                    secretLength: nil,
                    message: error.localizedDescription
                )
            )
        }

        return ProviderUserSecretRoundtripReport(
            ok: steps.allSatisfy(\.ok),
            service: service,
            account: account,
            steps: steps,
            warnings: ["low_sensitive_dummy_secret_only", "no_secret_value_or_hash_in_output"]
        )
    }

    private func accountName(alias: String) throws -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderKeychainServiceError.aliasMissing
        }
        return "mock-api:\(trimmed)"
    }

    private func userAccountName(alias: String) throws -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderKeychainServiceError.aliasMissing
        }
        return "openai-compatible:\(trimmed)"
    }

    private func normalizedSecret(_ value: String?) throws -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderKeychainServiceError.secretMissing
        }
        return trimmed
    }

    private func addRaw(account: String, secret: String) -> OSStatus {
        addRaw(account: account, secretData: Data(secret.utf8))
    }

    private func addRaw(account: String, secretData: Data) -> OSStatus {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = secretData
        return securityAPI.add(query as CFDictionary)
    }

    private func updateRaw(account: String, secret: String) -> OSStatus {
        updateRaw(account: account, secretData: Data(secret.utf8))
    }

    private func updateRaw(account: String, secretData: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: secretData
        ]
        return securityAPI.update(
            baseQuery(account: account) as CFDictionary,
            attributes: attributes as CFDictionary
        )
    }

    private func replaceUserSecretAccount(
        previousAccount: String,
        account: String,
        secretData: Data,
        secretLength: Int
    ) -> ProviderUserSecretOperationResult {
        let attributes: [String: Any] = [
            kSecAttrAccount as String: account,
            kSecValueData as String: secretData
        ]
        let status = securityAPI.update(
            baseQuery(account: previousAccount) as CFDictionary,
            attributes: attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            return userResult(
                ok: false,
                step: ProviderUserSecretAction.saveOrReplace.rawValue,
                account: previousAccount,
                osStatus: status,
                found: existsRaw(account: previousAccount) == errSecSuccess,
                secretLength: nil,
                message: "Provider secret alias migration failed."
            )
        }

        return userResult(
            ok: true,
            step: ProviderUserSecretAction.saveOrReplace.rawValue,
            account: account,
            osStatus: errSecSuccess,
            found: true,
            secretLength: secretLength,
            message: "Provider secret alias migrated."
        )
    }

    private func deleteRaw(account: String) -> OSStatus {
        securityAPI.delete(baseQuery(account: account) as CFDictionary)
    }

    private func readRaw(account: String) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = securityAPI.copyMatching(query as CFDictionary, result: &item)
        return (status, item as? Data)
    }

    private func existsRaw(account: String) -> OSStatus {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return securityAPI.copyMatching(query as CFDictionary, result: nil)
    }

    private func verifiedUserSecretSave(
        action: ProviderUserSecretAction,
        account: String,
        secret: String
    ) -> ProviderUserSecretOperationResult {
        let existsStatus = existsRaw(account: account)
        return userResult(
            ok: existsStatus == errSecSuccess,
            step: action.rawValue,
            account: account,
            osStatus: existsStatus,
            found: existsStatus == errSecSuccess,
            secretLength: secret.count,
            message: existsStatus == errSecSuccess ? "Provider secret saved." : "Provider secret save could not be verified."
        )
    }

    private func readResult(step: String, account: String, expectedSecret: String) -> ProviderKeychainOperationResult {
        let read = readRaw(account: account)
        let secret = read.data.flatMap(secretString)
        return result(
            ok: read.status == errSecSuccess && secret == expectedSecret,
            step: step,
            account: account,
            osStatus: read.status,
            found: read.data != nil,
            secret: secret,
            message: secret == expectedSecret ? "Keychain read matched expected test secret." : "Keychain read did not match expected test secret."
        )
    }

    private func baseQuery(account: String) -> [String: Any] {
        BlocksKeychainNamespace.queryForCurrentBuild([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ])
    }

    private func result(
        ok: Bool,
        step: String,
        account: String,
        osStatus: OSStatus,
        found: Bool,
        secret: String?,
        message: String
    ) -> ProviderKeychainOperationResult {
        ProviderKeychainOperationResult(
            ok: ok,
            step: step,
            service: service,
            account: account,
            osStatus: Int(osStatus),
            found: found,
            secretLength: secret?.count,
            secretSHA256_12: secret.map(shortSHA256),
            message: message
        )
    }

    private func userResult(
        ok: Bool,
        step: String,
        account: String,
        osStatus: OSStatus,
        found: Bool,
        secretLength: Int?,
        message: String
    ) -> ProviderUserSecretOperationResult {
        ProviderUserSecretOperationResult(
            ok: ok,
            step: step,
            service: service,
            account: account,
            osStatus: Int(osStatus),
            found: found,
            secretLength: secretLength,
            message: message
        )
    }

    private func secretString(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    private func shortSHA256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}
