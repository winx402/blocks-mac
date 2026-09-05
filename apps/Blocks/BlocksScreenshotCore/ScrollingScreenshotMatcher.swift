import Foundation

public struct ScrollingScreenshotMatcher: Sendable {
    public let configuration: ScrollingScreenshotMatcherConfiguration

    public init(configuration: ScrollingScreenshotMatcherConfiguration = .init()) {
        self.configuration = configuration
    }

    public func decide(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        expectedScrollRows: Int? = nil,
        temporalContext: ScrollingFrameTemporalContext? = nil,
        alignmentHint: ScrollingFrameAlignmentHint? = nil,
        knownFixedHeaderRows: Int = 0,
        knownFixedFooterRows: Int = 0,
        detectsStaticBands: Bool = true
    ) -> ScrollingStitchDecision {
        guard isValid(previous), isValid(incoming) else {
            return .recover(.invalidFrame)
        }
        guard previous.pixelSize == incoming.pixelSize,
              previous.sampleWidth == incoming.sampleWidth else {
            return .recover(.incompatibleFrameSize(
                expected: previous.pixelSize,
                actual: incoming.pixelSize
            ))
        }

        if let unchanged = refinedAlignment(
            previous: previous,
            incoming: incoming,
            previousStart: 0,
            incomingStart: 0,
            rowCount: previous.pixelHeight,
            coarseScore: 1,
            verticalSubpixelOffsets: [0]
        ), unchanged.score >= max(configuration.minimumMatchScore, 0.985) {
            return .noNewContent
        }

        let contentInsets = candidateContentInsets(
            previous: previous,
            incoming: incoming,
            knownFixedHeaderRows: knownFixedHeaderRows,
            knownFixedFooterRows: knownFixedFooterRows,
            detectsStaticBands: detectsStaticBands
        )
        let downwardCandidates = contentInsets.flatMap { insets in
            candidates(
                previous: previous,
                incoming: incoming,
                insets: insets,
                direction: .downward
            )
        }

        switch resolve(
            downwardCandidates,
            expectedScrollRows: expectedScrollRows,
            temporalContext: temporalContext,
            alignmentHint: alignmentHint
        ) {
        case let .match(candidate):
            let sourceStart = candidate.headerRows + candidate.overlapRows
            let sourceEnd = incoming.pixelHeight - candidate.footerRows
            guard sourceStart < sourceEnd else { return .noNewContent }
            return .append(ScrollingStitchMatch(
                overlapRows: candidate.overlapRows,
                fixedHeaderRows: candidate.headerRows,
                fixedFooterRows: candidate.footerRows,
                incomingSourceRows: sourceStart..<sourceEnd,
                confidence: candidate.score,
                verticalSubpixelOffset: candidate.verticalSubpixelOffset
            ))
        case let .ambiguous(candidateCount):
            return .recover(.ambiguousOverlap(candidateCount: candidateCount))
        case .none:
            break
        }

        let reverseCandidates = contentInsets.flatMap { insets in
            candidates(
                previous: previous,
                incoming: incoming,
                insets: insets,
                direction: .reverse
            )
        }
        switch resolve(
            reverseCandidates,
            expectedScrollRows: expectedScrollRows,
            temporalContext: temporalContext,
            alignmentHint: alignmentHint
        ) {
        case let .match(candidate):
            return .recover(.reverseScroll(overlapRows: candidate.overlapRows))
        case let .ambiguous(candidateCount):
            return .recover(.ambiguousOverlap(candidateCount: candidateCount))
        case .none:
            return .recover(.insufficientOverlap)
        }
    }

    private func isValid(_ frame: ScrollingFrameDescriptor) -> Bool {
        frame.pixelWidth > 0
            && frame.pixelHeight > 0
            && frame.sampleWidth > 0
            && frame.sampleHeight == frame.pixelHeight
            && frame.lumaSamples.count == frame.sampleWidth * frame.pixelHeight
    }

