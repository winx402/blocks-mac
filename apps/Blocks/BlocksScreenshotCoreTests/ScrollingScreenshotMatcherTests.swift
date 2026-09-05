import CoreGraphics
import ImageIO
import XCTest
@testable import BlocksScreenshotCore

final class ScrollingScreenshotMatcherTests: XCTestCase {
    func testFindsUniqueVerticalOverlapAndReturnsOnlyNewRows() throws {
        let previous = ScrollingScreenshotFixtures.frame("previous", rowIdentifiers: 0..<8)
        let incoming = ScrollingScreenshotFixtures.frame("incoming", rowIdentifiers: 5..<13)

        let decision = ScrollingScreenshotFixtures.exactMatcher.decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        )

        guard case let .append(match) = decision else {
            return XCTFail("Expected append, got \(decision)")
        }
        XCTAssertEqual(match.overlapRows, 3)
        XCTAssertEqual(match.fixedHeaderRows, 0)
        XCTAssertEqual(match.incomingSourceRows, 3..<8)
        XCTAssertEqual(match.confidence, 1)
    }

    func testRepeatedTextureWithTwoPlausibleOffsetsIsAmbiguous() {
        let matcher = ScrollingScreenshotMatcher(configuration: .init(
            minimumOverlapRows: 2,
            minimumFixedHeaderRows: 2,
            maximumFixedHeaderRows: 3,
            coarseCandidateCount: 12,
            horizontalSearchRadius: 0,
            minimumBlockSimilarity: 0.99,
            minimumMatchScore: 0.95,
            minimumMatchedBlockRatio: 0.75,
            ambiguityScoreTolerance: 0
        ))
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            rowIdentifiers: [90, 91, 1, 2, 1, 2]
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            rowIdentifiers: [1, 2, 1, 2, 100, 101]
        )

        XCTAssertEqual(
            matcher.decide(previous: previous.descriptor, incoming: incoming.descriptor),
            .recover(.ambiguousOverlap(candidateCount: 2))
        )
    }

    func testTemporalConsensusCannotForceARepeatedTextureMatch() {
        let matcher = ScrollingScreenshotMatcher(configuration: .init(
            minimumOverlapRows: 2,
            minimumFixedHeaderRows: 2,
            maximumFixedHeaderRows: 3,
            coarseCandidateCount: 12,
            horizontalSearchRadius: 0,
            minimumBlockSimilarity: 0.99,
            minimumMatchScore: 0.95,
            minimumMatchedBlockRatio: 0.75,
            ambiguityScoreTolerance: 0
        ))
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            rowIdentifiers: [90, 91, 1, 2, 1, 2]
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            rowIdentifiers: [1, 2, 1, 2, 100, 101]
        )

        guard case .recover(.ambiguousOverlap) = matcher.decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            temporalContext: .init(recentAcceptedScrollRows: [2, 2, 3])
        ) else {
            return XCTFail("Temporal history must not turn a visually ambiguous overlap into an append.")
        }
    }

    func testLowTextureViewportUsesSparseTexturedRegionsAcrossScales() throws {
        let document = (0..<96).map { row -> [UInt8] in
            var pixels = [UInt8](repeating: 242, count: 64)
            if row.isMultiple(of: 5) {
                let start = 8 + (row * 7) % 44
                for column in start..<min(64, start + 5) {
                    pixels[column] = UInt8(35 + (row * 11 + column) % 90)
                }
            }
            if row.isMultiple(of: 13) {
                pixels[28] = 20
                pixels[29] = 225
            }
            return pixels
        }
        let previous = ScrollingScreenshotSyntheticFrame(id: "previous", rows: Array(document[0..<64]))
        let incoming = ScrollingScreenshotSyntheticFrame(id: "incoming", rows: Array(document[3..<67]))

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        )

        guard case let .append(match) = decision else {
            return XCTFail("Sparse informative regions should support a small-step match, got \(decision)")
        }
        XCTAssertEqual(match.incomingSourceRows.count, 3)
    }

    func testHalfPixelSmallStepUsesSubpixelRefinementWithoutInventingExtraRows() throws {
        let previous = subpixelViewport(id: "previous", start: 0)
        let incoming = subpixelViewport(id: "incoming", start: 2.5)

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            temporalContext: .init(recentAcceptedScrollRows: [2, 3, 2])
        )

        guard case let .append(match) = decision else {
            return XCTFail("A half-pixel small step should remain matchable, got \(decision)")
        }
        XCTAssertTrue((2...3).contains(match.incomingSourceRows.count))
        XCTAssertEqual(abs(match.verticalSubpixelOffset), 0.5, accuracy: 0.001)
    }

    func testChangedKnownHeaderAndFooterFallBackToUncroppedRematch() throws {
        let previous = ScrollingScreenshotSyntheticFrame(
            id: "previous",
            rows: ScrollingScreenshotFixtures.rows(10_000..<10_008, width: 48)
                + ScrollingScreenshotFixtures.rows(0..<124, width: 48)
                + ScrollingScreenshotFixtures.rows(20_000..<20_008, width: 48)
        )
        let incoming = ScrollingScreenshotSyntheticFrame(
            id: "incoming",
            rows: ScrollingScreenshotFixtures.rows(11_000..<11_008, width: 48)
                + ScrollingScreenshotFixtures.rows(24..<148, width: 48)
                + ScrollingScreenshotFixtures.rows(21_000..<21_008, width: 48)
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            knownFixedHeaderRows: 8,
            knownFixedFooterRows: 8,
            detectsStaticBands: false
        )

        guard case let .append(match) = decision else {
            return XCTFail("Changed known bands should be rematched without destructive insets, got \(decision).")
        }
        XCTAssertEqual(match.fixedHeaderRows, 0)
        XCTAssertEqual(match.fixedFooterRows, 0)
        XCTAssertEqual(match.incomingSourceRows.count, 24)
    }

    func testStableFixedHeaderIsRemovedOnlyAfterUniqueContentOverlap() throws {
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            headerIdentifiers: [200, 201],
            contentIdentifiers: 0..<8
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            headerIdentifiers: [200, 201],
            contentIdentifiers: 5..<13
        )

        let decision = ScrollingScreenshotFixtures.exactMatcher.decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        )

        guard case let .append(match) = decision else {
            return XCTFail("Expected append, got \(decision)")
        }
        XCTAssertEqual(match.fixedHeaderRows, 2)
        XCTAssertEqual(match.overlapRows, 3)
        XCTAssertEqual(match.incomingSourceRows, 5..<10)
    }

    func testStableHeaderAndFooterAreExcludedFromAppendedRows() throws {
        let previous = ScrollingScreenshotSyntheticFrame(
            id: "previous",
            rows: ScrollingScreenshotFixtures.rows([100, 101])
                + ScrollingScreenshotFixtures.rows(0..<8)
                + ScrollingScreenshotFixtures.rows([200, 201])
        )
        let incoming = ScrollingScreenshotSyntheticFrame(
            id: "incoming",
            rows: ScrollingScreenshotFixtures.rows([100, 101])
                + ScrollingScreenshotFixtures.rows(5..<13)
                + ScrollingScreenshotFixtures.rows([200, 201])
        )

        let decision = ScrollingScreenshotFixtures.exactMatcher.decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        )

        guard case let .append(match) = decision else {
            return XCTFail("Expected append, got \(decision)")
        }
        XCTAssertEqual(match.fixedHeaderRows, 2)
        XCTAssertEqual(match.fixedFooterRows, 2)
        XCTAssertEqual(match.overlapRows, 3)
        XCTAssertEqual(match.incomingSourceRows, 5..<10)
    }

    func testChangingHeaderIsNotConservativelyClassifiedAsFixed() {
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            headerIdentifiers: [200, 201],
            contentIdentifiers: 0..<8
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            headerIdentifiers: [200, 202],
            contentIdentifiers: 5..<13
        )

        XCTAssertEqual(
            ScrollingScreenshotFixtures.exactMatcher.decide(
                previous: previous.descriptor,
                incoming: incoming.descriptor
            ),
            .recover(.insufficientOverlap)
        )
    }

    func testChangingFooterIsRejectedInsteadOfBeingClassifiedAsFixed() {
        let previous = ScrollingScreenshotSyntheticFrame(
            id: "previous",
            rows: ScrollingScreenshotFixtures.rows(0..<8)
                + ScrollingScreenshotFixtures.rows([200, 201])
        )
        let incoming = ScrollingScreenshotSyntheticFrame(
            id: "incoming",
            rows: ScrollingScreenshotFixtures.rows(5..<13)
                + ScrollingScreenshotFixtures.rows([202, 203])
        )

        XCTAssertEqual(
            ScrollingScreenshotFixtures.exactMatcher.decide(
                previous: previous.descriptor,
                incoming: incoming.descriptor
            ),
            .recover(.insufficientOverlap)
        )
    }

    func testChangedKnownFooterUsesPreviousFooterAsReplaceableTail() throws {
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            rowIdentifiers: Array(18..<82) + Array(repeating: 200, count: 8),
            width: 64
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            rowIdentifiers: Array(36..<100) + Array(repeating: 500, count: 8),
            width: 64
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            expectedScrollRows: 18,
            temporalContext: .init(recentAcceptedScrollRows: [18]),
            knownFixedFooterRows: 8
        )

        guard case let .append(match) = decision else {
            return XCTFail("A changed fixed footer should expose its old rows for replacement, got \(decision).")
        }
        XCTAssertEqual(match.overlapRows, 46)
        XCTAssertEqual(match.fixedFooterRows, 0)
        XCTAssertEqual(match.incomingSourceRows, 46..<72)
    }

    func testIdenticalVisualFrameHasNoNewContentEvenWhenIDChanges() {
        let previous = ScrollingScreenshotFixtures.frame("previous", rowIdentifiers: 0..<8)
        let incoming = ScrollingScreenshotSyntheticFrame(id: "incoming", rows: previous.rows)

        XCTAssertEqual(
            ScrollingScreenshotFixtures.exactMatcher.decide(
                previous: previous.descriptor,
                incoming: incoming.descriptor
            ),
            .noNewContent
        )
    }

    func testLargeRepeatedBlankRegionIsRejectedInsteadOfGuessingAnOffset() {
        let matcher = ScrollingScreenshotMatcher(configuration: .init(
            minimumOverlapRows: 2,
            minimumFixedHeaderRows: 2,
            maximumFixedHeaderRows: 3,
            coarseCandidateCount: 12,
            horizontalSearchRadius: 0,
            minimumBlockSimilarity: 0.99,
            minimumMatchScore: 0.95,
            minimumMatchedBlockRatio: 0.75,
            ambiguityScoreTolerance: 0
        ))
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            rowIdentifiers: [1, 2, 0, 0, 0, 0]
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            rowIdentifiers: [0, 0, 0, 0, 3, 4]
        )

        guard case .recover(.ambiguousOverlap) = matcher.decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        ) else {
            return XCTFail("Repeated blank rows must pause rather than append at a guessed offset.")
        }
    }

    func testSparseDynamicRowsDoNotInvalidateAnOtherwiseUniqueOverlap() throws {
        let previous = ScrollingScreenshotFixtures.frame("previous", rowIdentifiers: 0..<64, width: 48)
        let sourceIncoming = ScrollingScreenshotFixtures.frame("incoming", rowIdentifiers: 32..<96, width: 48)
        var samples = sourceIncoming.descriptor.lumaSamples
        for row in [5, 14, 23] {
            let range = (row * sourceIncoming.descriptor.sampleWidth)..<((row + 1) * sourceIncoming.descriptor.sampleWidth)
            for index in range { samples[index] = 255 &- samples[index] }
        }
        let incoming = ScrollingFrameDescriptor(
            id: "incoming-with-dynamic-rows",
            pixelSize: sourceIncoming.descriptor.pixelSize,
            sampleWidth: sourceIncoming.descriptor.sampleWidth,
            lumaSamples: samples
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming
        )

        guard case let .append(match) = decision else {
            return XCTFail("Sparse dynamic rows should not reject the full overlap, got \(decision)")
        }
        XCTAssertEqual(match.overlapRows, 32)
        XCTAssertEqual(match.incomingSourceRows, 32..<64)
    }

    func testWidespreadDynamicRowsRemainFailClosed() {
        let previous = ScrollingScreenshotFixtures.frame("previous", rowIdentifiers: 0..<64, width: 48)
        let sourceIncoming = ScrollingScreenshotFixtures.frame("incoming", rowIdentifiers: 32..<96, width: 48)
        var samples = sourceIncoming.descriptor.lumaSamples
        for row in stride(from: 1, to: 32, by: 3) {
            let range = (row * sourceIncoming.descriptor.sampleWidth)..<((row + 1) * sourceIncoming.descriptor.sampleWidth)
            for index in range { samples[index] = 255 &- samples[index] }
        }
        let incoming = ScrollingFrameDescriptor(
            id: "incoming-with-widespread-changes",
            pixelSize: sourceIncoming.descriptor.pixelSize,
            sampleWidth: sourceIncoming.descriptor.sampleWidth,
            lumaSamples: samples
        )

        guard case .recover = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming
        ) else {
            return XCTFail("Widespread changes must not be stitched speculatively.")
        }
    }

    func testTwoDimensionalConsensusIgnoresFixedSidebarAndLocalAnimation() throws {
        let previous = ScrollingScreenshotFixtures.viewport(
            "previous",
            documentStart: 0,
            dynamicRect: (38..<46, 18..<28)
        )
        let incoming = ScrollingScreenshotFixtures.viewport(
            "incoming",
            documentStart: 18,
            dynamicRect: (28..<36, 42..<52)
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        )

        guard case let .append(match) = decision else {
            return XCTFail("Expected local changes and a fixed sidebar to be tolerated, got \(decision)")
        }
        XCTAssertEqual(match.fixedHeaderRows, 8)
        XCTAssertEqual(match.incomingSourceRows.count, 18)
    }

    func testExpectedScrollPriorDisambiguatesRepeatedDocumentRows() throws {
        let repeatingRows = (0..<96).map { row in
            (0..<32).map { column in UInt8((row % 12) * 17 + column % 7) }
        }
        let previous = ScrollingScreenshotSyntheticFrame(
            id: "previous",
            rows: Array(repeatingRows[0..<64])
        )
        let incoming = ScrollingScreenshotSyntheticFrame(
            id: "incoming",
            rows: Array(repeatingRows[18..<82])
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            expectedScrollRows: 18
        )

        guard case .recover(.ambiguousOverlap) = decision else {
            return XCTFail("An expected distance must not force a visually ambiguous overlap, got \(decision)")
        }
    }

    func testUnanimousMultiRegionAlignmentValidatesOneRepeatedDocumentCandidate() throws {
        let repeatingRows = (0..<96).map { row in
            (0..<32).map { column in UInt8((row % 12) * 17 + column % 7) }
        }
        let previous = ScrollingScreenshotSyntheticFrame(
            id: "previous",
            rows: Array(repeatingRows[0..<64])
        )
        let incoming = ScrollingScreenshotSyntheticFrame(
            id: "incoming",
            rows: Array(repeatingRows[18..<82])
        )
        let hint = ScrollingFrameAlignmentHint(
            scrollRows: 18,
            horizontalShift: 0,
            agreeingRegions: 3,
            sampledRegions: 3,
            confidence: 0.96
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            alignmentHint: hint
        )

        guard case let .append(match) = decision else {
            return XCTFail("Unanimous independent alignment should validate one visual candidate, got \(decision)")
        }
        XCTAssertEqual(match.incomingSourceRows.count, 18)
    }

    func testLargeViewportMatcherStaysWithinInteractiveBudget() throws {
        let previous = ScrollingScreenshotFixtures.viewport(
            "previous",
            documentStart: 0,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14
        )
        let incoming = ScrollingScreenshotFixtures.viewport(
            "incoming",
            documentStart: 220,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14,
            dynamicRect: (78..<92, 340..<390)
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        guard case let .append(match) = decision else {
            return XCTFail("Expected a large viewport match, got \(decision)")
        }
        XCTAssertEqual(match.incomingSourceRows.count, 220)
        XCTAssertLessThan(elapsed, 0.5, "Matching must remain below the interactive capture budget.")
    }

    func testBrowserRenderedDescriptorsMatchWithinInteractiveBudget() throws {
        let previous = try browserFixtureDescriptor("0000")
        let incoming = try browserFixtureDescriptor("0320")
        let startedAt = CFAbsoluteTimeGetCurrent()

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous,
            incoming: incoming
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        guard case let .append(match) = decision else {
            return XCTFail("Expected browser fixture append, got \(decision)")
        }
        XCTAssertEqual(match.fixedHeaderRows, 72)
        XCTAssertEqual(match.fixedFooterRows, 0, "The changing tick badge must not be locked as a fixed footer.")
        XCTAssertEqual(match.incomingSourceRows.count, 320)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testBrowserRenderedPageDownFrameUsesTheReal310PointDelta() throws {
        let previous = try browserFixtureDescriptor(named: "page-down-00.png")
        let incoming = try browserFixtureDescriptor(named: "page-down-01.png")

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous,
            incoming: incoming
        )
        guard case let .append(match) = decision else {
            return XCTFail("A 310 point Page Down step with 318 content rows of overlap must be safe, got \(decision).")
        }
        XCTAssertEqual(match.fixedHeaderRows, 72)
        XCTAssertEqual(match.fixedFooterRows, 0)
        XCTAssertEqual(match.incomingSourceRows.count, 310)
    }

    func testEveryBrowserRenderedPageDownPairUsesTheActualBrowserDelta() throws {
        let positions = [0, 310, 620, 930, 1_240, 1_550, 1_860, 2_170, 2_480, 2_736, 2_992, 2_992]
        let descriptors = try positions.indices.map {
            try browserFixtureDescriptor(named: String(format: "page-down-%02d.png", $0))
        }
        let matcher = ScrollingScreenshotMatcher()

        for index in 1..<descriptors.count {
            let decision = matcher.decide(
                previous: descriptors[index - 1],
                incoming: descriptors[index]
            )
            let expectedDelta = positions[index] - positions[index - 1]
            if expectedDelta == 0 {
                XCTAssertEqual(decision, .noNewContent, "Pair \(index - 1) -> \(index) must be unchanged.")
            } else if case let .append(match) = decision {
                XCTAssertEqual(
                    match.incomingSourceRows.count,
                    expectedDelta,
                    "Pair \(index - 1) -> \(index) used the wrong browser delta."
                )
            } else {
                XCTFail("Pair \(index - 1) -> \(index) must append \(expectedDelta) rows, got \(decision).")
            }
        }
    }

    func testBrowserRenderedSequenceKeepsAppendingAcrossChangingFooterBadge() throws {
        let frames = try ["0000", "0320", "0640", "0960"].map { try browserFixtureDescriptor($0) }
        var state = ScrollingScreenshotSessionState()
        let assembler = ScrollingScreenshotAssembler()

        for (index, frame) in frames.enumerated() {
            let decision = assembler.decide(
                state: state,
                incoming: frame,
                alignmentHint: index == 0 ? nil : ScrollingFrameAlignmentHint(
                    scrollRows: 320,
                    horizontalShift: 0,
                    agreeingRegions: 3,
                    sampledRegions: 3,
                    confidence: 0.96
                )
            )
            switch (index, decision.stitchDecision) {
            case (0, .seed):
                break
            case (_, let .append(match)):
                XCTAssertEqual(match.fixedHeaderRows, 72)
                XCTAssertEqual(match.fixedFooterRows, 0)
                XCTAssertEqual(match.incomingSourceRows.count, 320)
            default:
                XCTFail("Browser frame \(index) must append, got \(decision.stitchDecision)")
            }
            state = decision.nextState
        }

        XCTAssertEqual(state.outputSize, ScreenshotPixelSize(width: 900, height: 1_660))
        XCTAssertTrue(state.hasConfirmedFixedHeader)
        XCTAssertFalse(state.hasConfirmedFixedFooter)
    }

    func testPageDownSizedJumpWithUnsafeOverlapIsRejectedInsteadOfSkippingContent() {
        let previous = ScrollingScreenshotFixtures.viewport(
            "previous",
            documentStart: 0,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14
        )
        let incoming = ScrollingScreenshotFixtures.viewport(
            "incoming",
            documentStart: 1_150,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14
        )

        guard case .recover = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor
        ) else {
            return XCTFail("A frame with only a narrow overlap must pause instead of silently skipping document rows.")
        }
    }

    func testPageDownSizedJumpCanUseIndependentMultiRegionAlignmentEvidence() throws {
        let previous = ScrollingScreenshotFixtures.viewport(
            "previous",
            documentStart: 0,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14
        )
        let incoming = ScrollingScreenshotFixtures.viewport(
            "incoming",
            documentStart: 1_150,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14
        )

        let decision = ScrollingScreenshotMatcher().decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            alignmentHint: ScrollingFrameAlignmentHint(
                scrollRows: 1_150,
                horizontalShift: 0,
                agreeingRegions: 3,
                sampledRegions: 3,
                confidence: 0.95
            )
        )

        guard case let .append(match) = decision else {
            return XCTFail("Independent multi-region evidence should admit a valid low-overlap Page Down frame, got \(decision)")
        }
        XCTAssertEqual(match.incomingSourceRows.count, 1_150)
    }

    func testLowOverlapHintWithOneFailedRegionIsRejected() {
        let frames = lowOverlapViewportPair()

        guard case .recover = ScrollingScreenshotMatcher().decide(
            previous: frames.previous.descriptor,
            incoming: frames.incoming.descriptor,
            alignmentHint: ScrollingFrameAlignmentHint(
                scrollRows: 1_150,
                horizontalShift: 0,
                agreeingRegions: 2,
                sampledRegions: 2,
                confidence: 0.99
            )
        ) else {
            return XCTFail("A low-overlap bypass requires all three independent regions to succeed.")
        }
    }

    func testLowOverlapHintWithHorizontalDriftIsRejected() {
        let frames = lowOverlapViewportPair()

        guard case .recover = ScrollingScreenshotMatcher().decide(
            previous: frames.previous.descriptor,
            incoming: frames.incoming.descriptor,
            alignmentHint: ScrollingFrameAlignmentHint(
                scrollRows: 1_150,
                horizontalShift: 1,
                agreeingRegions: 3,
                sampledRegions: 3,
                confidence: 0.99
            )
        ) else {
            return XCTFail("A low-overlap bypass must reject horizontal drift.")
        }
    }

    func testLowOverlapUnanimousLowConfidenceHintIsRejected() {
        let frames = lowOverlapViewportPair()

        guard case .recover = ScrollingScreenshotMatcher().decide(
            previous: frames.previous.descriptor,
            incoming: frames.incoming.descriptor,
            alignmentHint: ScrollingFrameAlignmentHint(
                scrollRows: 1_150,
                horizontalShift: 0,
                agreeingRegions: 3,
                sampledRegions: 3,
                confidence: 0.89
            )
        ) else {
            return XCTFail("A low-overlap bypass requires high-confidence three-region evidence.")
        }
    }

    func testLowOverlapRepeatedBodyRejectsTwoRegionConsensus() {
        let matcher = ScrollingScreenshotMatcher(configuration: .init(
            maximumFixedHeaderRows: 0,
            maximumFixedFooterRows: 0
        ))
        let identifiers = (0..<216).map { row in
            row % 8 == 3 ? 10_000 + row : row % 6
        }
        let previous = ScrollingScreenshotFixtures.frame(
            "previous",
            rowIdentifiers: identifiers[0..<120],
            width: 48
        )
        let incoming = ScrollingScreenshotFixtures.frame(
            "incoming",
            rowIdentifiers: identifiers[96..<216],
            width: 48
        )

        let decision = matcher.decide(
            previous: previous.descriptor,
            incoming: incoming.descriptor,
            alignmentHint: ScrollingFrameAlignmentHint(
                scrollRows: 96,
                horizontalShift: 0,
                agreeingRegions: 2,
                sampledRegions: 3,
                confidence: 0.95
            )
        )
        guard case .recover = decision else {
            return XCTFail("Repeated low-overlap content must not use a two-region majority bypass: \(decision).")
        }
    }

    func testStationaryViewportWithLocalizedAnimationDoesNotAppendDuplicateRows() {
        let previous = ScrollingScreenshotFixtures.viewport(
            "previous",
            documentStart: 2_400,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14,
            dynamicRect: (78..<92, 1_300..<1_350)
        )
        let incoming = ScrollingScreenshotFixtures.viewport(
            "incoming",
            documentStart: 2_400,
            height: 1_400,
            width: 96,
            fixedHeaderRows: 72,
            fixedSidebarColumns: 14,
            dynamicRect: (78..<92, 1_315..<1_365)
        )

        XCTAssertEqual(
            ScrollingScreenshotMatcher().decide(
                previous: previous.descriptor,
                incoming: incoming.descriptor
            ),
            .noNewContent,
            "A changing badge over a stationary page must not duplicate the bottom viewport."
        )
    }
}

