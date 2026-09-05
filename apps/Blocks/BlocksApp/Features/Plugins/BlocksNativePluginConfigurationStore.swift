import BlocksCore
import CryptoKit
import Foundation

enum BlocksNativePluginConfigurationStoreError: Error, LocalizedError {
    case invalidPluginID
    case unknownField(String)
    case sensitiveField(String)
    case requiredFieldMissing(String)
    case invalidValue(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPluginID:
            "The plugin identifier is invalid."
        case let .unknownField(fieldID):
            "The plugin configuration field is unknown: \(fieldID)."
        case let .sensitiveField(fieldID):
            "Sensitive plugin configuration must be stored in Keychain: \(fieldID)."
        case let .requiredFieldMissing(fieldID):
            "A required plugin configuration field is missing: \(fieldID)."
        case let .invalidValue(fieldID):
            "The plugin configuration value is invalid: \(fieldID)."
        case .encodingFailed:
            "The plugin configuration could not be encoded."
        }
    }
}

protocol BlocksNativePluginConfigurationStoring: Sendable {
    func configuration(
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws -> [String: JSONValue]

    /// Returns the effective configuration used for validation and execution.
    /// Unlike the editor-facing accessor, every required non-sensitive field
    /// must have a normalized, usable value.
    func activationConfiguration(
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws -> [String: JSONValue]

    func validateForSave(
        _ configuration: [String: JSONValue],
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws

    func save(
        _ configuration: [String: JSONValue],
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws

    func delete(pluginID: String) throws
}

/// Persists only non-sensitive declarative plugin configuration. Secret and
/// session-credential fields are rejected and remain Keychain-only.
struct BlocksNativePluginConfigurationStore:
    BlocksNativePluginConfigurationStoring,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults? = nil,
        keyPrefix: String = "translation.plugin.configuration."
    ) {
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = UserDefaults(
                suiteName:
                    "app.blocks.translation-plugin.configuration."
                    + UUID().uuidString
            )!
        }
        self.keyPrefix = keyPrefix
    }

    func configuration(
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws -> [String: JSONValue] {
        try validatePluginID(pluginID)
        var result = defaultConfiguration(manifest: manifest)
        if let data = defaults.data(forKey: storageKey(pluginID)),
           let stored = try? JSONDecoder().decode(
               [String: JSONValue].self,
               from: data
           ) {
            let allowedFieldIDs = Set(
                manifest.configurationFields.compactMap {
                    $0.type.isSensitive ? nil : $0.id
                }
            )
            result.merge(
                stored.filter { allowedFieldIDs.contains($0.key) }
            ) { _, current in current }
        }
        try validate(
            result,
            manifest: manifest,
            requireRequiredFields: false
        )
        return result.filter { key, _ in
            manifest.configurationFields.contains {
                $0.id == key && !$0.type.isSensitive
            }
        }
    }

    func activationConfiguration(
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws -> [String: JSONValue] {
        let result = try configuration(
            pluginID: pluginID,
            manifest: manifest
        )
        try validate(
            result,
            manifest: manifest,
            requireRequiredFields: true
        )
        return result
    }

    func save(
        _ configuration: [String: JSONValue],
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws {
        try validateForSave(
            configuration,
            pluginID: pluginID,
            manifest: manifest
        )
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: storageKey(pluginID))
    }

    func validateForSave(
        _ configuration: [String: JSONValue],
        pluginID: String,
        manifest: BlocksNativePluginManifest
    ) throws {
        try validatePluginID(pluginID)
        try validate(
            configuration,
            manifest: manifest,
            requireRequiredFields: false
        )
        var effectiveConfiguration = defaultConfiguration(manifest: manifest)
        effectiveConfiguration.merge(configuration) { _, current in current }
        try validate(
            effectiveConfiguration,
            manifest: manifest,
            requireRequiredFields: true
        )
        let data = try JSONEncoder().encode(configuration)
        guard data.count <= 64 * 1_024 else {
            throw BlocksNativePluginConfigurationStoreError.encodingFailed
        }
    }

    func delete(pluginID: String) throws {
        try validatePluginID(pluginID)
        defaults.removeObject(forKey: storageKey(pluginID))
    }

    private func validate(
        _ configuration: [String: JSONValue],
        manifest: BlocksNativePluginManifest,
        requireRequiredFields: Bool
    ) throws {
        let fields = Dictionary(
            uniqueKeysWithValues: manifest.configurationFields.map {
                ($0.id, $0)
            }
        )
        for (fieldID, value) in configuration {
            guard let field = fields[fieldID] else {
                throw BlocksNativePluginConfigurationStoreError
                    .unknownField(fieldID)
            }
            guard !field.type.isSensitive else {
                throw BlocksNativePluginConfigurationStoreError
                    .sensitiveField(fieldID)
            }
            guard Self.value(value, matches: field) else {
                throw BlocksNativePluginConfigurationStoreError
                    .invalidValue(fieldID)
            }
        }
        if requireRequiredFields {
            for field in manifest.configurationFields
                where field.required && !field.type.isSensitive {
                guard let value = configuration[field.id],
                      Self.hasUsableRequiredValue(value, for: field) else {
                    throw BlocksNativePluginConfigurationStoreError
                        .requiredFieldMissing(field.id)
                }
            }
        }
    }

    private static func hasUsableRequiredValue(
        _ value: JSONValue,
        for field: BlocksNativePluginConfigurationField
    ) -> Bool {
        switch (field.type, value) {
        case (.text, .string(let string)),
             (.url, .string(let string)),
             (.choice, .string(let string)):
            return !string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        case (.boolean, .bool):
            return true
        default:
            return false
        }
    }

    private func defaultConfiguration(
        manifest: BlocksNativePluginManifest
    ) -> [String: JSONValue] {
        Dictionary(
            uniqueKeysWithValues: manifest.configurationFields.compactMap {
                field in
                guard !field.type.isSensitive,
                      let value = field.defaultValue else {
                    return nil
                }
                return (field.id, value)
            }
        )
    }

    private static func value(
        _ value: JSONValue,
        matches field: BlocksNativePluginConfigurationField
    ) -> Bool {
        switch (field.type, value) {
        case (.text, .string(let string)), (.url, .string(let string)):
            guard string.count <= (field.maximumLength ?? 16_384) else {
                return false
            }
            if field.type == .url {
                guard let components = URLComponents(string: string),
                      components.scheme?.lowercased() == "https",
                      components.host != nil,
                      components.user == nil,
                      components.password == nil else {
                    return false
                }
            }
            return true
        case (.choice, .string(let selected)):
            return field.choices.contains { $0.value == selected }
        case (.boolean, .bool):
            return true
        case (.secret, _), (.sessionCredential, _):
            return false
        default:
            return false
        }
    }

    private func validatePluginID(_ pluginID: String) throws {
        guard !pluginID.isEmpty,
              pluginID.count <= 160,
              pluginID.range(
                  of: #"^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+$"#,
                  options: .regularExpression
              ) != nil else {
            throw BlocksNativePluginConfigurationStoreError.invalidPluginID
        }
    }

    private func storageKey(_ pluginID: String) -> String {
        keyPrefix + pluginID
    }
}

struct BlocksNativePluginValidationRevision:
    Codable,
    Equatable,
    Sendable
{
    let packageHash: String
    let configurationSHA256: String
    let credentialRevision: UInt64

    static func make(
        packageHash: String,
        configuration: [String: JSONValue],
        credentialRevision: UInt64
    ) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        return Self(
            packageHash: packageHash,
            configurationSHA256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined(),
            credentialRevision: credentialRevision
        )
    }
}

enum BlocksNativePluginValidationStoreError: Error, LocalizedError {
    case invalidPluginID
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidPluginID:
            "The plugin identifier is invalid."
        case .persistenceFailed:
            "The plugin validation state could not be persisted."
        }
    }
}