    private func candidateContentInsets(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        knownFixedHeaderRows: Int,
        knownFixedFooterRows: Int,
        detectsStaticBands: Bool
    ) -> [ContentInsets] {
        let detectedHeader = detectsStaticBands
            ? fixedBandRows(previous: previous, incoming: incoming, edge: .top)
            : nil
        let detectedFooter = detectsStaticBands
            ? fixedBandRows(previous: previous, incoming: incoming, edge: .bottom)
            : nil
        let headerCandidates = staticBandCandidates(
            previous: previous,
            incoming: incoming,
            knownRows: knownFixedHeaderRows,
            detectedRows: detectedHeader,
            edge: .top
        )
        let hasStableKnownHeader = knownFixedHeaderRows == 0 || isKnownBandStable(
            previous: previous,
            incoming: incoming,
            rows: knownFixedHeaderRows,
            edge: .top
        )
        let footerCandidates = footerInsetCandidates(
            previous: previous,
            incoming: incoming,
            knownRows: knownFixedFooterRows,
            detectedRows: detectedFooter,
            allowsAsymmetricReplacement: hasStableKnownHeader
        )
        var seen = Set<ContentInsets>()
        return headerCandidates.flatMap { headerRows in
            footerCandidates.compactMap { footer in
                let insets = ContentInsets(
                    headerRows: headerRows,
                    previousFooterRows: footer.previousRows,
                    incomingFooterRows: footer.incomingRows
                )
                guard seen.insert(insets).inserted,
                      previous.pixelHeight - headerRows - footer.previousRows
                        >= configuration.minimumOverlapRows,
                      incoming.pixelHeight - headerRows - footer.incomingRows
                        >= configuration.minimumOverlapRows else { return nil }
                return insets
            }
        }
    }

    private func footerInsetCandidates(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        knownRows: Int,
        detectedRows: Int?,
        allowsAsymmetricReplacement: Bool
    ) -> [FooterInsets] {
        guard knownRows > 0 else {
            return [FooterInsets(previousRows: 0, incomingRows: 0)]
                + [detectedRows].compactMap { rows in
                    rows.map { FooterInsets(previousRows: $0, incomingRows: $0) }
                }
        }
        if isKnownBandStable(
            previous: previous,
            incoming: incoming,
            rows: knownRows,
            edge: .bottom
        ) {
            return [FooterInsets(previousRows: knownRows, incomingRows: knownRows)]
        }

        var candidates = [FooterInsets(previousRows: 0, incomingRows: 0)]
        if allowsAsymmetricReplacement {
            candidates.insert(
                FooterInsets(previousRows: knownRows, incomingRows: 0),
                at: 0
            )
        }
        if let detectedRows {
            candidates.append(FooterInsets(
                previousRows: detectedRows,
                incomingRows: detectedRows
            ))
        }
        return candidates
    }

    private func staticBandCandidates(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        knownRows: Int,
        detectedRows: Int?,
        edge: StaticBandEdge
    ) -> [Int] {
        guard knownRows > 0 else { return [0, detectedRows ?? 0] }
        guard isKnownBandStable(
            previous: previous,
            incoming: incoming,
            rows: knownRows,
            edge: edge
        ) else {
            return [0]
        }
        return [knownRows]
    }

    private func fixedBandRows(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        edge: StaticBandEdge
    ) -> Int? {
        let minimumRows = edge == .top
            ? configuration.minimumFixedHeaderRows
            : configuration.minimumFixedFooterRows
        let maximumRows = edge == .top
            ? configuration.maximumFixedHeaderRows
            : configuration.maximumFixedFooterRows
        let limit = min(
            maximumRows,
            min(previous.pixelHeight, incoming.pixelHeight) - configuration.minimumOverlapRows
        )
        guard limit >= minimumRows else { return nil }

        var lastStableRow = -1
        var consecutiveUnstableRows = 0
        for offset in 0..<limit {
            let row = edge == .top ? offset : previous.pixelHeight - 1 - offset
            if rowSimilarity(previous, row, incoming, row) >= 0.9 {
                lastStableRow = offset
                consecutiveUnstableRows = 0
            } else {
                consecutiveUnstableRows += 1
                if consecutiveUnstableRows >= 2 { break }
            }
        }
        let rows = lastStableRow + 1
        return rows >= minimumRows ? rows : nil
    }

