import Foundation

/// Stable identifiers for first-party translation-service configuration
/// templates. A configured external service receives its own profile ID so
/// multiple accounts or endpoints can coexist without changing result order.
public enum TranslationServiceTemplateID: String, Codable, CaseIterable, Sendable {
    case appleLocal = "apple-local"
    case openAICompatible = "openai-compatible"
    case deepLFree = "deepl-free"
    case microsoftTranslator = "microsoft-translator"
    case googleCloudBasic = "google-cloud-basic"
    case alibabaMachineTranslation = "alibaba-machine-translation"
    case libreTranslate = "libretranslate"

    public var allowsMultipleProfiles: Bool {
        self != .appleLocal
    }
}

/// Public Alibaba Cloud Machine Translation regions supported by the
/// first-party adapter. Hosts are an explicit allowlist from the service's
/// endpoint table; a region identifier must never be interpolated into a host.
public enum AlibabaMachineTranslationRegion:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case chinaBeijing = "cn-beijing"
    case chinaShanghai = "cn-shanghai"
    case chinaHangzhou = "cn-hangzhou"
    case chinaShenzhen = "cn-shenzhen"
    case chinaQingdao = "cn-qingdao"
    case chinaHohhot = "cn-huhehaote"
    case chinaZhangjiakou = "cn-zhangjiakou"
    case chinaChengdu = "cn-chengdu"
    case chinaHongKong = "cn-hongkong"
    case singapore = "ap-southeast-1"
    case malaysia = "ap-southeast-3"
    case tokyo = "ap-northeast-1"
    case frankfurt = "eu-central-1"
    case london = "eu-west-1"
    case virginia = "us-east-1"
    case siliconValley = "us-west-1"
    case riyadh = "me-central-1"
    case dubai = "me-east-1"

    public var publicEndpointHost: String {
        switch self {
        case .chinaHangzhou:
            "mt.cn-hangzhou.aliyuncs.com"
        case .singapore:
            "mt.ap-southeast-1.aliyuncs.com"
        case .riyadh:
            "mt.me-central-1.aliyuncs.com"
        case .dubai:
            "alimt.me-east-1.aliyuncs.com"
        case .chinaBeijing,
             .chinaShanghai,
             .chinaShenzhen,
             .chinaQingdao,
             .chinaHohhot,
             .chinaZhangjiakou,
             .chinaChengdu,
             .chinaHongKong,
             .malaysia,
             .tokyo,
             .frankfurt,
             .london,
             .virginia,
             .siliconValley:
            "mt.aliyuncs.com"
        }
    }
}

public enum LibreTranslateBaseURLValidationError:
    Error,
    Equatable,
    Sendable
{
    case invalidURL
    case insecureURL
    case privateNetworkDenied
}

/// Canonical persistence and runtime policy for a LibreTranslate base URL.
///
/// A URL is validated before it reaches SQLite so credentials cannot be
/// smuggled through user-info, query, or fragment components. Runtime endpoint
/// construction consumes the same policy and therefore cannot silently drop a
/// persisted component that was accepted by the settings editor.
public enum LibreTranslateBaseURLPolicy {
    public static func normalizedURLString(
        _ rawValue: String
    ) throws -> String {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.count <= 2_048,
              var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        _ = try validatedExplicitPort(in: components)

        let scheme = components.scheme?.lowercased()
        let isLoopback =
            host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
        guard scheme == "https"
                || (scheme == "http" && isLoopback) else {
            throw LibreTranslateBaseURLValidationError.insecureURL
        }
        guard !isPrivateOrLocal(host) || isLoopback else {
            throw LibreTranslateBaseURLValidationError
                .privateNetworkDenied
        }

        components.scheme = scheme
        components.host = host
        guard let normalized = components.url?.absoluteString,
              !normalized.isEmpty,
              normalized.count <= 2_048 else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        return normalized
    }

