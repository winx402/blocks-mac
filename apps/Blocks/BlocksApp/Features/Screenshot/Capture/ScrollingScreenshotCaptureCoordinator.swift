import AppKit
import BlocksScreenshotCore
import CoreGraphics
import Foundation
import os

@MainActor
final class ScrollingScreenshotCaptureCoordinator {
    enum FirstFrameWatchdogSchedulingOutcome: Equatable {
        case armed
        case skippedAlreadyReceived
    }

    struct FirstCompleteFrameMarker {
        let generation: UInt64
        let workRevision: UInt64
    }

    static let motionSampleInterval = Duration.milliseconds(80)
    static let frameSettleDelay = Duration.milliseconds(180)
    static let recoverySampleDelay = Duration.milliseconds(180)
    static let activeHealthCheckInterval = Duration.seconds(2)
    static let defaultFirstCompleteFrameDeadline = Duration.seconds(5)
    nonisolated static let defaultFrameSourceStopDeadline = Duration.seconds(1)
    static let maximumPendingFrameDemands = 8

    let logger = Logger(subsystem: "app.blocks.app", category: "ScrollingCapture")
    let session: ScrollingScreenshotSessionCoordinator
    let frameSource: any ScrollingScreenshotFrameSourcing
    let healthChecker: ScrollingScreenshotHealthChecker
    private let screenRecordingPreflight: () -> Bool
    private let inputMonitoringPreflight: () -> Bool
    let scrollMonitorInstaller: (@escaping (NSEvent) -> Void) -> Any?
    let scrollMonitorRemover: (Any) -> Void
    let frameSourceStartDeadline: Duration
    let frameSourceStartDeadlineWait: @Sendable (Duration) async -> Bool
    private let frameSourceStartFailureDidComplete: (UInt64) -> Void
    let firstCompleteFrameDeadline: Duration
    let firstFrameWatchdogWait: @Sendable (Duration) async -> Bool
    let firstFrameWatchdogSchedulingDidComplete: (FirstFrameWatchdogSchedulingOutcome) -> Void
    let frameSourceStopDeadline: Duration
    let frameSourceStopDeadlineWait: @Sendable (Duration) async -> Bool
    let hud: ScrollingScreenshotHUDController
    var continuation: CheckedContinuation<CGImage, Error>?
    var scrollMonitor: Any?
    var motionSamplingTask: Task<Void, Never>?
    var settledFrameEvaluationTask: Task<Void, Never>?
    var recoverySamplingTask: Task<Void, Never>?
    var frameProcessingTask: Task<Void, Never>?
    var possibleEndTask: Task<Void, Never>?
    var possibleEndTaskOwner: UUID?
    var possibleEndResetTask: Task<Void, Never>?
    var possibleEndResetTaskOwner: UUID?
    var finalizationTask: Task<Void, Never>?
    var resumeHealthTask: Task<Void, Never>?
    var activeHealthTask: Task<Void, Never>?
    var frameSourceStartDeadlineTask: Task<Void, Never>?
    var frameSourceStartDeadlineOwner: UUID?
    var firstFrameWatchdogTask: Task<Void, Never>?
    var firstFrameWatchdogOwner: UUID?
    var firstCompleteFrameMarker: FirstCompleteFrameMarker?
    var frameSourceStopGeneration: UInt64?
    var frameSourceStopOwner: UUID?
    var stoppedFrameSourceGenerations: Set<UInt64> = []
    var frameSourceStopTask: Task<Void, Never>?
    var frameSourceStopDeadlineTask: Task<Void, Never>?
    var frameSourceStopWaiters: [CheckedContinuation<Bool, Never>] = []
    var selectionRect = CGRect.zero
    var isManuallyPaused = false
    var isCancellationPromptPresented = false
    var samplingGate = ScrollingFrameSamplingGate()
    var terminalGate = ScrollingScreenshotTerminalGate()
    var frameDemands: [UInt64: ScrollingScreenshotFrameDemand] = [:]
    var receivedFrames: [ScrollingScreenshotReceivedFrame] = []
    var nextFrameRequestID: UInt64 = 1
    var nextRecoveryAttemptID: UInt64 = 1
    var healthContext: ScrollingScreenshotHealthContext?
    var latestRuntimeState: ScrollingScreenshotRuntimeSnapshot.State = .idle
    var isEvaluatingFrame = false
    var workRevision: UInt64 = 0
    var frameProcessingOwner: UUID?
    var evaluatingFrameOwner: UUID?

