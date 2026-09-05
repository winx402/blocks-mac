import Foundation

public struct ScrollingScreenshotAssembler: Sendable {
    public let matcher: ScrollingScreenshotMatcher
    public let sizePolicy: ScrollingScreenshotSizePolicy

    public init(
        matcher: ScrollingScreenshotMatcher = .init(),
        sizePolicy: ScrollingScreenshotSizePolicy = .standard
    ) {
        self.matcher = matcher
        self.sizePolicy = sizePolicy
    }

    public func decide(
        state: ScrollingScreenshotSessionState,
        incoming: ScrollingFrameDescriptor,
        alignmentHint: ScrollingFrameAlignmentHint? = nil
    ) -> ScrollingScreenshotAssemblyDecision {
        if case let .stopped(reason) = state.phase {
            return ScrollingScreenshotAssemblyDecision(
                stitchDecision: .stop(reason),
                operation: .none,
                nextState: state
            )
        }

        guard let previous = state.lastAcceptedFrame else {
            return seed(state: state, incoming: incoming)
        }

        let stitchDecision = matcher.decide(
            previous: previous,
            incoming: incoming,
            expectedScrollRows: state.lastAcceptedScrollRows,
            temporalContext: .init(recentAcceptedScrollRows: state.recentAcceptedScrollRows),
            alignmentHint: alignmentHint,
            knownFixedHeaderRows: state.fixedHeaderObservationCount > 0 ? state.fixedHeaderRows : 0,
            knownFixedFooterRows: state.fixedFooterObservationCount > 0 ? state.fixedFooterRows : 0,
            detectsStaticBands: !state.hasConfirmedFixedHeader || !state.hasConfirmedFixedFooter
        )
        switch stitchDecision {
        case let .append(match):
            return append(state: state, incoming: incoming, match: match)
        case .noNewContent:
            return noNewContent(state: state, incoming: incoming)
        case let .recover(reason):
            return recover(state: state, reason: reason)
        case .seed:
            return recover(state: state, reason: .invalidFrame)
        case let .stop(reason):
            return stop(state: state, reason: reason)
        }
    }

    private func seed(
        state: ScrollingScreenshotSessionState,
        incoming: ScrollingFrameDescriptor
    ) -> ScrollingScreenshotAssemblyDecision {
        guard incoming.pixelWidth > 0, incoming.pixelHeight > 0 else {
            return recover(state: state, reason: .invalidFrame)
        }

        let assessment = sizePolicy.assess(incoming.pixelSize)
        guard assessment.status != .exceedsLimit else {
            return stop(state: state, reason: .sizeLimitExceeded(assessment))
        }

        let nextState = ScrollingScreenshotSessionState(
            phase: .capturing,
            outputSize: incoming.pixelSize,
            observedFrameCount: state.observedFrameCount + 1,
            acceptedFrameCount: state.acceptedFrameCount + 1,
            consecutiveRejectedFrameCount: 0,
            fixedHeaderRows: 0,
            fixedFooterRows: 0,
            fixedHeaderObservationCount: 0,
            fixedFooterObservationCount: 0,
            lastAcceptedFrame: incoming,
            lastAcceptedScrollRows: nil,
            recentAcceptedScrollRows: [],
            sizeAssessment: assessment
        )
        return ScrollingScreenshotAssemblyDecision(
            stitchDecision: .seed,
            operation: .write(ScrollingScreenshotWriteOperation(
                frameID: incoming.id,
                sourceRows: 0..<incoming.pixelHeight,
                destinationY: 0
            )),
            nextState: nextState
        )
    }

    private func append(
        state: ScrollingScreenshotSessionState,
        incoming: ScrollingFrameDescriptor,
        match: ScrollingStitchMatch
    ) -> ScrollingScreenshotAssemblyDecision {
        let replaceableFooterRows = max(state.fixedFooterRows, match.fixedFooterRows)
        let destinationY = max(0, state.outputSize.height - replaceableFooterRows)
        let nextSize = ScreenshotPixelSize(
            width: state.outputSize.width,
            height: destinationY + match.incomingSourceRows.count + match.fixedFooterRows
        )
        let assessment = sizePolicy.assess(nextSize)
        guard assessment.status != .exceedsLimit else {
            return stop(state: state, reason: .sizeLimitExceeded(assessment))
        }
        let headerConsensus = updatedStaticBandConsensus(
            currentRows: state.fixedHeaderRows,
            observationCount: state.fixedHeaderObservationCount,
            observedRows: match.fixedHeaderRows
        )
        let footerConsensus = updatedStaticBandConsensus(
            currentRows: state.fixedFooterRows,
            observationCount: state.fixedFooterObservationCount,
            observedRows: match.fixedFooterRows
        )
        let scrollRows = match.incomingSourceRows.count
        let recentScrollRows = Array((state.recentAcceptedScrollRows + [scrollRows]).suffix(5))

        let nextState = ScrollingScreenshotSessionState(
            phase: .capturing,
            outputSize: nextSize,
            observedFrameCount: state.observedFrameCount + 1,
            acceptedFrameCount: state.acceptedFrameCount + 1,
            consecutiveRejectedFrameCount: 0,
            fixedHeaderRows: headerConsensus.rows,
            fixedFooterRows: footerConsensus.rows,
            fixedHeaderObservationCount: headerConsensus.count,
            fixedFooterObservationCount: footerConsensus.count,
            lastAcceptedFrame: incoming,
            lastAcceptedScrollRows: scrollRows,
            recentAcceptedScrollRows: recentScrollRows,
            sizeAssessment: assessment
        )
        return ScrollingScreenshotAssemblyDecision(
            stitchDecision: .append(match),
            operation: .write(ScrollingScreenshotWriteOperation(
                frameID: incoming.id,
                sourceRows: match.incomingSourceRows,
                destinationY: destinationY
            )),
            nextState: nextState
        )
    }

