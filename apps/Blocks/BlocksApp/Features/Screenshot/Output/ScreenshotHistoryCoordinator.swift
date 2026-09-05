import AppKit
import BlocksCore
import BlocksScreenshotCore
import Foundation

@MainActor
final class ScreenshotClipboardArchiveCoordinator: ScreenshotClipboardArchiving {
    private let repository: ClipboardRepository
    private let featureAvailabilityStore: FeatureAvailabilityStore
    private let onCommitted: @MainActor () -> Void
    private let recordCommitGate: ClipboardRecordCommitGate?
    private let onCommittedDeletion: @Sendable ([String]) -> Void
    private let beforeCommitGateAcquire: @MainActor () -> Void

    init(
        repository: ClipboardRepository,
        featureAvailabilityStore: FeatureAvailabilityStore,
        onCommitted: @escaping @MainActor () -> Void = {},
        recordCommitGate: ClipboardRecordCommitGate? = nil,
        onCommittedDeletion: @escaping @Sendable ([String]) -> Void = { _ in },
        beforeCommitGateAcquire: @escaping @MainActor () -> Void = {}
    ) {
        self.repository = repository
        self.featureAvailabilityStore = featureAvailabilityStore
        self.onCommitted = onCommitted
        self.recordCommitGate = recordCommitGate
        self.onCommittedDeletion = onCommittedDeletion
        self.beforeCommitGateAcquire = beforeCommitGateAcquire
    }

    func archive(
        capture: ScreenshotCapture,
        image: NSImage,
        automaticallyRecognizesText: Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        guard featureAvailabilityStore.clipboardEnabled else {
            return .ignoredFeatureDisabled
        }
        let artifact = try await FinalizedScreenshotArtifact.make(
            capture: capture,
            image: image,
            pngEncoder: { try ScreenshotImageEncoder().pngData($0) }
        )
        return try await archive(
            artifact: artifact,
            automaticallyRecognizesText: automaticallyRecognizesText
        )
    }

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        try await archive(
            artifact: artifact,
            automaticallyRecognizesText: automaticallyRecognizesText,
            isCurrent: { true },
            admission: ScreenshotHistoryCommitAdmission()
        )
    }

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        try await archive(
            artifact: artifact,
            automaticallyRecognizesText: automaticallyRecognizesText,
            isCurrent: isCurrent,
            admission: ScreenshotHistoryCommitAdmission()
        )
    }

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        admission: ScreenshotHistoryCommitAdmission
    ) async throws -> ScreenshotClipboardArchiveResult {
        guard featureAvailabilityStore.clipboardEnabled, isCurrent() else {
            return .ignoredFeatureDisabled
        }
        let capture = artifact.capture
        let png = artifact.pngData
        let now = Date()
        let placeholderSignature = String(repeating: "0", count: 64)
        let sourceApp = ClipboardRecorderSourceApp(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            localizedName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            sourceAppIsCandidate: false
        )
        let record = ClipboardRecorderRecord(
            id: capture.id,
            createdAt: now,
            changeCount: 0,
            kind: .image,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.png"],
                byteCount: png.count
            ),
            sourceApp: sourceApp,
            signatureSHA256: placeholderSignature,
            signatureSHA256_12: String(placeholderSignature.prefix(12)),
            fixtureOwned: false,
            restorable: true,
            lastCopiedAt: now,
            summary: "Screenshot"
        )
        let request = ScreenshotHistoryCommitRequest(
            record: record,
            pngData: png,
            ocrState: automaticallyRecognizesText ? .pending : .notRequired
        )
        beforeCommitGateAcquire()
        let permit = await recordCommitGate?.acquire()
        if recordCommitGate != nil, permit == nil {
            throw CancellationError()
        }
        guard !Task.isCancelled, isCurrent() else {
            if let permit, let recordCommitGate {
                await recordCommitGate.release(permit)
            }
            return .ignoredFeatureDisabled
        }
        let repository = self.repository
        let onCommittedDeletion = self.onCommittedDeletion
        do {
            // Detached enqueue is not a durable boundary. The repository
            // admits this request immediately before its first physical write.
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    _ = try repository.commitScreenshotHistory(
                        request: request,
                        admission: admission,
                        onCommittedDeletion: onCommittedDeletion
                    )
                }.value
            } onCancel: {
                admission.revoke()
            }
            if let permit, let recordCommitGate {
                await recordCommitGate.release(permit)
            }
        } catch {
            if let permit, let recordCommitGate {
                await recordCommitGate.release(permit)
            }
            throw error
        }
        if isCurrent() {
            onCommitted()
        }
        return .stored
    }
}
