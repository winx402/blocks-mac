import AppKit
import BlocksCore
import BlocksScreenshotCore
import OSLog

struct FinalizedScreenshotArtifact {
    typealias PNGEncoder = @Sendable (CGImage) throws -> Data

    let capture: ScreenshotCapture
    let image: NSImage
    let pngData: Data
    let pixelSize: CGSize

    var captureID: String { capture.id }

    @MainActor
    static func make(
        capture: ScreenshotCapture,
        image: NSImage,
        pngEncoder: @escaping PNGEncoder
    ) async throws -> FinalizedScreenshotArtifact {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FinalizedScreenshotArtifactError.missingCGImage
        }
        try Task.checkCancellation()
        let encoding = ScreenshotPNGEncodingCancellationRace()
        Task.detached(priority: .userInitiated) { [encoding] in
            do {
                encoding.resolve(.success(try pngEncoder(cgImage)))
            } catch {
                encoding.resolve(.failure(error))
            }
        }
        let pngData = try await encoding.value()
        try Task.checkCancellation()
        return FinalizedScreenshotArtifact(
            capture: capture,
            image: image,
            pngData: pngData,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

/// Races a non-cooperative PNG encoder against parent-task cancellation.
///
/// The first `resolve` call while holding `lock` is the linearization point.
/// It stores the sole outcome and removes the continuation, so exactly one
/// caller resumes it; a later encoder result is discarded after cancellation.
private final class ScreenshotPNGEncodingCancellationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?

    func value() async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }, onCancel: {
            resolve(.failure(CancellationError()))
        })
    }

    func resolve(_ outcome: Result<Data, Error>) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }
}

private enum FinalizedScreenshotArtifactError: Error {
    case missingCGImage
}

enum ScreenshotOutputSinkStatus: Equatable {
    case notRequested
    case succeeded
    case failed
}

struct ScreenshotFinalOutputResult: Equatable {
    let pasteboard: ScreenshotOutputSinkStatus
    let archive: ScreenshotOutputSinkStatus
    let isCancelled: Bool

    init(
        pasteboard: ScreenshotOutputSinkStatus,
        archive: ScreenshotOutputSinkStatus,
        isCancelled: Bool = false
    ) {
        self.pasteboard = pasteboard
        self.archive = archive
        self.isCancelled = isCancelled
    }

    /// A successful sink has crossed an irreversible boundary. Later lifecycle
    /// revocation may suppress additional work, but cannot rewrite this truth.
    var hasCommittedSink: Bool {
        pasteboard == .succeeded || archive == .succeeded
    }

    var isTerminal: Bool { true }
}

enum ScreenshotClipboardArchiveResult: Equatable {
    case stored
    case ignoredFeatureDisabled
}

@MainActor
protocol ScreenshotClipboardArchiving {
    func archive(
        capture: ScreenshotCapture,
        image: NSImage,
        automaticallyRecognizesText: Bool
    ) async throws -> ScreenshotClipboardArchiveResult

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool
    ) async throws -> ScreenshotClipboardArchiveResult

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> ScreenshotClipboardArchiveResult

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        admission: ScreenshotHistoryCommitAdmission
    ) async throws -> ScreenshotClipboardArchiveResult
}

extension ScreenshotClipboardArchiving {
    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        try await archive(
            capture: artifact.capture,
            image: artifact.image,
            automaticallyRecognizesText: automaticallyRecognizesText
        )
    }

    func archive(
        artifact: FinalizedScreenshotArtifact,
        automaticallyRecognizesText: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        admission: ScreenshotHistoryCommitAdmission
    ) async throws -> ScreenshotClipboardArchiveResult {
        try await archive(
            artifact: artifact,
            automaticallyRecognizesText: automaticallyRecognizesText,
            isCurrent: isCurrent
        )
    }

}

