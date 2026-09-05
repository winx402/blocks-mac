import Foundation

public enum TranslationSourceManagementOperation:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case list
    case scaffold
    case validatePackage = "validate_package"
    case inspectPackage = "inspect_package"
    case inspectInstalled = "inspect_installed"
    case install
    case configure
    case setSecret = "set_secret"
    case test
    case enable
    case disable
    case reorder
    case exportRedacted = "export_redacted"
    case setDebug = "set_debug"
    case clearLogs = "clear_logs"
    case clearSafetyDisable = "clear_safety_disable"
    case remove
}

public struct TranslationSourcePackageSnapshot:
    Codable,
    Equatable,
    Sendable
{
    public static let maximumFileCount = 128
    public static let maximumTotalBytes = 16 * 1_048_576
    public static let maximumPathDepth = 16

    public let files: [String: Data]

    public init(files: [String: Data]) throws {
        try Self.validate(files)
        self.files = files
    }

    public static func validatingPackage(
        at packageURL: URL
    ) throws -> Self {
        let package = try BlocksNativePluginPackageValidator()
            .validate(directory: packageURL)
        return try Self(files: package.files)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let files = try container.decode([String: Data].self)
        try Self.validate(files)
        self.files = files
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(files)
    }

    private static func validate(_ files: [String: Data]) throws {
        guard !files.isEmpty,
              files.count <= maximumFileCount else {
            throw TranslationSourceActionValidationError.invalidPackageSnapshot
        }
        var totalBytes = 0
        for (path, data) in files {
            let components = path.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard !path.hasPrefix("/"),
                  !components.isEmpty,
                  components.count <= maximumPathDepth,
                  components.allSatisfy({
                      !$0.isEmpty
                          && $0 != "."
                          && $0 != ".."
                          && !$0.contains("\0")
                  }) else {
                throw TranslationSourceActionValidationError
                    .invalidPackageSnapshot
            }
            totalBytes += data.count
            guard totalBytes <= maximumTotalBytes else {
                throw TranslationSourceActionValidationError
                    .invalidPackageSnapshot
            }
        }
        guard files[BlocksNativePluginManifest.manifestFileName] != nil else {
            throw TranslationSourceActionValidationError.invalidPackageSnapshot
        }
    }
}

public struct TranslationSourceManagementActionInput:
    Codable,
    Equatable,
    Sendable
{
    public let operation: TranslationSourceManagementOperation
    public let sourceID: String?
    public let package: TranslationSourcePackageSnapshot?
    public let confirmationSHA256: String?
    public let configuration: [String: JSONValue]?
    public let secretID: String?
    public let secretValue: String?
    public let testText: String?
    public let testImage: TranslationSourceEncodedImage?
    public let capability: BlocksNativePluginCapability?
    public let orderedSourceIDs: [String]?
    public let confirmed: Bool
    public let scaffoldID: String?
    public let scaffoldDisplayName: String?
    /// Generic plugin management uses the same isolated broker transport but
    /// must not alter the translation result-source order.
    public let pluginScope: Bool?
    public let debugEnabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case operation
        case sourceID = "source_id"
        case package
        case confirmationSHA256 = "confirmation_sha256"
        case configuration
        case secretID = "secret_id"
        case secretValue = "secret_value"
        case testText = "test_text"
        case testImage = "test_image"
        case capability
        case orderedSourceIDs = "ordered_source_ids"
        case confirmed
        case scaffoldID = "scaffold_id"
        case scaffoldDisplayName = "scaffold_display_name"
        case pluginScope = "plugin_scope"
        case debugEnabled = "debug_enabled"
    }

    public init(
        operation: TranslationSourceManagementOperation,
        sourceID: String? = nil,
        package: TranslationSourcePackageSnapshot? = nil,
        confirmationSHA256: String? = nil,
        configuration: [String: JSONValue]? = nil,
        secretID: String? = nil,
        secretValue: String? = nil,
        testText: String? = nil,
        testImage: TranslationSourceEncodedImage? = nil,
        capability: BlocksNativePluginCapability? = nil,
        orderedSourceIDs: [String]? = nil,
        confirmed: Bool = false,
        scaffoldID: String? = nil,
        scaffoldDisplayName: String? = nil,
        pluginScope: Bool? = nil,
        debugEnabled: Bool? = nil
    ) {
        self.operation = operation
        self.sourceID = sourceID
        self.package = package
        self.confirmationSHA256 = confirmationSHA256
        self.configuration = configuration
        self.secretID = secretID
        self.secretValue = secretValue
        self.testText = testText
        self.testImage = testImage
        self.capability = capability
        self.orderedSourceIDs = orderedSourceIDs
        self.confirmed = confirmed
        self.scaffoldID = scaffoldID
        self.scaffoldDisplayName = scaffoldDisplayName
        self.pluginScope = pluginScope
        self.debugEnabled = debugEnabled
    }

    public func withPluginScope(_ enabled: Bool) -> Self {
        .init(
            operation: operation,
            sourceID: sourceID,
            package: package,
            confirmationSHA256: confirmationSHA256,
            configuration: configuration,
            secretID: secretID,
            secretValue: secretValue,
            testText: testText,
            testImage: testImage,
            capability: capability,
            orderedSourceIDs: orderedSourceIDs,
            confirmed: confirmed,
            scaffoldID: scaffoldID,
            scaffoldDisplayName: scaffoldDisplayName,
            pluginScope: enabled,
            debugEnabled: debugEnabled
        )
    }
}

