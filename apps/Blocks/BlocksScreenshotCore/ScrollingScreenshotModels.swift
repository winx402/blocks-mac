import Foundation

public struct ScrollingFrameDescriptor: Equatable, Sendable {
    public let id: String
    public let pixelSize: ScreenshotPixelSize
    public let sampleWidth: Int
    public let lumaSamples: [UInt8]

    public init(
        id: String,
        pixelSize: ScreenshotPixelSize,
        sampleWidth: Int,
        lumaSamples: [UInt8]
    ) {
        self.id = id
        self.pixelSize = pixelSize
        self.sampleWidth = sampleWidth
        self.lumaSamples = lumaSamples
    }

    public var pixelWidth: Int { pixelSize.width }
    public var pixelHeight: Int { pixelSize.height }
    public var sampleHeight: Int {
        guard sampleWidth > 0 else { return 0 }
        return lumaSamples.count / sampleWidth
    }
}

public struct ScrollingScreenshotMatcherConfiguration: Equatable, Sendable {
    public let minimumOverlapRows: Int
    public let minimumFixedHeaderRows: Int
    public let maximumFixedHeaderRows: Int
    public let minimumFixedFooterRows: Int
    public let maximumFixedFooterRows: Int
    public let coarseCandidateCount: Int
    public let horizontalSearchRadius: Int
    public let minimumBlockSimilarity: Double
    public let minimumMatchScore: Double
    public let minimumMatchedBlockRatio: Double
    public let minimumTextureCoverage: Double
    public let ambiguityScoreTolerance: Double
    public let minimumOverlapRatio: Double

    public init(
        minimumOverlapRows: Int = 24,
        minimumFixedHeaderRows: Int = 8,
        maximumFixedHeaderRows: Int = 512,
        minimumFixedFooterRows: Int = 8,
        maximumFixedFooterRows: Int = 512,
        coarseCandidateCount: Int = 16,
        horizontalSearchRadius: Int = 2,
        minimumBlockSimilarity: Double = 0.78,
        minimumMatchScore: Double = 0.82,
        minimumMatchedBlockRatio: Double = 0.58,
        minimumTextureCoverage: Double = 0.18,
        ambiguityScoreTolerance: Double = 0.015,
        minimumOverlapRatio: Double = 0.30
    ) {
        self.minimumOverlapRows = max(1, minimumOverlapRows)
        self.minimumFixedHeaderRows = max(1, minimumFixedHeaderRows)
        self.maximumFixedHeaderRows = max(0, maximumFixedHeaderRows)
        self.minimumFixedFooterRows = max(1, minimumFixedFooterRows)
        self.maximumFixedFooterRows = max(0, maximumFixedFooterRows)
        self.coarseCandidateCount = max(1, coarseCandidateCount)
        self.horizontalSearchRadius = max(0, horizontalSearchRadius)
        self.minimumBlockSimilarity = Self.clampedUnit(minimumBlockSimilarity)
        self.minimumMatchScore = minimumMatchScore.isFinite
            ? min(1, max(0, minimumMatchScore))
            : 1
        self.minimumMatchedBlockRatio = Self.clampedUnit(minimumMatchedBlockRatio)
        self.minimumTextureCoverage = Self.clampedUnit(minimumTextureCoverage)
        self.ambiguityScoreTolerance = ambiguityScoreTolerance.isFinite
            ? max(0, ambiguityScoreTolerance)
            : 0
        self.minimumOverlapRatio = Self.clampedUnit(minimumOverlapRatio)
    }

    private static func clampedUnit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }
}

public struct ScrollingFrameTemporalContext: Equatable, Sendable {
    public let recentAcceptedScrollRows: [Int]

    public init(recentAcceptedScrollRows: [Int]) {
        self.recentAcceptedScrollRows = Array(
            recentAcceptedScrollRows.filter { $0 > 0 }.suffix(5)
        )
    }

    public var consensusScrollRows: Int? {
        guard recentAcceptedScrollRows.count >= 2 else { return nil }
        let sorted = recentAcceptedScrollRows.sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(1, median / 3)
        let agreeing = recentAcceptedScrollRows.filter { abs($0 - median) <= tolerance }
        guard agreeing.count >= 2, agreeing.count * 3 >= recentAcceptedScrollRows.count * 2 else {
            return nil
        }
        return median
    }
}

public struct ScrollingFrameAlignmentHint: Equatable, Sendable {
    public let scrollRows: Int
    public let horizontalShift: Int
    public let agreeingRegions: Int
    public let sampledRegions: Int
    public let confidence: Double

    public init(
        scrollRows: Int,
        horizontalShift: Int,
        agreeingRegions: Int,
        sampledRegions: Int,
        confidence: Double
    ) {
        self.scrollRows = max(0, scrollRows)
        self.horizontalShift = horizontalShift
        self.agreeingRegions = max(0, agreeingRegions)
        self.sampledRegions = max(0, sampledRegions)
        self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
    }

    public var hasConsensus: Bool {
        sampledRegions >= 2 && agreeingRegions >= 2 && agreeingRegions * 2 > sampledRegions
    }
}

public struct ScrollingStitchMatch: Equatable, Sendable {
    public let overlapRows: Int
    public let fixedHeaderRows: Int
    public let fixedFooterRows: Int
    public let incomingSourceRows: Range<Int>
    public let confidence: Double
    public let verticalSubpixelOffset: Double