private extension ScrollingScreenshotMatcherTests {
    func lowOverlapViewportPair() -> (
        previous: ScrollingScreenshotSyntheticFrame,
        incoming: ScrollingScreenshotSyntheticFrame
    ) {
        (
            ScrollingScreenshotFixtures.viewport(
                "previous",
                documentStart: 0,
                height: 1_400,
                width: 96,
                fixedHeaderRows: 72,
                fixedSidebarColumns: 14
            ),
            ScrollingScreenshotFixtures.viewport(
                "incoming",
                documentStart: 1_150,
                height: 1_400,
                width: 96,
                fixedHeaderRows: 72,
                fixedSidebarColumns: 14
            )
        )
    }

    func subpixelViewport(
        id: String,
        start: Double,
        height: Int = 64,
        width: Int = 64
    ) -> ScrollingScreenshotSyntheticFrame {
        let rows = (0..<height).map { row in
            (0..<width).map { column -> UInt8 in
                let documentY = start + Double(row)
                let wave = sin(documentY * 0.13 + Double(column) * 0.17) * 42
                let fine = cos(documentY * 0.23 - Double(column) * 0.11) * 24
                return UInt8(clamping: Int((170 + wave + fine).rounded()))
            }
        }
        return ScrollingScreenshotSyntheticFrame(id: id, rows: rows)
    }

    func browserFixtureDescriptor(_ suffix: String) throws -> ScrollingFrameDescriptor {
        try browserFixtureDescriptor(named: "frame-\(suffix).png")
    }

    func browserFixtureDescriptor(named fileName: String) throws -> ScrollingFrameDescriptor {
        let file = URL(fileURLWithPath: fileName)
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(
                forResource: file.deletingPathExtension().lastPathComponent,
                withExtension: file.pathExtension,
                subdirectory: "Fixtures/Scrolling"
            )
        )
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ScrollingScreenshotMatcherTests", code: 1)
        }
        let sampleWidth = min(192, image.width)
        var pixels = [UInt8](repeating: 0, count: sampleWidth * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: image.height))
        }
        return ScrollingFrameDescriptor(
            id: fileName,
            pixelSize: ScreenshotPixelSize(width: image.width, height: image.height),
            sampleWidth: sampleWidth,
            lumaSamples: pixels
        )
    }
}
