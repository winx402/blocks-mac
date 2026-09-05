import CryptoKit
import Darwin
import Foundation

public struct BlocksNativePluginPackageLimits: Equatable, Sendable {
    public var maximumFileCount: Int
    public var maximumDirectoryCount: Int
    public var maximumPathDepth: Int
    public var maximumTotalBytes: Int
    public var maximumManifestBytes: Int
    public var maximumEntryPointBytes: Int

    public init(
        maximumFileCount: Int = 128,
        maximumDirectoryCount: Int = 128,
        maximumPathDepth: Int = 16,
        maximumTotalBytes: Int = 16 * 1_048_576,
        maximumManifestBytes: Int = 256 * 1_024,
        maximumEntryPointBytes: Int = 4 * 1_048_576
    ) {
        self.maximumFileCount = maximumFileCount
        self.maximumDirectoryCount = maximumDirectoryCount
        self.maximumPathDepth = maximumPathDepth
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumEntryPointBytes = maximumEntryPointBytes
    }
}

public struct BlocksNativePluginValidatedPackage: Sendable {
    public let manifest: BlocksNativePluginManifest
    public let manifestData: Data
    public let entrySource: String
    public let packageSHA256: String
    public let relativeFilePaths: [String]
    public let files: [String: Data]
    public let installationConfirmation: BlocksNativePluginInstallationConfirmation

    public init(
        manifest: BlocksNativePluginManifest,
        manifestData: Data,
        entrySource: String,
        packageSHA256: String,
        relativeFilePaths: [String],
        files: [String: Data] = [:],
        installationConfirmation: BlocksNativePluginInstallationConfirmation
    ) {
        self.manifest = manifest
        self.manifestData = manifestData
        self.entrySource = entrySource
        self.packageSHA256 = packageSHA256
        self.relativeFilePaths = relativeFilePaths
        self.files = files
        self.installationConfirmation = installationConfirmation
    }
}

public enum BlocksNativePluginValidationError: Error, LocalizedError, Equatable {
    case invalidPackageExtension
    case packageIsSymbolicLink
    case packageIsNotDirectory
    case fileCountExceeded(Int)
    case directoryCountExceeded(Int)
    case pathDepthExceeded(String)
    case totalSizeExceeded(Int)
    case symbolicLinkNotAllowed(String)
    case unsupportedFileType(String)
    case pathEscapesPackage(String)
    case missingManifest
    case manifestTooLarge(Int)
    case malformedManifest(String)
    case unsupportedSchemaVersion(Int)
    case invalidPluginID
    case invalidDisplayName
    case invalidVersion
    case invalidEntryPoint
    case entryPointMissing(String)
    case entryPointTooLarge(Int)
    case entryPointIsNotUTF8
    case entryPointContainsNullByte
    case capabilitiesMissing
    case duplicateCapability(String)
    case translationConfigurationWithoutCapability
    case translationConfigurationRequiredForSchemaV3
    case tooManyTranslationLanguages(Int)
    case duplicateTranslationLanguage(String)
    case translationContractRequiresSchemaV3
    case translationAcceptedInputsMissing
    case duplicateTranslationAcceptedInput(String)
    case duplicateTranslationContextField(String)
    case dataPermissionsRequireSchemaV3
    case duplicateDataPermission(String)
    case screenshotInputPermissionMismatch
    case invalidSecretID(String)
    case duplicateSecretID(String)
    case invalidSecretDisplayName(String)
    case duplicateSecretDisplayName(String)
    case configurationFieldsRequireSchemaV2
    case tooManyConfigurationFields(Int)
    case invalidConfigurationFieldID(String)
    case reservedConfigurationFieldID(String)
    case duplicateConfigurationFieldID(String)
    case invalidConfigurationFieldTitle(String)
    case invalidConfigurationFieldDetail(String)
    case invalidConfigurationFieldDefault(String)
    case invalidConfigurationFieldChoices(String)
    case invalidConfigurationFieldMaximumLength(String)
    case invalidConfigurationFieldHelpURL(String)
    case sensitiveConfigurationFieldNotDeclared(String)
    case secretDeclarationMissingSensitiveConfigurationField(String)
    case sensitiveConfigurationRequiredMismatch(String)
    case invalidSessionCredentialDomain(String)
    case networkDomainsMissing
    case invalidNetworkDomain(String)
    case duplicateNetworkDomain(String)
    case networkMethodsMissing
    case duplicateNetworkMethod(String)
    case invalidMaximumRequestBytes(Int)
    case platformRequiresSchemaV4
    case platformConfigurationRequired
    case secureFieldNotSupported(String)
    case invalidPlatformDeclaration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackageExtension:
            return "The plugin package must use the .blocksplugin extension."
        case .packageIsSymbolicLink:
            return "A plugin package cannot be a symbolic link."
        case .packageIsNotDirectory:
            return "The plugin package must be a directory."
        case let .fileCountExceeded(count):
            return "The plugin package contains too many files (\(count))."
        case let .directoryCountExceeded(count):
            return "The plugin package contains too many directories (\(count))."
        case let .pathDepthExceeded(path):
            return "The plugin package path is nested too deeply: \(path)."
        case let .totalSizeExceeded(size):
            return "The plugin package is too large (\(size) bytes)."
        case let .symbolicLinkNotAllowed(path):
            return "Symbolic links are not allowed in plugin packages: \(path)."
        case let .unsupportedFileType(path):
            return "Unsupported file type in plugin package: \(path)."
        case let .pathEscapesPackage(path):
            return "A plugin path escapes the package root: \(path)."
        case .missingManifest:
            return "The plugin package is missing manifest.json."
        case let .manifestTooLarge(size):
            return "The plugin manifest is too large (\(size) bytes)."
        case let .malformedManifest(message):
            return "The plugin manifest is invalid: \(message)"
        case let .unsupportedSchemaVersion(version):
            return "Unsupported plugin manifest schema version \(version)."
        case .invalidPluginID:
            return "The plugin ID must be a lowercase reverse-DNS identifier."
        case .invalidDisplayName:
            return "The plugin display name must contain 1 to 80 visible characters."
        case .invalidVersion:
            return "The plugin version must use semantic versioning."
        case .invalidEntryPoint:
            return "The plugin entry point must be a relative .js path inside the package."
        case let .entryPointMissing(path):
            return "The plugin entry point is missing: \(path)."
        case let .entryPointTooLarge(size):
            return "The plugin entry point is too large (\(size) bytes)."
        case .entryPointIsNotUTF8:
            return "The plugin entry point must be UTF-8 JavaScript."
        case .entryPointContainsNullByte:
            return "The plugin entry point contains a null byte."
        case .capabilitiesMissing:
            return "The plugin must declare at least one capability."
        case let .duplicateCapability(capability):
            return "The plugin declares a duplicate capability: \(capability)."
        case .translationConfigurationWithoutCapability:
            return "Translation language capabilities require the translation capability."
        case .translationConfigurationRequiredForSchemaV3:
            return "Schema version 3 translation plugins must declare a translation contract."
        case let .tooManyTranslationLanguages(count):
            return "The plugin declares too many translation languages (\(count))."
        case let .duplicateTranslationLanguage(language):
            return "The plugin declares a duplicate translation language: \(language)."
        case .translationContractRequiresSchemaV3:
            return "Translation input, context, and status declarations require manifest schema version 3."
        case .translationAcceptedInputsMissing:
            return "A schema version 3 translation plugin must accept at least one input type."
        case let .duplicateTranslationAcceptedInput(input):
            return "The plugin declares a duplicate translation input type: \(input)."
        case let .duplicateTranslationContextField(field):
            return "The plugin declares a duplicate translation context field: \(field)."
        case .dataPermissionsRequireSchemaV3:
            return "Plugin data permissions require manifest schema version 3."
        case let .duplicateDataPermission(permission):
            return "The plugin declares a duplicate data permission: \(permission)."
        case .screenshotInputPermissionMismatch:
            return "The screenshot_image input and data permission must be declared together."
        case let .invalidSecretID(secretID):
            return "The plugin declares an invalid secret ID: \(secretID)."
        case let .duplicateSecretID(secretID):
            return "The plugin declares a duplicate secret ID: \(secretID)."
        case let .invalidSecretDisplayName(secretID):
            return "The plugin secret has an invalid display name: \(secretID)."
        case let .duplicateSecretDisplayName(displayName):
            return "The plugin declares duplicate secret display name: \(displayName)."
        case .configurationFieldsRequireSchemaV2:
            return "Plugin configuration fields require manifest schema version 2."
        case let .tooManyConfigurationFields(count):
            return "The plugin declares too many configuration fields (\(count))."
        case let .invalidConfigurationFieldID(fieldID):
            return "The plugin declares an invalid configuration field ID: \(fieldID)."
        case let .reservedConfigurationFieldID(fieldID):
            return "The plugin configuration field uses a host-reserved ID: \(fieldID)."
        case let .duplicateConfigurationFieldID(fieldID):
            return "The plugin declares a duplicate configuration field ID: \(fieldID)."
        case let .invalidConfigurationFieldTitle(fieldID):
            return "The plugin configuration field has an invalid title: \(fieldID)."
        case let .invalidConfigurationFieldDetail(fieldID):
            return "The plugin configuration field has invalid descriptive text: \(fieldID)."
        case let .invalidConfigurationFieldDefault(fieldID):
            return "The plugin configuration field has an invalid default value: \(fieldID)."
        case let .invalidConfigurationFieldChoices(fieldID):
            return "The plugin configuration field has invalid choices: \(fieldID)."
        case let .invalidConfigurationFieldMaximumLength(fieldID):
            return "The plugin configuration field has an invalid maximum length: \(fieldID)."
        case let .invalidConfigurationFieldHelpURL(fieldID):
            return "The plugin configuration field has an invalid help URL: \(fieldID)."
        case let .sensitiveConfigurationFieldNotDeclared(fieldID):
            return "The sensitive configuration field is not declared as a plugin secret: \(fieldID)."
        case let .secretDeclarationMissingSensitiveConfigurationField(secretID):
            return "The plugin secret declaration does not have one matching sensitive configuration field: \(secretID)."
        case let .sensitiveConfigurationRequiredMismatch(fieldID):
            return "The sensitive configuration field and secret declaration disagree about whether the value is required: \(fieldID)."
        case let .invalidSessionCredentialDomain(domain):
            return "The plugin session credential declares an invalid exact HTTPS domain: \(domain)."
        case .networkDomainsMissing:
            return "A network permission must declare at least one domain."
        case let .invalidNetworkDomain(domain):
            return "The plugin declares an invalid network domain: \(domain)."
        case let .duplicateNetworkDomain(domain):
            return "The plugin declares a duplicate network domain: \(domain)."
        case .networkMethodsMissing:
            return "A network permission must declare at least one HTTP method."
        case let .duplicateNetworkMethod(method):
            return "The plugin declares a duplicate HTTP method: \(method)."
        case let .invalidMaximumRequestBytes(size):
            return "The plugin declares an invalid maximum request size: \(size)."
        case .platformRequiresSchemaV4:
            return "Hooks, actions, host UI, storage, schedules, and shared state require manifest schema version 4."
        case .platformConfigurationRequired:
            return "A schema version 4 hooks/actions/UI plugin must declare its platform contract."
        case let .secureFieldNotSupported(componentID):
            return "The plugin UI component \(componentID) uses secure_field, which is not supported. Sensitive configuration must use an explicitly declared Secret/Keychain configuration field."
        case let .invalidPlatformDeclaration(message):
            return "The plugin platform declaration is invalid: \(message)"
        }
    }
}

