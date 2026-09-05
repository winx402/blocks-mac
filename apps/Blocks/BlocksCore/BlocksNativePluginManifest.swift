import Foundation

public enum BlocksNativePluginCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case translation
    case ocr
    case hooks
    case actions
    case ui
}

public enum BlocksNativePluginHTTPMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct BlocksNativePluginSecretDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let required: Bool

    public init(id: String, displayName: String, required: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.required = required
    }
}

public enum BlocksNativePluginConfigurationFieldType:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case text
    case url
    case secret
    case boolean
    case choice
    case number
    case multipleChoice = "multiple_choice"
    case slider
    case color
    case file
    case tag
    case sessionCredential = "session_credential"

    public var isSensitive: Bool {
        self == .secret || self == .sessionCredential
    }
}

public struct BlocksNativePluginConfigurationChoice:
    Codable,
    Equatable,
    Sendable
{
    public let value: String
    public let title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

public struct BlocksNativePluginConfigurationFieldLocalization:
    Codable,
    Equatable,
    Sendable
{
    public let title: String
    public let detail: String?
    public let placeholder: String?

    public init(
        title: String,
        detail: String? = nil,
        placeholder: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
    }
}

/// Declarative configuration field rendered by the host. Sensitive field
/// values are stored in Keychain and are never included in the JavaScript
/// invocation configuration dictionary.
public struct BlocksNativePluginConfigurationField:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let type: BlocksNativePluginConfigurationFieldType
    public let title: String
    public let detail: String?
    public let placeholder: String?
    public let required: Bool
    public let defaultValue: JSONValue?
    public let choices: [BlocksNativePluginConfigurationChoice]
    public let maximumLength: Int?
    public let helpURL: String?
    /// Exact HTTPS domains that may receive a session credential. Wildcards
    /// are intentionally unsupported.
    public let allowedDomains: [String]
    public let localizations:
        [String: BlocksNativePluginConfigurationFieldLocalization]

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case detail
        case placeholder
        case required
        case defaultValue = "default"
        case choices
        case maximumLength = "maximum_length"
        case helpURL = "help_url"
        case allowedDomains = "allowed_domains"
        case localizations
    }

    public init(
        id: String,
        type: BlocksNativePluginConfigurationFieldType,
        title: String,
        detail: String? = nil,
        placeholder: String? = nil,
        required: Bool = false,
        defaultValue: JSONValue? = nil,
        choices: [BlocksNativePluginConfigurationChoice] = [],
        maximumLength: Int? = nil,
        helpURL: String? = nil,
        allowedDomains: [String] = [],
        localizations:
            [String: BlocksNativePluginConfigurationFieldLocalization] = [:]
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
        self.required = required
        self.defaultValue = defaultValue
        self.choices = choices
        self.maximumLength = maximumLength
        self.helpURL = helpURL
        self.allowedDomains = allowedDomains
        self.localizations = localizations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(
            BlocksNativePluginConfigurationFieldType.self,
            forKey: .type
        )
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        placeholder = try container.decodeIfPresent(
            String.self,
            forKey: .placeholder
        )
        required = try container.decodeIfPresent(
            Bool.self,
            forKey: .required
        ) ?? false
        defaultValue = try container.decodeIfPresent(
            JSONValue.self,
            forKey: .defaultValue
        )
        choices = try container.decodeIfPresent(
            [BlocksNativePluginConfigurationChoice].self,
            forKey: .choices
        ) ?? []
        maximumLength = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumLength
        )
        helpURL = try container.decodeIfPresent(
            String.self,
            forKey: .helpURL
        )
        allowedDomains = try container.decodeIfPresent(
            [String].self,
            forKey: .allowedDomains
        ) ?? []
        localizations = try container.decodeIfPresent(
            [String: BlocksNativePluginConfigurationFieldLocalization].self,
            forKey: .localizations
        ) ?? [:]
    }

    public func localized(
        locale: Locale = .current
    ) -> BlocksNativePluginConfigurationFieldLocalization {
        let identifier = locale.identifier.replacingOccurrences(
            of: "_",
            with: "-"
        )
        if let exact = localizations[identifier] { return exact }
        if let language = locale.language.languageCode?.identifier,
           let match = localizations.first(where: {
               $0.key == language || $0.key.hasPrefix("\(language)-")
           })?.value {
            return match
        }
        return localizations["en"]
            ?? .init(
                title: title,
                detail: detail,
                placeholder: placeholder
            )
    }
}

