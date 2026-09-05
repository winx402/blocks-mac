import AppKit
import BlocksCore
import Foundation

@MainActor
final class TranslationFeatureCoordinator:
    TranslationScreenshotWorkflowDelegate
{
    private let translationStore: TranslationStore
    let selectionReader: AXSelectionReader
    private let screenshotWorkflow:
        TranslationScreenshotWorkflowCoordinator
    let feedbackPresenter:
        TranslationFeatureFeedbackPresenter
    private let entryTelemetry = TranslationEntryTelemetry()
    let compatibilitySelectionService:
        TranslationCompatibilitySelectionService
    let compatibilitySelectionAuthorizationStore:
        TranslationCompatibilitySelectionAuthorizationStore
    let distributionChannel: DistributionChannel

    var presenters: [UUID: TranslationPanelPresenter] = [:]
    private var lastPresentedPanelID: UUID?
    var selectionTargets: [UUID: AXSelectionTarget] = [:]
    var compatibilitySelectionTasks:
        [UUID: Task<Void, Never>] = [:]
    var selectionCaptureExecution: TranslationSelectionCaptureExecution?
    var selectionInvocationID: UUID?
    private var entryInvocationID = UUID()
    private var entryDisplayIdentifier: String?
    private struct ClipboardReadExecution {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var clipboardReadExecution: ClipboardReadExecution?
    private var sectionSelector: (AppSection) -> Void = { _ in }
    private var closeClipboardPanel: (@escaping () -> Void) -> Void = { completion in completion() }
    private var readClipboardText: ((
        String,
        ClipboardPayloadReadPurpose,
        Int
    ) async -> ClipboardTextReadResult)?
    private var openMainWindow: (AppSection) -> Void = { _ in }
    private var copyText:
        @MainActor (String) async -> ClipboardExplicitTextCopyOutcome = {
            _ in .failed
        }
    private var dispatchPluginEvent: (@MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult)?
    private weak var pluginManager: BlocksNativePluginManager?
    private weak var pluginRuntime: BlocksPluginRuntimeCoordinator?

    init(
        translationStore: TranslationStore,
        selectionReader: AXSelectionReader = AXSelectionReader(),
        screenshotCaptureProvider: (any TranslationScreenshotCaptureProviding)? = nil,
        screenshotOCRProvider: (any TranslationScreenshotOCRProviding)? = nil,
        localOCRCoordinator: LocalOCRCoordinator? = nil,
        screenshotAttachmentEncoder:
            TranslationScreenshotWorkflowCoordinator.AttachmentEncoder? = nil,
        compatibilitySelectionService:
            TranslationCompatibilitySelectionService =
                TranslationCompatibilitySelectionService(),
        compatibilitySelectionAuthorizationStore:
            TranslationCompatibilitySelectionAuthorizationStore =
                TranslationCompatibilitySelectionAuthorizationStore(),
        distributionChannel: DistributionChannel = .current,
        notificationPresenter:
            (any BlocksNotificationPanelPresenting)? = nil
    ) {
        self.translationStore = translationStore
        self.selectionReader = selectionReader
        self.compatibilitySelectionService =
            compatibilitySelectionService
        self.compatibilitySelectionAuthorizationStore =
            compatibilitySelectionAuthorizationStore
        self.distributionChannel = distributionChannel
        let resolvedCaptureProvider = screenshotCaptureProvider
            ?? TranslationScreenshotCaptureProvider()
        let resolvedOCRProvider = screenshotOCRProvider
            ?? LocalVisionTranslationOCRAdapter(
                coordinator: localOCRCoordinator ?? LocalOCRCoordinator()
            )
        feedbackPresenter = TranslationFeatureFeedbackPresenter(
            notificationPresenter: notificationPresenter
        )
        screenshotWorkflow =
            TranslationScreenshotWorkflowCoordinator(
                translationStore: translationStore,
                captureProvider: resolvedCaptureProvider,
                ocrProvider: resolvedOCRProvider,
                usesExplicitOCRProvider:
                    screenshotOCRProvider != nil,
                attachmentEncoder: screenshotAttachmentEncoder
            )
        screenshotWorkflow.delegate = self
    }

    func configure(
        statusRecorder: @escaping (AppStatus) -> Void,
        sectionSelector: @escaping (AppSection) -> Void,
        closeClipboardPanel: @escaping (@escaping () -> Void) -> Void,
        readClipboardText: @escaping (
            String,
            ClipboardPayloadReadPurpose,
            Int
        ) async -> ClipboardTextReadResult,
        copyText: @escaping @MainActor (String) async
            -> ClipboardExplicitTextCopyOutcome,
        openMainWindow: @escaping (AppSection) -> Void,
        pluginManager: BlocksNativePluginManager? = nil,
        pluginRuntime: BlocksPluginRuntimeCoordinator? = nil,
        dispatchPluginEvent: (@MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult)? = nil
    ) {
        feedbackPresenter.configure(statusRecorder: statusRecorder)
        self.sectionSelector = sectionSelector
        self.closeClipboardPanel = closeClipboardPanel
        self.readClipboardText = readClipboardText
        self.copyText = copyText
        self.openMainWindow = openMainWindow
        self.pluginManager = pluginManager
        self.pluginRuntime = pluginRuntime
        self.dispatchPluginEvent = dispatchPluginEvent
    }

    func setScreenshotOCRProvider(
        _ provider: (any TranslationScreenshotOCRProviding)?
    ) {
        screenshotWorkflow.setOCRProvider(provider)
    }

    func closeFloatingPanel() {
        invalidateCurrentEntry()
        screenshotWorkflow.cancelAll()
        let active = Array(presenters.values)
        active.forEach { $0.forceClose() }
    }

    func closeUnpinnedPanels() {
        invalidateCurrentEntry()
        for presenter in Array(presenters.values)
            where !presenter.model.isPinned {
            presenter.close()
        }
    }

    func showScreenshotTranslation() {
        let entryID = beginEntry(source: .screenshotOCR)
        closeClipboardPanel { [weak self] in
            guard let self, isCurrentEntry(entryID) else { return }
            Task { @MainActor in
                await self.screenshotWorkflow.captureAndPresent {
                    self.isCurrentEntry(entryID)
                }
                if self.isCurrentEntry(entryID) {
                    self.finishEntryPresentation(
                        entryID,
                        outcome: "capture-cancelled"
                    )
                }
            }
        }
    }

    func showClipboardRecord(recordID: String) {
        let entryID = beginEntry(source: .clipboardRecord)
        let executionID = UUID()
        let task = Task { [weak self] in
            guard let self, let readClipboardText else { return }
            let textResult = await readClipboardText(
                recordID,
                .translationPreview,
                100_000
            )
            guard !Task.isCancelled,
                  isCurrentEntry(entryID),
                  clipboardReadExecution?.id == executionID else {
                return
            }
            let text = textResult.text?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !Task.isCancelled,
                  isCurrentEntry(entryID),
                  clipboardReadExecution?.id == executionID else {
                return
            }
            clipboardReadExecution = nil
            guard let text, !text.isEmpty else {
                finishEntryPresentation(
                    entryID,
                    outcome: "clipboard-unavailable"
                )
                feedbackPresenter.presentClipboardUnavailable()
                return
            }
            present(
                input: TranslationInput(
                    source: .clipboardRecord,
                    text: text,
                    context: TranslationInputContext(
                        clipboardRecordID: recordID
                    )
                ),
                entryID: entryID
            )
        }
        clipboardReadExecution = ClipboardReadExecution(
            id: executionID,
            task: task
        )
    }

    @discardableResult
    func showPluginTranslation(
        text: String,
        sourceLanguage: TranslationLanguageTag? = nil,
        targetLanguage: TranslationLanguageTag? = nil,
        origin: BlocksPluginHostInvocationOrigin
    ) -> Bool {
        guard origin.userInitiated else { return false }
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return false }
        let entryID = beginEntry(source: .manual)
        present(
            input: TranslationInput(source: .manual, text: normalized),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            entryID: entryID,
            pluginRunAuthorization: .init(
                userInitiated: origin.userInitiated
            )
        )
        return true
    }

    func reopenFavorite(_ favorite: TranslationFavorite) {
        let request = TranslationFavoriteRetranslationRequest(
            favorite: favorite
        )
        let entryID = beginEntry(source: request.input.source)
        present(
            input: request.input,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            entryID: entryID
        )
    }

    func openPanelForVerificationIfRequested() {
        guard ProcessInfo.processInfo.environment[
            "BLOCKS_OPEN_TRANSLATION_PANEL_ON_LAUNCH"
        ] == "1" else {
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.showManualPanel()
        }
    }

    func present(
        input: TranslationInput,
        sourceLanguage: TranslationLanguageTag? = nil,
        targetLanguage: TranslationLanguageTag? = nil,
        entryID: UUID,
        pluginRunAuthorization: BlocksPluginAuthorizationContext = .init(
            userInitiated: true
        ),
        shouldPresent: @escaping @MainActor () -> Bool = { true },
        onPresented: @escaping @MainActor (TranslationPanelSessionModel) -> Void = { _ in }
    ) {
        closeClipboardPanel { [weak self] in
            guard let self,
                  isCurrentEntry(entryID),
                  shouldPresent() else {
                return
            }
            let resolvedInput =
                TranslationEntryScreenContext.resolving(
                    input,
                    frozenDisplayIdentifier:
                        self.entryDisplayIdentifier
                )
            let target = targetLanguage ?? TranslationLanguagePreferences.preferredTarget()
            let model = TranslationPanelSessionModel(
                input: resolvedInput,
                direction: TranslationLanguageDirection(
                    source: sourceLanguage,
                    target: target
                ),
                translationStore: translationStore,
                usesAutomaticTarget: targetLanguage == nil,
                pluginRunAuthorization: pluginRunAuthorization
            )
            self.configurePluginEvents(for: model)
            self.replaceUnpinnedPresenterIfNeeded()
            let presenter = self.makePresenter(for: model)
            self.presenters[presenter.id] = presenter
            self.lastPresentedPanelID = presenter.id
            presenter.present()
            self.finishEntryPresentation(entryID, outcome: "presented")
            onPresented(model)
        }
    }

    private func makePresenter(
        for model: TranslationPanelSessionModel
    ) -> TranslationPanelPresenter {
        TranslationPanelPresenter(
            model: model,
            actions: TranslationPanelActions(
                copyText: { [weak self] text in
                    guard let self else { return .failed }
                    return await self.commitTranslatedText(text, model: model)
                },
                openFavorites: { [weak self] in
                    self?.openMainWindow(
                        .translationFavorites,
                        from: model.id
                    )
                },
                openTranslationSettings: { [weak self] in
                    self?.openTranslationSettings(from: model.id)
                },
                retakeScreenshot: { [weak self, weak model] in
                    guard let self, let model else { return }
                    Task { @MainActor in
                        await self.screenshotWorkflow
                            .retakeScreenshot(for: model)
                    }
                }
            ),
            pluginManager: pluginManager,
            pluginRuntime: pluginRuntime,
            onClose: { [weak self] id in
                self?.cancelSelectionCapture(panelID: id)
                self?.screenshotWorkflow.cancelRetake(modelID: model.id)
                self?.screenshotWorkflow.cancelOCR(modelID: model.id)
                self?.selectionTargets.removeValue(
                    forKey: model.id
                )
                self?.compatibilitySelectionTasks
                    .removeValue(forKey: model.id)?
                    .cancel()
                self?.presenters.removeValue(forKey: id)
                if self?.lastPresentedPanelID == id {
                    self?.lastPresentedPanelID = self?.presenters.keys.first
                }
            }
        )
    }

    private func cancelSelectionCapture(panelID: UUID) {
        guard let execution = selectionCaptureExecution,
              selectionInvocationID == execution.entryID,
              execution.panelID == panelID,
              presenters[panelID] != nil else {
            return
        }
        execution.cancel()
        selectionCaptureExecution = nil
        selectionInvocationID = nil
    }

    private func configurePluginEvents(
        for model: TranslationPanelSessionModel
    ) {
        guard let dispatchPluginEvent else { return }
        model.configurePluginEvents(dispatchPluginEvent)
    }

    func commitTranslatedText(
        _ text: String,
        model: TranslationPanelSessionModel,
        expectedTranslationSessionID: String? = nil,
        expectedRevision: Int64? = nil
    ) async -> ClipboardExplicitTextCopyOutcome {
        if let expectedTranslationSessionID,
           !model.acceptsPluginHostAction(
               translationSessionID: expectedTranslationSessionID,
               expectedRevision: expectedRevision
           ) {
            return .failed
        }
        guard let identity = model.currentPluginEventIdentity else {
            return await copyText(text)
        }
        let causationID = UUID()
        var outputText = text
        if let dispatchPluginEvent {
            let will = BlocksPluginEventEnvelope(
                name: .translationWillCommitResult,
                sessionID: identity.translationSessionID,
                revision: identity.revision,
                causationID: causationID,
                authorization: .init(userInitiated: true),
                payload: [
                    "panel_id": .string(model.id.uuidString),
                    "translation_session_id": .string(
                        identity.translationSessionID
                    ),
                    "translated_text": .string(text),
                ]
            )
            let result = await dispatchPluginEvent(will)
            guard result.allowed else { return .failed }
            outputText = result.envelope.payload
                .string("translated_text") ?? text
        }
        guard model.acceptsPluginHostAction(
            translationSessionID: identity.translationSessionID,
            expectedRevision: identity.revision
        ) else {
            return .failed
        }
        let outcome = await copyText(outputText)
        if outcome != .failed,
           model.acceptsPluginHostAction(
               translationSessionID: identity.translationSessionID,
               expectedRevision: identity.revision
           ),
           let dispatchPluginEvent {
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .translationCopyCompleted,
                    sessionID: identity.translationSessionID,
                    revision: identity.revision,
                    causationID: causationID,
                    payload: [
                        "panel_id": .string(model.id.uuidString),
                        "translation_session_id": .string(
                            identity.translationSessionID
                        ),
                        "translated_text": .string(outputText),
                        "history_recorded": .bool(
                            outcome == .copiedAndRecorded
                        ),
                    ]
                )
            )
        }
        return outcome
    }

    private func replaceUnpinnedPresenterIfNeeded() {
        for presenter in Array(presenters.values) where !presenter.model.isPinned {
            presenter.close()
        }
    }

    @discardableResult
    func beginEntry(source: TranslationInputSource) -> UUID {
        invalidateCurrentEntry()
        let id = UUID()
        entryInvocationID = id
        entryDisplayIdentifier =
            TranslationPanelScreenResolver.displayIdentifier(
                for: TranslationPanelScreenResolver.screen(
                    for: nil
                )
            )
        entryTelemetry.begin(id: id, source: source)
        replaceUnpinnedPresenterIfNeeded()
        return id
    }

    private func invalidateCurrentEntry() {
        entryTelemetry.cancel()
        entryInvocationID = UUID()
        entryDisplayIdentifier = nil
        selectionCaptureExecution?.cancel()
        selectionCaptureExecution = nil
        selectionInvocationID = nil
        compatibilitySelectionTasks.values.forEach {
            $0.cancel()
        }
        compatibilitySelectionTasks.removeAll()
        clipboardReadExecution?.task.cancel()
        clipboardReadExecution = nil
        screenshotWorkflow.cancelCapture()
    }

    func isCurrentEntry(_ id: UUID) -> Bool {
        entryInvocationID == id
    }

    private func finishEntryPresentation(
        _ id: UUID,
        outcome: String
    ) {
        entryTelemetry.finish(id: id, outcome: outcome)
    }

    func translationScreenshotWorkflowPresent(
        _ model: TranslationPanelSessionModel
    ) {
        configurePluginEvents(for: model)
        replaceUnpinnedPresenterIfNeeded()
        let presenter = makePresenter(for: model)
        presenters[presenter.id] = presenter
        presenter.present()
        finishEntryPresentation(
            entryInvocationID,
            outcome: "presented"
        )
    }

    func translationScreenshotWorkflowPresenter(
        for modelID: UUID
    ) -> TranslationPanelPresenter? {
        presenters[modelID]
    }

    func translationScreenshotWorkflowPresentFailure(
        _ status: AppStatus,
        anchor: TranslationInputAnchor?,
        deduplicationKey: String
    ) {
        finishEntryPresentation(
            entryInvocationID,
            outcome: "capture-failed"
        )
        feedbackPresenter.present(
            status,
            anchor: anchor,
            deduplicationKey: deduplicationKey
        )
    }