@MainActor
final class ScreenshotOutputSerialGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isHeld else {
            isHeld = true
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    func release() {
        precondition(isHeld, "Final-output gate released without an owner.")
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            isHeld = false
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

@MainActor
final class ScreenshotFinalOutputCoordinator {
    private let logger = Logger(subsystem: "app.blocks.app", category: "screenshot-final-output")
    private let preferencesStore: ScreenshotPreferencesStore
    private let pasteboardWriter: any ScreenshotPasteboardWriting
    private let archiveWriter: (any ScreenshotClipboardArchiving)?
    private let pngEncoder: FinalizedScreenshotArtifact.PNGEncoder
    private var dispatchPluginEvent: @MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult = { .allowed($0) }
    private var dispatchWillPluginEvent: @MainActor (
        BlocksPluginEventEnvelope,
        @escaping @MainActor () -> Bool
    ) async -> BlocksPluginEventDispatchResult = { envelope, _ in .allowed(envelope) }
    private var dispatchTerminalPluginEvent: @MainActor (
        BlocksPluginEventEnvelope,
        @escaping @MainActor () -> Bool
    ) async -> BlocksPluginEventDispatchResult = { envelope, _ in .allowed(envelope) }
    private var registerPluginResource: @Sendable (
        Data,
        BlocksPluginResourceKind,
        String?,
        [String: JSONValue]
    ) -> BlocksPluginResourceReference? = { _, _, _, _ in nil }
    private var removePluginResources: @Sendable ([String]) -> Void = { _ in }
    private let finalizationGate: ScreenshotOutputSerialGate
    private let screenshotHistoryCommitAdmissionFactory: @Sendable () -> ScreenshotHistoryCommitAdmission
    private var activeScreenshotHistoryCommitAdmission: ScreenshotHistoryCommitAdmission?

    init(
        preferencesStore: ScreenshotPreferencesStore,
        pasteboardWriter: any ScreenshotPasteboardWriting,
        archiveWriter: (any ScreenshotClipboardArchiving)? = nil,
        serializationGate: ScreenshotOutputSerialGate? = nil,
        screenshotHistoryCommitAdmissionFactory: @escaping @Sendable () -> ScreenshotHistoryCommitAdmission = {
            ScreenshotHistoryCommitAdmission()
        },
        pngEncoder: @escaping FinalizedScreenshotArtifact.PNGEncoder = {
            try ScreenshotImageEncoder().pngData($0)
        }
    ) {
        self.preferencesStore = preferencesStore
        self.pasteboardWriter = pasteboardWriter
        self.archiveWriter = archiveWriter
        self.pngEncoder = pngEncoder
        self.finalizationGate = serializationGate ?? ScreenshotOutputSerialGate()
        self.screenshotHistoryCommitAdmissionFactory = screenshotHistoryCommitAdmissionFactory
    }

    func configurePluginPlatform(
        dispatchPluginEvent: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult,
        dispatchWillPluginEvent: (@MainActor (
            BlocksPluginEventEnvelope,
            @escaping @MainActor () -> Bool
        ) async -> BlocksPluginEventDispatchResult)? = nil,
        dispatchTerminalPluginEvent: (@MainActor (
            BlocksPluginEventEnvelope,
            @escaping @MainActor () -> Bool
        ) async -> BlocksPluginEventDispatchResult)? = nil,
        registerResource: @escaping @Sendable (
            Data,
            BlocksPluginResourceKind,
            String?,
            [String: JSONValue]
        ) -> BlocksPluginResourceReference?,
        removeResources: @escaping @Sendable ([String]) -> Void
    ) {
        self.dispatchPluginEvent = dispatchPluginEvent
        self.dispatchWillPluginEvent = dispatchWillPluginEvent
            ?? { envelope, isCurrent in
                guard isCurrent() else { return .allowed(envelope) }
                let result = await dispatchPluginEvent(envelope)
                return isCurrent() ? result : .allowed(envelope)
            }
        self.dispatchTerminalPluginEvent = dispatchTerminalPluginEvent
            ?? { envelope, isCurrent in
                guard isCurrent() else { return .allowed(envelope) }
                return await dispatchPluginEvent(envelope)
            }
        registerPluginResource = registerResource
        removePluginResources = removeResources
    }

    func finalize(
        capture: ScreenshotCapture,
        image: NSImage,
        writesPasteboard: Bool,
        userInitiated: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        onCommitStarted: @escaping @MainActor () -> Void = {}
    ) async -> ScreenshotFinalOutputResult {
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        guard await finalizationGate.acquire() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        let admission = screenshotHistoryCommitAdmissionFactory()
        activeScreenshotHistoryCommitAdmission = admission
        defer {
            clearActiveScreenshotHistoryCommitAdmission(ifMatching: admission)
            finalizationGate.release()
        }
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        return await withTaskCancellationHandler {
            await finalizeLocked(
                capture: capture,
                image: image,
                writesPasteboard: writesPasteboard,
                userInitiated: userInitiated,
                isCurrent: isCurrent,
                onCommitStarted: onCommitStarted,
                screenshotHistoryCommitAdmission: admission
            )
        } onCancel: {
            admission.revoke()
        }
    }

    /// Called synchronously before runtime generation invalidation. This only
    /// affects a pending repository admission; an admitted history commit is
    /// intentionally durable.
    func revokePendingArchiveCommit() {
        activeScreenshotHistoryCommitAdmission?.revoke()
    }

    private func finalizeLocked(
        capture: ScreenshotCapture,
        image: NSImage,
        writesPasteboard: Bool,
        userInitiated: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        onCommitStarted: @escaping @MainActor () -> Void,
        screenshotHistoryCommitAdmission: ScreenshotHistoryCommitAdmission
    ) async -> ScreenshotFinalOutputResult {
        let preferences = preferencesStore.preferences
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        let needsArtifact = writesPasteboard || archiveWriter != nil
        if archiveWriter == nil {
            logger.error("stage=clipboard-archive-writer-unavailable")
        }

        guard needsArtifact else {
            return ScreenshotFinalOutputResult(
                pasteboard: .notRequested,
                archive: .failed
            )
        }

        let artifact: FinalizedScreenshotArtifact
        do {
            artifact = try await FinalizedScreenshotArtifact.make(
                capture: capture,
                image: image,
                pngEncoder: pngEncoder
            )
        } catch {
            if error is CancellationError {
                return cancelledResult(writesPasteboard: writesPasteboard)
            }
            logFailure(error, stage: "artifact")
            return ScreenshotFinalOutputResult(
                pasteboard: writesPasteboard ? .failed : .notRequested,
                archive: .failed
            )
        }

        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        guard !Task.isCancelled else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }

        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        let resource = registerPluginResource(
            artifact.pngData,
            .screenshot,
            "image/png",
            [
                "pixel_width": .int(Int(artifact.pixelSize.width)),
                "pixel_height": .int(Int(artifact.pixelSize.height)),
            ]
        )
        defer {
            if let resource { removePluginResources([resource.id]) }
        }
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        guard !Task.isCancelled else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        let payload: [String: JSONValue] = [
            "capture_id": .string(capture.id),
            "pixel_width": .int(Int(artifact.pixelSize.width)),
            "pixel_height": .int(Int(artifact.pixelSize.height)),
            "writes_pasteboard": .bool(writesPasteboard),
            "format": .string("png"),
        ]
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        let willResult = await dispatchWillPluginEvent(
            BlocksPluginEventEnvelope(
                name: .screenshotWillFinalizeOutput,
                sessionID: capture.id,
                authorization: .init(userInitiated: userInitiated),
                payload: payload,
                resources: resource.map { [$0] } ?? []
            ),
            isCurrent
        )
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        guard willResult.allowed else {
            _ = await dispatchTerminalPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .screenshotOutputFailed,
                    sessionID: capture.id,
                    payload: payload.merging([
                        "code": .string("blocked_by_plugin"),
                        "message": .string(willResult.reason ?? "Blocked by plugin."),
                    ]) { _, new in new }
                ),
                isCurrent
            )
            return ScreenshotFinalOutputResult(
                pasteboard: writesPasteboard ? .failed : .notRequested,
                archive: .failed
            )
        }
        guard isCurrent() else {
            return cancelledResult(writesPasteboard: writesPasteboard)
        }
        guard !Task.isCancelled else {
            await dispatchCancelledTerminalEvent(
                capture: capture,
                payload: payload,
                isCurrent: isCurrent
            )
            return cancelledResult(writesPasteboard: writesPasteboard)
        }