public struct BlocksNativePluginPresentationLocalization:
    Codable,
    Equatable,
    Sendable
{
    public let name: String?
    public let summary: String
    public let purpose: String
    public let trigger: String
    public let examples: [String]
    public let dataUsage: String

    private enum CodingKeys: String, CodingKey {
        case name, summary, purpose, trigger, examples
        case dataUsage = "data_usage"
    }

    public init(
        name: String? = nil,
        summary: String,
        purpose: String,
        trigger: String,
        examples: [String] = [],
        dataUsage: String
    ) {
        self.name = name
        self.summary = summary
        self.purpose = purpose
        self.trigger = trigger
        self.examples = examples
        self.dataUsage = dataUsage
    }
}

/// Ordinary-user presentation metadata. Runtime contracts remain in
/// `platform`; this content only explains the plugin without exposing Hook
/// identifiers, schemas, hashes, or host implementation terminology.
public struct BlocksNativePluginPresentation:
    Codable,
    Equatable,
    Sendable
{
    public let summary: String
    public let purpose: String
    public let trigger: String
    public let examples: [String]
    public let dataUsage: String
    public let localizations:
        [String: BlocksNativePluginPresentationLocalization]

    private enum CodingKeys: String, CodingKey {
        case summary, purpose, trigger, examples, localizations
        case dataUsage = "data_usage"
    }

    public init(
        summary: String,
        purpose: String,
        trigger: String,
        examples: [String] = [],
        dataUsage: String,
        localizations:
            [String: BlocksNativePluginPresentationLocalization] = [:]
    ) {
        self.summary = summary
        self.purpose = purpose
        self.trigger = trigger
        self.examples = examples
        self.dataUsage = dataUsage
        self.localizations = localizations
    }

    public func localized(
        fallbackName: String,
        locale: Locale = .current
    ) -> BlocksNativePluginPresentationLocalization {
        let identifier = locale.identifier.replacingOccurrences(
            of: "_",
            with: "-"
        )
        if let exact = localizations[identifier] { return exact }
        if let language = locale.language.languageCode?.identifier,
           let match = localizations.first(where: {
               $0.key == language || $0.key.hasPrefix("\(language)-")
           })?.value {
            return match
        }
        return localizations["en"]
            ?? .init(
                name: fallbackName,
                summary: summary,
                purpose: purpose,
                trigger: trigger,
                examples: examples,
                dataUsage: dataUsage
            )
    }
}

public struct BlocksNativePluginNetworkPermission: Codable, Equatable, Sendable {
    public static let defaultMaximumRequestBytes = 1_048_576
    public static let absoluteMaximumRequestBytes = 4_194_304

    public let domains: [String]
    public let methods: [BlocksNativePluginHTTPMethod]
    public let maximumRequestBytes: Int

    private enum CodingKeys: String, CodingKey {
        case domains
        case methods
        case maximumRequestBytes = "maximum_request_bytes"
    }

    public init(
        domains: [String],
        methods: [BlocksNativePluginHTTPMethod] = [.post],
        maximumRequestBytes: Int = defaultMaximumRequestBytes
    ) {
        self.domains = domains
        self.methods = methods
        self.maximumRequestBytes = maximumRequestBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domains = try container.decode([String].self, forKey: .domains)
        methods = try container.decodeIfPresent(
            [BlocksNativePluginHTTPMethod].self,
            forKey: .methods
        ) ?? [.post]
        maximumRequestBytes = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumRequestBytes
        ) ?? Self.defaultMaximumRequestBytes
    }
}

