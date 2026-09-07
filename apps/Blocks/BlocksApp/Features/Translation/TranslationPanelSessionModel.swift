import BlocksCore
import Combine
import Foundation
import OSLog

extension AppStatus {
    static var translationClipboardUnavailable: AppStatus {
        AppStatus(
            kind: .failed,
            title: L10n.string(
                "translation.clipboard.unavailable.title"
            ),
            detail: L10n.string(
                "translation.clipboard.unavailable.detail"
            )
        )
    }
}

struct TranslationFavoriteRetranslationRequest: Equatable {
    let input: TranslationInput
    let sourceLanguage: TranslationLanguageTag?
    let targetLanguage: TranslationLanguageTag

    init(favorite: TranslationFavorite) {
        input = TranslationInput(
            source: favorite.inputSource,
            text: favorite.sourceText
        )
        sourceLanguage = favorite.sourceLanguage
        targetLanguage = favorite.targetLanguage
    }
}

enum TranslationScreenshotOCRState: Equatable {
    case notApplicable
    case recognizing
    case recognized(lineCount: Int, meanConfidence: Float)
    case failed(code: String, message: String)
}

enum TranslationSelectionReadState: Equatable {
    case notApplicable
    case reading
    case selected
    case unavailable(AXSelectionReadFailureReason)
}

enum TranslationSelectionFailurePresentation {
    static func isSilentManualInput(
        _ reason: AXSelectionReadFailureReason
    ) -> Bool {
        switch reason {
        case .noFrontmostApplication,
             .blocksIsFrontmost,
             .cancelled,
             .focusedElementUnavailable,
             .selectionUnavailable,
             .emptySelection:
            true
        case .accessibilityPermissionDenied,
             .agentUnavailable,
             .agentInstallationConflict,
             .agentRequiresApproval,
             .agentVersionOutdated,
             .agentConnectionFailed,
             .targetExited,
             .timedOut,
             .selectionTooLarge,
             .passwordField:
            false
        }
    }
}

enum TranslationRunPhase: Equatable {
    case idle
    case debouncing
    case running
    case noServices
}

struct TranslationScreenshotProcessingRevision: Equatable {
    let ocr: UInt64
    let attachment: UInt64
}

enum TranslationServiceOrderPlacement: Equatable {
    case before
    case after
}

/// Observable state owned by one translation result card.
///
/// The session model keeps these objects stable for the lifetime of one
/// service result. Updating a streaming result therefore invalidates only the
/// card that observes this object, instead of publishing the complete session
/// snapshot through the panel root.
@MainActor
final class TranslationPanelResultState: ObservableObject, Identifiable {
    let id: String
    let serviceID: String

    @Published private(set) var result: TranslationResultSnapshot

    init(result: TranslationResultSnapshot) {
        id = result.id
        serviceID = result.service.id
        self.result = result
    }

    func update(_ result: TranslationResultSnapshot) {
        guard self.result != result else { return }
        self.result = result
    }
}

extension TranslationRunPhase {
    var accessibilityMessage: String? {
        switch self {
        case .idle:
            nil
        case .debouncing:
            L10n.string("translation.status.debouncing")
        case .running:
            L10n.string("translation.status.running")
        case .noServices:
            L10n.string("translation.service.noneEnabled")
        }
    }
}

extension TranslationScreenshotOCRState {
    var accessibilityMessage: String? {
        switch self {
        case .notApplicable:
            nil
        case .recognizing:
            L10n.string("translation.screenshot.recognizing")
        case let .recognized(lineCount, _):
            TranslationLocalizedFormat.ocrLines(lineCount)
        case let .failed(_, message):
            message
        }
    }
}

extension TranslationInputAnchor {
    init(screenRect: CGRect) {
        self.init(
            x: screenRect.minX,
            y: screenRect.minY,
            width: screenRect.width,
            height: screenRect.height
        )
    }
}

