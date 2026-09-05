import CoreGraphics
import Foundation

enum TranslationOCRServicePreference {
    static var prefersPlugin: Bool {
        let selected = UserDefaults.standard.string(
            forKey: "translation.ocr.defaultServiceID"
        ) ?? "apple-vision"
        return selected.hasPrefix("plugin:")
    }
}

struct TranslationScreenshotOCRSnapshot: Equatable, Sendable {
    let text: String
    let lineCount: Int
    let meanConfidence: Float
}

protocol TranslationScreenshotOCRProviding: Sendable {
    func recognizeText(
        in capture: TranslationScreenshotCapture,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> TranslationScreenshotOCRSnapshot
}

/// Adapts the existing Apple Vision OCR engine to translation screenshot input.
/// The adapter owns no session state; cancellation remains cooperative through
/// the existing request token and the translation run revision owns freshness.
final class LocalVisionTranslationOCRAdapter: TranslationScreenshotOCRProviding, @unchecked Sendable {
    typealias Recognize = @Sendable (
        _ image: CGImage,
        _ requestToken: LocalVisionOCRRequestToken
    ) async throws -> LocalVisionOCRResult

    private let recognize: Recognize

    init(coordinator: LocalOCRCoordinator = LocalOCRCoordinator()) {
        recognize = { image, requestToken in
            try await coordinator.recognizeText(
                in: image,
                context: .translationScreenshot,
                requestToken: requestToken
            )
        }
    }

    init(recognize: @escaping Recognize) {
        self.recognize = recognize
    }

    func recognizeText(
        in capture: TranslationScreenshotCapture,
        requestToken: LocalVisionOCRRequestToken = LocalVisionOCRRequestToken()
    ) async throws -> TranslationScreenshotOCRSnapshot {
        let result = try await recognize(capture.cgImage, requestToken)
        return TranslationScreenshotOCRSnapshot(
            text: result.text,
            lineCount: result.lineCount,
            meanConfidence: result.meanConfidence
        )
    }
}

@MainActor
final class TranslationOCRExecutionRegistry {
    private final class Execution {
        let id: UUID
        let token: LocalVisionOCRRequestToken
        var task: Task<Void, Never>?
        weak var model: TranslationPanelSessionModel?

        init(
            id: UUID,
            token: LocalVisionOCRRequestToken,
            model: TranslationPanelSessionModel
        ) {
            self.id = id
            self.token = token
            self.model = model
        }
    }

    private var executions: [UUID: Execution] = [:]

    var count: Int { executions.count }

    func begin(
        modelID: UUID,
        executionID: UUID,
        token: LocalVisionOCRRequestToken,
        model: TranslationPanelSessionModel
    ) {
        cancel(modelID: modelID)
        executions[modelID] = Execution(
            id: executionID,
            token: token,
            model: model
        )
    }

    func installTask(
        _ task: Task<Void, Never>,
        modelID: UUID,
        executionID: UUID
    ) {
        guard executions[modelID]?.id == executionID else {
            task.cancel()
            return
        }
        executions[modelID]?.task = task
    }

    func isCurrent(
        modelID: UUID,
        executionID: UUID,
        token: LocalVisionOCRRequestToken
    ) -> Bool {
        guard !Task.isCancelled,
              !token.isCancelled,
              let execution = executions[modelID] else {
            return false
        }
        return execution.id == executionID
            && execution.token === token
    }

    func finish(modelID: UUID, executionID: UUID) {
        guard executions[modelID]?.id == executionID else { return }
        executions.removeValue(forKey: modelID)
    }

    func cancel(modelID: UUID) {
        guard let execution = executions.removeValue(forKey: modelID) else {
            return
        }
        execution.token.cancel()
        execution.task?.cancel()
    }

    @discardableResult
    func cancelAll() -> [TranslationPanelSessionModel] {
        let active = executions
        executions.removeAll()
        for execution in active.values {
            execution.token.cancel()
            execution.task?.cancel()
        }
        return active.values.compactMap(\.model)
    }
}