public enum BlocksNativePluginDataPermission:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case screenshotImage = "screenshot_image"
    case clipboardContent = "clipboard_content"
    case screenshotDocument = "screenshot_document"
    case translationContent = "translation_content"
    case providerMetadata = "provider_metadata"
    case appContext = "app_context"
    case userGrantedFiles = "user_granted_files"
}

public struct BlocksNativePluginPermissions: Codable, Equatable, Sendable {
    public let network: BlocksNativePluginNetworkPermission?
    public let secrets: [BlocksNativePluginSecretDeclaration]
    public let data: [BlocksNativePluginDataPermission]

    private enum CodingKeys: String, CodingKey {
        case network
        case secrets
        case data
    }

    public init(
        network: BlocksNativePluginNetworkPermission? = nil,
        secrets: [BlocksNativePluginSecretDeclaration] = [],
        data: [BlocksNativePluginDataPermission] = []
    ) {
        self.network = network
        self.secrets = secrets
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent(
            BlocksNativePluginNetworkPermission.self,
            forKey: .network
        )
        secrets = try container.decodeIfPresent(
            [BlocksNativePluginSecretDeclaration].self,
            forKey: .secrets
        ) ?? []
        data = try container.decodeIfPresent(
            [BlocksNativePluginDataPermission].self,
            forKey: .data
        ) ?? []
    }
}

public struct BlocksNativePluginTranslationConfiguration: Codable, Equatable, Sendable {
    /// Empty means the plugin accepts any valid BCP-47 source language.
    public let supportedSourceLanguages: [TranslationLanguageTag]
    /// Empty means the plugin accepts any valid BCP-47 target language.
    public let supportedTargetLanguages: [TranslationLanguageTag]
    public let acceptedInputs: [TranslationSourceAcceptedInput]
    /// Schema v3 requires the field to be present in the package manifest.
    /// Older schemas retain their implicit text-only contract.
    public let declaresAcceptedInputs: Bool
    public let contextFields: [TranslationSourceContextField]
    public let requiresExplicitSourceLanguage: Bool
    public let supportsStatus: Bool

    private enum CodingKeys: String, CodingKey {
        case supportedSourceLanguages = "supported_source_languages"
        case supportedTargetLanguages = "supported_target_languages"
        case acceptedInputs = "accepted_inputs"
        case contextFields = "context_fields"
        case requiresExplicitSourceLanguage =
            "requires_explicit_source_language"
        case supportsStatus = "supports_status"
    }

    public init(
        supportedSourceLanguages: [TranslationLanguageTag] = [],
        supportedTargetLanguages: [TranslationLanguageTag] = [],
        acceptedInputs: [TranslationSourceAcceptedInput] = [.text],
        contextFields: [TranslationSourceContextField] = [],
        requiresExplicitSourceLanguage: Bool = false,
        supportsStatus: Bool = false
    ) {
        self.supportedSourceLanguages = supportedSourceLanguages
        self.supportedTargetLanguages = supportedTargetLanguages
        self.acceptedInputs = acceptedInputs
        declaresAcceptedInputs = true
        self.contextFields = contextFields
        self.requiresExplicitSourceLanguage =
            requiresExplicitSourceLanguage
        self.supportsStatus = supportsStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportedSourceLanguages = try container.decodeIfPresent(
            [TranslationLanguageTag].self,
            forKey: .supportedSourceLanguages
        ) ?? []
        supportedTargetLanguages = try container.decodeIfPresent(
            [TranslationLanguageTag].self,
            forKey: .supportedTargetLanguages
        ) ?? []
        declaresAcceptedInputs = container.contains(.acceptedInputs)
        acceptedInputs = try container.decodeIfPresent(
            [TranslationSourceAcceptedInput].self,
            forKey: .acceptedInputs
        ) ?? [.text]
        contextFields = try container.decodeIfPresent(
            [TranslationSourceContextField].self,
            forKey: .contextFields
        ) ?? []
        requiresExplicitSourceLanguage = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresExplicitSourceLanguage
        ) ?? false
        supportsStatus = try container.decodeIfPresent(
            Bool.self,
            forKey: .supportsStatus
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            supportedSourceLanguages,
            forKey: .supportedSourceLanguages
        )
        try container.encode(
            supportedTargetLanguages,
            forKey: .supportedTargetLanguages
        )
        try container.encode(acceptedInputs, forKey: .acceptedInputs)
        try container.encode(contextFields, forKey: .contextFields)
        try container.encode(
            requiresExplicitSourceLanguage,
            forKey: .requiresExplicitSourceLanguage
        )
        try container.encode(supportsStatus, forKey: .supportsStatus)
    }
}

