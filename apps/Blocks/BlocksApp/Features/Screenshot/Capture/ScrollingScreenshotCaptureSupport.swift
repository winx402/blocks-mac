import AppKit
import BlocksScreenshotCore
import CoreGraphics
import Foundation
import os

enum ScrollingScreenshotFrameDemand {
    case seed
    case motion(UInt64)
    case settled(UInt64)
    case recovery(UInt64)
    case countdown(UUID)
    case resumeValidation

    func matchesCountdown(_ token: UUID) -> Bool {
        if case .countdown(token) = self { return true }
        return false
    }
}

struct ScrollingScreenshotReceivedFrame {
    let generation: UInt64
    let requestID: UInt64
    let frame: ScrollingCapturedFrame
}

struct ScrollingFrameSamplingGate: Equatable {
    private(set) var hasSeedFrame = false
    private(set) var latestCaptureRequestSequence: UInt64 = 0
    private var evaluatedCaptureRequestSequence: UInt64 = 0
    private var activeCaptureRequestSequence: UInt64?

    var shouldIngestIncomingFrameImmediately: Bool { !hasSeedFrame }
    var hasActiveCaptureAttempt: Bool { activeCaptureRequestSequence != nil }
    var hasPendingCaptureAttempt: Bool {
        latestCaptureRequestSequence > evaluatedCaptureRequestSequence
    }

    mutating func markFrameAccepted(through sequence: UInt64? = nil) {
        hasSeedFrame = true
        markFrameEvaluated(through: sequence ?? latestCaptureRequestSequence)
    }

    @discardableResult
    mutating func registerCaptureAttempt() -> Bool {
        guard hasSeedFrame else { return false }
        if activeCaptureRequestSequence == nil {
            latestCaptureRequestSequence &+= 1
            activeCaptureRequestSequence = latestCaptureRequestSequence
        }
        return true
    }

    mutating func markFrameEvaluated(through sequence: UInt64? = nil) {
        let resolved = min(sequence ?? latestCaptureRequestSequence, latestCaptureRequestSequence)
        evaluatedCaptureRequestSequence = max(evaluatedCaptureRequestSequence, resolved)
    }

    mutating func finishCaptureAttempt(through sequence: UInt64? = nil) {
        let resolved = min(sequence ?? latestCaptureRequestSequence, latestCaptureRequestSequence)
        if activeCaptureRequestSequence == resolved {
            activeCaptureRequestSequence = nil
        }
    }

    mutating func reset() {
        self = ScrollingFrameSamplingGate()
    }
}