    public init(
        overlapRows: Int,
        fixedHeaderRows: Int,
        fixedFooterRows: Int = 0,
        incomingSourceRows: Range<Int>,
        confidence: Double,
        verticalSubpixelOffset: Double = 0
    ) {
        self.overlapRows = overlapRows
        self.fixedHeaderRows = fixedHeaderRows
        self.fixedFooterRows = fixedFooterRows
        self.incomingSourceRows = incomingSourceRows
        self.confidence = confidence
        self.verticalSubpixelOffset = verticalSubpixelOffset
    }
}

public enum ScrollingScreenshotRecoveryReason: Equatable, Sendable {
    case invalidFrame
    case incompatibleFrameSize(expected: ScreenshotPixelSize, actual: ScreenshotPixelSize)
    case ambiguousOverlap(candidateCount: Int)
    case reverseScroll(overlapRows: Int)
    case insufficientOverlap
}

public enum ScrollingScreenshotStopReason: Equatable, Sendable {
    case sizeLimitExceeded(ScrollingScreenshotSizeAssessment)
}

public enum ScrollingStitchDecision: Equatable, Sendable {
    case seed
    case append(ScrollingStitchMatch)
    case noNewContent
    case recover(ScrollingScreenshotRecoveryReason)
    case stop(ScrollingScreenshotStopReason)
}

public enum ScrollingScreenshotSessionPhase: Equatable, Sendable {
    case awaitingFirstFrame
    case capturing
    case recovering(ScrollingScreenshotRecoveryReason)
    case stopped(ScrollingScreenshotStopReason)
}

public struct ScrollingScreenshotSessionState: Equatable, Sendable {
    public let phase: ScrollingScreenshotSessionPhase
    public let outputSize: ScreenshotPixelSize
    public let observedFrameCount: Int
    public let acceptedFrameCount: Int
    public let consecutiveRejectedFrameCount: Int
    public let fixedHeaderRows: Int
    public let fixedFooterRows: Int
    public let fixedHeaderObservationCount: Int
    public let fixedFooterObservationCount: Int
    public let lastAcceptedFrame: ScrollingFrameDescriptor?
    public let lastAcceptedScrollRows: Int?
    public let recentAcceptedScrollRows: [Int]
    public let sizeAssessment: ScrollingScreenshotSizeAssessment?

    public init() {
        phase = .awaitingFirstFrame
        outputSize = ScreenshotPixelSize(width: 0, height: 0)
        observedFrameCount = 0
        acceptedFrameCount = 0
        consecutiveRejectedFrameCount = 0
        fixedHeaderRows = 0
        fixedFooterRows = 0
        fixedHeaderObservationCount = 0
        fixedFooterObservationCount = 0
        lastAcceptedFrame = nil
        lastAcceptedScrollRows = nil
        recentAcceptedScrollRows = []
        sizeAssessment = nil
    }

    init(
        phase: ScrollingScreenshotSessionPhase,
        outputSize: ScreenshotPixelSize,
        observedFrameCount: Int,
        acceptedFrameCount: Int,
        consecutiveRejectedFrameCount: Int,
        fixedHeaderRows: Int,
        fixedFooterRows: Int,
        fixedHeaderObservationCount: Int = 0,
        fixedFooterObservationCount: Int = 0,
        lastAcceptedFrame: ScrollingFrameDescriptor?,
        lastAcceptedScrollRows: Int?,
        recentAcceptedScrollRows: [Int] = [],
        sizeAssessment: ScrollingScreenshotSizeAssessment?
    ) {
        self.phase = phase
        self.outputSize = outputSize
        self.observedFrameCount = observedFrameCount
        self.acceptedFrameCount = acceptedFrameCount
        self.consecutiveRejectedFrameCount = consecutiveRejectedFrameCount
        self.fixedHeaderRows = fixedHeaderRows
        self.fixedFooterRows = fixedFooterRows
        self.fixedHeaderObservationCount = fixedHeaderObservationCount
        self.fixedFooterObservationCount = fixedFooterObservationCount
        self.lastAcceptedFrame = lastAcceptedFrame
        self.lastAcceptedScrollRows = lastAcceptedScrollRows
        self.recentAcceptedScrollRows = Array(recentAcceptedScrollRows.suffix(5))
        self.sizeAssessment = sizeAssessment
    }

    public var hasConfirmedFixedHeader: Bool {
        fixedHeaderRows > 0 && fixedHeaderObservationCount >= 2
    }

    public var hasConfirmedFixedFooter: Bool {
        fixedFooterRows > 0 && fixedFooterObservationCount >= 2
    }
}

public struct ScrollingScreenshotWriteOperation: Equatable, Sendable {
    public let frameID: String
    public let sourceRows: Range<Int>
    public let destinationY: Int

    public init(frameID: String, sourceRows: Range<Int>, destinationY: Int) {
        self.frameID = frameID
        self.sourceRows = sourceRows
        self.destinationY = destinationY
    }
}

public enum ScrollingScreenshotAssemblyOperation: Equatable, Sendable {
    case write(ScrollingScreenshotWriteOperation)
    case none
}

public struct ScrollingScreenshotAssemblyDecision: Equatable, Sendable {
    public let stitchDecision: ScrollingStitchDecision
    public let operation: ScrollingScreenshotAssemblyOperation
    public let nextState: ScrollingScreenshotSessionState

    public init(
        stitchDecision: ScrollingStitchDecision,
        operation: ScrollingScreenshotAssemblyOperation,
        nextState: ScrollingScreenshotSessionState
    ) {
        self.stitchDecision = stitchDecision
        self.operation = operation
        self.nextState = nextState
    }
}
