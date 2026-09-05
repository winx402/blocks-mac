import AppKit
import BlocksCore
import BlocksScreenshotCore
import Combine
import Foundation
import os

@MainActor
protocol ScreenshotCapturing {
    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool
    ) async throws -> ScreenshotCapture
    func cancelCurrentCapture()
}

@MainActor
protocol ScreenshotScrollingSessionControlling: AnyObject {
    func scrollingSessionStatus() async -> ScrollingScreenshotRuntimeSnapshot
    func finishScrollingSession(sessionID: String) -> Bool
    func cancelScrollingSession(
        sessionID: String,
        confirm: Bool
    ) async -> ScrollingScreenshotControlResult
    func finishScrollingEditingSession(
        sessionID: String,
        terminal: ScrollingScreenshotSessionTerminal
    ) async -> ScrollingScreenshotControlResult
}

@MainActor
protocol ScreenshotScrollingModePreparing: AnyObject {
    func prepareScrollingModeForNextCapture()
    func cancelPreparedScrollingModeForNextCapture()
}

@MainActor
protocol ScreenshotEditorPresenting {
    func configurePluginPlatform(
        manager: BlocksNativePluginManager?,
        runtime: BlocksPluginRuntimeCoordinator?
    )
    func prepareForNewCapture() async -> Bool
    func present(
        capture: ScreenshotCapture,
        retake: @escaping () -> Void,
        completion: @escaping (ScreenshotEditorOutcome) async -> Void
    )
    func edit(capture: ScreenshotCapture) async -> ScreenshotEditorOutcome
    func cancelCurrentSession()
    func markFinalOutputCommitStarted()
    func performPluginHostAction(
        _ actionID: String,
        origin: BlocksPluginHostInvocationOrigin,
        input: [String: JSONValue]
    ) async throws -> JSONValue
    func recordFinalOutputResult(_ result: ScreenshotFinalOutputResult)
    func setFinalOutputCancellationHandler(_ handler: (@MainActor () -> Void)?)
}

extension ScreenshotEditorPresenting {
    func configurePluginPlatform(
        manager: BlocksNativePluginManager?,
        runtime: BlocksPluginRuntimeCoordinator?
    ) {}

    func performPluginHostAction(
        _ actionID: String,
        origin: BlocksPluginHostInvocationOrigin,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
    }

    func recordFinalOutputResult(_ result: ScreenshotFinalOutputResult) {}
    func setFinalOutputCancellationHandler(_ handler: (@MainActor () -> Void)?) {}
    func markFinalOutputCommitStarted() {}
}

enum ScreenshotEditorOutcome {
    case completed(NSImage)
    case pinned(NSImage)
    case saved(NSImage)
    case cancelled
    case retake
    case failed(String)
}

enum ScreenshotStartResult: Equatable {
    case completed
    case cancelled
    case busy
    case failed
    case screenRecordingPermissionMissing
    case inputMonitoringPermissionMissing
    case featureDisabled
}

@MainActor
final class ScreenshotApplicationContextRestorer {
    private enum State {
        case pending
        case suppressed
        case restored
    }

    private let restoration: () -> Void
    private var state: State = .pending

    var didRestore: Bool { state == .restored }

    init(restoration: @escaping () -> Void) {
        self.restoration = restoration
    }

    func restoreOnce() {
        guard state == .pending else { return }
        state = .restored
        restoration()
    }

    /// Temporarily prevents a terminal callback from restoring the application
    /// that owned an editor which is being replaced by a newer capture request.
    func suppressRestoration() {
        guard state == .pending else { return }
        state = .suppressed
    }

    /// Re-enables restoration when replacement was cancelled and the existing
    /// editor remains the active session.
    func resumeRestoration() {
        guard state == .suppressed else { return }
        state = .pending
    }
}

@MainActor
private final class ScreenshotEditorCompletionOwnership {
    private(set) var isValid = true

    func invalidate() {
        isValid = false
    }
}

/// Represents the single linearization point between runtime revocation and a
/// requested output-file write. The lock protects only the state transition;
/// no caller holds it while encoding, invoking a test seam, or performing I/O.
private enum ScreenshotOutputFileWriteAdmissionError: Error {
    case runtimeRevoked
}

private final class ScreenshotOutputFileWriteAdmission: @unchecked Sendable {
    struct Lease: Sendable {
        fileprivate init() {}
    }

    private enum State {
        case pending
        case admitted
        case revoked
    }

    private let lock = NSLock()
    private var state: State = .pending

    /// Runtime revocation wins only before a file writer acquires its lease.
    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return }
        state = .revoked
    }

    /// Acquiring the lease is the file sink's irreversible admission point.
    /// Once admitted, later revocation intentionally cannot change the write
    /// outcome; the writer performs the complete truncate/write/sync sequence.
    func acquireLease() throws -> Lease {
        lock.lock()
        defer { lock.unlock() }
        if Task.isCancelled {
            throw CancellationError()
        }
        guard case .pending = state else {
            throw ScreenshotOutputFileWriteAdmissionError.runtimeRevoked
        }
        state = .admitted
        return Lease()
    }
}

@MainActor
final class ScreenshotStore: ObservableObject {
    @Published private(set) var lastCaptureSummary: String = L10n.string("main.noScreenshotCaptured")

    let preferencesStore: ScreenshotPreferencesStore

