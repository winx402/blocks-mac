import Foundation
import BlocksCore

@MainActor
final class ClipboardOCRScheduler {
    private let queue: ClipboardVisionOCRQueue
    private let applicationUpdateGate: ApplicationOperationAdmissionGate
    private let onRecordsUpdated: @MainActor (Set<String>) -> Void
    private var processingTask: Task<Void, Never>?
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var drainRequested = false
    private var notBefore = Date.distantPast
    private var pendingContext: LocalOCRRequestContext = .clipboardImage

    init(
        queue: ClipboardVisionOCRQueue,
        applicationUpdateGate: ApplicationOperationAdmissionGate = ApplicationOperationAdmissionGate(name: "Clipboard OCR scheduler"),
        onRecordsUpdated: @escaping @MainActor (Set<String>) -> Void
    ) {
        self.queue = queue
        self.applicationUpdateGate = applicationUpdateGate
        self.onRecordsUpdated = onRecordsUpdated
    }

    func schedule(
        context: LocalOCRRequestContext,
        quietDelay: TimeInterval
    ) {
        drainRequested = true
        if context == .startupRecovery, processingTask != nil {
            return
        }
        pendingContext = context
        notBefore = Date().addingTimeInterval(max(0, quietDelay))
        guard processingTask == nil else { return }

        let queue = queue
        processingTask = applicationUpdateGate.task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let delay = self.notBefore.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { break }
                    continue
                }
                self.drainRequested = false
                let results = await queue.processPending(
                    limit: 1,
                    context: self.pendingContext
                )
                guard !Task.isCancelled else { break }
                if results.isEmpty {
                    if self.drainRequested { continue }
                    break
                }
                let recordIDs = Self.updatedRecordIDs(in: results)
                if !recordIDs.isEmpty {
                    self.onRecordsUpdated(recordIDs)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.processingTask = nil
            if self.drainRequested {
                self.schedule(context: self.pendingContext, quietDelay: 0)
            }
        }
    }

    func retry(recordID: String) {
        retryTasks[recordID]?.cancel()
        let queue = queue
        retryTasks[recordID] = applicationUpdateGate.task { @MainActor [weak self] in
            let result = await queue.retryOCR(recordID: recordID)
            guard let self, !Task.isCancelled else { return }
            let recordIDs = Self.updatedRecordIDs(in: [result])
            if !recordIDs.isEmpty {
                self.onRecordsUpdated(recordIDs)
            }
            self.retryTasks[recordID] = nil
        }
    }

    func shutdown() {
        drainRequested = false
        processingTask?.cancel()
        processingTask = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
    }

    func resumeAfterCancelledApplicationUpdate() {
        guard drainRequested, processingTask == nil else { return }
        schedule(context: pendingContext, quietDelay: 0)
    }

    nonisolated func requestShutdown() {
        Task { @MainActor [self] in
            shutdown()
        }
    }

    private static func updatedRecordIDs(
        in results: [ClipboardVisionOCRQueue.OCRQueueResult]
    ) -> Set<String> {
        Set(results.compactMap { result in
            switch result {
            case let .completed(recordID), let .failed(recordID, _):
                recordID
            case .skipped:
                nil
            }
        })
    }
}