#if DEBUG
    var activeScreenshotOCRSessionCountForTesting: Int {
        screenshotWorkflow.activeOCRSessionCountForTesting
    }

    var activeSelectionCaptureCountForTesting: Int {
        selectionCaptureExecution == nil ? 0 : 1
    }

    var activeClipboardReadForTesting: Bool {
        clipboardReadExecution != nil
    }

    var presentedModelsForTesting: [TranslationPanelSessionModel] {
        presenters.values.map(\.model)
    }

    func startScreenshotOCRForTesting(
        capture: TranslationScreenshotCapture,
        model: TranslationPanelSessionModel
    ) {
        screenshotWorkflow.startOCR(capture: capture, model: model)
    }

    func retakeScreenshotForTesting(
        for model: TranslationPanelSessionModel
    ) async {
        await screenshotWorkflow.retakeScreenshot(for: model)
    }
#endif

    private func openTranslationSettings(from modelID: UUID) {
        openMainWindow(.translationSettings, from: modelID)
    }

    private func openMainWindow(
        _ section: AppSection,
        from modelID: UUID
    ) {
        openMainWindow(section)
        guard let presenter = presenters[modelID],
              !presenter.model.isPinned else {
            return
        }
        Task { @MainActor [weak self, weak presenter] in
            // AppModel publishes the requested route before opening the
            // singleton settings window. Let SwiftUI consume that generation
            // before removing the panel that initiated the navigation.
            await Task.yield()
            guard let self,
                  let presenter,
                  self.presenters[modelID] === presenter else {
                return
            }
            presenter.close()
        }
    }

}

enum TranslationEntryScreenContext {
    static func resolving(
        _ input: TranslationInput,
        frozenDisplayIdentifier: String?
    ) -> TranslationInput {
        guard input.context?.displayIdentifier == nil,
              let frozenDisplayIdentifier else {
            return input
        }
        let context = input.context
        return TranslationInput(
            id: input.id,
            source: input.source,
            text: input.text,
            createdAt: input.createdAt,
            context: TranslationInputContext(
                sourceApplicationBundleID:
                    context?.sourceApplicationBundleID,
                sourceApplicationName:
                    context?.sourceApplicationName,
                clipboardRecordID:
                    context?.clipboardRecordID,
                displayIdentifier:
                    frozenDisplayIdentifier,
                anchor: context?.anchor
            )
        )
    }
}