public struct BlocksNativePluginManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...6
    public static let manifestFileName = "manifest.json"

    public let schemaVersion: Int
    public let minimumHostAPIVersion: Int
    public let id: String
    public let displayName: String
    public let version: String
    public let entryPoint: String
    public let capabilities: [BlocksNativePluginCapability]
    public let translation: BlocksNativePluginTranslationConfiguration?
    public let permissions: BlocksNativePluginPermissions
    public let configurationFields: [BlocksNativePluginConfigurationField]
    public let presentation: BlocksNativePluginPresentation?
    public let platform: BlocksPluginPlatformConfiguration?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case minimumHostAPIVersion = "minimum_host_api_version"
        case id
        case displayName = "display_name"
        case version
        case entryPoint = "entry_point"
        case capabilities
        case translation
        case permissions
        case configurationFields = "configuration_fields"
        case presentation
        case platform
    }

    public init(
        // Programmatic callers must opt in to the explicit v3 contract.
        // Keeping the legacy default prevents an existing text-only builder
        // from silently producing an invalid v3 package.
        schemaVersion: Int = 2,
        minimumHostAPIVersion: Int = 1,
        id: String,
        displayName: String,
        version: String,
        entryPoint: String,
        capabilities: [BlocksNativePluginCapability],
        translation: BlocksNativePluginTranslationConfiguration? = nil,
        permissions: BlocksNativePluginPermissions = .init(),
        configurationFields: [BlocksNativePluginConfigurationField] = [],
        presentation: BlocksNativePluginPresentation? = nil,
        platform: BlocksPluginPlatformConfiguration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.minimumHostAPIVersion = minimumHostAPIVersion
        self.id = id
        self.displayName = displayName
        self.version = version
        self.entryPoint = entryPoint
        self.capabilities = capabilities
        self.translation = translation
        self.permissions = permissions
        self.configurationFields = configurationFields
        self.presentation = presentation
        self.platform = platform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        minimumHostAPIVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .minimumHostAPIVersion
        ) ?? 1
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        version = try container.decode(String.self, forKey: .version)
        entryPoint = try container.decode(String.self, forKey: .entryPoint)
        capabilities = try container.decode(
            [BlocksNativePluginCapability].self,
            forKey: .capabilities
        )
        translation = try container.decodeIfPresent(
            BlocksNativePluginTranslationConfiguration.self,
            forKey: .translation
        )
        permissions = try container.decodeIfPresent(
            BlocksNativePluginPermissions.self,
            forKey: .permissions
        ) ?? .init()
        configurationFields = try container.decodeIfPresent(
            [BlocksNativePluginConfigurationField].self,
            forKey: .configurationFields
        ) ?? []
        presentation = try container.decodeIfPresent(
            BlocksNativePluginPresentation.self,
            forKey: .presentation
        )
        platform = try container.decodeIfPresent(
            BlocksPluginPlatformConfiguration.self,
            forKey: .platform
        )
    }
}