    init(
        session: ScrollingScreenshotSessionCoordinator = .init(),
        frameSource: (any ScrollingScreenshotFrameSourcing)? = nil,
        healthChecker: ScrollingScreenshotHealthChecker = .live,
        hud: ScrollingScreenshotHUDController? = nil,
        screenRecordingPreflight: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        inputMonitoringPreflight: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        scrollMonitorInstaller: @escaping (@escaping (NSEvent) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(
                matching: [.scrollWheel, .keyDown, .leftMouseDragged],
                handler: handler
            )
        },
        scrollMonitorRemover: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        frameSourceStartDeadline: Duration = .seconds(5),
        frameSourceStartDeadlineWait: @escaping @Sendable (Duration) async -> Bool = { deadline in
            do {
                try await Task.sleep(for: deadline)
                return !Task.isCancelled
            } catch {
                return false
            }
        },
        frameSourceStartFailureDidComplete: @escaping (UInt64) -> Void = { _ in },
        firstCompleteFrameDeadline: Duration = .seconds(5),
        firstFrameWatchdogWait: @escaping @Sendable (Duration) async -> Bool = { deadline in
            do {
                try await Task.sleep(for: deadline)
                return !Task.isCancelled
            } catch {
                return false
            }
        },
        firstFrameWatchdogSchedulingDidComplete: @escaping (FirstFrameWatchdogSchedulingOutcome) -> Void = { _ in },
        frameSourceStopDeadline: Duration = ScrollingScreenshotCaptureCoordinator.defaultFrameSourceStopDeadline,
        frameSourceStopDeadlineWait: @escaping @Sendable (Duration) async -> Bool = { deadline in
            do {
                try await Task.sleep(for: deadline)
                return !Task.isCancelled
            } catch {
                return false
            }
        }
    ) {
        self.session = session
        self.frameSource = frameSource ?? ScreenCaptureKitScrollingFrameSource()
        self.healthChecker = healthChecker
        self.hud = hud ?? ScrollingScreenshotHUDController()
        self.screenRecordingPreflight = screenRecordingPreflight
        self.inputMonitoringPreflight = inputMonitoringPreflight
        self.scrollMonitorInstaller = scrollMonitorInstaller
        self.scrollMonitorRemover = scrollMonitorRemover
        self.frameSourceStartDeadline = frameSourceStartDeadline
        self.frameSourceStartDeadlineWait = frameSourceStartDeadlineWait
        self.frameSourceStartFailureDidComplete = frameSourceStartFailureDidComplete
        self.firstCompleteFrameDeadline = firstCompleteFrameDeadline
        self.firstFrameWatchdogWait = firstFrameWatchdogWait
        self.firstFrameWatchdogSchedulingDidComplete = firstFrameWatchdogSchedulingDidComplete
        self.frameSourceStopDeadline = frameSourceStopDeadline
        self.frameSourceStopDeadlineWait = frameSourceStopDeadlineWait
    }