@MainActor
extension ScrollingScreenshotCaptureCoordinator {
    func restartFromCurrentViewport() {
        guard continuation != nil,
              terminalGate.phase == .capturing,
              !hud.state.isCheckingResume,
              !hud.state.isRestarting else { return }
        let generation = terminalGate.generation
        hud.state.isRestarting = true
        let workRevision = prepareForRestart()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.session.restartFromCurrentViewport()
                guard self.isCurrentWork(
                    revision: workRevision,
                    generation: generation
                ) else { return }
                self.isManuallyPaused = false
                self.samplingGate.reset()
                self.updateHUD(snapshot)
                self.hud.state.isRestarting = false
                self.issueFrameDemand(.seed, generation: generation)
                self.logger.info("stage=restart-from-current-viewport")
            } catch {
                guard self.isCurrentWork(
                    revision: workRevision,
                    generation: generation
                ) else { return }
                self.hud.state.isRestarting = false
                self.pause(warning: L10n.string("screenshot.scrolling.error.writeFailed"))
            }
        }
    }

    private func prepareForRestart() -> UInt64 {
        let workRevision = invalidateAsynchronousWork()
        isManuallyPaused = true
        resetPossibleEndWork()
        motionSamplingTask?.cancel()
        motionSamplingTask = nil
        settledFrameEvaluationTask?.cancel()
        settledFrameEvaluationTask = nil
        cancelRecoverySampling()
        resumeHealthTask?.cancel()
        resumeHealthTask = nil
        hud.state.isCheckingResume = false
        removePendingDemands { _ in true }
        receivedFrames.removeAll(keepingCapacity: true)
        return workRevision
    }

    func enqueue(
        _ frame: ScrollingCapturedFrame,
        generation: UInt64,
        requestID: UInt64
    ) {
        guard terminalGate.acceptsCallback(generation: generation),
              !isCancellationPromptPresented,
              frameDemands[requestID] != nil else { return }
        receivedFrames.append(ScrollingScreenshotReceivedFrame(
            generation: generation,
            requestID: requestID,
            frame: frame
        ))
        startFrameProcessingIfNeeded()
    }

    private func startFrameProcessingIfNeeded() {
        guard frameProcessingTask == nil, !receivedFrames.isEmpty else { return }
        let owner = UUID()
        let revision = workRevision
        let generation = terminalGate.generation
        frameProcessingOwner = owner
        frameProcessingTask = Task { @MainActor [weak self] in
            await self?.drainReceivedFrames(
                owner: owner,
                revision: revision,
                generation: generation
            )
        }
    }

    private func drainReceivedFrames(
        owner: UUID,
        revision: UInt64,
        generation: UInt64
    ) async {
        while isCurrentFrameProcessingWork(
            owner: owner,
            revision: revision,
            generation: generation
        ), !receivedFrames.isEmpty {
            let received = receivedFrames.removeFirst()
            await process(
                received.frame,
                generation: received.generation,
                requestID: received.requestID,
                owner: owner,
                workRevision: revision
            )
        }
        guard frameProcessingOwner == owner else { return }
        frameProcessingTask = nil
        frameProcessingOwner = nil
        if isCurrentWork(revision: revision, generation: generation),
           !receivedFrames.isEmpty {
            startFrameProcessingIfNeeded()
        }
    }

    private func process(
        _ frame: ScrollingCapturedFrame,
        generation: UInt64,
        requestID: UInt64,
        owner: UUID,
        workRevision: UInt64
    ) async {
        guard isCurrentFrameProcessingWork(
            owner: owner,
            revision: workRevision,
            generation: generation
        ),
              !isCancellationPromptPresented,
              let demand = frameDemands.removeValue(forKey: requestID) else { return }
        isEvaluatingFrame = true
        evaluatingFrameOwner = owner
        defer {
            if evaluatingFrameOwner == owner {
                isEvaluatingFrame = false
                evaluatingFrameOwner = nil
            }
        }

        if case .resumeValidation = demand {
            defer {
                if isCurrentFrameProcessingWork(
                    owner: owner,
                    revision: workRevision,
                    generation: generation
                ) {
                    hud.state.isCheckingResume = false
                }
            }
            do {
                let snapshot = try await session.validateResumeAnchor(frame)
                guard isCurrentFrameProcessingWork(
                    owner: owner,
                    revision: workRevision,
                    generation: generation
                ) else { return }
                isManuallyPaused = snapshot.state != .capturing
                if !isManuallyPaused {
                    samplingGate.markFrameAccepted()
                }
                updateHUD(snapshot)
            } catch {
                guard isCurrentFrameProcessingWork(
                    owner: owner,
                    revision: workRevision,
                    generation: generation
                ) else { return }
                let snapshot = await session.pause(
                    warning: L10n.string("screenshot.scrolling.warning.frameChanged")
                )
                guard isCurrentFrameProcessingWork(
                    owner: owner,
                    revision: workRevision,
                    generation: generation
                ) else { return }
                isManuallyPaused = true
                updateHUD(snapshot)
            }
            return
        }

        guard !isManuallyPaused else { return }
        switch demand {
        case .seed:
            await evaluate(
                frame,
                generation: generation,
                workRevision: workRevision,
                owner: owner
            )
        case let .motion(sequence):
            await evaluate(
                frame,
                generation: generation,
                workRevision: workRevision,
                owner: owner,
                scheduleEndOnUnchanged: false,
                captureRequestSequence: sequence,
                commitsRecoveryAttempt: false
            )
        case let .settled(sequence):
            await evaluate(
                frame,
                generation: generation,
                workRevision: workRevision,
                owner: owner,
                scheduleEndOnUnchanged: false,
                captureRequestSequence: sequence,
                commitsRecoveryAttempt: true
            )
            guard isCurrentFrameProcessingWork(
                owner: owner,
                revision: workRevision,
                generation: generation
            ) else { return }
            samplingGate.finishCaptureAttempt(through: sequence)
            if terminalGate.phase == .capturing,
               samplingGate.hasPendingCaptureAttempt,
               possibleEndTask == nil,
               !isManuallyPaused {
                schedulePossibleEndIfNeeded()
            }
        case let .recovery(attemptID):
            await evaluate(
                frame,
                generation: generation,
                workRevision: workRevision,
                owner: owner,
                scheduleEndOnUnchanged: false,
                recoveryAttemptID: attemptID,
                commitsRecoveryAttempt: true
            )
        case .countdown:
            await evaluate(
                frame,
                generation: generation,
                workRevision: workRevision,
                owner: owner,
                scheduleEndOnUnchanged: false
            )
        case .resumeValidation:
            break
        }
    }

    func issueFrameDemand(_ demand: ScrollingScreenshotFrameDemand, generation: UInt64) {
        guard terminalGate.acceptsCallback(generation: generation) else { return }
        if case let .motion(sequence) = demand,
           frameDemands.values.contains(where: {
               if case let .motion(existing) = $0 { return existing == sequence }
               return false
           }) {
            return
        }
        coalescePendingDemands(for: demand)
        guard frameDemands.count < Self.maximumPendingFrameDemands else {
            logger.debug("stage=frame-demand-coalesced queued=\(self.frameDemands.count, privacy: .public)")
            return
        }
        let requestID = nextFrameRequestID
        nextFrameRequestID &+= 1
        frameDemands[requestID] = demand
        frameSource.requestFrame(generation: generation, requestID: requestID)
    }

    private func coalescePendingDemands(for incoming: ScrollingScreenshotFrameDemand) {
        switch incoming {
        case .motion:
            break
        case let .settled(sequence):
            removePendingDemands { demand in
                if case let .motion(existing) = demand { return existing <= sequence }
                return false
            }
        case .resumeValidation:
            removePendingDemands { demand in
                switch demand {
                case .seed, .resumeValidation: false
                case .motion, .settled, .recovery, .countdown: true
                }
            }
        case .recovery:
            removePendingDemands { demand in
                if case .recovery = demand { return true }
                return false
            }
        case .countdown:
            removePendingDemands { demand in
                if case .countdown = demand { return true }
                return false
            }
        case .seed:
            break
        }
    }

    func removePendingDemands(
        where shouldRemove: (ScrollingScreenshotFrameDemand) -> Bool
    ) {
        let requestIDs = frameDemands.compactMap { requestID, demand in
            shouldRemove(demand) ? requestID : nil
        }
        guard !requestIDs.isEmpty else { return }
        for requestID in requestIDs {
            frameDemands.removeValue(forKey: requestID)
        }
        frameSource.cancelFrameRequests(
            generation: terminalGate.generation,
            requestIDs: Set(requestIDs)
        )
        receivedFrames.removeAll { requestIDs.contains($0.requestID) }
    }

    func waitForFramePipelineDrain(generation: UInt64) async -> Bool {
        for _ in 0..<50 {
            guard terminalGate.acceptsCallback(generation: generation) else { return false }
            if frameDemands.isEmpty,
               receivedFrames.isEmpty,
               frameProcessingTask == nil,
               !isEvaluatingFrame {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        logger.debug(
            "stage=frame-pipeline-drain-timeout queued=\(self.frameDemands.count, privacy: .public) evaluating=\(self.isEvaluatingFrame, privacy: .public)"
        )
        return false
    }
}

enum ScrollingScreenshotControlFailure: Error, Equatable, Sendable {
    case staleSession
    case invalidState
    case sessionPaused
    case alreadyTerminal
    case confirmationRequired
    case cleanupFailed

    var code: String {
        switch self {
        case .staleSession: "stale_session"
        case .invalidState: "invalid_state"
        case .sessionPaused: "session_paused"
        case .alreadyTerminal: "already_terminal"
        case .confirmationRequired: "confirmation_required"
        case .cleanupFailed: "cleanup_failed"
        }
    }
}

enum ScrollingScreenshotTerminalClaim: Equatable, Sendable {
    case accepted
    case staleSession
    case alreadyTerminal
}

struct ScrollingScreenshotTerminalGate: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case capturing
        case finalizing
        case editing
        case terminal(ScrollingScreenshotSessionTerminal)
    }

    private(set) var generation: UInt64 = 0
    private(set) var sessionID: String?
    private(set) var phase: Phase = .idle

    mutating func begin(sessionID: String) throws -> UInt64 {
        switch phase {
        case .idle, .terminal:
            generation &+= 1
            self.sessionID = sessionID
            phase = .capturing
            return generation
        case .capturing, .finalizing, .editing:
            throw ScrollingScreenshotSessionError.sessionAlreadyActive
        }
    }

    mutating func reset() {
        generation &+= 1
        sessionID = nil
        phase = .idle
    }

    func acceptsCallback(generation: UInt64) -> Bool {
        self.generation == generation && !isTerminal
    }

    mutating func markFinalizing(generation: UInt64) -> Bool {
        guard acceptsCallback(generation: generation), phase == .capturing else { return false }
        phase = .finalizing
        return true
    }

    mutating func markEditing(generation: UInt64) -> Bool {
        guard acceptsCallback(generation: generation), phase == .finalizing else { return false }
        phase = .editing
        return true
    }

    mutating func claim(
        sessionID: String,
        generation: UInt64,
        terminal: ScrollingScreenshotSessionTerminal
    ) -> ScrollingScreenshotTerminalClaim {
        guard self.sessionID == sessionID, self.generation == generation else { return .staleSession }
        guard !isTerminal else { return .alreadyTerminal }
        phase = .terminal(terminal)
        return .accepted
    }

    func controlFailure(for requestedSessionID: String) -> ScrollingScreenshotControlFailure? {
        guard sessionID == requestedSessionID else { return .staleSession }
        return isTerminal ? .alreadyTerminal : nil
    }

    private var isTerminal: Bool {
        if case .terminal = phase { return true }
        return false
    }
}