public extension BlocksNativePluginManifest {
    /// The complete permission surface shown during installation and stored
    /// with the exact approved package hash. Keeping this list beside the
    /// manifest contract prevents the installer and repository from drifting
    /// into two incompatible permission models.
    var declaredPermissionTokens: [String] {
        var tokens = Set(permissions.secrets.map { "secret:\($0.id)" })
        if let network = permissions.network {
            tokens.insert("network")
            tokens.formUnion(network.methods.map { "method:\($0.rawValue)" })
        }
        tokens.formUnion(permissions.data.map { "data:\($0.rawValue)" })
        if let platform {
            tokens.formUnion(platform.hostActions.map { "host_action:\($0)" })
            tokens.formUnion(platform.actions.map { "action:\($0.id)" })
            tokens.formUnion(platform.importedActions.map {
                "plugin_action:\($0.pluginID):\($0.actionID)"
            })
            tokens.formUnion(platform.hooks.map { "hook:\($0.event.rawValue)" })
            tokens.formUnion(platform.ui.map { "ui:\($0.slot.rawValue)" })
            tokens.formUnion(platform.sharedState.map {
                "shared:\($0.ownerPluginID ?? id):\($0.id):\($0.access.rawValue)"
            })
            if platform.storage != nil {
                tokens.insert(BlocksPluginPermissionToken.privateStorage)
            }
            if platform.hooks.contains(where: \.runsInBackground)
                || !platform.schedules.isEmpty {
                tokens.insert("background")
            }
            if !platform.schedules.isEmpty {
                tokens.insert("background:schedules")
                tokens.formUnion(platform.schedules.map { "schedule:\($0.id)" })
            }
            tokens.formUnion(platform.hooks.compactMap {
                $0.failurePolicy == .failClosed
                    ? "fail_closed:\($0.id)"
                    : nil
            })
        }
        return tokens.sorted()
    }

    /// Schema v1/v2 plugins keep their original text-only invocation contract.
    var effectiveTranslationAcceptedInputs:
        [TranslationSourceAcceptedInput] {
        guard schemaVersion >= 3 else { return [.text] }
        return translation?.acceptedInputs ?? [.text]
    }

    var effectiveTranslationContextFields:
        [TranslationSourceContextField] {
        guard schemaVersion >= 3 else { return [.inputSource] }
        return translation?.contextFields ?? []
    }

    var translationRequiresExplicitSourceLanguage: Bool {
        schemaVersion >= 3
            && (translation?.requiresExplicitSourceLanguage ?? false)
    }

    var translationSupportsStatus: Bool {
        schemaVersion >= 3
            && (translation?.supportsStatus ?? false)
    }
}