public struct BlocksNativePluginPackageValidator {
    private struct PackageFile {
        let url: URL
        let relativePath: String
        let size: Int
    }

    public let limits: BlocksNativePluginPackageLimits
    private let fileManager: FileManager

    public init(
        limits: BlocksNativePluginPackageLimits = .init(),
        fileManager: FileManager = .default
    ) {
        self.limits = limits
        self.fileManager = fileManager
    }

    public func validate(directory packageURL: URL) throws -> BlocksNativePluginValidatedPackage {
        guard packageURL.pathExtension.lowercased() == "blocksplugin" else {
            throw BlocksNativePluginValidationError.invalidPackageExtension
        }

        let rootValues = try packageURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isSymbolicLink != true else {
            throw BlocksNativePluginValidationError.packageIsSymbolicLink
        }
        guard rootValues.isDirectory == true else {
            throw BlocksNativePluginValidationError.packageIsNotDirectory
        }

        let root = packageURL.standardizedFileURL
        let rootDescriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            if errno == ELOOP {
                throw BlocksNativePluginValidationError.packageIsSymbolicLink
            }
            throw BlocksNativePluginValidationError.packageIsNotDirectory
        }
        defer { close(rootDescriptor) }
        let files = try collectFiles(in: root)
        guard let manifestFile = files.first(where: {
            $0.relativePath == BlocksNativePluginManifest.manifestFileName
        }) else {
            throw BlocksNativePluginValidationError.missingManifest
        }
        guard manifestFile.size <= limits.maximumManifestBytes else {
            throw BlocksNativePluginValidationError.manifestTooLarge(manifestFile.size)
        }

        var fileData: [String: Data] = [:]
        fileData.reserveCapacity(files.count)
        for file in files {
            let data = try readRegularFile(
                file,
                relativeToRootDescriptor: rootDescriptor
            )
            guard data.count == file.size else {
                throw BlocksNativePluginValidationError.unsupportedFileType(file.relativePath)
            }
            fileData[file.relativePath] = data
        }
        guard let manifestData = fileData[BlocksNativePluginManifest.manifestFileName] else {
            throw BlocksNativePluginValidationError.missingManifest
        }
        let manifest: BlocksNativePluginManifest
        do {
            manifest = try JSONDecoder().decode(BlocksNativePluginManifest.self, from: manifestData)
        } catch {
            throw BlocksNativePluginValidationError.malformedManifest(error.localizedDescription)
        }
        try validate(manifest: manifest)