    private func noNewContent(
        state: ScrollingScreenshotSessionState,
        incoming: ScrollingFrameDescriptor
    ) -> ScrollingScreenshotAssemblyDecision {
        let nextState = ScrollingScreenshotSessionState(
            phase: .capturing,
            outputSize: state.outputSize,
            observedFrameCount: state.observedFrameCount + 1,
            acceptedFrameCount: state.acceptedFrameCount,
            consecutiveRejectedFrameCount: 0,
            fixedHeaderRows: state.fixedHeaderRows,
            fixedFooterRows: state.fixedFooterRows,
            fixedHeaderObservationCount: state.fixedHeaderObservationCount,
            fixedFooterObservationCount: state.fixedFooterObservationCount,
            lastAcceptedFrame: state.lastAcceptedFrame,
            lastAcceptedScrollRows: state.lastAcceptedScrollRows,
            recentAcceptedScrollRows: state.recentAcceptedScrollRows,
            sizeAssessment: state.sizeAssessment
        )
        return ScrollingScreenshotAssemblyDecision(
            stitchDecision: .noNewContent,
            operation: .none,
            nextState: nextState
        )
    }

    private func recover(
        state: ScrollingScreenshotSessionState,
        reason: ScrollingScreenshotRecoveryReason
    ) -> ScrollingScreenshotAssemblyDecision {
        let nextState = ScrollingScreenshotSessionState(
            phase: .recovering(reason),
            outputSize: state.outputSize,
            observedFrameCount: state.observedFrameCount + 1,
            acceptedFrameCount: state.acceptedFrameCount,
            consecutiveRejectedFrameCount: state.consecutiveRejectedFrameCount + 1,
            fixedHeaderRows: state.fixedHeaderRows,
            fixedFooterRows: state.fixedFooterRows,
            fixedHeaderObservationCount: state.fixedHeaderObservationCount,
            fixedFooterObservationCount: state.fixedFooterObservationCount,
            lastAcceptedFrame: state.lastAcceptedFrame,
            lastAcceptedScrollRows: state.lastAcceptedScrollRows,
            recentAcceptedScrollRows: state.recentAcceptedScrollRows,
            sizeAssessment: state.sizeAssessment
        )
        return ScrollingScreenshotAssemblyDecision(
            stitchDecision: .recover(reason),
            operation: .none,
            nextState: nextState
        )
    }

    private func stop(
        state: ScrollingScreenshotSessionState,
        reason: ScrollingScreenshotStopReason
    ) -> ScrollingScreenshotAssemblyDecision {
        let assessment: ScrollingScreenshotSizeAssessment
        switch reason {
        case let .sizeLimitExceeded(value):
            assessment = value
        }
        let nextState = ScrollingScreenshotSessionState(
            phase: .stopped(reason),
            outputSize: state.outputSize,
            observedFrameCount: state.observedFrameCount + 1,
            acceptedFrameCount: state.acceptedFrameCount,
            consecutiveRejectedFrameCount: state.consecutiveRejectedFrameCount,
            fixedHeaderRows: state.fixedHeaderRows,
            fixedFooterRows: state.fixedFooterRows,
            fixedHeaderObservationCount: state.fixedHeaderObservationCount,
            fixedFooterObservationCount: state.fixedFooterObservationCount,
            lastAcceptedFrame: state.lastAcceptedFrame,
            lastAcceptedScrollRows: state.lastAcceptedScrollRows,
            recentAcceptedScrollRows: state.recentAcceptedScrollRows,
            sizeAssessment: assessment
        )
        return ScrollingScreenshotAssemblyDecision(
            stitchDecision: .stop(reason),
            operation: .none,
            nextState: nextState
        )
    }

    private func updatedStaticBandConsensus(
        currentRows: Int,
        observationCount: Int,
        observedRows: Int
    ) -> (rows: Int, count: Int) {
        guard observedRows > 0 else { return (0, 0) }
        guard currentRows == 0 || currentRows == observedRows else {
            return (observedRows, 1)
        }
        return (observedRows, min(2, observationCount + 1))
    }
}
