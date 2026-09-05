import BlocksCore
import Foundation

@MainActor
final class TranslationSourceManagementService {
    @TaskLocal private static var currentActionRequestID: String? = nil

    private struct ActiveActionRequest {
        var task:
            Task<TranslationSourceManagementActionResult, Error>?
        var pluginID: String?
    }

    private struct PluginSourceTransition {
        var completionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private struct SourceIntent: Equatable {
        let generation: UInt64
        let enabled: Bool
    }

    private struct RecordedSourceIntent {
        let intent: SourceIntent
        let previousIntent: SourceIntent?
    }

    private let pluginManager: BlocksNativePluginManager
    private let translationStore: TranslationStore
    private let packageWorker: TranslationSourcePackageWorker
    private let communityDisclosureStore: TranslationCommunityWebDisclosureStore
    private let pluginRuntimeEnabled: (Bool, String) async throws -> Void
    private var activeActionRequests: [String: ActiveActionRequest] = [:]
    // A source's most recent request owns all state writes that follow an
    // asynchronous runtime transition. This is deliberately per-source so an
    // unrelated plugin cannot delay or invalidate another source's intent.
    private var sourceIntentSequences: [String: UInt64] = [:]
    private var sourceIntents: [String: SourceIntent] = [:]
    private var pluginSourceTransitions: [String: PluginSourceTransition] = [:]

    init(
        pluginManager: BlocksNativePluginManager,
        translationStore: TranslationStore,
        packageWorker: TranslationSourcePackageWorker =
            TranslationSourcePackageWorker(),
        communityDisclosureStore: TranslationCommunityWebDisclosureStore =
            TranslationCommunityWebDisclosureStore(),
        pluginRuntimeEnabled: ((Bool, String) async throws -> Void)? = nil
    ) {
        self.pluginManager = pluginManager
        self.translationStore = translationStore
        self.packageWorker = packageWorker
        self.communityDisclosureStore = communityDisclosureStore
        self.pluginRuntimeEnabled = pluginRuntimeEnabled ?? { enabled, pluginID in
            _ = try await pluginManager.setEnabled(
                enabled,
                pluginID: pluginID
            )
        }
    }

    // MARK: - Shared UI / Action façade

    func reloadPluginSnapshot() async {
        await pluginManager.reload()
    }

    func preparePluginInstallation(
        from packageURL: URL
    ) async throws -> BlocksNativePluginPendingInstallation {
        try await ensurePluginSnapshot()
        return try await pluginManager.prepareInstallation(
            from: packageURL
        )
    }

    func confirmPluginInstallation(
        pendingID: UUID
    ) async throws -> BlocksNativePluginMetadata {
        try await ensurePluginSnapshot()
        return try await pluginManager.confirmAndInstall(
            pendingID: pendingID
        )
    }

    func cancelPluginInstallation() {
        pluginManager.cancelPendingInstallation()
    }

    func setSourceEnabled(
        _ enabled: Bool,
        sourceID: String
    ) async throws {
        try await setEnabled(enabled, sourceID: sourceID)
    }

    func moveEnabledSource(
        sourceID: String,
        before destinationSourceID: String?
    ) {
        translationStore.moveEnabledService(
            serviceID: sourceID,
            before: destinationSourceID
        )
    }

    func setPluginRuntimeEnabled(
        _ enabled: Bool,
        pluginID: String
    ) async throws {
        _ = try await pluginManager.setEnabled(
            enabled,
            pluginID: pluginID
        )
    }

    func testSource(
        sourceID: String,
        capability: BlocksNativePluginCapability = .translation,
        testText: String? = nil,
        testImage: TranslationSourceEncodedImage? = nil
    ) async -> TranslationSourceConnectionTestSummary {
        await connectionTest(
            sourceID: sourceID,
            capability: capability,
            testText: testText,
            testImage: testImage
        )
    }

    func testServiceProfile(
        _ profile: TranslationServiceProfile
    ) async throws -> String {
        try await translationStore.connectionTest(profile: profile)
    }

    func testCommunitySource(
        sourceID: String,
        testText: String? = nil
    ) async throws {
        try requireCommunityWebDisclosure(sourceID: sourceID)
        try await translationStore.testCommunityService(
            serviceID: sourceID,
            testText: testText
        )
    }

    func uninstallPlugin(pluginID: String) async throws {
        try checkActionCancellation()
        try await pluginManager.uninstall(pluginID: pluginID)
        translationStore.removePluginService(pluginID: pluginID)
    }

    func pluginConfiguration(
        pluginID: String
    ) async throws -> [String: JSONValue] {
        try await pluginManager.configuration(pluginID: pluginID)
    }

    func savePluginConfiguration(
        _ configuration: [String: JSONValue],
        pluginID: String
    ) async throws {
        try await saveConfiguration(
            configuration,
            pluginID: pluginID
        )
    }

    func savePluginSecret(
        _ value: String,
        pluginID: String,
        secretID: String
    ) async throws {
        try checkActionCancellation()
        do {
            try await pluginManager.saveSecret(
                value,
                pluginID: pluginID,
                secretID: secretID
            )
        } catch {
            synchronizePluginEnablement(pluginID: pluginID)
            throw error
        }
        synchronizePluginEnablement(pluginID: pluginID)
    }

    func deletePluginSecret(
        pluginID: String,
        secretID: String
    ) async throws {
        try checkActionCancellation()
        do {
            try await pluginManager.deleteSecret(
                pluginID: pluginID,
                secretID: secretID
            )
        } catch {
            synchronizePluginEnablement(pluginID: pluginID)
            throw error
        }
        synchronizePluginEnablement(pluginID: pluginID)
    }

