import AppKit
import BlocksScreenshotCore
import CoreGraphics
import Foundation
import os

// First-terminal-wins completion, cancellation and resource teardown.
@MainActor
extension ScrollingScreenshotCaptureCoordinator {
    @discardableResult
    func requestFinish() -> Bool {
        guard continuation != nil,
              terminalGate.sessionID != nil,
              terminalGate.markFinalizing(generation: terminalGate.generation) else { return false }
        let generation = terminalGate.generation
        prepareForFinalization()
        hud.state.phase = .finalizing
        latestRuntimeState = .finalizing
        finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var didStopFrameSource = false
            do {
                guard await self.waitForFramePipelineDrain(generation: generation) else {
                    throw ScrollingScreenshotSessionError.invalidState
                }
                self.teardownSurfaces()
                let didStopFrameSourceBeforeDeadline = await self.stopFrameSourceBounded(
                    generation: generation
                )
                didStopFrameSource = true
                guard didStopFrameSourceBeforeDeadline else {
                    throw ScreenshotCaptureError.captureFailed(L10n.string("status.failed.detail"))
                }
                let image = try await self.session.finalize()
                guard !Task.isCancelled,
                      self.terminalGate.markEditing(generation: generation) else { return }
                self.finalizationTask = nil
                self.resolveCaptureForEditing(image)
            } catch is CancellationError {
                return
            } catch {
                guard self.terminalGate.acceptsCallback(generation: generation) else { return }
                self.finalizationTask = nil
                await self.fail(
                    error,
                    generation: generation,
                    shouldStopFrameSource: !didStopFrameSource
                )
            }
        }
        return true
    }

    func requestCancel() {
        Task { @MainActor [weak self] in
            guard let self,
                  let sessionID = self.terminalGate.sessionID,
                  !self.isCancellationPromptPresented else { return }
            let snapshot = await self.session.status()
            if snapshot.outputSize.height > 0 {
                self.isCancellationPromptPresented = true
                await self.cancelPossibleEndAndRefreshHUD()
                let confirmed = await self.hud.confirmDiscard()
                self.isCancellationPromptPresented = false
                guard confirmed else { return }
            }
            _ = await self.cancelConfirmed(sessionID: sessionID)
        }
    }

    func cancelConfirmed(sessionID: String) async -> ScrollingScreenshotControlFailure? {
        let generation = terminalGate.generation
        switch terminalGate.claim(sessionID: sessionID, generation: generation, terminal: .cancelled) {
        case .staleSession:
            return .staleSession
        case .alreadyTerminal:
            return .alreadyTerminal
        case .accepted:
            break
        }
        _ = invalidateAsynchronousWork()
        let task = finalizationTask
        finalizationTask = nil
        task?.cancel()
        possibleEndTask?.cancel()
        possibleEndTask = nil
        possibleEndTaskOwner = nil
        cancelPossibleEndResetWork()
        resumeHealthTask?.cancel()
        resumeHealthTask = nil
        activeHealthTask?.cancel()
        activeHealthTask = nil
        teardownSurfaces()
        _ = await stopFrameSourceBounded(generation: generation)
        var cleanupFailure: ScrollingScreenshotControlFailure?
        do {
            try await session.cancel(confirm: true)
        } catch ScrollingScreenshotSessionError.cleanupFailed {
            cleanupFailure = .cleanupFailed
            await session.releaseSessionAfterCleanupFailure()
            logger.error("stage=scrolling-cancel-cleanup-failed")
        } catch {
            cleanupFailure = .invalidState
        }
        resolveCaptureTerminal(.failure(ScreenshotCaptureError.cancelled))
        return cleanupFailure
    }

    func fail(
        _ error: Error,
        generation: UInt64,
        shouldStopFrameSource: Bool = true
    ) async {
        guard terminalGate.acceptsCallback(generation: generation),
              let sessionID = terminalGate.sessionID else { return }
        guard terminalGate.claim(
            sessionID: sessionID,
            generation: generation,
            terminal: .failed
        ) == .accepted else { return }
        _ = invalidateAsynchronousWork()
        teardownSurfaces()
        if shouldStopFrameSource {
            _ = await stopFrameSourceBounded(generation: generation)
        }
        do {
            try await session.cancel(confirm: true)
        } catch {
            await session.releaseSessionAfterCleanupFailure()
            logger.error("stage=scrolling-failure-cleanup-failed code=\((error as NSError).code, privacy: .public)")
        }
        resolveCaptureTerminal(.failure(error))
    }

    private func resolveCaptureForEditing(_ image: CGImage) {
        guard let continuation else { return }
        self.continuation = nil
        latestRuntimeState = .editing
        teardownSurfaces()
        continuation.resume(returning: image)
    }

    private func resolveCaptureTerminal(_ result: Result<CGImage, Error>) {
        let continuation = continuation
        self.continuation = nil
        latestRuntimeState = .idle
        teardownSurfaces()
        continuation?.resume(with: result)
    }

    private func stopFrameSourceBounded(generation: UInt64) async -> Bool {
        if stoppedFrameSourceGenerations.contains(generation) {
            guard frameSourceStopGeneration == generation,
                  frameSourceStopOwner != nil else { return true }
            return await withCheckedContinuation { continuation in
                frameSourceStopWaiters.append(continuation)
            }
        }

        stoppedFrameSourceGenerations.insert(generation)
        let owner = UUID()
        frameSourceStopGeneration = generation
        frameSourceStopOwner = owner
        return await withCheckedContinuation { continuation in
            frameSourceStopWaiters.append(continuation)
            let frameSource = self.frameSource
            frameSourceStopTask = Task { @MainActor [weak self, frameSource] in
                // Retain only the provider while it is stopping. A provider
                // that ignores cancellation must not retain the coordinator
                // (and its completed session) forever after the deadline.
                await frameSource.stop(generation: generation)
                self?.completeFrameSourceStop(
                    owner: owner,
                    generation: generation,
                    didReachDeadline: false
                )
            }
            frameSourceStopDeadlineTask = Task { @MainActor [weak self] in
                guard let self,
                      await self.frameSourceStopDeadlineWait(self.frameSourceStopDeadline),
                      !Task.isCancelled else { return }
                self.logger.warning("stage=scrolling-stream-stop-timeout generation=\(generation, privacy: .public)")
                self.completeFrameSourceStop(
                    owner: owner,
                    generation: generation,
                    didReachDeadline: true
                )
            }
        }
    }

    private func completeFrameSourceStop(
        owner: UUID,
        generation: UInt64,
        didReachDeadline: Bool
    ) {
        guard frameSourceStopOwner == owner,
              frameSourceStopGeneration == generation else { return }
        frameSourceStopOwner = nil
        frameSourceStopGeneration = nil
        frameSourceStopDeadlineTask?.cancel()
        frameSourceStopDeadlineTask = nil
        // SCStream.stopCapture can ignore cancellation. A timed-out call may finish later,
        // but its owner is detached so it cannot mutate a replacement capture.
        if didReachDeadline {
            frameSourceStopTask?.cancel()
        }
        frameSourceStopTask = nil
        let waiters = frameSourceStopWaiters
        frameSourceStopWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: !didReachDeadline) }
    }

    func teardownSurfaces() {
        if let scrollMonitor { scrollMonitorRemover(scrollMonitor) }
        scrollMonitor = nil
        possibleEndTask?.cancel()
        possibleEndTask = nil
        possibleEndTaskOwner = nil
        cancelPossibleEndResetWork()
        motionSamplingTask?.cancel()
        motionSamplingTask = nil
        settledFrameEvaluationTask?.cancel()
        settledFrameEvaluationTask = nil
        cancelRecoverySampling()
        _ = invalidateAsynchronousWork()
        resumeHealthTask?.cancel()
        resumeHealthTask = nil
        activeHealthTask?.cancel()
        activeHealthTask = nil
        hud.dismiss()
        hud.state.isCheckingResume = false
        hud.state.isRestarting = false
        selectionRect = .zero
        healthContext = nil
        samplingGate.reset()
        frameDemands.removeAll(keepingCapacity: true)
        receivedFrames.removeAll(keepingCapacity: true)
        isEvaluatingFrame = false
        isCancellationPromptPresented = false
    }

    private func prepareForFinalization() {
        clearFirstCompleteFrameState()
        if let scrollMonitor { scrollMonitorRemover(scrollMonitor) }
        scrollMonitor = nil
        possibleEndTask?.cancel()
        possibleEndTask = nil
        possibleEndTaskOwner = nil
        cancelPossibleEndResetWork()
        motionSamplingTask?.cancel()
        motionSamplingTask = nil
        settledFrameEvaluationTask?.cancel()
        settledFrameEvaluationTask = nil
        cancelRecoverySampling()
        activeHealthTask?.cancel()
        activeHealthTask = nil
    }

}