    func capture(
        sessionID: String,
        displayID: UInt32,
        displayFrame: CGRect,
        selectionRect: CGRect,
        backingScale: CGFloat,
        originatingApplication: NSRunningApplication?
    ) async throws -> CGImage {
        guard screenRecordingPreflight() else {
            throw ScreenshotCaptureError.screenRecordingPermissionMissing
        }
        guard inputMonitoringPreflight() else {
            throw ScreenshotCaptureError.inputMonitoringPermissionMissing
        }
        guard continuation == nil else {
            throw ScrollingScreenshotSessionError.sessionAlreadyActive
        }

        let startedSessionID = try await session.begin(sessionID: sessionID)
        let generation: UInt64
        do {
            generation = try terminalGate.begin(sessionID: startedSessionID)
        } catch {
            try? await session.cancel(confirm: true)
            throw error
        }
        stoppedFrameSourceGenerations.removeAll(keepingCapacity: true)
        let captureWorkRevision = invalidateAsynchronousWork()
        latestRuntimeState = .capturing
        self.selectionRect = selectionRect
        isManuallyPaused = false
        samplingGate.reset()
        frameDemands = [0: .seed]
        receivedFrames.removeAll(keepingCapacity: true)
        nextFrameRequestID = 1
        nextRecoveryAttemptID = 1
        let expectedPixelSize = ScreenshotPixelSize(
            width: max(1, Int((selectionRect.width * backingScale).rounded())),
            height: max(1, Int((selectionRect.height * backingScale).rounded()))
        )
        healthContext = ScrollingScreenshotHealthContext(
            displayID: displayID,
            displayFrame: displayFrame,
            selectionRect: selectionRect,
            expectedPixelSize: expectedPixelSize,
            hasInputMonitor: false
        )
        hud.state = ScrollingScreenshotHUDState()
        hud.transitionToCapturing(selectionRect: selectionRect) { [weak self] command in
            self?.handleHUDCommand(command)
        }
        guard installScrollMonitor() else {
            await abortSetup(sessionID: startedSessionID, generation: generation)
            throw ScrollingScreenshotHealthFailure.inputMonitorUnavailable
        }
        healthContext = healthContext.map {
            ScrollingScreenshotHealthContext(
                displayID: $0.displayID,
                displayFrame: $0.displayFrame,
                selectionRect: $0.selectionRect,
                expectedPixelSize: $0.expectedPixelSize,
                hasInputMonitor: scrollMonitor != nil
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.startFrameSourceStartDeadline(
                generation: generation,
                workRevision: captureWorkRevision
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.frameSource.start(
                        generation: generation,
                        displayID: displayID,
                        displayFrame: displayFrame,
                        selectionRect: selectionRect,
                        scale: backingScale,
                        onFrame: { [weak self] callbackGeneration, requestID, frame in
                            await self?.enqueueFirstCompleteFrame(
                                frame,
                                generation: callbackGeneration,
                                requestID: requestID
                            )
                        },
                        onFailure: { [weak self] callbackGeneration, error in
                            await self?.fail(error, generation: callbackGeneration)
                        }
                    )
                    guard self.isCurrentWork(
                        revision: captureWorkRevision,
                        generation: generation
                    ), self.terminalGate.phase == .capturing else { return }
                    self.cancelFrameSourceStartDeadline()
                    self.startFirstCompleteFrameWatchdog(
                        generation: generation,
                        workRevision: captureWorkRevision
                    )
                    self.startActiveHealthMonitoring(generation: generation)
                    originatingApplication?.activate()
                } catch {
                    await self.fail(error, generation: generation)
                    self.frameSourceStartFailureDidComplete(generation)
                }
            }
        }
    }

    func handleHUDCommand(_ command: ScreenshotScrollingCommand) {
        switch command {
        case .pause: pause()
        case .resume: resume()
        case .restart: restartFromCurrentViewport()
        case .finish: _ = requestFinish()
        case .cancel: requestCancel()
        case .start, .reselect: break
        }
    }

    func status() async -> ScrollingScreenshotRuntimeSnapshot {
        await session.status()
    }

    func finishFromAction(sessionID: String) -> ScrollingScreenshotControlResult {
        if let failure = terminalGate.controlFailure(for: sessionID) {
            return .rejected(failure, state: latestRuntimeState)
        }
        if latestRuntimeState == .paused || latestRuntimeState == .recovering {
            return .rejected(.sessionPaused, state: latestRuntimeState)
        }
        guard latestRuntimeState.acceptsFinishAction, requestFinish() else {
            return .rejected(.invalidState, state: latestRuntimeState)
        }
        return .accepted(state: .finalizing)
    }

    func cancelFromAction(sessionID: String, confirm: Bool) async -> ScrollingScreenshotControlResult {
        guard confirm else {
            return .rejected(.confirmationRequired, state: latestRuntimeState)
        }
        if let failure = terminalGate.controlFailure(for: sessionID) {
            return .rejected(failure, state: latestRuntimeState)
        }
        let wasEditing = latestRuntimeState == .editing
        if let failure = await cancelConfirmed(sessionID: sessionID) {
            return .rejected(failure, state: latestRuntimeState, wasEditing: wasEditing)
        }
        return .accepted(state: .idle, wasEditing: wasEditing)
    }