    func execute(
        _ input: TranslationSourceManagementActionInput,
        requestID: ActionRequestID? = nil
    ) async throws -> TranslationSourceManagementActionResult {
        guard let requestKey = requestID?.rawValue else {
            return try await executeOperation(input)
        }
        guard activeActionRequests[requestKey] == nil else {
            throw TranslationSourceManagementServiceError
                .invalidField("request_id")
        }
        let task = Task { @MainActor [self] in
            try await Self.$currentActionRequestID.withValue(
                requestKey
            ) {
                try Task.checkCancellation()
                return try await executeOperation(input)
            }
        }
        activeActionRequests[requestKey] = ActiveActionRequest(
            task: task,
            pluginID: nil
        )
        defer {
            activeActionRequests.removeValue(forKey: requestKey)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelActionRequest(_ requestID: String) -> Bool {
        guard let request = activeActionRequests[requestID] else {
            return false
        }
        request.task?.cancel()
        if let pluginID = request.pluginID {
            pluginManager.cancelActiveExecutions(pluginID: pluginID)
        }
        return true
    }

    private func executeOperation(
        _ input: TranslationSourceManagementActionInput
    ) async throws -> TranslationSourceManagementActionResult {
        switch input.operation {
        case .list:
            try await ensurePluginSnapshot()
            try checkActionCancellation()
            return result(
                for: .list,
                sources: input.pluginScope == true
                    ? pluginManager.plugins.map(summary(for:))
                    : nil
            )

        case .scaffold:
            let scaffold = try BlocksNativePluginScaffoldFactory.make(
                id: require(input.scaffoldID, field: "scaffold_id"),
                displayName: require(
                    input.scaffoldDisplayName,
                    field: "scaffold_display_name"
                ),
                pluginScope: input.pluginScope == true
            )
            return result(for: .scaffold, scaffold: scaffold)

        case .validatePackage, .inspectPackage:
            let inspection = try await inspect(
                package: try require(input.package, field: "package")
            )
            try checkActionCancellation()
            return result(
                for: input.operation,
                inspection: inspection
            )

        case .inspectInstalled:
            try await ensurePluginSnapshot()
            let pluginID = pluginID(
                from: try require(input.sourceID, field: "source_id")
            )
            let (_, package) = try await pluginManager
                .loadInstalledPackage(pluginID: pluginID)
            try checkActionCancellation()
            return result(
                for: .inspectInstalled,
                inspection: TranslationSourcePackageInspection(
                    manifest: package.manifest,
                    confirmation: package.installationConfirmation
                )
            )

        case .install:
            let package = try require(input.package, field: "package")
            let confirmationSHA256 = try require(
                input.confirmationSHA256,
                field: "confirmation_sha256"
            )
            let installed = try await install(
                package: package,
                confirmationSHA256: confirmationSHA256
            )
            return result(
                for: .install,
                sources: [summary(for: installed)]
            )

        case .configure:
            let pluginID = pluginID(
                from: try require(input.sourceID, field: "source_id")
            )
            setActivePluginID(pluginID)
            let configuration = try require(
                input.configuration,
                field: "configuration"
            )
            try await saveConfiguration(
                configuration,
                pluginID: pluginID
            )
            return result(for: .configure)

        case .setSecret:
            let pluginID = pluginID(
                from: try require(input.sourceID, field: "source_id")
            )
            setActivePluginID(pluginID)
            let secretID = try require(input.secretID, field: "secret_id")
            let secretValue = try require(
                input.secretValue,
                field: "secret_value"
            )
            try await savePluginSecret(
                secretValue,
                pluginID: pluginID,
                secretID: secretID
            )
            return result(for: .setSecret)

        case .test:
            let sourceID = try require(input.sourceID, field: "source_id")
            if sourceID.hasPrefix("plugin:") {
                setActivePluginID(pluginID(from: sourceID))
            }
            let capability = input.capability ?? .translation
            let test = await connectionTest(
                sourceID: sourceID,
                capability: capability,
                testText: input.testText,
                testImage: input.testImage
            )
            try checkActionCancellation()
            guard test.succeeded else {
                throw TranslationSourceManagementServiceError
                    .connectionTestFailed(
                        code:
                            test.errorCode
                            ?? "connection_test_failed",
                        message:
                            test.errorMessage
                            ?? "The translation source connection test failed."
                    )
            }
            return result(for: .test, connectionTest: test)

        case .enable:
            let sourceID = try require(input.sourceID, field: "source_id")
            if input.pluginScope == true {
                let pluginID = pluginID(from: sourceID)
                setActivePluginID(pluginID)
                _ = try await pluginManager.setEnabled(true, pluginID: pluginID)
                return result(for: .enable, sources: [
                    summary(for: try requirePlugin(pluginID))
                ])
            }
            if sourceID.hasPrefix("plugin:") {
                setActivePluginID(pluginID(from: sourceID))
            }
            try await setEnabled(true, sourceID: sourceID)
            return result(for: .enable)

        case .disable:
            let sourceID = try require(input.sourceID, field: "source_id")
            if input.pluginScope == true {
                let pluginID = pluginID(from: sourceID)
                setActivePluginID(pluginID)
                _ = try await pluginManager.setEnabled(false, pluginID: pluginID)
                return result(for: .disable, sources: [
                    summary(for: try requirePlugin(pluginID))
                ])
            }
            if sourceID.hasPrefix("plugin:") {
                setActivePluginID(pluginID(from: sourceID))
            }
            try await setEnabled(false, sourceID: sourceID)
            return result(for: .disable)

        case .reorder:
            try checkActionCancellation()
            try reorder(
                require(
                    input.orderedSourceIDs,
                    field: "ordered_source_ids"
                )
            )
            return result(for: .reorder)

        case .exportRedacted:
            let sourceID = try require(input.sourceID, field: "source_id")
            if sourceID.hasPrefix("plugin:") {
                setActivePluginID(pluginID(from: sourceID))
            }
            return result(
                for: .exportRedacted,
                redactedExport: try await redactedExport(
                    sourceID: sourceID
                )
            )

        case .setDebug:
            guard input.pluginScope == true else {
                throw TranslationSourceManagementServiceError
                    .invalidField("plugin_scope")
            }
            let pluginID = pluginID(
                from: try require(input.sourceID, field: "source_id")
            )
            try await pluginManager.setDebugEnabled(
                try require(input.debugEnabled, field: "debug_enabled"),
                pluginID: pluginID
            )
            return result(for: .setDebug, sources: [
                summary(for: try requirePlugin(pluginID))
            ])

        case .clearLogs:
            guard input.pluginScope == true, input.confirmed else {
                throw TranslationSourceManagementServiceError
                    .confirmationRequired
            }
            let pluginID = pluginID(
                from: try require(input.sourceID, field: "source_id")
            )
            try pluginManager.debugLogStore?.clear(pluginID: pluginID)
            return result(for: .clearLogs, sources: [
                summary(for: try requirePlugin(pluginID))
            ])

        case .clearSafetyDisable:
            guard input.pluginScope == true, input.confirmed else {
                throw TranslationSourceManagementServiceError
                    .confirmationRequired
            }
            let pluginID = pluginID(
                from: try require(input.sourceID, field: "source_id")
            )
            try await pluginManager.clearSafetyDisable(pluginID: pluginID)
            return result(for: .clearSafetyDisable, sources: [
                summary(for: try requirePlugin(pluginID))
            ])

        case .remove:
            guard input.confirmed else {
                throw TranslationSourceManagementServiceError
                    .confirmationRequired
            }
            let sourceID = try require(input.sourceID, field: "source_id")
            let pluginID = pluginID(from: sourceID)
            setActivePluginID(pluginID)
            try await uninstallPlugin(pluginID: pluginID)
            return result(for: .remove)
        }
    }

    private func ensurePluginSnapshot() async throws {
        try checkActionCancellation()
        if !pluginManager.snapshotIsReady {
            await pluginManager.reload()
        }
        try checkActionCancellation()
        guard pluginManager.isReadyForMutations else {
            throw TranslationSourceManagementServiceError
                .pluginStorageUnavailable
        }
    }

    private func requirePlugin(
        _ pluginID: String
    ) throws -> BlocksNativePluginMetadata {
        guard let plugin = pluginManager.plugins.first(where: {
            $0.id == pluginID
        }) else {
            throw TranslationSourceManagementServiceError
                .sourceUnavailable(pluginID)
        }
        return plugin
    }

    private func inspect(
        package: TranslationSourcePackageSnapshot
    ) async throws -> TranslationSourcePackageInspection {
        try checkActionCancellation()
        let validated = try await packageWorker.validate(package)
        try checkActionCancellation()
        return TranslationSourcePackageInspection(
            manifest: validated.manifest,
            confirmation: validated.installationConfirmation
        )
    }

    private func install(
        package: TranslationSourcePackageSnapshot,
        confirmationSHA256: String
    ) async throws -> BlocksNativePluginMetadata {
        try await ensurePluginSnapshot()
        let validated = try await packageWorker.validate(package)
        try checkActionCancellation()
        setActivePluginID(validated.manifest.id)
        let pending = try await pluginManager.prepareInstallation(
            validatedPackage: validated,
            sourceDisplayName: "Source.blocksplugin"
        )
        do {
            try checkActionCancellation()
        } catch {
            pluginManager.cancelPendingInstallation()
            throw error
        }
        guard pending.confirmation.packageSHA256
            .caseInsensitiveCompare(confirmationSHA256)
            == .orderedSame else {
            pluginManager.cancelPendingInstallation()
            throw TranslationSourceManagementServiceError
                .confirmationHashMismatch
        }
        try checkActionCancellation()
        return try await pluginManager.confirmAndInstall(
            pendingID: pending.id
        )
    }

    private func saveConfiguration(
        _ configuration: [String: JSONValue],
        pluginID: String
    ) async throws {
        let (_, package) = try await pluginManager.loadInstalledPackage(
            pluginID: pluginID
        )
        try checkActionCancellation()
        let sensitiveFieldIDs = Set(
            package.manifest.configurationFields.lazy
                .filter { $0.type.isSensitive }
                .map(\.id)
        )
        guard sensitiveFieldIDs.isDisjoint(with: configuration.keys) else {
            throw TranslationSourceManagementServiceError
                .sensitiveConfigurationRequiresSecretCommand
        }
        try checkActionCancellation()
        do {
            try await pluginManager.saveConfiguration(
                configuration,
                pluginID: pluginID
            )
        } catch {
            synchronizePluginEnablement(pluginID: pluginID)
            throw error
        }
        synchronizePluginEnablement(pluginID: pluginID)
    }

    private func synchronizePluginEnablement(pluginID: String) {
        let isEnabled =
            pluginManager.snapshotIsReady
            && pluginManager.plugins.first(where: { $0.id == pluginID })?
                .isEnabled == true
            && pluginManager.validatedPluginIDs.contains(pluginID)
        translationStore.setServiceEnabled(
            isEnabled,
            serviceID: sourceID(forPluginID: pluginID)
        )
    }

    private func connectionTest(
        sourceID: String,
        capability: BlocksNativePluginCapability,
        testText: String?,
        testImage: TranslationSourceEncodedImage? = nil
    ) async -> TranslationSourceConnectionTestSummary {
        if sourceID.hasPrefix("plugin:") {
            let pluginID = pluginID(from: sourceID)
            let result = await pluginManager.connectionTest(
                pluginID: pluginID,
                capability: capability,
                testText: testText,
                testImage: testImage
            )
            if !result.succeeded,
               result.errorCode != "request_cancelled",
               pluginManager.plugins.first(where: {
                   $0.id == pluginID
               })?.isEnabled == false {
                translationStore.removePluginService(
                    pluginID: sourceID
                )
            }
            return TranslationSourceConnectionTestSummary(
                sourceID: sourceID,
                capability: capability,
                succeeded: result.succeeded,
                outputSummary: result.outputSummary,
                errorCode: result.errorCode,
                errorMessage: result.errorMessage
            )
        }
        guard testImage == nil,
              capability == .translation,
              translationStore.availableServices.contains(where: {
                  $0.id == sourceID && $0.kind == .communityWeb
              }) else {
            return TranslationSourceConnectionTestSummary(
                sourceID: sourceID,
                capability: capability,
                succeeded: false,
                errorCode: "connection_test_unsupported",
                errorMessage:
                    "This translation source does not expose a CLI connection test."
            )
        }
        do {
            try requireCommunityWebDisclosure(sourceID: sourceID)
            try await translationStore.testCommunityService(
                serviceID: sourceID,
                testText: testText
            )
            return TranslationSourceConnectionTestSummary(
                sourceID: sourceID,
                capability: capability,
                succeeded: true
            )
        } catch {
            let managementError =
                error as? TranslationSourceManagementServiceError
            return TranslationSourceConnectionTestSummary(
                sourceID: sourceID,
                capability: capability,
                succeeded: false,
                errorCode:
                    managementError?.code
                        ?? "connection_test_failed",
                errorMessage: String(
                    error.localizedDescription.prefix(512)
                )
            )
        }
    }

    private func setEnabled(
        _ enabled: Bool,
        sourceID: String
    ) async throws {
        try checkActionCancellation()
        let isPersistentlyEnabled =
            translationStore.enabledServiceIDs.contains(sourceID)
        let hasConflictingPluginIntent =
            sourceID.hasPrefix("plugin:")
            && sourceIntents[sourceID].map { $0.enabled != enabled } == true
        let isAlreadyInRequestedState =
            isPersistentlyEnabled == enabled && !hasConflictingPluginIntent
        if enabled,
           !isPersistentlyEnabled,
           translationStore.enabledServiceIDs.count >= 4 {
            throw TranslationSourceManagementServiceError
                .maximumEnabledSourcesReached
        }

        if enabled {
            try requireCommunityWebDisclosure(sourceID: sourceID)
        }
        guard !isAlreadyInRequestedState else { return }

        guard sourceID.hasPrefix("plugin:") else {
            try checkActionCancellation()
            translationStore.setServiceEnabled(
                enabled,
                serviceID: sourceID
            )
            guard translationStore.enabledServiceIDs
                .contains(sourceID) == enabled else {
                throw TranslationSourceManagementServiceError
                    .sourceUnavailable(sourceID)
            }
            return
        }

        let pluginID = pluginID(from: sourceID)
        let recordedIntent = recordSourceIntent(
            sourceID: sourceID,
            enabled: enabled
        )
        let generation = recordedIntent.intent.generation
        do {
            try await waitForPluginSourceTransition(sourceID: sourceID)
            try Task.checkCancellation()
            guard isCurrentSourceIntent(
                sourceID: sourceID,
                generation: generation,
                enabled: enabled
            ) else { return }
        } catch {
            restoreSourceIntentIfCurrent(
                sourceID: sourceID,
                recordedIntent: recordedIntent
            )
            throw error
        }
        beginPluginSourceTransition(sourceID: sourceID)
        defer { finishPluginSourceTransition(sourceID: sourceID) }

        if !enabled {
            do {
                try checkActionCancellation()
                guard isCurrentSourceIntent(
                    sourceID: sourceID,
                    generation: generation,
                    enabled: false
                ) else { return }
                try await pluginRuntimeEnabled(false, pluginID)
                try checkActionCancellation()
                guard isCurrentSourceIntent(
                    sourceID: sourceID,
                    generation: generation,
                    enabled: false
                ) else {
                    await compensatePluginRuntimeForCurrentIntent(
                        sourceID: sourceID,
                        pluginID: pluginID,
                        performedEnabled: false
                    )
                    return
                }
                translationStore.setServiceEnabled(
                    false,
                    serviceID: sourceID
                )
            } catch {
                restoreSourceIntentIfCurrent(
                    sourceID: sourceID,
                    recordedIntent: recordedIntent
                )
                await compensatePluginRuntimeForCurrentIntent(
                    sourceID: sourceID,
                    pluginID: pluginID,
                    performedEnabled: false
                )
                throw error
            }
            return
        }

        try await pluginRuntimeEnabled(true, pluginID)
        do {
            guard isCurrentSourceIntent(
                sourceID: sourceID,
                generation: generation,
                enabled: true
            ) else {
                if currentSourceIntentEnabled(sourceID: sourceID) == false {
                    await disablePluginAfterFailedEnable(pluginID: pluginID)
                }
                return
            }
            guard try await waitUntilSourceIsAvailable(
                sourceID,
                generation: generation
            ) else {
                guard isCurrentSourceIntent(
                    sourceID: sourceID,
                    generation: generation,
                    enabled: true
                ) else {
                    if currentSourceIntentEnabled(sourceID: sourceID) == false {
                        await disablePluginAfterFailedEnable(pluginID: pluginID)
                    }
                    return
                }
                throw TranslationSourceManagementServiceError
                    .sourceUnavailable(sourceID)
            }
            try checkActionCancellation()
            guard isCurrentSourceIntent(
                sourceID: sourceID,
                generation: generation,
                enabled: true
            ) else {
                if currentSourceIntentEnabled(sourceID: sourceID) == false {
                    await disablePluginAfterFailedEnable(pluginID: pluginID)
                }
                return
            }
            translationStore.setServiceEnabled(
                true,
                serviceID: sourceID
            )
            guard translationStore.enabledServiceIDs.contains(sourceID) else {
                throw TranslationSourceManagementServiceError
                    .sourceUnavailable(sourceID)
            }
        } catch {
            await disablePluginAfterFailedEnable(pluginID: pluginID)
            throw error
        }
    }

    private func disablePluginAfterFailedEnable(pluginID: String) async {
        let pluginRuntimeEnabled = pluginRuntimeEnabled
        let cleanup = Task { @MainActor in
            _ = try? await pluginRuntimeEnabled(false, pluginID)
        }
        _ = await cleanup.result
    }

    private func compensatePluginRuntimeForCurrentIntent(
        sourceID: String,
        pluginID: String,
        performedEnabled: Bool
    ) async {
        let intendedEnabled = currentSourceIntentEnabled(sourceID: sourceID)
            ?? translationStore.enabledServiceIDs.contains(sourceID)
        guard intendedEnabled != performedEnabled else { return }
        _ = try? await pluginRuntimeEnabled(intendedEnabled, pluginID)
    }

    private func waitUntilSourceIsAvailable(
        _ sourceID: String,
        generation: UInt64
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        repeat {
            try checkActionCancellation()
            guard isCurrentSourceIntent(
                sourceID: sourceID,
                generation: generation,
                enabled: true
            ) else {
                return false
            }
            if translationStore.availableServices.contains(where: {
                $0.id == sourceID && $0.availability == .available
            }) {
                return true
            }
            await Task.yield()
            guard isCurrentSourceIntent(
                sourceID: sourceID,
                generation: generation,
                enabled: true
            ) else {
                return false
            }
            try await Task.sleep(for: .milliseconds(20))
            guard isCurrentSourceIntent(
                sourceID: sourceID,
                generation: generation,
                enabled: true
            ) else {
                return false
            }
        } while clock.now < deadline
        return false
    }

    private func recordSourceIntent(
        sourceID: String,
        enabled: Bool
    ) -> RecordedSourceIntent {
        let generation = (sourceIntentSequences[sourceID] ?? 0) &+ 1
        sourceIntentSequences[sourceID] = generation
        let intent = SourceIntent(generation: generation, enabled: enabled)
        let recordedIntent = RecordedSourceIntent(
            intent: intent,
            previousIntent: sourceIntents[sourceID]
        )
        sourceIntents[sourceID] = intent
        return recordedIntent
    }

    private func restoreSourceIntentIfCurrent(
        sourceID: String,
        recordedIntent: RecordedSourceIntent
    ) {
        guard sourceIntents[sourceID] == recordedIntent.intent else { return }
        sourceIntents[sourceID] = recordedIntent.previousIntent
    }

    private func isCurrentSourceIntent(
        sourceID: String,
        generation: UInt64,
        enabled: Bool
    ) -> Bool {
        sourceIntents[sourceID] == SourceIntent(
            generation: generation,
            enabled: enabled
        )
    }

    private func currentSourceIntentEnabled(sourceID: String) -> Bool? {
        sourceIntents[sourceID]?.enabled
    }

    private func beginPluginSourceTransition(sourceID: String) {
        precondition(pluginSourceTransitions[sourceID] == nil)
        pluginSourceTransitions[sourceID] = PluginSourceTransition()
    }

    private func waitForPluginSourceTransition(sourceID: String) async throws {
        while pluginSourceTransitions[sourceID] != nil {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    registerPluginSourceTransitionWaiter(
                        sourceID: sourceID,
                        waiterID: waiterID,
                        continuation: continuation
                    )
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelPluginSourceTransitionWaiter(
                        sourceID: sourceID,
                        waiterID: waiterID
                    )
                }
            }
            try Task.checkCancellation()
        }
    }