        guard let entryFile = files.first(where: { $0.relativePath == manifest.entryPoint }) else {
            throw BlocksNativePluginValidationError.entryPointMissing(manifest.entryPoint)
        }
        guard entryFile.size <= limits.maximumEntryPointBytes else {
            throw BlocksNativePluginValidationError.entryPointTooLarge(entryFile.size)
        }
        guard let entryData = fileData[entryFile.relativePath] else {
            throw BlocksNativePluginValidationError.entryPointMissing(manifest.entryPoint)
        }
        guard let entrySource = String(data: entryData, encoding: .utf8) else {
            throw BlocksNativePluginValidationError.entryPointIsNotUTF8
        }
        guard !entrySource.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw BlocksNativePluginValidationError.entryPointContainsNullByte
        }

        let packageSHA256 = deterministicHash(
            paths: files.map(\.relativePath),
            fileData: fileData
        )
        let confirmation = BlocksNativePluginInstallationConfirmation(
            pluginID: manifest.id,
            displayName: manifest.displayName,
            version: manifest.version,
            packageSHA256: packageSHA256,
            isSigned: false,
            capabilities: manifest.capabilities,
            networkDomains: manifest.permissions.network?.domains ?? [],
            networkMethods: manifest.permissions.network?.methods ?? [],
            networkMaximumRequestBytes:
                manifest.permissions.network?.maximumRequestBytes
                ?? BlocksNativePluginNetworkPermission.defaultMaximumRequestBytes,
            secretIDs: manifest.permissions.secrets.map(\.id),
            dataPermissions: manifest.permissions.data,
            translationAcceptedInputs:
                manifest.schemaVersion >= 3
                    ? manifest.effectiveTranslationAcceptedInputs
                    : [],
            translationContextFields:
                manifest.schemaVersion >= 3
                    ? manifest.effectiveTranslationContextFields
                    : [],
            hookEventNames: manifest.platform?.hooks.map(\.event) ?? [],
            hostActionIDs: manifest.platform?.hostActions ?? [],
            importedActionIDs: manifest.platform?.importedActions.map {
                "\($0.pluginID):\($0.actionID)"
            } ?? [],
            uiSlots: manifest.platform?.ui.map(\.slot) ?? [],
            sharedNamespaces: manifest.platform?.sharedState.map(\.id) ?? [],
            includesBackgroundExecution:
                manifest.platform?.hooks.contains(where: \.runsInBackground) == true
                || !(manifest.platform?.schedules.isEmpty ?? true),
            includesBackgroundHookExecution:
                manifest.platform?.hooks.contains(where: \.runsInBackground) == true,
            includesScheduledExecution:
                !(manifest.platform?.schedules.isEmpty ?? true),
            usesPrivateStorage: manifest.platform?.storage != nil,
            failClosedHookIDs: manifest.platform?.hooks.compactMap {
                $0.failurePolicy == .failClosed ? $0.id : nil
            } ?? []
        )
        return BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: manifestData,
            entrySource: entrySource,
            packageSHA256: packageSHA256,
            relativeFilePaths: files.map(\.relativePath),
            files: fileData,
            installationConfirmation: confirmation
        )
    }

    public func validate(manifest: BlocksNativePluginManifest) throws {
        guard BlocksNativePluginManifest.supportedSchemaVersions.contains(
            manifest.schemaVersion
        ) else {
            throw BlocksNativePluginValidationError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.minimumHostAPIVersion > 0,
              manifest.minimumHostAPIVersion <= BlocksPluginHostAPIV2.version else {
            throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                "Plugin requires host API v\(manifest.minimumHostAPIVersion), but this build provides v\(BlocksPluginHostAPIV2.version)."
            )
        }
        if manifest.schemaVersion == 1, !manifest.configurationFields.isEmpty {
            throw BlocksNativePluginValidationError
                .configurationFieldsRequireSchemaV2
        }
        guard Self.matches(
            manifest.id,
            pattern: #"^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+$"#
        ), manifest.id.count <= 160 else {
            throw BlocksNativePluginValidationError.invalidPluginID
        }
        let displayName = manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty,
              displayName.count <= 80,
              Self.isSafeDisplayText(displayName) else {
            throw BlocksNativePluginValidationError.invalidDisplayName
        }
        if manifest.schemaVersion >= 6 {
            guard let presentation = manifest.presentation else {
                throw BlocksNativePluginValidationError
                    .invalidPlatformDeclaration(
                        "Manifest v6 requires ordinary-user presentation metadata."
                    )
            }
            try Self.validatePresentation(
                presentation,
                fallbackName: displayName
            )
        }
        guard Self.matches(
            manifest.version,
            pattern: #"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
        ), manifest.version.count <= 80 else {
            throw BlocksNativePluginValidationError.invalidVersion
        }
        guard Self.isSafeRelativePath(manifest.entryPoint),
              manifest.entryPoint.lowercased().hasSuffix(".js") else {
            throw BlocksNativePluginValidationError.invalidEntryPoint
        }

        guard !manifest.capabilities.isEmpty else {
            throw BlocksNativePluginValidationError.capabilitiesMissing
        }
        var capabilities = Set<BlocksNativePluginCapability>()
        for capability in manifest.capabilities where !capabilities.insert(capability).inserted {
            throw BlocksNativePluginValidationError.duplicateCapability(capability.rawValue)
        }
        let platformCapabilities: Set<BlocksNativePluginCapability> = [
            .hooks, .actions, .ui,
        ]
        if manifest.schemaVersion < 4,
           manifest.platform != nil || !capabilities.isDisjoint(with: platformCapabilities) {
            throw BlocksNativePluginValidationError.platformRequiresSchemaV4
        }
        if manifest.schemaVersion >= 4,
           !capabilities.isDisjoint(with: platformCapabilities),
           manifest.platform == nil {
            throw BlocksNativePluginValidationError.platformConfigurationRequired
        }
        if let platform = manifest.platform {
            try Self.validatePlatform(
                platform,
                capabilities: capabilities
            )
            let clipboardContentActions: Set<String> = [
                "clipboard.record.read",
                "clipboard.record.update",
            ]
            if !Set(platform.hostActions).isDisjoint(
                with: clipboardContentActions
            ), !manifest.permissions.data.contains(.clipboardContent) {
                throw BlocksNativePluginValidationError
                    .invalidPlatformDeclaration(
                        "Clipboard record read/update actions require the clipboard_content data permission."
                    )
            }
        }
        if let translation = manifest.translation {
            guard capabilities.contains(.translation) else {
                throw BlocksNativePluginValidationError
                    .translationConfigurationWithoutCapability
            }
            let languageCount =
                translation.supportedSourceLanguages.count
                + translation.supportedTargetLanguages.count
            guard languageCount <= 512 else {
                throw BlocksNativePluginValidationError
                    .tooManyTranslationLanguages(languageCount)
            }
            for languages in [
                translation.supportedSourceLanguages,
                translation.supportedTargetLanguages,
            ] {
                var seen: Set<TranslationLanguageTag> = []
                for language in languages where !seen.insert(language).inserted {
                    throw BlocksNativePluginValidationError
                        .duplicateTranslationLanguage(language.rawValue)
                }
            }

            if manifest.schemaVersion < 3 {
                guard translation.acceptedInputs == [.text],
                      translation.contextFields.isEmpty,
                      !translation.requiresExplicitSourceLanguage,
                      !translation.supportsStatus,
                      manifest.permissions.data.isEmpty else {
                    throw BlocksNativePluginValidationError
                        .translationContractRequiresSchemaV3
                }
            } else {
                guard translation.declaresAcceptedInputs,
                      !translation.acceptedInputs.isEmpty else {
                    throw BlocksNativePluginValidationError
                        .translationAcceptedInputsMissing
                }
                var acceptedInputs =
                    Set<TranslationSourceAcceptedInput>()
                for input in translation.acceptedInputs
                    where !acceptedInputs.insert(input).inserted {
                    throw BlocksNativePluginValidationError
                        .duplicateTranslationAcceptedInput(input.rawValue)
                }
                var contextFields =
                    Set<TranslationSourceContextField>()
                for field in translation.contextFields
                    where !contextFields.insert(field).inserted {
                    throw BlocksNativePluginValidationError
                        .duplicateTranslationContextField(field.rawValue)
                }
            }
        } else if manifest.schemaVersion >= 3,
                  capabilities.contains(.translation) {
            throw BlocksNativePluginValidationError
                .translationConfigurationRequiredForSchemaV3
        }

        var dataPermissions =
            Set<BlocksNativePluginDataPermission>()
        if manifest.schemaVersion < 3,
           !manifest.permissions.data.isEmpty {
            throw BlocksNativePluginValidationError
                .dataPermissionsRequireSchemaV3
        }
        for permission in manifest.permissions.data
            where !dataPermissions.insert(permission).inserted {
            throw BlocksNativePluginValidationError
                .duplicateDataPermission(permission.rawValue)
        }
        if manifest.schemaVersion >= 4 {
            let declaresFileComponent = manifest.platform?.ui.contains {
                var pending = [$0.root]
                while let component = pending.popLast() {
                    if component.kind == .fileAuthorization { return true }
                    pending.append(contentsOf: component.children)
                }
                return false
            } == true
            let declaresUserFiles =
                manifest.platform?.storage?.userGrantedFiles == true
                || declaresFileComponent
            guard !declaresUserFiles
                    || dataPermissions.contains(.userGrantedFiles) else {
                throw BlocksNativePluginValidationError
                    .invalidPlatformDeclaration(
                        "User-authorized file components require the user_granted_files data permission."
                    )
            }
        }
        let acceptsScreenshot =
            manifest.effectiveTranslationAcceptedInputs.contains(
                .screenshotImage
            )
        let permitsScreenshot =
            dataPermissions.contains(.screenshotImage)
        let platformConsumesScreenshotResource = manifest.platform?.hostActions
            .contains("screenshot.ocr") == true
        let requiresScreenshotPermission =
            acceptsScreenshot
            || (manifest.schemaVersion >= 3
                && capabilities.contains(.ocr))
        guard !requiresScreenshotPermission || permitsScreenshot,
              !permitsScreenshot
                || acceptsScreenshot
                || capabilities.contains(.ocr)
                || platformConsumesScreenshotResource else {
            throw BlocksNativePluginValidationError
                .screenshotInputPermissionMismatch
        }

        var secretIDs = Set<String>()
        var secretDisplayNames = Set<String>()
        for secret in manifest.permissions.secrets {
            guard Self.matches(
                secret.id,
                pattern: #"^[a-z][a-z0-9._-]{0,63}$"#
            ) else {
                throw BlocksNativePluginValidationError.invalidSecretID(secret.id)
            }
            guard secretIDs.insert(secret.id).inserted else {
                throw BlocksNativePluginValidationError.duplicateSecretID(secret.id)
            }
            let secretDisplayName = secret.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secretDisplayName.isEmpty,
                  secretDisplayName.count <= 80,
                  Self.isSafeDisplayText(secretDisplayName) else {
                throw BlocksNativePluginValidationError.invalidSecretDisplayName(secret.id)
            }
            let comparisonDisplayName = secretDisplayName
                .precomposedStringWithCanonicalMapping
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            guard secretDisplayNames.insert(comparisonDisplayName).inserted else {
                throw BlocksNativePluginValidationError
                    .duplicateSecretDisplayName(secretDisplayName)
            }
        }

        try Self.validateConfigurationFields(
            manifest.configurationFields,
            declaredSecrets: Dictionary(
                uniqueKeysWithValues: manifest.permissions.secrets.map {
                    ($0.id, $0.required)
                }
            ),
            networkPermission: manifest.permissions.network
        )
        if manifest.schemaVersion >= 2 {
            let sensitiveFieldIDs = Set(
                manifest.configurationFields.lazy
                    .filter { $0.type.isSensitive }
                    .map(\.id)
            )
            for secret in manifest.permissions.secrets
                where !sensitiveFieldIDs.contains(secret.id) {
                throw BlocksNativePluginValidationError
                    .secretDeclarationMissingSensitiveConfigurationField(
                        secret.id
                    )
            }
        }

        if let network = manifest.permissions.network {
            guard !network.domains.isEmpty else {
                throw BlocksNativePluginValidationError.networkDomainsMissing
            }
            var domains = Set<String>()
            for domain in network.domains {
                let normalizedDomain = domain.lowercased()
                guard Self.isValidPermissionDomain(normalizedDomain) else {
                    throw BlocksNativePluginValidationError.invalidNetworkDomain(domain)
                }
                guard domains.insert(normalizedDomain).inserted else {
                    throw BlocksNativePluginValidationError.duplicateNetworkDomain(domain)
                }
            }
            guard !network.methods.isEmpty else {
                throw BlocksNativePluginValidationError.networkMethodsMissing
            }
            var methods = Set<BlocksNativePluginHTTPMethod>()
            for method in network.methods where !methods.insert(method).inserted {
                throw BlocksNativePluginValidationError.duplicateNetworkMethod(method.rawValue)
            }
            guard (1...BlocksNativePluginNetworkPermission.absoluteMaximumRequestBytes)
                .contains(network.maximumRequestBytes) else {
                throw BlocksNativePluginValidationError.invalidMaximumRequestBytes(
                    network.maximumRequestBytes
                )
            }
        }
    }

    private static func validatePresentation(
        _ presentation: BlocksNativePluginPresentation,
        fallbackName: String
    ) throws {
        func validateText(
            _ value: String,
            maximum: Int,
            field: String
        ) throws {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty,
                  trimmed.count <= maximum,
                  isSafeDisplayText(trimmed) else {
                throw BlocksNativePluginValidationError
                    .invalidPlatformDeclaration(
                        "Plugin presentation contains invalid \(field)."
                    )
            }
        }

        try validateText(presentation.summary, maximum: 240, field: "summary")
        try validateText(presentation.purpose, maximum: 1_000, field: "purpose")
        try validateText(presentation.trigger, maximum: 500, field: "trigger")
        try validateText(
            presentation.dataUsage,
            maximum: 1_000,
            field: "data usage"
        )
        guard presentation.examples.count <= 8 else {
            throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                "Plugin presentation declares too many examples."
            )
        }
        for example in presentation.examples {
            try validateText(example, maximum: 500, field: "example")
        }
        for (locale, localization) in presentation.localizations {
            guard matches(locale, pattern: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#) else {
                throw BlocksNativePluginValidationError
                    .invalidPlatformDeclaration(
                        "Plugin presentation has an invalid locale: \(locale)."
                    )
            }
            try validateText(
                localization.name ?? fallbackName,
                maximum: 80,
                field: "localized name"
            )
            try validateText(localization.summary, maximum: 240, field: "localized summary")
            try validateText(localization.purpose, maximum: 1_000, field: "localized purpose")
            try validateText(localization.trigger, maximum: 500, field: "localized trigger")
            try validateText(localization.dataUsage, maximum: 1_000, field: "localized data usage")
            guard localization.examples.count <= 8 else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Plugin presentation declares too many localized examples."
                )
            }
            for example in localization.examples {
                try validateText(example, maximum: 500, field: "localized example")
            }
        }
    }

    private static func validatePlatform(
        _ platform: BlocksPluginPlatformConfiguration,
        capabilities: Set<BlocksNativePluginCapability>
    ) throws {
        if !platform.hooks.isEmpty, !capabilities.contains(.hooks) {
            throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                "Hook subscriptions require the hooks capability."
            )
        }
        if !platform.actions.isEmpty, !capabilities.contains(.actions) {
            throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                "Exported actions require the actions capability."
            )
        }
        var hostActionIDs = Set<String>()
        for actionID in platform.hostActions {
            guard matches(actionID, pattern: #"^[a-z][a-z0-9._-]{0,127}$"#),
                  hostActionIDs.insert(actionID).inserted else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Invalid or duplicate host action identifier: \(actionID)."
                )
            }
            guard BlocksPluginHostAPIV2.actionIDs.contains(actionID) else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Unsupported host action identifier for host API v\(BlocksPluginHostAPIV2.version): \(actionID)."
                )
            }
        }
        if !platform.ui.isEmpty, !capabilities.contains(.ui) {
            throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                "UI contributions require the ui capability."
            )
        }
        var IDs = Set<String>()
        func validateID(_ id: String, context: String) throws {
            guard matches(id, pattern: #"^[a-z][a-z0-9._-]{0,127}$"#),
                  IDs.insert("\(context):\(id)").inserted else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Invalid or duplicate \(context) identifier: \(id)."
                )
            }
        }
        for hook in platform.hooks {
            try validateID(hook.id, context: "hook")
            guard matches(
                hook.entryFunction,
                pattern: #"^[A-Za-z_$][A-Za-z0-9_$]{0,127}$"#
            ), (1...2_000).contains(hook.timeoutMilliseconds) else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Hook \(hook.id) has an invalid entry function or timeout."
                )
            }
            if hook.event.phase != .will,
               hook.failurePolicy == .failClosed {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Only will events may use fail_closed."
                )
            }
            if hook.event == .appWillTerminate,
               hook.failurePolicy == .failClosed {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "app.will_terminate may not use fail_closed."
                )
            }
            if !hook.isExecutionEligible {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "runs_in_background=false is only allowed for non-termination will.* preflight hooks."
                )
            }
        }
        for action in platform.actions {
            try validateID(action.id, context: "action")
            guard matches(
                action.entryFunction,
                pattern: #"^[A-Za-z_$][A-Za-z0-9_$]{0,127}$"#
            ) else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Action \(action.id) has an invalid entry function."
                )
            }
        }
        var importedActionIDs = Set<String>()
        for action in platform.importedActions {
            guard matches(
                action.pluginID,
                pattern: #"^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$"#
            ), matches(
                action.actionID,
                pattern: #"^[a-z][a-z0-9._-]{0,127}$"#
            ), importedActionIDs.insert(
                "\(action.pluginID):\(action.actionID)"
            ).inserted else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Invalid or duplicate imported plugin action."
                )
            }
        }
        let exportedActionIDs = Set(platform.actions.map(\.id))
        var componentIDs = Set<String>()
        for contribution in platform.ui {
            try validateID(contribution.id, context: "ui")
            guard contribution.slot.allowedRootComponentKinds.contains(
                contribution.root.kind
            ) else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "UI contribution \(contribution.id) uses an unsupported root component for \(contribution.slot.rawValue)."
                )
            }
            var pending = [contribution.root]
            while let component = pending.popLast() {
                guard matches(
                    component.id,
                    pattern: #"^[a-z][a-z0-9._-]{0,127}$"#
                ), componentIDs.insert(component.id).inserted else {
                    throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                        "Invalid or duplicate UI component identifier: \(component.id)."
                    )
                }
                guard component.kind != .secureField else {
                    throw BlocksNativePluginValidationError
                        .secureFieldNotSupported(component.id)
                }
                if let actionID = component.actionID,
                   !exportedActionIDs.contains(actionID) {
                    throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                        "UI component \(component.id) references an undeclared action: \(actionID)."
                    )
                }
                let unknownProperties = Set(component.properties.keys)
                    .subtracting(component.kind.stateProperties)
                guard unknownProperties.isEmpty else {
                    throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                        "UI component \(component.id) declares unsupported properties: \(unknownProperties.sorted().joined(separator: ", "))."
                    )
                }
                pending.append(contentsOf: component.children)
            }
        }
        for namespace in platform.sharedState {
            try validateID(namespace.id, context: "namespace")
            if let displayName = namespace.displayName {
                let trimmed = displayName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard (1...80).contains(trimmed.count),
                      isSafeDisplayText(trimmed) else {
                    throw BlocksNativePluginValidationError
                        .invalidPlatformDeclaration(
                            "Shared namespace \(namespace.id) has an invalid display name."
                        )
                }
            }
            if let owner = namespace.ownerPluginID,
               !matches(owner, pattern: #"^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$"#) {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Shared namespace \(namespace.id) has an invalid owner plugin ID."
                )
            }
            guard namespace.schemaVersion > 0 else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Shared namespace \(namespace.id) has an invalid schema version."
                )
            }
        }
        for schedule in platform.schedules {
            try validateID(schedule.id, context: "schedule")
            guard matches(
                schedule.entryFunction,
                pattern: #"^[A-Za-z_$][A-Za-z0-9_$]{0,127}$"#
            ) else {
                throw BlocksNativePluginValidationError.invalidPlatformDeclaration(
                    "Schedule \(schedule.id) has an invalid entry function."
                )
            }
        }
    }


    private static func validateConfigurationFields(
        _ fields: [BlocksNativePluginConfigurationField],
        declaredSecrets: [String: Bool],
        networkPermission: BlocksNativePluginNetworkPermission?
    ) throws {
        guard fields.count <= 64 else {
            throw BlocksNativePluginValidationError
                .tooManyConfigurationFields(fields.count)
        }
        var fieldIDs = Set<String>()
        for field in fields {
            guard matches(
                field.id,
                pattern: #"^[a-z][a-z0-9._-]{0,63}$"#
            ) else {
                throw BlocksNativePluginValidationError
                    .invalidConfigurationFieldID(field.id)
            }
            guard field.id != "connection_test" else {
                throw BlocksNativePluginValidationError
                    .reservedConfigurationFieldID(field.id)
            }
            for (locale, localization) in field.localizations {
                guard matches(
                    locale,
                    pattern: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#
                ), !localization.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty,
                localization.title.count <= 120,
                isSafeDisplayText(localization.title) else {
                    throw BlocksNativePluginValidationError
                        .invalidPlatformDeclaration(
                            "Configuration field \(field.id) has invalid localization metadata."
                        )
                }
            }
            guard fieldIDs.insert(field.id).inserted else {
                throw BlocksNativePluginValidationError
                    .duplicateConfigurationFieldID(field.id)
            }
            let title = field.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !title.isEmpty,
                  title.count <= 80,
                  isSafeDisplayText(title) else {
                throw BlocksNativePluginValidationError
                    .invalidConfigurationFieldTitle(field.id)
            }
            for text in [field.detail, field.placeholder].compactMap({ $0 }) {
                guard text.count <= 512, isSafeDisplayText(text) else {
                    throw BlocksNativePluginValidationError
                        .invalidConfigurationFieldDetail(field.id)
                }
            }
            if let maximumLength = field.maximumLength {
                guard (1...16_384).contains(maximumLength) else {
                    throw BlocksNativePluginValidationError
                        .invalidConfigurationFieldMaximumLength(field.id)
                }
            }
            if let helpURL = field.helpURL {
                guard let components = URLComponents(string: helpURL),
                      components.scheme?.lowercased() == "https",
                      components.host != nil,
                      components.user == nil,
                      components.password == nil else {
                    throw BlocksNativePluginValidationError
                        .invalidConfigurationFieldHelpURL(field.id)
                }
            }
            try validateDefaultValue(field)
            try validateChoices(field)

            if field.type.isSensitive {
                guard let secretIsRequired = declaredSecrets[field.id] else {
                    throw BlocksNativePluginValidationError
                        .sensitiveConfigurationFieldNotDeclared(field.id)
                }
                guard secretIsRequired == field.required else {
                    throw BlocksNativePluginValidationError
                        .sensitiveConfigurationRequiredMismatch(field.id)
                }
            }
            if field.type == .sessionCredential {
                guard !field.allowedDomains.isEmpty else {
                    throw BlocksNativePluginValidationError
                        .invalidSessionCredentialDomain("")
                }
                let declaredNetworkDomains = Set(
                    networkPermission?.domains.map { $0.lowercased() } ?? []
                )
                var seenDomains = Set<String>()
                for rawDomain in field.allowedDomains {
                    let domain = rawDomain.lowercased()
                    guard !domain.hasPrefix("*."),
                          isValidPermissionDomain(domain),
                          declaredNetworkDomains.contains(domain),
                          seenDomains.insert(domain).inserted else {
                        throw BlocksNativePluginValidationError
                            .invalidSessionCredentialDomain(rawDomain)
                    }
                }
            } else if !field.allowedDomains.isEmpty {
                throw BlocksNativePluginValidationError
                    .invalidSessionCredentialDomain(
                        field.allowedDomains[0]
                    )
            }
        }
    }

    private static func validateDefaultValue(
        _ field: BlocksNativePluginConfigurationField
    ) throws {
        guard let value = field.defaultValue else { return }
        let isValid: Bool
        switch (field.type, value) {
        case (.text, .string),
             (.url, .string),
             (.choice, .string),
             (.color, .string),
             (.file, .string),
             (.tag, .string),
             (.boolean, .bool):
            isValid = true
        case (.number, .int),
             (.number, .double),
             (.slider, .int),
             (.slider, .double):
            isValid = true
        case let (.multipleChoice, .array(values)):
            isValid = values.allSatisfy {
                if case .string = $0 { return true }
                return false
            }
        case (.secret, _), (.sessionCredential, _):
            isValid = false
        default:
            isValid = false
        }
        guard isValid else {
            throw BlocksNativePluginValidationError
                .invalidConfigurationFieldDefault(field.id)
        }
        if case let .string(string) = value,
           string.count > (field.maximumLength ?? 16_384) {
            throw BlocksNativePluginValidationError
                .invalidConfigurationFieldDefault(field.id)
        }
    }

    private static func validateChoices(
        _ field: BlocksNativePluginConfigurationField
    ) throws {
        if field.type != .choice && field.type != .multipleChoice {
            guard field.choices.isEmpty else {
                throw BlocksNativePluginValidationError
                    .invalidConfigurationFieldChoices(field.id)
            }
            return
        }
        guard !field.choices.isEmpty, field.choices.count <= 128 else {
            throw BlocksNativePluginValidationError
                .invalidConfigurationFieldChoices(field.id)
        }
        var values = Set<String>()
        for choice in field.choices {
            guard !choice.value.isEmpty,
                  choice.value.count <= 256,
                  values.insert(choice.value).inserted,
                  !choice.title.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  choice.title.count <= 80,
                  isSafeDisplayText(choice.title) else {
                throw BlocksNativePluginValidationError
                    .invalidConfigurationFieldChoices(field.id)
            }
        }
        if case let .string(defaultValue) = field.defaultValue,
           !values.contains(defaultValue) {
            throw BlocksNativePluginValidationError
                .invalidConfigurationFieldDefault(field.id)
        }
        if field.type == .multipleChoice,
           case let .array(defaultValues) = field.defaultValue {
            let invalidDefault = defaultValues.contains { value in
                guard case let .string(rawValue) = value else {
                    return true
                }
                return !values.contains(rawValue)
            }
            if invalidDefault {
                throw BlocksNativePluginValidationError
                    .invalidConfigurationFieldDefault(field.id)
            }
        }
    }

    private func collectFiles(in root: URL) throws -> [PackageFile] {
        var files: [PackageFile] = []
        var pendingDirectories = [root]
        var totalBytes = 0
        var directoryCount = 0
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        while let directory = pendingDirectories.popLast() {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                let standardized = child.standardizedFileURL
                guard standardized.path.hasPrefix(rootPrefix) else {
                    throw BlocksNativePluginValidationError.pathEscapesPackage(child.path)
                }
                let relativePath = String(standardized.path.dropFirst(rootPrefix.count))
                guard Self.isSafeRelativePath(relativePath) else {
                    throw BlocksNativePluginValidationError.pathEscapesPackage(relativePath)
                }
                guard relativePath.split(separator: "/").count
                    <= limits.maximumPathDepth else {
                    throw BlocksNativePluginValidationError.pathDepthExceeded(relativePath)
                }
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
                if values.isSymbolicLink == true {
                    throw BlocksNativePluginValidationError.symbolicLinkNotAllowed(relativePath)
                }
                if values.isDirectory == true {
                    directoryCount += 1
                    guard directoryCount <= limits.maximumDirectoryCount else {
                        throw BlocksNativePluginValidationError.directoryCountExceeded(
                            directoryCount
                        )
                    }
                    pendingDirectories.append(child)
                    continue
                }
                guard values.isRegularFile == true else {
                    throw BlocksNativePluginValidationError.unsupportedFileType(relativePath)
                }

                let size = values.fileSize ?? 0
                totalBytes += size
                files.append(PackageFile(url: child, relativePath: relativePath, size: size))
                guard files.count <= limits.maximumFileCount else {
                    throw BlocksNativePluginValidationError.fileCountExceeded(files.count)
                }
                guard totalBytes <= limits.maximumTotalBytes else {
                    throw BlocksNativePluginValidationError.totalSizeExceeded(totalBytes)
                }
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func deterministicHash(
        paths: [String],
        fileData: [String: Data]
    ) -> String {
        var hasher = SHA256()
        for path in paths.sorted() {
            guard let data = fileData[path] else { continue }
            let pathData = Data(path.utf8)
            hasher.update(data: Self.lengthPrefix(pathData.count))
            hasher.update(data: pathData)
            hasher.update(data: Self.lengthPrefix(data.count))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readRegularFile(
        _ file: PackageFile,
        relativeToRootDescriptor rootDescriptor: Int32
    ) throws -> Data {
        let components = file.relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            throw BlocksNativePluginValidationError.unsupportedFileType(
                file.relativePath
            )
        }
        var directoryDescriptor = rootDescriptor
        var ownedDirectoryDescriptors: [Int32] = []
        defer {
            ownedDirectoryDescriptors.reversed().forEach { close($0) }
        }
        for component in components.dropLast() {
            let childDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard childDescriptor >= 0 else {
                if errno == ELOOP {
                    throw BlocksNativePluginValidationError.symbolicLinkNotAllowed(
                        file.relativePath
                    )
                }
                throw BlocksNativePluginValidationError.unsupportedFileType(
                    file.relativePath
                )
            }
            ownedDirectoryDescriptors.append(childDescriptor)
            directoryDescriptor = childDescriptor
        }
        let descriptor = fileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw BlocksNativePluginValidationError.symbolicLinkNotAllowed(
                    file.relativePath
                )
            }
            throw BlocksNativePluginValidationError.unsupportedFileType(file.relativePath)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw BlocksNativePluginValidationError.unsupportedFileType(file.relativePath)
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(limits.maximumTotalBytes) else {
            close(descriptor)
            throw BlocksNativePluginValidationError.totalSizeExceeded(Int(status.st_size))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return try handle.readToEnd() ?? Data()
    }

    private static func lengthPrefix(_ value: Int) -> Data {
        var bigEndianValue = UInt64(value).bigEndian
        return withUnsafeBytes(of: &bigEndianValue) { Data($0) }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func isValidPermissionDomain(_ value: String) -> Bool {
        let host = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
        guard host.contains("."),
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              host.count <= 253,
              !host.contains(":"),
              host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        if isNumericIPAddress(host) {
            return false
        }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45
            }
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isNumericIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        var address = in_addr()
        return host.withCString { inet_aton($0, &address) } == 1
    }

    private static func isSafeDisplayText(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar.value == 0x200E
                || scalar.value == 0x200F
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) {
                return false
            }
        }
        return true
    }
}

