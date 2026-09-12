import AppKit
import BlocksCore
import BlocksScreenshotCore
import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit

private struct ScreenshotDisplayGeometryContext {
    let bridge: ScreenshotCoordinateBridge
    let geometries: [ScreenshotDisplayGeometry]

    var descriptors: [ScreenshotDisplayDescriptor] {
        geometries.map { geometry in
            ScreenshotDisplayDescriptor(
                id: geometry.id,
                selectionFrame: geometry.appKitFrame.selectionRect,
                backingScale: Double(geometry.backingScale)
            )
        }
    }
}

private enum ScreenshotCaptureExclusion {
    case application(SCRunningApplication)
    case windows([SCWindow])
}

/// Owns exactly one ScreenCaptureKit single-frame request. The system request is
/// allowed to outlive its caller, so terminal state is locked separately from
/// the adapter's main-actor state and only the first terminal outcome resumes.
private final class ScreenshotSingleFrameRequestOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let onRelease: (@Sendable () -> Void)?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var earlyOutcome: Result<CGImage, Error>?
    private var isTerminal = false
    private var producerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    init(onRelease: (@Sendable () -> Void)? = nil) {
        self.onRelease = onRelease
    }

    deinit {
        onRelease?()
    }

    /// Claims the request before either unstructured task is started. A terminal
    /// outcome that won before installation resumes this continuation directly
    /// and prevents the caller from starting unnecessary work.
    func install(_ continuation: CheckedContinuation<CGImage, Error>) -> Bool {
        lock.lock()
        if let earlyOutcome {
            self.earlyOutcome = nil
            lock.unlock()
            continuation.resume(with: earlyOutcome)
            return false
        }
        guard !isTerminal else {
            lock.unlock()
            continuation.resume(throwing: ScreenshotCaptureError.cancelled)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setProducerTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = isTerminal
        if !shouldCancel {
            producerTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func setWatchdogTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = isTerminal
        if !shouldCancel {
            watchdogTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func succeed(_ image: CGImage) {
        finish(.success(image), cancelProducer: false, cancelWatchdog: true)
    }

    func fail(_ error: Error) {
        finish(.failure(error), cancelProducer: false, cancelWatchdog: true)
    }

    func cancel() {
        finish(.failure(ScreenshotCaptureError.cancelled), cancelProducer: true, cancelWatchdog: true)
    }

    func timeout() {
        finish(.failure(ScreenshotCaptureError.timedOut), cancelProducer: true, cancelWatchdog: false)
    }

    private func finish(
        _ outcome: Result<CGImage, Error>,
        cancelProducer: Bool,
        cancelWatchdog: Bool
    ) {
        lock.lock()
        guard !isTerminal else {
            lock.unlock()
            return
        }
        isTerminal = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            earlyOutcome = outcome
        }
        let producerTask = self.producerTask
        self.producerTask = nil
        let watchdogTask = self.watchdogTask
        self.watchdogTask = nil
        lock.unlock()
        if cancelProducer {
            producerTask?.cancel()
        }
        if cancelWatchdog {
            watchdogTask?.cancel()
        }
        continuation?.resume(with: outcome)
    }
}

enum ScreenshotCaptureError: LocalizedError {
    case cancelled
    case timedOut
    case selectionTooSmall
    case displayNotFound
    case noCandidateWindow
    case windowDisplayNotFound
    case editingContextUnavailable
    case screenRecordingPermissionMissing
    case inputMonitoringPermissionMissing
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            L10n.string("error.selectionCancelled")
        case .timedOut:
            L10n.string("error.selectionTimedOut")
        case .selectionTooSmall:
            L10n.string("error.selectionTooSmall")
        case .displayNotFound:
            L10n.string("error.displayNotFound")
        case .noCandidateWindow:
            L10n.string("error.noCandidateWindow")
        case .windowDisplayNotFound:
            L10n.string("error.windowDisplayNotFound")
        case .editingContextUnavailable:
            L10n.string("error.editingContextUnavailable")
        case .screenRecordingPermissionMissing:
            L10n.string("status.screenRecordingRequired.detail")
        case .inputMonitoringPermissionMissing:
            L10n.string("screenshot.scrolling.permission.required")
        case let .captureFailed(message):
            message
        }
    }
}

enum ScreenshotEditingContextRequirement: Equatable {
    case bestEffort
    case required
}

enum ScreenshotCapturePurpose: Equatable, Sendable {
    case standard
    case translationOCR

    var selectionDefaultsOverride: ScreenshotCaptureDefaults? {
        switch self {
        case .standard:
            nil
        case .translationOCR:
            ScreenshotCaptureDefaults()
        }
    }

    var showsSelectionParameterToolbar: Bool {
        self == .standard
    }

    var persistsSelectionParameters: Bool {
        self == .standard
    }

    var allowsScrollingCapture: Bool {
        self == .standard
    }
}

@MainActor
protocol ScreenshotPurposeCapturing: AnyObject {
    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool,
        purpose: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture
    func cancelCurrentCapture()
}

@MainActor
final class ScreenCaptureKitAdapter: ScreenshotScrollingSessionControlling, ScreenshotScrollingModePreparing {
    private static let performanceSignposter = OSSignposter(
        subsystem: "app.blocks.app",
        category: "ScreenshotPerformance"
    )
    private let selectionController: ScreenshotSelectionController
    private let countdownController = ScreenshotCaptureCountdownController()
    private let planner = ScreenshotCapturePlanner()
    private let preferencesStore: ScreenshotPreferencesStore
    private let scrollingCaptureCoordinator: ScrollingScreenshotCaptureCoordinator
    private let logger = Logger(subsystem: "app.blocks.app", category: "ScreenshotCapture")
    private var startsNextSessionInScrollingMode = false
    // Selection has a 60-second user-facing deadline. A 15-second internal
    // deadline keeps an unresponsive one-shot ScreenCaptureKit request from
    // holding that session gate indefinitely without changing UI copy.
    private static let singleFrameCaptureDeadline = Duration.seconds(15)
    private var activeSingleFrameRequests: [UUID: ScreenshotSingleFrameRequestOwner] = [:]

    init(preferencesStore: ScreenshotPreferencesStore? = nil) {
        let scrollingHUD = ScrollingScreenshotHUDController()
        self.preferencesStore = preferencesStore ?? ScreenshotPreferencesStore()
        selectionController = ScreenshotSelectionController(scrollingHUD: scrollingHUD)
        scrollingCaptureCoordinator = ScrollingScreenshotCaptureCoordinator(hud: scrollingHUD)
    }

    static func bestEffortEditingContext(
        _ build: () async throws -> ScreenshotEditingContext
    ) async -> ScreenshotEditingContext? {
        do {
            return try await build()
        } catch {
            return nil
        }
    }

    static func editingContext(
        requirement: ScreenshotEditingContextRequirement,
        _ build: () async throws -> ScreenshotEditingContext
    ) async throws -> ScreenshotEditingContext? {
        do {
            return try await build()
        } catch {
            guard requirement == .required else { return nil }
            throw ScreenshotCaptureError.editingContextUnavailable
        }
    }

    func cancelCurrentCapture() {
        invalidateActiveSingleFrameRequests()
        selectionController.cancel()
        countdownController.cancel()
        scrollingCaptureCoordinator.cancelCurrentSession()
    }

    func prepareScrollingModeForNextCapture() {
        startsNextSessionInScrollingMode = true
    }

    func cancelPreparedScrollingModeForNextCapture() {
        startsNextSessionInScrollingMode = false
    }

