import BlocksCore
import Combine
import Darwin
import Foundation

enum BlocksNativePluginHostConfiguration {
    static func connectionTest(
        persisted: [String: JSONValue]
    ) -> [String: JSONValue] {
        persisted.merging(
            ["connection_test": .bool(true)]
        ) { _, hostReservedValue in hostReservedValue }
    }
}

protocol BlocksNativePluginExecuting: Sendable {
    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput

    func executeConnectionTest(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput

    func cancelExecutions(pluginID: String)

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult
}

extension BlocksNativePluginExecuting {
    func executeConnectionTest(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        try await execute(
            package: package,
            metadata: metadata,
            invocation: invocation,
            progress: progress
        )
    }

    func cancelExecutions(pluginID: String) {}

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        throw BlocksNativePluginExecutionError.runnerUnavailable
    }
}

protocol BlocksNativePluginMetadataStoring: Sendable {
    func list() throws -> [BlocksNativePluginMetadata]
    func metadata(id: String) throws -> BlocksNativePluginMetadata
    func installApproved(
        package: BlocksNativePluginValidatedPackage,
        installedRelativePath: String,
        permissions: [String],
        domains: [String],
        installationOrigin: BlocksNativePluginInstallationOrigin,
        builtInCatalogVersion: String?,
        now: Date
    ) throws -> BlocksNativePluginMetadata
    func setEnabled(
        _ isEnabled: Bool,
        pluginID: String,
        now: Date
    ) throws -> BlocksNativePluginMetadata
    func remove(pluginID: String) throws
}

extension BlocksNativePluginMetadataRepository: BlocksNativePluginMetadataStoring {}

enum BlocksNativePluginExecutionError: Error, LocalizedError, Equatable {
    case runnerUnavailable
    case pluginNotApproved
    case pluginDisabled
    case packageHashMismatch
    case capabilityUnavailable
    case executionFailed(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .runnerUnavailable:
            return "The isolated plugin runner is not embedded in this build."
        case .pluginNotApproved:
            return "The plugin permissions have not been approved."
        case .pluginDisabled:
            return "The plugin is disabled."
        case .packageHashMismatch:
            return "The installed plugin package changed and must be reviewed again."
        case .capabilityUnavailable:
            return "The plugin does not provide the requested capability."
        case let .executionFailed(_, message):
            return message
        }
    }
}

struct BlocksNativePluginUnavailableExecutor: BlocksNativePluginExecuting {
    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        throw BlocksNativePluginExecutionError.runnerUnavailable
    }
}

struct BlocksNativePluginPendingInstallation: Identifiable, Sendable {
    let id: UUID
    let sourceDisplayName: String
    let confirmation: BlocksNativePluginInstallationConfirmation
    let installationOrigin: BlocksNativePluginInstallationOrigin
    let builtInCatalogVersion: String?
    fileprivate let package: BlocksNativePluginValidatedPackage

    var manifest: BlocksNativePluginManifest {
        package.manifest
    }
}

enum BlocksNativePluginManagerOperation: Equatable, Sendable {
    case idle
    case inspecting
    case awaitingConfirmation
    case installing
    case enabling(String)
    case disabling(String)
    case uninstalling(String)
    case testing(String)
}

struct BlocksNativePluginConnectionTestResult: Equatable, Sendable {
    let pluginID: String
    let capability: BlocksNativePluginCapability
    let succeeded: Bool
    let outputSummary: String?
    let errorCode: String?
    let errorMessage: String?
}

struct BlocksNativePluginRuntimeLoadFailure: Equatable, Sendable, Identifiable {
    let pluginID: String
    let displayName: String
    let capability: BlocksNativePluginCapability
    let message: String

    var id: String {
        "\(pluginID)::\(capability.rawValue)"
    }
}

enum BlocksNativePluginUninstallCheckpoint: Equatable, Sendable {
    case disabled
    case tombstonePersisted
    case secretsRemoved
    case metadataRemoved
    case packageRemoved
}

enum BlocksNativePluginUpgradeCheckpoint: Equatable, Sendable {
    case transactionPersisted
    case beforePreviousPackageRemoval
}

private struct BlocksNativePluginUninstallTombstone:
    Codable,
    Equatable,
    Sendable
{
    let pluginID: String
    let packageHash: String
    let installedRelativePath: String
    let secretIDs: [String]
}

/// Durable forward-recovery record for every approved same-ID package upgrade.
///
/// The record deliberately contains identifiers and package hashes only.
/// Secret material remains exclusively in Keychain. Persisting this record
/// before metadata changes makes an interrupted upgrade recoverable without
/// writing a secret backup to disk. `revokedSecretIDs` may be empty; package
/// replacement still needs the same atomic forward-recovery contract.
private struct BlocksNativePluginUpgradeSecretTombstone:
    Codable,
    Equatable,
    Sendable
{
    let pluginID: String
    let previousPackageHash: String
    let previousInstalledRelativePath: String
    let replacementPackageHash: String
    let replacementInstalledRelativePath: String
    let revokedSecretIDs: [String]
}

enum BlocksNativePluginManagerError: Error, LocalizedError, Equatable {
    case operationInProgress
    case storageUnavailable
    case pendingInstallationMissing
    case pendingInstallationChanged
    case managedRootIsSymbolicLink
    case installedPackageMissing
    case installedPathEscapesRoot
    case packageSnapshotIncomplete(String)
    case fileWriteFailed(String)
    case missingRequiredSecret(String)
    case missingRequiredConfiguration(String)
    case validationRequired
    case reservedOfficialIdentifier(String)
    case externalInstallationUnavailable
    case rollbackIncomplete(String)
    case recoveryConflict(String)

    var code: String {
        switch self {
        case .operationInProgress: "plugin_operation_in_progress"
        case .storageUnavailable: "plugin_storage_unavailable"
        case .pendingInstallationMissing: "plugin_installation_missing"
        case .pendingInstallationChanged: "plugin_package_changed"
        case .managedRootIsSymbolicLink: "plugin_root_is_symbolic_link"
        case .installedPackageMissing: "plugin_package_missing"
        case .installedPathEscapesRoot: "plugin_path_invalid"
        case .packageSnapshotIncomplete: "plugin_snapshot_incomplete"
        case .fileWriteFailed: "plugin_file_write_failed"
        case .missingRequiredSecret: "plugin_secret_missing"
        case .missingRequiredConfiguration: "plugin_configuration_missing"
        case .validationRequired: "plugin_validation_required"
        case .reservedOfficialIdentifier: "plugin_identifier_reserved"
        case .externalInstallationUnavailable: "plugin_external_unavailable"
        case .rollbackIncomplete: "plugin_rollback_incomplete"
        case .recoveryConflict: "plugin_recovery_conflict"
        }
    }

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another plugin operation is already in progress."
        case .storageUnavailable:
            return "The plugin metadata storage is unavailable."
        case .pendingInstallationMissing:
            return "The pending plugin installation no longer exists."
        case .pendingInstallationChanged:
            return "The plugin package changed after review. Review it again before installation."
        case .managedRootIsSymbolicLink:
            return "The managed plugin directory cannot be a symbolic link."
        case .installedPackageMissing:
            return "The installed plugin package is missing."
        case .installedPathEscapesRoot:
            return "The installed plugin path escapes the managed plugin directory."
        case let .packageSnapshotIncomplete(path):
            return "The validated plugin snapshot is missing \(path)."
        case let .fileWriteFailed(path):
            return "The plugin file could not be installed: \(path)."
        case let .missingRequiredSecret(secretID):
            return "Configure the required plugin secret before enabling: \(secretID)."
        case let .missingRequiredConfiguration(fieldID):
            return "Configure the required plugin field before enabling: \(fieldID)."
        case .validationRequired:
            return "Run a successful connection test for the current plugin configuration before enabling it."
        case let .reservedOfficialIdentifier(pluginID):
            return "The plugin identifier is reserved for a Blocks built-in package: \(pluginID)."
        case .externalInstallationUnavailable:
            return "This distribution channel only permits built-in plugin packages."
        case let .rollbackIncomplete(operation):
            return "The plugin \(operation) failed and its rollback was incomplete."
        case let .recoveryConflict(pluginID):
            return "An interrupted plugin operation conflicts with the installed plugin: \(pluginID)."
        }
    }
}

private struct UnavailableBlocksNativePluginMetadataStore:
    BlocksNativePluginMetadataStoring
{
    func list() throws -> [BlocksNativePluginMetadata] {
        throw BlocksNativePluginManagerError.storageUnavailable
    }

    func metadata(id: String) throws -> BlocksNativePluginMetadata {
        throw BlocksNativePluginManagerError.storageUnavailable
    }

    func installApproved(
        package: BlocksNativePluginValidatedPackage,
        installedRelativePath: String,
        permissions: [String],
        domains: [String],
        installationOrigin: BlocksNativePluginInstallationOrigin,
        builtInCatalogVersion: String?,
        now: Date
    ) throws -> BlocksNativePluginMetadata {
        throw BlocksNativePluginManagerError.storageUnavailable
    }

    func setEnabled(
        _ isEnabled: Bool,
        pluginID: String,
        now: Date
    ) throws -> BlocksNativePluginMetadata {
        throw BlocksNativePluginManagerError.storageUnavailable
    }

    func remove(pluginID: String) throws {
        throw BlocksNativePluginManagerError.storageUnavailable
    }
}

/// Executes every plugin persistence operation on one dedicated serial queue.
///
/// Package validation, SQLite, filesystem recovery and Keychain can all block.
/// Keeping those calls behind one executor both protects the main actor and
/// prevents recovery from racing a mutation against the same managed package.
private final class BlocksNativePluginPersistenceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.blocks.translation-plugin.persistence",
        qos: .utility
    )

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct BlocksNativePluginReloadOutcome: Sendable {
    let plugins: [BlocksNativePluginMetadata]
    let validatedPluginIDs: Set<String>
    let validationDisabledPluginIDs: Set<String>
    let recoveryErrorMessage: String?
}

private struct BlocksNativePluginValidationSnapshot: Sendable {
    let plugins: [BlocksNativePluginMetadata]
    let validatedPluginIDs: Set<String>
    let disabledPluginIDs: Set<String>
}

private struct BlocksNativePluginDeclaredSecret {
    let maximumLength: Int?
}

private struct BlocksNativePluginUpgradeSecretContract: Equatable {
    let fieldType: BlocksNativePluginConfigurationFieldType?
    let allowedDomains: [String]
}

private extension BlocksNativePluginManifest {
    func declaredSecret(
        id secretID: String
    ) -> BlocksNativePluginDeclaredSecret? {
        if schemaVersion == 1 {
            guard permissions.secrets.contains(where: {
                $0.id == secretID
            }) else {
                return nil
            }
            return BlocksNativePluginDeclaredSecret(maximumLength: nil)
        }
        guard let field = configurationFields.first(where: {
            $0.id == secretID && $0.type.isSensitive
        }) else {
            return nil
        }
        return BlocksNativePluginDeclaredSecret(
            maximumLength: field.maximumLength
        )
    }

    func upgradeSecretContracts()
        -> [String: BlocksNativePluginUpgradeSecretContract] {
        if schemaVersion == 1 {
            return Dictionary(
                uniqueKeysWithValues: permissions.secrets.map {
                    (
                        $0.id,
                        BlocksNativePluginUpgradeSecretContract(
                            fieldType: nil,
                            allowedDomains: []
                        )
                    )
                }
            )
        }
        return Dictionary(
            uniqueKeysWithValues: configurationFields.compactMap { field in
                guard field.type.isSensitive else {
                    return nil
                }
                return (
                    field.id,
                    BlocksNativePluginUpgradeSecretContract(
                        fieldType: field.type,
                        allowedDomains: field.type == .sessionCredential
                            ? Array(
                                Set(
                                    field.allowedDomains.map {
                                        $0.lowercased()
                                    }
                                )
                            ).sorted()
                            : []
                    )
                )
            }
        )
    }
}

@MainActor
final class BlocksNativePluginManager: ObservableObject {
    @Published private(set) var plugins: [BlocksNativePluginMetadata] = []
    @Published private(set) var pendingInstallation: BlocksNativePluginPendingInstallation?
    @Published private(set) var operation: BlocksNativePluginManagerOperation = .idle
    @Published private(set) var lastConnectionTest: BlocksNativePluginConnectionTestResult?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var runtimeLoadFailures:
        [BlocksNativePluginRuntimeLoadFailure] = []
    @Published private(set) var snapshotIsReady = false
    @Published private(set) var configurationRevision: UInt64 = 0
    @Published private(set) var validatedPluginIDs: Set<String> = []