public enum BlocksNativePluginNetworkPolicyError: Error, LocalizedError, Equatable {
    case networkPermissionMissing
    case invalidURL
    case urlTooLarge(Int)
    case insecureScheme
    case credentialsInURL
    case secretInURL
    case privateOrLocalHost
    case domainNotAllowed(String)
    case methodNotAllowed(String)
    case invalidTimeout
    case tooManyHeaders
    case invalidHeaderName(String)
    case invalidHeaderValue(String)
    case restrictedHeader(String)
    case requestTooLarge(Int)
    case malformedSecretReference
    case secretNotDeclared(String)
    case sessionCredentialDomainNotAllowed(
        credentialID: String,
        domain: String
    )
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .networkPermissionMissing:
            return "The plugin did not declare network access."
        case .invalidURL:
            return "The plugin supplied an invalid network URL."
        case let .urlTooLarge(size):
            return "The plugin network URL is too large (\(size) bytes)."
        case .insecureScheme:
            return "Plugin network requests must use HTTPS."
        case .credentialsInURL:
            return "Plugin network URLs cannot contain credentials."
        case .secretInURL:
            return "Plugin secret placeholders cannot appear in URLs."
        case .privateOrLocalHost:
            return "Plugin network requests cannot target local or private hosts."
        case let .domainNotAllowed(domain):
            return "The plugin is not allowed to access \(domain)."
        case let .methodNotAllowed(method):
            return "The plugin is not allowed to use HTTP \(method)."
        case .invalidTimeout:
            return "The plugin request timeout must be between 1 and 60 seconds."
        case .tooManyHeaders:
            return "The plugin supplied too many HTTP headers."
        case let .invalidHeaderName(name):
            return "The plugin supplied an invalid HTTP header name: \(name)."
        case let .invalidHeaderValue(name):
            return "The plugin supplied an invalid HTTP header value: \(name)."
        case let .restrictedHeader(name):
            return "The plugin cannot set the restricted HTTP header: \(name)."
        case let .requestTooLarge(size):
            return "The plugin network request is too large (\(size) bytes)."
        case .malformedSecretReference:
            return "The plugin supplied a malformed secret placeholder."
        case let .secretNotDeclared(secretID):
            return "The plugin did not declare the secret \(secretID)."
        case let .sessionCredentialDomainNotAllowed(
            credentialID,
            domain
        ):
            return "The session credential \(credentialID) cannot be sent to \(domain)."
        case let .responseTooLarge(size):
            return "The plugin network response is too large (\(size) bytes)."
        }
    }
}