    private func isKnownBandStable(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        rows: Int,
        edge: StaticBandEdge
    ) -> Bool {
        guard rows > 0, rows <= min(previous.pixelHeight, incoming.pixelHeight) else {
            return false
        }
        let similarities = (0..<rows).map { offset -> Double in
            let row = edge == .top ? offset : previous.pixelHeight - 1 - offset
            return rowSimilarity(previous, row, incoming, row)
        }
        let matching = similarities.filter { $0 >= 0.9 }.count
        let mean = similarities.reduce(0, +) / Double(rows)
        return matching * 10 >= rows * 9 && mean >= 0.9
    }

    private func candidates(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        insets: ContentInsets,
        direction: Direction
    ) -> [Candidate] {
        let previousContentHeight = previous.pixelHeight
            - insets.headerRows
            - insets.previousFooterRows
        let incomingContentHeight = incoming.pixelHeight
            - insets.headerRows
            - insets.incomingFooterRows
        let scrollingContentHeight = direction == .downward
            ? previousContentHeight
            : incomingContentHeight
        let maximumScrollRows = scrollingContentHeight - configuration.minimumOverlapRows
        guard maximumScrollRows > 0 else { return [] }

        var coarse: [(scrollRows: Int, overlapRows: Int, score: Double)] = []
        coarse.reserveCapacity(maximumScrollRows)
        for scrollRows in 1...maximumScrollRows {
            let overlapRows = direction == .downward
                ? min(previousContentHeight - scrollRows, incomingContentHeight)
                : min(previousContentHeight, incomingContentHeight - scrollRows)
            guard overlapRows >= configuration.minimumOverlapRows else { continue }
            let starts = alignmentStarts(
                contentStart: insets.headerRows,
                scrollRows: scrollRows,
                direction: direction
            )
            let score = coarseSimilarity(
                previous: previous,
                incoming: incoming,
                previousStart: starts.previous,
                incomingStart: starts.incoming,
                rowCount: overlapRows
            )
            coarse.append((scrollRows, overlapRows, score))
        }

        let shortlist = coarse.sorted {
            if $0.score == $1.score { return $0.overlapRows > $1.overlapRows }
            return $0.score > $1.score
        }.prefix(configuration.coarseCandidateCount)

        return shortlist.compactMap { item in
            let starts = alignmentStarts(
                contentStart: insets.headerRows,
                scrollRows: item.scrollRows,
                direction: direction
            )
            guard let refined = refinedAlignment(
                previous: previous,
                incoming: incoming,
                previousStart: starts.previous,
                incomingStart: starts.incoming,
                rowCount: item.overlapRows,
                coarseScore: item.score
            ) else { return nil }
            let denseDifference = denseAlignmentDifference(
                previous: previous,
                incoming: incoming,
                previousStart: starts.previous,
                incomingStart: starts.incoming,
                rowCount: item.overlapRows,
                horizontalShift: refined.horizontalShift,
                verticalSubpixelOffset: refined.verticalSubpixelOffset
            )
            return Candidate(
                headerRows: insets.headerRows,
                footerRows: insets.incomingFooterRows,
                scrollRows: item.scrollRows,
                overlapRows: item.overlapRows,
                score: refined.score,
                denseDifference: denseDifference,
                horizontalShift: refined.horizontalShift,
                verticalSubpixelOffset: refined.verticalSubpixelOffset
            )
        }
    }

    private func alignmentStarts(
        contentStart: Int,
        scrollRows: Int,
        direction: Direction
    ) -> (previous: Int, incoming: Int) {
        switch direction {
        case .downward:
            (contentStart + scrollRows, contentStart)
        case .reverse:
            (contentStart, contentStart + scrollRows)
        }
    }