    /// Returns a validated explicit port, or `nil` when the authority omits it.
    ///
    /// Foundation also returns `nil` for some malformed explicit ports (for
    /// example an empty port or an integer too large to represent). Inspecting
    /// the authority after the parsed host keeps those inputs distinct from a
    /// genuinely omitted port and prevents callers from silently using a
    /// default port instead.
    public static func validatedExplicitPort(
        in url: URL
    ) throws -> Int? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        return try validatedExplicitPort(in: components)
    }

    public static func operationEndpoint(
        baseURL: String,
        operation: String
    ) throws -> URL {
        guard !operation.isEmpty,
              operation.range(
                of: #"^[A-Za-z0-9._~-]+$"#,
                options: .regularExpression
              ) != nil,
              var components = URLComponents(
                string: try normalizedURLString(baseURL)
              ) else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + "/\(operation)"
        guard let endpoint = components.url else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        return endpoint
    }

    private static func isPrivateOrLocal(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            // The first-party loopback exception is handled above. Other IPv6
            // literals stay denied until a complete routability policy exists.
            return host.contains(":")
        }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    private static func validatedExplicitPort(
        in components: URLComponents
    ) throws -> Int? {
        guard let serialized = components.string,
              let hostRange = components.rangeOfHost else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        let authoritySuffix = serialized[hostRange.upperBound...]
        guard authoritySuffix.first == ":" else {
            return nil
        }
        guard let port = components.port,
              (1...65_535).contains(port) else {
            throw LibreTranslateBaseURLValidationError.invalidURL
        }
        return port
    }
}

/// Persisted non-sensitive translation-service configuration.
///
/// API keys, access-key secrets, cookies, tokens and passwords are never
/// represented by this type. They live in Keychain under the profile ID.
public struct TranslationServiceProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let templateID: TranslationServiceTemplateID
    public let displayName: String
    public let schemaVersion: Int
    public let configuration: [String: JSONValue]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        templateID: TranslationServiceTemplateID,
        displayName: String,
        schemaVersion: Int = 1,
        configuration: [String: JSONValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.templateID = templateID
        self.displayName = displayName
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Runtime service identifiers remain stable across restarts and are
    /// deliberately distinct from built-in singleton identifiers.
    public var serviceID: String {
        switch templateID {
        case .appleLocal:
            "apple-local"
        case .openAICompatible where id == "openai-compatible":
            "openai-compatible"
        default:
            "profile:\(id)"
        }
    }
}

public enum TranslationServiceProfileRepositoryError:
    Error,
    LocalizedError,
    Equatable
{
    case invalidID
    case invalidDisplayName
    case unsupportedSchemaVersion(Int)
    case sensitiveConfigurationKey(String)
    case invalidConfiguration
    case appleLocalMustBeSingleton
    case profileNotFound(String)
    case invalidStoredProfile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidID:
            "The translation service profile identifier is invalid."
        case .invalidDisplayName:
            "The translation service profile name is invalid."
        case let .unsupportedSchemaVersion(version):
            "Unsupported translation service profile schema version \(version)."
        case let .sensitiveConfigurationKey(key):
            "Sensitive translation service configuration must be stored in Keychain: \(key)."
        case .invalidConfiguration:
            "The translation service configuration is invalid."
        case .appleLocalMustBeSingleton:
            "Apple local translation supports only one profile."
        case let .profileNotFound(id):
            "The translation service profile was not found: \(id)."
        case let .invalidStoredProfile(id):
            "The stored translation service profile is invalid: \(id)."
        }
    }
}

public struct TranslationServiceProfileLoadIssue: Equatable, Sendable {
    public let profileID: String
    public let message: String

    public init(profileID: String, message: String) {
        self.profileID = profileID
        self.message = message
    }
}

public struct TranslationServiceProfileLoadResult: Equatable, Sendable {
    public let profiles: [TranslationServiceProfile]
    public let issues: [TranslationServiceProfileLoadIssue]

    public init(
        profiles: [TranslationServiceProfile],
        issues: [TranslationServiceProfileLoadIssue]
    ) {
        self.profiles = profiles
        self.issues = issues
    }
}

public final class TranslationServiceProfileRepository: @unchecked Sendable {
    private static let currentProfileSchemaVersion = 1
    private static let maximumConfigurationBytes = 32 * 1_024
    private static let sensitiveKeyFragments = [
        "apikey",
        "api_key",
        "accesskey",
        "access_key",
        "authorization",
        "bearer",
        "cookie",
        "credential",
        "password",
        "secret",
        "session",
        "token",
    ]

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func list() throws -> [TranslationServiceProfile] {
        try read(whereClause: "", bindings: [])
    }

