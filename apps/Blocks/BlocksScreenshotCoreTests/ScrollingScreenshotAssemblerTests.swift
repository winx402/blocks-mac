import XCTest
@testable import BlocksScreenshotCore

final class ScrollingScreenshotAssemblerTests: XCTestCase {
    func testVerticalFramesAssembleToIndependentGroundTruth() throws {
        let frames = [
            ScrollingScreenshotFixtures.frame("frame-0", rowIdentifiers: 0..<8),
            ScrollingScreenshotFixtures.frame("frame-1", rowIdentifiers: 5..<13),
            ScrollingScreenshotFixtures.frame("frame-2", rowIdentifiers: 10..<18),
        ]
        let result = try assemble(frames, with: ScrollingScreenshotFixtures.exactAssembler)

        XCTAssertEqual(result.rows, ScrollingScreenshotFixtures.rows(0..<18))
        XCTAssertEqual(result.state.outputSize, .init(width: 8, height: 18))
        XCTAssertEqual(result.state.observedFrameCount, 3)
        XCTAssertEqual(result.state.acceptedFrameCount, 3)
        XCTAssertEqual(result.state.phase, .capturing)
    }

    func testFixedHeaderIsWrittenOnceAndContentMatchesGroundTruth() throws {
        let frames = [
            ScrollingScreenshotFixtures.frame(
                "frame-0",
                headerIdentifiers: [200, 201],
                contentIdentifiers: 0..<8
            ),
            ScrollingScreenshotFixtures.frame(
                "frame-1",
                headerIdentifiers: [200, 201],
                contentIdentifiers: 5..<13
            ),
        ]
        let result = try assemble(frames, with: ScrollingScreenshotFixtures.exactAssembler)
        let expected = ScrollingScreenshotFixtures.rows([200, 201])
            + ScrollingScreenshotFixtures.rows(0..<13)

        XCTAssertEqual(result.rows, expected)
        XCTAssertEqual(result.state.fixedHeaderRows, 2)
        XCTAssertEqual(result.state.outputSize.height, expected.count)
    }

    func testFixedFooterReservesItsFinalPositionBeforeWritingNewRows() throws {
        let first = ScrollingScreenshotSyntheticFrame(
            id: "frame-0",
            rows: ScrollingScreenshotFixtures.rows([100, 101])
                + ScrollingScreenshotFixtures.rows(0..<8)
                + ScrollingScreenshotFixtures.rows([200, 201])
        )
        let second = ScrollingScreenshotSyntheticFrame(
            id: "frame-1",
            rows: ScrollingScreenshotFixtures.rows([100, 101])
                + ScrollingScreenshotFixtures.rows(5..<13)
                + ScrollingScreenshotFixtures.rows([200, 201])
        )
        let assembler = ScrollingScreenshotFixtures.exactAssembler
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)

        let appended = assembler.decide(state: seeded.nextState, incoming: second.descriptor)

