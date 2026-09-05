import Foundation
import Security

enum TranslationServiceCredentialStoreError: Error, LocalizedError {
    case invalidIdentifier
    case invalidValue
    case missingCredential(String)
    case invalidEncoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "The translation service credential identifier is invalid."
        case .invalidValue:
            "The translation service credential value is invalid."
        case let .missingCredential(fieldID):
            "The required translation service credential is missing: \(fieldID)."
        case .invalidEncoding:
            "The translation service credential could not be decoded."
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        }
    }
}

protocol TranslationServiceCredentialStoring: Sendable {
    func read(profileID: String, fieldID: String) throws -> String
    func value(profileID: String, fieldID: String) throws -> String?
    func contains(profileID: String, fieldID: String) throws -> Bool
    func save(_ value: String, profileID: String, fieldID: String) throws
    func delete(profileID: String, fieldID: String) throws
}

enum TranslationServiceCredentialPolicy {
    static let maximumUTF8Length = 16_384

    static func normalized(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumUTF8Length,
              !containsHeaderControlCharacter(normalized) else {
            throw TranslationServiceCredentialStoreError.invalidValue
        }
        return normalized
    }

    static func validateStored(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Length,
              !containsHeaderControlCharacter(value) else {
            throw TranslationServiceCredentialStoreError.invalidValue
        }
    }

    private static func containsHeaderControlCharacter(
        _ value: String
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0
                || scalar.value == 10
                || scalar.value == 13
        }
    }
}

/// Non-enumerating Keychain storage scoped to one exact service profile and
/// credential field. Callers must already know both identifiers.
struct TranslationServiceCredentialStore:
    TranslationServiceCredentialStoring,
    Sendable
{
    private let service: String

    init(service: String = "app.blocks.translation-service-credential") {
        self.service = service
    }

    func read(profileID: String, fieldID: String) throws -> String {
        guard let value = try value(profileID: profileID, fieldID: fieldID) else {
            throw TranslationServiceCredentialStoreError
                .missingCredential(fieldID)
        }
        return value
    }

    func value(profileID: String, fieldID: String) throws -> String? {
        let account = try account(profileID: profileID, fieldID: fieldID)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw TranslationServiceCredentialStoreError.keychain(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw TranslationServiceCredentialStoreError.invalidEncoding
        }
        try TranslationServiceCredentialPolicy.validateStored(value)
        return value
    }

    func contains(profileID: String, fieldID: String) throws -> Bool {
        try value(profileID: profileID, fieldID: fieldID) != nil
    }

    func save(_ value: String, profileID: String, fieldID: String) throws {
        let normalized = try TranslationServiceCredentialPolicy.normalized(
            value
        )
        let account = try account(profileID: profileID, fieldID: fieldID)
        let data = Data(normalized.utf8)
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TranslationServiceCredentialStoreError.keychain(updateStatus)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TranslationServiceCredentialStoreError.keychain(addStatus)
        }
    }

    func delete(profileID: String, fieldID: String) throws {
        let account = try account(profileID: profileID, fieldID: fieldID)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationServiceCredentialStoreError.keychain(status)
        }
    }

    private func account(profileID: String, fieldID: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
        )
        guard !profileID.isEmpty,
              !fieldID.isEmpty,
              profileID.count <= 160,
              fieldID.count <= 64,
              profileID.unicodeScalars.allSatisfy(allowed.contains),
              fieldID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TranslationServiceCredentialStoreError.invalidIdentifier
        }
        return "\(profileID)::\(fieldID)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
