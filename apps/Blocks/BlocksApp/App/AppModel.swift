import AppKit
import BlocksCore
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .screenshot
    @Published private(set) var mainWindowNavigationGeneration:
        UInt64 = 0
    @Published var status: AppStatus = .ready
    @Published private(set) var settingsAttentionRequest: SettingsAttentionRequest?
    let clipboardStore: ClipboardStore
    let providerStore: ProviderStore
    let translationStore: TranslationStore
    let translationPluginManager: BlocksNativePluginManager
    let pluginRuntimeCoordinator: BlocksPluginRuntimeCoordinator
    let translationSourceManagementService:
        TranslationSourceManagementService
    let permissionStore: PermissionStore
    let screenshotStore: ScreenshotStore
    let shortcutStore: ShortcutStore
    let privacyStore: PrivacyStore
    let featureAvailabilityStore: FeatureAvailabilityStore
    let actionBrokerManager: ActionBrokerServiceManager
    let clipboardCoordinator: ClipboardFeatureCoordinator
    let translationCoordinator: TranslationFeatureCoordinator
    let providerCoordinator: ProviderFeatureCoordinator
    let screenshotCoordinator: ScreenshotFeatureCoordinator
    let shortcutCoordinator: ShortcutFeatureCoordinator
    let permissionCoordinator: PermissionFeatureCoordinator
    /// Separate because the Direct Helper has an independent TCC identity.
    let selectionHelperSettingsController: SelectionHelperSettingsController?
    var cancellables: Set<AnyCancellable> = []
    private var mainWindowOpener: (() -> Void)?
    var translationPluginRefreshTask: Task<Void, Never>?
    var pluginLifecycleSnapshotByID:
        [String: BlocksNativePluginMetadata] = [:]
    private lazy var pluginNotificationPresenter =
        BlocksNotificationPanelPresenter()
    private let pluginColorSampler: ScreenshotColorSampleCoordinator

    deinit {
        translationPluginRefreshTask?.cancel()
    }

    init(
        clipboardStore: ClipboardStore? = nil,
        providerStore: ProviderStore? = nil,
        translationStore: TranslationStore? = nil,
        translationPluginManager: BlocksNativePluginManager? = nil,
        permissionStore: PermissionStore? = nil,
        screenshotStore: ScreenshotStore? = nil,
        shortcutStore: ShortcutStore? = nil,
        privacyStore: PrivacyStore? = nil,
        featureAvailabilityStore: FeatureAvailabilityStore? = nil,
        colorSampleCoordinator: ScreenshotColorSampleCoordinator? = nil
    ) {
        let runtimeServicesEnabled = !BlocksRuntimeEnvironment.isUnitTestHost
        if runtimeServicesEnabled {
            Step5OneShotMigration.run()
        }
        let catalog = AICapabilityCatalog.defaults()
        let resolvedProviderStore = providerStore ?? ProviderStore(catalog: catalog)
        let permissionAssistPanelPresenter = PermissionAssistPanelPresenter()
        let localVisionOCRService = LocalVisionOCRService()
        let localOCRCoordinator = LocalOCRCoordinator(service: localVisionOCRService)
        let sharedClipboardRepository = clipboardStore == nil ? AppModel.makeClipboardRepository() : nil
        let sharedClipboardOCRQueue = sharedClipboardRepository.map {
            ClipboardVisionOCRQueue(
                repository: $0,
                ocrCoordinator: localOCRCoordinator
            )
        }
        let resolvedClipboardStore = clipboardStore ?? ClipboardStore(
            repository: sharedClipboardRepository,
            ocrQueue: sharedClipboardOCRQueue
        )
        let providerAuditTokenSource =
            resolvedProviderStore.providerAuditTokenSource()
        let translationRuntimeService = OpenAITranslationRuntimeService(
            auditTokenSource: providerAuditTokenSource,
            auditHandlerWithToken: { [weak resolvedProviderStore] result, token, _, _ in
                Task { @MainActor in
                    resolvedProviderStore?.recordAcceptedTranslationRuntime(
                        result,
                        auditToken: token
                    )
                }
            }
        )
        let resolvedTranslationStore = translationStore ?? TranslationStore(
            translationRuntimeService: translationRuntimeService,
            favoriteRepository: AppModel.makeTranslationFavoriteRepository(),
            serviceProfileRepository:
                AppModel.makeTranslationServiceProfileRepository()
        )
        let resolvedTranslationPluginManager =
            translationPluginManager
            ?? AppModel.makeTranslationPluginManager()
        let resolvedPermissionStore = permissionStore ?? PermissionStore(
            assistPresenter: DefaultPermissionAssistPresenter(presenter: permissionAssistPanelPresenter)
        )
        let resolvedFeatureAvailabilityStore = featureAvailabilityStore ?? FeatureAvailabilityStore()
        let screenshotPreferencesStore = ScreenshotPreferencesStore()
        let screenshotCaptureAdapter = ScreenCaptureKitAdapter(
            preferencesStore: screenshotPreferencesStore
        )
        let screenshotCaptureArbiter = ScreenshotCaptureArbiter(
            captureService: screenshotCaptureAdapter
        )
        let translationScreenshotCaptureProvider =
            TranslationScreenshotCaptureProvider(
                captureService:
                    screenshotCaptureArbiter
                        .makeTranslationCaptureService()
            )
        let resolvedScreenshotStore = screenshotStore ?? ScreenshotStore(
            captureService: screenshotCaptureArbiter,
            preferencesStore: screenshotPreferencesStore,
            archiveWriter: sharedClipboardRepository.map { repository in
                ScreenshotClipboardArchiveCoordinator(
                    repository: repository,
                    featureAvailabilityStore: resolvedFeatureAvailabilityStore,
                    onCommitted: { [weak resolvedClipboardStore] in
                        resolvedClipboardStore?.refreshRepositoryStateAfterExternalCommit()
                    },
                    recordCommitGate: resolvedClipboardStore.recordCommitGate,
                    onCommittedDeletion: resolvedClipboardStore.committedDeletionHandler()
                )
            },
            ocrCoordinator: localOCRCoordinator,
            notificationPresenter: BlocksNotificationPanelPresenter(
                level: NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            ),
            featureEnabled: { resolvedFeatureAvailabilityStore.screenshotEnabled },
            permissionRefresher: { resolvedPermissionStore.refreshPermissionState() },
            permissionSnapshotProvider: { resolvedPermissionStore.permissionSnapshot }
        )
        let screenshotHistoryActionService = ScreenshotHistoryActionService(
            repository: sharedClipboardRepository,
            ocrQueue: sharedClipboardOCRQueue
        )
        let translationSourceManagementService =
            TranslationSourceManagementService(
                pluginManager: resolvedTranslationPluginManager,
                translationStore: resolvedTranslationStore
            )
        let resolvedPluginRuntimeCoordinator =
            BlocksPluginRuntimeCoordinator(
                manager: resolvedTranslationPluginManager
            )
        let destructiveConfirmationPresenter =
            BlocksPluginDestructiveActionConfirmationPresenter()
        AppTerminationCoordinator.shared.installDispatcher { [weak resolvedPluginRuntimeCoordinator] in
            await resolvedPluginRuntimeCoordinator?.dispatchAppWillTerminate()
        }
        AppTerminationCoordinator.shared.installFinalizer {
            [weak resolvedPluginRuntimeCoordinator] in
            resolvedPluginRuntimeCoordinator?.forceShutdownForApplicationTermination()
        }
        let pluginDevelopmentService = PluginDevelopmentService(
            pluginManager: resolvedTranslationPluginManager,
            runtime: resolvedPluginRuntimeCoordinator
        )
        let resolvedActionBrokerManager = ActionBrokerServiceManager(
            screenshotStore: resolvedScreenshotStore,
            historyService: screenshotHistoryActionService,
            translationSourceService:
                translationSourceManagementService,
            pluginDevelopmentService: pluginDevelopmentService
        )
        let resolvedShortcutStore = shortcutStore ?? ShortcutStore()
        let resolvedPrivacyStore = privacyStore ?? PrivacyStore()
        self.clipboardStore = resolvedClipboardStore
        self.providerStore = resolvedProviderStore
        self.translationStore = resolvedTranslationStore
        self.translationPluginManager = resolvedTranslationPluginManager
        self.pluginRuntimeCoordinator = resolvedPluginRuntimeCoordinator
        self.translationSourceManagementService =
            translationSourceManagementService
        self.permissionStore = resolvedPermissionStore
        self.screenshotStore = resolvedScreenshotStore
        self.shortcutStore = resolvedShortcutStore
        self.privacyStore = resolvedPrivacyStore
        self.featureAvailabilityStore = resolvedFeatureAvailabilityStore
        self.actionBrokerManager = resolvedActionBrokerManager
        self.clipboardCoordinator = ClipboardFeatureCoordinator(
            clipboardStore: resolvedClipboardStore,
            privacyStore: resolvedPrivacyStore,
            featureAvailabilityStore: resolvedFeatureAvailabilityStore
        )
        self.translationCoordinator = TranslationFeatureCoordinator(
            translationStore: resolvedTranslationStore,
            screenshotCaptureProvider:
                translationScreenshotCaptureProvider,
            localOCRCoordinator: localOCRCoordinator,
            notificationPresenter: BlocksNotificationPanelPresenter()
        )
        self.providerCoordinator = ProviderFeatureCoordinator(providerStore: resolvedProviderStore)
        self.screenshotCoordinator = ScreenshotFeatureCoordinator(store: resolvedScreenshotStore)
        self.shortcutCoordinator = ShortcutFeatureCoordinator(store: resolvedShortcutStore)
        self.permissionCoordinator = PermissionFeatureCoordinator(
            store: resolvedPermissionStore,
            assistPanelPresenter: permissionAssistPanelPresenter
        )
        resolvedPluginRuntimeCoordinator
            .configureDestructiveActionConfirmationHandler { request in
                let pluginDisplayName = resolvedTranslationPluginManager.plugins
                    .first(where: { $0.id == request.pluginID })?
                    .displayName ?? request.pluginID
                let targetDisplayName: String
                switch request.actionID {
                case "clipboard.record.delete":
                    targetDisplayName = resolvedClipboardStore
                        .resolveRecord(recordID: request.targetID)?
                        .summary ?? request.targetID
                case "clipboard.tag.delete":
                    targetDisplayName = resolvedClipboardStore.tagStore.tags
                        .first(where: { $0.id == request.targetID })?
                        .displayName ?? request.targetID
                default:
                    return false
                }
                return await destructiveConfirmationPresenter.present(
                    request,
                    pluginDisplayName: pluginDisplayName,
                    targetDisplayName: targetDisplayName
                )
            }
        self.pluginColorSampler = colorSampleCoordinator
            ?? ScreenshotColorSampleCoordinator()
        self.selectionHelperSettingsController =
            DistributionChannel.current.supportsSelectionHelper
                ? SelectionHelperSettingsController()
                : nil
        selectionHelperSettingsController?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        configureFeatureCoordinators()
        configurePluginPlatform(ocrCoordinator: localOCRCoordinator)
        bindStores(runtimeServicesEnabled: runtimeServicesEnabled)
        bindTranslationPlugins()
        clipboardCoordinator.loadRepositoryState()
        if runtimeServicesEnabled {
            if resolvedFeatureAvailabilityStore.clipboardEnabled {
                clipboardCoordinator.startLiveCapture()
            }
        }
        // The verification launcher deliberately disables live runtime services
        // so an isolated panel test cannot ingest the user's real pasteboard.
        // Opening the panel itself is safe and still exercises the production UI.
        openClipboardPanelForVerificationIfRequested()
        translationCoordinator.openPanelForVerificationIfRequested()
    }
    var clipboardTagStore: ClipboardTagStore { clipboardCoordinator.tagStore }

    private func configurePluginPlatform(ocrCoordinator: LocalOCRCoordinator) {
        let tagStore = clipboardTagStore
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.ensure"
        ) { context, input in
            guard case let .string(name)? = input["name"] else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.ensure"
                )
            }
            let normalized = try ClipboardTagNameNormalizer()
                .validateUserTagName(name)
            if let existing = tagStore.tags.first(where: {
                $0.normalizedName == normalized.normalizedName
            }) {
                return .object([
                    "tag_id": .string(existing.id),
                    "created": .bool(false),
                ])
            }
            guard let tagID = await tagStore.createFilterTag(displayName: name) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.ensure"
                )
            }
            _ = await self.pluginRuntimeCoordinator.dispatch(
                BlocksPluginEventEnvelope(
                    name: .clipboardTagChanged,
                    causationID: context.causationID,
                    payload: [
                        "operation": .string("created"),
                        "tag_id": .string(tagID),
                    ]
                )
            )
            return .object([
                "tag_id": .string(tagID),
                "created": .bool(true),
            ])
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.attach"
        ) { context, input in
            guard case let .string(recordID)? = input["record_id"],
                  case let .string(tagID)? = input["tag_id"] else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.attach"
                )
            }
            guard let expectedRevision = context.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardTagMutationError.revisionConflict
            }
            let contentRevision = try await tagStore.addTagFromPlugin(
                recordID: recordID,
                tagID: tagID,
                expectedContentRevision: expectedRevision
            )
            _ = await self.pluginRuntimeCoordinator.dispatch(
                BlocksPluginEventEnvelope(
                    name: .clipboardTagChanged,
                    causationID: context.causationID,
                    payload: [
                        "operation": .string("attached"),
                        "record_id": .string(recordID),
                        "tag_id": .string(tagID),
                        "content_revision": .int(Int(contentRevision)),
                    ]
                )
            )
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.ensure_and_attach"
        ) { context, input in
            guard case let .string(recordID)? = input["record_id"],
                  case let .string(name)? = input["name"] else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.ensure_and_attach"
                )
            }
            if let expectedRevision = context.expectedRevision {
                let normalized = try ClipboardTagNameNormalizer()
                    .validateUserTagName(name)
                guard expectedRevision > 0,
                      let existing = tagStore.tags.first(where: {
                          $0.normalizedName == normalized.normalizedName
                      }) else {
                    throw ClipboardTagMutationError.revisionConflict
                }
                let contentRevision: Int64
                contentRevision = try await tagStore.addTagFromPlugin(
                    recordID: recordID,
                    tagID: existing.id,
                    expectedContentRevision: expectedRevision
                )
                _ = await self.pluginRuntimeCoordinator.dispatch(
                    BlocksPluginEventEnvelope(
                        name: .clipboardTagChanged,
                        causationID: context.causationID,
                        payload: [
                            "operation": .string("attached"),
                            "record_id": .string(recordID),
                            "tag_id": .string(existing.id),
                            "content_revision": .int(Int(contentRevision)),
                        ]
                    )
                )
                return .object([
                    "tag_id": .string(existing.id),
                    "created": .bool(false),
                ])
            }
            let ensured = try await self.clipboardStore.ensureTagAndAttachFromPlugin(
                recordID: recordID,
                displayName: name,
                requiresPersistence: true
            )
            _ = await self.pluginRuntimeCoordinator.dispatch(
                BlocksPluginEventEnvelope(
                    name: .clipboardTagChanged,
                    causationID: context.causationID,
                    payload: [
                        "operation": .string(ensured.created ? "created_and_attached" : "attached"),
                        "record_id": .string(recordID),
                        "tag_id": .string(ensured.tagID),
                        "content_revision": .int(Int(ensured.contentRevision)),
                    ]
                )
            )
            return .object([
                "tag_id": .string(ensured.tagID),
                "created": .bool(ensured.created),
            ])
        }
        let resourceBroker = pluginRuntimeCoordinator.resources
        pluginRuntimeCoordinator.actionRegistry.register(
            "screenshot.ocr"
        ) { context, input in
            guard case let .string(resourceID)? = input["resource_id"] else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "screenshot.ocr"
                )
            }
            var data = Data()
            var offset = 0
            while true {
                let chunk = try resourceBroker.read(
                    pluginID: context.requestingPluginID,
                    id: resourceID,
                    offset: offset,
                    length: 1_048_576
                )
                guard case let .string(base64)? = chunk["data_base64"],
                      let chunkData = Data(base64Encoded: base64),
                      case let .int(nextOffset)? = chunk["next_offset"],
                      case let .bool(eof)? = chunk["eof"] else {
                    throw BlocksPluginRuntimeError.invalidHostOperation(
                        "screenshot.ocr"
                    )
                }
                data.append(chunkData)
                offset = nextOffset
                if eof { break }
            }
            let result = try await ocrCoordinator.recognizeText(
                from: data,
                context: .pluginScreenshot
            )
            return .object([
                "text": .string(result.text),
                "line_count": .int(result.lineCount),
            ])
        }
        let clipboardStore = self.clipboardStore
        let clipboardCoordinator = self.clipboardCoordinator
        let pluginRuntime = pluginRuntimeCoordinator
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.record.read"
        ) { context, input in
            guard self.translationPluginManager.plugins.first(where: {
                $0.id == context.requestingPluginID
            })?.approvedPermissions.contains("data:clipboard_content")
                == true else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "unapproved:data:clipboard_content"
                )
            }
            let recordID = try input.requiredString("record_id")
            guard let record = clipboardStore.resolveRecord(recordID: recordID) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.read"
                )
            }
            return .object([
                "record_id": .string(record.id),
                "kind": .string(record.kind.rawValue),
                "summary": .string(record.summary),
                "created_at": .double(record.createdAt.timeIntervalSince1970),
                "last_copied_at": .double(record.lastCopiedAt.timeIntervalSince1970),
                "is_favorite": .bool(tagStore.isFavorite(recordID: record.id)),
            ])
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.record.bring_to_front"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.bring_to_front.requires_user_initiated"
                )
            }
            let recordID = try input.requiredString("record_id")
            let update = await clipboardStore.commitCopyEvent(
                recordID: recordID,
                source: .plugin,
                causationID: context.causationID
            )
            guard update.recordFound, update.persisted else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.bring_to_front"
                )
            }
            return .bool(update.persisted)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.record.update"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.update.requires_user_initiated"
                )
            }
            guard self.translationPluginManager.plugins.first(where: {
                $0.id == context.requestingPluginID
            })?.approvedPermissions.contains("data:clipboard_content")
                == true else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "unapproved:data:clipboard_content"
                )
            }
            let recordID = try input.requiredString("record_id")
            let result = try await clipboardStore.updateRecordFromPlugin(
                recordID: recordID,
                customTitle: input.string("custom_title"),
                text: input.string("text"),
                expectedContentRevision: context.expectedRevision,
                causationID: context.causationID
            )
            return .object([
                "record_id": .string(recordID),
                "content_revision": .int(Int(result.newContentRevision)),
                "mutation_count": .int(result.mutationCount),
            ])
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.record.ocr"
        ) { _, input in
            let recordID = try input.requiredString("record_id")
            guard clipboardStore.resolveRecord(recordID: recordID) != nil else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.ocr"
                )
            }
            clipboardStore.retryOCR(recordID: recordID)
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.list"
        ) { _, _ in
            .array(tagStore.tags.map { tag in
                .object([
                    "tag_id": .string(tag.id),
                    "name": .string(tag.displayName),
                    "color": .string(tag.colorToken),
                    "content_revision": .int(Int(tag.contentRevision)),
                ])
            })
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.detach"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.detach.requires_user_initiated"
                )
            }
            let recordID = try input.requiredString("record_id")
            let tagID = try input.requiredString("tag_id")
            guard let expectedRevision = context.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardTagMutationError.revisionConflict
            }
            let contentRevision = try await tagStore.removeTagFromPlugin(
                recordID: recordID,
                tagID: tagID,
                expectedContentRevision: expectedRevision
            )
            _ = await pluginRuntime.dispatch(
                BlocksPluginEventEnvelope(
                    name: .clipboardTagChanged,
                    causationID: context.causationID,
                    payload: [
                        "operation": .string("detached"),
                        "record_id": .string(recordID),
                        "tag_id": .string(tagID),
                        "content_revision": .int(Int(contentRevision)),
                    ]
                )
            )
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.rename"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.rename.requires_user_initiated"
                )
            }
            let tagID = try input.requiredString("tag_id")
            let name = try input.requiredString("name")
            guard let expectedRevision = context.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardTagMutationError.revisionConflict
            }
            let contentRevision = try await tagStore.renameFilterTagFromPlugin(
                tagID: tagID,
                displayName: name,
                expectedContentRevision: expectedRevision
            )
            _ = await pluginRuntime.dispatch(
                BlocksPluginEventEnvelope(
                    name: .clipboardTagChanged,
                    causationID: context.causationID,
                    payload: [
                        "operation": .string("renamed"),
                        "tag_id": .string(tagID),
                        "content_revision": .int(Int(contentRevision)),
                    ]
                )
            )
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.tag.delete"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.delete.requires_user_initiated"
                )
            }
            guard context.destructiveActionAuthorized else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.delete.requires_destructive_confirmation"
                )
            }
            let tagID = try input.requiredString("tag_id")
            guard let expectedRevision = context.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardTagMutationError.revisionConflict
            }
            guard try await tagStore.deleteFilterTagFromPlugin(
                tagID: tagID,
                expectedContentRevision: expectedRevision
            ) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.tag.delete"
                )
            }
            _ = await pluginRuntime.dispatch(
                BlocksPluginEventEnvelope(
                    name: .clipboardTagChanged,
                    causationID: context.causationID,
                    payload: [
                        "operation": .string("deleted"),
                        "tag_id": .string(tagID),
                        "content_revision": .int(Int(expectedRevision)),
                    ]
                )
            )
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.record.favorite"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.favorite.requires_user_initiated"
                )
            }
            let recordID = try input.requiredString("record_id")
            let desired = input.bool("is_favorite") ?? true
            guard let expectedRevision = context.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardTagMutationError.revisionConflict
            }
            _ = try await clipboardStore.setFavoriteFromPlugin(
                recordID: recordID,
                isFavorite: desired,
                expectedContentRevision: expectedRevision,
                causationID: context.causationID,
                requiresPersistence: true
            )
            return .bool(desired)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.record.delete"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.delete.requires_user_initiated"
                )
            }
            guard context.destructiveActionAuthorized else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.delete.requires_destructive_confirmation"
                )
            }
            guard let expectedRevision = context.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardDetailSaveFailure.revisionConflict
            }
            let recordID = try input.requiredString("record_id")
            guard try await clipboardStore.deleteRecordFromPlugin(
                recordID: recordID,
                expectedContentRevision: expectedRevision,
                causationID: context.causationID,
                requiresPersistence: true
            ) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.record.delete"
                )
            }
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.copy_text"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.copy_text.requires_user_initiated"
                )
            }
            let text = try input.requiredString("text")
            let outcome = await clipboardCoordinator.copyExplicitText(
                text,
                source: .plugin
            )
            return .string(String(describing: outcome))
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "clipboard.paste_record"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.paste_record.requires_user_initiated"
                )
            }
            guard clipboardCoordinator.pasteRecord(
                recordID: try input.requiredString("record_id"),
                invocationOrigin: context.origin,
                pluginLifecycleToken: pluginRuntime
                    .captureHostActionLifecycleToken(),
                pluginLifecycleLeaseProvider: { [weak pluginRuntime] in
                    guard let pluginRuntime else { return nil }
                    return try? pluginRuntime.retainHostActionLifecycle(
                        pluginID: context.requestingPluginID
                    )
                },
                pluginLifecycleIsCurrent: { [weak pluginRuntime] token in
                    pluginRuntime?.isHostActionLifecycleCurrent(token) == true
                }
            ) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "clipboard.paste_record.not_accepted"
                )
            }
            return .bool(true)
        }
        let screenshotStore = self.screenshotStore
        let screenshotEditorActionIDs = [
            "screenshot.annotation.add_text",
            "screenshot.annotation.update_text",
            "screenshot.annotation.delete",
            "screenshot.watermark.apply_default",
            "screenshot.corner_radius.set",
            "screenshot.output.copy",
            "screenshot.output.save",
            "screenshot.output.pin",
            "screenshot.output.complete",
            "screenshot.output.archive",
        ]
        for actionID in screenshotEditorActionIDs {
            pluginRuntimeCoordinator.actionRegistry.register(actionID) { context, input in
                try await screenshotStore.performPluginHostAction(
                    actionID,
                    origin: context.origin,
                    input: input
                )
            }
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "screenshot.document.snapshot"
        ) { context, input in
            guard self.translationPluginManager.plugins.first(where: {
                $0.id == context.requestingPluginID
            })?.approvedPermissions.contains(
                "data:\(BlocksNativePluginDataPermission.screenshotDocument.rawValue)"
            ) == true else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "unapproved:data:screenshot_document"
                )
            }
            return try await screenshotStore.performPluginHostAction(
                "screenshot.document.snapshot",
                origin: context.origin,
                input: input
            )
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "screenshot.capture.start"
        ) { context, _ in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "screenshot.capture.start.requires_user_initiated"
                )
            }
            let result = await self.screenshotCoordinator.startSmartScreenshot()
            return .string(String(describing: result))
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            BlocksPluginHostCapabilityDescriptor(
                id: "screenshot.color_sample.begin",
                inputSchema: [
                    "operation_id": .string("string?"),
                ],
                outputSchema: [
                    "color_space": .string("sRGB"),
                    "red": .string("0...1"),
                    "green": .string("0...1"),
                    "blue": .string("0...1"),
                    "alpha": .string("0...1"),
                    "hex": .string("#RRGGBBAA"),
                    "normalized_x": .string("0...1"),
                    "normalized_y": .string("0...1"),
                ]
            )
        ) { context, _ in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "screenshot.color_sample.begin.requires_user_initiated"
                )
            }
            return try await self.pluginColorSampler.sample()
        }
        let translationCoordinator = self.translationCoordinator
        for actionID in [
            "translation.cancel",
            "translation.copy",
            "translation.favorite",
            "translation.retry",
        ] {
            pluginRuntimeCoordinator.actionRegistry.register(actionID) {
                context, input in
                try await translationCoordinator.performPluginHostAction(
                    actionID,
                    context: context,
                    input: input
                )
            }
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "translation.run"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "translation.run.requires_user_initiated"
                )
            }
            let text = try input.requiredString("text")
            let source = input.string("source_language")
                .flatMap(TranslationLanguageTag.init(rawValue:))
            let target = input.string("target_language")
                .flatMap(TranslationLanguageTag.init(rawValue:))
            guard translationCoordinator.showPluginTranslation(
                text: text,
                sourceLanguage: source,
                targetLanguage: target,
                origin: context.origin
            ) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "translation.run.invalid_input"
                )
            }
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "provider.capabilities.query"
        ) { _, _ in
            let llm = self.providerStore.llmProviderProfiles.map { profile in
                JSONValue.object([
                    "id": .string(profile.id),
                    "name": .string(profile.localizedName),
                    "domain": .string(profile.base.domain.rawValue),
                    "execution_mode": .string(profile.base.executionMode.rawValue),
                    "configured": .bool(profile.base.configured),
                    "implemented": .bool(profile.base.implemented),
                    "local_only": .bool(profile.base.localOnly),
                    "requires_external_transfer": .bool(
                        profile.base.requiresExternalTransfer
                    ),
                    "capabilities": .array(
                        profile.base.capabilityTags.map(JSONValue.string)
                    ),
                ])
            }
            let ocr = self.providerStore.ocrEngineProfiles.map { profile in
                JSONValue.object([
                    "id": .string(profile.id),
                    "name": .string(profile.localizedName),
                    "domain": .string(profile.base.domain.rawValue),
                    "execution_mode": .string(profile.base.executionMode.rawValue),
                    "configured": .bool(profile.base.configured),
                    "implemented": .bool(profile.base.implemented),
                    "local_only": .bool(profile.base.localOnly),
                    "requires_external_transfer": .bool(
                        profile.base.requiresExternalTransfer
                    ),
                    "capabilities": .array(
                        profile.base.capabilityTags.map(JSONValue.string)
                    ),
                ])
            }
            return .object([
                "llm": .array(llm),
                "ocr": .array(ocr),
                "request_operations": .array([
                    .string("connection_test"),
                ]),
            ])
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "provider.request"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "provider.request.requires_user_initiated"
                )
            }
            let operation = input.string("operation") ?? "connection_test"
            guard operation == "connection_test" else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "provider.request.operation:\(operation)"
                )
            }

            let defaults = UserDefaults.standard
            let baseURL = defaults.string(
                forKey: "provider.api.baseURL"
            ) ?? ""
            let configuredModel = defaults.string(
                forKey: "provider.api.modelName"
            ) ?? ""
            let keychainAlias = defaults.string(
                forKey: "provider.api.keychainAccountAlias"
            ) ?? ""
            let willResult = await self.pluginRuntimeCoordinator.dispatch(
                BlocksPluginEventEnvelope(
                    name: .providerWillSendRequest,
                    causationID: context.causationID,
                    authorization: .init(
                        userInitiated: context.origin.userInitiated
                    ),
                    payload: [
                        "provider": .string("openai-compatible"),
                        "model": .string(configuredModel),
                        "base_url_host": .string(
                            URL(string: baseURL)?.host ?? ""
                        ),
                        "operation": .string(operation),
                    ]
                )
            )
            guard willResult.allowed else {
                return .object([
                    "ok": .bool(false),
                    "status": .string("blocked_by_hook"),
                    "reason": .string(
                        willResult.reason ?? "Blocked by plugin."
                    ),
                ])
            }
            let resolvedModel = willResult.envelope.payload.string("model")
                ?? configuredModel
            let execution = await self.providerStore.runOpenAIConnectionTestExecution(
                baseURL: baseURL,
                modelName: resolvedModel,
                keychainAccountAlias: keychainAlias
            )
            guard case let .published(result) = execution else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "provider.request.authorization_invalidated"
                )
            }
            self.pluginRuntimeCoordinator.dispatchAsync(
                BlocksPluginEventEnvelope(
                    name: result.ok
                        ? .providerRequestCompleted
                        : .providerRequestFailed,
                    causationID: context.causationID,
                    payload: [
                        "provider": .string("openai-compatible"),
                        "model": .string(resolvedModel),
                        "operation": .string(operation),
                        "status": .string(result.status.rawValue),
                        "audit_id": .string(result.auditID),
                    ]
                )
            )
            return .object([
                "ok": .bool(result.ok),
                "status": .string(result.status.rawValue),
                "audit_id": .string(result.auditID),
                "duration_ms": .double(Double(result.durationMS)),
                "http_status": result.httpStatusCode.map {
                    .double(Double($0))
                } ?? .null,
            ])
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "system.notification"
        ) { _, input in
            let level: BlocksNotificationLevel = switch input.string("level") {
            case "success": .success
            case "warning": .warning
            case "error": .error
            default: .info
            }
            self.pluginNotificationPresenter.present(
                BlocksNotificationDescriptor(
                    level: level,
                    title: try input.requiredString("title"),
                    detail: input.string("detail"),
                    deduplicationKey: input.string("deduplication_key")
                ),
                on: NSScreen.main,
                avoiding: []
            )
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "system.open_plugin_page"
        ) { context, _ in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "system.open_plugin_page.requires_user_initiated"
                )
            }
            self.openMainWindow(section: .hooks)
            return .bool(true)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "system.schedule.set_enabled"
        ) { context, input in
            let enabled = input.bool("enabled") ?? true
            guard !enabled || context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "system.schedule.set_enabled.requires_user_initiated"
                )
            }
            let scheduleID = try input.requiredString("schedule_id")
            try await self.translationPluginManager.setScheduleEnabled(
                enabled,
                pluginID: context.requestingPluginID,
                scheduleID: scheduleID
            )
            await self.pluginRuntimeCoordinator.reloadSchedules()
            return .bool(enabled)
        }
        pluginRuntimeCoordinator.actionRegistry.register(
            "system.shortcut.execute"
        ) { context, input in
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "system.shortcut.execute.requires_user_initiated"
                )
            }
            let command = try input.requiredString("command")
            let didExecute: Bool
            switch command {
            case ShortcutCommand.screenshotSmart.rawValue:
                didExecute = await self.executeShortcutWithPluginHooks(
                    command: .screenshotSmart,
                    origin: context.origin,
                    requiresCurrentPluginLifecycle: true
                ) {
                    _ = await self.screenshotCoordinator.startSmartScreenshot()
                }
            case ShortcutCommand.clipboardHistory.rawValue:
                didExecute = await self.executeShortcutWithPluginHooks(
                    command: .clipboardHistory,
                    origin: context.origin,
                    requiresCurrentPluginLifecycle: true
                ) {
                    self.clipboardCoordinator.showHistory()
                }
            case ShortcutCommand.translationPanel.rawValue:
                didExecute = await self.executeShortcutWithPluginHooks(
                    command: .translationPanel,
                    origin: context.origin,
                    requiresCurrentPluginLifecycle: true
                ) {
                    self.translationCoordinator.showSmartSelectionPanel()
                }
            case ShortcutCommand.translationScreenshot.rawValue:
                didExecute = await self.executeShortcutWithPluginHooks(
                    command: .translationScreenshot,
                    origin: context.origin,
                    requiresCurrentPluginLifecycle: true
                ) {
                    self.translationCoordinator.showScreenshotTranslation()
                }
            default:
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "system.shortcut.execute:\(command)"
                )
            }
            guard didExecute else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "system.shortcut.execute.not_executed"
                )
            }
            return .bool(true)
        }
    }

    private func configureFeatureCoordinators() {
        let clipboardCoordinator = self.clipboardCoordinator
        let translationCoordinator = self.translationCoordinator
        let providerCoordinator = self.providerCoordinator
        let screenshotCoordinator = self.screenshotCoordinator
        let permissionCoordinator = self.permissionCoordinator
        let clipboardStore = self.clipboardStore
        let providerStore = self.providerStore
        let recordStatus: (AppStatus) -> Void = { [weak self] in self?.status = $0 }
        let selectSection: (AppSection) -> Void = { [weak self] in self?.selectedSection = $0 }
        let publishRouteResolution: (ProviderRouteResolution) -> Void = { [weak providerStore] resolution in
            providerStore?.providerRouteResolution = resolution
        }
        permissionCoordinator.configure(afterPermissionRefresh: { [weak clipboardCoordinator] in clipboardCoordinator?.pastePermissionStateDidRefresh() })
        clipboardCoordinator.configure(
            statusRecorder: recordStatus,
            sectionSelector: selectSection,
            closeTranslationPanel: { [weak translationCoordinator] in
                translationCoordinator?.closeFloatingPanel()
            },
            translateRecord: { [weak translationCoordinator] recordID in
                translationCoordinator?.showClipboardRecord(recordID: recordID)
            },
            refreshPermissionState: { [weak permissionCoordinator] in
                permissionCoordinator?.refreshPermissionState()
            },
            pluginManager: translationPluginManager,
            pluginRuntime: pluginRuntimeCoordinator,
            dispatchPluginEvent: { [weak pluginRuntimeCoordinator] envelope in
                guard let pluginRuntimeCoordinator else {
                    return .allowed(envelope)
                }
                return await pluginRuntimeCoordinator.dispatchFromFeature(
                    envelope
                )
            },
            stagePluginTextResource: { [weak pluginRuntimeCoordinator] text, kind, mediaType, metadata in
                await pluginRuntimeCoordinator?.resources.stageTextResource(
                    text,
                    kind: kind,
                    mediaType: mediaType,
                    metadata: metadata
                )
            },
            removePluginResources: { [weak pluginRuntimeCoordinator] ids in
                pluginRuntimeCoordinator?.resources.remove(ids: ids)
            },
            accessibilityGranted: { [weak permissionCoordinator] in
                permissionCoordinator?.accessibilityGranted ?? false
            },
            presentAccessibilityAssist: { [weak permissionCoordinator] onRefresh in
                permissionCoordinator?.presentAccessibilityAssist(onRefresh: onRefresh)
            }
        )
        translationCoordinator.configure(
            statusRecorder: recordStatus,
            sectionSelector: selectSection,
            closeClipboardPanel: { [weak clipboardCoordinator] completion in
                clipboardCoordinator?.closeFloatingPanel(afterClose: completion)
            },
            readClipboardText: { recordID, purpose, maximumCharacterCount in
                await clipboardStore.readTextForAction(
                    recordID: recordID,
                    purpose: purpose,
                    maximumCharacterCount: maximumCharacterCount
                )
            },
            copyText: { [weak clipboardCoordinator] text in
                guard let clipboardCoordinator else { return .failed }
                return await clipboardCoordinator.copyExplicitText(
                    text,
                    source: .translationResult
                )
            },
            openMainWindow: { [weak self] section in
                self?.openMainWindow(section: section)
            },
            pluginManager: translationPluginManager,
            pluginRuntime: pluginRuntimeCoordinator,
            dispatchPluginEvent: { [weak pluginRuntimeCoordinator] envelope in
                guard let pluginRuntimeCoordinator else {
                    return .allowed(envelope)
                }
                return await pluginRuntimeCoordinator.dispatchFromFeature(
                    envelope
                )
            }
        )
        providerCoordinator.configure(
            statusRecorder: recordStatus,
            selectedProviderSummary: {
                L10n.string("translation.service.openAICompatible")
            },
            selectedProviderRequiresExternalTransfer: {
                true
            },
            publishRouteResolution: publishRouteResolution,
            dispatchPluginEvent: { [weak pluginRuntimeCoordinator] envelope in
                guard let pluginRuntimeCoordinator else {
                    return .allowed(envelope)
                }
                return await pluginRuntimeCoordinator.dispatchFromFeature(
                    envelope
                )
            }
        )
        screenshotCoordinator.configure(
            statusRecorder: recordStatus,
            requestScreenRecordingPermissionAssist: { [weak permissionCoordinator] in
                permissionCoordinator?.requestScreenRecordingPermissionAssist()
            },
            requestInputMonitoringPermissionAssist: { [weak permissionCoordinator] in
                permissionCoordinator?.requestInputMonitoringPermissionAssist()
            },
            dispatchPluginEvent: { [weak pluginRuntimeCoordinator] envelope in
                guard let pluginRuntimeCoordinator else {
                    return .allowed(envelope)
                }
                return await pluginRuntimeCoordinator.dispatchFromFeature(
                    envelope
                )
            },
            registerPluginResource: { [weak pluginRuntimeCoordinator] data, kind, mediaType, metadata in
                pluginRuntimeCoordinator?.resources.register(
                    data: data,
                    kind: kind,
                    mediaType: mediaType,
                    metadata: metadata
                )
            },
            removePluginResources: { [weak pluginRuntimeCoordinator] ids in
                pluginRuntimeCoordinator?.resources.remove(ids: ids)
            },
            pluginManager: translationPluginManager,
            pluginRuntime: pluginRuntimeCoordinator
        )
        shortcutCoordinator.configure(
            statusRecorder: recordStatus,
            screenshotSmart: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.executeShortcutWithPluginHooks(
                        command: .screenshotSmart
                    ) { [weak self] in
                        await self?.startSmartScreenshot()
                    }
                }
            },
            clipboardHistory: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.executeShortcutWithPluginHooks(
                        command: .clipboardHistory
                    ) { [weak self] in
                        self?.showClipboardFloatingPanel()
                    }
                }
            },
            translationPanel: { [weak self] in
                Task { @MainActor [weak self, weak translationCoordinator] in
                    await self?.executeShortcutWithPluginHooks(
                        command: .translationPanel
                    ) {
                        translationCoordinator?.showSmartSelectionPanel()
                    }
                }
            },
            translationScreenshot: { [weak self] in
                Task { @MainActor [weak self, weak translationCoordinator] in
                    await self?.executeShortcutWithPluginHooks(
                        command: .translationScreenshot
                    ) {
                        translationCoordinator?.showScreenshotTranslation()
                    }
                }
            },
            clipboardQuickPaste: { [weak self] index in
                Task { @MainActor [weak self, weak clipboardCoordinator] in
                    await self?.executeShortcutWithPluginHooks(
                        commandName: "clipboardQuickPaste\(index)",
                        payload: ["index": .int(index)]
                    ) {
                        clipboardCoordinator?.pasteQuickRecord(index: index)
                    }
                }
            }
        )
    }

    @discardableResult
    func executeShortcutWithPluginHooks(
        command: ShortcutCommand,
        origin: BlocksPluginHostInvocationOrigin = .explicitUser,
        requiresCurrentPluginLifecycle: Bool = true,
        action: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await executeShortcutWithPluginHooks(
            commandName: command.rawValue,
            origin: origin,
            requiresCurrentPluginLifecycle:
                requiresCurrentPluginLifecycle,
            action: action
        )
    }

    @discardableResult
    func executeShortcutWithPluginHooks(
        commandName: String,
        payload: [String: JSONValue] = [:],
        origin: BlocksPluginHostInvocationOrigin = .explicitUser,
        requiresCurrentPluginLifecycle: Bool = true,
        action: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let causationID = UUID()
        let lifecycleToken = pluginRuntimeCoordinator
            .captureHostActionLifecycleToken()
        var eventPayload = payload
        eventPayload["command"] = .string(commandName)
        let will = BlocksPluginEventEnvelope(
            name: .automationWillExecuteShortcut,
            causationID: causationID,
            authorization: .init(userInitiated: origin.userInitiated),
            payload: eventPayload
        )
        let result = await pluginRuntimeCoordinator.dispatch(will)
        guard result.allowed else {
            status = AppStatus(
                kind: .failed,
                title: "Plugin blocked shortcut",
                detail: result.reason ?? commandName
            )
            return false
        }
        guard !requiresCurrentPluginLifecycle
                || pluginRuntimeCoordinator.isHostActionLifecycleCurrent(
                    lifecycleToken
                ) else {
            return false
        }
        await action()
        pluginRuntimeCoordinator.dispatchAsync(
            BlocksPluginEventEnvelope(
                name: .automationDidExecuteShortcut,
                causationID: causationID,
                authorization: .init(userInitiated: origin.userInitiated),
                payload: eventPayload
            )
        )
        return true
    }
    nonisolated private static func makeClipboardRepository() -> ClipboardRepository? {
        do {
            return try ClipboardRepository(database: AppDatabase.open())
        } catch {
            return nil
        }
    }

    private func openClipboardPanelForVerificationIfRequested() {
        clipboardCoordinator.openPanelForVerificationIfRequested(
            openMainWindow: openMainWindowOrDefault({}, section: .clipboardSettings),
            openSettings: { [weak self] in self?.openMainWindow(section: .clipboardSettings) }
        )
    }

    func configureMainWindowOpener(_ opener: @escaping () -> Void) { mainWindowOpener = opener }

    func openMainWindow(section: AppSection) {
        selectedSection = section
        mainWindowNavigationGeneration &+= 1
        mainWindowOpener?()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openMainWindowOrDefault(
        _ action: @escaping () -> Void,
        section: AppSection
    ) -> () -> Void {
        { [weak self] in
            guard let self else {
                return
            }
            self.selectedSection = section
            action()
            if self.mainWindowOpener != nil {
                self.mainWindowOpener?()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func markPlaceholder(_ feature: String) {
        status = AppStatus(
            kind: .placeholder,
            title: L10n.format("status.notImplemented.title", feature),
            detail: L10n.string("status.notImplemented.detail")
        )
    }

    func showSettingsSection() { selectedSection = .settings }

    func setScreenshotFeatureEnabled(_ enabled: Bool) {
        featureAvailabilityStore.setScreenshotEnabled(enabled)
    }

    func setClipboardFeatureEnabled(_ enabled: Bool) {
        featureAvailabilityStore.setClipboardEnabled(enabled)
    }

    func openScreenshotTagSettings() {
        selectedSection = .screenshot
        mainWindowOpener?()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.settingsAttentionRequest = SettingsAttentionRequest(target: .screenshotTag)
        }
    }

    func clipboardPolicySummary(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool
    ) -> String {
        clipboardCoordinator.policySummary(
            cleanupMode: cleanupMode,
            retentionPolicy: retentionPolicy,
            maxItems: maxItems,
            preserveFavorite: preserveFavorite
        )
    }

    func startClipboardLiveCapture() { clipboardCoordinator.startLiveCapture() }
    func ingestLiveClipboardCapture(_ snapshot: ClipboardLiveCaptureSnapshot) {
        clipboardCoordinator.ingestLiveCapture(snapshot)
    }
    func showClipboardHistory() { clipboardCoordinator.showHistory() }

    func showClipboardFloatingPanel(openMainWindow: @escaping () -> Void = {}) {
        clipboardCoordinator.showFloatingPanel(
            openMainWindow: openMainWindowOrDefault(openMainWindow, section: .clipboardSettings),
            openSettings: { [weak self] in self?.openMainWindow(section: .clipboardSettings) }
        )
    }

    func pasteClipboardRecord(recordID: String) {
        clipboardCoordinator.pasteRecord(recordID: recordID)
    }
    func pasteClipboardQuickRecord(index: Int) { clipboardCoordinator.pasteQuickRecord(index: index) }
    func toggleClipboardRecorderPaused() { clipboardCoordinator.toggleRecorderPaused() }
    func scheduleClipboardFilterClearAfterPanelClose() { clipboardCoordinator.scheduleFilterClearAfterPanelClose() }
    func toggleClipboardFavorite(recordID: String) { clipboardCoordinator.toggleFavorite(recordID: recordID) }
    func copyClipboardRecordAsPlainText(recordID: String) {
        clipboardCoordinator.copyRecordAsPlainText(recordID: recordID)
    }
    func copyTranslationText(
        _ text: String
    ) async -> ClipboardExplicitTextCopyOutcome {
        await clipboardCoordinator.copyExplicitText(
            text,
            source: .translationResult
        )
    }
    func clearUnfavoritedClipboardSummaries() { clipboardCoordinator.clearUnfavoritedSummaries() }
    func setClipboardTagFilter(_ tagID: String?) { clipboardCoordinator.setTagFilter(tagID) }

    func showTranslationFloatingPanel(openMainWindow: @escaping () -> Void = {}) {
        translationCoordinator.showManualPanel()
    }

    func showTranslationScreenshot() {
        translationCoordinator.showScreenshotTranslation()
    }

    func showTranslationFavorite(_ favorite: TranslationFavorite) {
        translationCoordinator.reopenFavorite(favorite)
    }

}