    private let captureService: ScreenshotCapturing
    private let scrollingSessionController: ScreenshotScrollingSessionControlling?
    private let scrollingModePreparer: ScreenshotScrollingModePreparing?
    private let editorPresenter: ScreenshotEditorPresenting
    private let finalOutputCoordinator: ScreenshotFinalOutputCoordinator
    private let outputSerializationGate: ScreenshotOutputSerialGate
    private let notificationPresenter: (any BlocksNotificationPanelPresenting)?
    private let editingContextFailureDecision: @MainActor () async -> Bool
    private let applicationContextSuspender: @MainActor () -> ScreenshotApplicationContextRestorer
    /// Test seam immediately before the output-file sink's admission point.
    /// It must not influence production behavior, where this is `nil`.
    private let beforeOutputFileWriteAdmissionForTesting: (@Sendable () async -> Void)?
    /// Test seam invoked only after a requested output file is synchronized.
    /// It must not influence production behavior, where this is `nil`.
    private let afterOutputFileSynchronizedForTesting: (@Sendable () async -> Void)?
    /// Test seam invoked after file-write admission and before any file I/O.
    /// It is evaluated only in DEBUG builds.
    private let afterOutputFileWriteAdmissionForTesting: (@Sendable () async -> Void)?
    private let sessionGate = ScreenshotSessionGate()
    private let permissionRefresher: () -> Void
    private let permissionSnapshotProvider: () -> PermissionStateSnapshot
    private let featureEnabled: () -> Bool
    private var statusRecorder: (AppStatus) -> Void = { _ in }
    private var retakeHandler: (Bool) -> Void = { _ in }
    private var activeEditorApplicationContext: ScreenshotApplicationContextRestorer?
    private var activeEditorFinalOutputTask: Task<ScreenshotFinalOutputResult, Never>?
    private var activeEditorFinalOutputTaskID: UUID?
    private var activeEditorCompletionGeneration: UUID?
    private var activeEditorScrollingSessionID: String?
    private var activeOutputFileWriteAdmission: ScreenshotOutputFileWriteAdmission?
    private var runtimeGeneration = UUID()
    /// This is deliberately distinct from `runtimeGeneration`: Action Broker
    /// cancellation must invalidate only the matching request, without
    /// disabling the screenshot feature or invalidating a later request.
    private var activeActionCancellationToken: UUID?
    private weak var pluginRuntime: BlocksPluginRuntimeCoordinator?
    private var dispatchPluginEvent: @MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult = { .allowed($0) }
    private let logger = Logger(subsystem: "app.blocks.app", category: "ScreenshotStore")

    init(
        captureService: ScreenshotCapturing? = nil,
        editorPresenter: ScreenshotEditorPresenting? = nil,
        preferencesStore: ScreenshotPreferencesStore? = nil,
        pasteboardWriter: (any ScreenshotPasteboardWriting)? = nil,
        archiveWriter: (any ScreenshotClipboardArchiving)? = nil,
        ocrCoordinator: LocalOCRCoordinator? = nil,
        ocrService: LocalVisionOCRService? = nil,
        notificationPresenter: (any BlocksNotificationPanelPresenting)? = nil,
        featureEnabled: @escaping () -> Bool = { true },
        editingContextFailureDecision: (@MainActor () async -> Bool)? = nil,
        applicationContextSuspender: (@MainActor () -> ScreenshotApplicationContextRestorer)? = nil,
        screenshotHistoryCommitAdmissionFactory: @escaping @Sendable () -> ScreenshotHistoryCommitAdmission = {
            ScreenshotHistoryCommitAdmission()
        },
        beforeOutputFileWriteAdmissionForTesting: (@Sendable () async -> Void)? = nil,
        afterOutputFileSynchronizedForTesting: (@Sendable () async -> Void)? = nil,
        afterOutputFileWriteAdmissionForTesting: (@Sendable () async -> Void)? = nil,
        permissionRefresher: @escaping () -> Void,
        permissionSnapshotProvider: @escaping () -> PermissionStateSnapshot
    ) {
        let preferencesStore = preferencesStore ?? ScreenshotPreferencesStore()
        self.preferencesStore = preferencesStore
        let outputSerializationGate = ScreenshotOutputSerialGate()
        self.outputSerializationGate = outputSerializationGate
        let resolvedCaptureService = captureService ?? ScreenCaptureKitAdapter(preferencesStore: preferencesStore)
        self.captureService = resolvedCaptureService
        scrollingSessionController = resolvedCaptureService as? ScreenshotScrollingSessionControlling
        scrollingModePreparer = resolvedCaptureService as? ScreenshotScrollingModePreparing
        self.editorPresenter = editorPresenter ?? ScreenshotEditorPresenter(
            preferencesStore: preferencesStore,
            ocrCoordinator: ocrCoordinator
                ?? LocalOCRCoordinator(service: ocrService ?? LocalVisionOCRService()),
            outputSerializationGate: outputSerializationGate
        )
        let pasteboardWriter = pasteboardWriter ?? ScreenshotPasteboardWriter()
        self.finalOutputCoordinator = ScreenshotFinalOutputCoordinator(
            preferencesStore: preferencesStore,
            pasteboardWriter: pasteboardWriter,
            archiveWriter: archiveWriter,
            serializationGate: outputSerializationGate,
            screenshotHistoryCommitAdmissionFactory: screenshotHistoryCommitAdmissionFactory
        )
        self.notificationPresenter = notificationPresenter
        self.editingContextFailureDecision = editingContextFailureDecision
            ?? Self.presentEditingContextFailureAlert
        self.applicationContextSuspender = applicationContextSuspender
            ?? Self.suspendApplicationContextForCapture
        self.beforeOutputFileWriteAdmissionForTesting = beforeOutputFileWriteAdmissionForTesting
        self.afterOutputFileSynchronizedForTesting = afterOutputFileSynchronizedForTesting
        self.afterOutputFileWriteAdmissionForTesting = afterOutputFileWriteAdmissionForTesting
        self.permissionRefresher = permissionRefresher
        self.permissionSnapshotProvider = permissionSnapshotProvider
        self.featureEnabled = featureEnabled
    }

    func configureCoordinator(
        statusRecorder: @escaping (AppStatus) -> Void,
        retakeHandler: @escaping (Bool) -> Void,
        dispatchPluginEvent: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult = { .allowed($0) },
        registerPluginResource: @escaping @Sendable (
            Data,
            BlocksPluginResourceKind,
            String?,
            [String: JSONValue]
        ) -> BlocksPluginResourceReference? = { _, _, _, _ in nil },
        removePluginResources: @escaping @Sendable ([String]) -> Void = { _ in },
        pluginManager: BlocksNativePluginManager? = nil,
        pluginRuntime: BlocksPluginRuntimeCoordinator? = nil
    ) {
        self.statusRecorder = statusRecorder
        self.retakeHandler = retakeHandler
        self.dispatchPluginEvent = dispatchPluginEvent
        self.pluginRuntime = pluginRuntime
        editorPresenter.configurePluginPlatform(
            manager: pluginManager,
            runtime: pluginRuntime
        )
        finalOutputCoordinator.configurePluginPlatform(
            dispatchPluginEvent: dispatchPluginEvent,
            dispatchWillPluginEvent: { [weak pluginRuntime] envelope, isCurrent in
                guard isCurrent() else { return .allowed(envelope) }
                guard let pluginRuntime else {
                    let result = await dispatchPluginEvent(envelope)
                    return isCurrent() ? result : .allowed(envelope)
                }
                return await pluginRuntime.dispatchFromFeature(
                    envelope,
                    admissionIsCurrent: isCurrent
                )
            },
            dispatchTerminalPluginEvent: { [weak pluginRuntime] envelope, isCurrent in
                guard let pluginRuntime else {
                    guard isCurrent() else {
                        return .allowed(envelope)
                    }
                    return await dispatchPluginEvent(envelope)
                }
                return await pluginRuntime
                    .dispatchFromFeatureAwaitingCompletion(
                        envelope,
                        admissionIsCurrent: isCurrent
                    )
            },
            registerResource: registerPluginResource,
            removeResources: removePluginResources
        )
    }