    private func coarseSimilarity(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        previousStart: Int,
        incomingStart: Int,
        rowCount: Int
    ) -> Double {
        let scales = [
            (x: 8, y: 8, weight: 0.25),
            (x: 18, y: 18, weight: 0.45),
            (x: 28, y: 24, weight: 0.30),
        ]
        return scales.reduce(0) { result, scale in
            result + multiscaleSimilarity(
                previous: previous,
                incoming: incoming,
                previousStart: previousStart,
                incomingStart: incomingStart,
                rowCount: rowCount,
                xCount: scale.x,
                yCount: scale.y
            ) * scale.weight
        }
    }

    private func multiscaleSimilarity(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        previousStart: Int,
        incomingStart: Int,
        rowCount: Int,
        xCount requestedXCount: Int,
        yCount requestedYCount: Int
    ) -> Double {
        let width = previous.sampleWidth
        let inset = max(0, width / 12)
        let usableWidth = max(1, width - inset * 2)
        let xCount = min(requestedXCount, usableWidth)
        let yCount = min(requestedYCount, rowCount)
        var totalDifference = 0
        var sampleCount = 0

        for yIndex in 0..<yCount {
            let rowOffset = distributedIndex(yIndex, count: yCount, length: rowCount)
            for xIndex in 0..<xCount {
                let x = inset + distributedIndex(xIndex, count: xCount, length: usableWidth)
                let lhs = Int(previous.lumaSamples[(previousStart + rowOffset) * width + x])
                let rhs = Int(incoming.lumaSamples[(incomingStart + rowOffset) * width + x])
                totalDifference += min(128, abs(lhs - rhs))
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }
        return max(0, 1 - Double(totalDifference) / Double(sampleCount * 96))
    }

    private func refinedAlignment(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        previousStart: Int,
        incomingStart: Int,
        rowCount: Int,
        coarseScore: Double,
        verticalSubpixelOffsets: [Double] = [-0.5, 0, 0.5]
    ) -> AlignmentScore? {
        let width = previous.sampleWidth
        let inset = max(0, width / 12)
        let usableWidth = max(1, width - inset * 2)
        let xBandCount = min(4, max(1, usableWidth / 6))
        let yBandCount = min(10, max(1, rowCount / 3))
        var best: AlignmentScore?

        for horizontalShift in (-configuration.horizontalSearchRadius)...configuration.horizontalSearchRadius {
            for verticalSubpixelOffset in verticalSubpixelOffsets {
                var blockScores: [Double] = []
                var texturedYBands = Set<Int>()
                let potentialBlockCount = xBandCount * yBandCount
                for yBand in 0..<yBandCount {
                    let yRange = partition(yBand, count: yBandCount, length: rowCount)
                    for xBand in 0..<xBandCount {
                        let xRange = partition(xBand, count: xBandCount, length: usableWidth)
                        let shifted = (xRange.lowerBound + inset + horizontalShift)..<(xRange.upperBound + inset + horizontalShift)
                        guard shifted.lowerBound >= 0, shifted.upperBound <= width else { continue }
                        if let score = blockSimilarity(
                            previous: previous,
                            incoming: incoming,
                            previousStart: previousStart + yRange.lowerBound,
                            incomingStart: incomingStart + yRange.lowerBound,
                            rowCount: yRange.count,
                            previousXRange: (xRange.lowerBound + inset)..<(xRange.upperBound + inset),
                            incomingXRange: shifted,
                            verticalSubpixelOffset: verticalSubpixelOffset
                        ) {
                            blockScores.append(score)
                            texturedYBands.insert(yBand)
                        }
                    }
                }
                guard !blockScores.isEmpty else { continue }
                let textureCoverage = Double(blockScores.count) / Double(max(1, potentialBlockCount))
                let minimumYBandCoverage = min(2, yBandCount)
                guard textureCoverage >= configuration.minimumTextureCoverage,
                      texturedYBands.count >= minimumYBandCoverage else { continue }
                let matchedCount = blockScores.filter { $0 >= configuration.minimumBlockSimilarity }.count
                let matchedRatio = Double(matchedCount) / Double(blockScores.count)
                let sortedScores = blockScores.sorted()
                let median = sortedScores[sortedScores.count / 2]
                let trimmed = sortedScores.dropFirst(sortedScores.count / 5)
                let robustMean = trimmed.reduce(0, +) / Double(max(1, trimmed.count))
                let score = median * 0.5 + robustMean * 0.3 + matchedRatio * 0.15 + coarseScore * 0.05
                guard matchedRatio >= configuration.minimumMatchedBlockRatio,
                      score >= configuration.minimumMatchScore else { continue }
                if best == nil || score > best!.score {
                    best = AlignmentScore(
                        score: min(1, score),
                        horizontalShift: horizontalShift,
                        verticalSubpixelOffset: verticalSubpixelOffset
                    )
                }
            }
        }
        return best
    }

    private func blockSimilarity(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        previousStart: Int,
        incomingStart: Int,
        rowCount: Int,
        previousXRange: Range<Int>,
        incomingXRange: Range<Int>,
        verticalSubpixelOffset: Double
    ) -> Double? {
        let coarse = sampledBlockSimilarity(
            previous: previous,
            incoming: incoming,
            previousStart: previousStart,
            incomingStart: incomingStart,
            rowCount: rowCount,
            previousXRange: previousXRange,
            incomingXRange: incomingXRange,
            verticalSubpixelOffset: verticalSubpixelOffset,
            requestedXSamples: 6,
            requestedYSamples: 6
        )
        let detailed = sampledBlockSimilarity(
            previous: previous,
            incoming: incoming,
            previousStart: previousStart,
            incomingStart: incomingStart,
            rowCount: rowCount,
            previousXRange: previousXRange,
            incomingXRange: incomingXRange,
            verticalSubpixelOffset: verticalSubpixelOffset,
            requestedXSamples: 12,
            requestedYSamples: 12
        )
        switch (coarse, detailed) {
        case let (.some(coarse), .some(detailed)):
            return coarse * 0.35 + detailed * 0.65
        case let (.some(score), .none), let (.none, .some(score)):
            return score
        case (.none, .none):
            return nil
        }
    }

    private func sampledBlockSimilarity(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        previousStart: Int,
        incomingStart: Int,
        rowCount: Int,
        previousXRange: Range<Int>,
        incomingXRange: Range<Int>,
        verticalSubpixelOffset: Double,
        requestedXSamples: Int,
        requestedYSamples: Int
    ) -> Double? {
        let width = previous.sampleWidth
        let xSamples = min(requestedXSamples, previousXRange.count)
        let ySamples = min(requestedYSamples, rowCount)
        var lhsSum = 0.0
        var rhsSum = 0.0
        var lhsSquaredSum = 0.0
        var rhsSquaredSum = 0.0
        var productSum = 0.0
        var absoluteDifference = 0.0
        var sampleCount = 0

        for yIndex in 0..<ySamples {
            let y = distributedIndex(yIndex, count: ySamples, length: rowCount)
            for xIndex in 0..<xSamples {
                let lhsX = previousXRange.lowerBound
                    + distributedIndex(xIndex, count: xSamples, length: previousXRange.count)
                let rhsX = incomingXRange.lowerBound
                    + distributedIndex(xIndex, count: xSamples, length: incomingXRange.count)
                let lhsValue = Double(previous.lumaSamples[(previousStart + y) * width + lhsX])
                guard let rhsValue = interpolatedLuma(
                    incoming,
                    row: Double(incomingStart + y) + verticalSubpixelOffset,
                    x: rhsX
                ) else { continue }
                lhsSum += lhsValue
                rhsSum += rhsValue
                lhsSquaredSum += lhsValue * lhsValue
                rhsSquaredSum += rhsValue * rhsValue
                productSum += lhsValue * rhsValue
                absoluteDifference += abs(lhsValue - rhsValue)
                sampleCount += 1
            }
        }
        guard sampleCount >= 4 else { return nil }

        let count = Double(sampleCount)
        let lhsMean = lhsSum / count
        let rhsMean = rhsSum / count
        let lhsVariance = max(0, lhsSquaredSum / count - lhsMean * lhsMean)
        let rhsVariance = max(0, rhsSquaredSum / count - rhsMean * rhsMean)
        let covariance = productSum / count - lhsMean * rhsMean
        let meanDifference = absoluteDifference / count
        if lhsVariance < 9, rhsVariance < 9 {
            return meanDifference <= 6 ? nil : 0
        }
        guard lhsVariance >= 1, rhsVariance >= 1 else { return 0 }
        let correlation = max(0, min(1, covariance / sqrt(lhsVariance * rhsVariance)))
        let absoluteScore = max(0, 1 - meanDifference / 72)
        return correlation * 0.72 + absoluteScore * 0.28
    }

    private func interpolatedLuma(
        _ frame: ScrollingFrameDescriptor,
        row: Double,
        x: Int
    ) -> Double? {
        guard row >= 0, row <= Double(frame.sampleHeight - 1), x >= 0, x < frame.sampleWidth else {
            return nil
        }
        let lowerRow = Int(floor(row))
        let upperRow = min(frame.sampleHeight - 1, lowerRow + 1)
        let fraction = row - Double(lowerRow)
        let lower = Double(frame.lumaSamples[lowerRow * frame.sampleWidth + x])
        let upper = Double(frame.lumaSamples[upperRow * frame.sampleWidth + x])
        return lower + (upper - lower) * fraction
    }

    private func denseAlignmentDifference(
        previous: ScrollingFrameDescriptor,
        incoming: ScrollingFrameDescriptor,
        previousStart: Int,
        incomingStart: Int,
        rowCount: Int,
        horizontalShift: Int,
        verticalSubpixelOffset: Double
    ) -> Double {
        let width = previous.sampleWidth
        let inset = max(2, width / 12)
        let usableWidth = width - inset * 2 - abs(horizontalShift)
        guard usableWidth >= 8, rowCount >= 8 else { return .infinity }

        let xBandCount = min(8, max(1, usableWidth / 8))
        let yBandCount = min(12, max(1, rowCount / 8))
        var blockDifferences: [Double] = []
        blockDifferences.reserveCapacity(xBandCount * yBandCount)

        for yBand in 0..<yBandCount {
            let yRange = partition(yBand, count: yBandCount, length: rowCount)
            for xBand in 0..<xBandCount {
                let xRange = partition(xBand, count: xBandCount, length: usableWidth)
                var difference = 0.0
                var texturedSampleCount = 0

                var y = yRange.lowerBound
                while y < yRange.upperBound {
                    var xOffset = xRange.lowerBound
                    while xOffset < xRange.upperBound {
                        let previousX = inset + xOffset
                        let incomingX = previousX + horizontalShift
                        let previousRow = previousStart + y
                        let incomingRow = Double(incomingStart + y) + verticalSubpixelOffset
                        guard previousX > 0,
                              incomingX > 0,
                              previousRow > 0,
                              let rhs = interpolatedLuma(incoming, row: incomingRow, x: incomingX),
                              let rhsLeft = interpolatedLuma(incoming, row: incomingRow, x: incomingX - 1),
                              let rhsAbove = interpolatedLuma(incoming, row: incomingRow - 1, x: incomingX) else {
                            xOffset += 2
                            continue
                        }

                        let lhs = Double(previous.lumaSamples[previousRow * width + previousX])
                        let lhsLeft = Double(previous.lumaSamples[previousRow * width + previousX - 1])
                        let lhsAbove = Double(previous.lumaSamples[(previousRow - 1) * width + previousX])
                        let lhsTexture = abs(lhs - lhsLeft) + abs(lhs - lhsAbove)
                        let rhsTexture = abs(rhs - rhsLeft) + abs(rhs - rhsAbove)
                        if max(lhsTexture, rhsTexture) >= 8 {
                            let lumaDifference = abs(lhs - rhs) / 255
                            let textureDifference = abs(lhsTexture - rhsTexture) / 510
                            difference += lumaDifference * 0.7 + textureDifference * 0.3
                            texturedSampleCount += 1
                        }
                        xOffset += 2
                    }
                    y += 2
                }

                if texturedSampleCount >= 6 {
                    blockDifferences.append(difference / Double(texturedSampleCount))
                }
            }
        }

        guard blockDifferences.count >= 4 else { return .infinity }
        let sorted = blockDifferences.sorted()
        let retainedCount = max(1, sorted.count - max(1, sorted.count / 20))
        return sorted.prefix(retainedCount).reduce(0, +) / Double(retainedCount)
    }

    private func rowSimilarity(
        _ lhs: ScrollingFrameDescriptor,
        _ lhsRow: Int,
        _ rhs: ScrollingFrameDescriptor,
        _ rhsRow: Int
    ) -> Double {
        let width = lhs.sampleWidth
        let inset = max(0, width / 12)
        let range = inset..<max(inset + 1, width - inset)
        var total = 0
        for x in range {
            total += abs(
                Int(lhs.lumaSamples[lhsRow * width + x])
                    - Int(rhs.lumaSamples[rhsRow * width + x])
            )
        }
        return max(0, 1 - Double(total) / Double(max(1, range.count) * 72))
    }

    private func partition(_ index: Int, count: Int, length: Int) -> Range<Int> {
        let lower = index * length / count
        let upper = (index + 1) * length / count
        return lower..<max(lower + 1, upper)
    }

    private func distributedIndex(_ index: Int, count: Int, length: Int) -> Int {
        guard count > 1, length > 1 else { return 0 }
        return min(length - 1, index * (length - 1) / (count - 1))
    }
}

private extension ScrollingScreenshotMatcher {
    enum Direction {
        case downward
        case reverse
    }

