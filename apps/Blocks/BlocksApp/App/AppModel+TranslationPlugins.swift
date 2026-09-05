import BlocksCore
import Combine
import Foundation

enum TranslationPluginRuntimeSelection {
    static let appleVisionOCRServiceID = "apple-vision"
    static let pluginOCRServicePrefix = "plugin:"

    static func enabledOCRPluginID(
        preferredServiceID: String,
        plugins: [BlocksNativePluginMetadata]
    ) -> String? {
        guard preferredServiceID.hasPrefix(pluginOCRServicePrefix) else {
            return nil
        }
        let pluginID = String(
            preferredServiceID.dropFirst(pluginOCRServicePrefix.count)
        )
        guard !pluginID.isEmpty,
              plugins.contains(where: {
                  $0.id == pluginID
                      && $0.isEnabled
                      && $0.approvalStatus == .approved
                      && $0.capabilities.contains(.ocr)
              }) else {
            return nil
        }
        return pluginID
    }
}

extension AppModel {
    nonisolated static func makeTranslationFavoriteRepository()
        -> TranslationFavoriteRepository?
    {
        do {
            return try TranslationFavoriteRepository(database: AppDatabase.open())
        } catch {
            return nil
        }
    }

    nonisolated static func makeTranslationServiceProfileRepository()
        -> TranslationServiceProfileRepository?
    {
        do {
            return try TranslationServiceProfileRepository(
                database: AppDatabase.open()
            )
        } catch {
            return nil
        }
    }

    static func makeTranslationPluginManager(
        storageEnvironmentProvider: () throws -> StorageEnvironment = {
            try StorageEnvironment.appSupport()
        }
    ) -> BlocksNativePluginManager {
        do {
            let environment = try storageEnvironmentProvider()
            try environment.prepare()
            let database = try AppDatabase.open(environment: environment)
            let repository = BlocksNativePluginMetadataRepository(database: database)
            let platformRepository = BlocksPluginPlatformRepository(database: database)
            let debugLogStore = BlocksPluginDebugLogStore(environment: environment)
            let hostOperationRouter = BlocksPluginHostOperationRouter()
            let secretStore = BlocksNativePluginSecretStore()
            let executor = BlocksNativePluginXPCExecutionClient(
                repository: repository,
                secretResolver: { pluginID, secretID in
                    try secretStore.read(pluginID: pluginID, secretID: secretID)
                },
                hostOperationHandler: { request in
                    hostOperationRouter.perform(request)
                },
                networkAuditHandler: { pluginID, entry in
                    guard (try? repository.metadata(id: pluginID).debugEnabled)
                        == true else { return }
                    try? debugLogStore.append(
                        pluginID: pluginID,
                        entry: entry
                    )
                }
            )
            return BlocksNativePluginManager(
                repository: repository,
                managedRoot: environment.rootDirectory
                    .appendingPathComponent(
                        "TranslationPlugins",
                        isDirectory: true
                    ),
                executor: executor,
                secretStore: secretStore,
                configurationStore:
                    BlocksNativePluginConfigurationStore(
                        defaults: .standard
                    ),
                validationStore:
                    BlocksNativePluginValidationStore(
                        defaults: .standard
                    ),
                platformRepository: platformRepository,
                debugLogStore: debugLogStore,
                hostOperationRouter: hostOperationRouter
            )
        } catch {
            return BlocksNativePluginManager(storageUnavailableBecause: error)
        }
    }