    func cancelCurrentAction() {
        captureService.cancelCurrentCapture()
        editorPresenter.cancelCurrentSession()
    }

    /// Cancels the current Action Broker capture request. The token is made
    /// stale before either irreversible sink can be admitted and before
    /// asking capture/editor work to stop, because those implementations may
    /// complete after cancellation.
    func cancelCurrentActionRequest() {
        guard activeActionCancellationToken != nil else { return }
        activeActionCancellationToken = nil
        finalOutputCoordinator.revokePendingArchiveCommit()
        activeOutputFileWriteAdmission?.revoke()
        cancelCurrentAction()
    }

    /// Invalidates every in-flight screenshot continuation before asking the
    /// underlying services to stop. Some capture and editor implementations
    /// can complete after cancellation, so callers must also hold this lease.
    func disableRuntime() {
        // This is the only admission lock. It is acquired before mutating the
        // runtime generation and never while any other lock or await is held.
        finalOutputCoordinator.revokePendingArchiveCommit()
        activeOutputFileWriteAdmission?.revoke()
        pluginRuntime?.invalidateFeatureAdmission(for: .screenshot)
        runtimeGeneration = UUID()
        sessionGate.invalidate()
        activeEditorCompletionGeneration = nil
        activeEditorScrollingSessionID = nil
        activeEditorFinalOutputTask?.cancel()
        activeEditorFinalOutputTask = nil
        activeEditorFinalOutputTaskID = nil
        editorPresenter.setFinalOutputCancellationHandler(nil)
        activeEditorApplicationContext?.restoreOnce()
        activeEditorApplicationContext = nil
        cancelCurrentAction()
    }

    private func isRuntimeCurrent(_ generation: UUID) -> Bool {
        runtimeGeneration == generation && featureEnabled()
    }

    private func isActionCurrent(
        _ token: UUID,
        runtimeGeneration: UUID
    ) -> Bool {
        activeActionCancellationToken == token
            && isRuntimeCurrent(runtimeGeneration)
    }

    /// GUI entry points use this after the session gate rejects a duplicate
    /// capture. Keeping it separate from `startSmartScreenshot()` prevents a
    /// background plugin action from presenting unsolicited UI.
    func presentBusyFeedback() {
        let title = L10n.string("screenshot.busy.title")
        let detail = L10n.string("screenshot.busy.detail")
        statusRecorder(AppStatus(kind: .running, title: title, detail: detail))
        notificationPresenter?.present(
            BlocksNotificationDescriptor(
                level: .info,
                title: title,
                detail: detail,
                deduplicationKey: "screenshot.capture.busy"
            ),
            on: notificationScreen(for: nil),
            avoiding: []
        )
    }

    func performPluginHostAction(
        _ actionID: String,
        origin: BlocksPluginHostInvocationOrigin,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        try await editorPresenter.performPluginHostAction(
            actionID,
            origin: origin,
            input: input
        )
    }

    @discardableResult
    func startSmartScreenshot() async -> ScreenshotStartResult {
        await startSmartScreenshot(startsInScrollingMode: false)
    }