        guard case let .write(operation) = appended.operation else {
            return XCTFail("Expected fixed-footer content to append.")
        }
        XCTAssertEqual(operation.sourceRows, 5..<10)
        XCTAssertEqual(operation.destinationY, 10)
        XCTAssertEqual(appended.nextState.fixedHeaderRows, 2)
        XCTAssertEqual(appended.nextState.fixedFooterRows, 2)
        XCTAssertEqual(appended.nextState.outputSize.height, 17)
    }

    func testChangedFixedFooterIsReplacedWithoutLeavingASeam() throws {
        let assembler = ScrollingScreenshotAssembler()
        let frames = [
            ScrollingScreenshotFixtures.frame(
                "frame-0",
                rowIdentifiers: Array(0..<64) + Array(repeating: 200, count: 8),
                width: 64
            ),
            ScrollingScreenshotFixtures.frame(
                "frame-1",
                rowIdentifiers: Array(18..<82) + Array(repeating: 200, count: 8),
                width: 64
            ),
            ScrollingScreenshotFixtures.frame(
                "frame-2",
                rowIdentifiers: Array(36..<100) + Array(repeating: 500, count: 8),
                width: 64
            ),
        ]
        let first = assembler.decide(state: .init(), incoming: frames[0].descriptor)
        let second = assembler.decide(state: first.nextState, incoming: frames[1].descriptor)

        let third = assembler.decide(state: second.nextState, incoming: frames[2].descriptor)

        guard case let .write(operation) = third.operation else {
            return XCTFail("Expected the changed footer frame to replace the deferred tail.")
        }
        XCTAssertEqual(operation.sourceRows, 46..<72)
        XCTAssertEqual(operation.destinationY, 82)
        XCTAssertEqual(third.nextState.outputSize.height, 108)
        XCTAssertEqual(third.nextState.fixedFooterRows, 0)
    }

    func testStickyHeaderChangingOnThirdFrameFallsBackWithoutDeletingBody() throws {
        let assembler = ScrollingScreenshotAssembler()
        let first = ScrollingScreenshotFixtures.viewport("frame-0", documentStart: 0)
        let second = ScrollingScreenshotFixtures.viewport("frame-1", documentStart: 18)
        let stableThird = ScrollingScreenshotFixtures.viewport("frame-2", documentStart: 36)
        let dynamicThird = ScrollingScreenshotSyntheticFrame(
            id: stableThird.id,
            rows: stableThird.rows.enumerated().map { row, pixels in
                row < 8 ? pixels.map { $0 &+ 73 } : pixels
            }
        )
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)
        let candidate = assembler.decide(state: seeded.nextState, incoming: second.descriptor)

        XCTAssertEqual(candidate.nextState.fixedHeaderObservationCount, 1)

        let rematched = assembler.decide(state: candidate.nextState, incoming: dynamicThird.descriptor)
        guard case let .append(match) = rematched.stitchDecision,
              case let .write(operation) = rematched.operation else {
            return XCTFail("A one-pair sticky-header guess must not become a hard inset: \(rematched.stitchDecision).")
        }
        XCTAssertEqual(match.fixedHeaderRows, 0)
        XCTAssertEqual(operation.sourceRows.count, 18)
        XCTAssertEqual(rematched.nextState.outputSize.height, 108)
        XCTAssertEqual(rematched.nextState.fixedHeaderRows, 0)
        XCTAssertEqual(rematched.nextState.fixedHeaderObservationCount, 0)
    }

    func testStableBandsBecomeReusableOnlyAfterTwoConsistentTransitions() {
        let assembler = ScrollingScreenshotFixtures.exactAssembler
        let frames = [0, 5, 10].enumerated().map { index, start in
            ScrollingScreenshotSyntheticFrame(
                id: "stable-\(index)",
                rows: ScrollingScreenshotFixtures.rows([100, 101])
                    + ScrollingScreenshotFixtures.rows(start..<(start + 8))
                    + ScrollingScreenshotFixtures.rows([200, 201])
            )
        }
        var state = ScrollingScreenshotSessionState()
        for frame in frames {
            state = assembler.decide(state: state, incoming: frame.descriptor).nextState
        }

        XCTAssertEqual(state.fixedHeaderObservationCount, 2)
        XCTAssertEqual(state.fixedFooterObservationCount, 2)
        XCTAssertTrue(state.hasConfirmedFixedHeader)
        XCTAssertTrue(state.hasConfirmedFixedFooter)
    }

    func testNoNewContentDoesNotWriteOrGrowOutput() {
        let assembler = ScrollingScreenshotFixtures.exactAssembler
        let first = ScrollingScreenshotFixtures.frame("frame-0", rowIdentifiers: 0..<8)
        let duplicate = ScrollingScreenshotSyntheticFrame(id: "frame-1", rows: first.rows)
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)

        let decision = assembler.decide(state: seeded.nextState, incoming: duplicate.descriptor)

        XCTAssertEqual(decision.stitchDecision, .noNewContent)
        XCTAssertEqual(decision.operation, .none)
        XCTAssertEqual(decision.nextState.outputSize, seeded.nextState.outputSize)
        XCTAssertEqual(decision.nextState.acceptedFrameCount, 1)
        XCTAssertEqual(decision.nextState.observedFrameCount, 2)
    }

    func testDelayedLazyContentAfterUnchangedFrameContinuesFromLastAcceptedAnchor() throws {
        let assembler = ScrollingScreenshotFixtures.exactAssembler
        let first = ScrollingScreenshotFixtures.frame("frame-0", rowIdentifiers: 0..<8)
        let unchanged = ScrollingScreenshotSyntheticFrame(id: "frame-1", rows: first.rows)
        let loaded = ScrollingScreenshotFixtures.frame("frame-2", rowIdentifiers: 5..<13)
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)
        let waiting = assembler.decide(state: seeded.nextState, incoming: unchanged.descriptor)

        let resumed = assembler.decide(state: waiting.nextState, incoming: loaded.descriptor)

        guard case let .write(operation) = resumed.operation else {
            return XCTFail("Expected delayed content to append from the last accepted frame.")
        }
        XCTAssertEqual(operation.sourceRows, 3..<8)
        XCTAssertEqual(resumed.nextState.outputSize.height, 13)
        XCTAssertEqual(resumed.nextState.acceptedFrameCount, 2)
        XCTAssertEqual(resumed.nextState.observedFrameCount, 3)
    }

    func testReverseFrameIsRejectedAndNextForwardFrameRecoversFromLastAcceptedFrame() throws {
        let assembler = ScrollingScreenshotFixtures.exactAssembler
        let first = ScrollingScreenshotFixtures.frame("frame-0", rowIdentifiers: 5..<13)
        let reverse = ScrollingScreenshotFixtures.frame("reverse", rowIdentifiers: 0..<8)
        let recovered = ScrollingScreenshotFixtures.frame("recovered", rowIdentifiers: 10..<18)
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)

        let rejected = assembler.decide(state: seeded.nextState, incoming: reverse.descriptor)
        XCTAssertEqual(rejected.stitchDecision, .recover(.reverseScroll(overlapRows: 3)))
        XCTAssertEqual(rejected.operation, .none)
        XCTAssertEqual(rejected.nextState.lastAcceptedFrame, first.descriptor)
        XCTAssertEqual(rejected.nextState.consecutiveRejectedFrameCount, 1)

        let accepted = assembler.decide(state: rejected.nextState, incoming: recovered.descriptor)
        guard case let .write(operation) = accepted.operation else {
            return XCTFail("Expected recovery write")
        }
        XCTAssertEqual(operation.sourceRows, 3..<8)
        XCTAssertEqual(accepted.nextState.phase, .capturing)
        XCTAssertEqual(accepted.nextState.consecutiveRejectedFrameCount, 0)

        let assembled = first.rows + recovered.rows[operation.sourceRows]
        XCTAssertEqual(Array(assembled), ScrollingScreenshotFixtures.rows(5..<18))
    }

    func testTooFastFrameIsRejectedAndLaterOverlappingFrameRecovers() throws {
        let assembler = ScrollingScreenshotFixtures.exactAssembler
        let first = ScrollingScreenshotFixtures.frame("frame-0", rowIdentifiers: 0..<8)
        let tooFast = ScrollingScreenshotFixtures.frame("too-fast", rowIdentifiers: 20..<28)
        let recovered = ScrollingScreenshotFixtures.frame("recovered", rowIdentifiers: 5..<13)
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)

        let rejected = assembler.decide(state: seeded.nextState, incoming: tooFast.descriptor)
        XCTAssertEqual(rejected.stitchDecision, .recover(.insufficientOverlap))
        XCTAssertEqual(rejected.nextState.lastAcceptedFrame, first.descriptor)

        let accepted = assembler.decide(state: rejected.nextState, incoming: recovered.descriptor)
        guard case let .write(operation) = accepted.operation else {
            return XCTFail("Expected recovery write")
        }
        let assembled = first.rows + recovered.rows[operation.sourceRows]

        XCTAssertEqual(Array(assembled), ScrollingScreenshotFixtures.rows(0..<13))
        XCTAssertEqual(accepted.nextState.acceptedFrameCount, 2)
        XCTAssertEqual(accepted.nextState.observedFrameCount, 3)
    }

    func testVariableScrollDeltasAppendEveryBridgeWithoutAssumingConstantSpeed() throws {
        let starts = [0, 11, 29, 47, 66]
        let frames = starts.enumerated().map { index, start in
            ScrollingScreenshotFixtures.viewport(
                "variable-\(index)",
                documentStart: start,
                height: 72,
                width: 48,
                fixedHeaderRows: 8,
                fixedSidebarColumns: 8
            )
        }
        let assembler = ScrollingScreenshotAssembler()
        var state = ScrollingScreenshotSessionState()
        var appendedRows: [Int] = []

        for (index, frame) in frames.enumerated() {
            let decision = assembler.decide(state: state, incoming: frame.descriptor)
            if index == 0 {
                XCTAssertEqual(decision.stitchDecision, .seed)
            } else if case let .write(operation) = decision.operation {
                appendedRows.append(operation.sourceRows.count)
            } else {
                XCTFail("Variable bridge \(index) did not append: \(decision.stitchDecision)")
            }
            state = decision.nextState
        }

        XCTAssertEqual(appendedRows, [11, 18, 18, 19])
        XCTAssertEqual(state.outputSize.height, 72 + 66)
        XCTAssertEqual(state.acceptedFrameCount, frames.count)
    }

    func testSizeLimitStopsBeforeWritingAndPreservesPartialResult() {
        let assembler = ScrollingScreenshotAssembler(
            matcher: ScrollingScreenshotFixtures.exactMatcher,
            sizePolicy: .init(maximumDimension: 10, maximumPixelCount: 1_000)
        )
        let first = ScrollingScreenshotFixtures.frame("frame-0", rowIdentifiers: 0..<8)
        let incoming = ScrollingScreenshotFixtures.frame("frame-1", rowIdentifiers: 5..<13)
        let seeded = assembler.decide(state: .init(), incoming: first.descriptor)

        let stopped = assembler.decide(state: seeded.nextState, incoming: incoming.descriptor)

        guard case let .stop(.sizeLimitExceeded(assessment)) = stopped.stitchDecision else {
            return XCTFail("Expected size-limit stop")
        }
        XCTAssertEqual(assessment.status, .exceedsLimit)
        XCTAssertEqual(assessment.size.height, 13)
        XCTAssertEqual(stopped.operation, .none)
        XCTAssertEqual(stopped.nextState.outputSize.height, 8)
        XCTAssertEqual(stopped.nextState.lastAcceptedFrame, first.descriptor)
    }

    private func assemble(
        _ frames: [ScrollingScreenshotSyntheticFrame],
        with assembler: ScrollingScreenshotAssembler
    ) throws -> (rows: [[UInt8]], state: ScrollingScreenshotSessionState) {
        var state = ScrollingScreenshotSessionState()
        var rows: [[UInt8]] = []

        for frame in frames {
            let decision = assembler.decide(state: state, incoming: frame.descriptor)
            if case let .write(operation) = decision.operation {
                XCTAssertEqual(operation.frameID, frame.id)
                XCTAssertEqual(operation.destinationY, rows.count)
                rows.append(contentsOf: frame.rows[operation.sourceRows])
            }
            state = decision.nextState
        }
        return (rows, state)
    }
}