    func bindTranslationPlugins() {
        translationPluginManager.$plugins
            .sink { [weak self] _ in
                self?.refreshTranslationPluginRuntime()
            }
            .store(in: &cancellables)
        translationPluginManager.$configurationRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshTranslationPluginRuntime()
            }
            .store(in: &cancellables)
        refreshTranslationPluginRuntime()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await translationPluginManager.reload()
            guard !Task.isCancelled,
                  translationPluginManager.snapshotIsReady else { return }
            if let builtInCatalog = try? BlocksBuiltInPluginCatalog.load() {
                await translationPluginManager.applyCompatibleBuiltInUpdates(
                    catalog: builtInCatalog
                )
            }
            await pluginRuntimeCoordinator.reloadSchedules()
            pluginRuntimeCoordinator.dispatchAsync(
                BlocksPluginEventEnvelope(name: .appLaunched)
            )
        }
    }

    func refreshTranslationPluginRuntime() {
        translationPluginRefreshTask?.cancel()
        translationPluginRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var translationAdapters: [any TranslationServiceAdapter] = []
            var runtimeFailures: [BlocksNativePluginRuntimeLoadFailure] = []
            for metadata in translationPluginManager.plugins
                where metadata.capabilities.contains(.translation)
            {
                guard !Task.isCancelled else { return }
                guard metadata.isEnabled else {
                    translationAdapters.append(
                        TranslationUnavailablePluginServiceAdapter(
                            metadata: metadata,
                            errorCode: "plugin_disabled",
                            message: L10n.string(
                                "translation.error.pluginDisabled"
                            )
                        )
                    )
                    continue
                }
                guard metadata.approvalStatus == .approved else {
                    translationAdapters.append(
                        TranslationUnavailablePluginServiceAdapter(
                            metadata: metadata,
                            errorCode: "plugin_not_approved",
                            message: L10n.string(
                                "translation.error.pluginNotApproved"
                            )
                        )
                    )
                    continue
                }
                do {
                    let adapter = try await translationPluginManager
                        .makeTranslationAdapter(pluginID: metadata.id)
                    translationAdapters.append(adapter)
                } catch {
                    translationAdapters.append(
                        TranslationUnavailablePluginServiceAdapter(
                            metadata: metadata,
                            errorCode: "plugin_runner_unavailable",
                            message: error.localizedDescription
                        )
                    )
                    runtimeFailures.append(
                        BlocksNativePluginRuntimeLoadFailure(
                            pluginID: metadata.id,
                            displayName: metadata.displayName,
                            capability: .translation,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            guard !Task.isCancelled else { return }
            translationStore.replacePluginAdapters(
                translationAdapters,
                snapshotIsAuthoritative:
                    translationPluginManager.pluginSnapshotIsAuthoritative
            )

            let defaults = UserDefaults.standard
            let preferredOCRService = defaults.string(
                forKey: "translation.ocr.defaultServiceID"
            ) ?? TranslationPluginRuntimeSelection.appleVisionOCRServiceID
            guard preferredOCRService.hasPrefix(
                TranslationPluginRuntimeSelection.pluginOCRServicePrefix
            ) else {
                if preferredOCRService
                    != TranslationPluginRuntimeSelection.appleVisionOCRServiceID
                {
                    defaults.set(
                        TranslationPluginRuntimeSelection
                            .appleVisionOCRServiceID,
                        forKey: "translation.ocr.defaultServiceID"
                    )
                }
                translationCoordinator.setScreenshotOCRProvider(nil)
                translationPluginManager.updateRuntimeLoadFailures(
                    runtimeFailures
                )
                return
            }
            guard let pluginID =
                TranslationPluginRuntimeSelection.enabledOCRPluginID(
                    preferredServiceID: preferredOCRService,
                    plugins: translationPluginManager.plugins
                )
            else {
                let configuredPluginID = String(
                    preferredOCRService.dropFirst(
                        TranslationPluginRuntimeSelection
                            .pluginOCRServicePrefix.count
                    )
                )
                let metadata = translationPluginManager.plugins.first {
                    $0.id == configuredPluginID
                }
                runtimeFailures.append(
                    BlocksNativePluginRuntimeLoadFailure(
                        pluginID: configuredPluginID,
                        displayName: metadata?.displayName ?? configuredPluginID,
                        capability: .ocr,
                        message:
                            "The configured OCR plugin is disabled, unapproved, or unavailable."
                    )
                )
                translationCoordinator.setScreenshotOCRProvider(nil)
                translationPluginManager.updateRuntimeLoadFailures(
                    runtimeFailures
                )
                return
            }
            do {
                let adapter = try await translationPluginManager.makeOCRAdapter(
                    pluginID: pluginID
                )
                guard !Task.isCancelled else { return }
                translationCoordinator.setScreenshotOCRProvider(adapter)
            } catch {
                let metadata = translationPluginManager.plugins.first {
                    $0.id == pluginID
                }
                runtimeFailures.append(
                    BlocksNativePluginRuntimeLoadFailure(
                        pluginID: pluginID,
                        displayName: metadata?.displayName ?? pluginID,
                        capability: .ocr,
                        message: error.localizedDescription
                    )
                )
                guard !Task.isCancelled else { return }
                translationCoordinator.setScreenshotOCRProvider(nil)
            }
            translationPluginManager.updateRuntimeLoadFailures(runtimeFailures)
        }
    }
}
