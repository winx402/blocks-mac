import AppKit
import BlocksScreenshotCore
import CoreGraphics
import Foundation
import os

// Sampling and liveness scheduling for the coordinator's single session.
@MainActor
extension ScrollingScreenshotCaptureCoordinator {
    func startFrameSourceStartDeadline(
        generation: UInt64,
        workRevision: UInt64
    ) {
        guard isCurrentWork(revision: workRevision, generation: generation),
              terminalGate.phase == .capturing else { return }
        cancelFrameSourceStartDeadline()
        let owner = UUID()
        frameSourceStartDeadlineOwner = owner
        frameSourceStartDeadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.frameSourceStartDeadlineOwner == owner {
                    self.frameSourceStartDeadlineTask = nil
                    self.frameSourceStartDeadlineOwner = nil
                }
            }
            guard await self.frameSourceStartDeadlineWait(
                self.frameSourceStartDeadline
            ), self.isCurrentFrameSourceStartDeadline(
                owner: owner,
                revision: workRevision,
                generation: generation
            ) else { return }
            await self.fail(
                ScreenshotCaptureError.captureFailed(L10n.string("status.failed.detail")),
                generation: generation
            )
        }
    }

    func cancelFrameSourceStartDeadline() {
        frameSourceStartDeadlineTask?.cancel()
        frameSourceStartDeadlineTask = nil
        frameSourceStartDeadlineOwner = nil
    }

    private func isCurrentFrameSourceStartDeadline(
        owner: UUID,
        revision: UInt64,
        generation: UInt64
    ) -> Bool {
        isCurrentWork(revision: revision, generation: generation)
            && terminalGate.phase == .capturing
            && frameSourceStartDeadlineOwner == owner
    }

    func startFirstCompleteFrameWatchdog(
        generation: UInt64,
        workRevision: UInt64
    ) {
        guard isCurrentWork(revision: workRevision, generation: generation),
              terminalGate.phase == .capturing else { return }
        guard !hasFirstCompleteFrameEnqueued(
            generation: generation,
            workRevision: workRevision
        ) else {
            firstFrameWatchdogSchedulingDidComplete(.skippedAlreadyReceived)
            return
        }
        cancelFirstCompleteFrameWatchdog()
        let owner = UUID()
        firstFrameWatchdogOwner = owner
        firstFrameWatchdogSchedulingDidComplete(.armed)
        firstFrameWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.firstFrameWatchdogOwner == owner {
                    self.firstFrameWatchdogTask = nil
                    self.firstFrameWatchdogOwner = nil
                }
            }
            guard await self.firstFrameWatchdogWait(self.firstCompleteFrameDeadline),
                  self.isCurrentFirstFrameWatchdog(
                      owner: owner,
                      revision: workRevision,
                      generation: generation
                  ) else { return }
            await self.fail(
                ScreenshotCaptureError.captureFailed(L10n.string("status.failed.detail")),
                generation: generation
            )
        }
    }

    func cancelFirstCompleteFrameWatchdog() {
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameWatchdogOwner = nil
    }

    func clearFirstCompleteFrameState() {
        cancelFirstCompleteFrameWatchdog()
        firstCompleteFrameMarker = nil
    }

    func markFirstCompleteFrameEnqueued(
        generation: UInt64,
        workRevision: UInt64
    ) {
        firstCompleteFrameMarker = FirstCompleteFrameMarker(
            generation: generation,
            workRevision: workRevision
        )
    }

    private func hasFirstCompleteFrameEnqueued(
        generation: UInt64,
        workRevision: UInt64
    ) -> Bool {
        guard let firstCompleteFrameMarker else { return false }
        return firstCompleteFrameMarker.generation == generation
            && firstCompleteFrameMarker.workRevision == workRevision
    }

    private func isCurrentFirstFrameWatchdog(
        owner: UUID,
        revision: UInt64,
        generation: UInt64
    ) -> Bool {
        isCurrentWork(revision: revision, generation: generation)
            && terminalGate.phase == .capturing
            && firstFrameWatchdogOwner == owner
            && !hasFirstCompleteFrameEnqueued(
                generation: generation,
                workRevision: revision
            )
    }

    @discardableResult
    func installScrollMonitor() -> Bool {
        scrollMonitor = scrollMonitorInstaller { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.terminalGate.acceptsCallback(generation: self.terminalGate.generation) else { return }
                if event.type == .keyDown, Self.isCancelKeyCode(event.keyCode) {
                    self.requestCancel()
                    return
                }
                guard Self.captureInputIntent(for: event) == .sample else { return }
                if Self.requiresPointerInsideSelection(for: event.type),
                   !self.selectionRect.contains(NSEvent.mouseLocation) {
                    return
                }
                guard self.samplingGate.registerCaptureAttempt() else { return }
                self.cancelPossibleEnd()
                if self.motionSamplingTask == nil {
                    self.issueFrameDemand(
                        .motion(self.samplingGate.latestCaptureRequestSequence),
                        generation: self.terminalGate.generation
                    )
                }
                self.scheduleMotionSampleIfNeeded()
                self.scheduleSettledFrameEvaluation()
                let inverted = event.type == .scrollWheel ? event.isDirectionInvertedFromDevice : false
                self.logger.debug("stage=scroll-attempt inverted=\(inverted, privacy: .public)")
            }
        }
        return scrollMonitor != nil
    }

    func startActiveHealthMonitoring(generation: UInt64) {
        activeHealthTask?.cancel()
        activeHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.terminalGate.generation == generation {
                    self.activeHealthTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.activeHealthCheckInterval)
                } catch {
                    return
                }
                await self.checkActiveHealth(generation: generation)
                guard self.terminalGate.acceptsCallback(
                    generation: generation
                ) else { return }
            }
        }
    }

    func checkActiveHealth(generation: UInt64) async {
        guard terminalGate.acceptsCallback(generation: generation),
              !isManuallyPaused,
              let context = healthContext else { return }
        let revision = workRevision
        let currentContext = ScrollingScreenshotHealthContext(
            displayID: context.displayID,
            displayFrame: context.displayFrame,
            selectionRect: context.selectionRect,
            expectedPixelSize: context.expectedPixelSize,
            hasInputMonitor: scrollMonitor != nil
        )
        let health = await healthChecker.check(currentContext)
        guard isCurrentWork(revision: revision, generation: generation),
              !isManuallyPaused else { return }
        if case let .unhealthy(failure) = health {
            pause(warning: failure.localizedWarning)
        }
    }

    private func scheduleMotionSampleIfNeeded() {
        guard !isManuallyPaused, motionSamplingTask == nil else { return }
        let generation = terminalGate.generation
        let sequence = samplingGate.latestCaptureRequestSequence
        motionSamplingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.motionSampleInterval)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.terminalGate.acceptsCallback(generation: generation) else { return }
            self.motionSamplingTask = nil
            self.issueFrameDemand(.motion(sequence), generation: generation)
        }
    }

    private func scheduleSettledFrameEvaluation() {
        guard !isManuallyPaused else { return }
        settledFrameEvaluationTask?.cancel()
        let generation = terminalGate.generation
        let sequence = samplingGate.latestCaptureRequestSequence
        settledFrameEvaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.frameSettleDelay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.terminalGate.acceptsCallback(generation: generation),
                  self.samplingGate.latestCaptureRequestSequence == sequence else { return }
            if let motionTask = self.motionSamplingTask {
                await motionTask.value
            }
            guard !Task.isCancelled,
                  self.terminalGate.acceptsCallback(generation: generation) else { return }
            self.settledFrameEvaluationTask = nil
            self.issueFrameDemand(.settled(sequence), generation: generation)
        }
    }

    func scheduleRecoverySample() {
        recoverySamplingTask?.cancel()
        let generation = terminalGate.generation
        let attemptID = nextRecoveryAttemptID
        nextRecoveryAttemptID &+= 1
        recoverySamplingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.recoverySampleDelay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.terminalGate.acceptsCallback(generation: generation),
                  self.latestRuntimeState == .recovering,
                  !self.isManuallyPaused else { return }
            self.recoverySamplingTask = nil
            self.issueFrameDemand(.recovery(attemptID), generation: generation)
        }
    }

    func cancelRecoverySampling() {
        recoverySamplingTask?.cancel()
        recoverySamplingTask = nil
    }

    func schedulePossibleEndIfNeeded() {
        guard terminalGate.phase == .capturing,
              samplingGate.hasPendingCaptureAttempt,
              possibleEndTask == nil,
              !isManuallyPaused else { return }
        cancelPossibleEndResetWork()
        let generation = terminalGate.generation
        guard let sessionID = terminalGate.sessionID else { return }
        let revision = workRevision
        let owner = UUID()
        possibleEndTaskOwner = owner
        possibleEndTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.possibleEndTaskOwner == owner {
                    self.possibleEndTask = nil
                    self.possibleEndTaskOwner = nil
                }
            }
            for remaining in stride(from: 3, through: 1, by: -1) {
                guard self.isCurrentWork(revision: revision, generation: generation),
                      self.possibleEndTaskOwner == owner else { return }
                let snapshot = await self.session.setPossibleEnd(
                    true,
                    expectedSessionID: sessionID
                )
                guard self.isCurrentWork(revision: revision, generation: generation),
                      self.possibleEndTaskOwner == owner else { return }
                self.updateHUD(snapshot)
                self.hud.state.phase = .possibleEnd(secondsRemaining: remaining)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                let token = UUID()
                self.issueFrameDemand(.countdown(token), generation: generation)
                await self.waitForCountdownDemand(token, generation: generation)
                guard self.isCurrentWork(revision: revision, generation: generation),
                      self.possibleEndTaskOwner == owner,
                      self.samplingGate.hasPendingCaptureAttempt,
                      !self.isManuallyPaused else { return }
            }
            _ = self.requestFinish()
        }
    }

    private func waitForCountdownDemand(_ token: UUID, generation: UInt64) async {
        for _ in 0..<30 {
            guard terminalGate.acceptsCallback(generation: generation),
                  isCountdownDemandOutstanding(token) else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isCountdownDemandOutstanding(_ token: UUID) -> Bool {
        frameDemands.values.contains { $0.matchesCountdown(token) }
    }

    @discardableResult
    func cancelPossibleEnd() -> Bool {
        let requiresSessionReset = possibleEndTask != nil || latestRuntimeState == .possibleEnd
        resetPossibleEndWork()
        guard requiresSessionReset,
              possibleEndResetTask == nil,
              let sessionID = terminalGate.sessionID else { return false }
        let generation = terminalGate.generation
        let revision = workRevision
        let owner = UUID()
        possibleEndResetTaskOwner = owner
        possibleEndResetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.possibleEndResetTaskOwner == owner {
                    self.possibleEndResetTask = nil
                    self.possibleEndResetTaskOwner = nil
                }
            }
            guard self.isCurrentWork(revision: revision, generation: generation),
                  self.possibleEndResetTaskOwner == owner else { return }
            let snapshot = await self.session.setPossibleEnd(
                false,
                expectedSessionID: sessionID
            )
            guard self.isCurrentWork(revision: revision, generation: generation),
                  self.possibleEndResetTaskOwner == owner else { return }
            self.updateHUD(snapshot)
        }
        return true
    }

    func cancelPossibleEndAndRefreshHUD() async {
        resetPossibleEndWork()
        cancelPossibleEndResetWork()
        let generation = terminalGate.generation
        let revision = workRevision
        guard terminalGate.acceptsCallback(generation: generation),
              let sessionID = terminalGate.sessionID else { return }
        let snapshot = await session.setPossibleEnd(
            false,
            expectedSessionID: sessionID
        )
        guard isCurrentWork(revision: revision, generation: generation) else { return }
        updateHUD(snapshot)
    }

    func resetPossibleEndWork() {
        possibleEndTask?.cancel()
        possibleEndTask = nil
        possibleEndTaskOwner = nil
        removePendingDemands { demand in
            if case .countdown = demand { return true }
            return false
        }
    }

    func cancelPossibleEndResetWork() {
        possibleEndResetTask?.cancel()
        possibleEndResetTask = nil
        possibleEndResetTaskOwner = nil
    }

}