    enum StaticBandEdge {
        case top
        case bottom
    }

    struct ContentInsets: Hashable {
        let headerRows: Int
        let previousFooterRows: Int
        let incomingFooterRows: Int
    }

    struct FooterInsets: Hashable {
        let previousRows: Int
        let incomingRows: Int
    }

    struct AlignmentScore {
        let score: Double
        let horizontalShift: Int
        let verticalSubpixelOffset: Double
    }

    struct Candidate {
        let headerRows: Int
        let footerRows: Int
        let scrollRows: Int
        let overlapRows: Int
        let score: Double
        let denseDifference: Double
        let horizontalShift: Int
        let verticalSubpixelOffset: Double
    }

    enum Resolution {
        case match(Candidate)
        case ambiguous(candidateCount: Int)
        case none
    }

    func resolve(
        _ candidates: [Candidate],
        expectedScrollRows: Int?,
        temporalContext: ScrollingFrameTemporalContext?,
        alignmentHint: ScrollingFrameAlignmentHint?
    ) -> Resolution {
        var bestByScrollRows: [Int: Candidate] = [:]
        for candidate in candidates {
            if let existing = bestByScrollRows[candidate.scrollRows], existing.score >= candidate.score {
                continue
            }
            bestByScrollRows[candidate.scrollRows] = candidate
        }
        let ranked = bestByScrollRows.values.sorted {
            if $0.score == $1.score { return $0.overlapRows > $1.overlapRows }
            return $0.score > $1.score
        }
        guard let rawBest = ranked.first else { return .none }
        let ambiguityTolerance = rawBest.score >= 0.97
            ? min(configuration.ambiguityScoreTolerance, 0.01)
            : configuration.ambiguityScoreTolerance
        let plausible = ranked.filter {
            rawBest.score - $0.score <= ambiguityTolerance
        }
        let best: Candidate
        if plausible.count == 1 {
            best = rawBest
        } else if let denselyValidated = resolveWithDenseEvidence(plausible) {
            best = denselyValidated
        } else if let independentlyValidated = resolveWithIndependentAlignment(
            plausible,
            hint: alignmentHint
        ) {
            best = independentlyValidated
        } else if let locallyResolved = resolveSubpixelNeighbors(
            plausible,
            expectedScrollRows: expectedScrollRows,
            temporalContext: temporalContext,
            alignmentHint: alignmentHint
        ) {
            best = locallyResolved
        } else {
            return .ambiguous(candidateCount: plausible.count)
        }
        let contentRows = best.scrollRows + best.overlapRows
        let overlapRatio = Double(best.overlapRows) / Double(max(1, contentRows))
        if overlapRatio < configuration.minimumOverlapRatio,
           !hasTrustedLowOverlapAlignment(best, hint: alignmentHint) {
            return .none
        }
        return .match(best)
    }

