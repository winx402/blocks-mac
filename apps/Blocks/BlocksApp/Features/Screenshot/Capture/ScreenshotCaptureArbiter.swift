import BlocksScreenshotCore
import Foundation

enum ScreenshotCaptureOwner: Equatable {
    case standard
    case translation
}

enum ScreenshotCaptureArbitrationError: Error, Equatable {
    case busy(activeOwner: ScreenshotCaptureOwner)
}

/// Owns the single interactive capture surface shared by standard screenshots
/// and screenshot translation. Standard capture may preempt translation;
/// translation never interrupts an active standard capture.
@MainActor
final class ScreenshotCaptureArbiter {
    private struct ActiveSession {
        let id: UUID
        let owner: ScreenshotCaptureOwner
        var task: Task<ScreenshotCapture, Error>?
    }

    private let captureService: any ScreenshotPurposeCapturing
    private let scrollingController:
        (any ScreenshotScrollingSessionControlling)?
    private let scrollingModePreparer:
        (any ScreenshotScrollingModePreparing)?
    private var activeSession: ActiveSession?

    init(captureService: any ScreenshotPurposeCapturing) {
        self.captureService = captureService
        scrollingController =
            captureService as? any ScreenshotScrollingSessionControlling
        scrollingModePreparer =
            captureService as? any ScreenshotScrollingModePreparing
    }

    func makeTranslationCaptureService()
        -> any ScreenshotPurposeCapturing
    {
        TranslationCaptureClient(arbiter: self)
    }

    fileprivate func capture(
        owner: ScreenshotCaptureOwner,
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool,
        purpose: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture {
        let reservation = try reserve(owner: owner)
        let sessionID = reservation.id
        defer { finish(owner: owner, sessionID: sessionID) }

        if let previousTask = reservation.previousTask {
            previousTask.cancel()
            captureService.cancelCurrentCapture()
            _ = try? await previousTask.value
        }

        try Task.checkCancellation()
        guard activeSession?.id == sessionID else {
            throw CancellationError()
        }

        let task = Task { @MainActor [captureService] in
            try Task.checkCancellation()
            return try await captureService.capture(
                intent: intent,
                requiresEditingContext: requiresEditingContext,
                purpose: purpose
            )
        }
        activeSession?.task = task
        return try await task.value
    }

    private func reserve(
        owner: ScreenshotCaptureOwner
    ) throws -> (
        id: UUID,
        previousTask: Task<ScreenshotCapture, Error>?
    ) {
        var previousTask: Task<ScreenshotCapture, Error>?
        if let activeSession {
            switch (owner, activeSession.owner) {
            case (.standard, .translation),
                 (.translation, .translation):
                previousTask = activeSession.task
            case (.standard, .standard),
                 (.translation, .standard):
                throw ScreenshotCaptureArbitrationError.busy(
                    activeOwner: activeSession.owner
                )
            }
        }
        let sessionID = UUID()
        activeSession = ActiveSession(
            id: sessionID,
            owner: owner,
            task: previousTask
        )
        return (sessionID, previousTask)
    }

    private func finish(
        owner: ScreenshotCaptureOwner,
        sessionID: UUID
    ) {
        guard activeSession?.id == sessionID,
              activeSession?.owner == owner else {
            return
        }
        activeSession = nil
    }

    fileprivate func cancel(owner: ScreenshotCaptureOwner) {
        guard activeSession?.owner == owner else { return }
        activeSession?.task?.cancel()
        activeSession = nil
        captureService.cancelCurrentCapture()
    }

#if DEBUG
    var activeOwnerForTesting: ScreenshotCaptureOwner? {
        activeSession?.owner
    }
#endif
}

extension ScreenshotCaptureArbiter: ScreenshotCapturing {
    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool
    ) async throws -> ScreenshotCapture {
        try await capture(
            owner: .standard,
            intent: intent,
            requiresEditingContext: requiresEditingContext,
            purpose: .standard
        )
    }

    func cancelCurrentCapture() {
        cancel(owner: .standard)
    }
}

extension ScreenshotCaptureArbiter:
    ScreenshotScrollingSessionControlling,
    ScreenshotScrollingModePreparing
{
    func scrollingSessionStatus()
        async -> ScrollingScreenshotRuntimeSnapshot
    {
        guard let scrollingController else {
            return ScrollingScreenshotRuntimeSnapshot(
                sessionID: nil,
                state: .idle,
                outputSize: ScreenshotPixelSize(width: 0, height: 0),
                warning: nil
            )
        }
        return await scrollingController.scrollingSessionStatus()
    }

    func finishScrollingSession(sessionID: String) -> Bool {
        scrollingController?.finishScrollingSession(
            sessionID: sessionID
        ) ?? false
    }

    func cancelScrollingSession(
        sessionID: String,
        confirm: Bool
    ) async -> ScrollingScreenshotControlResult {
        guard let scrollingController else {
            return .rejected(.staleSession, state: .idle)
        }
        return await scrollingController.cancelScrollingSession(
            sessionID: sessionID,
            confirm: confirm
        )
    }

    func finishScrollingEditingSession(
        sessionID: String,
        terminal: ScrollingScreenshotSessionTerminal
    ) async -> ScrollingScreenshotControlResult {
        guard let scrollingController else {
            return .rejected(.staleSession, state: .idle)
        }
        return await scrollingController.finishScrollingEditingSession(
            sessionID: sessionID,
            terminal: terminal
        )
    }

    func prepareScrollingModeForNextCapture() {
        scrollingModePreparer?.prepareScrollingModeForNextCapture()
    }

    func cancelPreparedScrollingModeForNextCapture() {
        scrollingModePreparer?.cancelPreparedScrollingModeForNextCapture()
    }
}

@MainActor
private final class TranslationCaptureClient:
    ScreenshotPurposeCapturing
{
    private let arbiter: ScreenshotCaptureArbiter

    init(arbiter: ScreenshotCaptureArbiter) {
        self.arbiter = arbiter
    }

    func capture(
        intent: ScreenshotCaptureIntent,
        requiresEditingContext: Bool,
        purpose: ScreenshotCapturePurpose
    ) async throws -> ScreenshotCapture {
        try await arbiter.capture(
            owner: .translation,
            intent: intent,
            requiresEditingContext: requiresEditingContext,
            purpose: purpose
        )
    }

    func cancelCurrentCapture() {
        arbiter.cancel(owner: .translation)
    }
}