public struct TranslationSourceSummary:
    Codable,
    Equatable,
    Sendable
{
    public let sourceID: String
    public let pluginID: String?
    public let displayName: String
    public let kind: String
    public let version: String?
    public let availability: String
    public let isEnabled: Bool
    public let isPluginRuntimeEnabled: Bool?
    public let isValidated: Bool?
    public let capabilities: [BlocksNativePluginCapability]

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case pluginID = "plugin_id"
        case displayName = "display_name"
        case kind
        case version
        case availability
        case isEnabled = "is_enabled"
        case isPluginRuntimeEnabled = "is_plugin_runtime_enabled"
        case isValidated = "is_validated"
        case capabilities
    }

    public init(
        sourceID: String,
        pluginID: String? = nil,
        displayName: String,
        kind: String,
        version: String? = nil,
        availability: String,
        isEnabled: Bool,
        isPluginRuntimeEnabled: Bool? = nil,
        isValidated: Bool? = nil,
        capabilities: [BlocksNativePluginCapability] = []
    ) {
        self.sourceID = sourceID
        self.pluginID = pluginID
        self.displayName = displayName
        self.kind = kind
        self.version = version
        self.availability = availability
        self.isEnabled = isEnabled
        self.isPluginRuntimeEnabled = isPluginRuntimeEnabled
        self.isValidated = isValidated
        self.capabilities = capabilities
    }
}

public struct TranslationSourcePackageInspection:
    Codable,
    Equatable,
    Sendable
{
    public let manifest: BlocksNativePluginManifest
    public let confirmation: BlocksNativePluginInstallationConfirmation

    public init(
        manifest: BlocksNativePluginManifest,
        confirmation: BlocksNativePluginInstallationConfirmation
    ) {
        self.manifest = manifest
        self.confirmation = confirmation
    }
}

public struct TranslationSourceScaffold:
    Codable,
    Equatable,
    Sendable
{
    public let suggestedDirectoryName: String
    public let files: [String: Data]

    private enum CodingKeys: String, CodingKey {
        case suggestedDirectoryName = "suggested_directory_name"
        case files
    }

    public init(
        suggestedDirectoryName: String,
        files: [String: Data]
    ) {
        self.suggestedDirectoryName = suggestedDirectoryName
        self.files = files
    }
}

