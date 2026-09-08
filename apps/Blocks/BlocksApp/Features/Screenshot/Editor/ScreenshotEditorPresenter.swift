import AppKit
import BlocksCore
import BlocksScreenshotCore
import OSLog
import SwiftUI

@MainActor
protocol ScreenshotEditorLocalEscapeHandling: AnyObject {
    func handleEditorEscape() -> Bool
}

final class ScreenshotEditorHostPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .closable],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        minSize = .zero
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53,
           !(firstResponder is NSTextView) {
            if let localHandler = firstResponder as? ScreenshotEditorLocalEscapeHandling,
               localHandler.handleEditorEscape() {
                return
            }
            if let onEscape {
                onEscape()
                return
            }
        }
        super.sendEvent(event)
    }
}

enum ScreenshotEditorCloseDecision: Equatable {
    case complete
    case discard
    case cancel
}

struct ScreenshotEditorCloseConfirmationResult: Equatable {
    let decision: ScreenshotEditorCloseDecision
    let suppressesFutureConfirmation: Bool
}

@MainActor
final class ScreenshotEditorCloseConfirmationCoordinator {
    typealias Presenter = @MainActor (
        NSAlert,
        NSWindow,
        @escaping (NSApplication.ModalResponse) -> Void
    ) -> Void

    private let presenter: Presenter
    private var activeAlert: NSAlert?
    private(set) var isPresenting = false

    init(presenter: @escaping Presenter = { alert, window, completion in
        alert.beginSheetModal(for: window, completionHandler: completion)
    }) {
        self.presenter = presenter
    }