    @discardableResult
    func startSmartScreenshot(
        startsInScrollingMode: Bool
    ) async -> ScreenshotStartResult {
        let runtimeGeneration = runtimeGeneration
        guard isRuntimeCurrent(runtimeGeneration) else {
            statusRecorder(AppStatus(
                kind: .ready,
                title: L10n.string("feature.screenshot.disabled.title"),
                detail: L10n.string("feature.screenshot.disabled.detail")
            ))
            return .featureDisabled
        }
        let sessionID = UUID()
        guard sessionGate.begin(owner: sessionID) else { return .busy }
        defer { sessionGate.end(owner: sessionID) }
        guard await prepareForNewCapture() else {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            statusRecorder(AppStatus(
                kind: .ready,
                title: L10n.string("status.cancelled.title"),
                detail: L10n.string("status.cancelled.detail")
            ))
            return .cancelled
        }
        guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
        permissionRefresher()
        let snapshot = permissionSnapshotProvider()
        guard snapshot.screenRecordingGranted else {
            statusRecorder(screenRecordingMissingStatus(snapshot))
            return .screenRecordingPermissionMissing
        }
        let applicationContext = applicationContextSuspender()
        activeEditorApplicationContext = applicationContext
        var editorOwnsApplicationContext = false
        defer {
            if !editorOwnsApplicationContext {
                applicationContext.restoreOnce()
                clearActiveEditorApplicationContext(ifMatching: applicationContext)
            }
        }

        guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
        statusRecorder(AppStatus(
            kind: .running,
            title: L10n.string("status.selectRegion.title"),
            detail: L10n.string("selection.window.instructions")
        ))

        do {
            let capture = try await captureSmartScreenshot(
                startsInScrollingMode: startsInScrollingMode
            )
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            if capture.editingContext == nil
                || (!capture.defersOutputUntilEditorCompletion
                    && capture.editingContext?.supportsRangeExpansion != true) {
                throw ScreenshotCaptureError.editingContextUnavailable
            }
            lastCaptureSummary = L10n.format(
                "capture.summary",
                Int(capture.pixelSize.width),
                Int(capture.pixelSize.height),
                capture.kind.localizedTitle
            )
            let capturePayload = pluginCapturePayload(capture)
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .screenshotCaptureCompleted,
                    sessionID: capture.id,
                    payload: capturePayload
                )
            )
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            if capture.scrollingSessionID != nil {
                guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
                _ = await dispatchPluginEvent(
                    BlocksPluginEventEnvelope(
                        name: .screenshotLongCaptureAssembled,
                        sessionID: capture.id,
                        payload: capturePayload
                    )
                )
                guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            }
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            statusRecorder(AppStatus(kind: .ready, title: L10n.string("status.captured.title"), detail: lastCaptureSummary))
            let completionGeneration = UUID()
            activeEditorCompletionGeneration = completionGeneration
            activeEditorScrollingSessionID = capture.scrollingSessionID
            editorPresenter.present(
                capture: capture,
                retake: { [weak self] in
                    guard let self, self.isRuntimeCurrent(runtimeGeneration) else { return }
                    self.retakeHandler(
                        capture.defersOutputUntilEditorCompletion
                    )
                },
                completion: { [weak self] outcome in
                    defer {
                        applicationContext.restoreOnce()
                        self?.clearActiveEditorApplicationContext(ifMatching: applicationContext)
                    }
                    guard let self else { return }
                    let ownership = ScreenshotEditorCompletionOwnership()
                    guard self.isRuntimeCurrent(runtimeGeneration),
                          self.activeEditorCompletionGeneration == completionGeneration else {
                        return
                    }
                    self.editorPresenter.setFinalOutputCancellationHandler {
                        ownership.invalidate()
                    }
                    defer {
                        self.clearActiveEditorCompletionGeneration(
                            ifMatching: completionGeneration
                        )
                    }
                    switch outcome {
                    case let .completed(image):
                        guard await self.finishDeferredScrollingSession(
                            for: capture,
                            terminal: .completed,
                            isCurrent: {
                                ownership.isValid
                                    && self.isRuntimeCurrent(runtimeGeneration)
                                    && self.activeEditorCompletionGeneration == completionGeneration
                                    && !Task.isCancelled
                            }
                        ) else {
                            guard ownership.isValid,
                                  self.isRuntimeCurrent(runtimeGeneration),
                                  self.activeEditorCompletionGeneration == completionGeneration,
                                  !Task.isCancelled else { return }
                            self.editorPresenter.recordFinalOutputResult(
                                ScreenshotFinalOutputResult(
                                    pasteboard: .failed,
                                    archive: .failed,
                                    isCancelled: true
                                )
                            )
                            return
                        }
                        guard ownership.isValid,
                              self.isRuntimeCurrent(runtimeGeneration),
                              self.activeEditorCompletionGeneration == completionGeneration,
                              !Task.isCancelled else { return }
                        let result = await self.runEditorFinalOutput(
                            capture: capture,
                            image: image,
                            writesPasteboard: true,
                            isRuntimeCurrent: {
                                self.isRuntimeCurrent(runtimeGeneration)
                                    && ownership.isValid
                                    && self.activeEditorCompletionGeneration == completionGeneration
                            }
                        )
                        // The presenter owns the host-action result. Preserve
                        // this terminal fact before checking runtime ownership:
                        // its result may be a durable commit or a true
                        // pre-commit cancellation. UI/status effects remain
                        // guarded below.
                        self.editorPresenter.recordFinalOutputResult(result)
                        guard ownership.isValid,
                              self.isRuntimeCurrent(runtimeGeneration),
                              self.activeEditorCompletionGeneration == completionGeneration else { return }
                        if !result.isCancelled {
                            self.recordFinalOutputStatus(result, capture: capture)
                        }
                    case let .pinned(image):
                        guard await self.finishDeferredScrollingSession(
                            for: capture,
                            terminal: .completed,
                            isCurrent: {
                                ownership.isValid
                                    && self.isRuntimeCurrent(runtimeGeneration)
                                    && self.activeEditorCompletionGeneration == completionGeneration
                                    && !Task.isCancelled
                            }
                        ) else { return }
                        guard ownership.isValid,
                              self.isRuntimeCurrent(runtimeGeneration),
                              self.activeEditorCompletionGeneration == completionGeneration,
                              !Task.isCancelled else { return }
                        let result = await self.runEditorFinalOutput(
                            capture: capture,
                            image: image,
                            writesPasteboard: false,
                            isRuntimeCurrent: {
                                self.isRuntimeCurrent(runtimeGeneration)
                                    && ownership.isValid
                                    && self.activeEditorCompletionGeneration == completionGeneration
                            }
                        )
                        // See the completed branch above: final-output truth
                        // is a host-result fact, not a late UI side effect.
                        self.editorPresenter.recordFinalOutputResult(result)
                        guard ownership.isValid,
                              self.isRuntimeCurrent(runtimeGeneration),
                              self.activeEditorCompletionGeneration == completionGeneration else { return }
                        if !result.isCancelled {
                            self.recordFinalOutputStatus(result, capture: capture)
                        }
                    case .saved:
                        _ = await self.finishDeferredScrollingSession(
                            for: capture,
                            terminal: .completed,
                            isCurrent: {
                                ownership.isValid
                                    && self.isRuntimeCurrent(runtimeGeneration)
                                    && self.activeEditorCompletionGeneration == completionGeneration
                                    && !Task.isCancelled
                            }
                        )
                    case .cancelled, .retake:
                        _ = await self.finishDeferredScrollingSession(
                            for: capture,
                            terminal: .cancelled,
                            isCurrent: {
                                ownership.isValid
                                    && self.isRuntimeCurrent(runtimeGeneration)
                                    && self.activeEditorCompletionGeneration == completionGeneration
                                    && !Task.isCancelled
                            }
                        )
                    case .failed:
                        _ = await self.finishDeferredScrollingSession(
                            for: capture,
                            terminal: .failed,
                            isCurrent: {
                                ownership.isValid
                                    && self.isRuntimeCurrent(runtimeGeneration)
                                    && self.activeEditorCompletionGeneration == completionGeneration
                                    && !Task.isCancelled
                            }
                        )
                    }
                }
            )
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .screenshotEditorOpened,
                    sessionID: capture.id,
                    payload: capturePayload
                )
            )
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            editorOwnsApplicationContext = true
            return .completed
        } catch ScreenshotCaptureError.cancelled {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            statusRecorder(AppStatus(
                kind: .ready,
                title: L10n.string("status.cancelled.title"),
                detail: L10n.string("status.cancelled.detail")
            ))
            return .cancelled
        } catch ScreenshotCaptureError.timedOut {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            recordScreenshotFailure(
                title: L10n.string("status.timedOut.title"),
                detail: L10n.string("status.timedOut.detail"),
                deduplicationKey: "screenshot.capture.timed-out",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            return .failed
        } catch ScreenshotCaptureError.selectionTooSmall {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            recordScreenshotFailure(
                title: L10n.string("status.selectionTooSmall.title"),
                detail: L10n.string("status.selectionTooSmall.detail"),
                deduplicationKey: "screenshot.capture.selection-too-small",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            return .failed
        } catch ScreenshotCaptureError.noCandidateWindow {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            recordScreenshotFailure(
                title: L10n.string("status.noCandidateWindow.title"),
                detail: L10n.string("status.noCandidateWindow.detail"),
                deduplicationKey: "screenshot.capture.no-window",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            return .failed
        } catch ScreenshotCaptureError.displayNotFound {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            logger.error("stage=screenshot-capture-failed reason=display-not-found")
            recordScreenshotFailure(
                title: L10n.string("status.displayNotFound.title"),
                detail: L10n.string("status.displayNotFound.detail"),
                deduplicationKey: "screenshot.capture.display-not-found",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            return .failed
        } catch ScreenshotCaptureError.windowDisplayNotFound {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            recordScreenshotFailure(
                title: L10n.string("status.windowDisplayNotFound.title"),
                detail: L10n.string("status.windowDisplayNotFound.detail"),
                deduplicationKey: "screenshot.capture.window-display-not-found",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            return .failed
        } catch ScreenshotCaptureError.editingContextUnavailable {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            recordScreenshotFailure(
                title: L10n.string("status.editingContextUnavailable.title"),
                detail: L10n.string("status.editingContextUnavailable.detail"),
                deduplicationKey: "screenshot.capture.editing-context",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            applicationContext.restoreOnce()
            if await editingContextFailureDecision() {
                guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
                retakeHandler(false)
            }
            return .failed
        } catch ScreenshotCaptureError.screenRecordingPermissionMissing {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            statusRecorder(screenRecordingMissingStatus(permissionSnapshotProvider()))
            return .screenRecordingPermissionMissing
        } catch ScreenshotCaptureError.inputMonitoringPermissionMissing {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            logger.error("stage=screenshot-capture-failed reason=input-monitoring-missing")
            statusRecorder(AppStatus(
                kind: .permissionMissing,
                title: L10n.string("screenshot.scrolling.permission.title"),
                detail: L10n.string("screenshot.scrolling.permission.required")
            ))
            return .inputMonitoringPermissionMissing
        } catch {
            guard isRuntimeCurrent(runtimeGeneration) else { return .cancelled }
            let failure = error as NSError
            logger.error(
                "stage=screenshot-capture-failed reason=unexpected domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
            )
            recordScreenshotFailure(
                title: L10n.string("status.failed.title"),
                detail: error.localizedDescription,
                deduplicationKey: "screenshot.capture.unexpected",
                isCurrent: { self.isRuntimeCurrent(runtimeGeneration) }
            )
            return .failed
        }
    }

    private func captureSmartScreenshot(
        startsInScrollingMode: Bool
    ) async throws -> ScreenshotCapture {
        if startsInScrollingMode {
            scrollingModePreparer?.prepareScrollingModeForNextCapture()
        }
        defer {
            if startsInScrollingMode {
                scrollingModePreparer?.cancelPreparedScrollingModeForNextCapture()
            }
        }
        return try await captureService.capture(
            intent: try ScreenshotCaptureIntent(kind: .smart),
            requiresEditingContext: true
        )
    }

    private func runEditorFinalOutput(
        capture: ScreenshotCapture,
        image: NSImage,
        writesPasteboard: Bool,
        isRuntimeCurrent: @escaping @MainActor () -> Bool
    ) async -> ScreenshotFinalOutputResult {
        let taskID = UUID()
        let task = Task { @MainActor [finalOutputCoordinator] in
            await finalOutputCoordinator.finalize(
                capture: capture,
                image: image,
                writesPasteboard: writesPasteboard,
                userInitiated: true,
                isCurrent: isRuntimeCurrent,
                onCommitStarted: { [editorPresenter] in
                    editorPresenter.markFinalOutputCommitStarted()
                }
            )
        }
        activeEditorFinalOutputTask = task
        activeEditorFinalOutputTaskID = taskID
        editorPresenter.setFinalOutputCancellationHandler { [weak self, task] in
            task.cancel()
            guard let self, self.activeEditorFinalOutputTaskID == taskID else { return }
            self.activeEditorFinalOutputTask = nil
            self.activeEditorFinalOutputTaskID = nil
        }
        let result = await task.value
        if activeEditorFinalOutputTaskID == taskID {
            activeEditorFinalOutputTask = nil
            activeEditorFinalOutputTaskID = nil
            editorPresenter.setFinalOutputCancellationHandler(nil)
        }
        return result
    }

    private func clearActiveEditorCompletionGeneration(ifMatching generation: UUID) {
        guard activeEditorCompletionGeneration == generation else { return }
        activeEditorCompletionGeneration = nil
        activeEditorScrollingSessionID = nil
    }

    private func clearActiveOutputFileWriteAdmission(
        ifMatching admission: ScreenshotOutputFileWriteAdmission?
    ) {
        guard let admission,
              activeOutputFileWriteAdmission === admission else { return }
        activeOutputFileWriteAdmission = nil
    }

    private static func suspendApplicationContextForCapture() -> ScreenshotApplicationContextRestorer {
        let previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
        let blocksWasFrontmost = previousFrontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        return ScreenshotApplicationContextRestorer {
            let restoreExternalApplication = {
                guard !blocksWasFrontmost, let previousFrontmostApplication else { return }
                previousFrontmostApplication.activate(options: [.activateAllWindows])
            }
            restoreExternalApplication()
            Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(80))
                restoreExternalApplication()
            }
        }
    }

    func scrollingStatusAction() async -> ScreenshotScrollingStatusActionResult {
        guard let scrollingSessionController else {
            return ScreenshotScrollingStatusActionResult(permission: permissionSnapshotProvider().inputMonitoringGranted ? nil : .inputMonitoring)
        }
        let snapshot = await scrollingSessionController.scrollingSessionStatus()
        return ScreenshotScrollingStatusActionResult(
            sessionID: snapshot.sessionID,
            state: snapshot.actionState,
            size: snapshot.outputSize.width > 0 && snapshot.outputSize.height > 0
                ? ScreenshotPixelDimensions(width: snapshot.outputSize.width, height: snapshot.outputSize.height)
                : nil,
            warning: snapshot.warning,
            permission: permissionSnapshotProvider().inputMonitoringGranted ? nil : .inputMonitoring
        )
    }

    func finishScrollingAction(_ input: ScreenshotScrollingFinishActionInput) async -> ScreenshotScrollingFinishActionResult {
        return ScreenshotScrollingFinishActionResult(
            sessionID: input.sessionID,
            finishRequested: scrollingSessionController?.finishScrollingSession(sessionID: input.sessionID) ?? false
        )
    }

    func cancelScrollingAction(_ input: ScreenshotScrollingCancelActionInput) async -> ScreenshotScrollingCancelActionResult {
        let result = await scrollingSessionController?.cancelScrollingSession(
            sessionID: input.sessionID,
            confirm: input.confirm
        ) ?? .rejected(.invalidState, state: .idle)
        let terminalWasClaimedByPendingEditorCompletion =
            result.failure == .alreadyTerminal
                && activeEditorScrollingSessionID == input.sessionID
        if result.wasEditing
            && (result.accepted || terminalWasClaimedByPendingEditorCompletion) {
            editorPresenter.cancelCurrentSession()
        }
        return ScreenshotScrollingCancelActionResult(
            sessionID: input.sessionID,
            cancelled: result.accepted
        )
    }

    private static func presentEditingContextFailureAlert() async -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string("status.editingContextUnavailable.title")
        alert.informativeText = L10n.string("status.editingContextUnavailable.detail")
        alert.addButton(withTitle: L10n.string("screenshot.result.retake"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }) else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    func executeAction(
        _ input: ScreenshotCaptureActionInput,
        outputFile: FileHandle?
    ) async throws -> ScreenshotCaptureActionResult {
        let runtimeGeneration = runtimeGeneration
        guard isRuntimeCurrent(runtimeGeneration) else {
            throw ScreenshotActionExecutionError.featureDisabled
        }
        let sessionID = UUID()
        guard sessionGate.begin(owner: sessionID) else {
            throw ScreenshotActionExecutionError.sessionInProgress
        }
        defer { sessionGate.end(owner: sessionID) }
        let actionCancellationToken = UUID()
        activeActionCancellationToken = actionCancellationToken
        defer {
            if activeActionCancellationToken == actionCancellationToken {
                activeActionCancellationToken = nil
            }
        }
        let isCurrent = { [weak self] in
            self?.isActionCurrent(
                actionCancellationToken,
                runtimeGeneration: runtimeGeneration
            ) ?? false
        }
        let outputFileWriteAdmission = outputFile.map { _ in
            ScreenshotOutputFileWriteAdmission()
        }
        if let outputFileWriteAdmission {
            activeOutputFileWriteAdmission = outputFileWriteAdmission
        }
        defer {
            clearActiveOutputFileWriteAdmission(
                ifMatching: outputFileWriteAdmission
            )
        }
        try Task.checkCancellation()
        guard await prepareForNewCapture() else {
            throw ScreenshotActionExecutionError.cancelled
        }
        guard isCurrent() else {
            throw ScreenshotActionExecutionError.cancelled
        }
        let applicationContext = input.interaction == .interactive
            ? applicationContextSuspender()
            : nil
        defer { applicationContext?.restoreOnce() }
        while true {
            try Task.checkCancellation()
            let isInteractive = input.interaction == .interactive
            var capture = try await captureService.capture(
                intent: try makeIntent(input),
                requiresEditingContext: isInteractive
            )
            guard isCurrent() else {
                throw ScreenshotActionExecutionError.cancelled
            }
            capture = try applyingWatermarkSelection(
                input.watermark,
                to: capture,
                rendersImmediately: !isInteractive
            )
            try Task.checkCancellation()
            if isInteractive,
               capture.editingContext?.supportsRangeExpansion != true,
               !capture.defersOutputUntilEditorCompletion {
                throw ScreenshotActionExecutionError.editorFailed(
                    L10n.string("screenshot.editor.quickContextUnavailable")
                )
            }
            var resultImage = capture.image
            var shouldCopy = input.copy
            var shouldCommitFinalOutput = true

            if input.interaction == .interactive {
                let outcome = await editorPresenter.edit(capture: capture)
                guard isCurrent() else {
                    throw ScreenshotActionExecutionError.cancelled
                }
                switch outcome {
                case let .completed(image):
                    resultImage = image
                    shouldCopy = true
                    guard await finishDeferredScrollingSession(
                        for: capture,
                        terminal: .completed,
                        isCurrent: isCurrent
                    ) else {
                        throw ScreenshotActionExecutionError.cancelled
                    }
                case let .pinned(image):
                    resultImage = image
                    shouldCopy = false
                    guard await finishDeferredScrollingSession(
                        for: capture,
                        terminal: .completed,
                        isCurrent: isCurrent
                    ) else {
                        throw ScreenshotActionExecutionError.cancelled
                    }
                case let .saved(image):
                    resultImage = image
                    shouldCopy = false
                    shouldCommitFinalOutput = false
                    guard await finishDeferredScrollingSession(
                        for: capture,
                        terminal: .completed,
                        isCurrent: isCurrent
                    ) else {
                        throw ScreenshotActionExecutionError.cancelled
                    }
                case .retake:
                    _ = await finishDeferredScrollingSession(
                        for: capture,
                        terminal: .cancelled,
                        isCurrent: isCurrent
                    )
                    continue
                case .cancelled:
                    _ = await finishDeferredScrollingSession(
                        for: capture,
                        terminal: .cancelled,
                        isCurrent: isCurrent
                    )
                    throw ScreenshotActionExecutionError.cancelled
                case let .failed(message):
                    _ = await finishDeferredScrollingSession(
                        for: capture,
                        terminal: .failed,
                        isCurrent: isCurrent
                    )
                    throw ScreenshotActionExecutionError.editorFailed(message)
                }
                try Task.checkCancellation()
            }

            let finalOutput = if shouldCommitFinalOutput {
                await finalOutputCoordinator.finalize(
                    capture: capture,
                    image: resultImage,
                    writesPasteboard: shouldCopy,
                    userInitiated: input.interaction == .interactive,
                    isCurrent: isCurrent
                )
            } else {
                ScreenshotFinalOutputResult(pasteboard: .notRequested, archive: .notRequested)
            }
            if finalOutput.isCancelled {
                throw ScreenshotActionExecutionError.cancelled
            }
            guard isCurrent() || finalOutput.hasCommittedSink else {
                throw ScreenshotActionExecutionError.cancelled
            }
            guard let resultCGImage = resultImage.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ) else {
                throw ScreenshotActionExecutionError.missingImage
            }

            let outputStatus: ScreenshotActionSinkStatus
            if let outputFile {
                if !isCurrent() {
                    // Final output already committed, but runtime revocation
                    // must not admit this later file sink.
                    outputStatus = .failed
                } else if let outputFileWriteAdmission {
                    if Task.isCancelled {
                        guard finalOutput.hasCommittedSink else {
                            throw ScreenshotActionExecutionError.cancelled
                        }
                        outputStatus = .failed
                    } else {
                        do {
                            let jpegQuality = preferencesStore.preferences.jpegQuality
                            try await Self.write(
                                resultCGImage,
                                format: input.format,
                                jpegQuality: jpegQuality,
                                to: outputFile,
                                admission: outputFileWriteAdmission,
                                beforeOutputFileWriteAdmission: beforeOutputFileWriteAdmissionForTesting,
                                afterOutputFileWriteAdmission: afterOutputFileWriteAdmissionForTesting,
                                afterOutputFileSynchronized: afterOutputFileSynchronizedForTesting
                            )
                            outputStatus = .succeeded
                        } catch is ScreenshotOutputFileWriteAdmissionError {
                            // A runtime revoke won the admission race. A prior
                            // pasteboard/archive commit remains durable truth, but
                            // this requested file was never admitted.
                            guard finalOutput.hasCommittedSink else {
                                throw ScreenshotActionExecutionError.cancelled
                            }
                            outputStatus = .failed
                        } catch is CancellationError {
                            guard finalOutput.hasCommittedSink else {
                                throw ScreenshotActionExecutionError.cancelled
                            }
                            outputStatus = .failed
                        } catch {
                            outputStatus = .failed
                        }
                    }
                } else {
                    assertionFailure("Missing output-file admission for requested output.")
                    outputStatus = .failed
                }
            } else {
                outputStatus = .notRequested
            }

            return ScreenshotCaptureActionResult(
                captureID: capture.id,
                kind: capture.kind.actionKind,
                displayScope: capture.displayScope?.actionScope,
                pixelSize: ScreenshotPixelDimensions(
                    width: resultCGImage.width,
                    height: resultCGImage.height
                ),
                pasteboard: finalOutput.pasteboard.actionStatus,
                history: finalOutput.archive.actionStatus,
                output: outputStatus
            )
        }
    }

    private func makeIntent(_ input: ScreenshotCaptureActionInput) throws -> ScreenshotCaptureIntent {
        switch input.kind {
        case .smart:
            return try ScreenshotCaptureIntent(kind: .smart)
        case .region:
            return try ScreenshotCaptureIntent(kind: .region)
        case .window:
            return try ScreenshotCaptureIntent(kind: .window)
        case .display:
            return try ScreenshotCaptureIntent(
                kind: .display,
                displayScope: input.displayScope?.coreScope ?? .current
            )
        }
    }

    private func prepareForNewCapture() async -> Bool {
        let supersededContext = activeEditorApplicationContext
        supersededContext?.suppressRestoration()
        guard await editorPresenter.prepareForNewCapture() else {
            supersededContext?.resumeRestoration()
            return false
        }
        clearActiveEditorApplicationContext(ifMatching: supersededContext)
        return true
    }

    private func clearActiveEditorApplicationContext(
        ifMatching context: ScreenshotApplicationContextRestorer?
    ) {
        guard let context,
              activeEditorApplicationContext === context else { return }
        activeEditorApplicationContext = nil
    }

    private func finishDeferredScrollingSession(
        for capture: ScreenshotCapture,
        terminal: ScrollingScreenshotSessionTerminal,
        isCurrent: @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> Bool {
        guard isCurrent() else { return false }
        guard capture.defersOutputUntilEditorCompletion,
              let sessionID = capture.scrollingSessionID else { return true }
        guard let scrollingSessionController else {
            recordScrollingCleanupFailure()
            return false
        }
        let result = await scrollingSessionController.finishScrollingEditingSession(
            sessionID: sessionID,
            terminal: terminal
        )
        guard isCurrent() else { return false }
        if result.accepted {
            return true
        }
        if result.failure != .alreadyTerminal {
            recordScrollingCleanupFailure()
        }
        return false
    }

    private func recordScrollingCleanupFailure() {
        recordScreenshotFailure(
            title: L10n.string("status.failed.title"),
            detail: L10n.string("screenshot.scrolling.error.writeFailed"),
            deduplicationKey: "screenshot.scrolling.cleanup"
        )
    }

    private nonisolated static func write(
        _ image: CGImage,
        format: ScreenshotCaptureFormat,
        jpegQuality: Double,
        to file: FileHandle,
        admission: ScreenshotOutputFileWriteAdmission,
        beforeOutputFileWriteAdmission: (@Sendable () async -> Void)?,
        afterOutputFileWriteAdmission: (@Sendable () async -> Void)?,
        afterOutputFileSynchronized: (@Sendable () async -> Void)?
    ) async throws {
        let writeTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let encoder = ScreenshotImageEncoder()
            let data = switch format {
            case .png: try encoder.pngData(image)
            case .jpeg: try encoder.jpegData(image, quality: jpegQuality)
            }
            try Task.checkCancellation()
            await beforeOutputFileWriteAdmission?()
            // No cancellation check is permitted after this successful lease:
            // runtime revocation can no longer override an admitted file sink.
            _ = try admission.acquireLease()
#if DEBUG
            await afterOutputFileWriteAdmission?()
#endif
            try file.seek(toOffset: 0)
            try file.truncate(atOffset: 0)
            try file.write(contentsOf: data)
            try file.synchronize()
            await afterOutputFileSynchronized?()
        }
        try await withTaskCancellationHandler {
            try await writeTask.value
        } onCancel: {
            writeTask.cancel()
        }
    }

    private func applyingWatermarkSelection(
        _ selection: ScreenshotCaptureWatermarkSelection,
        to capture: ScreenshotCapture,
        rendersImmediately: Bool
    ) throws -> ScreenshotCapture {
        let presetID: UUID? = switch selection {
        case .default: capture.watermarkPresetID
        case .none: nil
        case let .presetID(id): id
        }
        let preset = presetID.flatMap { id in
            preferencesStore.preferences.watermarkPresets.first(where: { $0.id == id })
        }
        if presetID != nil, preset == nil {
            throw ScreenshotActionExecutionError.watermarkPresetNotFound
        }

        var outputImage = capture.image
        if rendersImmediately, let preset {
            guard let source = capture.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ScreenshotActionExecutionError.missingImage
            }
            let bounds = ScreenshotPixelRect(x: 0, y: 0, width: source.width, height: source.height)
            let element = ScreenshotElement(
                kind: .watermark,
                geometry: .rect(bounds),
                watermark: ScreenshotWatermarkInstance(
                    presetID: preset.id,
                    name: preset.name,
                    style: preset.style
                )
            )
            let rendered = try ScreenshotRenderer().render(
                source: source,
                snapshot: ScreenshotSceneSnapshot(cropRect: bounds, elements: [element])
            )
            outputImage = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
        }
        return ScreenshotCapture(
            id: capture.id,
            image: outputImage,
            pixelSize: capture.pixelSize,
            sourceRect: capture.sourceRect,
            kind: capture.kind,
            displayScope: capture.displayScope,
            sourceSummary: capture.sourceSummary,
            editingContext: capture.editingContext,
            defersOutputUntilEditorCompletion: capture.defersOutputUntilEditorCompletion,
            scrollingSessionID: capture.scrollingSessionID,
            watermarkPresetID: presetID,
            selectionSurfaceHandoff: capture.selectionSurfaceHandoff
        )
    }

    private func screenRecordingMissingStatus(_ snapshot: PermissionStateSnapshot) -> AppStatus {
        AppStatus(
            kind: .permissionMissing,
            title: L10n.string("status.screenRecordingRequired.title"),
            detail: snapshot.screenRecordingRestartLikely
                ? L10n.string("status.screenRecordingRestartRequired.detail")
                : L10n.string("status.screenRecordingRequired.detail")
        )
    }

    private func recordFinalOutputStatus(
        _ result: ScreenshotFinalOutputResult,
        capture: ScreenshotCapture
    ) {
        switch (result.pasteboard, result.archive) {
        case (.failed, .failed):
            recordScreenshotFailure(
                title: L10n.string("status.failed.title"),
                detail: L10n.string("screenshot.history.outputBothFailed"),
                deduplicationKey: "screenshot.output.both-failed",
                sourceRect: capture.sourceRect
            )
        case (.failed, _):
            recordScreenshotFailure(
                title: L10n.string("screenshot.result.copyFailed"),
                detail: L10n.string("screenshot.history.outputCopyFailed"),
                deduplicationKey: "screenshot.output.copy-failed",
                sourceRect: capture.sourceRect
            )
        case (_, .failed):
            recordScreenshotFailure(
                title: L10n.string("screenshot.history.saveFailed"),
                detail: L10n.string("screenshot.history.saveFailedDetail"),
                deduplicationKey: "screenshot.output.archive-failed",
                sourceRect: capture.sourceRect
            )
        default:
            break
        }
    }

    private func recordScreenshotFailure(
        title: String,
        detail: String,
        deduplicationKey: String,
        sourceRect: CGRect? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        guard isCurrent() else { return }
        dispatchPluginFailure(
            code: deduplicationKey,
            message: detail,
            sourceRect: sourceRect,
            isCurrent: isCurrent
        )
        statusRecorder(AppStatus(kind: .failed, title: title, detail: detail))
        notificationPresenter?.present(
            BlocksNotificationDescriptor(
                level: .error,
                title: title,
                detail: detail,
                deduplicationKey: deduplicationKey
            ),
            on: notificationScreen(for: sourceRect),
            avoiding: []
        )
    }

    private func pluginCapturePayload(
        _ capture: ScreenshotCapture
    ) -> [String: JSONValue] {
        [
            "capture_id": .string(capture.id),
            "kind": .string(String(describing: capture.kind)),
            "pixel_width": .int(Int(capture.pixelSize.width)),
            "pixel_height": .int(Int(capture.pixelSize.height)),
            "is_scrolling": .bool(capture.scrollingSessionID != nil),
        ]
    }

    private func dispatchPluginFailure(
        code: String,
        message: String,
        sourceRect: CGRect?,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        Task { @MainActor [dispatchPluginEvent] in
            guard isCurrent() else { return }
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .screenshotCaptureFailed,
                    payload: [
                        "code": .string(code),
                        "message": .string(message),
                        "has_source_rect": .bool(sourceRect != nil),
                    ]
                )
            )
        }
    }

    private func notificationScreen(for sourceRect: CGRect?) -> NSScreen? {
        if let sourceRect {
            return NSScreen.screens.max { lhs, rhs in
                lhs.frame.intersection(sourceRect).area
                    < rhs.frame.intersection(sourceRect).area
            }
        }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
    }

}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

