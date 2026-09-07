import BlocksCore
import Foundation
import OSLog

actor ClipboardVisionOCRQueue {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-ocr"
    )
    enum OCRQueueResult: Equatable {
        case completed(recordID: String)
        case failed(recordID: String, errorCode: String)
        case skipped(recordID: String, reason: String)
    }

    private let repository: ClipboardRepository
    private let recognizer: ClipboardVisionTextRecognizer
    private let applicationUpdateGate: ApplicationOperationAdmissionGate
    private var runningRecordIDs: Set<String> = []

    init(
        repository: ClipboardRepository,
        ocrCoordinator: LocalOCRCoordinator = LocalOCRCoordinator(),
        applicationUpdateGate: ApplicationOperationAdmissionGate = ApplicationOperationAdmissionGate(name: "Clipboard OCR")
    ) {
        self.repository = repository
        self.recognizer = AppleVisionTextRecognizer(coordinator: ocrCoordinator)
        self.applicationUpdateGate = applicationUpdateGate
    }

    init(
        repository: ClipboardRepository,
        recognizer: ClipboardVisionTextRecognizer,
        applicationUpdateGate: ApplicationOperationAdmissionGate = ApplicationOperationAdmissionGate(name: "Clipboard OCR")
    ) {
        self.repository = repository
        self.recognizer = recognizer
        self.applicationUpdateGate = applicationUpdateGate
    }

    func processPending(
        limit: Int = 1,
        context: LocalOCRRequestContext = .clipboardImage
    ) async -> [OCRQueueResult] {
        guard let lease = applicationUpdateGate.begin() else { return [] }
        defer { lease.release() }
        do {
            let documents = try repository.loadPendingOCRDocuments(limit: max(1, limit))
            var results: [OCRQueueResult] = []
            for document in documents {
                results.append(await process(
                    recordID: document.recordID,
                    revision: document.revision,
                    context: context
                ))
            }
            return results
        } catch {
            return []
        }
    }

    func processQueued(
        recordID: String,
        revision: String,
        context: LocalOCRRequestContext = .clipboardImage
    ) async -> OCRQueueResult {
        guard let lease = applicationUpdateGate.begin() else {
            return .skipped(recordID: recordID, reason: "application_update_paused")
        }
        defer { lease.release() }
        return await process(recordID: recordID, revision: revision, context: context)
    }

    func retryOCR(recordID: String) async -> OCRQueueResult {
        guard let lease = applicationUpdateGate.begin() else {
            return .skipped(recordID: recordID, reason: "application_update_paused")
        }
        defer { lease.release() }
        do {
            guard !runningRecordIDs.contains(recordID) else {
                return .skipped(recordID: recordID, reason: "already_running")
            }
            let preparation = try repository.prepareOCRRetry(recordID: recordID)
            switch preparation {
            case .alreadyRunning:
                return .skipped(recordID: recordID, reason: "already_running")
            case .locked:
                return .skipped(recordID: recordID, reason: "user_edited_ocr_locked")
            case .documentMissing:
                return .skipped(recordID: recordID, reason: "document_missing")
            case let .ready(document), let .alreadyPending(document):
                return await process(
                    recordID: document.recordID,
                    revision: document.revision,
                    context: .retry
                )
            }
        } catch {
            return .failed(recordID: recordID, errorCode: "retry_failed")
        }
    }

    private func process(
        recordID: String,
        revision: String,
        context: LocalOCRRequestContext
    ) async -> OCRQueueResult {
        guard runningRecordIDs.insert(recordID).inserted else {
            return .skipped(recordID: recordID, reason: "already_running")
        }
        defer { runningRecordIDs.remove(recordID) }

        do {
            guard let document = try repository.loadSearchDocument(recordID: recordID),
                  document.revision == revision else {
                return .skipped(recordID: recordID, reason: "revision_mismatch")
            }
            guard document.ocrState == .pending || document.ocrState == .failed else {
                return .skipped(recordID: recordID, reason: "state_not_pending")
            }
            guard document.ocrTextSource != .userEdited,
                  document.ocrLockedContentRevision == nil else {
                return .skipped(recordID: recordID, reason: "user_edited_ocr_locked")
            }

            let beginPersistState = Self.signposter.beginInterval("OCRPersist", "transition=running")
            let didBegin = try repository.updateOCRResult(
                recordID: recordID,
                revision: revision,
                text: nil,
                state: .running,
                errorCode: nil
            )
            Self.signposter.endInterval("OCRPersist", beginPersistState)
            guard didBegin else {
                return .skipped(recordID: recordID, reason: "running_update_rejected")
            }

            guard let payload = try readOCRInputPayload(recordID: recordID),
                  payload.kind == .image,
                  let imageData = payload.pngData,
                  !imageData.isEmpty else {
                return try fail(recordID: recordID, revision: revision, errorCode: "image_payload_unavailable")
            }

            let requestToken = LocalVisionOCRRequestToken()
            let recognized = try await withTaskCancellationHandler {
                try await recognizer.recognizeText(
                    from: imageData,
                    context: context,
                    requestToken: requestToken
                )
            } onCancel: {
                requestToken.cancel()
            }
            try Task.checkCancellation()
            try requestToken.checkCancellation()
            let successPersistState = Self.signposter.beginInterval("OCRPersist", "transition=succeeded")
            let didSucceed = try repository.updateOCRResult(
                recordID: recordID,
                revision: revision,
                text: recognized.text,
                state: .succeeded,
                errorCode: nil
            )
            Self.signposter.endInterval("OCRPersist", successPersistState)
            guard didSucceed else {
                return .skipped(recordID: recordID, reason: "succeeded_update_rejected")
            }
            return .completed(recordID: recordID)
        } catch is CancellationError {
            _ = try? repository.returnOCRToPending(recordID: recordID, revision: revision)
            return .skipped(recordID: recordID, reason: "cancelled")
        } catch {
            return (try? fail(recordID: recordID, revision: revision, errorCode: errorCode(for: error)))
                ?? .failed(recordID: recordID, errorCode: "ocr_failed")
        }
    }

    private func readOCRInputPayload(recordID: String) throws -> ClipboardRecorderPayload? {
        let purpose = ClipboardPayloadReadPurpose.ocrInput
        guard purpose == .ocrInput else {
            return nil
        }
        return try repository.readPayload(recordID: recordID)
    }

    private func fail(recordID: String, revision: String, errorCode: String) throws -> OCRQueueResult {
        let persistState = Self.signposter.beginInterval("OCRPersist", "transition=failed")
        defer { Self.signposter.endInterval("OCRPersist", persistState) }
        _ = try repository.updateOCRResult(
            recordID: recordID,
            revision: revision,
            text: nil,
            state: .failed,
            errorCode: errorCode
        )
        return .failed(recordID: recordID, errorCode: errorCode)
    }

    private func errorCode(for error: Error) -> String {
        if let recognizerError = error as? ClipboardVisionTextRecognizerError {
            return recognizerError.lowSensitivityCode
        }
        return "ocr_failed"
    }
}