    private func registerPluginSourceTransitionWaiter(
        sourceID: String,
        waiterID: UUID,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard var transition = pluginSourceTransitions[sourceID] else {
            continuation.resume()
            return
        }
        transition.completionWaiters[waiterID] = continuation
        pluginSourceTransitions[sourceID] = transition
    }

    private func cancelPluginSourceTransitionWaiter(
        sourceID: String,
        waiterID: UUID
    ) {
        guard var transition = pluginSourceTransitions[sourceID],
              let continuation = transition.completionWaiters.removeValue(
                forKey: waiterID
              ) else {
            return
        }
        pluginSourceTransitions[sourceID] = transition
        continuation.resume(throwing: CancellationError())
    }

    private func finishPluginSourceTransition(sourceID: String) {
        let waiters = pluginSourceTransitions.removeValue(
            forKey: sourceID
        )?.completionWaiters ?? [:]
        waiters.values.forEach { $0.resume() }
    }

    private func checkActionCancellation() throws {
        try Task.checkCancellation()
    }

    private func requireCommunityWebDisclosure(sourceID: String) throws {
        guard let source = TranslationCommunityWebSource(rawValue: sourceID)
        else {
            return
        }
        guard communityDisclosureStore.isAcknowledged(source: source) else {
            throw TranslationSourceManagementServiceError.confirmationRequired
        }
    }