struct ScrollingScreenshotControlResult: Equatable, Sendable {
    let accepted: Bool
    let state: ScrollingScreenshotRuntimeSnapshot.State
    let failure: ScrollingScreenshotControlFailure?
    let wasEditing: Bool

    static func accepted(
        state: ScrollingScreenshotRuntimeSnapshot.State,
        wasEditing: Bool = false
    ) -> Self {
        Self(accepted: true, state: state, failure: nil, wasEditing: wasEditing)
    }

    static func rejected(
        _ failure: ScrollingScreenshotControlFailure,
        state: ScrollingScreenshotRuntimeSnapshot.State,
        wasEditing: Bool = false
    ) -> Self {
        Self(accepted: false, state: state, failure: failure, wasEditing: wasEditing)
    }
}

struct ScrollingScreenshotHealthContext: Equatable, Sendable {
    let displayID: UInt32
    let displayFrame: CGRect
    let selectionRect: CGRect
    let expectedPixelSize: ScreenshotPixelSize
    let hasInputMonitor: Bool
}

enum ScrollingScreenshotHealthFailure: Error, Equatable, Sendable {
    case screenRecordingPermissionMissing
    case inputMonitoringPermissionMissing
    case inputMonitorUnavailable
    case displayUnavailable
    case displayGeometryChanged
    case regionInvalid

