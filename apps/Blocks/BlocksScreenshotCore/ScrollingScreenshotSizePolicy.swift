import Foundation

public enum ScrollingScreenshotSizeConstraint: String, Equatable, Sendable {
    case positiveDimensions
    case maximumDimension
    case maximumPixelCount
}

public enum ScrollingScreenshotSizeStatus: String, Equatable, Sendable {
    case safe
    case warning
    case exceedsLimit
}

public struct ScrollingScreenshotSizeAssessment: Equatable, Sendable {
    public let size: ScreenshotPixelSize
    public let pixelCount: Int?
    public let status: ScrollingScreenshotSizeStatus
    public let approachingLimits: [ScrollingScreenshotSizeConstraint]
    public let exceededLimits: [ScrollingScreenshotSizeConstraint]

    public init(
        size: ScreenshotPixelSize,
        pixelCount: Int?,
        status: ScrollingScreenshotSizeStatus,
        approachingLimits: [ScrollingScreenshotSizeConstraint],
        exceededLimits: [ScrollingScreenshotSizeConstraint]
    ) {
        self.size = size
        self.pixelCount = pixelCount
        self.status = status
        self.approachingLimits = approachingLimits
        self.exceededLimits = exceededLimits
    }
}

public struct ScrollingScreenshotSizePolicy: Equatable, Sendable {
    public static let absoluteMaximumDimension = 32_768
    public static let absoluteMaximumPixelCount = 120_000_000
    public static let effectiveMaximumDimension = 16_384
    public static let effectiveMaximumPixelCount = 64_000_000
    public static let standard = ScrollingScreenshotSizePolicy()

    public let maximumDimension: Int
    public let maximumPixelCount: Int
    public let warningFraction: Double

    public init(
        maximumDimension: Int = Self.effectiveMaximumDimension,
        maximumPixelCount: Int = Self.effectiveMaximumPixelCount,
        warningFraction: Double = 0.9
    ) {
        self.maximumDimension = min(Self.absoluteMaximumDimension, max(1, maximumDimension))
        self.maximumPixelCount = min(Self.absoluteMaximumPixelCount, max(1, maximumPixelCount))
        self.warningFraction = warningFraction.isFinite
            ? min(1, max(0, warningFraction))
            : 0.9
    }

    public func assess(_ size: ScreenshotPixelSize) -> ScrollingScreenshotSizeAssessment {
        let dimensionsAreValid = size.width > 0 && size.height > 0
        let (pixelCount, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        var approaching: [ScrollingScreenshotSizeConstraint] = []
        var exceeded: [ScrollingScreenshotSizeConstraint] = []

        if !dimensionsAreValid {
            exceeded.append(.positiveDimensions)
        }
        if size.width > maximumDimension || size.height > maximumDimension {
            exceeded.append(.maximumDimension)
        } else if reachesWarning(size.width, limit: maximumDimension)
                    || reachesWarning(size.height, limit: maximumDimension) {
            approaching.append(.maximumDimension)
        }

        if overflow || pixelCount > maximumPixelCount {
            exceeded.append(.maximumPixelCount)
        } else if dimensionsAreValid && reachesWarning(pixelCount, limit: maximumPixelCount) {
            approaching.append(.maximumPixelCount)
        }

        let status: ScrollingScreenshotSizeStatus
        if !exceeded.isEmpty {
            status = .exceedsLimit
        } else if !approaching.isEmpty {
            status = .warning
        } else {
            status = .safe
        }

        return ScrollingScreenshotSizeAssessment(
            size: size,
            pixelCount: overflow ? nil : pixelCount,
            status: status,
            approachingLimits: approaching,
            exceededLimits: exceeded
        )
    }

    private func reachesWarning(_ value: Int, limit: Int) -> Bool {
        Double(value) >= Double(limit) * warningFraction
    }
}