    private func setActivePluginID(_ pluginID: String) {
        guard let requestID = Self.currentActionRequestID,
              var request = activeActionRequests[requestID] else {
            return
        }
        request.pluginID = pluginID
        activeActionRequests[requestID] = request
    }

    private func reorder(_ orderedSourceIDs: [String]) throws {
        guard !orderedSourceIDs.isEmpty,
              orderedSourceIDs.count <= 4,
              Set(orderedSourceIDs).count == orderedSourceIDs.count,
              Set(orderedSourceIDs)
                == Set(translationStore.enabledServiceIDs) else {
            throw TranslationSourceManagementServiceError
                .invalidSourceOrder
        }
        guard translationStore.setEnabledServiceOrder(
            orderedSourceIDs
        ) else {
            throw TranslationSourceManagementServiceError.invalidSourceOrder
        }
    }

    private func redactedExport(
        sourceID: String
    ) async throws -> TranslationSourceRedactedExport {
        guard sourceID.hasPrefix("plugin:") else {
            guard let summary = summaries().first(where: {
                $0.sourceID == sourceID
            }) else {
                throw TranslationSourceManagementServiceError
                    .sourceUnavailable(sourceID)
            }
            return TranslationSourceRedactedExport(
                source: summary,
                manifest: nil,
                configuration: [:],
                declaredSecretIDs: []
            )
        }
        let pluginID = pluginID(from: sourceID)
        let (_, package) = try await pluginManager.loadInstalledPackage(
            pluginID: pluginID
        )
        try checkActionCancellation()
        let sensitiveIDs = Set(
            package.manifest.configurationFields.lazy
                .filter { $0.type.isSensitive }
                .map(\.id)
        )
        let storedConfiguration = try await pluginManager.configuration(
            pluginID: pluginID
        )
        try checkActionCancellation()
        let configuration = storedConfiguration.filter {
            !sensitiveIDs.contains($0.key)
        }
        guard let summary = summaries().first(where: {
            $0.sourceID == sourceID
        }) else {
            throw TranslationSourceManagementServiceError
                .sourceUnavailable(sourceID)
        }
        return TranslationSourceRedactedExport(
            source: summary,
            manifest: package.manifest,
            configuration: configuration,
            declaredSecretIDs:
                package.manifest.permissions.secrets.map(\.id).sorted()
        )
    }