    func scrollingSessionStatus() async -> ScrollingScreenshotRuntimeSnapshot {
        let captureSnapshot = await scrollingCaptureCoordinator.status()
        return captureSnapshot.sessionID == nil
            ? (selectionController.scrollingSelectionStatus() ?? captureSnapshot)
            : captureSnapshot
    }

    func finishScrollingSession(sessionID: String) -> Bool {
        scrollingCaptureCoordinator.finishFromAction(sessionID: sessionID).accepted
    }

    func cancelScrollingSession(
        sessionID: String,
        confirm: Bool
    ) async -> ScrollingScreenshotControlResult {
        let result = await scrollingCaptureCoordinator.cancelFromAction(
            sessionID: sessionID,
            confirm: confirm
        )
        if result.accepted {
            return result
        }
        if selectionController.cancelScrollingSelection(sessionID: sessionID, confirm: confirm) {
            return .accepted(state: .idle)
        }
        return result
    }

    func finishScrollingEditingSession(
        sessionID: String,
        terminal: ScrollingScreenshotSessionTerminal
    ) async -> ScrollingScreenshotControlResult {
        await scrollingCaptureCoordinator.finishEditingSession(
            sessionID: sessionID,
            terminal: terminal
        )
    }

    static let interactiveEditingContextRequirement = ScreenshotEditingContextRequirement.required

    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool
    ) async throws -> ScreenshotCapture {
        try await capture(
            intent: intent,
            requiresEditingContext: requiresEditingContext,
            purpose: .standard
        )
    }

    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool,
        purpose: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture {
        // Freeze the user's ordinary foreground window before any suspension or
        // selection UI can change the app's main/key window identity.
        let originatingApplication = NSWorkspace.shared.frontmostApplication
        let allowedOwnWindowID = Self.allowedOwnCaptureWindowID(
            frontmostProcessID: originatingApplication?.processIdentifier,
            ownProcessID: ProcessInfo.processInfo.processIdentifier,
            mainWindow: NSApp.mainWindow.map(Self.ownCaptureWindowSnapshot),
            keyWindow: NSApp.keyWindow.map(Self.ownCaptureWindowSnapshot)
        )
        // A replacement must make any previous ScreenCaptureKit one-shot
        // completion stale before it can compose a capture result.
        invalidateActiveSingleFrameRequests()
        Self.performanceSignposter.emitEvent(
            "Shortcut",
            "intent=\(intent.kind.rawValue, privacy: .public)"
        )
        let editingContextRequirement: ScreenshotEditingContextRequirement = requiresEditingContext
            ? .required
            : .bestEffort
        selectionController.applyDefaults(
            purpose.selectionDefaultsOverride
                ?? preferencesStore.preferences.captureDefaults
        )
        let startsInScrollingMode = purpose.allowsScrollingCapture
            && startsNextSessionInScrollingMode
        startsNextSessionInScrollingMode = false
        let content = try await loadShareableContent()
        let displayContext = try makeDisplayGeometryContext(for: content.displays)
        let displayDescriptors = displayContext.descriptors
        let initialOwnApplication = captureExcludedApplication(in: content)
        let initialExclusion = resolvedCaptureExclusion(
            in: content,
            allowedOwnWindowID: allowedOwnWindowID
        )

        switch intent.kind {
        case .display:
            let scope = intent.displayScope ?? .current
            switch scope {
            case .all:
                return try await captureDisplayPlan(
                    planner.planDisplays(
                        scope: .all,
                        currentDisplayID: currentDisplayID() ?? 0,
                        displays: displayDescriptors
                    ),
                    content: content,
                    descriptors: displayDescriptors,
                    exclusion: initialExclusion,
                    displayScope: .all,
                    editingContextRequirement: editingContextRequirement
                )
            case let .displayID(id):
                return try await captureDisplayPlan(
                    planner.planDisplays(scope: .displayID(id), currentDisplayID: id, displays: displayDescriptors),
                    content: content,
                    descriptors: displayDescriptors,
                    exclusion: initialExclusion,
                    displayScope: .displayID(id),
                    editingContextRequirement: editingContextRequirement
                )
            case .current:
                let displayID = currentDisplayID() ?? content.displays.first?.displayID ?? 0
                return try await captureDisplayPlan(
                    planner.planDisplays(
                        scope: .displayID(displayID),
                        currentDisplayID: displayID,
                        displays: displayDescriptors
                    ),
                    content: content,
                    descriptors: displayDescriptors,
                    exclusion: initialExclusion,
                    displayScope: .displayID(displayID),
                    editingContextRequirement: editingContextRequirement
                )
            }
        case .smart, .region, .window:
            break
        }

        let initialWindowMetadata = frontToBackWindowMetadata()
        let candidateWindows = windowCandidates(
            from: content.windows,
            allowedOwnWindowID: allowedOwnWindowID,
            windowMetadata: initialWindowMetadata
        )
        let windowsByID = Dictionary(uniqueKeysWithValues: candidateWindows.map { ($0.windowID, $0) })
        let candidateWindowIDs = Set(windowsByID.keys)
        let initialSelectionCandidates = selectionCandidates(
            from: content.windows,
            bridge: displayContext.bridge,
            selectableWindowIDs: candidateWindowIDs,
            allowedOwnWindowID: allowedOwnWindowID,
            windowMetadata: initialWindowMetadata
        )
        let selectionCandidatesByID = Dictionary(uniqueKeysWithValues: initialSelectionCandidates.map { ($0.id, $0) })
        if intent.kind == .window, windowsByID.isEmpty {
            throw ScreenshotCaptureError.noCandidateWindow
        }
        var usesInitialFrozenCatalog = selectionController.parameters.freezesFrame
        let selection = await selectionController.select(
            intent: intent,
            candidates: initialSelectionCandidates,
            displays: displayContext.geometries.enumerated().map(selectionDisplay),
            frozenSnapshotProvider: { [weak self] showsCursor in
                guard let self else { throw ScreenshotCaptureError.captureFailed("Capture service unavailable.") }
                if usesInitialFrozenCatalog {
                    usesInitialFrozenCatalog = false
                    return try await self.captureFrozenSelectionSnapshot(
                        content: content,
                        showsCursor: showsCursor,
                        allowedWindowIDs: candidateWindowIDs,
                        expectedDisplays: displayDescriptors,
                        allowedOwnWindowID: allowedOwnWindowID,
                        exclusion: initialExclusion
                    )
                }
                return try await self.captureFrozenSelectionSnapshot(
                    showsCursor: showsCursor,
                    allowedWindowIDs: candidateWindowIDs,
                    expectedDisplays: displayDescriptors,
                    allowedOwnWindowID: allowedOwnWindowID
                )
            },
            magnifierSnapshotProvider: { [weak self] in
                guard let self else { throw ScreenshotCaptureError.captureFailed("Capture service unavailable.") }
                return try await self.captureFreshDisplaySnapshots(
                    showsCursor: false,
                    allowedOwnWindowID: allowedOwnWindowID
                )
            },
            onParametersChanged: { [weak preferencesStore] parameters in
                guard purpose.persistsSelectionParameters else { return }
                preferencesStore?.updateCaptureDefaultsFromSession(parameters.captureDefaults)
            },
            customConstraints: purpose.showsSelectionParameterToolbar
                ? preferencesStore.preferences.customConstraints
                : [],
            watermarkPresets: purpose.showsSelectionParameterToolbar
                ? preferencesStore.preferences.watermarkPresets
                : [],
            onSaveCustomConstraint: { [weak preferencesStore] constraint in
                guard purpose.persistsSelectionParameters else { return }
                preferencesStore?.saveCustomConstraint(constraint)
            },
            onDeleteCustomConstraint: { [weak preferencesStore] id in
                guard purpose.persistsSelectionParameters else { return }
                preferencesStore?.removeCustomConstraint(id: id)
            },
            showsParameterToolbar: purpose.showsSelectionParameterToolbar,
            startsInScrollingMode: startsInScrollingMode,
            timeout: 60
        )
        Self.performanceSignposter.emitEvent(
            "SelectionFinished",
            "frozen=\(self.selectionController.parameters.freezesFrame, privacy: .public)"
        )
        var transfersSelectionSurface = false
        defer {
            if !transfersSelectionSurface {
                selectionController.dismissSelectionSurfaces()
                selectionController.clearRetainedSelectionSurfaceWindowIDs()
            }
        }
        if case .screenRecordingPermissionMissing = selection {
            throw ScreenshotCaptureError.screenRecordingPermissionMissing
        }
        if case .inputMonitoringPermissionMissing = selection {
            throw ScreenshotCaptureError.inputMonitoringPermissionMissing
        }
        switch selection {
        case .cancelled:
            throw ScreenshotCaptureError.cancelled
        case .timedOut:
            throw ScreenshotCaptureError.timedOut
        case .snapshotFailed:
            throw ScreenshotCaptureError.captureFailed(
                L10n.string("status.failed.detail")
            )
        case .screenRecordingPermissionMissing:
            throw ScreenshotCaptureError.screenRecordingPermissionMissing
        case .inputMonitoringPermissionMissing:
            throw ScreenshotCaptureError.inputMonitoringPermissionMissing
        case .window, .region, .scrollingRegion, .display, .allDisplays:
            break
        }
        let parameters = selectionController.parameters
        let selectedFrozenSnapshot = parameters.freezesFrame
            ? selectionController.consumeResultFrozenSnapshot()
            : nil
        let captureContent: SCShareableContent
        let captureExclusion: ScreenshotCaptureExclusion
        if selectedFrozenSnapshot != nil {
            // The frozen images were captured before the selection surfaces
            // appeared. Reusing the original content avoids a second
            // ScreenCaptureKit query between mouse-up and editor creation.
            captureContent = content
            captureExclusion = initialExclusion
        } else if allowedOwnWindowID == nil, let initialOwnApplication {
            // An application exclusion keeps the already-created selection surfaces
            // out of the capture without another shareable-content directory query.
            captureContent = content
            captureExclusion = .application(initialOwnApplication)
        } else {
            let surfaceSnapshot = try await Self.captureSurfaceHandoff(
                selectionSurfaceWindowIDs:
                    selectionController.selectionSurfaceWindowIDs,
                load: { [self] in
                    let captureContent = try await loadShareableContent()
                    return (
                        captureContent,
                        captureContent.windows.map { ($0.windowID, $0) }
                    )
                }
            )
            captureContent = surfaceSnapshot.content
            captureExclusion = .windows(
                captureExcludedWindows(
                    in: surfaceSnapshot.content,
                    allowedOwnWindowID: allowedOwnWindowID
                )
            )
        }
        let captureDisplayContext = try makeDisplayGeometryContext(for: captureContent.displays)
        let captureDisplayDescriptors = captureDisplayContext.descriptors
        // The handoff snapshot contains both the temporary selection surfaces and any
        // persistent Blocks windows that may become visible again once the overlay closes.
        // Exclude them from the pixels and editor source, except the ordinary
        // foreground window whose identity was frozen at capture entry.
        let selectedFrozenSnapshots: [UInt32: CGImage]
        if let selectedFrozenSnapshot {
            let compatible = Self.compatibleFrozenImages(
                selectedFrozenSnapshot,
                liveDescriptors: captureDisplayDescriptors
            )
            guard compatible.count == selectedFrozenSnapshot.images.count else {
                if editingContextRequirement == .required {
                    throw ScreenshotCaptureError.editingContextUnavailable
                }
                throw ScreenshotCaptureError.captureFailed(
                    "The display layout changed before the frozen screenshot completed."
                )
            }
            selectedFrozenSnapshots = compatible
        } else {
            selectedFrozenSnapshots = [:]
        }
        let selectionSurfaceHandoff: ScreenshotSelectionSurfaceHandoff?
        if requiresEditingContext {
            transfersSelectionSurface = true
            selectionSurfaceHandoff = ScreenshotSelectionSurfaceHandoff {
                self.selectionController.dismissSelectionSurfaces()
                self.selectionController.clearRetainedSelectionSurfaceWindowIDs()
            }
        } else {
            selectionSurfaceHandoff = nil
        }
        func finalizeInteractiveCapture(
            _ capture: ScreenshotCapture
        ) -> ScreenshotCapture {
            guard let selectionSurfaceHandoff else { return capture }
            if let context = capture.editingContext {
                selectionController.prepareHandoffFrame(
                    from: context,
                    captureID: capture.id
                )
            }
            return capture.attachingSelectionSurfaceHandoff(
                selectionSurfaceHandoff
            )
        }
        if purpose.persistsSelectionParameters {
            preferencesStore.updateCaptureDefaultsFromSession(parameters.captureDefaults)
        }
        if parameters.delaySeconds > 0 {
            let completed = await countdownController.run(
                seconds: parameters.delaySeconds,
                targetRect: countdownTargetRect(
                    for: selection,
                    candidatesByID: selectionCandidatesByID,
                    displays: displayContext.geometries
                )
            )
            guard completed else { throw ScreenshotCaptureError.cancelled }
        }

        switch selection {
        case let .window(windowID):
            guard let originalWindow = windowsByID[windowID] else {
                throw ScreenshotCaptureError.noCandidateWindow
            }
            let windowContent: SCShareableContent
            let windowContext: ScreenshotDisplayGeometryContext
            let windowCandidate: ScreenshotSelectionCandidate
            let windowExclusion: ScreenshotCaptureExclusion
            if let selectedFrozenSnapshot,
               let frozenCandidate = selectedFrozenSnapshot.candidates.first(
                   where: { $0.id == windowID }
               ) {
                windowContent = captureContent
                windowContext = captureDisplayContext
                windowCandidate = frozenCandidate
                windowExclusion = captureExclusion
            } else if parameters.delaySeconds > 0 {
                let delayedContent = try await loadShareableContent()
                let delayedContext = try makeDisplayGeometryContext(
                    for: delayedContent.displays
                )
                let metadata = frontToBackWindowMetadata()
                let liveWindows = windowCandidates(
                    from: delayedContent.windows,
                    allowedOwnWindowID: allowedOwnWindowID,
                    windowMetadata: metadata
                )
                let liveWindowIDs = Set(liveWindows.map(\.windowID))
                guard let liveCandidate = selectionCandidates(
                    from: delayedContent.windows,
                    bridge: delayedContext.bridge,
                    selectableWindowIDs: liveWindowIDs,
                    allowedOwnWindowID: allowedOwnWindowID,
                    windowMetadata: metadata
                ).first(where: { $0.id == windowID }) else {
                    throw ScreenshotCaptureError.noCandidateWindow
                }
                windowContent = delayedContent
                windowContext = delayedContext
                windowCandidate = liveCandidate
                windowExclusion = resolvedCaptureExclusion(
                    in: delayedContent,
                    allowedOwnWindowID: allowedOwnWindowID
                )
            } else {
                guard let candidate = selectionCandidatesByID[windowID] else {
                    throw ScreenshotCaptureError.noCandidateWindow
                }
                windowContent = captureContent
                windowContext = captureDisplayContext
                windowCandidate = candidate
                windowExclusion = captureExclusion
            }
            let capture = try await captureWindowFromDisplaySnapshot(
                planner.planWindow(
                    ScreenshotWindowCandidate(
                        id: windowID,
                        frame: windowCandidate.frame.selectionRect
                    ),
                    displays: windowContext.descriptors
                ),
                selectionFrame: windowCandidate.frame,
                sourceApplicationName:
                    originalWindow.owningApplication?.applicationName,
                content: windowContent,
                descriptors: windowContext.descriptors,
                frozenSnapshots: Self.compatibleFrozenImages(
                    selectedFrozenSnapshot,
                    liveDescriptors: windowContext.descriptors
                ),
                exclusion: windowExclusion,
                editingContextRequirement: editingContextRequirement
            )
            return finalizeInteractiveCapture(capture)

        case let .region(rect):
            guard rect.width >= 8, rect.height >= 8 else {
                throw ScreenshotCaptureError.selectionTooSmall
            }
            let capture = try await captureRegion(
                planner.planRegion(rect.selectionRect, displays: captureDisplayDescriptors),
                content: captureContent,
                descriptors: captureDisplayDescriptors,
                frozenSnapshots: selectedFrozenSnapshots,
                exclusion: captureExclusion,
                editingContextRequirement: editingContextRequirement
            )
            return finalizeInteractiveCapture(capture)

        case let .scrollingRegion(rect, displayID, sessionID):
            selectionSurfaceHandoff?.complete()
            guard let geometry = captureDisplayContext.geometries.first(where: { $0.id == displayID }) else {
                throw ScreenshotCaptureError.displayNotFound
            }
            let targetApplication = scrollingTargetApplication(
                selectionRect: rect,
                windows: captureContent.windows,
                bridge: captureDisplayContext.bridge
            ) ?? originatingApplication.flatMap { application in
                application.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : application
            }
            let image = try await scrollingCaptureCoordinator.capture(
                sessionID: sessionID,
                displayID: displayID,
                displayFrame: geometry.appKitFrame,
                selectionRect: rect,
                backingScale: geometry.backingScale,
                originatingApplication: targetApplication
            )
            return try makeScrollingCapture(
                image: image,
                selectionRect: rect,
                display: geometry,
                sessionID: sessionID
            )

        case let .display(displayID):
            let capture = try await captureDisplayPlan(
                planner.planDisplays(
                    scope: .displayID(displayID),
                    currentDisplayID: displayID,
                    displays: captureDisplayDescriptors
                ),
                content: captureContent,
                descriptors: captureDisplayDescriptors,
                frozenSnapshots: selectedFrozenSnapshots,
                exclusion: captureExclusion,
                displayScope: .displayID(displayID),
                editingContextRequirement: editingContextRequirement
            )
            return finalizeInteractiveCapture(capture)

        case .allDisplays:
            let capture = try await captureDisplayPlan(
                planner.planDisplays(
                    scope: .all,
                    currentDisplayID: currentDisplayID() ?? 0,
                    displays: captureDisplayDescriptors
                ),
                content: captureContent,
                descriptors: captureDisplayDescriptors,
                frozenSnapshots: selectedFrozenSnapshots,
                exclusion: captureExclusion,
                displayScope: .all,
                editingContextRequirement: editingContextRequirement
            )
            return finalizeInteractiveCapture(capture)

        case .cancelled:
            throw ScreenshotCaptureError.cancelled
        case .timedOut:
            throw ScreenshotCaptureError.timedOut
        case .snapshotFailed:
            throw ScreenshotCaptureError.captureFailed(L10n.string("status.failed.detail"))
        case .screenRecordingPermissionMissing:
            throw ScreenshotCaptureError.screenRecordingPermissionMissing
        case .inputMonitoringPermissionMissing:
            throw ScreenshotCaptureError.inputMonitoringPermissionMissing
        }
    }

    private func makeScrollingCapture(
        image: CGImage,
        selectionRect: CGRect,
        display: ScreenshotDisplayGeometry,
        sessionID: String
    ) throws -> ScreenshotCapture {
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: image.width, height: image.height)
        let editingContext = ScreenshotEditingContext(
            sourceContext: ScreenshotSourceContext(
                sourceBounds: bounds,
                tileDescriptors: [ScreenshotSourceTileDescriptor(id: "scrolling-final", bounds: bounds)],
                compositeSource: image
            ),
            sourceFrame: display.appKitFrame,
            screens: [ScreenshotEditingScreen(displayID: display.id, frame: display.appKitFrame)],
            initialCropRect: bounds,
            supportsRangeExpansion: false
        )
        return ScreenshotCapture(
            id: makeCaptureID(),
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            pixelSize: CGSize(width: image.width, height: image.height),
            sourceRect: selectionRect,
            kind: .region,
            displayScope: .displayID(display.id),
            sourceSummary: L10n.format("screenshot.scrolling.source", image.width, image.height),
            editingContext: editingContext,
            defersOutputUntilEditorCompletion: true,
            scrollingSessionID: sessionID,
            watermarkPresetID: selectionController.parameters.watermarkPresetID
        )
    }

    private func countdownTargetRect(
        for selection: ScreenshotSelectionResult,
        candidatesByID: [UInt32: ScreenshotSelectionCandidate],
        displays: [ScreenshotDisplayGeometry]
    ) -> CGRect {
        switch selection {
        case let .window(id):
            return candidatesByID[id]?.frame ?? .zero
        case let .region(frame):
            return frame
        case let .scrollingRegion(frame, _, _):
            return frame
        case let .display(id):
            return displays.first(where: { $0.id == id })?.appKitFrame ?? .zero
        case .allDisplays:
            return displays.map(\.appKitFrame).reduce(CGRect.null) { $0.union($1) }
        case .cancelled,
             .timedOut,
             .snapshotFailed,
             .screenRecordingPermissionMissing,
             .inputMonitoringPermissionMissing:
            return NSScreen.main?.visibleFrame ?? .zero
        }
    }

    private func captureRegion(
        _ plan: ScreenshotCapturePlan,
        content: SCShareableContent,
        descriptors: [ScreenshotDisplayDescriptor],
        frozenSnapshots: [UInt32: CGImage] = [:],
        exclusion: ScreenshotCaptureExclusion? = nil,
        editingContextRequirement: ScreenshotEditingContextRequirement
    ) async throws -> ScreenshotCapture {
        let editingSnapshots = await snapshotsForCaptureContext(
            plan: plan,
            content: content,
            descriptors: descriptors,
            availableSnapshots: frozenSnapshots,
            exclusion: exclusion
        )
        let image = try await capture(
            plan: plan,
            content: content,
            descriptors: descriptors,
            frozenSnapshots: editingSnapshots,
            exclusion: exclusion
        )
        let editingContext = try await makeEditingContext(
            plan: plan,
            content: nil,
            descriptors: descriptors,
            availableSnapshots: editingSnapshots,
            exclusion: exclusion,
            initialRegionConstraint: selectionController.parameters.constraint.aspectConstraint,
            requirement: editingContextRequirement
        )
        return ScreenshotCapture(
            id: makeCaptureID(),
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            pixelSize: CGSize(width: image.width, height: image.height),
            sourceRect: plan.selectionRegion.cgRect,
            kind: .region,
            displayScope: nil,
            sourceSummary: L10n.format(
                "capture.source.region",
                Int(plan.selectionRegion.width.rounded()),
                Int(plan.selectionRegion.height.rounded())
            ),
            editingContext: editingContext,
            watermarkPresetID: selectionController.parameters.watermarkPresetID
        )
    }

    private func captureDisplayPlan(
        _ plan: ScreenshotCapturePlan,
        content: SCShareableContent,
        descriptors: [ScreenshotDisplayDescriptor],
        frozenSnapshots: [UInt32: CGImage] = [:],
        exclusion: ScreenshotCaptureExclusion? = nil,
        displayScope: ScreenshotDisplayScope,
        editingContextRequirement: ScreenshotEditingContextRequirement
    ) async throws -> ScreenshotCapture {
        let editingSnapshots = await snapshotsForCaptureContext(
            plan: plan,
            content: content,
            descriptors: descriptors,
            availableSnapshots: frozenSnapshots,
            exclusion: exclusion
        )
        let image = try await capture(
            plan: plan,
            content: content,
            descriptors: descriptors,
            frozenSnapshots: editingSnapshots,
            exclusion: exclusion
        )
        let editingContext = try await makeEditingContext(
            plan: plan,
            content: nil,
            descriptors: descriptors,
            availableSnapshots: editingSnapshots,
            exclusion: exclusion,
            requirement: editingContextRequirement
        )
        let sourceSummary = plan.slices.count == 1
            ? L10n.format("capture.source.display", displayIndex(plan.slices[0].displayID, in: content.displays) + 1)
            : "\(plan.slices.count) displays"
        return ScreenshotCapture(
            id: makeCaptureID(),
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            pixelSize: CGSize(width: image.width, height: image.height),
            sourceRect: plan.selectionRegion.cgRect,
            kind: .display,
            displayScope: displayScope,
            sourceSummary: sourceSummary,
            editingContext: editingContext,
            watermarkPresetID: selectionController.parameters.watermarkPresetID
        )
    }

    private func captureWindowFromDisplaySnapshot(
        _ plan: ScreenshotCapturePlan,
        selectionFrame: CGRect,
        sourceApplicationName: String?,
        content: SCShareableContent,
        descriptors: [ScreenshotDisplayDescriptor],
        frozenSnapshots: [UInt32: CGImage],
        exclusion: ScreenshotCaptureExclusion? = nil,
        editingContextRequirement: ScreenshotEditingContextRequirement
    ) async throws -> ScreenshotCapture {
        let editingSnapshots = await snapshotsForCaptureContext(
            plan: plan,
            content: content,
            descriptors: descriptors,
            availableSnapshots: frozenSnapshots,
            exclusion: exclusion
        )
        let image = try await capture(
            plan: plan,
            content: content,
            descriptors: descriptors,
            frozenSnapshots: editingSnapshots,
            exclusion: exclusion
        )
        let editingContext = try await makeEditingContext(
            plan: plan,
            content: nil,
            descriptors: descriptors,
            availableSnapshots: editingSnapshots,
            cleanCaptureImage: image,
            exclusion: exclusion,
            requirement: editingContextRequirement
        )
        return ScreenshotCapture(
            id: makeCaptureID(),
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            pixelSize: CGSize(width: image.width, height: image.height),
            sourceRect: selectionFrame,
            kind: .window,
            displayScope: nil,
            sourceSummary: L10n.format(
                "capture.source.window",
                sourceApplicationName
                    ?? L10n.string("capture.source.unknownApp")
            ),
            editingContext: editingContext,
            watermarkPresetID: selectionController.parameters.watermarkPresetID
        )
    }

    private func capture(
        plan: ScreenshotCapturePlan,
        content: SCShareableContent,
        descriptors: [ScreenshotDisplayDescriptor],
        frozenSnapshots: [UInt32: CGImage],
        exclusion: ScreenshotCaptureExclusion? = nil
    ) async throws -> CGImage {
        try await compose(plan: plan) { slice in
            guard let display = content.displays.first(where: { $0.displayID == slice.displayID }),
                  let descriptor = descriptors.first(where: { $0.id == slice.displayID }) else {
                throw ScreenshotCaptureError.displayNotFound
            }
            if !frozenSnapshots.isEmpty {
                guard let frozen = frozenSnapshots[slice.displayID],
                      let cropped = frozen.cropping(to: slice.sourcePixels.cgRect) else {
                    throw ScreenshotCaptureError.captureFailed("Frozen display pixels are unavailable.")
                }
                return cropped
            }
            let filter = captureFilter(
                display: display,
                exclusion: exclusion ?? resolvedCaptureExclusion(in: content)
            )
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(
                x: Double(slice.sourcePixels.x) / descriptor.backingScale,
                y: Double(slice.sourcePixels.y) / descriptor.backingScale,
                width: Double(slice.sourcePixels.width) / descriptor.backingScale,
                height: Double(slice.sourcePixels.height) / descriptor.backingScale
            )
            configuration.width = slice.sourcePixels.width
            configuration.height = slice.sourcePixels.height
            configuration.showsCursor = selectionController.parameters.showsCursor
            logger.debug(
                "stage=display-slice filter=display displayID=\(slice.displayID, privacy: .public) sourceX=\(configuration.sourceRect.minX, privacy: .public) sourceY=\(configuration.sourceRect.minY, privacy: .public) sourceWidth=\(configuration.sourceRect.width, privacy: .public) sourceHeight=\(configuration.sourceRect.height, privacy: .public)"
            )
            do {
                return try await captureImage(filter: filter, configuration: configuration)
            } catch {
                let nsError = error as NSError
                logger.error(
                    "stage=display-slice-failed filter=display displayID=\(slice.displayID, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
                )
                throw error
            }
        }
    }

    private func makeEditingContext(
        plan: ScreenshotCapturePlan,
        content: SCShareableContent?,
        descriptors: [ScreenshotDisplayDescriptor],
        availableSnapshots: [UInt32: CGImage],
        cleanCaptureImage: CGImage? = nil,
        exclusion: ScreenshotCaptureExclusion? = nil,
        initialRegionConstraint: ScreenshotRegionConstraint = .free,
        requirement: ScreenshotEditingContextRequirement
    ) async throws -> ScreenshotEditingContext? {
        let relevantDisplayIDs = Set(plan.slices.map(\.displayID))
        let context = try await Self.editingContext(requirement: requirement) { [self] in
            var images = availableSnapshots.filter { relevantDisplayIDs.contains($0.key) }
            let missingDisplayIDs = relevantDisplayIDs.subtracting(images.keys)
            if !missingDisplayIDs.isEmpty {
                guard let content else {
                    throw ScreenshotEditingContextError.missingDisplayImage(missingDisplayIDs.first!)
                }
                let captured = try await captureDisplaySnapshots(
                    content: content,
                    descriptors: descriptors,
                    showsCursor: selectionController.parameters.showsCursor,
                    displayIDs: missingDisplayIDs,
                    exclusion: exclusion
                )
                images.merge(captured) { current, _ in current }
            }
            return try ScreenshotEditingContextBuilder.make(
                plan: plan,
                displays: descriptors,
                displayImages: images,
                cleanCaptureImage: cleanCaptureImage,
                initialRegionConstraint: initialRegionConstraint
            )
        }
        if context == nil {
            logger.warning("stage=editing-context-unavailable captureContinues=true")
        }
        return context
    }

    static func compatibleFrozenImages(
        _ snapshot: ScreenshotFrozenSelectionSnapshot?,
        liveDescriptors: [ScreenshotDisplayDescriptor]
    ) -> [UInt32: CGImage] {
        guard let snapshot else { return [:] }
        let liveByID = Dictionary(uniqueKeysWithValues: liveDescriptors.map { ($0.id, $0) })
        let frozenByID = Dictionary(uniqueKeysWithValues: snapshot.displayDescriptors.map { ($0.id, $0) })
        return snapshot.images.filter { displayID, _ in
            guard let live = liveByID[displayID], let frozen = frozenByID[displayID] else {
                return false
            }
            return live == frozen
        }
    }

    private func snapshotsForCaptureContext(
        plan: ScreenshotCapturePlan,
        content: SCShareableContent,
        descriptors: [ScreenshotDisplayDescriptor],
        availableSnapshots: [UInt32: CGImage],
        exclusion: ScreenshotCaptureExclusion? = nil
    ) async -> [UInt32: CGImage] {
        let relevantDisplayIDs = Set(plan.slices.map(\.displayID))
        let relevantAvailable = availableSnapshots.filter { relevantDisplayIDs.contains($0.key) }
        if relevantAvailable.count == relevantDisplayIDs.count {
            return relevantAvailable
        }
        do {
            return try await captureDisplaySnapshots(
                content: content,
                descriptors: descriptors,
                showsCursor: selectionController.parameters.showsCursor,
                displayIDs: relevantDisplayIDs,
                exclusion: exclusion
            )
        } catch {
            logger.warning("stage=editing-snapshot-unavailable captureFallsBack=true")
            return [:]
        }
    }

    private func compose(
        plan: ScreenshotCapturePlan,
        imageForSlice: (ScreenshotCaptureSlice) async throws -> CGImage
    ) async throws -> CGImage {
        var tiles: [ScreenshotImageCompositeTile] = []
        tiles.reserveCapacity(plan.slices.count)
        for slice in plan.slices {
            let image = try await imageForSlice(slice)
            tiles.append(.init(image: image, destination: slice.destinationPixels))
        }
        do {
            return try ScreenshotImageCompositor.compose(size: plan.outputSize, tiles: tiles)
        } catch {
            throw ScreenshotCaptureError.captureFailed("Unable to compose screenshot.")
        }
    }

    private func captureDisplaySnapshots(
        content: SCShareableContent,
        descriptors: [ScreenshotDisplayDescriptor],
        showsCursor: Bool,
        displayIDs: Set<UInt32>? = nil,
        exclusion: ScreenshotCaptureExclusion? = nil
    ) async throws -> [UInt32: CGImage] {
        var snapshots: [UInt32: CGImage] = [:]
        let tasks: [Task<(UInt32, CGImage), Error>] = content.displays.compactMap { display in
            if let displayIDs, !displayIDs.contains(display.displayID) { return nil }
            guard let descriptor = descriptors.first(where: { $0.id == display.displayID }) else { return nil }
            return Task { @MainActor [weak self] in
                guard let self else { throw ScreenshotCaptureError.captureFailed("Capture service unavailable.") }
                let filter = self.captureFilter(
                    display: display,
                    exclusion: exclusion
                        ?? self.resolvedCaptureExclusion(in: content)
                )
                let configuration = SCStreamConfiguration()
                configuration.width = Int((display.frame.width * descriptor.backingScale).rounded())
                configuration.height = Int((display.frame.height * descriptor.backingScale).rounded())
                configuration.showsCursor = showsCursor
                return (display.displayID, try await self.captureImage(filter: filter, configuration: configuration))
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        for task in tasks {
            let (displayID, image) = try await task.value
            snapshots[displayID] = image
        }
        return snapshots
    }

    private func captureFreshDisplaySnapshots(
        showsCursor: Bool,
        allowedOwnWindowID: UInt32?
    ) async throws -> [UInt32: CGImage] {
        let content = try await loadShareableContent()
        let descriptors = try makeDisplayGeometryContext(for: content.displays).descriptors
        return try await captureDisplaySnapshots(
            content: content,
            descriptors: descriptors,
            showsCursor: showsCursor,
            exclusion: resolvedCaptureExclusion(
                in: content,
                allowedOwnWindowID: allowedOwnWindowID
            )
        )
    }

    static func captureSurfaceHandoff<Content, Window>(
        selectionSurfaceWindowIDs: Set<UInt32>,
        load: () async throws -> (Content, [(UInt32, Window)])
    ) async rethrows -> (content: Content, excludedWindows: [Window]) {
        let (content, windows) = try await load()
        return (
            content,
            windows.compactMap { id, window in
                selectionSurfaceWindowIDs.contains(id) ? window : nil
            }
        )
    }

    static func captureExcludedWindowIDs(
        availableWindowIDs: Set<UInt32>,
        selectionSurfaceWindowIDs: Set<UInt32>,
        ownWindowIDs: Set<UInt32> = [],
        allowedOwnWindowID: UInt32? = nil
    ) -> Set<UInt32> {
        var excludedOwnWindowIDs = ownWindowIDs
        if let allowedOwnWindowID {
            excludedOwnWindowIDs.remove(allowedOwnWindowID)
        }
        // Selection UI always wins, even if a stale/misclassified ID is allowed.
        return availableWindowIDs.intersection(
            selectionSurfaceWindowIDs.union(excludedOwnWindowIDs)
        )
    }

    struct OwnCaptureWindowSnapshot {
        var windowID: UInt32
        var isVisible = true
        var isMiniaturized = false
        var isNormalLevel = true
        var isTitled = true
        var isPanel = false
        var hasParent = false
    }

    private static func ownCaptureWindowSnapshot(_ window: NSWindow) -> OwnCaptureWindowSnapshot {
        OwnCaptureWindowSnapshot(
            windowID: UInt32(max(0, window.windowNumber)),
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isNormalLevel: window.level == .normal,
            isTitled: window.styleMask.contains(.titled),
            isPanel: window is NSPanel,
            hasParent: window.parent != nil
        )
    }

    static func allowedOwnCaptureWindowID(
        frontmostProcessID: pid_t?,
        ownProcessID: pid_t,
        mainWindow: OwnCaptureWindowSnapshot?,
        keyWindow: OwnCaptureWindowSnapshot?
    ) -> UInt32? {
        guard frontmostProcessID == ownProcessID else { return nil }
        return [mainWindow, keyWindow].compactMap { $0 }.first { window in
            window.windowID > 0 && window.isVisible && !window.isMiniaturized
                && window.isNormalLevel && window.isTitled && !window.isPanel
                && !window.hasParent
        }?.windowID
    }

    private func captureExcludedWindows(
        in content: SCShareableContent,
        allowedOwnWindowID: UInt32? = nil
    ) -> [SCWindow] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownWindowIDs = Set(content.windows.compactMap { window -> UInt32? in
            guard window.owningApplication?.bundleIdentifier == ownBundleID
                    || window.owningApplication?.processID == ownProcessID else { return nil }
            return window.windowID
        })
        let excludedIDs = Self.captureExcludedWindowIDs(
            availableWindowIDs: Set(content.windows.map(\.windowID)),
            selectionSurfaceWindowIDs: selectionController.selectionSurfaceWindowIDs,
            ownWindowIDs: ownWindowIDs,
            allowedOwnWindowID: allowedOwnWindowID
        )
        return content.windows.filter { excludedIDs.contains($0.windowID) }
    }

    private func captureExcludedApplication(
        in content: SCShareableContent
    ) -> SCRunningApplication? {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return content.applications.first { application in
            application.bundleIdentifier == ownBundleID
                || application.processID == ownProcessID
        }
    }

    private func resolvedCaptureExclusion(
        in content: SCShareableContent,
        allowedOwnWindowID: UInt32? = nil
    ) -> ScreenshotCaptureExclusion {
        if allowedOwnWindowID == nil,
           let application = captureExcludedApplication(in: content) {
            return .application(application)
        }
        return .windows(captureExcludedWindows(
            in: content,
            allowedOwnWindowID: allowedOwnWindowID
        ))
    }

    private func captureFilter(
        display: SCDisplay,
        exclusion: ScreenshotCaptureExclusion
    ) -> SCContentFilter {
        switch exclusion {
        case let .application(application):
            SCContentFilter(
                display: display,
                excludingApplications: [application],
                exceptingWindows: []
            )
        case let .windows(windows):
            SCContentFilter(display: display, excludingWindows: windows)
        }
    }

    private func captureFrozenSelectionSnapshot(
        showsCursor: Bool,
        allowedWindowIDs: Set<UInt32>,
        expectedDisplays: [ScreenshotDisplayDescriptor],
        allowedOwnWindowID: UInt32?
    ) async throws -> ScreenshotFrozenSelectionSnapshot {
        let content = try await loadShareableContent()
        return try await captureFrozenSelectionSnapshot(
            content: content,
            showsCursor: showsCursor,
            allowedWindowIDs: allowedWindowIDs,
            expectedDisplays: expectedDisplays,
            allowedOwnWindowID: allowedOwnWindowID,
            exclusion: resolvedCaptureExclusion(
                in: content,
                allowedOwnWindowID: allowedOwnWindowID
            )
        )
    }

    private func captureFrozenSelectionSnapshot(
        content: SCShareableContent,
        showsCursor: Bool,
        allowedWindowIDs: Set<UInt32>,
        expectedDisplays: [ScreenshotDisplayDescriptor],
        allowedOwnWindowID: UInt32?,
        exclusion: ScreenshotCaptureExclusion?
    ) async throws -> ScreenshotFrozenSelectionSnapshot {
        let displayContext = try makeDisplayGeometryContext(for: content.displays)
        let descriptors = displayContext.descriptors
        let images = try await captureDisplaySnapshots(
            content: content,
            descriptors: descriptors,
            showsCursor: showsCursor,
            exclusion: exclusion
        )
        guard descriptors.sorted(by: { $0.id < $1.id }) == expectedDisplays.sorted(by: { $0.id < $1.id }) else {
            throw ScreenshotCaptureError.captureFailed("The display layout changed while freezing the screenshot.")
        }
        let candidates = selectionCandidates(
            from: content.windows,
            bridge: displayContext.bridge,
            selectableWindowIDs: allowedWindowIDs,
            nonOccludingWindowIDs: selectionController.selectionSurfaceWindowIDs,
            allowedOwnWindowID: allowedOwnWindowID
        )
        return ScreenshotFrozenSelectionSnapshot(
            images: images,
            candidates: candidates,
            displayDescriptors: descriptors
        )
    }

    private func selectionCandidate(
        _ window: SCWindow,
        bridge: ScreenshotCoordinateBridge
    ) -> ScreenshotSelectionCandidate {
        let selectionFrame = bridge.selectionRect(fromQuartzRect: window.frame)
        return ScreenshotSelectionCandidate(
            id: window.windowID,
            frame: selectionFrame,
            title: window.title?.isEmpty == false
                ? window.title!
                : (window.owningApplication?.applicationName ?? L10n.string("capture.source.unknownApp"))
        )
    }

    private func selectionCandidates(
        from windows: [SCWindow],
        bridge: ScreenshotCoordinateBridge,
        selectableWindowIDs: Set<UInt32>,
        nonOccludingWindowIDs: Set<UInt32> = [],
        allowedOwnWindowID: UInt32? = nil,
        windowMetadata suppliedWindowMetadata: FrontToBackWindowMetadata? = nil
    ) -> [ScreenshotSelectionCandidate] {
        let windowMetadata = suppliedWindowMetadata ?? frontToBackWindowMetadata()
        let candidates = windows.compactMap { window -> ScreenshotWindowVisibility.Candidate? in
            guard window.isOnScreen, !window.frame.isEmpty else { return nil }
            let alpha = windowMetadata.alphaByWindowNumber[window.windowID] ?? 1
            guard alpha > 0 else { return nil }
            let frame = bridge.selectionRect(fromQuartzRect: window.frame)
            let role = windowSurfaceRole(
                for: window,
                selectionFrame: frame,
                alpha: alpha,
                selectionSurfaceWindowIDs: nonOccludingWindowIDs,
                allowedOwnWindowID: allowedOwnWindowID
            )
            let isSelectable = selectableWindowIDs.contains(window.windowID) && role.isSelectable
            return ScreenshotWindowVisibility.Candidate(
                id: window.windowID,
                frame: frame,
                title: window.title?.isEmpty == false
                    ? window.title!
                    : (window.owningApplication?.applicationName ?? L10n.string("capture.source.unknownApp")),
                isSelectable: isSelectable,
                isOccluding: role.isOccluding,
                alpha: alpha
            )
        }
        return ScreenshotWindowVisibility.selectionCandidates(
            frontToBack: ScreenshotWindowVisibility.orderedFrontToBack(
                candidates,
                windowNumbers: windowMetadata.windowNumbers
            )
        )
    }

    static func preferredScrollingTargetWindowID(
        selectionRect: CGRect,
        candidatesFrontToBack: [ScreenshotSelectionCandidate]
    ) -> UInt32? {
        let center = CGPoint(x: selectionRect.midX, y: selectionRect.midY)
        if let centered = candidatesFrontToBack.first(where: {
            $0.visibleHitRegions.contains(where: { $0.contains(center) })
        }) {
            return centered.id
        }

        var best: (id: UInt32, visibleArea: CGFloat)?
        for candidate in candidatesFrontToBack {
            let visibleArea = candidate.visibleHitRegions.reduce(CGFloat.zero) { total, region in
                let overlap = region.intersection(selectionRect)
                guard !overlap.isNull, !overlap.isEmpty else { return total }
                return total + overlap.width * overlap.height
            }
            guard visibleArea > 0,
                  best == nil || visibleArea > best!.visibleArea else { continue }
            best = (candidate.id, visibleArea)
        }
        return best?.id
    }

    private func scrollingTargetApplication(
        selectionRect: CGRect,
        windows: [SCWindow],
        bridge: ScreenshotCoordinateBridge
    ) -> NSRunningApplication? {
        let ownBundleID = Bundle.main.bundleIdentifier
        let externalWindowIDs = Set(windows.compactMap { window -> UInt32? in
            guard window.owningApplication?.bundleIdentifier != ownBundleID else { return nil }
            return window.windowID
        })
        let ownWindowIDs = Set(windows.compactMap { window -> UInt32? in
            guard window.owningApplication?.bundleIdentifier == ownBundleID else { return nil }
            return window.windowID
        })
        let candidates = selectionCandidates(
            from: windows,
            bridge: bridge,
            selectableWindowIDs: externalWindowIDs,
            nonOccludingWindowIDs: ownWindowIDs
        )
        guard let windowID = Self.preferredScrollingTargetWindowID(
            selectionRect: selectionRect,
            candidatesFrontToBack: candidates
        ), let processID = windows.first(where: { $0.windowID == windowID })?.owningApplication?.processID else {
            return nil
        }
        return NSRunningApplication(processIdentifier: processID)
    }

    private struct FrontToBackWindowMetadata {
        let windowNumbers: [UInt32]
        let alphaByWindowNumber: [UInt32: CGFloat]
    }

    private func frontToBackWindowMetadata() -> FrontToBackWindowMetadata {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else {
            return FrontToBackWindowMetadata(windowNumbers: [], alphaByWindowNumber: [:])
        }
        var windowNumbers: [UInt32] = []
        var alphaByWindowNumber: [UInt32: CGFloat] = [:]
        for info in windowInfo {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            windowNumbers.append(number)
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber {
                alphaByWindowNumber[number] = CGFloat(alpha.doubleValue)
            }
        }
        return FrontToBackWindowMetadata(
            windowNumbers: windowNumbers,
            alphaByWindowNumber: alphaByWindowNumber
        )
    }

    private func selectionDisplay(
        _ pair: (offset: Int, element: ScreenshotDisplayGeometry)
    ) -> ScreenshotSelectionDisplay {
        return ScreenshotSelectionDisplay(
            id: pair.element.id,
            frame: pair.element.appKitFrame,
            title: L10n.format("capture.source.display", pair.offset + 1),
            backingScale: Double(pair.element.backingScale)
        )
    }

    private func makeDisplayGeometryContext(
        for displays: [SCDisplay]
    ) throws -> ScreenshotDisplayGeometryContext {
        let screensByID = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                screen.displayID.map { ($0, screen) }
            }
        )
        let primaryID = CGMainDisplayID()
        guard let primaryScreen = screensByID[primaryID],
              let primaryDisplay = displays.first(where: { $0.displayID == primaryID }) else {
            throw ScreenshotCaptureError.displayNotFound
        }
        let bridge = ScreenshotCoordinateBridge(
            primaryAppKitFrame: primaryScreen.frame,
            primaryQuartzFrame: primaryDisplay.frame
        )
        let geometries = try displays.map { display in
            guard let screen = screensByID[display.displayID] else {
                throw ScreenshotCaptureError.displayNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return ScreenshotDisplayGeometry(
                id: display.displayID,
                appKitFrame: screen.frame,
                quartzFrame: display.frame,
                backingScale: max(1, CGFloat(filter.pointPixelScale))
            )
        }
        return ScreenshotDisplayGeometryContext(bridge: bridge, geometries: geometries)
    }

    private func windowCandidates(
        from windows: [SCWindow],
        allowedOwnWindowID: UInt32? = nil,
        windowMetadata suppliedWindowMetadata: FrontToBackWindowMetadata? = nil
    ) -> [SCWindow] {
        let alphaByWindowNumber = (
            suppliedWindowMetadata ?? frontToBackWindowMetadata()
        ).alphaByWindowNumber
        return windows.filter { window in
            guard window.isOnScreen else { return false }
            let role = windowSurfaceRole(
                for: window,
                selectionFrame: window.frame,
                alpha: alphaByWindowNumber[window.windowID] ?? 1,
                selectionSurfaceWindowIDs: [],
                allowedOwnWindowID: allowedOwnWindowID
            )
            return role.isSelectable
        }
    }

    static func isBlocksSelectionSurface(
        windowID: UInt32,
        isBlocksOwnedSurface: Bool,
        selectionSurfaceWindowIDs: Set<UInt32>,
        allowedOwnWindowID: UInt32? = nil
    ) -> Bool {
        (isBlocksOwnedSurface && windowID != allowedOwnWindowID)
            || selectionSurfaceWindowIDs.contains(windowID)
    }

    private func windowSurfaceRole(
        for window: SCWindow,
        selectionFrame: CGRect,
        alpha: CGFloat,
        selectionSurfaceWindowIDs: Set<UInt32>,
        allowedOwnWindowID: UInt32? = nil
    ) -> ScreenshotWindowSurfaceRole {
        let application = window.owningApplication.flatMap {
            NSRunningApplication(processIdentifier: $0.processID)
        }
        let ownerKind: ScreenshotWindowOwnerKind = switch application?.activationPolicy {
        case .regular: .regular
        case .accessory: .accessory
        case .prohibited: .prohibited
        case nil: .unknown
        @unknown default: .unknown
        }
        let bundleIdentifier = window.owningApplication?.bundleIdentifier
        let isBlocksOwnedSurface = bundleIdentifier == Bundle.main.bundleIdentifier
            || window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        return ScreenshotWindowSurfaceClassifier.role(for: ScreenshotWindowSurfaceMetadata(
            layer: window.windowLayer,
            frame: selectionFrame,
            alpha: alpha,
            hasOwningApplication: window.owningApplication != nil,
            ownerKind: ownerKind,
            isAppleOwned: bundleIdentifier?.hasPrefix("com.apple.") == true,
            // Match pixel exclusion: only the ordinary own window frozen at
            // session entry is selectable and occluding. Other Blocks chrome
            // stays excluded even if it becomes frontmost during handoff.
            isBlocksSelectionSurface: Self.isBlocksSelectionSurface(
                windowID: window.windowID,
                isBlocksOwnedSurface: isBlocksOwnedSurface,
                selectionSurfaceWindowIDs: selectionSurfaceWindowIDs,
                allowedOwnWindowID: allowedOwnWindowID
            )
        ))
    }

    private func currentDisplayID() -> UInt32? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        return screen?.displayID
    }

    private func displayIndex(_ displayID: UInt32, in displays: [SCDisplay]) -> Int {
        displays.firstIndex(where: { $0.displayID == displayID }) ?? 0
    }

    private func makeCaptureID() -> String {
        "cap_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))"
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        return content
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await captureSingleFrameImage(
            deadline: Self.singleFrameCaptureDeadline,
            operation: {
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
        )
    }

    /// Internal operation seam for deterministic single-frame lifecycle tests.
    /// Production capture uses this exact owner, replacement dictionary, and
    /// deadline path; `beforeInstall` exists only to hold the narrow interval
    /// before a continuation is installed.
    func captureSingleFrameImage(
        deadline: Duration,
        beforeInstall: (@Sendable () async -> Void)? = nil,
        onOwnerRelease: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> CGImage
    ) async throws -> CGImage {
        let requestID = UUID()
        let owner = ScreenshotSingleFrameRequestOwner(onRelease: onOwnerRelease)
        activeSingleFrameRequests[requestID] = owner
        defer {
            // A late completion from this request must not clear a replacement.
            if activeSingleFrameRequests[requestID] === owner {
                activeSingleFrameRequests[requestID] = nil
            }
        }

        return try await withTaskCancellationHandler(operation: {
            if let beforeInstall {
                await beforeInstall()
            }
            return try await withCheckedThrowingContinuation { continuation in
                guard owner.install(continuation) else { return }
                // These are intentionally unstructured. Do not await their
                // completion: ScreenCaptureKit may ignore cancellation.
                let producer = Task { [weak owner, operation] in
                    do {
                        let image = try await operation()
                        owner?.succeed(image)
                    } catch {
                        owner?.fail(error)
                    }
                }
                owner.setProducerTask(producer)
                let watchdog = Task { [owner, deadline] in
                    do {
                        try await Task.sleep(for: deadline)
                        owner.timeout()
                    } catch {
                        // Cancellation of the watchdog has no terminal meaning.
                    }
                }
                owner.setWatchdogTask(watchdog)
            }
        }, onCancel: {
            owner.cancel()
        })
    }

    private func invalidateActiveSingleFrameRequests() {
        let requests = Array(activeSingleFrameRequests.values)
        activeSingleFrameRequests.removeAll()
        requests.forEach { $0.cancel() }
    }
}

extension ScreenCaptureKitAdapter: ScreenshotPurposeCapturing {}

private extension ScreenshotSelectionParameters {
    var captureDefaults: ScreenshotCaptureDefaults {
        ScreenshotCaptureDefaults(
            delaySeconds: delaySeconds,
            showsCursor: showsCursor,
            freezesFrame: freezesFrame,
            regionConstraint: constraint,
            watermarkPresetID: watermarkPresetID
        )
    }
}

private extension CGRect {
    var selectionRect: ScreenshotSelectionRect {
        ScreenshotSelectionRect(x: minX, y: minY, width: width, height: height)
    }
}

private extension ScreenshotSelectionRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private extension ScreenshotPixelRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