    func finishEditingSession(
        sessionID: String,
        terminal: ScrollingScreenshotSessionTerminal
    ) async -> ScrollingScreenshotControlResult {
        if let failure = terminalGate.controlFailure(for: sessionID) {
            return .rejected(failure, state: latestRuntimeState, wasEditing: true)
        }
        guard terminalGate.phase == .editing else {
            return .rejected(.invalidState, state: latestRuntimeState, wasEditing: true)
        }
        let generation = terminalGate.generation
        guard terminalGate.claim(
            sessionID: sessionID,
            generation: generation,
            terminal: terminal
        ) == .accepted else {
            return .rejected(.alreadyTerminal, state: latestRuntimeState, wasEditing: true)
        }
        do {
            try await session.finishEditing(sessionID: sessionID, terminal: terminal)
            latestRuntimeState = .idle
            return .accepted(state: .idle, wasEditing: true)
        } catch ScrollingScreenshotSessionError.cleanupFailed {
            await session.releaseSessionAfterCleanupFailure()
            latestRuntimeState = .idle
            return .rejected(.cleanupFailed, state: latestRuntimeState, wasEditing: true)
        } catch {
            return .rejected(.invalidState, state: latestRuntimeState, wasEditing: true)
        }
    }

    func cancelCurrentSession() {
        guard let sessionID = terminalGate.sessionID else { return }
        Task { @MainActor [weak self] in
            _ = await self?.cancelConfirmed(sessionID: sessionID)
        }
    }

    private func enqueueFirstCompleteFrame(
        _ frame: ScrollingCapturedFrame,
        generation: UInt64,
        requestID: UInt64
    ) {
        guard terminalGate.acceptsCallback(generation: generation),
              !isCancellationPromptPresented,
              frameDemands[requestID] != nil else { return }
        markFirstCompleteFrameEnqueued(
            generation: generation,
            workRevision: workRevision
        )
        cancelFirstCompleteFrameWatchdog()
        enqueue(frame, generation: generation, requestID: requestID)
    }

    func evaluate(
        _ frame: ScrollingCapturedFrame,
        generation: UInt64,
        workRevision: UInt64,
        owner: UUID,
        scheduleEndOnUnchanged: Bool = true,
        captureRequestSequence: UInt64? = nil,
        recoveryAttemptID: UInt64? = nil,
        commitsRecoveryAttempt: Bool = true
    ) async {
        guard isCurrentFrameProcessingWork(
            owner: owner,
            revision: workRevision,
            generation: generation
        ), !isManuallyPaused else { return }
        do {
            let event = try await session.ingest(
                frame,
                recoveryAttemptID: recoveryAttemptID ?? captureRequestSequence,
                commitsRecoveryAttempt: commitsRecoveryAttempt
            )
            guard isCurrentFrameProcessingWork(
                owner: owner,
                revision: workRevision,
                generation: generation
            ), !isManuallyPaused else { return }
            switch event {
            case let .accepted(snapshot), let .recovered(snapshot):
                cancelRecoverySampling()
                samplingGate.markFrameAccepted(through: captureRequestSequence)
                cancelPossibleEnd()
                updateHUD(snapshot)
            case let .recovering(snapshot):
                samplingGate.markFrameEvaluated(through: captureRequestSequence)
                cancelPossibleEnd()
                updateHUD(snapshot)
                scheduleRecoverySample()
            case let .unchanged(snapshot):
                cancelRecoverySampling()
                updateHUD(snapshot)
                if let captureRequestSequence,
                   samplingGate.latestCaptureRequestSequence > captureRequestSequence {
                    samplingGate.markFrameEvaluated(through: captureRequestSequence)
                } else if scheduleEndOnUnchanged {
                    schedulePossibleEndIfNeeded()
                }
            case let .paused(snapshot):
                cancelRecoverySampling()
                samplingGate.markFrameEvaluated(through: captureRequestSequence)
                isManuallyPaused = true
                cancelPossibleEnd()
                updateHUD(snapshot)
            case let .reachedLimit(snapshot):
                cancelRecoverySampling()
                updateHUD(snapshot)
                _ = requestFinish()
            }
        } catch {
            guard isCurrentFrameProcessingWork(
                owner: owner,
                revision: workRevision,
                generation: generation
            ) else { return }
            await fail(error, generation: generation)
        }
    }

