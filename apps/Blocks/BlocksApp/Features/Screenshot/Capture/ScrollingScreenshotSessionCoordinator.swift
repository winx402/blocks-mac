import BlocksScreenshotCore
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

actor ScrollingScreenshotSessionCoordinator {
    static let maximumAutomaticRecoveryAttempts = 3

    enum OperationReturnBoundary: Sendable, Hashable {
        case ingest
        case validateResumeAnchor
        case pause
        case restart
    }

    private struct Strip: Codable, Sendable, ScrollingScreenshotCompositeSegment {
        let fileName: String
        let destinationY: Int
        let width: Int
        let height: Int
    }

    private struct DeferredFooter: Sendable {
        let strip: Strip
        let byteCount: Int64
    }

    private let assembler: ScrollingScreenshotAssembler
    private let logger = Logger(subsystem: "app.blocks.app", category: "ScrollingSession")
    private let rootDirectory: URL
    private let fileSystem: ScrollingScreenshotFileSystem
    private let resourceSampler: ScrollingScreenshotResourceSampler
    private let operationReturnBoundary: (@Sendable (OperationReturnBoundary) async -> Void)?
    private var sessionID: String?
    private var sessionDirectory: URL?
    private var state = ScrollingScreenshotSessionState()
    private var strips: [Strip] = []
    private var runtimeState: ScrollingScreenshotRuntimeSnapshot.State = .idle
    private var warning: String?
    private var deferredFooter: DeferredFooter?
    private var automaticRecoveryAttemptCount = 0
    private var lastAutomaticRecoveryAttemptID: UInt64?
    private var lastAcceptedImage: CGImage?
    private let visionAligner = ScrollingScreenshotVisionAligner()
    private var metrics = ScrollingScreenshotResourceMetrics()
    private var lastCleanupDiagnostic: ScrollingScreenshotCleanupDiagnostic?

    init(
        assembler: ScrollingScreenshotAssembler = .init(),
        rootDirectory: URL? = nil,
        fileSystem: ScrollingScreenshotFileSystem = .init(),
        resourceSampler: ScrollingScreenshotResourceSampler = .init(),
        operationReturnBoundary: (@Sendable (OperationReturnBoundary) async -> Void)? = nil
    ) {
        self.assembler = assembler
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.fileSystem = fileSystem
        self.resourceSampler = resourceSampler
        self.operationReturnBoundary = operationReturnBoundary
        lastCleanupDiagnostic = Self.removeAbandonedSessions(
            in: self.rootDirectory,
            fileSystem: fileSystem,
            now: resourceSampler.now
        ).diagnostic
    }

    func begin(sessionID requestedSessionID: String? = nil) throws -> String {
        guard sessionID == nil else { throw ScrollingScreenshotSessionError.sessionAlreadyActive }
        let id = requestedSessionID ?? "scroll-\(UUID().uuidString.lowercased())"
        let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        sessionID = id
        sessionDirectory = directory
        state = ScrollingScreenshotSessionState()
        strips.removeAll()
        runtimeState = .capturing
        warning = nil
        deferredFooter = nil
        automaticRecoveryAttemptCount = 0
        lastAutomaticRecoveryAttemptID = nil
        lastAcceptedImage = nil
        metrics = ScrollingScreenshotResourceMetrics()
        let initialResidentBytes = resourceSampler.residentBytes()
        metrics.baselineResidentBytes = initialResidentBytes
        metrics.peakResidentBytes = initialResidentBytes
        lastCleanupDiagnostic = nil
        return id
    }

    func ingest(
        _ frame: ScrollingCapturedFrame,
        recoveryAttemptID: UInt64? = nil,
        commitsRecoveryAttempt: Bool = true
    ) async throws -> ScrollingScreenshotIngestEvent {
        let startedAt = resourceSampler.now()
        defer {
            metrics.ingest.record(milliseconds: elapsedMilliseconds(since: startedAt))
            sampleResidentMemory()
        }
        guard sessionID != nil, let directory = sessionDirectory else {
            throw ScrollingScreenshotSessionError.noActiveSession
        }
        let descriptor = try ScrollingScreenshotCompositeSupport.makeDescriptor(
            image: frame.image,
            id: UUID().uuidString
        )
        let wasRecovering = runtimeState == .recovering
        var decision = assembler.decide(
            state: state,
            incoming: descriptor
        )
        if Self.shouldRequestVisionFallback(for: decision.stitchDecision),
           let previousImage = lastAcceptedImage,
           let alignmentHint = visionAligner.alignmentHint(
               previous: previousImage,
               incoming: frame.image
           ) {
            decision = assembler.decide(
                state: state,
                incoming: descriptor,
                alignmentHint: alignmentHint
            )
        }
        let diagnostic = Self.diagnosticFields(for: decision.stitchDecision)
        logger.debug(
            "stage=stitch-decision observed=\(decision.nextState.observedFrameCount, privacy: .public) decision=\(diagnostic.name, privacy: .public) appendRows=\(diagnostic.appendRows, privacy: .public) overlapRows=\(diagnostic.overlapRows, privacy: .public) headerRows=\(diagnostic.headerRows, privacy: .public) footerRows=\(diagnostic.footerRows, privacy: .public) outputHeight=\(decision.nextState.outputSize.height, privacy: .public)"
        )
        switch decision.operation {
        case let .write(operation):
            let stripImage = try ScrollingScreenshotCompositeSupport.crop(
                frame.image,
                rows: operation.sourceRows
            )
            let fileName = "strip-\(UUID().uuidString.lowercased()).png"
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            let fixedFooterRows: Int
            if case let .append(match) = decision.stitchDecision {
                fixedFooterRows = match.fixedFooterRows
            } else {
                fixedFooterRows = 0
            }
            let pendingFooter: DeferredFooter?
            var createdFooterURL: URL?
            do {
                try ScrollingScreenshotCompositeSupport.writePNG(stripImage, to: url)
                if fixedFooterRows > 0, fixedFooterRows < frame.image.height {
                    let footerImage = try ScrollingScreenshotCompositeSupport.crop(
                        frame.image,
                        rows: (frame.image.height - fixedFooterRows)..<frame.image.height
                    )
                    let footerFileName = "footer-\(UUID().uuidString.lowercased()).png"
                    let footerURL = directory.appendingPathComponent(footerFileName, isDirectory: false)
                    createdFooterURL = footerURL
                    try ScrollingScreenshotCompositeSupport.writePNG(footerImage, to: footerURL)
                    pendingFooter = DeferredFooter(
                        strip: Strip(
                            fileName: footerFileName,
                            destinationY: decision.nextState.outputSize.height - fixedFooterRows,
                            width: footerImage.width,
                            height: footerImage.height
                        ),
                        byteCount: fileSystem.fileSize(footerURL)
                    )
                } else {
                    pendingFooter = nil
                }
            } catch {
                try? fileSystem.removeItem(url)
                if let createdFooterURL {
                    try? fileSystem.removeItem(createdFooterURL)
                }
                throw error
            }

            strips.append(Strip(
                fileName: fileName,
                destinationY: operation.destinationY,
                width: stripImage.width,
                height: stripImage.height
            ))
            let stripByteCount = fileSystem.fileSize(url)
            metrics.currentTemporaryDiskBytes += stripByteCount

            if let previousFooter = deferredFooter {
                let previousURL = directory.appendingPathComponent(previousFooter.strip.fileName)
                do {
                    try fileSystem.removeItem(previousURL)
                    metrics.currentTemporaryDiskBytes = max(
                        0,
                        metrics.currentTemporaryDiskBytes - previousFooter.byteCount
                    )
                } catch {
                    logger.error(
                        "stage=replace-deferred-footer domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)"
                    )
                }
                self.deferredFooter = nil
            }
            if let pendingFooter {
                deferredFooter = pendingFooter
                metrics.currentTemporaryDiskBytes += pendingFooter.byteCount
            }
            metrics.peakTemporaryDiskBytes = max(
                metrics.peakTemporaryDiskBytes,
                metrics.currentTemporaryDiskBytes
            )
        case .none:
            break
        }
        state = decision.nextState

        let event: ScrollingScreenshotIngestEvent
        switch decision.stitchDecision {
        case .seed, .append:
            lastAcceptedImage = frame.image
            resetAutomaticRecoveryBudget()
            runtimeState = .capturing
            warning = state.sizeAssessment?.status == .warning
                ? L10n.string("screenshot.scrolling.warning.size")
                : nil
            event = wasRecovering ? .recovered(snapshot()) : .accepted(snapshot())
        case .noNewContent:
            if wasRecovering {
                resetAutomaticRecoveryBudget()
                runtimeState = .capturing
                warning = nil
                event = .recovered(snapshot())
            } else {
                event = .unchanged(snapshot())
            }
        case let .recover(reason):
            if Self.isAutomaticallyRecoverable(reason) {
                if commitsRecoveryAttempt {
                    registerAutomaticRecoveryAttempt(id: recoveryAttemptID)
                }
                if !commitsRecoveryAttempt
                    || automaticRecoveryAttemptCount < Self.maximumAutomaticRecoveryAttempts {
                    runtimeState = .recovering
                    warning = L10n.string("screenshot.scrolling.recovering")
                    event = .recovering(snapshot())
                } else {
                    resetAutomaticRecoveryBudget()
                    runtimeState = .paused
                    warning = Self.localizedWarning(for: reason)
                    event = .paused(snapshot())
                }
            } else {
                resetAutomaticRecoveryBudget()
                runtimeState = .paused
                warning = Self.localizedWarning(for: reason)
                event = .paused(snapshot())
            }
        case .stop:
            runtimeState = .finalizing
            warning = L10n.string("screenshot.scrolling.warning.limitReached")
            event = .reachedLimit(snapshot())
        }
        if let operationReturnBoundary {
            await operationReturnBoundary(.ingest)
        }
        return event
    }

    func setPossibleEnd(
        _ enabled: Bool,
        expectedSessionID: String? = nil
    ) -> ScrollingScreenshotRuntimeSnapshot {
        if let expectedSessionID, expectedSessionID != sessionID {
            return snapshot()
        }
        if enabled, runtimeState == .capturing {
            runtimeState = .possibleEnd
        } else if !enabled, runtimeState == .possibleEnd {
            runtimeState = .capturing
        }
        return snapshot()
    }

    func validateResumeAnchor(
        _ frame: ScrollingCapturedFrame
    ) async throws -> ScrollingScreenshotRuntimeSnapshot {
        guard runtimeState == .paused || runtimeState == .recovering else {
            throw ScrollingScreenshotSessionError.invalidState
        }
        resetAutomaticRecoveryBudget()
        runtimeState = .recovering
        warning = L10n.string("screenshot.scrolling.recovering")
        let event = try await ingest(frame, commitsRecoveryAttempt: false)
        switch event {
        case .accepted, .unchanged, .recovered:
            runtimeState = .capturing
            warning = nil
        case let .recovering(snapshot), let .paused(snapshot):
            runtimeState = .paused
            warning = snapshot.warning
        case .reachedLimit:
            runtimeState = .paused
            warning = L10n.string("screenshot.scrolling.warning.limitReached")
        }
        let snapshot = snapshot()
        if let operationReturnBoundary {
            await operationReturnBoundary(.validateResumeAnchor)
        }
        return snapshot
    }

    func pause(warning requestedWarning: String? = nil) async -> ScrollingScreenshotRuntimeSnapshot {
        runtimeState = .paused
        warning = requestedWarning ?? L10n.string("screenshot.scrolling.paused.manual")
        let snapshot = snapshot()
        if let operationReturnBoundary {
            await operationReturnBoundary(.pause)
        }
        return snapshot
    }

    func restartFromCurrentViewport() async throws -> ScrollingScreenshotRuntimeSnapshot {
        guard sessionID != nil, let directory = sessionDirectory else {
            throw ScrollingScreenshotSessionError.noActiveSession
        }
        guard runtimeState != .finalizing, runtimeState != .editing else {
            throw ScrollingScreenshotSessionError.invalidState
        }
        let fileNames = strips.map(\.fileName) + [deferredFooter?.strip.fileName].compactMap { $0 }
        for fileName in fileNames {
            try fileSystem.removeItem(directory.appendingPathComponent(fileName))
        }
        state = ScrollingScreenshotSessionState()
        strips.removeAll()
        deferredFooter = nil
        lastAcceptedImage = nil
        runtimeState = .capturing
        warning = nil
        resetAutomaticRecoveryBudget()
        metrics.currentTemporaryDiskBytes = 0
        let snapshot = snapshot()
        if let operationReturnBoundary {
            await operationReturnBoundary(.restart)
        }
        return snapshot
    }

    func status() -> ScrollingScreenshotRuntimeSnapshot {
        snapshot()
    }

    func finalize() async throws -> CGImage {
        let startedAt = resourceSampler.now()
        defer {
            metrics.finalize.record(milliseconds: elapsedMilliseconds(since: startedAt))
            sampleResidentMemory()
        }
        guard sessionID != nil, let directory = sessionDirectory else {
            throw ScrollingScreenshotSessionError.noActiveSession
        }
        guard !strips.isEmpty, state.outputSize.width > 0, state.outputSize.height > 0 else {
            throw ScrollingScreenshotSessionError.insufficientContent
        }
        guard ScrollingScreenshotCompositeSupport.hasContiguousCoverage(
            strips: strips,
            deferredFooter: deferredFooter?.strip,
            outputSize: state.outputSize
        ) else {
            logger.error(
                "stage=finalize-coverage-invalid strips=\(self.strips.count, privacy: .public) outputHeight=\(self.state.outputSize.height, privacy: .public)"
            )
            runtimeState = .paused
            warning = L10n.string("screenshot.scrolling.error.finalizeFailed")
            throw ScrollingScreenshotSessionError.invalidCompositeCoverage
        }
        runtimeState = .finalizing
        try Task.checkCancellation()
        guard let context = CGContext(
            data: nil,
            width: state.outputSize.width,
            height: state.outputSize.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollingScreenshotSessionError.unableToAllocateImage
        }
        sampleResidentMemory()
        context.interpolationQuality = .none
        for strip in strips {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(strip.fileName)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ScrollingScreenshotSessionError.unableToDecodeStrip
            }
            context.draw(image, in: CGRect(
                x: 0,
                y: state.outputSize.height - strip.destinationY - image.height,
                width: image.width,
                height: image.height
            ))
            sampleResidentMemory()
        }
        if let deferredFooter {
            let url = directory.appendingPathComponent(deferredFooter.strip.fileName)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ScrollingScreenshotSessionError.unableToDecodeStrip
            }
            context.draw(image, in: CGRect(
                x: 0,
                y: state.outputSize.height - deferredFooter.strip.destinationY - image.height,
                width: image.width,
                height: image.height
            ))
            sampleResidentMemory()
        }
        guard let image = context.makeImage() else {
            throw ScrollingScreenshotSessionError.unableToAllocateImage
        }
        sampleResidentMemory()
        try Task.checkCancellation()
        do {
            try cleanupTemporaryContent()
        } catch {
            runtimeState = .paused
            warning = L10n.string("screenshot.scrolling.error.writeFailed")
            throw error
        }
        runtimeState = .editing
        warning = nil
        lastAcceptedImage = nil
        return image
    }

    func finishEditing(
        sessionID requestedSessionID: String,
        terminal: ScrollingScreenshotSessionTerminal
    ) throws {
        guard sessionID == requestedSessionID else {
            throw ScrollingScreenshotSessionError.staleSession
        }
        guard runtimeState == .editing else {
            throw ScrollingScreenshotSessionError.invalidState
        }
        _ = terminal
        try cleanupTemporaryContent()
        resetSession()
    }

    func cancel(confirm: Bool) throws {
        guard sessionID != nil else { throw ScrollingScreenshotSessionError.noActiveSession }
        if !strips.isEmpty, !confirm { throw ScrollingScreenshotSessionError.confirmationRequired }
        try cleanupTemporaryContent()
        resetSession()
    }

    func retryCleanup() throws {
        try cleanupTemporaryContent()
    }

    func releaseSessionAfterCleanupFailure() {
        // Keep the orphaned cache directory for the next launch cleanup pass,
        // but never let a filesystem failure permanently occupy the session gate.
        resetSession()
    }

    func cleanupDiagnostic() -> ScrollingScreenshotCleanupDiagnostic? {
        lastCleanupDiagnostic
    }

    func resourceMetrics() -> ScrollingScreenshotResourceMetrics {
        metrics
    }

    private func snapshot() -> ScrollingScreenshotRuntimeSnapshot {
        ScrollingScreenshotRuntimeSnapshot(
            sessionID: sessionID,
            state: runtimeState,
            outputSize: state.outputSize,
            warning: warning
        )
    }

    private func resetSession() {
        sessionID = nil
        sessionDirectory = nil
        state = ScrollingScreenshotSessionState()
        strips.removeAll()
        runtimeState = .idle
        warning = nil
        deferredFooter = nil
        lastAcceptedImage = nil
        resetAutomaticRecoveryBudget()
    }

    private func registerAutomaticRecoveryAttempt(id: UInt64?) {
        if let id {
            guard lastAutomaticRecoveryAttemptID != id else { return }
            lastAutomaticRecoveryAttemptID = id
        } else {
            lastAutomaticRecoveryAttemptID = nil
        }
        automaticRecoveryAttemptCount += 1
    }

    private func resetAutomaticRecoveryBudget() {
        automaticRecoveryAttemptCount = 0
        lastAutomaticRecoveryAttemptID = nil
    }

    private func cleanupTemporaryContent() throws {
        guard let directory = sessionDirectory else {
            metrics.currentTemporaryDiskBytes = 0
            lastCleanupDiagnostic = nil
            return
        }
        let startedAt = resourceSampler.now()
        defer {
            metrics.cleanup.record(milliseconds: elapsedMilliseconds(since: startedAt))
            sampleResidentMemory()
        }
        var lastError: Error?
        for attempt in 1...3 {
            do {
                if fileSystem.fileExists(directory) {
                    try fileSystem.removeItem(directory)
                }
                sessionDirectory = nil
                strips.removeAll()
                deferredFooter = nil
                metrics.currentTemporaryDiskBytes = 0
                lastCleanupDiagnostic = nil
                return
            } catch {
                lastError = error
                lastCleanupDiagnostic = ScrollingScreenshotCleanupDiagnostic(
                    attempts: attempt,
                    errorCode: (error as NSError).code
                )
            }
        }
        if let lastError {
            lastCleanupDiagnostic = ScrollingScreenshotCleanupDiagnostic(
                attempts: 3,
                errorCode: (lastError as NSError).code
            )
        }
        throw ScrollingScreenshotSessionError.cleanupFailed
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Double {
        max(0, resourceSampler.now() - startedAt) * 1_000
    }

    private func sampleResidentMemory() {
        guard let residentBytes = resourceSampler.residentBytes() else { return }
        metrics.peakResidentBytes = max(metrics.peakResidentBytes ?? 0, residentBytes)
    }

}