    @discardableResult
    func present(
        on window: NSWindow,
        completion: @escaping (ScreenshotEditorCloseConfirmationResult) -> Void
    ) -> Bool {
        guard !isPresenting else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.string("screenshot.editor.unsaved.title")
        alert.informativeText = L10n.string("screenshot.editor.unsaved.detail")
        alert.addButton(withTitle: L10n.string("screenshot.editor.done"))
        alert.addButton(withTitle: L10n.string("screenshot.editor.discard"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("screenshot.editor.unsaved.suppression")
        activeAlert = alert
        isPresenting = true
        presenter(alert, window) { [weak self] response in
            guard let self else { return }
            self.activeAlert = nil
            self.isPresenting = false
            let decision: ScreenshotEditorCloseDecision = switch response {
            case .alertFirstButtonReturn: .complete
            case .alertSecondButtonReturn: .discard
            default: .cancel
            }
            completion(ScreenshotEditorCloseConfirmationResult(
                decision: decision,
                suppressesFutureConfirmation: decision == .discard
                    && alert.suppressionButton?.state == .on
            ))
        }
        return true
    }

    func decision(on window: NSWindow) async -> ScreenshotEditorCloseConfirmationResult {
        await withCheckedContinuation { continuation in
            guard present(on: window, completion: { continuation.resume(returning: $0) }) else {
                continuation.resume(returning: ScreenshotEditorCloseConfirmationResult(
                    decision: .cancel,
                    suppressesFutureConfirmation: false
                ))
                return
            }
        }
    }
}

@MainActor
final class ScreenshotEditorSelectionHandoffCoordinator {
    private var activeTransitionID: UUID?
    private var pendingHandoff: ScreenshotSelectionSurfaceHandoff?

    func begin(
        transitionID: UUID,
        handoff: ScreenshotSelectionSurfaceHandoff?
    ) {
        cancel()
        activeTransitionID = transitionID
        pendingHandoff = handoff
    }

    func completeIfCurrent(transitionID: UUID) {
        guard activeTransitionID == transitionID else { return }
        activeTransitionID = nil
        completePendingHandoff()
    }

    func cancel() {
        activeTransitionID = nil
        completePendingHandoff()
    }

    private func completePendingHandoff() {
        pendingHandoff?.complete()
        pendingHandoff = nil
    }
}

private enum ScreenshotEditorFinalizationTaskContext {
    @TaskLocal static var sessionID: UUID?
}

@MainActor
private final class ScreenshotEditorSessionStoreReference {
    weak var store: ScreenshotEditorStore?
}

typealias ScreenshotEditorOutputCoordinatorFactory = @MainActor (
    ScreenshotPreferencesStore,
    @escaping () -> NSWindow?,
    ScreenshotOutputSerialGate
) -> ScreenshotEditorOutputCoordinator

@MainActor
final class ScreenshotEditorPresenter: NSObject, NSWindowDelegate {
    static let transitionWatchdogSeconds: TimeInterval = 1
    private static let performanceLogger = Logger(
        subsystem: "app.blocks.app",
        category: "ScreenshotPerformance"
    )
    private static let performanceSignposter = OSSignposter(
        subsystem: "app.blocks.app",
        category: "ScreenshotPerformance"
    )
    private let preferencesStore: ScreenshotPreferencesStore
    private let ocrCoordinator: LocalOCRCoordinator
    private let pinnedScreenshotManager: PinnedScreenshotManager
    private let outputSerializationGate: ScreenshotOutputSerialGate
    private let outputCoordinatorFactory: ScreenshotEditorOutputCoordinatorFactory
    private let outputImageProcessor: ScreenshotEditorOutputImageProcessor
    private var hostPanel: ScreenshotEditorHostPanel?
    private var hostPanelSessionID: UUID?
    private var store: ScreenshotEditorStore?
    private let closeConfirmationCoordinator: ScreenshotEditorCloseConfirmationCoordinator
    private var allowClose = false
    private var sessionCompletion: ((ScreenshotEditorOutcome) async -> Void)?
    private var activeSessionID: UUID?
    private var reportedFinalOutputResults: [UUID: ScreenshotFinalOutputResult] = [:]
    private var hostFinalOutputTaskID: UUID?
    private var hostFinalOutputSessionID: UUID?
    private var hostFinalOutputTask: Task<ScreenshotEditorOutputExecutionResult, Never>?
    private var finalOutputCancellationHandler: (@MainActor () -> Void)?
    private var finalOutputCancellationHandlerSessionID: UUID?
    private var finalOutputCommitStartedSessionID: UUID?
    private var editorTransitionID: UUID?
    private var editorTransitionStartedAt: CFAbsoluteTime = 0
    private var editorTransitionWatchdog: Task<Void, Never>?
    private let selectionHandoffCoordinator = ScreenshotEditorSelectionHandoffCoordinator()
    private weak var pluginManager: BlocksNativePluginManager?
    private weak var pluginRuntime: BlocksPluginRuntimeCoordinator?

    init(
        preferencesStore: ScreenshotPreferencesStore? = nil,
        ocrCoordinator: LocalOCRCoordinator = LocalOCRCoordinator(),
        pinnedScreenshotManager: PinnedScreenshotManager? = nil,
        closeConfirmationCoordinator: ScreenshotEditorCloseConfirmationCoordinator? = nil,
        outputSerializationGate: ScreenshotOutputSerialGate? = nil,
        outputCoordinatorFactory: @escaping ScreenshotEditorOutputCoordinatorFactory = {
            preferencesStore,
            presentationWindow,
            serializationGate in
            ScreenshotEditorOutputCoordinator(
                preferencesStore: preferencesStore,
                presentationWindow: presentationWindow,
                serializationGate: serializationGate
            )
        },
        outputImageProcessor: @escaping ScreenshotEditorOutputImageProcessor = {
            try ScreenshotOutputProcessor.process(
                image: $0,
                imageRect: $1,
                outputRect: $2,
                appearance: $3
            )
        }
    ) {
        self.preferencesStore = preferencesStore ?? ScreenshotPreferencesStore()
        self.ocrCoordinator = ocrCoordinator
        self.pinnedScreenshotManager = pinnedScreenshotManager ?? PinnedScreenshotManager()
        self.closeConfirmationCoordinator = closeConfirmationCoordinator
            ?? ScreenshotEditorCloseConfirmationCoordinator()
        self.outputSerializationGate = outputSerializationGate ?? ScreenshotOutputSerialGate()
        self.outputCoordinatorFactory = outputCoordinatorFactory
        self.outputImageProcessor = outputImageProcessor
    }

    var editorStoreForTesting: ScreenshotEditorStore? { store }
    var editorPanelForTesting: ScreenshotEditorHostPanel? { hostPanel }
    var activeSessionIDForTesting: UUID? { activeSessionID }
    var reportedFinalOutputResultCountForTesting: Int {
        reportedFinalOutputResults.count
    }
    var onRetakeTaskSettledForTesting: (() -> Void)?

    static func makeHostPanel(frame: CGRect) -> ScreenshotEditorHostPanel {
        ScreenshotEditorHostPanel(contentRect: frame)
    }

    func configurePluginPlatform(
        manager: BlocksNativePluginManager?,
        runtime: BlocksPluginRuntimeCoordinator?
    ) {
        pluginManager = manager
        pluginRuntime = runtime
    }

    func prepareForNewCapture() async -> Bool {
        await prepareForReplacement()
    }

    func present(
        capture: ScreenshotCapture,
        retake: @escaping () -> Void,
        completion: @escaping (ScreenshotEditorOutcome) async -> Void
    ) {
        presentSession(capture: capture, retake: retake, completion: completion)
    }

    func edit(capture: ScreenshotCapture) async -> ScreenshotEditorOutcome {
        await withCheckedContinuation { continuation in
            presentSession(
                capture: capture,
                retake: {},
                completion: { continuation.resume(returning: $0) }
            )
        }
    }

    func cancelCurrentSession() {
        guard hostPanel != nil else { return }
        // A normal request cancellation must not tear down a final output that
        // may already have crossed an irreversible sink boundary. The output
        // completion owns closing the editor once every requested sink has
        // reported its terminal state.
        guard store?.isOutputPending != true
                || finalOutputCommitStartedSessionID != activeSessionID else { return }
        invalidateCurrentFinalization()
        finishSessionWithoutWaiting(.cancelled)
        allowClose = true
        closeEditorWindow()
        allowClose = false
    }

    func performPluginHostAction(
        _ actionID: String,
        origin: BlocksPluginHostInvocationOrigin,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        guard let store else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "screenshot_editor_not_open"
            )
        }
        switch actionID {
        case "screenshot.document.snapshot":
            let data = try JSONEncoder().encode(store.pluginSceneSnapshot)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        case "screenshot.annotation.add_text":
            try requireUserInitiated(origin, actionID: actionID)
            let text = try input.requiredString("text")
            let rect = Self.pluginRect(from: input)
            guard let id = store.addPluginText(text, rect: rect) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
            }
            return .object(["element_id": .string(id.uuidString)])
        case "screenshot.annotation.update_text":
            try requireUserInitiated(origin, actionID: actionID)
            guard let id = UUID(uuidString: try input.requiredString("element_id")),
                  store.updatePluginText(id: id, text: try input.requiredString("text")) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
            }
            return .bool(true)
        case "screenshot.annotation.delete":
            try requireUserInitiated(origin, actionID: actionID)
            guard let id = UUID(uuidString: try input.requiredString("element_id")),
                  store.deletePluginElement(id: id) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
            }
            return .bool(true)
        case "screenshot.watermark.apply_default":
            try requireUserInitiated(origin, actionID: actionID)
            store.selectOrCreateWatermark()
            return .bool(true)
        case "screenshot.corner_radius.set":
            try requireUserInitiated(origin, actionID: actionID)
            let desired = input.bool("enabled") ?? true
            if store.isRoundedOutput != desired { store.toggleRoundedOutput() }
            return .bool(desired)
        case "screenshot.output.copy":
            try requireUserInitiated(origin, actionID: actionID)
            return try hostActionResult(
                actionID: actionID,
                result: await store.copyCurrentAwaitingCompletion()
            )
        case "screenshot.output.save":
            try requireUserInitiated(origin, actionID: actionID)
            return try hostActionResult(
                actionID: actionID,
                result: await store.saveCurrentAwaitingCompletion()
            )
        case "screenshot.output.pin":
            try requireUserInitiated(origin, actionID: actionID)
            return try hostActionResult(
                actionID: actionID,
                result: await pinCurrentForHostAction(store: store)
            )
        case "screenshot.output.complete", "screenshot.output.archive":
            try requireUserInitiated(origin, actionID: actionID)
            return try hostActionResult(
                actionID: actionID,
                result: await completeCurrentForHostAction(store: store)
            )
        default:
            throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
        }
    }

    private func requireUserInitiated(
        _ origin: BlocksPluginHostInvocationOrigin,
        actionID: String
    ) throws {
        guard origin.userInitiated else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "\(actionID).requires_user_initiated"
            )
        }
    }

    private func outputAdmissionOperationCode(
        _ actionID: String,
        _ admission: ScreenshotEditorOutputAdmission
    ) -> String {
        "\(actionID).\(admission.operationCode)"
    }

    private func hostActionResult(
        actionID: String,
        result: ScreenshotEditorOutputExecutionResult
    ) throws -> JSONValue {
        switch result {
        case .succeeded:
            return .bool(true)
        case .failed:
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "\(actionID).output_failed"
            )
        case .cancelled:
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "\(actionID).output_cancelled"
            )
        case let .rejected(admission):
            throw BlocksPluginRuntimeError.invalidHostOperation(
                outputAdmissionOperationCode(actionID, admission)
            )
        }
    }

    private func completeCurrentForHostAction(
        store: ScreenshotEditorStore
    ) async -> ScreenshotEditorOutputExecutionResult {
        guard let sessionID = activeSessionID else { return .cancelled }
        switch await store.prepareFinalizedImageForHostAction() {
        case let .prepared(image):
            return await runHostFinalOutput(sessionID: sessionID) { presenter in
                await presenter.completeSession(image, sessionID: sessionID, store: store)
            }
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case let .rejected(admission):
            return .rejected(admission)
        }
    }

    private func pinCurrentForHostAction(
        store: ScreenshotEditorStore
    ) async -> ScreenshotEditorOutputExecutionResult {
        guard let sessionID = activeSessionID else { return .cancelled }
        switch await store.prepareFinalizedImageForHostAction() {
        case let .prepared(image):
            let presentation = store.pinnedPresentationForHostAction(image: image)
            return await runHostFinalOutput(sessionID: sessionID) { presenter in
                await presenter.pinSession(presentation, sessionID: sessionID, store: store)
            }
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case let .rejected(admission):
            return .rejected(admission)
        }
    }

    private func runHostFinalOutput(
        sessionID: UUID,
        _ operation: @escaping @MainActor (
            ScreenshotEditorPresenter
        ) async -> ScreenshotEditorOutputExecutionResult
    ) async -> ScreenshotEditorOutputExecutionResult {
        guard activeSessionID == sessionID, hostFinalOutputTask == nil else {
            return .rejected(.busy)
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            await ScreenshotEditorFinalizationTaskContext.$sessionID.withValue(sessionID) {
                guard let self, !Task.isCancelled, self.activeSessionID == sessionID else {
                    return ScreenshotEditorOutputExecutionResult.cancelled
                }
                return await operation(self)
            }
        }
        hostFinalOutputTaskID = taskID
        hostFinalOutputSessionID = sessionID
        hostFinalOutputTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self, task] in
                guard let self,
                      self.hostFinalOutputTaskID == taskID,
                      self.hostFinalOutputSessionID == sessionID,
                      self.finalOutputCommitStartedSessionID != sessionID else { return }
                task.cancel()
                guard self.finalOutputCancellationHandlerSessionID == sessionID else {
                    return
                }
                self.finalOutputCancellationHandler?()
            }
        }
        if hostFinalOutputTaskID == taskID {
            hostFinalOutputTaskID = nil
            hostFinalOutputSessionID = nil
            hostFinalOutputTask = nil
        }
        return result
    }

    private func cancelHostFinalOutputTask() {
        guard finalOutputCommitStartedSessionID != hostFinalOutputSessionID else { return }
        hostFinalOutputTask?.cancel()
        guard finalOutputCancellationHandlerSessionID == hostFinalOutputSessionID else { return }
        finalOutputCancellationHandler?()
    }

    private func invalidateCurrentFinalization() {
        cancelHostFinalOutputTask()
        finalOutputCancellationHandler = nil
        finalOutputCancellationHandlerSessionID = nil
    }

    private func awaitHostFinalOutputTask() async {
        guard let task = hostFinalOutputTask,
              let taskID = hostFinalOutputTaskID else { return }
        _ = await task.value
        if hostFinalOutputTaskID == taskID {
            hostFinalOutputTaskID = nil
            hostFinalOutputSessionID = nil
            hostFinalOutputTask = nil
        }
    }

    func recordFinalOutputResult(_ result: ScreenshotFinalOutputResult) {
        guard let sessionID = ScreenshotEditorFinalizationTaskContext.sessionID,
              activeSessionID == sessionID else { return }
        if finalOutputCommitStartedSessionID == sessionID {
            finalOutputCommitStartedSessionID = nil
        }
        reportedFinalOutputResults[sessionID] = result
    }

    func markFinalOutputCommitStarted() {
        guard let sessionID = ScreenshotEditorFinalizationTaskContext.sessionID,
              activeSessionID == sessionID else { return }
        finalOutputCommitStartedSessionID = sessionID
    }

    func setFinalOutputCancellationHandler(_ handler: (@MainActor () -> Void)?) {
        let sessionID = ScreenshotEditorFinalizationTaskContext.sessionID
        guard let sessionID, activeSessionID == sessionID else { return }
        finalOutputCancellationHandler = handler
        finalOutputCancellationHandlerSessionID = handler == nil ? nil : sessionID
    }

    private func resolvedFinalOutputExecutionResult(sessionID: UUID)
        -> ScreenshotEditorOutputExecutionResult
    {
        guard let result = reportedFinalOutputResults[sessionID] else { return .failed }
        if result.isCancelled { return .cancelled }
        return result.pasteboard == .failed || result.archive == .failed
            ? .failed
            : .succeeded
    }

    private func hasCommittedFinalOutputResult(sessionID: UUID) -> Bool {
        reportedFinalOutputResults[sessionID]?.hasCommittedSink == true
    }

    private static func pluginRect(from input: [String: JSONValue]) -> CGRect? {
        guard let x = input.double("x"),
              let y = input.double("y"),
              let width = input.double("width"),
              let height = input.double("height"),
              width > 0,
              height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func presentSession(
        capture: ScreenshotCapture,
        retake: @escaping () -> Void,
        completion: ((ScreenshotEditorOutcome) async -> Void)?
    ) {
        invalidateCurrentFinalization()
        let sessionID = UUID()
        activeSessionID = sessionID
        finalOutputCommitStartedSessionID = nil
        reportedFinalOutputResults[sessionID] = nil
        sessionCompletion = completion

        do {
            let sessionStoreReference = ScreenshotEditorSessionStoreReference()
            let presentationWindow: () -> NSWindow? = {
                [weak self, sessionStoreReference] in
                guard let self,
                      let store = sessionStoreReference.store,
                      self.isActiveEditorSession(
                          sessionID: sessionID,
                          store: store
                      ) else { return nil }
                return self.hostPanel
            }
            let outputCoordinator = outputCoordinatorFactory(
                preferencesStore,
                presentationWindow,
                outputSerializationGate
            )
            let store = try ScreenshotEditorStore(
                capture: capture,
                preferencesStore: preferencesStore,
                onComplete: { [weak self] image in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeSessionID == sessionID,
                              let store = self.store else { return }
                        _ = await self.runHostFinalOutput(sessionID: sessionID) { presenter in
                            await presenter.completeSession(
                                image,
                                sessionID: sessionID,
                                store: store
                            )
                        }
                    }
                },
                onPinned: { [weak self] presentation in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeSessionID == sessionID,
                              let store = self.store else { return }
                        _ = await self.runHostFinalOutput(sessionID: sessionID) { presenter in
                            await presenter.pinSession(
                                presentation,
                                sessionID: sessionID,
                                store: store
                            )
                        }
                    }
                },
                onSaved: { [weak self] image in
                    Task { @MainActor [weak self, sessionStoreReference] in
                        guard let store = sessionStoreReference.store else { return }
                        await self?.saveSession(
                            image,
                            sessionID: sessionID,
                            store: store
                        )
                    }
                },
                onRetake: { [weak self, sessionStoreReference] in
                    Task { @MainActor [weak self, sessionStoreReference] in
                        defer { self?.onRetakeTaskSettledForTesting?() }
                        guard let store = sessionStoreReference.store else { return }
                        await self?.requestRetake(
                            retake,
                            sessionID: sessionID,
                            store: store
                        )
                    }
                },
                onClose: { [weak self, sessionStoreReference] in
                    guard let self,
                          let store = sessionStoreReference.store,
                          self.isActiveEditorSession(
                              sessionID: sessionID,
                              store: store,
                              requiresCompletion: false
                          ) else { return }
                    self.allowClose = true
                    self.closeEditorWindow()
                    self.allowClose = false
                },
                onRequestClose: { [weak self, sessionStoreReference] in
                    guard let self,
                          let store = sessionStoreReference.store,
                          self.isActiveEditorSession(
                              sessionID: sessionID,
                              store: store
                          ) else { return }
                    self.requestClose(sessionID: sessionID, store: store)
                },
                presentationWindow: presentationWindow,
                outputCoordinator: outputCoordinator,
                outputSerializationGate: outputSerializationGate,
                outputImageProcessor: outputImageProcessor,
                ocrCoordinator: ocrCoordinator,
                onElementCommitted: { [weak self] element in
                    self?.dispatchElementCommitted(element)
                },
                onOCRCompleted: { [weak self] requestID, region, revision, text in
                    self?.dispatchOCRCompleted(
                        requestID: requestID,
                        region: region,
                        revision: revision,
                        text: text
                    )
                }
            )
            sessionStoreReference.store = store
            self.store = store
            guard let initialFrame = capture.editingContext?.sourceFrame else {
                throw ScreenshotEditorError.editingContextUnavailable
            }
            let canvasPresentation = ScreenshotEditorCanvasPresentation.resolve(
                sourceFrame: initialFrame,
                captureFrame: capture.sourceRect,
                displayFrames: capture.editingContext?.screens.map(\.frame) ?? [],
                isLongImage: store.prefersLongImageViewport
            )
            // The image still occupies the full display. Only chrome avoids a
            // physical notch; do not subtract menu-bar/Dock bands from pixels.
            let screenInsets = NSScreen.screens.first(where: { $0.frame == initialFrame })?.safeAreaInsets
            let chromeSafeAreaInsets = EdgeInsets(
                top: screenInsets?.top ?? 0, leading: screenInsets?.left ?? 0,
                bottom: screenInsets?.bottom ?? 0, trailing: screenInsets?.right ?? 0
            )
            let panel = Self.makeHostPanel(frame: initialFrame)
            panel.onEscape = store.handleEscape
            panel.delegate = self
            panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.alphaValue = 0
            let transitionID = UUID()
            let captureID = capture.id
            let captureMode = String(describing: capture.kind)
            let displayCount = capture.editingContext?.screens.count ?? 0
            editorTransitionID = transitionID
            editorTransitionStartedAt = CFAbsoluteTimeGetCurrent()
            selectionHandoffCoordinator.begin(
                transitionID: transitionID,
                handoff: capture.selectionSurfaceHandoff
            )
            panel.contentView = NSHostingView(
                rootView: ScreenshotEditorHostView(
                    store: store,
                    pluginManager: pluginManager,
                    pluginRuntime: pluginRuntime,
                    canvasPresentation: canvasPresentation,
                    chromeSafeAreaInsets: chromeSafeAreaInsets,
                    onFirstFrameRendered: { [weak self] in
                        self?.editorCanvasDidDraw(
                            transitionID: transitionID,
                            captureID: captureID,
                            captureMode: captureMode,
                            displayCount: displayCount
                        )
                    }
                ).blocksDefaultFont()
            )
            hostPanel = panel
            hostPanelSessionID = sessionID
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            startTransitionWatchdog(
                transitionID: transitionID,
                captureID: captureID
            )
        } catch {
            capture.selectionSurfaceHandoff?.complete()
            presentNonblockingError(error)
            finishSessionWithoutWaiting(.failed(error.localizedDescription))
        }
    }

    private func dispatchElementCommitted(_ element: ScreenshotElement) {
        pluginRuntime?.dispatchAsync(BlocksPluginEventEnvelope(
            name: .screenshotElementCommitted,
            payload: [
                "element_id": .string(element.id.uuidString),
                "element_kind": .string(element.kind.rawValue)
            ]
        ))
    }

    private func dispatchOCRCompleted(
        requestID: UUID,
        region: ScreenshotPixelRect,
        revision: UInt64,
        text: String
    ) {
        pluginRuntime?.dispatchAsync(BlocksPluginEventEnvelope(
            name: .screenshotOCRCompleted,
            requestID: requestID.uuidString,
            revision: Int64(clamping: revision),
            payload: [
                "region": .object([
                    "x": .int(region.x),
                    "y": .int(region.y),
                    "width": .int(region.width),
                    "height": .int(region.height)
                ]),
                "ocr_text": .string(text)
            ]
        ))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === hostPanel else { return true }
        guard store?.isOutputPending != true else { return false }
        if !allowClose, store?.isDirty == true {
            requestClose()
            return false
        }
        cancelEditorTransition()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === hostPanel else { return }
        cancelEditorTransition()
        store?.shutdown()
        finishSessionWithoutWaiting(.cancelled)
        hostPanel = nil
        hostPanelSessionID = nil
        store = nil
        allowClose = false
    }

    private func editorCanvasDidDraw(
        transitionID: UUID,
        captureID: String,
        captureMode: String,
        displayCount: Int
    ) {
        guard editorTransitionID == transitionID else { return }
        let elapsedMS = Int(
            (CFAbsoluteTimeGetCurrent() - editorTransitionStartedAt) * 1_000
        )
        Self.performanceLogger.info(
            "stage=editor-canvas-drawn captureID=\(captureID, privacy: .public) mode=\(captureMode, privacy: .public) displayCount=\(displayCount, privacy: .public) elapsedMS=\(elapsedMS, privacy: .public)"
        )
        Self.performanceSignposter.emitEvent(
            "EditorCanvasDrawn",
            "captureID=\(captureID, privacy: .public)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.commitEditorTransition(
                transitionID: transitionID,
                captureID: captureID,
                captureMode: captureMode,
                displayCount: displayCount
            )
        }
    }

    private func commitEditorTransition(
        transitionID: UUID,
        captureID: String,
        captureMode: String,
        displayCount: Int
    ) {
        guard editorTransitionID == transitionID,
              let panel = hostPanel else { return }
        editorTransitionID = nil
        editorTransitionWatchdog?.cancel()
        editorTransitionWatchdog = nil
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        if let firstResponder = panel.initialFirstResponder {
            panel.makeFirstResponder(firstResponder)
        }
        BlocksAppKitMotion.animate(
            window: panel,
            to: panel.frame,
            alphaValue: 1,
            role: .confirmation
        ) {
            self.selectionHandoffCoordinator.completeIfCurrent(
                transitionID: transitionID
            )
        }
        let elapsedMS = Int(
            (CFAbsoluteTimeGetCurrent() - editorTransitionStartedAt) * 1_000
        )
        Self.performanceLogger.info(
            "stage=transition-committed captureID=\(captureID, privacy: .public) mode=\(captureMode, privacy: .public) displayCount=\(displayCount, privacy: .public) elapsedMS=\(elapsedMS, privacy: .public)"
        )
        Self.performanceSignposter.emitEvent(
            "TransitionCommitted",
            "captureID=\(captureID, privacy: .public)"
        )
        Self.performanceSignposter.emitEvent(
            "EditorFirstFrame",
            "captureID=\(captureID, privacy: .public)"
        )
    }

    private func startTransitionWatchdog(
        transitionID: UUID,
        captureID: String
    ) {
        editorTransitionWatchdog?.cancel()
        editorTransitionWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.transitionWatchdogSeconds)
            )
            guard !Task.isCancelled,
                  let self,
                  self.editorTransitionID == transitionID else { return }
            self.editorTransitionID = nil
            self.editorTransitionWatchdog = nil
            self.selectionHandoffCoordinator.cancel()
            Self.performanceLogger.error(
                "stage=transition-timeout captureID=\(captureID, privacy: .public) elapsedMS=1000"
            )
            let error = ScreenshotCaptureError.captureFailed(
                L10n.string("status.failed.detail")
            )
            self.finishSessionWithoutWaiting(
                .failed(error.localizedDescription)
            )
            self.allowClose = true
            self.closeEditorWindow()
            self.allowClose = false
            self.presentNonblockingError(error)
        }
    }

    private func finishSession(
        _ outcome: ScreenshotEditorOutcome,
        sessionID: UUID
    ) async {
        guard activeSessionID == sessionID else { return }
        let completion = sessionCompletion
        sessionCompletion = nil
        await completion?(outcome)
    }

    private func finishSessionWithoutWaiting(_ outcome: ScreenshotEditorOutcome) {
        invalidateCurrentFinalization()
        if let activeSessionID {
            reportedFinalOutputResults[activeSessionID] = nil
        }
        activeSessionID = nil
        let completion = sessionCompletion
        sessionCompletion = nil
        guard let completion else { return }
        Task { @MainActor in
            await completion(outcome)
        }
    }

    @discardableResult
    private func completeSession(
        _ image: NSImage,
        sessionID: UUID,
        store: ScreenshotEditorStore
    ) async -> ScreenshotEditorOutputExecutionResult {
        guard activeSessionID == sessionID, self.store === store,
              sessionCompletion != nil else {
            return .cancelled
        }
        reportedFinalOutputResults[sessionID] = nil
        store.setFinalizingOutput(true)
        await finishSession(.completed(image), sessionID: sessionID)
        guard !Task.isCancelled || hasCommittedFinalOutputResult(sessionID: sessionID) else {
            reportedFinalOutputResults[sessionID] = nil
            if self.store === store {
                store.setFinalizingOutput(false)
            }
            return .cancelled
        }
        let executionResult = resolvedFinalOutputExecutionResult(sessionID: sessionID)
        guard activeSessionID == sessionID, self.store === store else {
            return executionResult
        }
        reportedFinalOutputResults[sessionID] = nil
        store.setFinalizingOutput(false)
        allowClose = true
        closeEditorWindow()
        allowClose = false
        return executionResult
    }

    @discardableResult
    private func pinSession(
        _ presentation: PinnedScreenshotPresentation,
        sessionID: UUID,
        store: ScreenshotEditorStore
    ) async -> ScreenshotEditorOutputExecutionResult {
        guard activeSessionID == sessionID, self.store === store,
              sessionCompletion != nil else { return .cancelled }
        reportedFinalOutputResults[sessionID] = nil
        pinnedScreenshotManager.present(presentation, ocrCoordinator: ocrCoordinator)
        store.setFinalizingOutput(true)
        await finishSession(.pinned(presentation.image), sessionID: sessionID)
        guard !Task.isCancelled || hasCommittedFinalOutputResult(sessionID: sessionID) else {
            reportedFinalOutputResults[sessionID] = nil
            if self.store === store {
                store.setFinalizingOutput(false)
            }
            return .cancelled
        }
        let executionResult = resolvedFinalOutputExecutionResult(sessionID: sessionID)
        guard activeSessionID == sessionID, self.store === store else {
            return executionResult
        }
        reportedFinalOutputResults[sessionID] = nil
        store.setFinalizingOutput(false)
        allowClose = true
        closeEditorWindow()
        allowClose = false
        return executionResult
    }

    func saveSession(
        _ image: NSImage,
        sessionID: UUID,
        store: ScreenshotEditorStore
    ) async {
        guard activeSessionID == sessionID,
              self.store === store,
              hostPanelSessionID == sessionID,
              hostPanel != nil,
              sessionCompletion != nil else { return }
        store.setFinalizingOutput(true)
        await finishSession(.saved(image), sessionID: sessionID)
        guard activeSessionID == sessionID,
              self.store === store,
              hostPanelSessionID == sessionID,
              hostPanel != nil else { return }
        store.setFinalizingOutput(false)
        allowClose = true
        closeEditorWindow()
        allowClose = false
    }

    private func requestRetake(
        _ retake: @escaping () -> Void,
        sessionID: UUID,
        store: ScreenshotEditorStore
    ) async {
        guard isActiveRetakeSession(sessionID: sessionID, store: store) else { return }
        var completedCurrentSession = false
        if store.isDirty {
            guard isActiveRetakeSession(sessionID: sessionID, store: store) else { return }
            switch await dirtyDocumentDecision() {
            case .complete:
                guard isActiveRetakeSession(sessionID: sessionID, store: store) else { return }
                guard let image = await store.completeForReplacement() else { return }
                guard isActiveRetakeSession(sessionID: sessionID, store: store) else { return }
                await finishSession(.completed(image), sessionID: sessionID)
                guard isActiveRetakeSession(
                    sessionID: sessionID,
                    store: store,
                    requiresCompletion: false
                ) else { return }
                completedCurrentSession = true
            case .discard:
                break
            case .cancel:
                return
            }
        }
        if !completedCurrentSession {
            guard isActiveRetakeSession(sessionID: sessionID, store: store) else { return }
            await finishSession(.retake, sessionID: sessionID)
            guard isActiveRetakeSession(
                sessionID: sessionID,
                store: store,
                requiresCompletion: false
            ) else { return }
        }
        guard isActiveRetakeSession(
            sessionID: sessionID,
            store: store,
            requiresCompletion: false
        ) else { return }
        allowClose = true
        closeEditorWindow()
        allowClose = false
        retake()
    }

    private func isActiveEditorSession(
        sessionID: UUID,
        store: ScreenshotEditorStore,
        requiresCompletion: Bool = true
    ) -> Bool {
        guard activeSessionID == sessionID,
              self.store === store,
              hostPanelSessionID == sessionID,
              hostPanel != nil else { return false }
        return !requiresCompletion || sessionCompletion != nil
    }

    private func isActiveRetakeSession(
        sessionID: UUID,
        store: ScreenshotEditorStore,
        requiresCompletion: Bool = true
    ) -> Bool {
        isActiveEditorSession(
            sessionID: sessionID,
            store: store,
            requiresCompletion: requiresCompletion
        )
    }

    private func prepareForReplacement() async -> Bool {
        // A replacement request arriving during final output queues behind the
        // existing transaction. Do not cancel it: pasteboard or archive work
        // may already be irreversible.
        if store?.isOutputPending == true {
            if finalOutputCommitStartedSessionID == activeSessionID {
                await awaitHostFinalOutputTask()
            } else {
                invalidateCurrentFinalization()
                await awaitHostFinalOutputTask()
            }
        }
        guard hostPanel != nil else { return true }
        guard store?.isOutputPending != true else { return false }
        guard store?.isDirty == true else {
            allowClose = true
            closeEditorWindow()
            allowClose = false
            return true
        }
        switch await dirtyDocumentDecision() {
        case .complete:
            guard let store, let image = await store.completeForReplacement() else { return false }
            guard let sessionID = activeSessionID else { return false }
            await finishSession(.completed(image), sessionID: sessionID)
            allowClose = true
            closeEditorWindow()
            allowClose = false
            return true
        case .discard:
            allowClose = true
            closeEditorWindow()
            allowClose = false
            return true
        case .cancel:
            return false
        }
    }

    private func dirtyDocumentDecision() async -> ScreenshotEditorCloseDecision {
        guard preferencesStore.preferences.confirmsDiscardBeforeClosing else { return .discard }
        guard let panel = hostPanel else { return .cancel }
        store?.setCloseConfirmationPresented(true)
        defer { store?.setCloseConfirmationPresented(false) }
        let result = await closeConfirmationCoordinator.decision(on: panel)
        persistCloseConfirmationSuppressionIfNeeded(result)
        return result.decision
    }

    private func requestClose(
        sessionID: UUID? = nil,
        store expectedStore: ScreenshotEditorStore? = nil
    ) {
        if let sessionID, let expectedStore,
           !isActiveEditorSession(sessionID: sessionID, store: expectedStore) {
            return
        }
        // Once final output has started, closing is not a discard operation:
        // a pasteboard or archive sink may already have crossed its irreversible
        // boundary. Keep the editor alive until finalization reports success or
        // failure, matching the scrolling-editor terminal contract.
        guard store?.isOutputPending != true else { return }
        guard store?.isDirty == true else {
            finishSessionWithoutWaiting(.cancelled)
            allowClose = true
            closeEditorWindow()
            allowClose = false
            return
        }
        guard preferencesStore.preferences.confirmsDiscardBeforeClosing else {
            finishSessionWithoutWaiting(.cancelled)
            allowClose = true
            closeEditorWindow()
            allowClose = false
            return
        }
        guard let panel = hostPanel else { return }
        let requestedSessionID = sessionID ?? activeSessionID
        let requestedStore = expectedStore ?? store
        let presented = closeConfirmationCoordinator.present(on: panel) { [weak self, weak requestedStore] result in
            guard let self,
                  let requestedSessionID,
                  let requestedStore,
                  self.isActiveEditorSession(
                      sessionID: requestedSessionID,
                      store: requestedStore
                  ) else { return }
            let store = requestedStore
            store.setCloseConfirmationPresented(false)
            self.persistCloseConfirmationSuppressionIfNeeded(result)
            switch result.decision {
            case .complete:
                _ = store.complete()
                return
            case .discard:
                self.finishSessionWithoutWaiting(.cancelled)
            case .cancel:
                return
            }
            self.allowClose = true
            self.closeEditorWindow()
            self.allowClose = false
        }
        if presented { store?.setCloseConfirmationPresented(true) }
    }

    private func persistCloseConfirmationSuppressionIfNeeded(
        _ result: ScreenshotEditorCloseConfirmationResult
    ) {
        guard result.suppressesFutureConfirmation else { return }
        preferencesStore.update { $0.confirmsDiscardBeforeClosing = false }
    }

    private func closeEditorWindow() {
        cancelEditorTransition()
        store?.shutdown()
        if let hostPanel {
            hostPanel.close()
        } else {
            finishSessionWithoutWaiting(.cancelled)
            store = nil
        }
    }

    private func cancelEditorTransition() {
        editorTransitionWatchdog?.cancel()
        editorTransitionWatchdog = nil
        editorTransitionID = nil
        selectionHandoffCoordinator.cancel()
        if let hostPanel {
            BlocksAppKitMotion.cancelAnimations(on: hostPanel)
        }
    }

    private func presentNonblockingError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = hostPanel ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
            return
        }
        alert.window.level = .floating
        alert.window.center()
        alert.window.orderFrontRegardless()
    }
}