    @discardableResult
    func invalidateAsynchronousWork() -> UInt64 {
        workRevision &+= 1
        cancelFrameSourceStartDeadline()
        clearFirstCompleteFrameState()
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
        frameProcessingOwner = nil
        if evaluatingFrameOwner != nil {
            isEvaluatingFrame = false
            evaluatingFrameOwner = nil
        }
        return workRevision
    }

    func isCurrentWork(revision: UInt64, generation: UInt64) -> Bool {
        !Task.isCancelled
            && workRevision == revision
            && terminalGate.acceptsCallback(generation: generation)
    }

    func isCurrentFrameProcessingWork(
        owner: UUID,
        revision: UInt64,
        generation: UInt64
    ) -> Bool {
        isCurrentWork(revision: revision, generation: generation)
            && frameProcessingOwner == owner
    }

    private func abortSetup(sessionID: String, generation: UInt64) async {
        _ = terminalGate.claim(
            sessionID: sessionID,
            generation: generation,
            terminal: .failed
        )
        _ = invalidateAsynchronousWork()
        try? await session.cancel(confirm: true)
        latestRuntimeState = .idle
        teardownSurfaces()
        terminalGate.reset()
    }

    func pause(warning: String? = nil) {
        guard let sessionID = terminalGate.sessionID else { return }
        let workRevision = invalidateAsynchronousWork()
        isManuallyPaused = true
        samplingGate.markFrameEvaluated()
        samplingGate.finishCaptureAttempt()
        motionSamplingTask?.cancel()
        motionSamplingTask = nil
        settledFrameEvaluationTask?.cancel()
        settledFrameEvaluationTask = nil
        cancelRecoverySampling()
        resumeHealthTask?.cancel()
        resumeHealthTask = nil
        hud.state.isCheckingResume = false
        hud.state.isRestarting = false
        removePendingDemands { _ in true }
        receivedFrames.removeAll(keepingCapacity: true)
        cancelPossibleEnd()
        let generation = terminalGate.generation
        Task { @MainActor [weak self] in
            guard let self,
                  self.terminalGate.sessionID == sessionID,
                  self.isCurrentWork(
                      revision: workRevision,
                      generation: generation
                  ) else { return }
            let snapshot = await self.session.pause(warning: warning)
            guard self.isCurrentWork(
                revision: workRevision,
                generation: generation
            ) else { return }
            self.updateHUD(snapshot)
        }
    }

    private func resume() {
        guard isManuallyPaused,
              !hud.state.isCheckingResume,
              let context = healthContext,
              terminalGate.phase == .capturing else { return }
        let workRevision = invalidateAsynchronousWork()
        resumeHealthTask?.cancel()
        hud.state.isCheckingResume = true
        let generation = terminalGate.generation
        resumeHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentWork(
                    revision: workRevision,
                    generation: generation
                ) {
                    self.resumeHealthTask = nil
                }
            }
            let health = await self.healthChecker.check(context)
            guard self.isCurrentWork(
                revision: workRevision,
                generation: generation
            ), self.isManuallyPaused else { return }
            switch health {
            case .healthy:
                self.issueFrameDemand(.resumeValidation, generation: generation)
            case let .unhealthy(failure):
                let warning = failure.localizedWarning
                let snapshot = await self.session.pause(warning: warning)
                guard self.isCurrentWork(
                    revision: workRevision,
                    generation: generation
                ), self.isManuallyPaused else { return }
                self.updateHUD(snapshot)
                self.isManuallyPaused = true
                self.hud.state.isCheckingResume = false
            }
        }
    }

    func updateHUD(_ snapshot: ScrollingScreenshotRuntimeSnapshot) {
        latestRuntimeState = snapshot.state
        hud.state.apply(snapshot)
    }
}
