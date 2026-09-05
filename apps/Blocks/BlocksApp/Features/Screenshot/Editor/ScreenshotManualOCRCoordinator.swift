import CoreGraphics
import BlocksScreenshotCore
import Foundation

enum ScreenshotManualOCRFailure: Equatable {
    case timedOut
    case recognitionFailed
}

enum ScreenshotManualOCRState: Equatable {
    case idle
    case selecting(ScreenshotPixelRect)
    case recognizing(requestID: UUID, region: ScreenshotPixelRect, revision: UInt64)
    case result(requestID: UUID, region: ScreenshotPixelRect, revision: UInt64, text: String)
    case failed(requestID: UUID, region: ScreenshotPixelRect, revision: UInt64, reason: ScreenshotManualOCRFailure)

    var isLocked: Bool {
        if case .recognizing = self { return true }
        return false
    }
}

@MainActor
final class ScreenshotManualOCRCoordinator: ObservableObject {
    typealias Recognizer = @Sendable (CGImage) async throws -> String
    typealias Completion = @MainActor @Sendable (
        UUID,
        ScreenshotPixelRect,
        UInt64,
        String
    ) -> Void

    @Published private(set) var state: ScreenshotManualOCRState = .idle

    private let recognizer: Recognizer
    private let onCompleted: Completion
    private let timeout: Duration
    private var activeRequestID: UUID?
    private var recognitionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        timeout: Duration = .seconds(30),
        onCompleted: @escaping Completion = { _, _, _, _ in },
        recognizer: @escaping Recognizer
    ) {
        self.timeout = timeout
        self.onCompleted = onCompleted
        self.recognizer = recognizer
    }

    deinit {
        recognitionTask?.cancel()
        timeoutTask?.cancel()
    }

    func beginSelection(at point: ScreenshotPixelPoint) {
        guard !state.isLocked else { return }
        state = .selecting(ScreenshotPixelRect(
            x: Int(point.x.rounded()),
            y: Int(point.y.rounded()),
            width: 0,
            height: 0
        ))
    }

    func updateSelection(from start: ScreenshotPixelPoint, to current: ScreenshotPixelPoint) {
        guard !state.isLocked else { return }
        state = .selecting(ScreenshotPixelRect(
            x: Int(min(start.x, current.x).rounded()),
            y: Int(min(start.y, current.y).rounded()),
            width: Int(abs(current.x - start.x).rounded()),
            height: Int(abs(current.y - start.y).rounded())
        ))
    }

    @discardableResult
    func recognize(
        image: CGImage,
        region: ScreenshotPixelRect,
        revision: UInt64
    ) -> UUID? {
        guard let requestID = prepareRecognition(
            region: region,
            revision: revision
        ) else { return nil }
        guard recognizePrepared(image: image, requestID: requestID) else {
            cancel()
            return nil
        }
        return requestID
    }

    @discardableResult
    func prepareRecognition(
        region: ScreenshotPixelRect,
        revision: UInt64
    ) -> UUID? {
        guard !state.isLocked, region.width > 0, region.height > 0 else { return nil }
        recognitionTask?.cancel()
        timeoutTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        state = .recognizing(requestID: requestID, region: region, revision: revision)
        return requestID
    }

    @discardableResult
    func recognizePrepared(image: CGImage, requestID: UUID) -> Bool {
        guard activeRequestID == requestID,
              case let .recognizing(activeID, region, revision) = state,
              activeID == requestID else {
            return false
        }
        let recognizer = self.recognizer
        let timeout = self.timeout
        recognitionTask = Task { [weak self] in
            do {
                let text = try await recognizer(image)
                self?.finish(
                    requestID: requestID,
                    region: region,
                    revision: revision,
                    text: text
                )
            } catch is CancellationError {
                return
            } catch {
                self?.fail(
                    requestID: requestID,
                    region: region,
                    revision: revision,
                    reason: .recognitionFailed
                )
            }
        }
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.fail(
                requestID: requestID,
                region: region,
                revision: revision,
                reason: .timedOut
            )
        }
        return true
    }

    func updateResultText(_ text: String) {
        guard case let .result(requestID, region, revision, _) = state else { return }
        state = .result(requestID: requestID, region: region, revision: revision, text: text)
    }

    func invalidate(for revision: UInt64) {
        switch state {
        case let .recognizing(_, _, activeRevision),
             let .result(_, _, activeRevision, _),
             let .failed(_, _, activeRevision, _):
            guard revision != activeRevision else { return }
            cancel()
        case .idle, .selecting:
            break
        }
    }

    func closeResult() {
        guard !state.isLocked else { return }
        activeRequestID = nil
        state = .idle
    }

    func cancel() {
        _ = claimTerminal(requestID: activeRequestID)
        recognitionTask?.cancel()
        recognitionTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        state = .idle
    }

    private func finish(
        requestID: UUID,
        region: ScreenshotPixelRect,
        revision: UInt64,
        text: String
    ) {
        guard claimTerminal(requestID: requestID) else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        recognitionTask = nil
        state = .result(requestID: requestID, region: region, revision: revision, text: text)
        onCompleted(requestID, region, revision, text)
    }

    private func fail(
        requestID: UUID,
        region: ScreenshotPixelRect,
        revision: UInt64,
        reason: ScreenshotManualOCRFailure
    ) {
        guard claimTerminal(requestID: requestID) else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        state = .failed(requestID: requestID, region: region, revision: revision, reason: reason)
    }

    private func claimTerminal(requestID: UUID?) -> Bool {
        guard let requestID, activeRequestID == requestID else { return false }
        activeRequestID = nil
        return true
    }
}