    var localizedWarning: String {
        switch self {
        case .screenRecordingPermissionMissing, .inputMonitoringPermissionMissing:
            L10n.string("screenshot.scrolling.permission.required")
        case .inputMonitorUnavailable, .displayUnavailable, .displayGeometryChanged, .regionInvalid:
            L10n.string("screenshot.scrolling.warning.frameChanged")
        }
    }
}

extension ScrollingScreenshotRuntimeSnapshot.State {
    var acceptsFinishAction: Bool {
        self == .capturing || self == .possibleEnd
    }
}

extension ScrollingScreenshotHUDState {
    mutating func apply(_ snapshot: ScrollingScreenshotRuntimeSnapshot) {
        accumulatedHeight = snapshot.outputSize.height
        warning = snapshot.warning
        switch snapshot.state {
        case .idle, .selecting, .capturing: phase = .capturing
        case .recovering: phase = .recovering
        case .paused: phase = .paused
        case .possibleEnd: break
        case .finalizing, .editing: phase = .finalizing
        }
    }
}

enum ScrollingScreenshotHealthStatus: Equatable, Sendable {
    case healthy
    case unhealthy(ScrollingScreenshotHealthFailure)
}

struct ScrollingScreenshotHealthChecker: @unchecked Sendable {
    private let evaluator: @MainActor @Sendable (
        ScrollingScreenshotHealthContext
    ) async -> ScrollingScreenshotHealthStatus