    private let repository: any BlocksNativePluginMetadataStoring
    private let managedRoot: URL
    private let executor: any BlocksNativePluginExecuting
    private let secretStore: any BlocksNativePluginSecretStoring
    private let configurationStore:
        any BlocksNativePluginConfigurationStoring
    private let validationStore:
        any BlocksNativePluginValidationStoring
    let platformRepository: BlocksPluginPlatformRepository?
    let debugLogStore: BlocksPluginDebugLogStore?
    let hostOperationRouter: BlocksPluginHostOperationRouter
    nonisolated let hostOperationAdmissionGate: BlocksPluginHostOperationAdmissionGate
    let executionSettlementGate: PluginExecutionSettlementGate
    private let storageInitializationFailure: String?
    private let installSnapshotStagingHook: (@Sendable () throws -> Void)?
    private let uninstallCheckpointHook:
        (@Sendable (BlocksNativePluginUninstallCheckpoint) throws -> Void)?
    private let upgradeCheckpointHook:
        (@Sendable (BlocksNativePluginUpgradeCheckpoint) throws -> Void)?
    private let hookBindingsLoadedHook: (@Sendable () async -> Void)?
    private let persistenceWorker = BlocksNativePluginPersistenceWorker()
    private var managedRecoveryFailed = false
    private var reloadGeneration: UInt64 = 0
    /// A lifecycle cutoff for results that were already executing in an
    /// isolated runner.  Unlike the host-operation gate, this also covers a
    /// runner reply that arrives after disable, uninstall, or replacement.
    private var executionGenerationByPluginID: [String: UInt64] = [:]
    private var reloadCompletionWaiters:
        [CheckedContinuation<Void, Never>] = []

    init(
        repository: any BlocksNativePluginMetadataStoring,
        managedRoot: URL,
        executor: any BlocksNativePluginExecuting = BlocksNativePluginUnavailableExecutor(),
        secretStore: any BlocksNativePluginSecretStoring = BlocksNativePluginSecretStore(),
        configurationStore:
            any BlocksNativePluginConfigurationStoring =
                BlocksNativePluginConfigurationStore(),
        validationStore:
            any BlocksNativePluginValidationStoring =
                BlocksNativePluginValidationStore(),
        platformRepository: BlocksPluginPlatformRepository? = nil,
        debugLogStore: BlocksPluginDebugLogStore? = nil,
        hostOperationRouter: BlocksPluginHostOperationRouter = .init(),
        hostOperationAdmissionGate: BlocksPluginHostOperationAdmissionGate = .init(),
        executionSettlementGate: PluginExecutionSettlementGate? = nil,
        storageInitializationFailure: String? = nil,
        installSnapshotStagingHook: (@Sendable () throws -> Void)? = nil,
        uninstallCheckpointHook:
            (@Sendable (BlocksNativePluginUninstallCheckpoint) throws -> Void)? = nil,
        upgradeCheckpointHook:
            (@Sendable (BlocksNativePluginUpgradeCheckpoint) throws -> Void)? = nil,
        hookBindingsLoadedHook: (@Sendable () async -> Void)? = nil
    ) {
        self.repository = repository
        self.managedRoot = managedRoot.standardizedFileURL
        self.executor = executor
        self.secretStore = secretStore
        self.configurationStore = configurationStore
        self.validationStore = validationStore
        self.platformRepository = platformRepository
        self.debugLogStore = debugLogStore
        self.hostOperationRouter = hostOperationRouter
        self.hostOperationAdmissionGate = hostOperationAdmissionGate
        self.executionSettlementGate = executionSettlementGate
            ?? PluginExecutionSettlementGate()
        self.storageInitializationFailure = storageInitializationFailure
        self.installSnapshotStagingHook = installSnapshotStagingHook
        self.uninstallCheckpointHook = uninstallCheckpointHook
        self.upgradeCheckpointHook = upgradeCheckpointHook
        self.hookBindingsLoadedHook = hookBindingsLoadedHook
        if let storageInitializationFailure {
            lastErrorMessage = storageInitializationFailure
        }
    }

    convenience init(
        database: AppDatabase,
        storageEnvironment: StorageEnvironment,
        executor: any BlocksNativePluginExecuting = BlocksNativePluginUnavailableExecutor(),
        secretStore: any BlocksNativePluginSecretStoring = BlocksNativePluginSecretStore()
    ) {
        self.init(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: storageEnvironment.rootDirectory
                .appendingPathComponent("TranslationPlugins", isDirectory: true),
            executor: executor,
            secretStore: secretStore
        )
    }

    convenience init(storageUnavailableBecause error: Error) {
        self.init(
            repository: UnavailableBlocksNativePluginMetadataStore(),
            managedRoot: URL(
                fileURLWithPath: "/BlocksTranslationPlugins-Unavailable",
                isDirectory: true
            ),
            storageInitializationFailure: error.localizedDescription
        )
    }

    var storageIsAvailable: Bool {
        storageInitializationFailure == nil
    }

    var pluginSnapshotIsAuthoritative: Bool {
        storageIsAvailable
            && snapshotIsReady
            && !managedRecoveryFailed
            && lastErrorMessage == nil
    }

    var isReadyForMutations: Bool {
        storageIsAvailable
            && snapshotIsReady
            && !managedRecoveryFailed
    }