public struct BlocksNativePluginInstallationConfirmation: Codable, Equatable, Sendable {
    public let pluginID: String
    public let displayName: String
    public let version: String
    public let packageSHA256: String
    public let isSigned: Bool
    public let capabilities: [BlocksNativePluginCapability]
    public let networkDomains: [String]
    public let networkMethods: [BlocksNativePluginHTTPMethod]
    public let networkMaximumRequestBytes: Int
    public let secretIDs: [String]
    public let dataPermissions: [BlocksNativePluginDataPermission]
    public let translationAcceptedInputs:
        [TranslationSourceAcceptedInput]
    public let translationContextFields:
        [TranslationSourceContextField]
    public let hookEventNames: [BlocksPluginEventName]
    public let hostActionIDs: [String]
    public let importedActionIDs: [String]
    public let uiSlots: [BlocksPluginUISlot]
    public let sharedNamespaces: [String]
    public let includesBackgroundExecution: Bool
    public let includesBackgroundHookExecution: Bool
    public let includesScheduledExecution: Bool
    public let usesPrivateStorage: Bool
    public let failClosedHookIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case pluginID
        case displayName
        case version
        case packageSHA256
        case isSigned
        case capabilities
        case networkDomains
        case networkMethods
        case networkMaximumRequestBytes
        case secretIDs
        case dataPermissions
        case translationAcceptedInputs
        case translationContextFields
        case hookEventNames
        case hostActionIDs
        case importedActionIDs
        case uiSlots
        case sharedNamespaces
        case includesBackgroundExecution
        case includesBackgroundHookExecution
        case includesScheduledExecution
        case usesPrivateStorage
        case failClosedHookIDs
    }

    public init(
        pluginID: String,
        displayName: String,
        version: String,
        packageSHA256: String,
        isSigned: Bool,
        capabilities: [BlocksNativePluginCapability],
        networkDomains: [String],
        networkMethods: [BlocksNativePluginHTTPMethod],
        networkMaximumRequestBytes: Int =
            BlocksNativePluginNetworkPermission.defaultMaximumRequestBytes,
        secretIDs: [String],
        dataPermissions: [BlocksNativePluginDataPermission] = [],
        translationAcceptedInputs:
            [TranslationSourceAcceptedInput] = [],
        translationContextFields:
            [TranslationSourceContextField] = [],
        hookEventNames: [BlocksPluginEventName] = [],
        hostActionIDs: [String] = [],
        importedActionIDs: [String] = [],
        uiSlots: [BlocksPluginUISlot] = [],
        sharedNamespaces: [String] = [],
        includesBackgroundExecution: Bool = false,
        includesBackgroundHookExecution: Bool = false,
        includesScheduledExecution: Bool = false,
        usesPrivateStorage: Bool = false,
        failClosedHookIDs: [String] = []
    ) {
        self.pluginID = pluginID
        self.displayName = displayName
        self.version = version
        self.packageSHA256 = packageSHA256
        self.isSigned = isSigned
        self.capabilities = capabilities
        self.networkDomains = networkDomains
        self.networkMethods = networkMethods
        self.networkMaximumRequestBytes = networkMaximumRequestBytes
        self.secretIDs = secretIDs
        self.dataPermissions = dataPermissions
        self.translationAcceptedInputs = translationAcceptedInputs
        self.translationContextFields = translationContextFields
        self.hookEventNames = hookEventNames
        self.hostActionIDs = hostActionIDs
        self.importedActionIDs = importedActionIDs
        self.uiSlots = uiSlots
        self.sharedNamespaces = sharedNamespaces
        self.includesBackgroundExecution = includesBackgroundExecution
        self.includesBackgroundHookExecution = includesBackgroundHookExecution
        self.includesScheduledExecution = includesScheduledExecution
        self.usesPrivateStorage = usesPrivateStorage
        self.failClosedHookIDs = failClosedHookIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        displayName = try container.decode(
            String.self,
            forKey: .displayName
        )
        version = try container.decode(String.self, forKey: .version)
        packageSHA256 = try container.decode(
            String.self,
            forKey: .packageSHA256
        )
        isSigned = try container.decode(Bool.self, forKey: .isSigned)
        capabilities = try container.decode(
            [BlocksNativePluginCapability].self,
            forKey: .capabilities
        )
        networkDomains = try container.decode(
            [String].self,
            forKey: .networkDomains
        )
        networkMethods = try container.decode(
            [BlocksNativePluginHTTPMethod].self,
            forKey: .networkMethods
        )
        networkMaximumRequestBytes = try container.decodeIfPresent(
            Int.self,
            forKey: .networkMaximumRequestBytes
        ) ?? BlocksNativePluginNetworkPermission.defaultMaximumRequestBytes
        secretIDs = try container.decode(
            [String].self,
            forKey: .secretIDs
        )
        dataPermissions = try container.decodeIfPresent(
            [BlocksNativePluginDataPermission].self,
            forKey: .dataPermissions
        ) ?? []
        translationAcceptedInputs = try container.decodeIfPresent(
            [TranslationSourceAcceptedInput].self,
            forKey: .translationAcceptedInputs
        ) ?? []
        translationContextFields = try container.decodeIfPresent(
            [TranslationSourceContextField].self,
            forKey: .translationContextFields
        ) ?? []
        hookEventNames = try container.decodeIfPresent(
            [BlocksPluginEventName].self,
            forKey: .hookEventNames
        ) ?? []
        hostActionIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .hostActionIDs
        ) ?? []
        importedActionIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .importedActionIDs
        ) ?? []
        uiSlots = try container.decodeIfPresent(
            [BlocksPluginUISlot].self,
            forKey: .uiSlots
        ) ?? []
        sharedNamespaces = try container.decodeIfPresent(
            [String].self,
            forKey: .sharedNamespaces
        ) ?? []
        includesBackgroundExecution = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesBackgroundExecution
        ) ?? false
        includesBackgroundHookExecution = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesBackgroundHookExecution
        ) ?? false
        includesScheduledExecution = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesScheduledExecution
        ) ?? false
        usesPrivateStorage = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesPrivateStorage
        ) ?? false
        failClosedHookIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .failClosedHookIDs
        ) ?? []
    }

    public var requiresRiskConfirmation: Bool {
        !isSigned
            || !networkDomains.isEmpty
            || !secretIDs.isEmpty
            || !dataPermissions.isEmpty
            || !translationContextFields.isEmpty
            || !hookEventNames.isEmpty
            || !hostActionIDs.isEmpty
            || !importedActionIDs.isEmpty
            || !uiSlots.isEmpty
            || !sharedNamespaces.isEmpty
            || includesBackgroundExecution
            || includesBackgroundHookExecution
            || includesScheduledExecution
            || usesPrivateStorage
            || !failClosedHookIDs.isEmpty
    }
}

