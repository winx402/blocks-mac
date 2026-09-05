import Foundation

/// A reusable tiled text watermark. Values are intentionally normalized so a
/// preset keeps the same visual weight across region, display, and scrolling captures.
public struct ScreenshotWatermarkStyle: Codable, Equatable, Sendable {
    public static let defaultFontSizeFraction = 0.035
    public static let defaultDensity = 0.5
    public static let defaultAngleDegrees = -30.0
    public static let defaultOpacity = 0.2

    public var text: String
    public var color: ScreenshotColor
    public var weight: ScreenshotTextWeight
    /// Font size relative to the final crop width.
    public var fontSizeFraction: Double
    /// 0 is sparse and 1 is dense.
    public var density: Double
    public var angleDegrees: Double
    public var opacity: Double

    public init(
        text: String,
        color: ScreenshotColor = .init(red: 0.56, green: 0.56, blue: 0.58, alpha: 1),
        weight: ScreenshotTextWeight = .semibold,
        fontSizeFraction: Double = ScreenshotWatermarkStyle.defaultFontSizeFraction,
        density: Double = ScreenshotWatermarkStyle.defaultDensity,
        angleDegrees: Double = ScreenshotWatermarkStyle.defaultAngleDegrees,
        opacity: Double = ScreenshotWatermarkStyle.defaultOpacity
    ) {
        self.text = text
        self.color = color
        self.weight = weight
        self.fontSizeFraction = Self.clampFinite(fontSizeFraction, range: 0.01...0.12, fallback: Self.defaultFontSizeFraction)
        self.density = Self.clampFinite(density, range: 0...1, fallback: Self.defaultDensity)
        self.angleDegrees = Self.clampFinite(angleDegrees, range: -90...90, fallback: Self.defaultAngleDegrees)
        self.opacity = Self.clampFinite(opacity, range: 0...1, fallback: Self.defaultOpacity)
    }

    public var normalized: ScreenshotWatermarkStyle {
        ScreenshotWatermarkStyle(
            text: text,
            color: color,
            weight: weight,
            fontSizeFraction: fontSizeFraction,
            density: density,
            angleDegrees: angleDegrees,
            opacity: opacity
        )
    }

    private static func clampFinite(
        _ value: Double,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

public struct ScreenshotWatermarkPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var style: ScreenshotWatermarkStyle

    public init(
        id: UUID = UUID(),
        name: String,
        style: ScreenshotWatermarkStyle
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.style = style.normalized
    }
}

public struct ScreenshotWatermarkInstance: Codable, Equatable, Sendable {
    public var presetID: UUID?
    public var name: String
    public var style: ScreenshotWatermarkStyle

    public init(
        presetID: UUID? = nil,
        name: String,
        style: ScreenshotWatermarkStyle
    ) {
        self.presetID = presetID
        self.name = name
        self.style = style.normalized
    }
}

public enum ScreenshotWatermarkOverride: Codable, Equatable, Sendable {
    case `default`
    case none
    case preset(UUID)

    private enum CodingKeys: String, CodingKey { case mode, presetID = "preset_id" }
    private enum Mode: String, Codable { case `default`, none, preset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .default:
            self = .default
        case .none:
            self = .none
        case .preset:
            self = .preset(try container.decode(UUID.self, forKey: .presetID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .default:
            try container.encode(Mode.default, forKey: .mode)
        case .none:
            try container.encode(Mode.none, forKey: .mode)
        case let .preset(id):
            try container.encode(Mode.preset, forKey: .mode)
            try container.encode(id, forKey: .presetID)
        }
    }
}