public enum BlocksNativePluginScaffoldFactory {
    public static func make(
        id: String,
        displayName: String,
        pluginScope: Bool
    ) throws -> TranslationSourceScaffold {
        let normalizedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedName.isEmpty else {
            throw BlocksNativePluginValidationError.invalidDisplayName
        }

        let manifest: BlocksNativePluginManifest
        let source: String
        if pluginScope {
            manifest = BlocksNativePluginManifest(
                schemaVersion: 6,
                id: id,
                displayName: normalizedName,
                version: "0.1.0",
                entryPoint: "main.js",
                capabilities: [.hooks, .actions],
                presentation: BlocksNativePluginPresentation(
                    summary: "A starter Blocks plugin.",
                    purpose: "Shows how to receive a host event and expose a manual action.",
                    trigger: "Runs after Blocks launches or when its Run action is invoked.",
                    examples: ["Receive an app launch event and return a structured result."],
                    dataUsage: "Uses only the event data explicitly provided by Blocks."
                ),
                platform: BlocksPluginPlatformConfiguration(
                    hooks: [
                        BlocksPluginHookSubscription(
                            id: "app-launched",
                            event: .appLaunched,
                            entryFunction: "handleAppLaunched"
                        ),
                    ],
                    actions: [
                        BlocksPluginActionDeclaration(
                            id: "run",
                            displayName: "Run",
                            entryFunction: "performAction"
                        ),
                    ],
                    storage: BlocksPluginStorageDeclaration(
                        kinds: [.keyValue, .document, .queue]
                    )
                )
            )
            source = """
            function handleAppLaunched(event, context) {
              return { diagnostics: [{ level: "info", code: "ready", message: "Plugin is ready." }] };
            }

            function performAction(input, context) {
              return {
                output: { received: input || {} },
                diagnostics: [{ level: "info", code: "completed", message: "Action completed." }]
              };
            }
            """
        } else {
            manifest = BlocksNativePluginManifest(
                schemaVersion: 3,
                id: id,
                displayName: normalizedName,
                version: "0.1.0",
                entryPoint: "main.js",
                capabilities: [.translation],
                translation: BlocksNativePluginTranslationConfiguration(
                    acceptedInputs: [.text],
                    contextFields: [],
                    supportsStatus: true
                )
            )
            source = """
            function translate(input, context) {
              if (!input || typeof input.text !== "string" || input.text.length === 0) {
                throw new Error("Source text is required.");
              }
              blocks.progress({ kind: "status", code: "processing" });
              return {
                status: "completed",
                text: input.text,
                metadata: { scaffold: true }
              };
            }
            """
        }

        try BlocksNativePluginPackageValidator().validate(
            manifest: manifest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return TranslationSourceScaffold(
            suggestedDirectoryName: "\(id).blocksplugin",
            files: pluginScope
                ? [
                    BlocksNativePluginManifest.manifestFileName:
                        try encoder.encode(manifest),
                    "main.js": Data(source.utf8),
                    "README.md": Data(Self.pluginReadme.utf8),
                    "Tests/app-launched.event.json": Data(
                        Self.pluginEventFixture.utf8
                    ),
                    "Tests/app-launched.expected.json": Data(
                        Self.pluginExpectedFixture.utf8
                    ),
                ]
                : [
                    BlocksNativePluginManifest.manifestFileName:
                        try encoder.encode(manifest),
                    "main.js": Data(source.utf8),
                ]
        )
    }

    private static let pluginReadme = """
    # Blocks Plugin

    Validate and test this package before installation:

    ```sh
    blocks plugin validate --strict .
    blocks plugin test . --event Tests/app-launched.event.json --expect Tests/app-launched.expected.json
    blocks plugin pack . --output Plugin.blocksplugin
    ```

    Query the current host contract with `blocks plugin api list --json`.
    """

    private static let pluginEventFixture = """
    {
      "name": "app.launched",
      "payload": {},
      "source": { "fixture": true }
    }
    """

    private static let pluginExpectedFixture = """
    {
      "diagnostic_codes": ["ready"],
      "host_actions": []
    }
    """
}

public struct TranslationSourceConnectionTestSummary:
    Codable,
    Equatable,
    Sendable
{
    public let sourceID: String
    public let capability: BlocksNativePluginCapability
    public let succeeded: Bool
    public let outputSummary: String?
    public let errorCode: String?
    public let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case capability
        case succeeded
        case outputSummary = "output_summary"
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    public init(
        sourceID: String,
        capability: BlocksNativePluginCapability,
        succeeded: Bool,
        outputSummary: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.sourceID = sourceID
        self.capability = capability
        self.succeeded = succeeded
        self.outputSummary = outputSummary
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct TranslationSourceRedactedExport:
    Codable,
    Equatable,
    Sendable
{
    public let source: TranslationSourceSummary
    public let manifest: BlocksNativePluginManifest?
    public let configuration: [String: JSONValue]
    public let declaredSecretIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case source
        case manifest
        case configuration
        case declaredSecretIDs = "declared_secret_ids"
    }

    public init(
        source: TranslationSourceSummary,
        manifest: BlocksNativePluginManifest?,
        configuration: [String: JSONValue],
        declaredSecretIDs: [String]
    ) {
        self.source = source
        self.manifest = manifest
        self.configuration = configuration
        self.declaredSecretIDs = declaredSecretIDs
    }
}

public struct TranslationSourceManagementActionResult:
    Codable,
    Equatable,
    Sendable
{
    public let operation: TranslationSourceManagementOperation
    public let sources: [TranslationSourceSummary]
    public let inspection: TranslationSourcePackageInspection?
    public let scaffold: TranslationSourceScaffold?
    public let connectionTest: TranslationSourceConnectionTestSummary?
    public let redactedExport: TranslationSourceRedactedExport?
    public let enabledSourceIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case operation
        case sources
        case inspection
        case scaffold
        case connectionTest = "connection_test"
        case redactedExport = "redacted_export"
        case enabledSourceIDs = "enabled_source_ids"
    }

    public init(
        operation: TranslationSourceManagementOperation,
        sources: [TranslationSourceSummary] = [],
        inspection: TranslationSourcePackageInspection? = nil,
        scaffold: TranslationSourceScaffold? = nil,
        connectionTest: TranslationSourceConnectionTestSummary? = nil,
        redactedExport: TranslationSourceRedactedExport? = nil,
        enabledSourceIDs: [String] = []
    ) {
        self.operation = operation
        self.sources = sources
        self.inspection = inspection
        self.scaffold = scaffold
        self.connectionTest = connectionTest
        self.redactedExport = redactedExport
        self.enabledSourceIDs = enabledSourceIDs
    }
}

public enum TranslationSourceActionValidationError:
    Error,
    LocalizedError,
    Equatable
{
    case invalidPackageSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidPackageSnapshot:
            "The translation source package snapshot is invalid."
        }
    }
}