public enum BlocksNativePluginApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
}

public enum BlocksNativePluginInstallationOrigin:
    String,
    Codable,
    Sendable
{
    case external
    case builtIn = "built_in"
}

public struct BlocksNativePluginMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let packageVersion: String
    public let packageHash: String
    public let manifestJSON: String
    public let capabilities: [BlocksNativePluginCapability]
    public let installedRelativePath: String
    public let installationOrigin: BlocksNativePluginInstallationOrigin
    public let builtInCatalogVersion: String?
    public let isEnabled: Bool
    public let approvalStatus: BlocksNativePluginApprovalStatus
    public let approvedPermissions: [String]
    public let approvedDomains: [String]
    public let debugEnabled: Bool
    public let safetyDisabled: Bool
    public let consecutiveFailureCount: Int
    public let installedAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        displayName: String,
        packageVersion: String,
        packageHash: String,
        manifestJSON: String,
        capabilities: [BlocksNativePluginCapability],
        installedRelativePath: String,
        installationOrigin: BlocksNativePluginInstallationOrigin = .external,
        builtInCatalogVersion: String? = nil,
        isEnabled: Bool,
        approvalStatus: BlocksNativePluginApprovalStatus,
        approvedPermissions: [String],
        approvedDomains: [String],
        debugEnabled: Bool = false,
        safetyDisabled: Bool = false,
        consecutiveFailureCount: Int = 0,
        installedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.packageVersion = packageVersion
        self.packageHash = packageHash
        self.manifestJSON = manifestJSON
        self.capabilities = capabilities
        self.installedRelativePath = installedRelativePath
        self.installationOrigin = installationOrigin
        self.builtInCatalogVersion = builtInCatalogVersion
        self.isEnabled = isEnabled
        self.approvalStatus = approvalStatus
        self.approvedPermissions = approvedPermissions
        self.approvedDomains = approvedDomains
        self.debugEnabled = debugEnabled
        self.safetyDisabled = safetyDisabled
        self.consecutiveFailureCount = consecutiveFailureCount
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }
}

public enum BlocksNativePluginInvocationKind: String, Codable, Sendable {
    case translation
    case ocr
}

public struct BlocksNativePluginInvocation: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let pluginID: String
    public let kind: BlocksNativePluginInvocationKind
    public let input: [String: JSONValue]
    public let configuration: [String: JSONValue]

    public init(
        requestID: UUID = UUID(),
        pluginID: String,
        kind: BlocksNativePluginInvocationKind,
        input: [String: JSONValue],
        configuration: [String: JSONValue] = [:]
    ) {
        self.requestID = requestID
        self.pluginID = pluginID
        self.kind = kind
        self.input = input
        self.configuration = configuration
    }
}

public enum BlocksNativePluginProgressKind: String, Codable, Sendable {
    case progress
    case partialText = "partial_text"
    case status
    case diagnostics
}

