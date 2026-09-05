import BlocksScreenshotCore
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ScrollingScreenshotCompositeSegment {
    var destinationY: Int { get }
    var width: Int { get }
    var height: Int { get }
}

enum ScrollingScreenshotCompositeSupport {
    static func crop(_ image: CGImage, rows: Range<Int>) throws -> CGImage {
        guard rows.lowerBound >= 0,
              rows.upperBound <= image.height,
              let cropped = image.cropping(to: CGRect(
                  x: 0,
                  y: rows.lowerBound,
                  width: image.width,
                  height: rows.count
              )) else {
            throw ScrollingScreenshotSessionError.unableToEncodeStrip
        }
        return cropped
    }

    static func makeDescriptor(image: CGImage, id: String) throws -> ScrollingFrameDescriptor {
        let sampleWidth = min(192, image.width)
        var pixels = [UInt8](repeating: 0, count: sampleWidth * image.height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                throw ScrollingScreenshotSessionError.unableToAllocateImage
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: image.height))
        }
        return ScrollingFrameDescriptor(
            id: id,
            pixelSize: ScreenshotPixelSize(width: image.width, height: image.height),
            sampleWidth: sampleWidth,
            lumaSamples: pixels
        )
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScrollingScreenshotSessionError.unableToEncodeStrip
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScrollingScreenshotSessionError.unableToEncodeStrip
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func hasContiguousCoverage<Segment: ScrollingScreenshotCompositeSegment>(
        strips: [Segment],
        deferredFooter: Segment?,
        outputSize: ScreenshotPixelSize
    ) -> Bool {
        let segments = (strips + [deferredFooter].compactMap { $0 })
            .filter { $0.width == outputSize.width && $0.height > 0 }
            .sorted {
                let lhsY = $0.destinationY
                let rhsY = $1.destinationY
                if lhsY == rhsY { return $0.height > $1.height }
                return lhsY < rhsY
            }
        var coveredEnd = 0
        for segment in segments {
            let start = segment.destinationY
            guard start >= 0, start <= coveredEnd else { return false }
            coveredEnd = max(coveredEnd, start + segment.height)
        }
        return coveredEnd >= outputSize.height
    }
}

extension ScrollingScreenshotSessionCoordinator {
    static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blocks/ScrollingScreenshot", isDirectory: true)
    }

    static func removeAbandonedSessions(
        in root: URL,
        fileSystem: ScrollingScreenshotFileSystem,
        now: @Sendable () -> TimeInterval
    ) -> (diagnostic: ScrollingScreenshotCleanupDiagnostic?, elapsedMilliseconds: Double) {
        let startedAt = now()
        guard fileSystem.fileExists(root) else { return (nil, 0) }
        var diagnostic: ScrollingScreenshotCleanupDiagnostic?
        for attempt in 1...3 {
            do {
                try fileSystem.removeItem(root)
                return (nil, max(0, now() - startedAt) * 1_000)
            } catch {
                diagnostic = ScrollingScreenshotCleanupDiagnostic(
                    attempts: attempt,
                    errorCode: (error as NSError).code
                )
            }
        }
        return (diagnostic, max(0, now() - startedAt) * 1_000)
    }

    static func localizedWarning(for reason: ScrollingScreenshotRecoveryReason) -> String {
        switch reason {
        case .invalidFrame, .incompatibleFrameSize:
            L10n.string("screenshot.scrolling.warning.frameChanged")
        case .ambiguousOverlap:
            L10n.string("screenshot.scrolling.warning.ambiguous")
        case .reverseScroll:
            L10n.string("screenshot.scrolling.warning.reverse")
        case .insufficientOverlap:
            L10n.string("screenshot.scrolling.warning.fast")
        }
    }

    static func diagnosticFields(
        for decision: ScrollingStitchDecision
    ) -> (name: String, appendRows: Int, overlapRows: Int, headerRows: Int, footerRows: Int) {
        switch decision {
        case .seed:
            ("seed", 0, 0, 0, 0)
        case let .append(match):
            (
                "append",
                match.incomingSourceRows.count,
                match.overlapRows,
                match.fixedHeaderRows,
                match.fixedFooterRows
            )
        case .noNewContent:
            ("unchanged", 0, 0, 0, 0)
        case .recover(.ambiguousOverlap):
            ("recover-ambiguous", 0, 0, 0, 0)
        case .recover(.reverseScroll):
            ("recover-reverse", 0, 0, 0, 0)
        case .recover(.insufficientOverlap):
            ("recover-insufficient", 0, 0, 0, 0)
        case .recover:
            ("recover-invalid", 0, 0, 0, 0)
        case .stop:
            ("stop", 0, 0, 0, 0)
        }
    }

    static func isAutomaticallyRecoverable(_ reason: ScrollingScreenshotRecoveryReason) -> Bool {
        switch reason {
        case .ambiguousOverlap, .reverseScroll, .insufficientOverlap:
            true
        case .invalidFrame, .incompatibleFrameSize:
            false
        }
    }

    static func shouldRequestVisionFallback(for decision: ScrollingStitchDecision) -> Bool {
        switch decision {
        case .recover(.ambiguousOverlap), .recover(.insufficientOverlap):
            true
        case .seed, .append, .noNewContent, .recover, .stop:
            false
        }
    }
}