public struct BlocksNativePluginValidatedNetworkRequest: Equatable, Sendable {
    public let request: BlocksNativePluginNetworkRequest
    public let url: URL
    public let referencedSecretIDs: Set<String>

    public init(
        request: BlocksNativePluginNetworkRequest,
        url: URL,
        referencedSecretIDs: Set<String>
    ) {
        self.request = request
        self.url = url
        self.referencedSecretIDs = referencedSecretIDs
    }
}

public struct BlocksNativePluginNetworkPolicy {
    public static let maximumResponseBytes = 8 * 1_048_576
    public static let maximumURLBytes = 8 * 1_024

    public init() {}

    public func validate(
        _ request: BlocksNativePluginNetworkRequest,
        manifest: BlocksNativePluginManifest
    ) throws -> BlocksNativePluginValidatedNetworkRequest {
        guard let permission = manifest.permissions.network else {
            throw BlocksNativePluginNetworkPolicyError.networkPermissionMissing
        }
        let urlBytes = request.url.utf8.count
        guard urlBytes <= Self.maximumURLBytes else {
            throw BlocksNativePluginNetworkPolicyError.urlTooLarge(urlBytes)
        }
        guard let components = URLComponents(string: request.url),
              let url = components.url,
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw BlocksNativePluginNetworkPolicyError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw BlocksNativePluginNetworkPolicyError.insecureScheme
        }
        guard components.user == nil, components.password == nil else {
            throw BlocksNativePluginNetworkPolicyError.credentialsInURL
        }
        guard !request.url.contains("{{secret:") else {
            throw BlocksNativePluginNetworkPolicyError.secretInURL
        }
        guard !Self.isLocalOrIPAddress(host) else {
            throw BlocksNativePluginNetworkPolicyError.privateOrLocalHost
        }
        guard permission.domains.contains(where: {
            Self.matches(host: host, permissionDomain: $0.lowercased())
        }) else {
            throw BlocksNativePluginNetworkPolicyError.domainNotAllowed(host)
        }
        guard permission.methods.contains(request.method) else {
            throw BlocksNativePluginNetworkPolicyError.methodNotAllowed(request.method.rawValue)
        }
        guard (1...60).contains(request.timeoutSeconds) else {
            throw BlocksNativePluginNetworkPolicyError.invalidTimeout
        }
        guard request.headers.count <= 64 else {
            throw BlocksNativePluginNetworkPolicyError.tooManyHeaders
        }