public struct BlocksNativePluginProgress: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let kind: BlocksNativePluginProgressKind
    public let code: String?
    public let fraction: Double?
    public let text: String?
    public let metadata: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case requestID
        case kind
        case code
        case fraction
        case text
        case metadata
    }

    public init(
        requestID: UUID,
        kind: BlocksNativePluginProgressKind,
        code: String? = nil,
        fraction: Double? = nil,
        text: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.requestID = requestID
        self.kind = kind
        self.code = code
        self.fraction = fraction
        self.text = text
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        kind = try container.decode(
            BlocksNativePluginProgressKind.self,
            forKey: .kind
        )
        code = try container.decodeIfPresent(String.self, forKey: .code)
        fraction = try container.decodeIfPresent(
            Double.self,
            forKey: .fraction
        )
        text = try container.decodeIfPresent(String.self, forKey: .text)
        metadata = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .metadata
        ) ?? [:]
    }
}

public enum BlocksNativePluginOutputStatus:
    String,
    Codable,
    Sendable
{
    case completed
    case failed
}

public struct BlocksNativePluginOutput: Codable, Equatable, Sendable {
    public let status: BlocksNativePluginOutputStatus
    public let text: String
    public let metadata: [String: JSONValue]
    public let errorCode: String?
    public let errorMessage: String?
    public let isRetryable: Bool

    public init(
        status: BlocksNativePluginOutputStatus = .completed,
        text: String = "",
        metadata: [String: JSONValue] = [:],
        errorCode: String? = nil,
        errorMessage: String? = nil,
        isRetryable: Bool = true
    ) {
        self.status = status
        self.text = text
        self.metadata = metadata
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.isRetryable = isRetryable
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case text
        case metadata
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case isRetryable = "is_retryable"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(
            BlocksNativePluginOutputStatus.self,
            forKey: .status
        ) ?? .completed
        text = try container.decodeIfPresent(
            String.self,
            forKey: .text
        ) ?? ""
        metadata = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .metadata
        ) ?? [:]
        errorCode = try container.decodeIfPresent(
            String.self,
            forKey: .errorCode
        )
        errorMessage = try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )
        isRetryable = try container.decodeIfPresent(
            Bool.self,
            forKey: .isRetryable
        ) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if status != .completed {
            try container.encode(status, forKey: .status)
        }
        try container.encode(text, forKey: .text)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        if !isRetryable {
            try container.encode(isRetryable, forKey: .isRetryable)
        }
    }
}

public struct BlocksNativePluginNetworkRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let url: String
    public let method: BlocksNativePluginHTTPMethod
    public let headers: [String: String]
    public let body: Data?
    public let timeoutSeconds: Double

    public init(
        requestID: UUID = UUID(),
        url: String,
        method: BlocksNativePluginHTTPMethod,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutSeconds: Double = 15
    ) {
        self.requestID = requestID
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BlocksNativePluginNetworkResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        requestID: UUID,
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        self.requestID = requestID
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct BlocksNativePluginRunnerRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let manifest: BlocksNativePluginManifest
    public let entrySource: String
    public let invocation: BlocksNativePluginInvocation
    public let executionTimeLimitSeconds: Double

    public init(
        protocolVersion: Int = BlocksNativePluginXPC.protocolVersion,
        manifest: BlocksNativePluginManifest,
        entrySource: String,
        invocation: BlocksNativePluginInvocation,
        executionTimeLimitSeconds: Double = 30
    ) {
        self.protocolVersion = protocolVersion
        self.manifest = manifest
        self.entrySource = entrySource
        self.invocation = invocation
        self.executionTimeLimitSeconds = executionTimeLimitSeconds
    }
}

public enum BlocksNativePluginRunnerStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

public struct BlocksNativePluginRunnerResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let status: BlocksNativePluginRunnerStatus
    public let output: BlocksNativePluginOutput?
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        requestID: UUID,
        status: BlocksNativePluginRunnerStatus,
        output: BlocksNativePluginOutput? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.output = output
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