    private func result(
        for operation: TranslationSourceManagementOperation,
        sources: [TranslationSourceSummary]? = nil,
        inspection: TranslationSourcePackageInspection? = nil,
        scaffold: TranslationSourceScaffold? = nil,
        connectionTest: TranslationSourceConnectionTestSummary? = nil,
        redactedExport: TranslationSourceRedactedExport? = nil
    ) -> TranslationSourceManagementActionResult {
        TranslationSourceManagementActionResult(
            operation: operation,
            sources: sources ?? summaries(),
            inspection: inspection,
            scaffold: scaffold,
            connectionTest: connectionTest,
            redactedExport: redactedExport,
            enabledSourceIDs: translationStore.enabledServiceIDs
        )
    }

    private func summaries() -> [TranslationSourceSummary] {
        let pluginMetadataBySourceID = Dictionary(
            uniqueKeysWithValues: pluginManager.plugins.map {
                (sourceID(forPluginID: $0.id), $0)
            }
        )
        var includedPluginIDs = Set<String>()
        var output = translationStore.availableServices.map { descriptor in
            let metadata = pluginMetadataBySourceID[descriptor.id]
            if let metadata {
                includedPluginIDs.insert(metadata.id)
            }
            return TranslationSourceSummary(
                sourceID: descriptor.id,
                pluginID: metadata?.id,
                displayName: descriptor.displayName,
                kind: descriptor.kind.rawValue,
                version: descriptor.version,
                availability: descriptor.availability.rawValue,
                isEnabled: translationStore.enabledServiceIDs
                    .contains(descriptor.id),
                isPluginRuntimeEnabled: metadata?.isEnabled,
                isValidated: metadata.map {
                    pluginManager.validatedPluginIDs.contains($0.id)
                },
                capabilities: metadata?.capabilities ?? []
            )
        }
        output.append(
            contentsOf: pluginManager.plugins
                .filter {
                    !includedPluginIDs.contains($0.id)
                        && $0.capabilities.contains(.translation)
                }
                .map(summary(for:))
        )
        return output
    }