    func manifest(pluginID: String) -> BlocksNativePluginManifest? {
        guard let metadata = plugins.first(where: { $0.id == pluginID }) else {
            return nil
        }
        return try? JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: Data(metadata.manifestJSON.utf8)
        )
    }

    func hookBindings(pluginID: String) async -> [BlocksPluginHookBinding] {
        guard let platformRepository else { return [] }
        let bindings = (try? await Task.detached {
            try platformRepository.hookBindings(pluginID: pluginID)
        }.value) ?? []
        return Self.filterBindingsForDistribution(
            bindings,
            pluginID: \.pluginID,
            pluginSnapshot: plugins
        )
    }

    func hookBindings(
        event: BlocksPluginEventName,
        distributionChannel: DistributionChannel = .current
    ) async -> [BlocksPluginHookBinding] {
        guard let platformRepository else { return [] }
        let bindings = (try? await persistenceWorker.perform {
            try platformRepository.hookBindings(for: event)
        }) ?? []
        await hookBindingsLoadedHook?()
        return Self.filterBindingsForDistribution(
            bindings,
            pluginID: \.pluginID,
            pluginSnapshot: plugins,
            distributionChannel: distributionChannel
        )
    }

    func setHookEnabled(
        _ enabled: Bool,
        pluginID: String,
        hookID: String
    ) async throws {
        guard let platformRepository else {
            throw BlocksNativePluginManagerError.storageUnavailable
        }
        try await Task.detached {
            try platformRepository.setHookEnabled(
                enabled,
                pluginID: pluginID,
                hookID: hookID
            )
        }.value
    }

    func reorderHooks(
        event: BlocksPluginEventName,
        orderedBindingIDs: [String]
    ) async throws {
        guard let platformRepository else {
            throw BlocksNativePluginManagerError.storageUnavailable
        }
        try await persistenceWorker.perform {
            try platformRepository.reorderHooks(
                event: event,
                orderedBindingIDs: orderedBindingIDs
            )
        }
    }

    func scheduleBindings(
        pluginID: String? = nil,
        runnableOnly: Bool = true
    ) async -> [BlocksPluginScheduleBinding] {
        guard let platformRepository else { return [] }
        let bindings = (try? await persistenceWorker.perform {
            try platformRepository.scheduleBindings(
                pluginID: pluginID,
                runnableOnly: runnableOnly
            )
        }) ?? []
        return Self.filterBindingsForDistribution(
            bindings,
            pluginID: \.pluginID,
            pluginSnapshot: plugins
        )
    }

    func setScheduleEnabled(
        _ enabled: Bool,
        pluginID: String,
        scheduleID: String
    ) async throws {
        guard let platformRepository else {
            throw BlocksNativePluginManagerError.storageUnavailable
        }
        try await persistenceWorker.perform {
            try platformRepository.setScheduleEnabled(
                enabled,
                pluginID: pluginID,
                scheduleID: scheduleID
            )
        }
    }

    func updateScheduleTiming(
        pluginID: String,
        scheduleID: String,
        nextFireAt: Date?,
        lastFiredAt: Date?
    ) async {
        guard let platformRepository else { return }
        try? await persistenceWorker.perform {
            try platformRepository.updateScheduleTiming(
                pluginID: pluginID,
                scheduleID: scheduleID,
                nextFireAt: nextFireAt,
                lastFiredAt: lastFiredAt
            )
        }
    }

    func setDebugEnabled(_ enabled: Bool, pluginID: String) async throws {
        guard let platformRepository else {
            throw BlocksNativePluginManagerError.storageUnavailable
        }
        try await Task.detached {
            try platformRepository.setDebugEnabled(enabled, pluginID: pluginID)
        }.value
        await reload()
    }

    func clearSafetyDisable(pluginID: String) async throws {
        guard let platformRepository else {
            throw BlocksNativePluginManagerError.storageUnavailable
        }
        try await Task.detached {
            try platformRepository.clearSafetyDisable(pluginID: pluginID)
        }.value
        await reopenHostOperationsIfMetadataIsRunnable(pluginID: pluginID)
        await reload()
    }

    func reload() async {
        guard operation == .idle else {
            return
        }
        guard let storageInitializationFailure else {
            // This is the reload linearization point: runner replies which
            // have already returned must wait until validation/recovery has
            // published its durable cutoffs.
            executionSettlementGate.beginGlobalSettlement()
            reloadGeneration &+= 1
            let generation = reloadGeneration
            snapshotIsReady = false
            let repository = repository
            let managedRoot = managedRoot
            let executor = executor
            let secretStore = secretStore
            let configurationStore = configurationStore
            let validationStore = validationStore
            let uninstallCheckpointHook = uninstallCheckpointHook
            let outcome: BlocksNativePluginReloadOutcome
            do {
                outcome = try await persistenceWorker.perform {
                    do {
                        try Self.reconcileManagedStorage(
                            repository: repository,
                            managedRoot: managedRoot,
                            executor: executor,
                            secretStore: secretStore,
                            configurationStore: configurationStore,
                            validationStore: validationStore,
                            uninstallCheckpointHook: uninstallCheckpointHook
                        )
                        let validationSnapshot =
                            try Self.reconcileValidationState(
                                repository: repository,
                                executor: executor,
                                configurationStore: configurationStore,
                                validationStore: validationStore
                            )
                        return BlocksNativePluginReloadOutcome(
                            plugins: validationSnapshot.plugins,
                            validatedPluginIDs:
                                validationSnapshot.validatedPluginIDs,
                            validationDisabledPluginIDs:
                                validationSnapshot.disabledPluginIDs,
                            recoveryErrorMessage: nil
                        )
                    } catch {
                        return BlocksNativePluginReloadOutcome(
                            plugins: (try? repository.list()) ?? [],
                            validatedPluginIDs: [],
                            validationDisabledPluginIDs: [],
                            recoveryErrorMessage: error.localizedDescription
                        )
                    }
                }
            } catch {
                outcome = BlocksNativePluginReloadOutcome(
                    plugins: [],
                    validatedPluginIDs: [],
                    validationDisabledPluginIDs: [],
                    recoveryErrorMessage: error.localizedDescription
                )
            }
            guard generation == reloadGeneration else {
                executionSettlementGate.finishGlobalSettlement()
                await waitForCurrentReloadCompletionIfNeeded()
                return
            }
            let allowedPlugins = Self.allowedPluginsForDistribution(
                outcome.plugins
            )
            applyValidationLifecycleCutoffs(
                outcome.validationDisabledPluginIDs
            )
            plugins = allowedPlugins
            validatedPluginIDs = outcome.validatedPluginIDs.intersection(
                Set(allowedPlugins.map(\.id))
            )
            managedRecoveryFailed = outcome.recoveryErrorMessage != nil
            snapshotIsReady = outcome.recoveryErrorMessage == nil
            lastErrorMessage = outcome.recoveryErrorMessage
            // Persisted validation cutoffs are also mirrored in the runtime
            // gate before any waiting runner reply is released.
            executionSettlementGate.finishGlobalSettlement(
                invalidatingPluginIDs: outcome.validationDisabledPluginIDs,
                invalidateAll: outcome.recoveryErrorMessage != nil
            )
            resumeReloadCompletionWaiters()
            return
        }
        plugins = []
        validatedPluginIDs = []
        snapshotIsReady = false
        lastErrorMessage = storageInitializationFailure
        resumeReloadCompletionWaiters()
    }

    func updateRuntimeLoadFailures(
        _ failures: [BlocksNativePluginRuntimeLoadFailure]
    ) {
        runtimeLoadFailures = failures
    }

    func cancelActiveExecutions(pluginID: String) {
        executor.cancelExecutions(pluginID: pluginID)
    }

    func cancelAllActiveExecutions() {
        for plugin in plugins {
            executor.cancelExecutions(pluginID: plugin.id)
        }
    }

    func prepareInstallation(
        from packageURL: URL
    ) async throws -> BlocksNativePluginPendingInstallation {
        #if BLOCKS_APP_STORE_BETA
        throw BlocksNativePluginManagerError.externalInstallationUnavailable
        #else
        do {
            let package = try await persistenceWorker.perform {
                try BlocksNativePluginPackageValidator().validate(directory: packageURL)
            }
            try Task.checkCancellation()
            return try await prepareInstallation(
                validatedPackage: package,
                sourceDisplayName: packageURL.lastPathComponent
            )
        } catch {
            if operation == .idle {
                lastErrorMessage = error.localizedDescription
            }
            throw error
        }
        #endif
    }

    func prepareInstallation(
        validatedPackage package: BlocksNativePluginValidatedPackage,
        sourceDisplayName: String
    ) async throws -> BlocksNativePluginPendingInstallation {
        guard !package.manifest.id.hasPrefix("com.blocks.builtin.") else {
            throw BlocksNativePluginManagerError.reservedOfficialIdentifier(
                package.manifest.id
            )
        }
        #if BLOCKS_APP_STORE_BETA
        throw BlocksNativePluginManagerError.externalInstallationUnavailable
        #else
        return try await prepareValidatedInstallation(
            package,
            sourceDisplayName: sourceDisplayName,
            installationOrigin: .external,
            builtInCatalogVersion: nil
        )
        #endif
    }

    func prepareBuiltInInstallation(
        entryID: String,
        catalog: BlocksBuiltInPluginCatalog
    ) async throws -> BlocksNativePluginPendingInstallation {
        let matchingEntries = catalog.document.entries.filter {
            $0.id == entryID
        }
        guard matchingEntries.count == 1,
              let entry = matchingEntries.first else {
            throw BlocksBuiltInPluginCatalogError.entryUnavailable(entryID)
        }
        let package = try await Task.detached(priority: .utility) {
            try catalog.validatedPackage(for: entry)
        }.value
        return try await prepareValidatedInstallation(
            package,
            sourceDisplayName: entry.localized().name,
            installationOrigin: .builtIn,
            builtInCatalogVersion: catalog.document.catalogVersion
        )
    }

    private func prepareValidatedInstallation(
        _ package: BlocksNativePluginValidatedPackage,
        sourceDisplayName: String,
        installationOrigin: BlocksNativePluginInstallationOrigin,
        builtInCatalogVersion: String?
    ) async throws -> BlocksNativePluginPendingInstallation {
        try await requireOperation(.idle)
        operation = .inspecting
        lastErrorMessage = nil
        let pending = BlocksNativePluginPendingInstallation(
            id: UUID(),
            sourceDisplayName: sourceDisplayName,
            confirmation: package.installationConfirmation,
            installationOrigin: installationOrigin,
            builtInCatalogVersion: builtInCatalogVersion,
            package: package
        )
        pendingInstallation = pending
        operation = .awaitingConfirmation
        return pending
    }

    func cancelPendingInstallation() {
        guard operation == .awaitingConfirmation else {
            return
        }
        pendingInstallation = nil
        operation = .idle
    }

    func cancelPendingInstallation(id: UUID) {
        guard operation == .awaitingConfirmation,
              pendingInstallation?.id == id else {
            return
        }
        pendingInstallation = nil
        operation = .idle
    }

    @discardableResult
    func confirmAndInstall(
        pendingID: UUID
    ) async throws -> BlocksNativePluginMetadata {
        guard let pending = pendingInstallation, pending.id == pendingID else {
            throw BlocksNativePluginManagerError.pendingInstallationMissing
        }
        #if BLOCKS_APP_STORE_BETA
        guard pending.installationOrigin == .builtIn else {
            throw BlocksNativePluginManagerError.externalInstallationUnavailable
        }
        #endif
        try await requireOperation(.awaitingConfirmation)
        try Task.checkCancellation()
        operation = .installing
        lastErrorMessage = nil
        invalidateExecutionGeneration(pluginID: pending.package.manifest.id)
        // Close runtime admission before the first suspension. A replacement
        // must not start new hooks from the still-enabled persisted snapshot
        // while the upgrade is inspecting metadata or draining old work.
        revokeHostOperations(pluginID: pending.package.manifest.id)
        var createdSnapshotRelativePath: String?
        var upgradeTombstone:
            BlocksNativePluginUpgradeSecretTombstone?
        var metadataWasCommitted = false
        var interruptionBeforeMetadataCommit = false
        let managedRoot = self.managedRoot
        let repository = self.repository
        let validationStore = self.validationStore
        do {
            let relativePath = "\(pending.package.manifest.id)/\(pending.package.packageSHA256)"
            let package = pending.package
            let installSnapshotStagingHook = installSnapshotStagingHook
            let previousMetadata: BlocksNativePluginMetadata?
            do {
                previousMetadata = try await persistenceWorker.perform {
                    try repository.metadata(id: package.manifest.id)
                }
            } catch let error as BlocksNativePluginMetadataRepositoryError {
                guard case .pluginNotFound = error else { throw error }
                previousMetadata = nil
            }
            try Task.checkCancellation()
            // A reviewed package is still not trusted to execute. Disable the
            // previous revision and invalidate its connection-test proof before
            // any package snapshot is replaced, including same-hash reinstalls.
            if previousMetadata != nil {
                await revokeHostOperationsAndDrain(
                    pluginID: package.manifest.id
                )
                executor.cancelExecutions(pluginID: package.manifest.id)
            }
            try await persistenceWorker.perform {
                if previousMetadata?.isEnabled == true {
                    _ = try repository.setEnabled(
                        false,
                        pluginID: package.manifest.id,
                        now: Date()
                    )
                }
                try validationStore.invalidate(
                    pluginID: package.manifest.id
                )
            }
            if previousMetadata != nil {
                executor.cancelExecutions(pluginID: package.manifest.id)
            }
            validatedPluginIDs.remove(package.manifest.id)
            let didCreateSnapshot = try await persistenceWorker.perform {
                try Self.installSnapshot(
                    package,
                    relativePath: relativePath,
                    managedRoot: managedRoot,
                    stagingOpenedHook: installSnapshotStagingHook
                )
            }
            if didCreateSnapshot {
                createdSnapshotRelativePath = relativePath
            }
            if let previousMetadata,
               previousMetadata.packageHash != package.packageSHA256 {
                let previousManifest = try await persistenceWorker.perform {
                    try Self.validatedStoredManifest(previousMetadata)
                }
                let previousSecretContracts =
                    previousManifest.upgradeSecretContracts()
                let replacementSecretContracts =
                    package.manifest.upgradeSecretContracts()
                let revokedSecretIDs = previousSecretContracts.compactMap {
                    secretID, previousContract in
                    guard replacementSecretContracts[secretID]
                        == previousContract else {
                        return secretID
                    }
                    return nil
                }
                    .sorted()
                let tombstone = BlocksNativePluginUpgradeSecretTombstone(
                    pluginID: package.manifest.id,
                    previousPackageHash: previousMetadata.packageHash,
                    previousInstalledRelativePath:
                        previousMetadata.installedRelativePath,
                    replacementPackageHash: package.packageSHA256,
                    replacementInstalledRelativePath: relativePath,
                    revokedSecretIDs: revokedSecretIDs
                )
                try await persistenceWorker.perform {
                    try Self.persistUpgradeSecretTombstone(
                        tombstone,
                        managedRoot: managedRoot
                    )
                }
                upgradeTombstone = tombstone
                do {
                    try upgradeCheckpointHook?(.transactionPersisted)
                } catch {
                    interruptionBeforeMetadataCommit = true
                    throw error
                }
            }
            let platformRepository = platformRepository
            try await persistenceWorker.perform {
                try platformRepository?.validateSharedStateDeclarations(
                    pluginID: package.manifest.id,
                    platform: package.manifest.platform
                )
            }
            let permissions = Self.approvalPermissionTokens(for: package.manifest)
            let approved = try await persistenceWorker.perform {
                try repository.installApproved(
                    package: package,
                    installedRelativePath: relativePath,
                    permissions: permissions,
                    domains: package.manifest.permissions.network?.domains ?? [],
                    installationOrigin: pending.installationOrigin,
                    builtInCatalogVersion: pending.builtInCatalogVersion,
                    now: Date()
                )
            }
            let installed = try await persistenceWorker.perform {
                if approved.isEnabled {
                    return try repository.setEnabled(
                        false,
                        pluginID: approved.id,
                        now: Date()
                    )
                }
                return approved
            }
            if package.manifest.schemaVersion >= 4 {
                try await persistenceWorker.perform {
                    try platformRepository?.synchronizeManifest(
                        pluginID: package.manifest.id,
                        platform: package.manifest.platform
                    )
                }
            }
            metadataWasCommitted = true
            if let upgradeTombstone {
                let executor = executor
                let secretStore = secretStore
                let upgradeCheckpointHook = upgradeCheckpointHook
                try await persistenceWorker.perform {
                    try Self.completeInterruptedUpgradeSecretRevocation(
                        upgradeTombstone,
                        repository: repository,
                        managedRoot: managedRoot,
                        executor: executor,
                        secretStore: secretStore,
                        upgradeCheckpointHook: upgradeCheckpointHook,
                        cancelExecutionsBeforeRevocation: false
                    )
                }
            } else if let previousMetadata,
                      previousMetadata.installedRelativePath != relativePath {
                try await persistenceWorker.perform {
                    try Self.removeManagedSnapshotIfPresent(
                        relativePath: previousMetadata.installedRelativePath,
                        managedRoot: managedRoot
                    )
                }
            }
            createdSnapshotRelativePath = nil
            pendingInstallation = nil
            operation = .idle
            await refreshPluginSnapshot()
            return installed
        } catch {
            await reopenHostOperationsIfMetadataIsRunnable(
                pluginID: pending.package.manifest.id
            )
            if interruptionBeforeMetadataCommit {
                // Test-only checkpoint mirrors a process interruption: leave
                // the marker and staged replacement intact so startup recovery
                // proves it can distinguish prepare from committed metadata.
                managedRecoveryFailed = true
                operation = .awaitingConfirmation
                lastErrorMessage = error.localizedDescription
                throw error
            }
            if metadataWasCommitted, upgradeTombstone != nil {
                // The durable marker owns forward recovery from this point.
                // Removing either package here would make the transaction
                // impossible to finish after a Keychain or filesystem error.
                managedRecoveryFailed = true
                operation = .awaitingConfirmation
                lastErrorMessage = error.localizedDescription
                throw error
            }
            var rollbackSucceeded = true
            if let upgradeTombstone {
                do {
                    try await persistenceWorker.perform {
                        try Self.removeManagedSnapshotIfPresent(
                            relativePath:
                                upgradeTombstone
                                .replacementInstalledRelativePath,
                            managedRoot: managedRoot
                        )
                        try Self.removeUpgradeSecretTombstone(
                            upgradeTombstone,
                            managedRoot: managedRoot
                        )
                    }
                    createdSnapshotRelativePath = nil
                } catch {
                    rollbackSucceeded = false
                }
            }
            if let createdSnapshotRelativePath {
                do {
                    try await persistenceWorker.perform {
                        try Self.removeManagedSnapshotIfPresent(
                            relativePath: createdSnapshotRelativePath,
                            managedRoot: managedRoot
                        )
                    }
                } catch {
                    rollbackSucceeded = false
                }
            }
            operation = .awaitingConfirmation
            guard rollbackSucceeded else {
                let rollbackError =
                    BlocksNativePluginManagerError.rollbackIncomplete("install")
                lastErrorMessage = rollbackError.localizedDescription
                throw rollbackError
            }
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func setEnabled(
        _ isEnabled: Bool,
        pluginID: String
    ) async throws -> BlocksNativePluginMetadata {
        try await requireOperation(.idle)
        operation = isEnabled ? .enabling(pluginID) : .disabling(pluginID)
        if !isEnabled {
            invalidateExecutionGeneration(pluginID: pluginID)
            // Publish the lifecycle cutoff synchronously. Waiting for the gate
            // to drain is intentionally off the admission linearization point.
            revokeHostOperations(pluginID: pluginID)
            await revokeHostOperationsAndDrain(pluginID: pluginID)
            executor.cancelExecutions(pluginID: pluginID)
        }
        do {
            if isEnabled {
                let (_, package) = try await loadInstalledPackage(pluginID: pluginID)
                let secretStore = secretStore
                let requiredSecretIDs = package.manifest.permissions.secrets
                    .filter(\.required)
                    .map(\.id)
                    .sorted()
                let missingSecret: String? =
                    try await persistenceWorker.perform {
                    for secretID in requiredSecretIDs {
                        guard try secretStore.contains(
                            pluginID: pluginID,
                            secretID: secretID
                        ) else {
                            return secretID
                        }
                    }
                    return nil
                }
                if let missingSecret {
                    throw BlocksNativePluginManagerError.missingRequiredSecret(
                        missingSecret
                    )
                }
                let configurationStore = configurationStore
                let validationStore = validationStore
                let requiresConnectionValidation =
                    package.manifest.capabilities.contains(.translation)
                    || package.manifest.capabilities.contains(.ocr)
                let validationState =
                    try await persistenceWorker.perform {
                    let configuration: [String: JSONValue]
                    do {
                        configuration =
                            try configurationStore.activationConfiguration(
                                pluginID: pluginID,
                                manifest: package.manifest
                            )
                    } catch let error
                        as BlocksNativePluginConfigurationStoreError {
                        if case let .requiredFieldMissing(fieldID) = error {
                            throw BlocksNativePluginManagerError
                                .missingRequiredConfiguration(fieldID)
                        }
                        throw error
                    }
                    let revision =
                        try BlocksNativePluginValidationRevision.make(
                            packageHash: package.packageSHA256,
                            configuration: configuration,
                            credentialRevision:
                                try validationStore.credentialRevision(
                                    pluginID: pluginID
                                )
                        )
                    return (
                        revision: revision,
                        isValidated:
                            try validationStore.validatedRevision(
                                pluginID: pluginID
                            ) == revision
                    )
                }
                guard !requiresConnectionValidation
                    || validationState.isValidated else {
                    throw BlocksNativePluginManagerError.validationRequired
                }
                if !requiresConnectionValidation
                    && !validationState.isValidated {
                    try await persistenceWorker.perform {
                        try validationStore.markValidated(
                            validationState.revision,
                            pluginID: pluginID
                        )
                    }
                    validatedPluginIDs.insert(pluginID)
                }
            }
            try Task.checkCancellation()
            let repository = repository
            let metadata = try await persistenceWorker.perform {
                try repository.setEnabled(
                    isEnabled,
                    pluginID: pluginID,
                    now: Date()
                )
            }
            if !isEnabled {
                // The second cancellation closes the registration race where an
                // invocation starts after the optimistic cancellation but before
                // the authoritative disabled state is committed.
                executor.cancelExecutions(pluginID: pluginID)
            } else if metadata.isEnabled,
                      metadata.approvalStatus == .approved,
                      !metadata.safetyDisabled {
                hostOperationAdmissionGate.allow(pluginID: pluginID)
            }
            operation = .idle
            await refreshPluginSnapshot()
            return metadata
        } catch {
            if !isEnabled {
                await reopenHostOperationsIfMetadataIsRunnable(pluginID: pluginID)
            }
            operation = .idle
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func uninstall(pluginID: String) async throws {
        try await requireOperation(.idle)
        operation = .uninstalling(pluginID)
        invalidateExecutionGeneration(pluginID: pluginID)
        revokeHostOperations(pluginID: pluginID)
        await revokeHostOperationsAndDrain(pluginID: pluginID)
        executor.cancelExecutions(pluginID: pluginID)
        let repository = self.repository
        let managedRoot = self.managedRoot
        let executor = self.executor
        let secretStore = self.secretStore
        let configurationStore = self.configurationStore
        let validationStore = self.validationStore
        let debugLogStore = self.debugLogStore
        let uninstallCheckpointHook = self.uninstallCheckpointHook
        var uninstallTombstoneWasPersisted = false
        do {
            var metadata = try await persistenceWorker.perform {
                try repository.metadata(id: pluginID)
            }
            try Task.checkCancellation()
            if metadata.isEnabled {
                metadata = try await persistenceWorker.perform {
                    try repository.setEnabled(
                        false,
                        pluginID: pluginID,
                        now: Date()
                    )
                }
            }
            let persistedMetadata = metadata
            executor.cancelExecutions(pluginID: pluginID)
            try uninstallCheckpointHook?(.disabled)

            let tombstone = try await persistenceWorker.perform {
                let manifest = try JSONDecoder().decode(
                    BlocksNativePluginManifest.self,
                    from: Data(persistedMetadata.manifestJSON.utf8)
                )
                try BlocksNativePluginPackageValidator().validate(
                    manifest: manifest
                )
                return BlocksNativePluginUninstallTombstone(
                    pluginID: pluginID,
                    packageHash: persistedMetadata.packageHash,
                    installedRelativePath:
                        persistedMetadata.installedRelativePath,
                    secretIDs: manifest.permissions.secrets.map(\.id).sorted()
                )
            }
            try await persistenceWorker.perform {
                try Self.persistUninstallTombstone(
                    tombstone,
                    managedRoot: managedRoot
                )
            }
            uninstallTombstoneWasPersisted = true
            try uninstallCheckpointHook?(.tombstonePersisted)

            try await persistenceWorker.perform {
                try debugLogStore?.clear(pluginID: pluginID)
                try Self.completeInterruptedUninstall(
                    tombstone,
                    repository: repository,
                    managedRoot: managedRoot,
                    executor: executor,
                    secretStore: secretStore,
                    configurationStore: configurationStore,
                    validationStore: validationStore,
                    uninstallCheckpointHook: uninstallCheckpointHook
                )
            }
            validatedPluginIDs.remove(pluginID)
            operation = .idle
            let reloadedPlugins = try await persistenceWorker.perform {
                try repository.list()
            }
            plugins = Self.allowedPluginsForDistribution(reloadedPlugins)
            snapshotIsReady = true
            managedRecoveryFailed = false
            lastErrorMessage = nil
        } catch {
            executor.cancelExecutions(pluginID: pluginID)
            if uninstallTombstoneWasPersisted {
                // The durable marker now owns forward recovery. Keep this
                // manager fail-closed until an explicit reload reconciles it;
                // otherwise a same-process enable can revive the package that
                // the user already asked to uninstall.
                managedRecoveryFailed = true
                snapshotIsReady = false
            } else {
                await reopenHostOperationsIfMetadataIsRunnable(pluginID: pluginID)
            }
            operation = .idle
            if let currentPlugins = try? await persistenceWorker.perform({
                try repository.list()
            }) {
                plugins = Self.allowedPluginsForDistribution(currentPlugins)
            }
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// A failed lifecycle mutation may only reopen the synchronous host path
    /// when persisted metadata still says the plugin is runnable.  In
    /// particular, an uninstall that has reached a disabled/tombstoned state
    /// must not be revived merely because a later cleanup step failed.
    private func reopenHostOperationsIfMetadataIsRunnable(
        pluginID: String
    ) async {
        let repository = repository
        guard let metadata = try? await persistenceWorker.perform({
            try repository.metadata(id: pluginID)
        }), metadata.isEnabled,
           metadata.approvalStatus == .approved,
           !metadata.safetyDisabled else {
            return
        }
        hostOperationAdmissionGate.allow(pluginID: pluginID)
    }

    func revokeHostOperationsAndDrain(pluginID: String) async {
        let gate = hostOperationAdmissionGate
        gate.revoke(pluginID: pluginID)
        await Task.detached {
            gate.drain(pluginID: pluginID)
        }.value
    }

    func revokeHostOperations(pluginID: String) {
        hostOperationAdmissionGate.revoke(pluginID: pluginID)
    }

    func executionGeneration(pluginID: String) -> UInt64 {
        executionGenerationByPluginID[pluginID, default: 0]
    }

    func isExecutionCurrent(pluginID: String, generation: UInt64) -> Bool {
        executionGeneration(pluginID: pluginID) == generation
            && !hostOperationAdmissionGate.isRevoked(pluginID: pluginID)
    }

    /// App termination permanently revokes host operations before dispatching
    /// its final hook.  The hook runner may still start for bounded, fail-open
    /// cleanup, but it must remain tied to the current installed revision.
    func isExecutionGenerationCurrent(
        pluginID: String,
        generation: UInt64
    ) -> Bool {
        executionGeneration(pluginID: pluginID) == generation
    }

    func invalidateExecutionGeneration(pluginID: String) {
        executionGenerationByPluginID[pluginID, default: 0] &+= 1
        executionSettlementGate.invalidatePlugin(pluginID)
    }

    /// Revalidates an asynchronous host action against persisted plugin state
    /// after it has crossed the shared admission barrier. This closes the
    /// window where the published snapshot still looks runnable while a
    /// safety cutoff has already committed to SQLite.
    func requireRunnableHostActionPermission(
        pluginID: String,
        permission: String,
        unapprovedOperation: String? = nil
    ) async throws {
        let repository = repository
        let metadata = try await persistenceWorker.perform {
            try repository.metadata(id: pluginID)
        }
        guard metadata.approvalStatus == .approved else {
            throw BlocksNativePluginExecutionError.pluginNotApproved
        }
        guard metadata.isEnabled, !metadata.safetyDisabled else {
            throw BlocksNativePluginExecutionError.pluginDisabled
        }
        guard metadata.approvedPermissions.contains(permission) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "unapproved:\(unapprovedOperation ?? permission)"
            )
        }
    }

    func connectionTest(
        pluginID: String,
        capability: BlocksNativePluginCapability,
        testText: String? = nil,
        testImage: TranslationSourceEncodedImage? = nil
    ) async -> BlocksNativePluginConnectionTestResult {
        do {
            try await requireRecoveryReady()
            try Task.checkCancellation()
        } catch is CancellationError {
            let result = BlocksNativePluginConnectionTestResult(
                pluginID: pluginID,
                capability: capability,
                succeeded: false,
                outputSummary: nil,
                errorCode: "request_cancelled",
                errorMessage: "The connection test was cancelled."
            )
            lastConnectionTest = result
            return result
        } catch {
            let result = BlocksNativePluginConnectionTestResult(
                pluginID: pluginID,
                capability: capability,
                succeeded: false,
                outputSummary: nil,
                errorCode: Self.errorCode(for: error),
                errorMessage: error.localizedDescription
            )
            lastConnectionTest = result
            return result
        }
        guard operation == .idle else {
            let result = BlocksNativePluginConnectionTestResult(
                pluginID: pluginID,
                capability: capability,
                succeeded: false,
                outputSummary: nil,
                errorCode: "plugin_manager_busy",
                errorMessage:
                    BlocksNativePluginManagerError.operationInProgress
                        .localizedDescription
            )
            lastConnectionTest = result
            return result
        }
        operation = .testing(pluginID)
        let result: BlocksNativePluginConnectionTestResult
        var shouldRefreshSnapshot = false
        do {
            let (metadata, package) = try await loadInstalledPackage(pluginID: pluginID)
            try Task.checkCancellation()
            guard package.manifest.capabilities.contains(capability) else {
                throw BlocksNativePluginExecutionError.capabilityUnavailable
            }
            let configurationStore = configurationStore
            let validationStore = validationStore
            let validationInput =
                try await persistenceWorker.perform {
                    let configuration =
                        try configurationStore.activationConfiguration(
                        pluginID: pluginID,
                        manifest: package.manifest
                    )
                    let revision =
                        try BlocksNativePluginValidationRevision.make(
                            packageHash: package.packageSHA256,
                            configuration: configuration,
                            credentialRevision:
                                try validationStore.credentialRevision(
                                    pluginID: pluginID
                                )
                        )
                    return (configuration, revision)
                }
            let connectionTestConfiguration =
                BlocksNativePluginHostConfiguration.connectionTest(
                    persisted: validationInput.0
                )
            let normalizedTestImage: TranslationSourceEncodedImage?
            if let testImage {
                normalizedTestImage = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    return try TranslationSourceImageEncoder.encode(
                        sourceData: testImage.data
                    )
                }.value
            } else {
                normalizedTestImage = nil
            }
            let invocation: BlocksNativePluginInvocation
            switch capability {
            case .translation:
                let acceptedInputs = Set(
                    package.manifest
                        .effectiveTranslationAcceptedInputs
                )
                if normalizedTestImage != nil,
                   !acceptedInputs.contains(.screenshotImage) {
                    throw BlocksNativePluginExecutionError
                        .executionFailed(
                            code: "plugin_test_image_unsupported",
                            message:
                                "This translation source does not accept screenshot images."
                        )
                }
                if normalizedTestImage == nil,
                   !acceptedInputs.contains(.text) {
                    throw BlocksNativePluginExecutionError
                        .executionFailed(
                            code: "plugin_test_image_required",
                            message:
                                "This translation source requires an image. Run the test again with --image PATH."
                        )
                }
                let sourceText = testText.flatMap { value in
                    value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty ? nil : value
                } ?? (
                    acceptedInputs.contains(.text)
                        ? "Blocks connection test"
                        : ""
                )
                let attachmentPayloads =
                    normalizedTestImage.map { image in
                        [
                            TranslationSourceAttachmentPayload(
                                descriptor:
                                    TranslationSourceAttachmentDescriptor(
                                        kind: .screenshotImage,
                                        mediaType: image.mediaType,
                                        byteCount: image.data.count,
                                        pixelWidth: image.pixelWidth,
                                        pixelHeight: image.pixelHeight,
                                        sha256:
                                            TranslationAttachmentDigest
                                                .sha256Hex(image.data)
                                    ),
                                data: image.data,
                                base64EncodedData:
                                    image.data.base64EncodedString()
                            ),
                        ]
                    } ?? []
                let request = TranslationServiceRequest(
                    sessionID: "connection-test",
                    input: TranslationInput(
                        source:
                            normalizedTestImage == nil
                                ? .manual
                                : .screenshotOCR,
                        text: sourceText
                    ),
                    direction: TranslationLanguageDirection(
                        source: TranslationLanguageTag("en"),
                        target:
                            TranslationLanguageTag("zh-Hans")!
                    ),
                    context: TranslationSourceContext(
                        inputSource:
                            normalizedTestImage == nil
                                ? .manual
                                : .screenshotOCR
                    ),
                    attachments: attachmentPayloads
                )
                invocation = BlocksNativePluginInvocation(
                    requestID: request.invocation.id,
                    pluginID: pluginID,
                    kind: .translation,
                    input:
                        try TranslationPluginServiceAdapter
                            .invocationInput(
                                request,
                                manifest: package.manifest,
                                approvedPermissions:
                                    Set(metadata.approvedPermissions)
                            ),
                    configuration: connectionTestConfiguration
                )
            case .ocr:
                let image = normalizedTestImage
                invocation = BlocksNativePluginInvocation(
                    pluginID: pluginID,
                    kind: .ocr,
                    input: [
                        "image_base64": .string(
                            image?.data.base64EncodedString()
                                ?? Self.onePixelPNGBase64
                        ),
                        "media_type": .string(
                            image?.mediaType ?? "image/png"
                        ),
                    ],
                    configuration: connectionTestConfiguration
                )
            case .hooks, .actions, .ui:
                throw BlocksNativePluginExecutionError.executionFailed(
                    code: "connection_test_unsupported",
                    message: "This plugin capability does not define a connection test."
                )
            }
            let output = try await executor.executeConnectionTest(
                package: package,
                metadata: metadata,
                invocation: invocation,
                progress: { _ in }
            )
            try Task.checkCancellation()
            let (_, currentPackage) =
                try await loadInstalledPackage(pluginID: pluginID)
            let currentRevision =
                try await persistenceWorker.perform {
                    let currentConfiguration =
                        try configurationStore.activationConfiguration(
                            pluginID: pluginID,
                            manifest: currentPackage.manifest
                        )
                    return try BlocksNativePluginValidationRevision.make(
                        packageHash: currentPackage.packageSHA256,
                        configuration: currentConfiguration,
                        credentialRevision:
                            try validationStore.credentialRevision(
                                pluginID: pluginID
                            )
                    )
                }
            guard currentRevision == validationInput.1 else {
                throw BlocksNativePluginManagerError.validationRequired
            }
            try Task.checkCancellation()
            try await persistenceWorker.perform {
                try validationStore.markValidated(
                    currentRevision,
                    pluginID: pluginID
                )
            }
            validatedPluginIDs.insert(pluginID)
            result = BlocksNativePluginConnectionTestResult(
                pluginID: pluginID,
                capability: capability,
                succeeded: true,
                outputSummary:
                    testText == nil
                        ? String(output.text.prefix(160))
                        : nil,
                errorCode: nil,
                errorMessage: nil
            )
        } catch is CancellationError {
            executor.cancelExecutions(pluginID: pluginID)
            result = BlocksNativePluginConnectionTestResult(
                pluginID: pluginID,
                capability: capability,
                succeeded: false,
                outputSummary: nil,
                errorCode: "request_cancelled",
                errorMessage: "The connection test was cancelled."
            )
        } catch {
            let repository = repository
            let validationStore = validationStore
            executor.cancelExecutions(pluginID: pluginID)
            do {
                try await persistenceWorker.perform {
                    if let metadata = try? repository.metadata(
                        id: pluginID
                    ), metadata.isEnabled {
                        _ = try repository.setEnabled(
                            false,
                            pluginID: pluginID,
                            now: Date()
                        )
                    }
                    try validationStore.invalidate(pluginID: pluginID)
                }
                shouldRefreshSnapshot = true
            } catch let invalidationError {
                managedRecoveryFailed = true
                snapshotIsReady = false
                lastErrorMessage =
                    invalidationError.localizedDescription
            }
            executor.cancelExecutions(pluginID: pluginID)
            validatedPluginIDs.remove(pluginID)
            result = BlocksNativePluginConnectionTestResult(
                pluginID: pluginID,
                capability: capability,
                succeeded: false,
                outputSummary: nil,
                errorCode: Self.errorCode(for: error),
                errorMessage: String(error.localizedDescription.prefix(512))
            )
        }
        operation = .idle
        if shouldRefreshSnapshot {
            await refreshPluginSnapshot()
        }
        lastConnectionTest = result
        return result
    }

    func loadInstalledPackage(
        pluginID: String
    ) async throws -> (BlocksNativePluginMetadata, BlocksNativePluginValidatedPackage) {
        try await requireRecoveryReady()
        let repository = repository
        let managedRoot = managedRoot
        return try await persistenceWorker.perform {
            let metadata = try repository.metadata(id: pluginID)
            #if BLOCKS_APP_STORE_BETA
            guard metadata.installationOrigin == .builtIn else {
                throw BlocksNativePluginManagerError.externalInstallationUnavailable
            }
            #endif
            let packageURL = try Self.managedURL(
                for: metadata,
                managedRoot: managedRoot
            )
            let package =
            try BlocksNativePluginPackageValidator().validate(directory: packageURL)
            guard package.packageSHA256 == metadata.packageHash else {
                throw BlocksNativePluginExecutionError.packageHashMismatch
            }
            return (metadata, package)
        }
    }

    func executePlatform(
        pluginID: String,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void = { _ in }
    ) async throws -> BlocksPluginRuntimeResult {
        let (metadata, package) = try await loadInstalledPackage(pluginID: pluginID)
        try Task.checkCancellation()
        guard package.manifest.schemaVersion >= 4,
              package.manifest.platform != nil else {
            throw BlocksNativePluginExecutionError.capabilityUnavailable
        }
        let configurationStore = configurationStore
        let configuration = try await persistenceWorker.perform {
            try configurationStore.activationConfiguration(
                pluginID: pluginID,
                manifest: package.manifest
            )
        }
        try Task.checkCancellation()
        let resolvedInvocation = BlocksPluginRuntimeInvocation(
            requestID: invocation.requestID,
            pluginID: invocation.pluginID,
            kind: invocation.kind,
            entryFunction: invocation.entryFunction,
            event: invocation.event,
            input: invocation.input,
            configuration: configuration.merging(invocation.configuration) {
                _, invocationValue in invocationValue
            }
        )
        try Task.checkCancellation()
        return try await executor.executePlatform(
            package: package,
            metadata: metadata,
            invocation: resolvedInvocation,
            timeoutSeconds: timeoutSeconds,
            progress: progress
        )
    }

    func configuration(
        pluginID: String
    ) async throws -> [String: JSONValue] {
        let (_, package) = try await loadInstalledPackage(
            pluginID: pluginID
        )
        let configurationStore = configurationStore
        return try await persistenceWorker.perform {
            try configurationStore.configuration(
                pluginID: pluginID,
                manifest: package.manifest
            )
        }
    }

    func saveConfiguration(
        _ configuration: [String: JSONValue],
        pluginID: String
    ) async throws {
        try await requireOperation(.idle)
        operation = .disabling(pluginID)
        lastErrorMessage = nil
        var mutationStarted = false
        do {
            let (_, package) = try await loadInstalledPackage(
                pluginID: pluginID
            )
            let repository = repository
            let configurationStore = configurationStore
            let validationStore = validationStore
            let executor = executor
            try await persistenceWorker.perform {
                try configurationStore.validateForSave(
                    configuration,
                    pluginID: pluginID,
                    manifest: package.manifest
                )
            }
            try Task.checkCancellation()
            mutationStarted = true
            executor.cancelExecutions(pluginID: pluginID)
            try await persistenceWorker.perform {
                let metadata = try repository.metadata(id: pluginID)
                if metadata.isEnabled {
                    _ = try repository.setEnabled(
                        false,
                        pluginID: pluginID,
                        now: Date()
                    )
                }
                try validationStore.invalidate(pluginID: pluginID)
                executor.cancelExecutions(pluginID: pluginID)
                try configurationStore.save(
                    configuration,
                    pluginID: pluginID,
                    manifest: package.manifest
                )
            }
            validatedPluginIDs.remove(pluginID)
            configurationRevision &+= 1
            operation = .idle
            await refreshPluginSnapshot()
        } catch {
            if mutationStarted {
                executor.cancelExecutions(pluginID: pluginID)
                validatedPluginIDs.remove(pluginID)
            }
            operation = .idle
            await refreshPluginSnapshot()
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func saveSecret(
        _ value: String,
        pluginID: String,
        secretID: String
    ) async throws {
        try await requireOperation(.idle)
        operation = .disabling(pluginID)
        lastErrorMessage = nil
        var mutationStarted = false
        do {
            let (_, package) = try await loadInstalledPackage(
                pluginID: pluginID
            )
            guard let declaredSecret = package.manifest.declaredSecret(
                id: secretID
            ) else {
                throw BlocksNativePluginSecretStoreError.invalidIdentifier
            }
            guard !value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                throw BlocksNativePluginManagerError
                    .missingRequiredSecret(secretID)
            }
            if let maximumLength = declaredSecret.maximumLength,
               value.count > maximumLength {
                throw BlocksNativePluginSecretStoreError.valueTooLarge(
                    Data(value.utf8).count
                )
            }
            try Task.checkCancellation()
            let repository = repository
            let secretStore = secretStore
            let validationStore = validationStore
            let executor = executor
            mutationStarted = true
            executor.cancelExecutions(pluginID: pluginID)
            try await persistenceWorker.perform {
                let metadata = try repository.metadata(id: pluginID)
                if metadata.isEnabled {
                    _ = try repository.setEnabled(
                        false,
                        pluginID: pluginID,
                        now: Date()
                    )
                }
                try validationStore
                    .invalidateAndAdvanceCredentialRevision(
                        pluginID: pluginID
                    )
                executor.cancelExecutions(pluginID: pluginID)
                try secretStore.save(
                    value,
                    pluginID: pluginID,
                    secretID: secretID
                )
            }
            validatedPluginIDs.remove(pluginID)
            configurationRevision &+= 1
            operation = .idle
            await refreshPluginSnapshot()
        } catch {
            if mutationStarted {
                executor.cancelExecutions(pluginID: pluginID)
                validatedPluginIDs.remove(pluginID)
            }
            operation = .idle
            await refreshPluginSnapshot()
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func deleteSecret(
        pluginID: String,
        secretID: String
    ) async throws {
        try await requireOperation(.idle)
        operation = .disabling(pluginID)
        lastErrorMessage = nil
        var mutationStarted = false
        do {
            let (_, package) = try await loadInstalledPackage(
                pluginID: pluginID
            )
            guard package.manifest.declaredSecret(id: secretID) != nil else {
                throw BlocksNativePluginSecretStoreError.invalidIdentifier
            }
            try Task.checkCancellation()
            let repository = repository
            let secretStore = secretStore
            let validationStore = validationStore
            let executor = executor
            mutationStarted = true
            executor.cancelExecutions(pluginID: pluginID)
            try await persistenceWorker.perform {
                let metadata = try repository.metadata(id: pluginID)
                if metadata.isEnabled {
                    _ = try repository.setEnabled(
                        false,
                        pluginID: pluginID,
                        now: Date()
                    )
                }
                try validationStore
                    .invalidateAndAdvanceCredentialRevision(
                        pluginID: pluginID
                    )
                executor.cancelExecutions(pluginID: pluginID)
                try secretStore.delete(
                    pluginID: pluginID,
                    secretID: secretID
                )
            }
            validatedPluginIDs.remove(pluginID)
            configurationRevision &+= 1
            operation = .idle
            await refreshPluginSnapshot()
        } catch {
            if mutationStarted {
                executor.cancelExecutions(pluginID: pluginID)
                validatedPluginIDs.remove(pluginID)
            }
            operation = .idle
            await refreshPluginSnapshot()
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func makeTranslationAdapter(
        pluginID: String
    ) async throws -> TranslationPluginServiceAdapter {
        let (metadata, package) = try await loadInstalledPackage(pluginID: pluginID)
        guard package.manifest.capabilities.contains(.translation) else {
            throw BlocksNativePluginExecutionError.capabilityUnavailable
        }
        let configurationStore = configurationStore
        let configuration = try await persistenceWorker.perform {
            try configurationStore.configuration(
                pluginID: pluginID,
                manifest: package.manifest
            )
        }
        return TranslationPluginServiceAdapter(
            package: package,
            metadata: metadata,
            executor: executor,
            configuration: configuration
        )
    }

    func makeOCRAdapter(
        pluginID: String
    ) async throws -> PluginOCRServiceAdapter {
        let (metadata, package) = try await loadInstalledPackage(pluginID: pluginID)
        guard package.manifest.capabilities.contains(.ocr) else {
            throw BlocksNativePluginExecutionError.capabilityUnavailable
        }
        let configurationStore = configurationStore
        let configuration = try await persistenceWorker.perform {
            try configurationStore.configuration(
                pluginID: pluginID,
                manifest: package.manifest
            )
        }
        return PluginOCRServiceAdapter(
            package: package,
            metadata: metadata,
            executor: executor,
            configuration: configuration
        )
    }

    nonisolated private static func reconcileValidationState(
        repository: any BlocksNativePluginMetadataStoring,
        executor: any BlocksNativePluginExecuting,
        configurationStore:
            any BlocksNativePluginConfigurationStoring,
        validationStore: any BlocksNativePluginValidationStoring
    ) throws -> BlocksNativePluginValidationSnapshot {
        var plugins = try repository.list()
        var validatedPluginIDs: Set<String> = []
        var disabledPluginIDs: Set<String> = []
        for index in plugins.indices {
            let metadata = plugins[index]
            let currentRevision: BlocksNativePluginValidationRevision?
            do {
                let manifest = try JSONDecoder().decode(
                    BlocksNativePluginManifest.self,
                    from: Data(metadata.manifestJSON.utf8)
                )
                try BlocksNativePluginPackageValidator().validate(
                    manifest: manifest
                )
                let configuration =
                    try configurationStore.activationConfiguration(
                        pluginID: metadata.id,
                        manifest: manifest
                    )
                let credentialRevision =
                    try validationStore.credentialRevision(
                        pluginID: metadata.id
                    )
                currentRevision =
                    try BlocksNativePluginValidationRevision.make(
                        packageHash: metadata.packageHash,
                        configuration: configuration,
                        credentialRevision: credentialRevision
                    )
            } catch {
                currentRevision = nil
            }
            let persistedRevision = try? validationStore.validatedRevision(
                pluginID: metadata.id
            )
            if let currentRevision,
               persistedRevision == currentRevision {
                validatedPluginIDs.insert(metadata.id)
                continue
            }
            guard metadata.isEnabled else { continue }
            executor.cancelExecutions(pluginID: metadata.id)
            plugins[index] = try repository.setEnabled(
                false,
                pluginID: metadata.id,
                now: Date()
            )
            disabledPluginIDs.insert(metadata.id)
            executor.cancelExecutions(pluginID: metadata.id)
        }
        return BlocksNativePluginValidationSnapshot(
            plugins: plugins,
            validatedPluginIDs: validatedPluginIDs,
            disabledPluginIDs: disabledPluginIDs
        )
    }

    nonisolated private static func reconcileManagedStorage(
        repository: any BlocksNativePluginMetadataStoring,
        managedRoot: URL,
        executor: any BlocksNativePluginExecuting,
        secretStore: any BlocksNativePluginSecretStoring,
        configurationStore: any BlocksNativePluginConfigurationStoring,
        validationStore: any BlocksNativePluginValidationStoring,
        uninstallCheckpointHook:
            (@Sendable (BlocksNativePluginUninstallCheckpoint) throws -> Void)?
    ) throws {
        let rootDescriptor = try Self.openManagedRootDescriptor(
            managedRoot,
            createIfMissing: true
        )
        defer { close(rootDescriptor) }

        let rootEntries = try Self.managedDirectoryEntries(
            rootDescriptor: rootDescriptor
        )
        for name in rootEntries where name.hasPrefix(".installing-")
            && name.hasSuffix(".blocksplugin") {
            try Self.removeManagedEntry(
                parentDescriptor: rootDescriptor,
                name: name
            )
        }

        let tombstoneNames = rootEntries.filter {
            $0.hasPrefix(".uninstalling-") && $0.hasSuffix(".json")
        }.sorted()
        for tombstoneName in tombstoneNames {
            let data = try Self.readManagedEntryFile(
                name: tombstoneName,
                rootDescriptor: rootDescriptor
            )
            let tombstone = try JSONDecoder().decode(
                BlocksNativePluginUninstallTombstone.self,
                from: data
            )
            let expectedTombstoneName = try Self.uninstallTombstoneName(
                for: tombstone
            )
            guard tombstoneName == expectedTombstoneName else {
                throw BlocksNativePluginManagerError.recoveryConflict(
                    tombstone.pluginID
                )
            }
            try Self.completeInterruptedUninstall(
                tombstone,
                repository: repository,
                managedRoot: managedRoot,
                executor: executor,
                secretStore: secretStore,
                configurationStore: configurationStore,
                validationStore: validationStore,
                uninstallCheckpointHook: uninstallCheckpointHook,
                rootDescriptor: rootDescriptor
            )
        }

        let upgradeTombstoneNames = rootEntries.filter {
            $0.hasPrefix(".upgrading-secrets-") && $0.hasSuffix(".json")
        }.sorted()
        for tombstoneName in upgradeTombstoneNames {
            let data = try Self.readManagedEntryFile(
                name: tombstoneName,
                rootDescriptor: rootDescriptor
            )
            let tombstone = try JSONDecoder().decode(
                BlocksNativePluginUpgradeSecretTombstone.self,
                from: data
            )
            let expectedTombstoneName = try Self.upgradeSecretTombstoneName(
                for: tombstone
            )
            guard tombstoneName == expectedTombstoneName else {
                throw BlocksNativePluginManagerError.recoveryConflict(
                    tombstone.pluginID
                )
            }
            try Self.completeInterruptedUpgradeSecretRevocation(
                tombstone,
                repository: repository,
                managedRoot: managedRoot,
                executor: executor,
                secretStore: secretStore,
                rootDescriptor: rootDescriptor
            )
        }
    }

    nonisolated private static func completeInterruptedUpgradeSecretRevocation(
        _ tombstone: BlocksNativePluginUpgradeSecretTombstone,
        repository: any BlocksNativePluginMetadataStoring,
        managedRoot: URL,
        executor: any BlocksNativePluginExecuting,
        secretStore: any BlocksNativePluginSecretStoring,
        upgradeCheckpointHook:
            (@Sendable (BlocksNativePluginUpgradeCheckpoint) throws -> Void)? = nil,
        cancelExecutionsBeforeRevocation: Bool = true,
        rootDescriptor existingRootDescriptor: Int32? = nil
    ) throws {
        let rootDescriptor: Int32
        let ownsRootDescriptor: Bool
        if let existingRootDescriptor {
            rootDescriptor = existingRootDescriptor
            ownsRootDescriptor = false
        } else {
            rootDescriptor = try Self.openManagedRootDescriptor(
                managedRoot,
                createIfMissing: true
            )
            ownsRootDescriptor = true
        }
        defer {
            if ownsRootDescriptor {
                close(rootDescriptor)
            }
        }
        guard Self.managedRootDescriptor(
            rootDescriptor,
            stillMatches: managedRoot
        ) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }

        let currentMetadata = try repository.metadata(id: tombstone.pluginID)
        if currentMetadata.packageHash == tombstone.previousPackageHash,
           currentMetadata.installedRelativePath
                == tombstone.previousInstalledRelativePath {
            // The marker was durable but the metadata commit never happened.
            // Roll back the staged replacement without touching Keychain.
            try Self.removeManagedSnapshotIfPresent(
                relativePath: tombstone.replacementInstalledRelativePath,
                rootDescriptor: rootDescriptor
            )
            try Self.removeUpgradeSecretTombstone(
                tombstone,
                rootDescriptor: rootDescriptor
            )
            return
        }

        let replacementURL = try Self.managedPackageURL(
            relativePath: tombstone.replacementInstalledRelativePath,
            managedRoot: managedRoot
        )
        let replacementPackage = try BlocksNativePluginPackageValidator()
            .validate(directory: replacementURL)
        guard replacementPackage.manifest.id == tombstone.pluginID,
              replacementPackage.packageSHA256
                == tombstone.replacementPackageHash else {
            throw BlocksNativePluginManagerError.recoveryConflict(
                tombstone.pluginID
            )
        }
        guard currentMetadata.packageHash
                == tombstone.replacementPackageHash,
              currentMetadata.installedRelativePath
                == tombstone.replacementInstalledRelativePath else {
            throw BlocksNativePluginManagerError.recoveryConflict(
                tombstone.pluginID
            )
        }
        if cancelExecutionsBeforeRevocation {
            executor.cancelExecutions(pluginID: tombstone.pluginID)
        }

        for secretID in tombstone.revokedSecretIDs {
            try secretStore.delete(
                pluginID: tombstone.pluginID,
                secretID: secretID
            )
        }
        try upgradeCheckpointHook?(.beforePreviousPackageRemoval)

        if tombstone.previousInstalledRelativePath
            != tombstone.replacementInstalledRelativePath {
            try Self.removeManagedSnapshotIfPresent(
                relativePath: tombstone.previousInstalledRelativePath,
                rootDescriptor: rootDescriptor
            )
        }
        try Self.removeUpgradeSecretTombstone(
            tombstone,
            rootDescriptor: rootDescriptor
        )
    }

    nonisolated private static func completeInterruptedUninstall(
        _ tombstone: BlocksNativePluginUninstallTombstone,
        repository: any BlocksNativePluginMetadataStoring,
        managedRoot: URL,
        executor: any BlocksNativePluginExecuting,
        secretStore: any BlocksNativePluginSecretStoring,
        configurationStore: any BlocksNativePluginConfigurationStoring,
        validationStore: any BlocksNativePluginValidationStoring,
        uninstallCheckpointHook:
            (@Sendable (BlocksNativePluginUninstallCheckpoint) throws -> Void)?,
        rootDescriptor existingRootDescriptor: Int32? = nil
    ) throws {
        let rootDescriptor: Int32
        let ownsRootDescriptor: Bool
        if let existingRootDescriptor {
            rootDescriptor = existingRootDescriptor
            ownsRootDescriptor = false
        } else {
            rootDescriptor = try Self.openManagedRootDescriptor(
                managedRoot,
                createIfMissing: true
            )
            ownsRootDescriptor = true
        }
        defer {
            if ownsRootDescriptor {
                close(rootDescriptor)
            }
        }
        guard Self.managedRootDescriptor(
            rootDescriptor,
            stillMatches: managedRoot
        ) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }

        let currentMetadata: BlocksNativePluginMetadata?
        do {
            currentMetadata = try repository.metadata(id: tombstone.pluginID)
        } catch let error as BlocksNativePluginMetadataRepositoryError {
            guard case .pluginNotFound = error else { throw error }
            currentMetadata = nil
        }
        if let currentMetadata {
            guard currentMetadata.packageHash == tombstone.packageHash,
                  currentMetadata.installedRelativePath
                    == tombstone.installedRelativePath else {
                throw BlocksNativePluginManagerError.recoveryConflict(
                    tombstone.pluginID
                )
            }
            if currentMetadata.isEnabled {
                _ = try repository.setEnabled(
                    false,
                    pluginID: tombstone.pluginID,
                    now: Date()
                )
            }
        }
        executor.cancelExecutions(pluginID: tombstone.pluginID)

        for secretID in tombstone.secretIDs {
            try secretStore.delete(
                pluginID: tombstone.pluginID,
                secretID: secretID
            )
        }
        try uninstallCheckpointHook?(.secretsRemoved)

        if currentMetadata != nil {
            try repository.remove(pluginID: tombstone.pluginID)
        }
        try uninstallCheckpointHook?(.metadataRemoved)

        try Self.removeManagedSnapshotIfPresent(
            relativePath: tombstone.installedRelativePath,
            rootDescriptor: rootDescriptor
        )
        try uninstallCheckpointHook?(.packageRemoved)

        try configurationStore.delete(pluginID: tombstone.pluginID)
        try validationStore.delete(pluginID: tombstone.pluginID)

        let tombstoneName = try Self.uninstallTombstoneName(for: tombstone)
        let removeResult = tombstoneName.withCString {
            unlinkat(rootDescriptor, $0, 0)
        }
        guard removeResult == 0 || errno == ENOENT else {
            throw BlocksNativePluginManagerError.fileWriteFailed(
                tombstoneName
            )
        }
        _ = fsync(rootDescriptor)
    }

    nonisolated private static func managedURL(
        for metadata: BlocksNativePluginMetadata,
        managedRoot: URL
    ) throws -> URL {
        let candidate = managedRoot
            .appendingPathComponent(metadata.installedRelativePath, isDirectory: true)
            .appendingPathExtension("blocksplugin")
            .standardizedFileURL
        let prefix = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        try Self.validateExistingManagedPackage(
            relativePath: metadata.installedRelativePath,
            managedRoot: managedRoot
        )
        return candidate
    }

    private func requireOperation(
        _ expected: BlocksNativePluginManagerOperation
    ) async throws {
        try Task.checkCancellation()
        try await requireRecoveryReady()
        try Task.checkCancellation()
        guard operation == expected else {
            let error = BlocksNativePluginManagerError.operationInProgress
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func requireRecoveryReady() async throws {
        try Task.checkCancellation()
        guard storageInitializationFailure == nil else {
            let error = BlocksNativePluginManagerError.storageUnavailable
            lastErrorMessage = storageInitializationFailure
                ?? error.localizedDescription
            throw error
        }
        if !snapshotIsReady, !managedRecoveryFailed {
            await reload()
            try Task.checkCancellation()
        }
        guard !managedRecoveryFailed else {
            let error = BlocksNativePluginManagerError.recoveryConflict(
                "managed-storage"
            )
            lastErrorMessage = error.localizedDescription
            throw error
        }
        guard snapshotIsReady else {
            let error = BlocksNativePluginManagerError.recoveryConflict(
                "managed-storage"
            )
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func refreshPluginSnapshot() async {
        executionSettlementGate.beginGlobalSettlement()
        let repository = repository
        let executor = executor
        let configurationStore = configurationStore
        let validationStore = validationStore
        do {
            let snapshot = try await persistenceWorker.perform {
                try Self.reconcileValidationState(
                    repository: repository,
                    executor: executor,
                    configurationStore: configurationStore,
                    validationStore: validationStore
                )
            }
            let allowedPlugins = Self.allowedPluginsForDistribution(
                snapshot.plugins
            )
            applyValidationLifecycleCutoffs(snapshot.disabledPluginIDs)
            plugins = allowedPlugins
            validatedPluginIDs = snapshot.validatedPluginIDs.intersection(
                Set(allowedPlugins.map(\.id))
            )
            snapshotIsReady = true
            managedRecoveryFailed = false
            lastErrorMessage = nil
            executionSettlementGate.finishGlobalSettlement(
                invalidatingPluginIDs: snapshot.disabledPluginIDs
            )
        } catch {
            snapshotIsReady = false
            validatedPluginIDs = []
            lastErrorMessage = error.localizedDescription
            executionSettlementGate.finishGlobalSettlement(invalidateAll: true)
        }
    }

    private func applyValidationLifecycleCutoffs(_ pluginIDs: Set<String>) {
        for pluginID in pluginIDs {
            invalidateExecutionGeneration(pluginID: pluginID)
            revokeHostOperations(pluginID: pluginID)
            cancelActiveExecutions(pluginID: pluginID)
        }
    }

    private func waitForCurrentReloadCompletionIfNeeded() async {
        guard !snapshotIsReady, !managedRecoveryFailed else {
            return
        }
        await withCheckedContinuation { continuation in
            reloadCompletionWaiters.append(continuation)
        }
    }

    nonisolated private static func allowedPluginsForDistribution(
        _ plugins: [BlocksNativePluginMetadata]
    ) -> [BlocksNativePluginMetadata] {
        let allowedPluginIDs = allowedPluginIDsForDistribution(plugins)
        return plugins.filter { allowedPluginIDs.contains($0.id) }
    }

    nonisolated static func filterBindingsForDistribution<Binding>(
        _ bindings: [Binding],
        pluginID: KeyPath<Binding, String>,
        pluginSnapshot: [BlocksNativePluginMetadata],
        distributionChannel: DistributionChannel = .current
    ) -> [Binding] {
        guard !distributionChannel.supportsExternalPlugins else {
            return bindings
        }
        let allowedPluginIDs = allowedPluginIDsForDistribution(
            pluginSnapshot,
            distributionChannel: distributionChannel
        )
        return bindings.filter { allowedPluginIDs.contains($0[keyPath: pluginID]) }
    }

    nonisolated static func allowedPluginIDsForDistribution(
        _ plugins: [BlocksNativePluginMetadata],
        distributionChannel: DistributionChannel = .current
    ) -> Set<String> {
        guard !distributionChannel.supportsExternalPlugins else {
            return Set(plugins.map(\.id))
        }
        return Set(
            plugins.lazy
                .filter { $0.installationOrigin == .builtIn }
                .map(\.id)
        )
    }

    private func resumeReloadCompletionWaiters() {
        let waiters = reloadCompletionWaiters
        reloadCompletionWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    nonisolated private static func persistUninstallTombstone(
        _ tombstone: BlocksNativePluginUninstallTombstone,
        managedRoot: URL
    ) throws {
        let rootDescriptor = try openManagedRootDescriptor(
            managedRoot,
            createIfMissing: true
        )
        defer { close(rootDescriptor) }
        guard managedRootDescriptor(
            rootDescriptor,
            stillMatches: managedRoot
        ) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }

        let name = try uninstallTombstoneName(for: tombstone)
        let data = try JSONEncoder().encode(tombstone)
        try persistManagedTombstone(
            data,
            name: name,
            pluginID: tombstone.pluginID,
            rootDescriptor: rootDescriptor
        )
    }

    nonisolated private static func persistUpgradeSecretTombstone(
        _ tombstone: BlocksNativePluginUpgradeSecretTombstone,
        managedRoot: URL
    ) throws {
        let rootDescriptor = try openManagedRootDescriptor(
            managedRoot,
            createIfMissing: true
        )
        defer { close(rootDescriptor) }
        guard managedRootDescriptor(
            rootDescriptor,
            stillMatches: managedRoot
        ) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        let name = try upgradeSecretTombstoneName(for: tombstone)
        let data = try JSONEncoder().encode(tombstone)
        try persistManagedTombstone(
            data,
            name: name,
            pluginID: tombstone.pluginID,
            rootDescriptor: rootDescriptor
        )
    }

    nonisolated private static func persistManagedTombstone(
        _ data: Data,
        name: String,
        pluginID: String,
        rootDescriptor: Int32
    ) throws {
        if let existing = try managedEntryStat(
            parentDescriptor: rootDescriptor,
            name: name
        ) {
            guard (existing.st_mode & S_IFMT) == S_IFREG,
                  try readManagedEntryFile(
                      name: name,
                      rootDescriptor: rootDescriptor
                  ) == data else {
                throw BlocksNativePluginManagerError.recoveryConflict(
                    pluginID
                )
            }
            return
        }

        let temporaryName = ".tombstone-\(UUID().uuidString).tmp"
        try writeManagedEntryFile(
            data,
            name: temporaryName,
            rootDescriptor: rootDescriptor
        )
        var didRename = false
        defer {
            if !didRename {
                temporaryName.withCString {
                    _ = unlinkat(rootDescriptor, $0, 0)
                }
            }
        }
        let renameResult = temporaryName.withCString { sourceName in
            name.withCString { destinationName in
                renameatx_np(
                    rootDescriptor,
                    sourceName,
                    rootDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameResult != 0, errno == EEXIST {
            guard try readManagedEntryFile(
                name: name,
                rootDescriptor: rootDescriptor
            ) == data else {
                throw BlocksNativePluginManagerError.recoveryConflict(
                    pluginID
                )
            }
            return
        }
        guard renameResult == 0, fsync(rootDescriptor) == 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
        didRename = true
    }

    nonisolated private static func removeUpgradeSecretTombstone(
        _ tombstone: BlocksNativePluginUpgradeSecretTombstone,
        managedRoot: URL
    ) throws {
        let rootDescriptor = try openManagedRootDescriptor(
            managedRoot,
            createIfMissing: true
        )
        defer { close(rootDescriptor) }
        try removeUpgradeSecretTombstone(
            tombstone,
            rootDescriptor: rootDescriptor
        )
    }

    nonisolated private static func removeUpgradeSecretTombstone(
        _ tombstone: BlocksNativePluginUpgradeSecretTombstone,
        rootDescriptor: Int32
    ) throws {
        let name = try upgradeSecretTombstoneName(for: tombstone)
        let removeResult = name.withCString {
            unlinkat(rootDescriptor, $0, 0)
        }
        guard removeResult == 0 || errno == ENOENT,
              fsync(rootDescriptor) == 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
    }

    nonisolated private static func uninstallTombstoneName(
        for tombstone: BlocksNativePluginUninstallTombstone
    ) throws -> String {
        let lowercaseHash = tombstone.packageHash.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        let installedPathComponents = try managedRelativePathComponents(
            tombstone.installedRelativePath
        )
        guard lowercaseHash.count == 64,
              lowercaseHash.unicodeScalars.allSatisfy(
                  hexadecimal.contains
              ),
              !tombstone.pluginID.isEmpty,
              installedPathComponents.count == 2,
              installedPathComponents.first == tombstone.pluginID,
              installedPathComponents.last == lowercaseHash,
              tombstone.secretIDs.allSatisfy({
                  !$0.isEmpty
                      && !$0.contains("/")
                      && !$0.contains("\0")
              }) else {
            throw BlocksNativePluginManagerError.recoveryConflict(
                tombstone.pluginID
            )
        }
        return ".uninstalling-\(lowercaseHash).json"
    }

    nonisolated private static func upgradeSecretTombstoneName(
        for tombstone: BlocksNativePluginUpgradeSecretTombstone
    ) throws -> String {
        let previousHash = tombstone.previousPackageHash.lowercased()
        let replacementHash = tombstone.replacementPackageHash.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        let previousPathComponents = try managedRelativePathComponents(
            tombstone.previousInstalledRelativePath
        )
        let replacementPathComponents = try managedRelativePathComponents(
            tombstone.replacementInstalledRelativePath
        )
        let secretIDs = tombstone.revokedSecretIDs
        guard previousHash.count == 64,
              replacementHash.count == 64,
              previousHash != replacementHash,
              previousHash.unicodeScalars.allSatisfy(hexadecimal.contains),
              replacementHash.unicodeScalars.allSatisfy(hexadecimal.contains),
              !tombstone.pluginID.isEmpty,
              previousPathComponents
                == [tombstone.pluginID, previousHash],
              replacementPathComponents
                == [tombstone.pluginID, replacementHash],
              secretIDs == Array(Set(secretIDs)).sorted(),
              secretIDs.allSatisfy({
                  !$0.isEmpty
                      && !$0.contains("/")
                      && !$0.contains("\0")
              }) else {
            throw BlocksNativePluginManagerError.recoveryConflict(
                tombstone.pluginID
            )
        }
        return ".upgrading-secrets-\(replacementHash).json"
    }

    nonisolated private static func validatedStoredManifest(
        _ metadata: BlocksNativePluginMetadata
    ) throws -> BlocksNativePluginManifest {
        let manifest: BlocksNativePluginManifest
        do {
            manifest = try JSONDecoder().decode(
                BlocksNativePluginManifest.self,
                from: Data(metadata.manifestJSON.utf8)
            )
            try BlocksNativePluginPackageValidator().validate(
                manifest: manifest
            )
        } catch {
            throw BlocksNativePluginManagerError.recoveryConflict(metadata.id)
        }
        guard manifest.id == metadata.id else {
            throw BlocksNativePluginManagerError.recoveryConflict(metadata.id)
        }
        return manifest
    }

    nonisolated private static func openManagedRootDescriptor(
        _ managedRoot: URL,
        createIfMissing: Bool
    ) throws -> Int32 {
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: managedRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let rootValues = try managedRoot.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard rootValues.isSymbolicLink != true else {
            throw BlocksNativePluginManagerError.managedRootIsSymbolicLink
        }
        let descriptor = open(
            managedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw BlocksNativePluginManagerError.installedPackageMissing
            }
            throw BlocksNativePluginManagerError.managedRootIsSymbolicLink
        }
        return descriptor
    }

    nonisolated private static func managedDirectoryEntries(
        rootDescriptor: Int32
    ) throws -> [String] {
        let duplicatedDescriptor = dup(rootDescriptor)
        guard duplicatedDescriptor >= 0,
              let directory = fdopendir(duplicatedDescriptor) else {
            if duplicatedDescriptor >= 0 {
                close(duplicatedDescriptor)
            }
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    nonisolated private static func writeManagedEntryFile(
        _ data: Data,
        name: String,
        rootDescriptor: Int32
    ) throws {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\0") else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
        let fileDescriptor = name.withCString {
            openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
        defer { close(fileDescriptor) }
        try writeData(
            data,
            fileDescriptor: fileDescriptor,
            path: name
        )
    }

    nonisolated private static func readManagedEntryFile(
        name: String,
        rootDescriptor: Int32
    ) throws -> Data {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\0") else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
        let fileDescriptor = name.withCString {
            openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
        defer { close(fileDescriptor) }
        return try readData(
            fileDescriptor: fileDescriptor,
            path: name
        )
    }

    nonisolated private static func installSnapshot(
        _ package: BlocksNativePluginValidatedPackage,
        relativePath: String,
        managedRoot: URL,
        stagingOpenedHook: (@Sendable () throws -> Void)? = nil
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rootValues = try managedRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else {
            throw BlocksNativePluginManagerError.managedRootIsSymbolicLink
        }
        let rootDescriptor = open(
            managedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.managedRootIsSymbolicLink
        }
        defer { close(rootDescriptor) }
        let pathComponents = try managedRelativePathComponents(relativePath)
        let packageName = pathComponents.last! + ".blocksplugin"

        let destination = managedRoot
            .appendingPathComponent(relativePath, isDirectory: true)
            .appendingPathExtension("blocksplugin")
            .standardizedFileURL
        let rootPrefix = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        if let existingParentDescriptor = try openManagedDirectoryIfPresent(
            components: Array(pathComponents.dropLast()),
            rootDescriptor: rootDescriptor
        ) {
            defer { close(existingParentDescriptor) }
            if let existingStat = try managedEntryStat(
                parentDescriptor: existingParentDescriptor,
                name: packageName
            ) {
                guard (existingStat.st_mode & S_IFMT) == S_IFDIR else {
                    throw BlocksNativePluginManagerError.installedPathEscapesRoot
                }
                let existing = try BlocksNativePluginPackageValidator().validate(
                    directory: destination
                )
                guard existing.packageSHA256 == package.packageSHA256 else {
                    throw BlocksNativePluginManagerError.pendingInstallationChanged
                }
                return false
            }
        }

        let stagingName = ".installing-\(UUID().uuidString).blocksplugin"
        let stagingCreateResult = stagingName.withCString {
            mkdirat(rootDescriptor, $0, mode_t(0o700))
        }
        guard stagingCreateResult == 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(stagingName)
        }
        let stagingDescriptor = stagingName.withCString {
            openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard stagingDescriptor >= 0 else {
            stagingName.withCString {
                _ = unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
            }
            throw BlocksNativePluginManagerError.fileWriteFailed(stagingName)
        }
        var didMoveStaging = false
        defer {
            if !didMoveStaging {
                removeKnownSnapshotContents(
                    rootDescriptor: stagingDescriptor,
                    relativeFilePaths: package.relativeFilePaths
                )
                stagingName.withCString {
                    _ = unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
                }
            }
            close(stagingDescriptor)
        }
        try stagingOpenedHook?()

        for relativeFilePath in package.relativeFilePaths.sorted() {
            guard let data = package.files[relativeFilePath] else {
                throw BlocksNativePluginManagerError.packageSnapshotIncomplete(
                    relativeFilePath
                )
            }
            try writeManagedFile(
                data,
                relativePath: relativeFilePath,
                rootDescriptor: stagingDescriptor
            )
        }
        guard try stagedSnapshotMatches(
            package,
            rootDescriptor: stagingDescriptor
        ) else {
            throw BlocksNativePluginManagerError.pendingInstallationChanged
        }
        guard managedRootDescriptor(
            rootDescriptor,
            stillMatches: managedRoot
        ) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        let destinationParentDescriptor = try openManagedDirectory(
            components: Array(pathComponents.dropLast()),
            rootDescriptor: rootDescriptor,
            createIfMissing: true
        )
        defer { close(destinationParentDescriptor) }
        let renameResult = stagingName.withCString { sourceName in
            packageName.withCString { destinationName in
                renameatx_np(
                    rootDescriptor,
                    sourceName,
                    destinationParentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            if errno == EEXIST {
                throw BlocksNativePluginManagerError.pendingInstallationChanged
            }
            throw BlocksNativePluginManagerError.fileWriteFailed(packageName)
        }
        didMoveStaging = true
        return true
    }

    nonisolated private static func managedPackageURL(
        relativePath: String,
        managedRoot: URL
    ) throws -> URL {
        let destination = managedRoot
            .appendingPathComponent(relativePath, isDirectory: true)
            .appendingPathExtension("blocksplugin")
            .standardizedFileURL
        let rootPrefix = managedRoot.path.hasSuffix("/")
            ? managedRoot.path
            : managedRoot.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        try validateExistingManagedPackage(
            relativePath: relativePath,
            managedRoot: managedRoot
        )
        return destination
    }

    nonisolated private static func validateExistingManagedPackage(
        relativePath: String,
        managedRoot: URL
    ) throws {
        let rootDescriptor = open(
            managedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.managedRootIsSymbolicLink
        }
        defer { close(rootDescriptor) }
        let pathComponents = try managedRelativePathComponents(relativePath)
        let packageName = pathComponents.last! + ".blocksplugin"
        let parentDescriptor = try openManagedDirectory(
            components: Array(pathComponents.dropLast()),
            rootDescriptor: rootDescriptor,
            createIfMissing: false
        )
        defer { close(parentDescriptor) }
        guard let packageStat = try managedEntryStat(
            parentDescriptor: parentDescriptor,
            name: packageName
        ) else {
            throw BlocksNativePluginManagerError.installedPackageMissing
        }
        guard (packageStat.st_mode & S_IFMT) == S_IFDIR else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
    }

    nonisolated private static func managedRelativePathComponents(
        _ relativePath: String
    ) throws -> [String] {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
              }) else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        return components
    }

    nonisolated private static func openManagedDirectory(
        components: [String],
        rootDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32 {
        var currentDescriptor = dup(rootDescriptor)
        guard currentDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        do {
            for component in components {
                if createIfMissing {
                    let createResult = component.withCString {
                        mkdirat(currentDescriptor, $0, mode_t(0o700))
                    }
                    guard createResult == 0 || errno == EEXIST else {
                        throw BlocksNativePluginManagerError.fileWriteFailed(
                            component
                        )
                    }
                }
                let nextDescriptor = component.withCString {
                    openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard nextDescriptor >= 0 else {
                    if errno == ENOENT {
                        throw BlocksNativePluginManagerError.installedPackageMissing
                    }
                    throw BlocksNativePluginManagerError.installedPathEscapesRoot
                }
                close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            return currentDescriptor
        } catch {
            close(currentDescriptor)
            throw error
        }
    }

    nonisolated private static func openManagedDirectoryIfPresent(
        components: [String],
        rootDescriptor: Int32
    ) throws -> Int32? {
        do {
            return try openManagedDirectory(
                components: components,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
        } catch let error as BlocksNativePluginManagerError
            where error == .installedPackageMissing {
            return nil
        }
    }

    nonisolated private static func managedEntryStat(
        parentDescriptor: Int32,
        name: String
    ) throws -> stat? {
        var entryStat = stat()
        let result = name.withCString {
            fstatat(
                parentDescriptor,
                $0,
                &entryStat,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            return entryStat
        }
        if errno == ENOENT {
            return nil
        }
        throw BlocksNativePluginManagerError.installedPathEscapesRoot
    }

    nonisolated private static func writeManagedFile(
        _ data: Data,
        relativePath: String,
        rootDescriptor: Int32
    ) throws {
        let components = try managedRelativePathComponents(relativePath)
        let fileName = components.last!
        let parentDescriptor = try openManagedDirectory(
            components: Array(components.dropLast()),
            rootDescriptor: rootDescriptor,
            createIfMissing: true
        )
        defer { close(parentDescriptor) }
        let fileDescriptor = fileName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(relativePath)
        }
        defer { close(fileDescriptor) }
        try writeData(
            data,
            fileDescriptor: fileDescriptor,
            path: relativePath
        )
    }

    nonisolated private static func stagedSnapshotMatches(
        _ package: BlocksNativePluginValidatedPackage,
        rootDescriptor: Int32
    ) throws -> Bool {
        for relativePath in package.relativeFilePaths {
            guard let expectedData = package.files[relativePath] else {
                throw BlocksNativePluginManagerError.packageSnapshotIncomplete(
                    relativePath
                )
            }
            let actualData = try readManagedFile(
                relativePath: relativePath,
                rootDescriptor: rootDescriptor
            )
            guard actualData == expectedData else {
                return false
            }
        }
        return true
    }

    nonisolated private static func readManagedFile(
        relativePath: String,
        rootDescriptor: Int32
    ) throws -> Data {
        let components = try managedRelativePathComponents(relativePath)
        let fileName = components.last!
        let parentDescriptor = try openManagedDirectory(
            components: Array(components.dropLast()),
            rootDescriptor: rootDescriptor,
            createIfMissing: false
        )
        defer { close(parentDescriptor) }
        let fileDescriptor = fileName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(relativePath)
        }
        defer { close(fileDescriptor) }
        return try readData(
            fileDescriptor: fileDescriptor,
            path: relativePath
        )
    }

    nonisolated private static func writeData(
        _ data: Data,
        fileDescriptor: Int32,
        path: String
    ) throws {
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var writtenBytes = 0
                while writtenBytes < rawBuffer.count {
                    let result = Darwin.write(
                        fileDescriptor,
                        baseAddress.advanced(by: writtenBytes),
                        rawBuffer.count - writtenBytes
                    )
                    if result < 0, errno == EINTR {
                        continue
                    }
                    guard result > 0 else {
                        throw BlocksNativePluginManagerError.fileWriteFailed(
                            path
                        )
                    }
                    writtenBytes += result
                }
            }
            guard fsync(fileDescriptor) == 0 else {
                throw BlocksNativePluginManagerError.fileWriteFailed(path)
            }
        } catch {
            throw BlocksNativePluginManagerError.fileWriteFailed(path)
        }
    }

    nonisolated private static func readData(
        fileDescriptor: Int32,
        path: String
    ) throws -> Data {
        var fileStat = stat()
        guard fstat(fileDescriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size >= 0 else {
            throw BlocksNativePluginManagerError.fileWriteFailed(path)
        }
        var result = Data()
        result.reserveCapacity(Int(fileStat.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    fileDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
            if byteCount < 0, errno == EINTR {
                continue
            }
            guard byteCount >= 0 else {
                throw BlocksNativePluginManagerError.fileWriteFailed(path)
            }
            guard byteCount > 0 else {
                break
            }
            result.append(contentsOf: buffer.prefix(byteCount))
        }
        return result
    }

    nonisolated private static func managedRootDescriptor(
        _ rootDescriptor: Int32,
        stillMatches managedRoot: URL
    ) -> Bool {
        var originalStat = stat()
        guard fstat(rootDescriptor, &originalStat) == 0 else {
            return false
        }
        let currentDescriptor = open(
            managedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else {
            return false
        }
        defer { close(currentDescriptor) }
        var currentStat = stat()
        guard fstat(currentDescriptor, &currentStat) == 0 else {
            return false
        }
        return originalStat.st_dev == currentStat.st_dev
            && originalStat.st_ino == currentStat.st_ino
    }

    nonisolated private static func removeKnownSnapshotContents(
        rootDescriptor: Int32,
        relativeFilePaths: [String]
    ) {
        var directoryPaths: Set<String> = []
        for relativeFilePath in relativeFilePaths {
            guard let components = try? managedRelativePathComponents(
                relativeFilePath
            ) else {
                continue
            }
            if components.count > 1 {
                for componentCount in 1..<components.count {
                    directoryPaths.insert(
                        components.prefix(componentCount).joined(separator: "/")
                    )
                }
            }
            guard let parentDescriptor = try? openManagedDirectory(
                components: Array(components.dropLast()),
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            ) else {
                continue
            }
            components.last!.withCString {
                _ = unlinkat(parentDescriptor, $0, 0)
            }
            close(parentDescriptor)
        }
        for directoryPath in directoryPaths.sorted(by: {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }) {
            guard let components = try? managedRelativePathComponents(
                directoryPath
            ),
            let parentDescriptor = try? openManagedDirectory(
                components: Array(components.dropLast()),
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            ) else {
                continue
            }
            components.last!.withCString {
                _ = unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            close(parentDescriptor)
        }
    }

    nonisolated private static func removeManagedSnapshotIfPresent(
        relativePath: String,
        managedRoot: URL
    ) throws {
        let rootDescriptor = try openManagedRootDescriptor(
            managedRoot,
            createIfMissing: false
        )
        defer { close(rootDescriptor) }
        try removeManagedSnapshotIfPresent(
            relativePath: relativePath,
            rootDescriptor: rootDescriptor
        )
    }

    nonisolated private static func removeManagedSnapshotIfPresent(
        relativePath: String,
        rootDescriptor: Int32
    ) throws {
        let pathComponents = try managedRelativePathComponents(relativePath)
        let parentComponents = Array(pathComponents.dropLast())
        guard let parentDescriptor = try openManagedDirectoryIfPresent(
            components: parentComponents,
            rootDescriptor: rootDescriptor
        ) else {
            return
        }
        defer { close(parentDescriptor) }
        let packageName = pathComponents.last! + ".blocksplugin"
        try removeManagedEntry(
            parentDescriptor: parentDescriptor,
            name: packageName
        )
        if parentComponents.count == 1 {
            parentComponents[0].withCString {
                _ = unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
            }
        }
    }

    nonisolated private static func removeManagedEntry(
        parentDescriptor: Int32,
        name: String
    ) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw BlocksNativePluginManagerError.installedPathEscapesRoot
        }
        guard let entryStat = try managedEntryStat(
            parentDescriptor: parentDescriptor,
            name: name
        ) else {
            return
        }
        if (entryStat.st_mode & S_IFMT) == S_IFDIR {
            let directoryDescriptor = name.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard directoryDescriptor >= 0 else {
                throw BlocksNativePluginManagerError.installedPathEscapesRoot
            }
            defer { close(directoryDescriptor) }
            for childName in try managedDirectoryEntries(
                rootDescriptor: directoryDescriptor
            ) {
                try removeManagedEntry(
                    parentDescriptor: directoryDescriptor,
                    name: childName
                )
            }
            let result = name.withCString {
                unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            guard result == 0 || errno == ENOENT else {
                throw BlocksNativePluginManagerError.fileWriteFailed(name)
            }
            return
        }
        let result = name.withCString {
            unlinkat(parentDescriptor, $0, 0)
        }
        guard result == 0 || errno == ENOENT else {
            throw BlocksNativePluginManagerError.fileWriteFailed(name)
        }
    }

    private static func approvalPermissionTokens(
        for manifest: BlocksNativePluginManifest
    ) -> [String] {
        manifest.declaredPermissionTokens
    }

    private static func errorCode(for error: Error) -> String {
        if let error = error as? BlocksNativePluginExecutionError {
            switch error {
            case .runnerUnavailable:
                return "runner_unavailable"
            case .pluginNotApproved:
                return "plugin_not_approved"
            case .pluginDisabled:
                return "plugin_disabled"
            case .packageHashMismatch:
                return "package_hash_mismatch"
            case .capabilityUnavailable:
                return "capability_unavailable"
            case let .executionFailed(code, _):
                return code
            }
        }
        return "plugin_operation_failed"
    }

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}