    private func resolveWithDenseEvidence(_ candidates: [Candidate]) -> Candidate? {
        let ranked = candidates
            .filter { $0.denseDifference.isFinite }
            .sorted {
                if $0.denseDifference == $1.denseDifference { return $0.score > $1.score }
                return $0.denseDifference < $1.denseDifference
            }
        guard ranked.count >= 2 else { return ranked.first }
        let best = ranked[0]
        let runnerUp = ranked[1]
        let requiredSeparation = max(0.002, best.denseDifference * 0.20)
        guard runnerUp.denseDifference - best.denseDifference >= requiredSeparation,
              runnerUp.denseDifference >= best.denseDifference * 1.5 else {
            return nil
        }
        return best
    }

    private func hasTrustedLowOverlapAlignment(
        _ candidate: Candidate,
        hint: ScrollingFrameAlignmentHint?
    ) -> Bool {
        guard let hint,
              hint.sampledRegions == 3,
              hint.agreeingRegions == 3,
              hint.confidence >= 0.9,
              hint.horizontalShift == 0,
              candidate.horizontalShift == 0,
              hint.scrollRows > 0 else { return false }
        let tolerance = max(8, hint.scrollRows / 8)
        return abs(candidate.scrollRows - hint.scrollRows) <= tolerance
    }

