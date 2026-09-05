import Foundation
import Security

protocol BlocksNativePluginSecretStoring: Sendable {
    func value(pluginID: String, secretID: String) throws -> String?
    func contains(pluginID: String, secretID: String) throws -> Bool
    func save(_ value: String, pluginID: String, secretID: String) throws
    func delete(pluginID: String, secretID: String) throws
}

enum BlocksNativePluginSecretStoreError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case missingSecret
    case invalidEncoding
    case valueTooLarge(Int)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "The plugin or secret identifier is invalid."
        case .missingSecret:
            return "The requested plugin secret is not configured."
        case .invalidEncoding:
            return "The plugin secret could not be decoded."
        case let .valueTooLarge(size):
            return "The plugin secret exceeds the 64 KiB limit (\(size) bytes)."
        case let .keychain(status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        }
    }
}

/// Keychain-backed storage scoped to one exact plugin/secret pair. The API
/// deliberately exposes no enumeration operation, so a plugin can only ask
/// the host for a secret declared in its validated manifest.
struct BlocksNativePluginSecretStore: BlocksNativePluginSecretStoring, Sendable {
    static let maximumValueBytes = 64 * 1_024

    private let service: String

    init(service: String = "app.blocks.translation-plugin-secret") {
        self.service = service
    }

    func read(pluginID: String, secretID: String) throws -> String {
        guard let value = try value(pluginID: pluginID, secretID: secretID) else {
            throw BlocksNativePluginSecretStoreError.missingSecret
        }
        return value
    }

    func value(pluginID: String, secretID: String) throws -> String? {
        let account = try account(pluginID: pluginID, secretID: secretID)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw BlocksNativePluginSecretStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw BlocksNativePluginSecretStoreError.invalidEncoding
        }
        guard data.count <= Self.maximumValueBytes else {
            throw BlocksNativePluginSecretStoreError.valueTooLarge(
                data.count
            )
        }
        guard
              let value = String(data: data, encoding: .utf8) else {
            throw BlocksNativePluginSecretStoreError.invalidEncoding
        }
        return value
    }

    func contains(pluginID: String, secretID: String) throws -> Bool {
        try value(pluginID: pluginID, secretID: secretID) != nil
    }

    func save(_ value: String, pluginID: String, secretID: String) throws {
        let account = try account(pluginID: pluginID, secretID: secretID)
        let data = Data(value.utf8)
        guard data.count <= Self.maximumValueBytes else {
            throw BlocksNativePluginSecretStoreError.valueTooLarge(
                data.count
            )
        }
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw BlocksNativePluginSecretStoreError.keychain(updateStatus)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BlocksNativePluginSecretStoreError.keychain(addStatus)
        }
    }

    func delete(pluginID: String, secretID: String) throws {
        let account = try account(pluginID: pluginID, secretID: secretID)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BlocksNativePluginSecretStoreError.keychain(status)
        }
    }

    private func account(pluginID: String, secretID: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !pluginID.isEmpty,
              !secretID.isEmpty,
              pluginID.unicodeScalars.allSatisfy(allowed.contains),
              secretID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw BlocksNativePluginSecretStoreError.invalidIdentifier
        }
        return "\(pluginID)::\(secretID)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
