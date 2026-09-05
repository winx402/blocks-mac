import XCTest
@testable import BlocksScreenshotCore

final class ScrollingScreenshotSizePolicyTests: XCTestCase {
    func testStandardPolicyUsesConservativeEffectiveLimitsBelowProductCeilings() {
        let policy = ScrollingScreenshotSizePolicy.standard

        XCTAssertEqual(policy.maximumDimension, 16_384)
        XCTAssertEqual(policy.maximumPixelCount, 64_000_000)
        XCTAssertEqual(ScrollingScreenshotSizePolicy.absoluteMaximumDimension, 32_768)
        XCTAssertEqual(ScrollingScreenshotSizePolicy.absoluteMaximumPixelCount, 120_000_000)
    }

    func testEffectiveMaximumDimensionAllows16384AndRejects16385() {
        let policy = ScrollingScreenshotSizePolicy.standard

        let boundary = policy.assess(.init(width: 16_384, height: 1))
        let exceeded = policy.assess(.init(width: 16_385, height: 1))

        XCTAssertEqual(boundary.status, .warning)
        XCTAssertEqual(boundary.exceededLimits, [])
        XCTAssertEqual(boundary.approachingLimits, [.maximumDimension])
        XCTAssertEqual(exceeded.status, .exceedsLimit)
        XCTAssertEqual(exceeded.exceededLimits, [.maximumDimension])
    }

    func testEffectiveMaximumPixelCountAllows64MPAndRejectsAnythingAboveIt() {
        let policy = ScrollingScreenshotSizePolicy.standard

        let boundary = policy.assess(.init(width: 8_000, height: 8_000))
        let exceeded = policy.assess(.init(width: 8_000, height: 8_001))

        XCTAssertEqual(boundary.pixelCount, 64_000_000)
        XCTAssertEqual(boundary.status, .warning)
        XCTAssertEqual(boundary.exceededLimits, [])
        XCTAssertEqual(boundary.approachingLimits, [.maximumPixelCount])
        XCTAssertEqual(exceeded.status, .exceedsLimit)
        XCTAssertEqual(exceeded.exceededLimits, [.maximumPixelCount])
    }

    func testWarningStartsAtNinetyPercentOfPixelLimit() {
        let policy = ScrollingScreenshotSizePolicy.standard

        let below = policy.assess(.init(width: 8_000, height: 7_199))
        let threshold = policy.assess(.init(width: 8_000, height: 7_200))

        XCTAssertEqual(below.pixelCount, 57_592_000)
        XCTAssertEqual(below.status, .safe)
        XCTAssertEqual(threshold.pixelCount, 57_600_000)
        XCTAssertEqual(threshold.status, .warning)
        XCTAssertEqual(threshold.approachingLimits, [.maximumPixelCount])
    }

    func testWarningStartsWhenEitherDimensionReachesNinetyPercent() {
        let policy = ScrollingScreenshotSizePolicy(
            maximumDimension: 100,
            maximumPixelCount: 100_000,
            warningFraction: 0.9
        )

        XCTAssertEqual(policy.assess(.init(width: 89, height: 20)).status, .safe)
        let threshold = policy.assess(.init(width: 90, height: 20))

        XCTAssertEqual(threshold.status, .warning)
        XCTAssertEqual(threshold.approachingLimits, [.maximumDimension])
    }

    func testCustomPolicyCannotExceedProductAbsoluteLimits() {
        let policy = ScrollingScreenshotSizePolicy(
            maximumDimension: 100_000,
            maximumPixelCount: 900_000_000
        )

        XCTAssertEqual(policy.maximumDimension, 32_768)
        XCTAssertEqual(policy.maximumPixelCount, 120_000_000)
    }

    func testPublicDecisionModelsAreSendable() {
        requireSendable(ScrollingScreenshotSessionState())
        requireSendable(ScrollingScreenshotFixtures.frame("frame", rowIdentifiers: 0..<3).descriptor)
        requireSendable(ScrollingFrameTemporalContext(recentAcceptedScrollRows: [3, 3, 4]))
        requireSendable(ScrollingStitchDecision.noNewContent)
        requireSendable(ScrollingScreenshotSizePolicy.standard)
        requireSendable(ScrollingScreenshotFixtures.exactAssembler)
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