// MARK: - Generic plugin development and lifecycle transport

/// The plugin CLI has a dedicated contract. Translation sources may be
/// implemented by plugins, but generic plugin management must not inherit
/// translation-only fields or result ordering semantics.
public enum PluginDevelopmentOperation: String, Codable, Sendable {
    case list
    case inspect
    case install
    case configure
    case setSecret = "set_secret"
    case enable
    case disable
    case invoke
    case catalogList = "catalog_list"
    case catalogInstall = "catalog_install"
    case setDebug = "set_debug"
    case showLogs = "show_logs"
    case clearLogs = "clear_logs"
    case clearSafetyDisable = "clear_safety_disable"
    case remove
}

public enum PluginDevelopmentInvokeInputSource: Equatable, Sendable {
    case none
    case standardInput
    case file(String)
}

public enum PluginDevelopmentInvokeArgumentsError: Error, Equatable, Sendable {
    case invalidArguments
}

/// Parses only the trusted command-line envelope for `blocks plugin invoke`.
/// Plugin-provided action JSON is deliberately not consulted when deriving
/// destructive confirmation.
public struct PluginDevelopmentInvokeArguments: Equatable, Sendable {
    public let pluginID: String
    public let actionID: String
    public let inputSource: PluginDevelopmentInvokeInputSource
    public let confirmed: Bool

    public static func parse(
        _ arguments: [String]
    ) throws -> PluginDevelopmentInvokeArguments {
        guard arguments.count >= 2,
              !arguments[0].isEmpty,
              !arguments[1].isEmpty,
              !arguments[0].hasPrefix("--"),
              !arguments[1].hasPrefix("--") else {
            throw PluginDevelopmentInvokeArgumentsError.invalidArguments
        }

        var confirmed = false
        var inputSource = PluginDevelopmentInvokeInputSource.none
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--confirm":
                guard !confirmed else {
                    throw PluginDevelopmentInvokeArgumentsError.invalidArguments
                }
                confirmed = true
                index += 1
            case "--stdin":
                guard inputSource == .none else {
                    throw PluginDevelopmentInvokeArgumentsError.invalidArguments
                }
                inputSource = .standardInput
                index += 1
            case "--file":
                guard inputSource == .none,
                      index + 1 < arguments.count else {
                    throw PluginDevelopmentInvokeArgumentsError.invalidArguments
                }
                let path = arguments[index + 1]
                guard !path.isEmpty, !path.hasPrefix("--") else {
                    throw PluginDevelopmentInvokeArgumentsError.invalidArguments
                }
                inputSource = .file(path)
                index += 2
            default:
                throw PluginDevelopmentInvokeArgumentsError.invalidArguments
            }
        }

        return .init(
            pluginID: arguments[0],
            actionID: arguments[1],
            inputSource: inputSource,
            confirmed: confirmed
        )
    }

    public init(
        pluginID: String,
        actionID: String,
        inputSource: PluginDevelopmentInvokeInputSource,
        confirmed: Bool
    ) {
        self.pluginID = pluginID
        self.actionID = actionID
        self.inputSource = inputSource
        self.confirmed = confirmed
    }
}