    init(
        _ evaluator: @escaping @MainActor @Sendable (
            ScrollingScreenshotHealthContext
        ) async -> ScrollingScreenshotHealthStatus
    ) {
        self.evaluator = evaluator
    }

    @MainActor
    func check(_ context: ScrollingScreenshotHealthContext) async -> ScrollingScreenshotHealthStatus {
        await evaluator(context)
    }

    static let live = ScrollingScreenshotHealthChecker { context in
        guard CGPreflightScreenCaptureAccess() else {
            return .unhealthy(.screenRecordingPermissionMissing)
        }
        guard CGPreflightListenEventAccess() else {
            return .unhealthy(.inputMonitoringPermissionMissing)
        }
        guard context.hasInputMonitor else { return .unhealthy(.inputMonitorUnavailable) }
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == context.displayID
        }) else {
            return .unhealthy(.displayUnavailable)
        }
        guard screen.frame.approximatelyEquals(context.displayFrame, tolerance: 1) else {
            return .unhealthy(.displayGeometryChanged)
        }
        guard context.displayFrame.contains(context.selectionRect),
              context.selectionRect.width >= 8,
              context.selectionRect.height >= 8,
              context.expectedPixelSize.width > 0,
              context.expectedPixelSize.height > 0 else {
            return .unhealthy(.regionInvalid)
        }
        return .healthy
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

extension ScrollingScreenshotCaptureCoordinator {
    enum CaptureInputIntent: Equatable {
        case sample
        case none
    }

    static func captureInputIntent(for event: NSEvent) -> CaptureInputIntent {
        switch event.type {
        case .scrollWheel:
            captureInputIntent(
                eventType: event.type,
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY
            )
        case .keyDown:
            captureInputIntent(eventType: event.type, keyCode: event.keyCode)
        default:
            captureInputIntent(eventType: event.type)
        }
    }

    static func captureInputIntent(
        eventType: NSEvent.EventType,
        scrollingDeltaX: CGFloat = 0,
        scrollingDeltaY: CGFloat = 0,
        keyCode: UInt16 = 0
    ) -> CaptureInputIntent {
        switch eventType {
        case .scrollWheel:
            let horizontal = abs(scrollingDeltaX)
            let vertical = abs(scrollingDeltaY)
            return vertical >= 0.5 && vertical >= horizontal ? .sample : .none
        case .keyDown:
            return [49, 116, 121, 125, 126].contains(keyCode) ? .sample : .none
        case .leftMouseDragged:
            return .sample
        default:
            return .none
        }
    }

    static func isCancelKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 53
    }

    static func requiresPointerInsideSelection(for eventType: NSEvent.EventType) -> Bool {
        eventType != .keyDown
    }
}
