import Foundation

typealias ClipboardVisionTextRecognition = LocalVisionOCRResult
typealias ClipboardVisionTextRecognizerError = LocalVisionOCRError

protocol ClipboardVisionTextRecognizer {
    func recognizeText(
        from imageData: Data,
        context: LocalOCRRequestContext,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> ClipboardVisionTextRecognition
}

struct AppleVisionTextRecognizer: ClipboardVisionTextRecognizer {
    private let coordinator: LocalOCRCoordinator

    init(coordinator: LocalOCRCoordinator = LocalOCRCoordinator()) {
        self.coordinator = coordinator
    }

    func recognizeText(
        from imageData: Data,
        context: LocalOCRRequestContext,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> ClipboardVisionTextRecognition {
        try await coordinator.recognizeText(
            from: imageData,
            context: context,
            requestToken: requestToken
        )
    }
}

final class MockClipboardVisionTextRecognizer: ClipboardVisionTextRecognizer {
    enum ScriptedResult: Equatable {
        case succeeded(String)
        case failed(String)
        case runningHold(String)
    }

    private let lock = NSLock()
    private var scriptedResults: [ScriptedResult]
    private var runningContinuations: [CheckedContinuation<ClipboardVisionTextRecognition, Error>] = []

    init(scriptedResults: [ScriptedResult] = [.succeeded("VISION-004")]) {
        self.scriptedResults = scriptedResults
    }

    var runningHoldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runningContinuations.count
    }

    func recognizeText(
        from imageData: Data,
        context: LocalOCRRequestContext,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> ClipboardVisionTextRecognition {
        guard !imageData.isEmpty else {
            throw ClipboardVisionTextRecognizerError.imageDataUnavailable
        }
        try requestToken.checkCancellation()

        switch nextScriptedResult() {
        case .succeeded(let text):
            return recognition(text: text)
        case .failed(let code):
            throw ClipboardVisionTextRecognizerError.fixtureFailed(code)
        case .runningHold:
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                runningContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseRunningHold(text: String = "VISION-004") {
        let continuations = drainRunningContinuations()
        let result = recognition(text: text)
        continuations.forEach { continuation in
            continuation.resume(returning: result)
        }
    }

    func failRunningHold(code: String = "fixture_running_hold_failed") {
        let continuations = drainRunningContinuations()
        continuations.forEach { continuation in
            continuation.resume(throwing: ClipboardVisionTextRecognizerError.fixtureFailed(code))
        }
    }

    private func nextScriptedResult() -> ScriptedResult {
        lock.lock()
        defer { lock.unlock() }
        guard !scriptedResults.isEmpty else {
            return .succeeded("VISION-004")
        }
        return scriptedResults.removeFirst()
    }

    private func drainRunningContinuations() -> [CheckedContinuation<ClipboardVisionTextRecognition, Error>] {
        lock.lock()
        defer { lock.unlock() }
        let continuations = runningContinuations
        runningContinuations.removeAll()
        return continuations
    }

    private func recognition(text: String) -> ClipboardVisionTextRecognition {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ClipboardVisionTextRecognition(text: text, lineCount: max(1, lines.count))
    }
}