protocol BlocksNativePluginValidationStoring: Sendable {
    func credentialRevision(pluginID: String) throws -> UInt64
    func validatedRevision(
        pluginID: String
    ) throws -> BlocksNativePluginValidationRevision?
    func markValidated(
        _ revision: BlocksNativePluginValidationRevision,
        pluginID: String
    ) throws
    func invalidate(pluginID: String) throws
    func invalidateAndAdvanceCredentialRevision(
        pluginID: String
    ) throws
    func delete(pluginID: String) throws
}

/// Stores only non-secret validation metadata. The credential revision changes
/// when Keychain material changes, so persisted validation never needs to read,
/// hash, or duplicate a secret value.
final class BlocksNativePluginValidationStore:
    BlocksNativePluginValidationStoring,
    @unchecked Sendable
{
    private struct State: Codable, Equatable {
        var credentialRevision: UInt64 = 0
        var validatedRevision: BlocksNativePluginValidationRevision?
    }

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults? = nil,
        keyPrefix: String = "translation.plugin.validation."
    ) {
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = UserDefaults(
                suiteName:
                    "app.blocks.translation-plugin.validation."
                    + UUID().uuidString
            )!
        }
        self.keyPrefix = keyPrefix
    }

    func credentialRevision(pluginID: String) throws -> UInt64 {
        try lock.withLock {
            try state(pluginID: pluginID).credentialRevision
        }
    }

    func validatedRevision(
        pluginID: String
    ) throws -> BlocksNativePluginValidationRevision? {
        try lock.withLock {
            try state(pluginID: pluginID).validatedRevision
        }
    }

    func markValidated(
        _ revision: BlocksNativePluginValidationRevision,
        pluginID: String
    ) throws {
        try lock.withLock {
            var current = try state(pluginID: pluginID)
            guard current.credentialRevision
                    == revision.credentialRevision else {
                throw BlocksNativePluginValidationStoreError.persistenceFailed
            }
            current.validatedRevision = revision
            try persist(current, pluginID: pluginID)
        }
    }

    func invalidate(pluginID: String) throws {
        try lock.withLock {
            var current = try recoverableState(pluginID: pluginID)
            current.validatedRevision = nil
            try persist(current, pluginID: pluginID)
        }
    }

    func invalidateAndAdvanceCredentialRevision(
        pluginID: String
    ) throws {
        try lock.withLock {
            var current = try recoverableState(pluginID: pluginID)
            guard current.credentialRevision < UInt64.max else {
                throw BlocksNativePluginValidationStoreError.persistenceFailed
            }
            current.credentialRevision += 1
            current.validatedRevision = nil
            try persist(current, pluginID: pluginID)
        }
    }

    func delete(pluginID: String) throws {
        try lock.withLock {
            try validatePluginID(pluginID)
            defaults.removeObject(forKey: storageKey(pluginID))
        }
    }

    private func state(pluginID: String) throws -> State {
        try validatePluginID(pluginID)
        guard let data = defaults.data(forKey: storageKey(pluginID)) else {
            return State()
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data)
        else {
            throw BlocksNativePluginValidationStoreError.persistenceFailed
        }
        return state
    }

    /// Invalidation is a recovery operation. Corrupt validation state is
    /// replaced by a clean, unvalidated state rather than preventing the user
    /// from repairing or uninstalling the plugin.
    private func recoverableState(pluginID: String) throws -> State {
        do {
            return try state(pluginID: pluginID)
        } catch BlocksNativePluginValidationStoreError.persistenceFailed {
            return State()
        }
    }

    private func persist(_ state: State, pluginID: String) throws {
        try validatePluginID(pluginID)
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: storageKey(pluginID))
        guard defaults.data(forKey: storageKey(pluginID)) == data else {
            throw BlocksNativePluginValidationStoreError.persistenceFailed
        }
    }

    private func validatePluginID(_ pluginID: String) throws {
        guard !pluginID.isEmpty,
              pluginID.count <= 160,
              pluginID.range(
                  of: #"^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+$"#,
                  options: .regularExpression
              ) != nil else {
            throw BlocksNativePluginValidationStoreError.invalidPluginID
        }
    }

    private func storageKey(_ pluginID: String) -> String {
        keyPrefix + pluginID
    }
}