public struct PluginDevelopmentActionInput: Codable, Equatable, Sendable {
    public let operation: PluginDevelopmentOperation
    public let pluginID: String?
    public let package: TranslationSourcePackageSnapshot?
    public let confirmationSHA256: String?
    public let configuration: [String: JSONValue]?
    public let secretID: String?
    public let secretValue: String?
    public let actionID: String?
    public let actionInput: [String: JSONValue]?
    public let debugEnabled: Bool?
    public let confirmed: Bool
    public let maximumLogBytes: Int?
    public let catalogID: String?

    private enum CodingKeys: String, CodingKey {
        case operation
        case pluginID = "plugin_id"
        case package
        case confirmationSHA256 = "confirmation_sha256"
        case configuration
        case secretID = "secret_id"
        case secretValue = "secret_value"
        case actionID = "action_id"
        case actionInput = "action_input"
        case debugEnabled = "debug_enabled"
        case confirmed
        case maximumLogBytes = "maximum_log_bytes"
        case catalogID = "catalog_id"
    }

    public init(
        operation: PluginDevelopmentOperation,
        pluginID: String? = nil,
        package: TranslationSourcePackageSnapshot? = nil,
        confirmationSHA256: String? = nil,
        configuration: [String: JSONValue]? = nil,
        secretID: String? = nil,
        secretValue: String? = nil,
        actionID: String? = nil,
        actionInput: [String: JSONValue]? = nil,
        debugEnabled: Bool? = nil,
        confirmed: Bool = false,
        maximumLogBytes: Int? = nil,
        catalogID: String? = nil
    ) {
        self.operation = operation
        self.pluginID = pluginID
        self.package = package
        self.confirmationSHA256 = confirmationSHA256
        self.configuration = configuration
        self.secretID = secretID
        self.secretValue = secretValue
        self.actionID = actionID
        self.actionInput = actionInput
        self.debugEnabled = debugEnabled
        self.confirmed = confirmed
        self.maximumLogBytes = maximumLogBytes
        self.catalogID = catalogID
    }
}

public struct PluginDevelopmentSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let enabled: Bool
    public let safetyDisabled: Bool
    public let debugEnabled: Bool
    public let installationOrigin: String

    private enum CodingKeys: String, CodingKey {
        case id, name, version, enabled
        case safetyDisabled = "safety_disabled"
        case debugEnabled = "debug_enabled"
        case installationOrigin = "installation_origin"
    }

    public init(
        id: String,
        name: String,
        version: String,
        enabled: Bool,
        safetyDisabled: Bool,
        debugEnabled: Bool,
        installationOrigin: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.safetyDisabled = safetyDisabled
        self.debugEnabled = debugEnabled
        self.installationOrigin = installationOrigin
    }
}

public struct PluginDevelopmentActionResult: Codable, Equatable, Sendable {
    public let operation: PluginDevelopmentOperation
    public let plugins: [PluginDevelopmentSummary]
    public let inspection: TranslationSourcePackageInspection?
    public let invocationOutput: [String: JSONValue]?
    public let logs: String?
    public let catalog: [PluginDevelopmentCatalogSummary]

    private enum CodingKeys: String, CodingKey {
        case operation, plugins, inspection, logs, catalog
        case invocationOutput = "invocation_output"
    }

    public init(
        operation: PluginDevelopmentOperation,
        plugins: [PluginDevelopmentSummary] = [],
        inspection: TranslationSourcePackageInspection? = nil,
        invocationOutput: [String: JSONValue]? = nil,
        logs: String? = nil,
        catalog: [PluginDevelopmentCatalogSummary] = []
    ) {
        self.operation = operation
        self.plugins = plugins
        self.inspection = inspection
        self.invocationOutput = invocationOutput
        self.logs = logs
        self.catalog = catalog
    }
}

public struct PluginDevelopmentCatalogSummary:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let name: String
    public let summary: String
    public let version: String
    public let installed: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        version: String,
        installed: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.installed = installed
    }
}