    private func resolveSubpixelNeighbors(
        _ candidates: [Candidate],
        expectedScrollRows: Int?,
        temporalContext: ScrollingFrameTemporalContext?,
        alignmentHint: ScrollingFrameAlignmentHint?
    ) -> Candidate? {
        guard let minimum = candidates.map(\.scrollRows).min(),
              let maximum = candidates.map(\.scrollRows).max(),
              maximum - minimum <= 2,
              candidates.contains(where: { abs($0.verticalSubpixelOffset) > 0.01 }) else { return nil }
        let preferredRows = alignmentHint?.hasConsensus == true
            ? alignmentHint?.scrollRows
            : temporalContext?.consensusScrollRows ?? expectedScrollRows
        guard let preferredRows else { return nil }
        let ranked = candidates.sorted {
            let lhs = abs($0.scrollRows - preferredRows)
            let rhs = abs($1.scrollRows - preferredRows)
            if lhs == rhs { return $0.score > $1.score }
            return lhs < rhs
        }
        guard let first = ranked.first else { return nil }
        if ranked.count > 1,
           abs(first.scrollRows - preferredRows) == abs(ranked[1].scrollRows - preferredRows) {
            return nil
        }
        return first
    }

    private func resolveWithIndependentAlignment(
        _ candidates: [Candidate],
        hint: ScrollingFrameAlignmentHint?
    ) -> Candidate? {
        guard let hint,
              hint.sampledRegions >= 3,
              hint.agreeingRegions == hint.sampledRegions,
              hint.confidence >= 0.9 else { return nil }
        let tolerance = max(6, hint.scrollRows / 10)
        let matching = candidates.filter { abs($0.scrollRows - hint.scrollRows) <= tolerance }
        guard let best = matching.min(by: {
            abs($0.scrollRows - hint.scrollRows) < abs($1.scrollRows - hint.scrollRows)
        }) else { return nil }
        let bestDistance = abs(best.scrollRows - hint.scrollRows)
        guard matching.filter({ abs($0.scrollRows - hint.scrollRows) == bestDistance }).count == 1 else {
            return nil
        }
        return best
    }
}