@MainActor
final class TranslationPanelSessionModel: ObservableObject, Identifiable {
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationFavorites"
    )
    private static let runLogger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationRun"
    )

    let id = UUID()
    let inputSource: TranslationInputSource
    @Published private(set) var inputContext: TranslationInputContext?

    @Published var sourceText: String
    @Published private(set) var sourceLanguage: TranslationLanguageTag?
    @Published private(set) var targetLanguage: TranslationLanguageTag
    @Published private(set) var usesAutomaticTarget: Bool
    @Published private(set) var resultStates:
        [TranslationPanelResultState] = []
    @Published private(set) var canFavorite = false
    @Published private(set) var isFavorite = false
    @Published private(set) var runPhase: TranslationRunPhase = .idle
    @Published var isPinned = false
    @Published var ocrState: TranslationScreenshotOCRState
    @Published private(set) var selectionReadState: TranslationSelectionReadState
    @Published private(set) var operationError: String?
    @Published private(set) var sourceFocusRequest = 0

    let appleRuntimeController: AppleTranslationRuntimeController

    private let translationStore: TranslationStore
    private let supportedLanguagesConsumerToken = UUID()
    private let runCoordinator: TranslationRunCoordinator
    private let pluginRunAuthorization: BlocksPluginAuthorizationContext
    private var autoTranslationTask: Task<Void, Never>?
    private var storeObservation: AnyCancellable?
    private var serviceOrderObservation: AnyCancellable?
    private var observedEnabledServiceIDs: Set<String> = []
    private var sourceEditRevision: UInt64 = 0
    private var screenshotOCRSourceRevision: UInt64?
    private var screenshotOCRExecutionRevision: UInt64 = 0
    private var screenshotAttachmentExecutionRevision: UInt64 = 0
    private var selectionSourceRevision: UInt64?
    private var sessionSnapshot: TranslationSessionSnapshot?
    private var sourceAttachments:
        [TranslationSourceAttachmentPayload] = []
    private var expectsScreenshotAttachment = false
    private var screenshotAttachmentFailure:
        (code: String, message: String)?
    private var sourceOCRSummary: TranslationSourceOCRSummary?
    private var dispatchPluginEvent: (@MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult)?
    private var pluginRunPreflightTask: Task<Void, Never>?
    private var pluginRunRevision: UInt64 = 0
    private var pluginResultStates: [String: TranslationResultState] = [:]
    private var pluginCompletedSessionID: String?
    private var pluginEventTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledPluginSessionID: String?
    private var favoriteOperationID: UUID?
    private var favoriteOperationTask: Task<Bool, Never>?

    init(
        input: TranslationInput,
        direction: TranslationLanguageDirection,
        translationStore: TranslationStore,
        runCoordinator: TranslationRunCoordinator? = nil,
        usesAutomaticTarget: Bool = false,
        ocrState: TranslationScreenshotOCRState? = nil,
        pluginRunAuthorization: BlocksPluginAuthorizationContext = .init(
            userInitiated: true
        )
    ) {
        inputSource = input.source
        inputContext = input.context
        sourceText = input.text
        sourceLanguage = direction.source
        targetLanguage = direction.target
        self.usesAutomaticTarget = usesAutomaticTarget
        self.translationStore = translationStore
        self.runCoordinator = runCoordinator ?? TranslationRunCoordinator()
        self.pluginRunAuthorization = pluginRunAuthorization
        appleRuntimeController = AppleTranslationRuntimeController()
        self.ocrState = ocrState
            ?? (
                input.source == .screenshotOCR
                    && input.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                    ? .recognizing
                    : .notApplicable
            )
        selectionReadState = input.source == .selection
            ? (
                input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .reading
                    : .selected
            )
            : .notApplicable
        observedEnabledServiceIDs = Set(translationStore.enabledServiceIDs)
        if self.ocrState == .recognizing {
            screenshotOCRSourceRevision = sourceEditRevision
        }
        if selectionReadState == .reading {
            selectionSourceRevision = sourceEditRevision
        }
        let configurationPublishers: [
            AnyPublisher<Void, Never>
        ] = [
            translationStore.$availableServices
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            translationStore.$supportedSourceLanguages
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            translationStore.$supportedLanguages
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
        ]
        storeObservation = Publishers.MergeMany(
            configurationPublishers
        )
        .sink { [weak self] in
            self?.objectWillChange.send()
        }
        serviceOrderObservation = translationStore.$enabledServiceIDs
            .dropFirst()
            .sink { [weak self] serviceIDs in
                guard let self else { return }
                let previousResultOrder =
                    self.resultStates.map(\.serviceID)
                let enabledServiceIDs = Set(serviceIDs)
                let removedServiceIDs = self.observedEnabledServiceIDs
                    .subtracting(enabledServiceIDs)
                self.observedEnabledServiceIDs = enabledServiceIDs
                self.runCoordinator.updateAllowedServiceIDs(serviceIDs)
                removedServiceIDs.forEach {
                    self.runCoordinator.cancel(serviceID: $0)
                }
                self.runCoordinator.reorderServices(serviceIDs)
                if previousResultOrder
                    == self.resultStates.map(\.serviceID) {
                    self.objectWillChange.send()
                }
            }
    }

    deinit {
        autoTranslationTask?.cancel()
        pluginRunPreflightTask?.cancel()
        pluginEventTasks.values.forEach { $0.cancel() }
        favoriteOperationTask?.cancel()
    }

    func configurePluginEvents(
        _ dispatcher: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult
    ) {
        dispatchPluginEvent = dispatcher
    }

    var successfulResults: [TranslationResultSnapshot] {
        snapshot?.successfulResults ?? []
    }

    /// Compatibility read model for tests and non-observing feature code.
    ///
    /// SwiftUI must observe `resultStates` at the card boundary instead of
    /// observing this aggregate snapshot. The snapshot is still kept current
    /// for favorites, output, and existing callers that synchronously inspect
    /// a session.
    var snapshot: TranslationSessionSnapshot? {
        sessionSnapshot
    }

    /// Identity for plugin events that operate on the active translation run.
    ///
    /// This remains unavailable after cancellation, closure, or before a run
    /// produces a snapshot, so callers cannot manufacture a session event.
    var currentPluginEventIdentity: (
        translationSessionID: String,
        revision: Int64
    )? {
        guard let snapshot = sessionSnapshot,
              let revision = Int64(exactly: pluginRunRevision),
              isCurrentPluginSession(snapshot.id, revision: revision) else {
            return nil
        }
        return (snapshot.id, revision)
    }

    func acceptsPluginHostAction(
        translationSessionID: String,
        expectedRevision: Int64?
    ) -> Bool {
        isCurrentPluginSession(
            translationSessionID,
            revision: expectedRevision
        )
    }

    var shouldRunOnPresentation: Bool {
        hasRunnableSourceInput && ocrState != .recognizing
    }

    var isRunning: Bool {
        runPhase == .running
    }

    var supportedLanguages: [TranslationLanguageTag] {
        translationStore.supportedLanguages
    }

    var supportedSourceLanguages: [TranslationLanguageTag] {
        translationStore.supportedSourceLanguages
    }

    func beginSupportedLanguagesConsumer() {
        translationStore.beginSupportedLanguagesConsumer(
            token: supportedLanguagesConsumerToken
        )
    }

    func endSupportedLanguagesConsumer() {
        translationStore.endSupportedLanguagesConsumer(
            token: supportedLanguagesConsumerToken
        )
    }

    var needsScreenshotAttachment: Bool {
        guard inputSource == .screenshotOCR else { return false }
        return translationStore.adaptersForEnabledServices(
            appleRuntimeController: appleRuntimeController
        ).contains {
            $0.acceptedInputs.contains(.screenshotImage)
        }
    }

    func updateSourceTextFromUser(_ text: String) {
        guard sourceText != text else { return }
        sourceEditRevision &+= 1
        sourceText = text
        scheduleAutomaticTranslation()
    }

    func updateSourceLanguage(_ language: TranslationLanguageTag?) {
        guard sourceLanguage != language else { return }
        sourceLanguage = language
        scheduleAutomaticTranslation()
    }

    func updateTargetLanguage(_ language: TranslationLanguageTag) {
        let targetChanged = targetLanguage != language
        let modeChanged = usesAutomaticTarget
        guard targetChanged || modeChanged else { return }
        usesAutomaticTarget = false
        targetLanguage = language
        TranslationLanguagePreferences.rememberFocusLanguage(language)
        scheduleAutomaticTranslation()
    }

    func enableAutomaticTarget() {
        guard !usesAutomaticTarget else { return }
        usesAutomaticTarget = true
        scheduleAutomaticTranslation()
    }

    func swapLanguagesAndRun() {
        guard let sourceLanguage else { return }
        let previousTarget = targetLanguage
        self.sourceLanguage = previousTarget
        targetLanguage = sourceLanguage
        usesAutomaticTarget = false
        TranslationLanguagePreferences.rememberFocusLanguage(sourceLanguage)
        runImmediately()
    }

    func runImmediately() {
        autoTranslationTask?.cancel()
        pluginRunPreflightTask?.cancel()
        invalidateCurrentPluginSession()
        cancelPluginEventTasks()
        cancelFavoriteOperation()
        pluginRunRevision &+= 1
        let runRevision = pluginRunRevision
        runCoordinator.cancelCurrent()
        let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableInputs = availableSourceInputs(
            normalizedText: normalized
        )
        guard !availableInputs.isEmpty else {
            runCoordinator.cancelCurrent()
            clearSnapshot()
            updateRunPhase(.idle)
            return
        }
        operationError = nil
        let resolvedDirection = TranslationTargetResolver.resolveDirection(
            text: normalized,
            explicitSource: sourceLanguage,
            explicitTarget: usesAutomaticTarget ? nil : targetLanguage,
            preferences: TranslationLanguagePreferences.snapshot()
        )
        guard let resolvedTarget = resolvedDirection.target else {
            runCoordinator.cancelCurrent()
            clearSnapshot()
            updateRunPhase(.idle)
            operationError = L10n.string(
                "translation.language.noFocusConfigured"
            )
            return
        }
        let resolvedSourceLanguage = resolvedDirection.source
        let sourceResolution = resolvedDirection.sourceResolution
        if usesAutomaticTarget {
            targetLanguage = resolvedTarget
        }
        operationError = nil
        let translationSessionUUID = UUID()
        let translationSessionID = translationSessionUUID.uuidString
        guard let dispatchPluginEvent else {
            startResolvedRun(
                translationSessionID: translationSessionID,
                normalized: normalized,
                sourceLanguage: resolvedSourceLanguage,
                targetLanguage: resolvedTarget,
                sourceResolution: sourceResolution,
                availableInputs: availableInputs
            )
            return
        }
        updateRunPhase(.running)
        let causationID = translationSessionUUID
        let resolvedEvent = BlocksPluginEventEnvelope(
            name: .translationInputResolved,
            sessionID: translationSessionID,
            revision: Int64(runRevision),
            causationID: causationID,
            source: ["input_source": .string(inputSource.rawValue)],
            payload: [
                "panel_id": .string(id.uuidString),
                "translation_session_id": .string(translationSessionID),
                "source_text": .string(normalized),
                "source_language": resolvedSourceLanguage.map {
                    .string($0.rawValue)
                } ?? .null,
                "target_language": .string(resolvedTarget.rawValue),
                "resolution": .string(sourceResolution.rawValue),
            ]
        )
        guard let preflightTask =
            TranslationApplicationOperationAdmission.gate.task({
                [weak self] in
                guard let self else { return }
                _ = await dispatchPluginEvent(resolvedEvent)
                guard !Task.isCancelled, self.pluginRunRevision == runRevision else {
                    return
                }
                let willEvent = BlocksPluginEventEnvelope(
                    name: .translationWillRunSession,
                    sessionID: translationSessionID,
                    revision: Int64(runRevision),
                    causationID: causationID,
                    source: resolvedEvent.source,
                    authorization: pluginRunAuthorization,
                    payload: resolvedEvent.payload
                )
                let result = await dispatchPluginEvent(willEvent)
                guard !Task.isCancelled, self.pluginRunRevision == runRevision else {
                    return
                }
                guard result.allowed else {
                    self.runCoordinator.cancelCurrent()
                    self.clearSnapshot()
                    self.updateRunPhase(.idle)
                    self.operationError = result.reason ?? "A plugin blocked this translation."
                    return
                }
                let text = result.envelope.payload.string("source_text")?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? normalized
                let source = result.envelope.payload.string("source_language")
                    .flatMap(TranslationLanguageTag.init(rawValue:))
                    ?? resolvedSourceLanguage
                let target = result.envelope.payload.string("target_language")
                    .flatMap(TranslationLanguageTag.init(rawValue:))
                    ?? resolvedTarget
                let inputs = self.availableSourceInputs(normalizedText: text)
                guard !inputs.isEmpty else {
                    self.runCoordinator.cancelCurrent()
                    self.clearSnapshot()
                    self.updateRunPhase(.idle)
                    return
                }
                self.startResolvedRun(
                    translationSessionID: translationSessionID,
                    normalized: text,
                    sourceLanguage: source,
                    targetLanguage: target,
                    sourceResolution: sourceResolution,
                    availableInputs: inputs
                )
        }) else {
            updateRunPhase(.idle)
            operationError = L10n.string("translation.error.generic")
            return
        }
        pluginRunPreflightTask = preflightTask
    }

    private func startResolvedRun(
        translationSessionID: String,
        normalized: String,
        sourceLanguage resolvedSourceLanguage: TranslationLanguageTag?,
        targetLanguage resolvedTarget: TranslationLanguageTag,
        sourceResolution: TranslationSourceResolution,
        availableInputs: Set<TranslationSourceAcceptedInput>
    ) {
        cancelledPluginSessionID = nil
        let input = TranslationInput(
            source: inputSource,
            text: normalized,
            context: inputContext
        )
        targetLanguage = resolvedTarget
        let adapters = translationStore.adaptersForEnabledServices(
            appleRuntimeController: appleRuntimeController
        ).filter {
            !$0.acceptedInputs.isDisjoint(with: availableInputs)
        }
        guard !adapters.isEmpty else {
            runCoordinator.cancelCurrent()
            applySnapshot(
                TranslationSessionSnapshot(
                    id: translationSessionID,
                    input: input,
                    direction: TranslationLanguageDirection(
                        source: resolvedSourceLanguage,
                        target: targetLanguage
                    ),
                    results: []
                )
            )
            updateRunPhase(.noServices)
            return
        }
        updateRunPhase(.running)
        Self.runLogger.info(
            "panel=\(self.id.uuidString, privacy: .public) phase=resolved source=\(resolvedSourceLanguage?.rawValue ?? "auto", privacy: .public) source_resolution=\(sourceResolution.rawValue, privacy: .public) target=\(self.targetLanguage.rawValue, privacy: .public) characters=\(normalized.count, privacy: .public) services=\(adapters.count, privacy: .public)"
        )
        pluginResultStates.removeAll(keepingCapacity: true)
        pluginCompletedSessionID = nil
        let initialSnapshot = runCoordinator.start(
            sessionID: translationSessionID,
            input: input,
            direction: TranslationLanguageDirection(
                source: resolvedSourceLanguage,
                target: targetLanguage
            ),
            adapters: adapters,
            context: TranslationSourceContext(
                inputSource: inputSource,
                sourceApplicationBundleID:
                    inputContext?.sourceApplicationBundleID,
                ocrSummary: sourceOCRSummary
            ),
            attachments: sourceAttachments
        ) { [weak self] snapshot in
            guard let self else { return }
            self.applySnapshot(snapshot)
        }
        if sessionSnapshot?.id != initialSnapshot.id {
            applySnapshot(initialSnapshot)
        }
        if let screenshotAttachmentFailure {
            runCoordinator.failPendingScreenshotAttachment(
                code: screenshotAttachmentFailure.code,
                message: screenshotAttachmentFailure.message
            )
        }
    }

    func scheduleAutomaticTranslation(delay: Duration = .milliseconds(450)) {
        autoTranslationTask?.cancel()
        pluginRunPreflightTask?.cancel()
        invalidateCurrentPluginSession()
        cancelPluginEventTasks()
        cancelFavoriteOperation()
        pluginRunRevision &+= 1
        runCoordinator.cancelCurrent()
        clearSnapshot()
        guard hasRunnableSourceInput else {
            updateRunPhase(.idle)
            return
        }
        guard let task = TranslationApplicationOperationAdmission.gate.task({
            [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.runImmediately()
        }) else {
            updateRunPhase(.idle)
            return
        }
        updateRunPhase(.debouncing)
        autoTranslationTask = task
    }

    @discardableResult
    func retry(serviceID: String) -> Bool {
        guard let result = sessionSnapshot?.results.first(where: {
            $0.service.id == serviceID
        }), result.state == .failed || result.state == .cancelled,
        result.isRetryable != false else {
            return false
        }
        cancelPluginEventTasks()
        cancelFavoriteOperation()
        pluginRunRevision &+= 1
        pluginCompletedSessionID = nil
        operationError = nil
        updateRunPhase(.running)
        runCoordinator.retry(serviceID: serviceID)
        return true
    }

    @discardableResult
    func cancel(serviceID: String) -> Bool {
        guard let result = sessionSnapshot?.results.first(where: {
            $0.service.id == serviceID
        }), result.state == .waiting || result.state == .running
            || result.state == .streaming else {
            return false
        }
        cancelPluginEventTasks()
        cancelFavoriteOperation()
        pluginRunRevision &+= 1
        pluginCompletedSessionID = nil
        runCoordinator.cancel(serviceID: serviceID)
        return true
    }

    func cancel() {
        autoTranslationTask?.cancel()
        pluginRunPreflightTask?.cancel()
        invalidateCurrentPluginSession()
        cancelPluginEventTasks()
        cancelFavoriteOperation()
        pluginRunRevision &+= 1
        runCoordinator.cancelCurrent()
        appleRuntimeController.cancelAll()
        sourceAttachments.removeAll()
        expectsScreenshotAttachment = false
        screenshotAttachmentFailure = nil
        screenshotOCRExecutionRevision &+= 1
        screenshotAttachmentExecutionRevision &+= 1
        sourceOCRSummary = nil
        updateRunPhase(.idle)
    }

    func moveResultService(
        serviceID: String,
        relativeTo destinationServiceID: String,
        placement: TranslationServiceOrderPlacement
    ) {
        let current = translationStore.enabledServiceIDs
        guard current.contains(serviceID),
              current.contains(destinationServiceID),
              serviceID != destinationServiceID else {
            return
        }
        let remaining = current.filter { $0 != serviceID }
        guard let destinationIndex = remaining.firstIndex(
            of: destinationServiceID
        ) else {
            return
        }
        let insertionIndex = placement == .before
            ? destinationIndex
            : destinationIndex + 1
        let beforeServiceID =
            insertionIndex < remaining.count
                ? remaining[insertionIndex]
                : nil
        translationStore.moveEnabledService(
            serviceID: serviceID,
            before: beforeServiceID
        )
        Self.runLogger.info(
            "panel=\(self.id.uuidString, privacy: .public) phase=reorder source_service=\(serviceID, privacy: .public) destination_service=\(destinationServiceID, privacy: .public) placement=\(String(describing: placement), privacy: .public)"
        )
    }

    func moveResultServiceUp(_ serviceID: String) {
        guard let index = translationStore.enabledServiceIDs.firstIndex(
            of: serviceID
        ),
        index > 0 else {
            return
        }
        translationStore.moveEnabledService(
            serviceID: serviceID,
            before: translationStore.enabledServiceIDs[index - 1]
        )
    }

    func moveResultServiceDown(_ serviceID: String) {
        guard let index = translationStore.enabledServiceIDs.firstIndex(
            of: serviceID
        ),
        index < translationStore.enabledServiceIDs.count - 1 else {
            return
        }
        let destinationIndex = index + 2
        translationStore.moveEnabledService(
            serviceID: serviceID,
            before:
                destinationIndex
                    < translationStore.enabledServiceIDs.count
                    ? translationStore.enabledServiceIDs[
                        destinationIndex
                    ]
                    : nil
        )
    }

    func beginScreenshotRetake(
        context: TranslationInputContext? = nil
    ) {
        guard inputSource == .screenshotOCR else { return }
        cancel()
        if let context {
            inputContext = context
        }
        sourceText = ""
        sourceOCRSummary = nil
        sourceEditRevision &+= 1
        screenshotOCRSourceRevision = sourceEditRevision
        clearSnapshot()
        operationError = nil
        ocrState = .recognizing
    }

    func installScreenshotAttachment(
        _ attachment: TranslationSourceAttachmentPayload,
        revision: UInt64? = nil
    ) {
        guard inputSource == .screenshotOCR,
              attachment.descriptor.kind == .screenshotImage,
              revision == nil
                || revision == screenshotAttachmentExecutionRevision else {
            return
        }
        expectsScreenshotAttachment = true
        sourceAttachments = [attachment]
        screenshotAttachmentFailure = nil
        runCoordinator.installAttachments([attachment])
    }

    func expectScreenshotAttachment() {
        guard inputSource == .screenshotOCR else { return }
        expectsScreenshotAttachment = true
        sourceAttachments.removeAll()
        screenshotAttachmentFailure = nil
    }

    func beginScreenshotProcessing(
        expectsAttachment: Bool
    ) -> TranslationScreenshotProcessingRevision {
        guard inputSource == .screenshotOCR else {
            return TranslationScreenshotProcessingRevision(
                ocr: screenshotOCRExecutionRevision,
                attachment: screenshotAttachmentExecutionRevision
            )
        }
        screenshotOCRExecutionRevision &+= 1
        screenshotAttachmentExecutionRevision &+= 1
        ocrState = .recognizing
        if expectsAttachment {
            expectScreenshotAttachment()
        } else {
            expectsScreenshotAttachment = false
            sourceAttachments.removeAll()
            screenshotAttachmentFailure = nil
        }
        return TranslationScreenshotProcessingRevision(
            ocr: screenshotOCRExecutionRevision,
            attachment: screenshotAttachmentExecutionRevision
        )
    }

    func updateOCRResult(
        text: String,
        lineCount: Int,
        meanConfidence: Float,
        revision: UInt64? = nil
    ) {
        guard revision == nil
                || revision == screenshotOCRExecutionRevision else {
            return
        }
        ocrState = .recognized(
            lineCount: lineCount,
            meanConfidence: meanConfidence
        )
        sourceOCRSummary = TranslationSourceOCRSummary(
            lineCount: lineCount
        )
        guard screenshotOCRSourceRevision == sourceEditRevision else {
            return
        }
        sourceText = text
        screenshotOCRSourceRevision = nil
        scheduleAutomaticTranslation()
    }

    func updateOCRFailure(
        code: String,
        message: String,
        revision: UInt64? = nil
    ) {
        guard revision == nil
                || revision == screenshotOCRExecutionRevision else {
            return
        }
        let ocrStillOwnsSource =
            screenshotOCRSourceRevision == sourceEditRevision
        screenshotOCRSourceRevision = nil
        sourceOCRSummary = nil
        ocrState = .failed(code: code, message: message)
        // A user may start correcting the source while OCR is still running.
        // The late OCR failure remains useful context, but it must not make an
        // already-running user translation look idle.
        if ocrStillOwnsSource {
            updateRunPhase(.idle)
            if hasRunnableSourceInput {
                runImmediately()
            }
        }
    }

    func updateScreenshotAttachmentFailure(
        code: String,
        message: String,
        revision: UInt64
    ) {
        guard inputSource == .screenshotOCR,
              revision == screenshotAttachmentExecutionRevision else {
            return
        }
        sourceAttachments.removeAll()
        screenshotAttachmentFailure = (
            code: code,
            message: message
        )
        runCoordinator.failPendingScreenshotAttachment(
            code: code,
            message: message
        )
    }

    func updateSelection(_ result: AXSelectionReadResult) {
        guard inputSource == .selection else { return }
        let mayReplaceSource =
            selectionSourceRevision == sourceEditRevision
        selectionSourceRevision = nil
        switch result {
        case let .selected(selection):
            let resolvedAnchor = selection.screenBounds.map {
                TranslationInputAnchor(screenRect: $0)
            } ?? inputContext?.anchor
            inputContext = TranslationInputContext(
                sourceApplicationBundleID: selection.target.bundleIdentifier,
                sourceApplicationName: selection.target.applicationName,
                displayIdentifier:
                    inputContext?.displayIdentifier,
                anchor: resolvedAnchor
            )
            selectionReadState = .selected
            guard mayReplaceSource else { return }
            sourceText = selection.selectedText
            runImmediately()
        case let .unavailable(failure):
            selectionReadState = .unavailable(failure.reason)
            if mayReplaceSource {
                updateRunPhase(.idle)
            }
        }
    }

    func beginCompatibilitySelection() {
        guard inputSource == .selection else { return }
        selectionSourceRevision = sourceEditRevision
        selectionReadState = .reading
        operationError = nil
    }

    func requestSourceFocus() {
        sourceFocusRequest &+= 1
    }

    @discardableResult
    func favorite() async -> Bool {
        guard canFavorite, let snapshot else { return false }
        cancelFavoriteOperation()
        guard let admissionLease =
            TranslationApplicationOperationAdmission.gate.begin() else {
            return false
        }
        let operationID = UUID()
        let revision = Int64(exactly: pluginRunRevision)
        favoriteOperationID = operationID
        let task = Task { @MainActor [weak self, admissionLease] in
            defer { admissionLease.release() }
            guard let self, let revision else { return false }
            do {
                try await self.translationStore.saveFavorite(
                    session: snapshot
                )
                try Task.checkCancellation()
                guard self.favoriteOperationID == operationID,
                      self.isCurrentPluginSession(
                          snapshot.id,
                          revision: revision
                      ) else {
                    return false
                }
                self.runCoordinator.markSessionFavorite(
                    sessionID: snapshot.id
                )
                self.operationError = nil
                self.emitPluginEvent(
                    .translationFavoriteChanged,
                    snapshot: snapshot,
                    payload: [
                        "is_favorite": .bool(true),
                        "favorite_id": .string(snapshot.id),
                        "translations": .array(
                            snapshot.successfulResults.map { result in
                                .object([
                                    "service_id": .string(
                                        result.service.id
                                    ),
                                    "service_name": .string(
                                        result.service.displayName
                                    ),
                                    "translated_text": .string(
                                        result.translatedText
                                    ),
                                ])
                            }
                        ),
                    ]
                )
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard self.favoriteOperationID == operationID else {
                    return false
                }
                Self.logger.error(
                    "Favorite save failed: \(String(describing: error), privacy: .private)"
                )
                self.operationError =
                    TranslationFavoriteErrorPresentation.userMessage
                return false
            }
        }
        favoriteOperationTask = task
        let succeeded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if favoriteOperationID == operationID {
            favoriteOperationTask = nil
            favoriteOperationID = nil
        }
        return succeeded
    }

    private func applySnapshot(
        _ snapshot: TranslationSessionSnapshot
    ) {
        var existingByServiceID:
            [String: TranslationPanelResultState] = [:]
        for state in resultStates {
            existingByServiceID[state.serviceID] = state
        }

        var pendingUpdates:
            [(TranslationPanelResultState, TranslationResultSnapshot)] = []
        let nextStates = snapshot.results.map { result in
            if let existing = existingByServiceID[result.service.id],
               existing.id == result.id {
                pendingUpdates.append((existing, result))
                return existing
            }
            return TranslationPanelResultState(result: result)
        }
        let resultOrderChanged =
            nextStates.map(\.id) != resultStates.map(\.id)

        sessionSnapshot = snapshot
        if resultOrderChanged {
            resultStates = nextStates
        }
        for (state, result) in pendingUpdates {
            state.update(result)
        }

        let hasActiveResults = snapshot.results.contains {
            $0.state == .waiting
                || $0.state == .running
                || $0.state == .streaming
        }
        updateRunPhase(hasActiveResults ? .running : .idle)

        let nextCanFavorite =
            !snapshot.successfulResults.isEmpty
            && snapshot.input.text == normalizedSourceText
            && snapshot.direction == currentDirection
        if canFavorite != nextCanFavorite {
            canFavorite = nextCanFavorite
        }
        if isFavorite != snapshot.isFavorite {
            isFavorite = snapshot.isFavorite
        }
        emitPluginResultEvents(snapshot)
    }

    private func emitPluginResultEvents(
        _ snapshot: TranslationSessionSnapshot
    ) {
        guard dispatchPluginEvent != nil else { return }
        for result in snapshot.results {
            guard pluginResultStates[result.service.id] != result.state else {
                continue
            }
            pluginResultStates[result.service.id] = result.state
            if result.state == .cancelled,
               result.errorCode
                == TranslationServiceAdapterError
                    .publicationRejected.errorCode {
                continue
            }
            let eventName: BlocksPluginEventName
            switch result.state {
            case .succeeded:
                eventName = .translationSourceResult
            case .failed:
                eventName = .translationSourceFailed
            case .waiting, .running, .streaming, .cancelled:
                eventName = .translationSourceStatus
            }
            emitPluginEvent(
                eventName,
                snapshot: snapshot,
                payload: [
                    "service_id": .string(result.service.id),
                    "state": .string(result.state.rawValue),
                    "translated_text": .string(result.translatedText),
                    "error_code": result.errorCode.map(JSONValue.string) ?? .null,
                    "retryable": result.isRetryable.map(JSONValue.bool) ?? .null,
                ]
            )
        }
        let isTerminal = !snapshot.results.isEmpty
            && snapshot.results.allSatisfy {
                $0.state == .succeeded
                    || $0.state == .failed
                    || $0.state == .cancelled
            }
        guard isTerminal, pluginCompletedSessionID != snapshot.id else {
            return
        }
        let hasSuccessfulResult = !snapshot.successfulResults.isEmpty
        let hasFailedResult = snapshot.results.contains {
            $0.state == .failed
        }
        guard hasSuccessfulResult || hasFailedResult else {
            return
        }
        pluginCompletedSessionID = snapshot.id
        emitPluginEvent(
            hasSuccessfulResult
                ? .translationSessionCompleted
                : .translationSessionFailed,
            snapshot: snapshot,
            payload: [
                "successful_service_ids": .array(
                    snapshot.successfulResults.map {
                        .string($0.service.id)
                    }
                ),
                "result_count": .int(snapshot.results.count),
            ]
        )
    }

    private func emitPluginEvent(
        _ name: BlocksPluginEventName,
        snapshot: TranslationSessionSnapshot,
        payload extraPayload: [String: JSONValue]
    ) {
        guard let dispatchPluginEvent else { return }
        let revision = Int64(exactly: pluginRunRevision)
        guard let revision,
              isCurrentPluginSession(snapshot.id, revision: revision) else {
            return
        }
        var payload = extraPayload
        payload["panel_id"] = .string(id.uuidString)
        payload["translation_session_id"] = .string(snapshot.id)
        payload["source_text"] = .string(snapshot.input.text)
        payload["source_language"] = snapshot.direction.source.map {
            .string($0.rawValue)
        } ?? .null
        payload["target_language"] = .string(
            snapshot.direction.target.rawValue
        )
        let envelope = BlocksPluginEventEnvelope(
            name: name,
            sessionID: snapshot.id,
            revision: revision,
            causationID: UUID(uuidString: snapshot.id),
            source: ["input_source": .string(inputSource.rawValue)],
            payload: payload
        )
        let eventID = UUID()
        guard let task = TranslationApplicationOperationAdmission.gate.task({
            [weak self] in
            defer {
                self?.pluginEventTasks.removeValue(forKey: eventID)
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentPluginSession(
                      snapshot.id,
                      revision: revision
                  ) else {
                return
            }
            _ = await dispatchPluginEvent(envelope)
            guard !Task.isCancelled,
                  self.isCurrentPluginSession(
                      snapshot.id,
                      revision: revision
                  ) else {
                return
            }
        }) else {
            return
        }
        pluginEventTasks[eventID] = task
    }

    private func invalidateCurrentPluginSession() {
        if let sessionID = sessionSnapshot?.id {
            cancelledPluginSessionID = sessionID
        }
    }

    private func cancelPluginEventTasks() {
        pluginEventTasks.values.forEach { $0.cancel() }
        pluginEventTasks.removeAll()
    }

    private func cancelFavoriteOperation() {
        favoriteOperationID = nil
        favoriteOperationTask?.cancel()
        favoriteOperationTask = nil
    }

    private func isCurrentPluginSession(
        _ translationSessionID: String,
        revision: Int64?
    ) -> Bool {
        guard let revision,
              revision >= 0,
              let expectedRevision = UInt64(exactly: revision),
              expectedRevision == pluginRunRevision,
              cancelledPluginSessionID != translationSessionID,
              sessionSnapshot?.id == translationSessionID else {
            return false
        }
        return true
    }

    private func clearSnapshot() {
        sessionSnapshot = nil
        if !resultStates.isEmpty {
            resultStates = []
        }
        if canFavorite {
            canFavorite = false
        }
        if isFavorite {
            isFavorite = false
        }
    }

    private func updateRunPhase(_ phase: TranslationRunPhase) {
        guard runPhase != phase else { return }
        runPhase = phase
    }

    private var normalizedSourceText: String {
        sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasRunnableSourceInput: Bool {
        !availableSourceInputs(
            normalizedText: normalizedSourceText
        ).isEmpty
    }

    private func availableSourceInputs(
        normalizedText: String
    ) -> Set<TranslationSourceAcceptedInput> {
        var inputs: Set<TranslationSourceAcceptedInput> = []
        if !normalizedText.isEmpty {
            inputs.insert(.text)
        }
        if expectsScreenshotAttachment
            || sourceAttachments.contains(where: {
                $0.descriptor.kind == .screenshotImage
            }) {
            inputs.insert(.screenshotImage)
        }
        return inputs
    }

    private var currentDirection: TranslationLanguageDirection {
        TranslationLanguageDirection(
            source:
                sourceLanguage
                ?? snapshot?.direction.source,
            target: targetLanguage
        )
    }

#if DEBUG
    var hasScreenshotAttachmentForTesting: Bool {
        sourceAttachments.contains {
            $0.descriptor.kind == .screenshotImage
        }
    }

    var screenshotProcessingRevisionForTesting:
        TranslationScreenshotProcessingRevision {
        TranslationScreenshotProcessingRevision(
            ocr: screenshotOCRExecutionRevision,
            attachment: screenshotAttachmentExecutionRevision
        )
    }
#endif
}