private extension ScrollingScreenshotRuntimeSnapshot {
    var actionState: ScreenshotScrollingSessionState? {
        switch state {
        case .idle: nil
        case .selecting: .selecting
        case .capturing: .capturing
        case .recovering: .recovering
        case .paused: .paused
        case .possibleEnd: .possibleEnd
        case .finalizing: .finishing
        case .editing: .completed
        }
    }
}

extension ScreenCaptureKitAdapter: ScreenshotCapturing {}
extension ScreenshotEditorPresenter: ScreenshotEditorPresenting {}

enum ScreenshotActionExecutionError: Error {
    case cancelled
    case editorFailed(String)
    case missingImage
    case sessionInProgress
    case featureDisabled
    case watermarkPresetNotFound
}

@MainActor
final class ScreenshotSessionGate {
    private var owner: UUID?

    func begin(owner: UUID) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        return true
    }

    func end(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
    }

    func invalidate() {
        owner = nil
    }
}

private extension ScreenshotResolvedCaptureKind {
    var actionKind: ScreenshotCaptureActionResolvedKind {
        switch self {
        case .region: .region
        case .window: .window
        case .display: .display
        }
    }
}

private extension ScreenshotCaptureActionDisplayScope {
    var coreScope: ScreenshotDisplayScope {
        switch self {
        case .current: .current
        case .all: .all
        case let .displayID(id): .displayID(id)
        }
    }
}

private extension ScreenshotDisplayScope {
    var actionScope: ScreenshotCaptureActionDisplayScope {
        switch self {
        case .current: .current
        case .all: .all
        case let .displayID(id): .displayID(id)
        }
    }
}

private extension ScreenshotOutputSinkStatus {
    var actionStatus: ScreenshotActionSinkStatus {
        switch self {
        case .notRequested: .notRequested
        case .succeeded: .succeeded
        case .failed: .failed
        }
    }
}