    /// Loads every valid row while isolating malformed or future-schema rows.
    ///
    /// A single damaged profile must not make unrelated configured services
    /// disappear. Database-level failures still throw because no trustworthy
    /// snapshot can be produced in that case.
    public func listRecoveringInvalidRows()
        throws -> TranslationServiceProfileLoadResult
    {
        try database.connection.withStatement(
            Self.selectSQL(whereClause: ""),
            bindings: []
        ) { statement in
            var profiles: [TranslationServiceProfile] = []
            var issues: [TranslationServiceProfileLoadIssue] = []
            var rowNumber = 0
            while try statement.step() {
                rowNumber += 1
                let rawID = statement.columnString(0)
                    ?? "unknown-row-\(rowNumber)"
                do {
                    profiles.append(try decodeCurrentRow(statement))
                } catch {
                    issues.append(
                        TranslationServiceProfileLoadIssue(
                            profileID: rawID,
                            message: String(
                                error.localizedDescription.prefix(512)
                            )
                        )
                    )
                }
            }
            return TranslationServiceProfileLoadResult(
                profiles: profiles,
                issues: issues
            )
        }
    }

    public func profile(id: String) throws -> TranslationServiceProfile {
        guard let profile = try read(
            whereClause: "WHERE id = ?",
            bindings: [.string(id)]
        ).first else {
            throw TranslationServiceProfileRepositoryError.profileNotFound(id)
        }
        return profile
    }