        // This task preserves the existing all-or-nothing sink-set behavior
        // after user cancellation. Runtime authorization still reaches each
        // sink's own irreversible admission boundary.
        let commitTask = Task { @MainActor [self] in
            guard isCurrent() else {
                return self.cancelledResult(writesPasteboard: writesPasteboard)
            }
            onCommitStarted()
            return await commitSinks(
                capture: capture,
                artifact: artifact,
                payload: payload,
                resource: resource,
                writesPasteboard: writesPasteboard,
                automaticallyRecognizesText: preferences.automaticallyRecognizesHistory,
                isCurrent: isCurrent,
                screenshotHistoryCommitAdmission: screenshotHistoryCommitAdmission
            )
        }
        return await commitTask.value
    }

    private func commitSinks(
        capture: ScreenshotCapture,
        artifact: FinalizedScreenshotArtifact,
        payload: [String: JSONValue],
        resource: BlocksPluginResourceReference?,
        writesPasteboard: Bool,
        automaticallyRecognizesText: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        screenshotHistoryCommitAdmission: ScreenshotHistoryCommitAdmission
    ) async -> ScreenshotFinalOutputResult {
        let pasteboardStatus: ScreenshotOutputSinkStatus
        if writesPasteboard {
            guard isCurrent() else {
                return cancelledResult(writesPasteboard: writesPasteboard)
            }
            do {
                try await pasteboardWriter.write(
                    artifact,
                    operationAllowed: isCurrent
                )
                pasteboardStatus = .succeeded
            } catch {
                logFailure(error, stage: "pasteboard")
                pasteboardStatus = .failed
            }
        } else {
            pasteboardStatus = .notRequested
        }

        guard isCurrent() else {
            return revocationResult(
                pasteboard: pasteboardStatus,
                archive: archiveWriter == nil ? .failed : .notRequested
            )
        }

        let archiveStatus: ScreenshotOutputSinkStatus
        if let archiveWriter {
            guard isCurrent() else {
                return revocationResult(
                    pasteboard: pasteboardStatus,
                    archive: .notRequested
                )
            }
            do {
                let result = try await archiveWriter.archive(
                    artifact: artifact,
                    automaticallyRecognizesText: automaticallyRecognizesText,
                    isCurrent: isCurrent,
                    admission: screenshotHistoryCommitAdmission
                )
                archiveStatus = result == .stored ? .succeeded : .notRequested
            } catch is CancellationError {
                archiveStatus = .failed
            } catch {
                logFailure(error, stage: "clipboard-archive")
                archiveStatus = .failed
            }
        } else {
            archiveStatus = .failed
        }

        guard isCurrent() else {
            return revocationResult(
                pasteboard: pasteboardStatus,
                archive: archiveStatus
            )
        }

        let finalResult = ScreenshotFinalOutputResult(
            pasteboard: pasteboardStatus,
            archive: archiveStatus
        )
        let failed = pasteboardStatus == .failed || archiveStatus == .failed
        guard isCurrent() else {
            return finalResult
        }
        _ = await dispatchTerminalPluginEvent(
            BlocksPluginEventEnvelope(
                name: failed ? .screenshotOutputFailed : .screenshotOutputFinished,
                sessionID: capture.id,
                payload: payload.merging([
                    "pasteboard": .string(String(describing: pasteboardStatus)),
                    "archive": .string(String(describing: archiveStatus)),
                ]) { _, new in new },
                resources: resource.map { [$0] } ?? []
            ),
            isCurrent
        )
        return finalResult
    }

    private func cancelledResult(writesPasteboard: Bool) -> ScreenshotFinalOutputResult {
        ScreenshotFinalOutputResult(
            pasteboard: writesPasteboard ? .failed : .notRequested,
            archive: .failed,
            isCancelled: true
        )
    }

    private func clearActiveScreenshotHistoryCommitAdmission(
        ifMatching admission: ScreenshotHistoryCommitAdmission
    ) {
        guard activeScreenshotHistoryCommitAdmission === admission else { return }
        activeScreenshotHistoryCommitAdmission = nil
    }

    private func revocationResult(
        pasteboard: ScreenshotOutputSinkStatus,
        archive: ScreenshotOutputSinkStatus
    ) -> ScreenshotFinalOutputResult {
        let result = ScreenshotFinalOutputResult(
            pasteboard: pasteboard,
            archive: archive
        )
        return ScreenshotFinalOutputResult(
            pasteboard: pasteboard,
            archive: archive,
            isCancelled: !result.hasCommittedSink
        )
    }

    private func dispatchCancelledTerminalEvent(
        capture: ScreenshotCapture,
        payload: [String: JSONValue],
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        _ = await dispatchTerminalPluginEvent(
            BlocksPluginEventEnvelope(
                name: .screenshotOutputFailed,
                sessionID: capture.id,
                payload: payload.merging([
                    "code": .string("cancelled"),
                ]) { _, new in new }
            ),
            isCurrent
        )
    }

    private func logFailure(_ error: Error, stage: String) {
        let failure = error as NSError
        logger.error(
            "stage=\(stage, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
        )
    }
}