        let restrictedHeaders = Set([
            "connection",
            "content-length",
            "host",
            "proxy-authorization",
            "proxy-connection",
            "transfer-encoding",
            "upgrade",
        ])
        var referencedSecrets = Set<String>()
        var headerBytes = 0
        for (name, value) in request.headers {
            let lowercasedName = name.lowercased()
            guard Self.isValidHeaderName(name) else {
                throw BlocksNativePluginNetworkPolicyError.invalidHeaderName(name)
            }
            guard !restrictedHeaders.contains(lowercasedName) else {
                throw BlocksNativePluginNetworkPolicyError.restrictedHeader(name)
            }
            guard !value.contains("\r"), !value.contains("\n") else {
                throw BlocksNativePluginNetworkPolicyError.invalidHeaderValue(name)
            }
            headerBytes += name.utf8.count + value.utf8.count
            referencedSecrets.formUnion(
                try BlocksNativePluginSecretReferenceParser.references(in: value)
            )
        }
        if let body = request.body,
           let bodyText = String(data: body, encoding: .utf8) {
            referencedSecrets.formUnion(
                try BlocksNativePluginSecretReferenceParser.references(in: bodyText)
            )
        }

        let declaredSecretIDs = Set(manifest.permissions.secrets.map(\.id))
        if let undeclared = referencedSecrets.subtracting(declaredSecretIDs).sorted().first {
            throw BlocksNativePluginNetworkPolicyError.secretNotDeclared(undeclared)
        }
        let sessionCredentialFields: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: manifest.configurationFields.compactMap {
                field -> (String, Set<String>)? in
                guard field.type == .sessionCredential else {
                    return nil
                }
                return (
                    field.id,
                    Set(field.allowedDomains.map { $0.lowercased() })
                )
            }
        )
        for credentialID in referencedSecrets.sorted() {
            guard let allowedDomains =
                    sessionCredentialFields[credentialID] else {
                continue
            }
            guard allowedDomains.contains(host) else {
                throw BlocksNativePluginNetworkPolicyError
                    .sessionCredentialDomainNotAllowed(
                        credentialID: credentialID,
                        domain: host
                    )
            }
        }

        let requestBytes = headerBytes + (request.body?.count ?? 0)
        guard requestBytes <= permission.maximumRequestBytes else {
            throw BlocksNativePluginNetworkPolicyError.requestTooLarge(requestBytes)
        }
        return BlocksNativePluginValidatedNetworkRequest(
            request: request,
            url: url,
            referencedSecretIDs: referencedSecrets
        )
    }

    public func validateRedirect(
        from originalRequest: BlocksNativePluginNetworkRequest,
        to redirectedURL: URL,
        method: BlocksNativePluginHTTPMethod? = nil,
        manifest: BlocksNativePluginManifest
    ) throws {
        let redirectedRequest = BlocksNativePluginNetworkRequest(
            requestID: originalRequest.requestID,
            url: redirectedURL.absoluteString,
            method: method ?? originalRequest.method,
            headers: originalRequest.headers,
            body: originalRequest.body,
            timeoutSeconds: originalRequest.timeoutSeconds
        )
        _ = try validate(redirectedRequest, manifest: manifest)
    }

    public func validateResponseSize(_ size: Int) throws {
        guard size <= Self.maximumResponseBytes else {
            throw BlocksNativePluginNetworkPolicyError.responseTooLarge(size)
        }
    }

    private static func matches(host: String, permissionDomain: String) -> Bool {
        if permissionDomain.hasPrefix("*.") {
            let suffix = String(permissionDomain.dropFirst(2))
            return host.hasSuffix("." + suffix) && host != suffix
        }
        return host == permissionDomain
    }

    private static func isLocalOrIPAddress(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return true
        }
        if host.contains(":") { return true }
        var address = in_addr()
        return host.withCString { inet_aton($0, &address) } == 1
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~".unicodeScalars)
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || allowedPunctuation.contains($0)
        }
    }
}

public enum BlocksNativePluginSecretReferenceParser {
    private static let validReferencePattern = #"\{\{secret:([a-z][a-z0-9._-]{0,63})\}\}"#

    public static func references(in value: String) throws -> Set<String> {
        let regularExpression = try NSRegularExpression(pattern: validReferencePattern)
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regularExpression.matches(in: value, range: fullRange)
        var references = Set<String>()
        for match in matches {
            guard match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: value) else {
                throw BlocksNativePluginNetworkPolicyError.malformedSecretReference
            }
            references.insert(String(value[idRange]))
        }

        var scrubbed = value as NSString
        for match in matches.reversed() {
            scrubbed = scrubbed.replacingCharacters(in: match.range, with: "") as NSString
        }
        if (scrubbed as String).contains("{{secret:") {
            throw BlocksNativePluginNetworkPolicyError.malformedSecretReference
        }
        return references
    }
}