    @discardableResult
    public func save(
        _ candidate: TranslationServiceProfile,
        now: Date = Date()
    ) throws -> TranslationServiceProfile {
        let profile = try validated(candidate, now: now)
        if profile.templateID == .appleLocal {
            let existingAppleID = try database.connection.firstString(
                """
                SELECT id
                FROM translation_service_profiles
                WHERE template_id = ?
                LIMIT 1
                """,
                bindings: [.string(TranslationServiceTemplateID.appleLocal.rawValue)]
            )
            guard existingAppleID == nil || existingAppleID == profile.id else {
                throw TranslationServiceProfileRepositoryError.appleLocalMustBeSingleton
            }
        }

        let configurationJSON = try Self.encodeConfiguration(
            profile.configuration
        )
        try database.connection.withStatement(
            """
            INSERT INTO translation_service_profiles (
                id,
                template_id,
                display_name,
                schema_version,
                non_sensitive_configuration_json,
                created_at,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                template_id = excluded.template_id,
                display_name = excluded.display_name,
                schema_version = excluded.schema_version,
                non_sensitive_configuration_json =
                    excluded.non_sensitive_configuration_json,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .string(profile.id),
                .string(profile.templateID.rawValue),
                .string(profile.displayName),
                .int(profile.schemaVersion),
                .string(configurationJSON),
                .double(profile.createdAt.timeIntervalSince1970),
                .double(profile.updatedAt.timeIntervalSince1970),
            ]
        ) { statement in
            _ = try statement.step()
        }
        return try self.profile(id: profile.id)
    }

    public func delete(id: String) throws {
        _ = try profile(id: id)
        try database.connection.withStatement(
            "DELETE FROM translation_service_profiles WHERE id = ?",
            bindings: [.string(id)]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func read(
        whereClause: String,
        bindings: [SQLiteBinding]
    ) throws -> [TranslationServiceProfile] {
        try database.connection.withStatement(
            Self.selectSQL(whereClause: whereClause),
            bindings: bindings
        ) { statement in
            var profiles: [TranslationServiceProfile] = []
            while try statement.step() {
                profiles.append(try decodeCurrentRow(statement))
            }
            return profiles
        }
    }

    private static func selectSQL(whereClause: String) -> String {
        """
        SELECT
            id,
            template_id,
            display_name,
            schema_version,
            non_sensitive_configuration_json,
            created_at,
            updated_at
        FROM translation_service_profiles
        \(whereClause)
        ORDER BY created_at, id
        """
    }

    private func decodeCurrentRow(
        _ statement: SQLiteStatement
    ) throws -> TranslationServiceProfile {
        guard let id = statement.columnString(0),
              let rawTemplateID = statement.columnString(1),
              let templateID = TranslationServiceTemplateID(
                  rawValue: rawTemplateID
              ),
              let displayName = statement.columnString(2),
              let configurationJSON = statement.columnString(4) else {
            throw TranslationServiceProfileRepositoryError
                .invalidStoredProfile(
                    statement.columnString(0) ?? "unknown"
                )
        }
        do {
            let profile = TranslationServiceProfile(
                id: id,
                templateID: templateID,
                displayName: displayName,
                schemaVersion: statement.columnInt(3),
                configuration: try Self.decodeConfiguration(
                    configurationJSON
                ),
                createdAt: Date(
                    timeIntervalSince1970: statement.columnDouble(5)
                ),
                updatedAt: Date(
                    timeIntervalSince1970: statement.columnDouble(6)
                )
            )
            return try validated(profile, now: profile.updatedAt)
        } catch let error as TranslationServiceProfileRepositoryError {
            throw error
        } catch {
            throw TranslationServiceProfileRepositoryError
                .invalidStoredProfile(id)
        }
    }

    private func validated(
        _ candidate: TranslationServiceProfile,
        now: Date
    ) throws -> TranslationServiceProfile {
        guard Self.isValidIdentifier(candidate.id) else {
            throw TranslationServiceProfileRepositoryError.invalidID
        }
        let displayName = candidate.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !displayName.isEmpty,
              displayName.count <= 80,
              Self.isSafeDisplayText(displayName) else {
            throw TranslationServiceProfileRepositoryError.invalidDisplayName
        }
        guard candidate.schemaVersion == Self.currentProfileSchemaVersion else {
            throw TranslationServiceProfileRepositoryError
                .unsupportedSchemaVersion(candidate.schemaVersion)
        }
        for key in candidate.configuration.keys {
            let normalized = key.lowercased()
            guard !Self.sensitiveKeyFragments.contains(where: {
                normalized.contains($0)
            }) else {
                throw TranslationServiceProfileRepositoryError
                    .sensitiveConfigurationKey(key)
            }
            guard Self.isValidConfigurationKey(key) else {
                throw TranslationServiceProfileRepositoryError
                    .invalidConfiguration
            }
        }
        let normalizedConfiguration = try Self.normalizedConfiguration(
            candidate.configuration,
            templateID: candidate.templateID
        )
        _ = try Self.encodeConfiguration(normalizedConfiguration)
        return TranslationServiceProfile(
            id: candidate.id,
            templateID: candidate.templateID,
            displayName: displayName,
            schemaVersion: candidate.schemaVersion,
            configuration: normalizedConfiguration,
            createdAt: candidate.createdAt,
            updatedAt: now
        )
    }

    private static func encodeConfiguration(
        _ configuration: [String: JSONValue]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= maximumConfigurationBytes else {
            throw TranslationServiceProfileRepositoryError
                .invalidConfiguration
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeConfiguration(
        _ value: String
    ) throws -> [String: JSONValue] {
        let data = Data(value.utf8)
        guard data.count <= maximumConfigurationBytes else {
            throw TranslationServiceProfileRepositoryError
                .invalidConfiguration
        }
        return try JSONDecoder().decode(
            [String: JSONValue].self,
            from: data
        )
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 160
            && value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isValidConfigurationKey(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.range(
                of: #"^[A-Za-z][A-Za-z0-9._-]*$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isSafeDisplayText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.newlines.contains($0)
        }
    }

    private static func normalizedConfiguration(
        _ configuration: [String: JSONValue],
        templateID: TranslationServiceTemplateID
    ) throws -> [String: JSONValue] {
        let allowedKeys: Set<String>
        switch templateID {
        case .microsoftTranslator:
            allowedKeys = ["region"]
        case .alibabaMachineTranslation:
            allowedKeys = ["region"]
        case .libreTranslate:
            allowedKeys = ["base_url"]
        case .appleLocal,
             .openAICompatible,
             .deepLFree,
             .googleCloudBasic:
            allowedKeys = []
        }
        guard Set(configuration.keys).isSubset(of: allowedKeys) else {
            throw TranslationServiceProfileRepositoryError
                .invalidConfiguration
        }
        var normalizedConfiguration = configuration
        for (key, value) in configuration {
            guard case let .string(string) = value else {
                throw TranslationServiceProfileRepositoryError
                    .invalidConfiguration
            }
            let normalized = string.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty else {
                throw TranslationServiceProfileRepositoryError
                    .invalidConfiguration
            }
            switch (templateID, key) {
            case (.microsoftTranslator, "region"):
                guard normalized.count <= 64,
                      normalized.range(
                          of: #"^[A-Za-z0-9-]+$"#,
                          options: .regularExpression
                      ) != nil else {
                    throw TranslationServiceProfileRepositoryError
                        .invalidConfiguration
                }
            case (.alibabaMachineTranslation, "region"):
                guard AlibabaMachineTranslationRegion(
                    rawValue: normalized
                ) != nil else {
                    throw TranslationServiceProfileRepositoryError
                        .invalidConfiguration
                }
            case (.libreTranslate, "base_url"):
                guard let normalizedURL = try?
                    LibreTranslateBaseURLPolicy
                        .normalizedURLString(normalized) else {
                    throw TranslationServiceProfileRepositoryError
                        .invalidConfiguration
                }
                normalizedConfiguration[key] = .string(normalizedURL)
            default:
                throw TranslationServiceProfileRepositoryError
                    .invalidConfiguration
            }
        }
        return normalizedConfiguration
    }
}
