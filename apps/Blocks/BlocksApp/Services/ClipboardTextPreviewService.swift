import BlocksCore
import Foundation

struct ClipboardTextPreview {
    let text: String
    let originalCharacterCount: Int
    let truncated: Bool
}

@MainActor
final class ClipboardTextPreviewService {
    private let broker: any ClipboardBrokerServing
    private let pasteboardWriter: ClipboardPasteboardWriter

    init(broker: any ClipboardBrokerServing = ClipboardBrokerClient.shared) {
        self.broker = broker
        pasteboardWriter = ClipboardPasteboardWriter(broker: broker)
    }

    func currentPlainText(maxCharacters: Int = 4_000) async -> ClipboardTextPreview? {
        let result: ClipboardBrokerPlainTextResult
        do {
            result = try await broker.currentPlainText(limit: maxCharacters)
        } catch {
            return nil
        }
        guard let text = result.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let originalCharacterCount = result.truncated
            ? result.originalCharacterCount
            : trimmed.count
        return ClipboardTextPreview(
            text: trimmed,
            originalCharacterCount: originalCharacterCount,
            truncated: result.truncated
        )
    }

    func writePlainText(_ text: String) async -> Bool {
        do {
            _ = try await pasteboardWriter.writePlainText(text)
            return true
        } catch {
            return false
        }
    }
}