    private func summary(
        for metadata: BlocksNativePluginMetadata
    ) -> TranslationSourceSummary {
        let sourceID = sourceID(forPluginID: metadata.id)
        return TranslationSourceSummary(
            sourceID: sourceID,
            pluginID: metadata.id,
            displayName: metadata.displayName,
            kind: TranslationServiceKind.plugin.rawValue,
            version: metadata.packageVersion,
            availability:
                metadata.isEnabled
                    ? TranslationServiceAvailability.available.rawValue
                    : TranslationServiceAvailability.disabled.rawValue,
            isEnabled: translationStore.enabledServiceIDs
                .contains(sourceID),
            isPluginRuntimeEnabled: metadata.isEnabled,
            isValidated: pluginManager.validatedPluginIDs
                .contains(metadata.id),
            capabilities: metadata.capabilities
        )
    }

    private func require<Value>(
        _ value: Value?,
        field: String
    ) throws -> Value {
        guard let value else {
            throw TranslationSourceManagementServiceError
                .missingField(field)
        }
        return value
    }

    private func pluginID(from sourceID: String) -> String {
        sourceID.hasPrefix("plugin:")
            ? String(sourceID.dropFirst("plugin:".count))
            : sourceID
    }

    private func sourceID(forPluginID pluginID: String) -> String {
        pluginID.hasPrefix("plugin:")
            ? pluginID
            : "plugin:\(pluginID)"
    }
}

enum TranslationSourceManagementServiceError:
    Error,
    LocalizedError,
    Equatable
{
    case missingField(String)
    case invalidField(String)
    case confirmationRequired
    case confirmationHashMismatch
    case pluginStorageUnavailable
    case sensitiveConfigurationRequiresSecretCommand
    case maximumEnabledSourcesReached
    case sourceUnavailable(String)
    case invalidSourceOrder
    case connectionTestFailed(code: String, message: String)

    var code: String {
        switch self {
        case .missingField: "missing_field"
        case .invalidField: "invalid_field"
        case .confirmationRequired: "confirmation_required"
        case .confirmationHashMismatch: "confirmation_hash_mismatch"
        case .pluginStorageUnavailable: "plugin_storage_unavailable"
        case .sensitiveConfigurationRequiresSecretCommand:
            "sensitive_configuration_requires_secret_command"
        case .maximumEnabledSourcesReached:
            "maximum_enabled_sources_reached"
        case .sourceUnavailable: "translation_source_unavailable"
        case .invalidSourceOrder: "invalid_source_order"
        case let .connectionTestFailed(code, _): code
        }
    }

    var errorDescription: String? {
        switch self {
        case let .missingField(field):
            "The required field \(field) is missing."
        case let .invalidField(field):
            "The field \(field) is invalid."
        case .confirmationRequired:
            "This operation requires explicit confirmation."
        case .confirmationHashMismatch:
            "The package hash does not match the reviewed hash."
        case .pluginStorageUnavailable:
            "Translation source storage is unavailable."
        case .sensitiveConfigurationRequiresSecretCommand:
            "Sensitive fields must be written with translation-source secret set --stdin."
        case .maximumEnabledSourcesReached:
            "At most four translation sources can be enabled."
        case let .sourceUnavailable(sourceID):
            "The translation source \(sourceID) is unavailable."
        case .invalidSourceOrder:
            "The order must contain every enabled translation source exactly once."
        case let .connectionTestFailed(_, message):
            message
        }
    }
}

final class TranslationSourcePackageWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.blocks.translation-source.package",
        qos: .utility
    )

    func validate(
        _ snapshot: TranslationSourcePackageSnapshot
    ) async throws -> BlocksNativePluginValidatedPackage {
        try Task.checkCancellation()
        let package = try await withCheckedThrowingContinuation {
            continuation in
            queue.async {
                do {
                    continuation.resume(
                        returning: try Self.validateSynchronously(
                            snapshot
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        return package
    }

    private static func validateSynchronously(
        _ snapshot: TranslationSourcePackageSnapshot
    ) throws -> BlocksNativePluginValidatedPackage {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "BlocksTranslationSource-\(UUID().uuidString)",
            isDirectory: true
        )
        let packageURL = root.appendingPathComponent(
            "Source.blocksplugin",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for (relativePath, data) in snapshot.files.sorted(by: {
            $0.key < $1.key
        }) {
            let destination = packageURL.appendingPathComponent(
                relativePath,
                isDirectory: false
            )
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(
                to: destination,
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }
        return try BlocksNativePluginPackageValidator().validate(
            directory: packageURL
        )
    }
}

/// Dedicated lifecycle used by `blocks plugin`. It intentionally does not
/// read or mutate translation source ordering.
@MainActor
final class PluginDevelopmentService {
    private let pluginManager: BlocksNativePluginManager
    private let runtime: BlocksPluginRuntimeCoordinator
    private let builtInCatalogLoader: () throws -> BlocksBuiltInPluginCatalog
    private let packageWorker = TranslationSourcePackageWorker()
    private var tasks: [String: Task<PluginDevelopmentActionResult, Error>] = [:]

    init(
        pluginManager: BlocksNativePluginManager,
        runtime: BlocksPluginRuntimeCoordinator,
        builtInCatalogLoader: @escaping () throws -> BlocksBuiltInPluginCatalog =
            { try BlocksBuiltInPluginCatalog.load() }
    ) {
        self.pluginManager = pluginManager
        self.runtime = runtime
        self.builtInCatalogLoader = builtInCatalogLoader
    }

    func execute(
        _ input: PluginDevelopmentActionInput,
        requestID: ActionRequestID
    ) async throws -> PluginDevelopmentActionResult {
        let key = requestID.rawValue
        let task = Task { @MainActor in
            try await executeOperation(input)
        }
        tasks[key] = task
        defer { tasks.removeValue(forKey: key) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel(_ requestID: String) -> Bool {
        guard let task = tasks[requestID] else { return false }
        task.cancel()
        pluginManager.cancelAllActiveExecutions()
        return true
    }

    private func executeOperation(
        _ input: PluginDevelopmentActionInput
    ) async throws -> PluginDevelopmentActionResult {
        try Task.checkCancellation()
        if !pluginManager.snapshotIsReady { await pluginManager.reload() }
        switch input.operation {
        case .list:
            return result(.list, plugins: pluginManager.plugins)
        case .inspect:
            let id = try required(input.pluginID, "plugin_id")
            let (_, package) = try await pluginManager.loadInstalledPackage(
                pluginID: id
            )
            return .init(
                operation: .inspect,
                plugins: summary(pluginManager.plugins.filter { $0.id == id }),
                inspection: .init(
                    manifest: package.manifest,
                    confirmation: package.installationConfirmation
                )
            )
        case .install:
            let snapshot = try required(input.package, "package")
            let reviewedHash = try required(
                input.confirmationSHA256,
                "confirmation_sha256"
            ).lowercased()
            let package = try await packageWorker.validate(snapshot)
            guard package.packageSHA256 == reviewedHash else {
                throw TranslationSourceManagementServiceError
                    .confirmationHashMismatch
            }
            let pending = try await pluginManager.prepareInstallation(
                validatedPackage: package,
                sourceDisplayName: package.manifest.displayName
            )
            let installed = try await pluginManager.confirmAndInstall(
                pendingID: pending.id
            )
            return result(.install, plugins: [installed])
        case .configure:
            let id = try required(input.pluginID, "plugin_id")
            try await pluginManager.saveConfiguration(
                try required(input.configuration, "configuration"),
                pluginID: id
            )
            return result(.configure, plugins: matching(id))
        case .setSecret:
            let id = try required(input.pluginID, "plugin_id")
            try await pluginManager.saveSecret(
                try required(input.secretValue, "secret_value"),
                pluginID: id,
                secretID: try required(input.secretID, "secret_id")
            )
            return result(.setSecret, plugins: matching(id))
        case .enable, .disable:
            let id = try required(input.pluginID, "plugin_id")
            let updated = try await pluginManager.setEnabled(
                input.operation == .enable,
                pluginID: id
            )
            return result(input.operation, plugins: [updated])
        case .invoke:
            let id = try required(input.pluginID, "plugin_id")
            let actionID = try required(input.actionID, "action_id")
            let output = try await runtime.performPluginAction(
                pluginID: id,
                actionID: actionID,
                input: input.actionInput ?? [:],
                kind: .action,
                // `--confirm` is retained by the CLI parser for compatibility,
                // but generic plugin invocation never receives destructive
                // host-action authority.
                origin: .commandLine()
            )
            return .init(
                operation: .invoke,
                invocationOutput: output.output
            )
        case .catalogList:
            let catalog = try builtInCatalogLoader()
            let installedIDs = Set(pluginManager.plugins.map(\.id))
            return .init(
                operation: .catalogList,
                catalog: catalog.document.entries.map { entry in
                    let localized = entry.localized()
                    return .init(
                        id: entry.id,
                        name: localized.name,
                        summary: localized.summary,
                        version: entry.version,
                        installed: installedIDs.contains(entry.id)
                    )
                }
            )
        case .catalogInstall:
            let id = try required(input.catalogID, "catalog_id")
            let catalog = try builtInCatalogLoader()
            guard let entry = catalog.document.entries.first(where: {
                $0.id == id
            }) else {
                throw TranslationSourceManagementServiceError
                    .sourceUnavailable(id)
            }
            let package = try await Task.detached(priority: .utility) {
                try catalog.validatedPackage(for: entry)
            }.value
            guard input.confirmed else {
                guard input.confirmationSHA256 == nil else {
                    throw TranslationSourceManagementServiceError
                        .confirmationRequired
                }
                return .init(
                    operation: .catalogInstall,
                    inspection: .init(
                        manifest: package.manifest,
                        confirmation: package.installationConfirmation
                    )
                )
            }
            let reviewedHash = try required(
                input.confirmationSHA256,
                "confirmation_sha256"
            ).lowercased()
            guard package.packageSHA256 == reviewedHash else {
                throw TranslationSourceManagementServiceError
                    .confirmationHashMismatch
            }
            let pending = try await pluginManager.prepareBuiltInInstallation(
                entryID: entry.id,
                catalog: catalog
            )
            let installed = try await pluginManager.confirmAndInstall(
                pendingID: pending.id
            )
            return result(.catalogInstall, plugins: [installed])
        case .setDebug:
            let id = try required(input.pluginID, "plugin_id")
            try await pluginManager.setDebugEnabled(
                try required(input.debugEnabled, "debug_enabled"),
                pluginID: id
            )
            return result(.setDebug, plugins: matching(id))
        case .showLogs:
            let id = try required(input.pluginID, "plugin_id")
            let limit = min(max(input.maximumLogBytes ?? 65_536, 1), 1_048_576)
            return .init(
                operation: .showLogs,
                plugins: summary(matching(id)),
                logs: try readLogs(pluginID: id, maximumBytes: limit)
            )
        case .clearLogs:
            guard input.confirmed else {
                throw TranslationSourceManagementServiceError
                    .confirmationRequired
            }
            let id = try required(input.pluginID, "plugin_id")
            try pluginManager.debugLogStore?.clear(pluginID: id)
            return result(.clearLogs, plugins: matching(id))
        case .clearSafetyDisable:
            guard input.confirmed else {
                throw TranslationSourceManagementServiceError
                    .confirmationRequired
            }
            let id = try required(input.pluginID, "plugin_id")
            try await pluginManager.clearSafetyDisable(pluginID: id)
            return result(.clearSafetyDisable, plugins: matching(id))
        case .remove:
            guard input.confirmed else {
                throw TranslationSourceManagementServiceError
                    .confirmationRequired
            }
            let id = try required(input.pluginID, "plugin_id")
            try await pluginManager.uninstall(pluginID: id)
            return result(.remove)
        }
    }

    private func matching(_ id: String) -> [BlocksNativePluginMetadata] {
        pluginManager.plugins.filter { $0.id == id }
    }

    private func result(
        _ operation: PluginDevelopmentOperation,
        plugins: [BlocksNativePluginMetadata] = []
    ) -> PluginDevelopmentActionResult {
        .init(operation: operation, plugins: summary(plugins))
    }

    private func summary(
        _ plugins: [BlocksNativePluginMetadata]
    ) -> [PluginDevelopmentSummary] {
        plugins.map {
            .init(
                id: $0.id,
                name: $0.displayName,
                version: $0.packageVersion,
                enabled: $0.isEnabled,
                safetyDisabled: $0.safetyDisabled,
                debugEnabled: $0.debugEnabled,
                installationOrigin: $0.installationOrigin.rawValue
            )
        }
    }

    private func readLogs(
        pluginID: String,
        maximumBytes: Int
    ) throws -> String {
        guard let store = pluginManager.debugLogStore else { return "" }
        var remaining = maximumBytes
        var chunks: [Data] = []
        for url in try store.logFiles(pluginID: pluginID) {
            guard remaining > 0 else { break }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            let count = min(Int(length), remaining)
            try handle.seek(toOffset: length - UInt64(count))
            chunks.append(try handle.read(upToCount: count) ?? Data())
            remaining -= count
        }
        return chunks.reversed().map { String(decoding: $0, as: UTF8.self) }
            .joined()
    }

    private func required<Value>(
        _ value: Value?,
        _ field: String
    ) throws -> Value {
        guard let value else {
            throw TranslationSourceManagementServiceError.missingField(field)
        }
        return value
    }
}