enum ScrollingScreenshotSessionError: LocalizedError {
    case sessionAlreadyActive
    case noActiveSession
    case confirmationRequired
    case insufficientContent
    case unableToEncodeStrip
    case unableToDecodeStrip
    case unableToAllocateImage
    case invalidCompositeCoverage
    case staleSession
    case invalidState
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive: L10n.string("screenshot.scrolling.error.sessionActive")
        case .noActiveSession: L10n.string("screenshot.scrolling.error.noSession")
        case .confirmationRequired: L10n.string("screenshot.scrolling.error.confirmationRequired")
        case .insufficientContent: L10n.string("screenshot.scrolling.error.insufficientContent")
        case .unableToEncodeStrip: L10n.string("screenshot.scrolling.error.writeFailed")
        case .unableToDecodeStrip: L10n.string("screenshot.scrolling.error.readFailed")
        case .unableToAllocateImage, .invalidCompositeCoverage:
            L10n.string("screenshot.scrolling.error.finalizeFailed")
        case .staleSession: L10n.string("screenshot.scrolling.error.noSession")
        case .invalidState: L10n.string("screenshot.scrolling.error.finalizeFailed")
        case .cleanupFailed: L10n.string("screenshot.scrolling.error.writeFailed")
        }
    }
}

enum ScrollingScreenshotSessionTerminal: Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

struct ScrollingScreenshotCleanupDiagnostic: Equatable, Sendable {
    let attempts: Int
    let errorCode: Int
}

struct ScrollingScreenshotStageMetrics: Equatable, Sendable {
    private(set) var sampleCount = 0
    private(set) var totalMilliseconds = 0.0
    private(set) var maximumMilliseconds = 0.0

    mutating func record(milliseconds: Double) {
        let value = milliseconds.isFinite ? max(0, milliseconds) : 0
        sampleCount += 1
        totalMilliseconds += value
        maximumMilliseconds = max(maximumMilliseconds, value)
    }
}

struct ScrollingScreenshotResourceMetrics: Equatable, Sendable {
    var baselineResidentBytes: Int64?
    var peakResidentBytes: Int64?
    var currentTemporaryDiskBytes: Int64 = 0
    var peakTemporaryDiskBytes: Int64 = 0
    var ingest = ScrollingScreenshotStageMetrics()
    var finalize = ScrollingScreenshotStageMetrics()
    var cleanup = ScrollingScreenshotStageMetrics()

    var peakResidentIncreaseBytes: Int64? {
        guard let baselineResidentBytes, let peakResidentBytes else { return nil }
        return max(0, peakResidentBytes - baselineResidentBytes)
    }
}

struct ScrollingScreenshotFileSystem: @unchecked Sendable {
    let removeItem: @Sendable (URL) throws -> Void
    let fileSize: @Sendable (URL) -> Int64
    let fileExists: @Sendable (URL) -> Bool

    init(
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        fileSize: @escaping @Sendable (URL) -> Int64 = { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        },
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.removeItem = removeItem
        self.fileSize = fileSize
        self.fileExists = fileExists
    }
}

struct ScrollingScreenshotResourceSampler: @unchecked Sendable {
    let residentBytes: @Sendable () -> Int64?
    let now: @Sendable () -> TimeInterval

    init(
        residentBytes: @escaping @Sendable () -> Int64? = { Self.currentResidentBytes() },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.residentBytes = residentBytes
        self.now = now
    }

    private static func currentResidentBytes() -> Int64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : nil
    }
}

struct ScrollingScreenshotRuntimeSnapshot: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case idle
        case selecting
        case capturing
        case recovering
        case paused
        case possibleEnd
        case finalizing
        case editing
    }

    let sessionID: String?
    let state: State
    let outputSize: ScreenshotPixelSize
    let warning: String?
}

enum ScrollingScreenshotIngestEvent: Sendable {
    case accepted(ScrollingScreenshotRuntimeSnapshot)
    case unchanged(ScrollingScreenshotRuntimeSnapshot)
    case recovering(ScrollingScreenshotRuntimeSnapshot)
    case recovered(ScrollingScreenshotRuntimeSnapshot)
    case paused(ScrollingScreenshotRuntimeSnapshot)
    case reachedLimit(ScrollingScreenshotRuntimeSnapshot)
}
