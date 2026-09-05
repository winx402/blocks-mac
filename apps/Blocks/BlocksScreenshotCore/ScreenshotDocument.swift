import CoreGraphics
import CoreText
import Foundation

public enum ScreenshotEditorTool: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case freehand
    case text
    case highlight
    case blur
    case pixelate
    case counter
    case step
    case callout
    case spotlight
    case redact
    case magnifier
    case watermark

    public static let allCases: [ScreenshotEditorTool] = [
        .select, .arrow, .rectangle, .ellipse, .freehand, .text, .highlight,
        .blur, .pixelate, .counter, .step, .callout, .spotlight, .redact,
        .magnifier, .watermark,
    ]

    public var id: String { rawValue }

    public var toolbarItemID: ScreenshotToolbarItemID {
        ScreenshotToolbarItemID(editorTool: self)
    }
}

public struct ScreenshotPixelPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenshotColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct ScreenshotResolvedColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ color: ScreenshotColor, opacity: Double = 1) {
        red = Self.clamp(color.red)
        green = Self.clamp(color.green)
        blue = Self.clamp(color.blue)
        alpha = Self.clamp(color.alpha) * Self.clamp(opacity)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public struct ScreenshotSourceTileDescriptor: Equatable, Sendable {
    public let id: String
    public let bounds: ScreenshotPixelRect

    public init(id: String, bounds: ScreenshotPixelRect) {
        self.id = id
        self.bounds = bounds
    }
}

public struct ScreenshotSourceContext: @unchecked Sendable {
    public let sourceBounds: ScreenshotPixelRect
    public let tileDescriptors: [ScreenshotSourceTileDescriptor]
    public let compositeSource: CGImage

    public init(
        sourceBounds: ScreenshotPixelRect,
        tileDescriptors: [ScreenshotSourceTileDescriptor],
        compositeSource: CGImage
    ) {
        self.sourceBounds = sourceBounds
        self.tileDescriptors = tileDescriptors
        self.compositeSource = compositeSource
    }
}

public enum ScreenshotElementKind: String, Codable, CaseIterable, Sendable {
    case arrow
    case line
    case rectangle
    case ellipse
    case freehand
    case text
    case highlight
    case blur
    case pixelate
    case counter
    case step
    case callout
    case spotlight
    case redact
    case magnifier
    case watermark
}

public extension ScreenshotElementKind {
    var tool: ScreenshotEditorTool {
        switch self {
        case .arrow: .arrow
        case .line: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .freehand: .freehand
        case .text: .text
        case .highlight: .highlight
        case .blur: .blur
        case .pixelate: .pixelate
        case .counter: .counter
        case .step: .step
        case .callout: .callout
        case .spotlight: .spotlight
        case .redact: .redact
        case .magnifier: .magnifier
        case .watermark: .watermark
        }
    }
}

public enum ScreenshotCalloutTarget: Codable, Equatable, Sendable {
    case point(ScreenshotPixelPoint)
    case ellipse(ScreenshotPixelRect)
}

public enum ScreenshotElementGeometry: Codable, Equatable, Sendable {
    case line(start: ScreenshotPixelPoint, end: ScreenshotPixelPoint)
    case rect(ScreenshotPixelRect)
    case path([ScreenshotPixelPoint])
    case callout(body: ScreenshotPixelRect, pointer: ScreenshotPixelPoint)
    case calloutComposite(target: ScreenshotCalloutTarget, note: ScreenshotPixelRect)
    case counter(center: ScreenshotPixelPoint)
    case step(badgeCenter: ScreenshotPixelPoint, note: ScreenshotPixelRect?)
    case magnifier(center: ScreenshotPixelPoint)
}

public enum ScreenshotLineEnding: String, Codable, CaseIterable, Sendable {
    case none
    case openArrow
    case filledArrow
    case circle
}

public enum ScreenshotLinePattern: String, Codable, CaseIterable, Sendable {
    case solid
    case dashed
}

public enum ScreenshotHighlightMode: String, Codable, CaseIterable, Sendable {
    case freehand
    case rectangle
}

public enum ScreenshotTextWeight: String, Codable, CaseIterable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

public enum ScreenshotTextAlignment: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

public enum ScreenshotTextBoxSizing: String, Codable, CaseIterable, Sendable {
    case auto
    case fixedWidth
    case fixedBox
}

public enum ScreenshotEffectShape: String, Codable, CaseIterable, Sendable {
    case rectangle
    case ellipse
}

public enum ScreenshotCounterShape: String, Codable, CaseIterable, Sendable {
    case circle
    case roundedRectangle
}

public enum ScreenshotRedactMode: String, Codable, CaseIterable, Sendable {
    case solid
    case securePixelate
}

public struct ScreenshotLineAppearance: Codable, Equatable, Sendable {
    public var color: ScreenshotColor
    public var width: Double
    public var opacity: Double
    public var startEnding: ScreenshotLineEnding
    public var endEnding: ScreenshotLineEnding
    public var pattern: ScreenshotLinePattern
    public var curvature: Double
    public var arrowHeadSize: Double

    public init(
        color: ScreenshotColor = .accentRed,
        width: Double = 3,
        opacity: Double = 1,
        startEnding: ScreenshotLineEnding = .none,
        endEnding: ScreenshotLineEnding = .none,
        pattern: ScreenshotLinePattern = .solid,
        curvature: Double = 0,
        arrowHeadSize: Double = 1
    ) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.startEnding = startEnding
        self.endEnding = endEnding
        self.pattern = pattern
        self.curvature = curvature
        self.arrowHeadSize = arrowHeadSize
    }

    private enum CodingKeys: String, CodingKey {
        case color, width, opacity, startEnding, endEnding, pattern, curvature, arrowHeadSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(ScreenshotColor.self, forKey: .color)
        width = try container.decode(Double.self, forKey: .width)
        opacity = try container.decode(Double.self, forKey: .opacity)
        startEnding = try container.decode(ScreenshotLineEnding.self, forKey: .startEnding)
        endEnding = try container.decode(ScreenshotLineEnding.self, forKey: .endEnding)
        pattern = try container.decode(ScreenshotLinePattern.self, forKey: .pattern)
        curvature = try container.decodeIfPresent(Double.self, forKey: .curvature) ?? 0
        arrowHeadSize = try container.decodeIfPresent(Double.self, forKey: .arrowHeadSize) ?? 1
    }
}

public struct ScreenshotShapeAppearance: Codable, Equatable, Sendable {
    public var strokeColor: ScreenshotColor
    public var fillColor: ScreenshotColor?
    public var fillOpacity: Double
    public var strokeWidth: Double
    public var opacity: Double
    public var cornerRadius: Double

    public init(
        strokeColor: ScreenshotColor = .accentRed,
        fillColor: ScreenshotColor? = nil,
        fillOpacity: Double = 0.16,
        strokeWidth: Double = 3,
        opacity: Double = 1,
        cornerRadius: Double = 0
    ) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.cornerRadius = cornerRadius
    }

    private enum CodingKeys: String, CodingKey {
        case strokeColor, fillColor, fillOpacity, strokeWidth, opacity, cornerRadius
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try container.decode(ScreenshotColor.self, forKey: .strokeColor)
        fillColor = try container.decodeIfPresent(ScreenshotColor.self, forKey: .fillColor)
        fillOpacity = try container.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0.16
        strokeWidth = try container.decode(Double.self, forKey: .strokeWidth)
        opacity = try container.decode(Double.self, forKey: .opacity)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
    }
}

public struct ScreenshotFreehandAppearance: Codable, Equatable, Sendable {
    public var color: ScreenshotColor
    public var width: Double
    public var opacity: Double
    public var smoothing: Double

    public init(color: ScreenshotColor = .accentRed, width: Double = 3, opacity: Double = 1, smoothing: Double = 0.5) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.smoothing = smoothing
    }
}

public struct ScreenshotHighlightAppearance: Codable, Equatable, Sendable {
    public var color: ScreenshotColor
    public var width: Double
    public var opacity: Double
    public var mode: ScreenshotHighlightMode

    public init(
        color: ScreenshotColor = .init(red: 1, green: 0.82, blue: 0.18, alpha: 1),
        width: Double = 18,
        opacity: Double = 0.34,
        mode: ScreenshotHighlightMode = .rectangle
    ) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.mode = mode
    }
}

public struct ScreenshotTextAppearance: Codable, Equatable, Sendable {
    public var color: ScreenshotColor
    public var fontSize: Double
    public var weight: ScreenshotTextWeight
    public var alignment: ScreenshotTextAlignment
    public var backgroundColor: ScreenshotColor?
    public var backgroundPadding: Double
    public var backgroundBorderColor: ScreenshotColor?
    public var backgroundBorderWidth: Double
    public var backgroundCornerRadius: Double
    public var lineSpacing: Double
    public var opacity: Double

    public init(
        color: ScreenshotColor = .accentRed,
        fontSize: Double = 20,
        weight: ScreenshotTextWeight = .regular,
        alignment: ScreenshotTextAlignment = .leading,
        backgroundColor: ScreenshotColor? = nil,
        backgroundPadding: Double = 4,
        backgroundBorderColor: ScreenshotColor? = nil,
        backgroundBorderWidth: Double = 0,
        backgroundCornerRadius: Double = 0,
        lineSpacing: Double = 1.2,
        opacity: Double = 1
    ) {
        self.color = color
        self.fontSize = fontSize
        self.weight = weight
        self.alignment = alignment
        self.backgroundColor = backgroundColor
        self.backgroundPadding = backgroundPadding
        self.backgroundBorderColor = backgroundBorderColor
        self.backgroundBorderWidth = backgroundBorderWidth
        self.backgroundCornerRadius = backgroundCornerRadius
        self.lineSpacing = lineSpacing
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case color, fontSize, weight, alignment, backgroundColor, backgroundPadding
        case backgroundBorderColor, backgroundBorderWidth, backgroundCornerRadius
        case lineSpacing, opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(ScreenshotColor.self, forKey: .color)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        weight = try container.decode(ScreenshotTextWeight.self, forKey: .weight)
        alignment = try container.decode(ScreenshotTextAlignment.self, forKey: .alignment)
        backgroundColor = try container.decodeIfPresent(ScreenshotColor.self, forKey: .backgroundColor)
        backgroundPadding = try container.decode(Double.self, forKey: .backgroundPadding)
        backgroundBorderColor = try container.decodeIfPresent(
            ScreenshotColor.self,
            forKey: .backgroundBorderColor
        )
        backgroundBorderWidth = try container.decodeIfPresent(
            Double.self,
            forKey: .backgroundBorderWidth
        ) ?? 0
        backgroundCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .backgroundCornerRadius
        ) ?? 0
        lineSpacing = try container.decode(Double.self, forKey: .lineSpacing)
        opacity = try container.decode(Double.self, forKey: .opacity)
    }
}

public struct ScreenshotEffectAppearance: Codable, Equatable, Sendable {
    public var shape: ScreenshotEffectShape
    public var intensity: Double

    public init(shape: ScreenshotEffectShape = .rectangle, intensity: Double = 8) {
        self.shape = shape
        self.intensity = intensity
    }
}

public struct ScreenshotCounterAppearance: Codable, Equatable, Sendable {
    public var shape: ScreenshotCounterShape
    public var size: Double
    public var fillColor: ScreenshotColor
    public var textColor: ScreenshotColor
    public var borderColor: ScreenshotColor
    public var borderWidth: Double
    public var opacity: Double

    public init(
        shape: ScreenshotCounterShape = .circle,
        size: Double = 28,
        fillColor: ScreenshotColor = .accentRed,
        textColor: ScreenshotColor = .white,
        borderColor: ScreenshotColor = .white,
        borderWidth: Double = 2,
        opacity: Double = 1
    ) {
        self.shape = shape
        self.size = size
        self.fillColor = fillColor
        self.textColor = textColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.opacity = opacity
    }
}

public struct ScreenshotStepConnectorAttachment: Codable, Equatable, Sendable {
    /// Unit vector from the badge center to its connector endpoint.
    public var badgeDirection: ScreenshotPixelPoint
    /// Unit coordinates within the note rectangle, constrained to its perimeter.
    public var notePosition: ScreenshotPixelPoint

    public init(
        badgeDirection: ScreenshotPixelPoint,
        notePosition: ScreenshotPixelPoint
    ) {
        self.badgeDirection = badgeDirection
        self.notePosition = notePosition
    }
}

public struct ScreenshotStepAppearance: Codable, Equatable, Sendable {
    public var badge: ScreenshotCounterAppearance
    public var connector: ScreenshotLineAppearance
    public var note: ScreenshotTextAppearance
    public var connectorAttachment: ScreenshotStepConnectorAttachment?
    public var gap: Double

    public var badgeShape: ScreenshotCounterShape {
        get { badge.shape }
        set { badge.shape = newValue }
    }
    public var badgeSize: Double {
        get { badge.size }
        set { badge.size = newValue }
    }
    public var badgeFillColor: ScreenshotColor {
        get { badge.fillColor }
        set { badge.fillColor = newValue }
    }
    public var badgeTextColor: ScreenshotColor {
        get { badge.textColor }
        set { badge.textColor = newValue }
    }
    public var badgeBorderColor: ScreenshotColor {
        get { badge.borderColor }
        set { badge.borderColor = newValue }
    }
    public var badgeBorderWidth: Double {
        get { badge.borderWidth }
        set { badge.borderWidth = newValue }
    }
    public var noteBackgroundColor: ScreenshotColor {
        get { note.backgroundColor ?? .init(red: 0, green: 0, blue: 0, alpha: 0) }
        set { note.backgroundColor = newValue }
    }
    public var noteTextColor: ScreenshotColor {
        get { note.color }
        set { note.color = newValue }
    }
    public var noteBorderColor: ScreenshotColor {
        get { note.backgroundBorderColor ?? connector.color }
        set { note.backgroundBorderColor = newValue }
    }
    public var noteBorderWidth: Double {
        get { note.backgroundBorderWidth }
        set { note.backgroundBorderWidth = newValue }
    }
    public var noteCornerRadius: Double {
        get { note.backgroundCornerRadius }
        set { note.backgroundCornerRadius = newValue }
    }
    public var noteFontSize: Double {
        get { note.fontSize }
        set { note.fontSize = newValue }
    }
    public var notePadding: Double {
        get { note.backgroundPadding }
        set { note.backgroundPadding = newValue }
    }
    public var opacity: Double {
        get { badge.opacity }
        set {
            badge.opacity = newValue
            connector.opacity = newValue
            note.opacity = newValue
        }
    }

    public init(
        badgeShape: ScreenshotCounterShape = .circle,
        badgeSize: Double = 28,
        badgeFillColor: ScreenshotColor = .accentRed,
        badgeTextColor: ScreenshotColor = .white,
        badgeBorderColor: ScreenshotColor = .white,
        badgeBorderWidth: Double = 2,
        noteBackgroundColor: ScreenshotColor = .init(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.9),
        noteTextColor: ScreenshotColor = .white,
        noteBorderColor: ScreenshotColor = .accentRed,
        noteBorderWidth: Double = 1,
        noteCornerRadius: Double = 8,
        noteFontSize: Double = 16,
        notePadding: Double = 8,
        connectorAttachment: ScreenshotStepConnectorAttachment? = nil,
        gap: Double = 28,
        opacity: Double = 1
    ) {
        badge = ScreenshotCounterAppearance(
            shape: badgeShape,
            size: badgeSize,
            fillColor: badgeFillColor,
            textColor: badgeTextColor,
            borderColor: badgeBorderColor,
            borderWidth: badgeBorderWidth,
            opacity: opacity
        )
        connector = ScreenshotLineAppearance(
            color: noteBorderColor,
            width: max(2, noteBorderWidth),
            opacity: opacity
        )
        note = ScreenshotTextAppearance(
            color: noteTextColor,
            fontSize: noteFontSize,
            weight: .medium,
            alignment: .leading,
            backgroundColor: noteBackgroundColor,
            backgroundPadding: notePadding,
            backgroundBorderColor: noteBorderColor,
            backgroundBorderWidth: noteBorderWidth,
            backgroundCornerRadius: noteCornerRadius,
            lineSpacing: 1.2,
            opacity: opacity
        )
        self.connectorAttachment = connectorAttachment
        self.gap = gap
    }

    public init(
        badge: ScreenshotCounterAppearance,
        connector: ScreenshotLineAppearance,
        note: ScreenshotTextAppearance,
        connectorAttachment: ScreenshotStepConnectorAttachment? = nil,
        gap: Double = 28
    ) {
        self.badge = badge
        self.connector = connector
        self.note = note
        self.connectorAttachment = connectorAttachment
        self.gap = gap
    }

    private enum CodingKeys: String, CodingKey {
        case badge, connector, note, connectorAttachment, gap
        case badgeShape, badgeSize, badgeFillColor, badgeTextColor, badgeBorderColor, badgeBorderWidth
        case noteBackgroundColor, noteTextColor, noteBorderColor, noteBorderWidth
        case noteCornerRadius, noteFontSize, notePadding, opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let badge = try container.decodeIfPresent(ScreenshotCounterAppearance.self, forKey: .badge),
           let connector = try container.decodeIfPresent(ScreenshotLineAppearance.self, forKey: .connector),
           let note = try container.decodeIfPresent(ScreenshotTextAppearance.self, forKey: .note) {
            _ = try container.decodeIfPresent(
                ScreenshotStepConnectorAttachment.self,
                forKey: .connectorAttachment
            )
            self.init(
                badge: badge,
                connector: connector,
                note: note,
                connectorAttachment: nil,
                gap: try container.decodeIfPresent(Double.self, forKey: .gap) ?? 28
            )
            return
        }

        self.init(
            badgeShape: try container.decodeIfPresent(
                ScreenshotCounterShape.self,
                forKey: .badgeShape
            ) ?? .circle,
            badgeSize: try container.decodeIfPresent(Double.self, forKey: .badgeSize) ?? 28,
            badgeFillColor: try container.decodeIfPresent(
                ScreenshotColor.self,
                forKey: .badgeFillColor
            ) ?? .accentRed,
            badgeTextColor: try container.decodeIfPresent(
                ScreenshotColor.self,
                forKey: .badgeTextColor
            ) ?? .white,
            badgeBorderColor: try container.decodeIfPresent(
                ScreenshotColor.self,
                forKey: .badgeBorderColor
            ) ?? .white,
            badgeBorderWidth: try container.decodeIfPresent(Double.self, forKey: .badgeBorderWidth) ?? 2,
            noteBackgroundColor: try container.decodeIfPresent(
                ScreenshotColor.self,
                forKey: .noteBackgroundColor
            ) ?? .init(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.9),
            noteTextColor: try container.decodeIfPresent(
                ScreenshotColor.self,
                forKey: .noteTextColor
            ) ?? .white,
            noteBorderColor: try container.decodeIfPresent(
                ScreenshotColor.self,
                forKey: .noteBorderColor
            ) ?? .accentRed,
            noteBorderWidth: try container.decodeIfPresent(Double.self, forKey: .noteBorderWidth) ?? 1,
            noteCornerRadius: try container.decodeIfPresent(Double.self, forKey: .noteCornerRadius) ?? 8,
            noteFontSize: try container.decodeIfPresent(Double.self, forKey: .noteFontSize) ?? 16,
            notePadding: try container.decodeIfPresent(Double.self, forKey: .notePadding) ?? 8,
            connectorAttachment: nil,
            gap: try container.decodeIfPresent(Double.self, forKey: .gap) ?? 28,
            opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(badge, forKey: .badge)
        try container.encode(connector, forKey: .connector)
        try container.encode(note, forKey: .note)
        try container.encode(gap, forKey: .gap)
    }
}

public struct ScreenshotCalloutAppearance: Codable, Equatable, Sendable {
    public var target: ScreenshotShapeAppearance
    public var connector: ScreenshotLineAppearance
    public var note: ScreenshotTextAppearance
    public var connectorAttachment: ScreenshotCalloutConnectorAttachment?

    public var backgroundColor: ScreenshotColor {
        get { note.backgroundColor ?? .init(red: 0, green: 0, blue: 0, alpha: 0) }
        set { note.backgroundColor = newValue }
    }
    public var borderColor: ScreenshotColor {
        get { connector.color }
        set {
            target.strokeColor = newValue
            connector.color = newValue
            note.backgroundBorderColor = newValue
        }
    }
    public var textColor: ScreenshotColor {
        get { note.color }
        set { note.color = newValue }
    }
    public var borderWidth: Double {
        get { connector.width }
        set {
            target.strokeWidth = newValue
            connector.width = newValue
            note.backgroundBorderWidth = newValue
        }
    }
    public var cornerRadius: Double {
        get { note.backgroundCornerRadius }
        set { note.backgroundCornerRadius = newValue }
    }
    public var fontSize: Double {
        get { note.fontSize }
        set { note.fontSize = newValue }
    }
    public var weight: ScreenshotTextWeight {
        get { note.weight }
        set { note.weight = newValue }
    }
    public var alignment: ScreenshotTextAlignment {
        get { note.alignment }
        set { note.alignment = newValue }
    }
    public var padding: Double {
        get { note.backgroundPadding }
        set { note.backgroundPadding = newValue }
    }
    public var opacity: Double {
        get { note.opacity }
        set {
            target.opacity = newValue
            connector.opacity = newValue
            note.opacity = newValue
        }
    }

    public init(
        backgroundColor: ScreenshotColor = .init(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.9),
        borderColor: ScreenshotColor = .accentRed,
        textColor: ScreenshotColor = .white,
        borderWidth: Double = 2,
        cornerRadius: Double = 10,
        fontSize: Double = 18,
        weight: ScreenshotTextWeight = .medium,
        alignment: ScreenshotTextAlignment = .leading,
        padding: Double = 10,
        opacity: Double = 1
    ) {
        target = ScreenshotShapeAppearance(
            strokeColor: borderColor,
            fillColor: nil,
            fillOpacity: 0,
            strokeWidth: max(1, borderWidth),
            opacity: opacity
        )
        connector = ScreenshotLineAppearance(
            color: borderColor,
            width: max(1, borderWidth),
            opacity: opacity,
            startEnding: .none,
            endEnding: .filledArrow
        )
        note = ScreenshotTextAppearance(
            color: textColor,
            fontSize: fontSize,
            weight: weight,
            alignment: alignment,
            backgroundColor: backgroundColor,
            backgroundPadding: padding,
            backgroundBorderColor: borderColor,
            backgroundBorderWidth: borderWidth,
            backgroundCornerRadius: cornerRadius,
            lineSpacing: 1.2,
            opacity: opacity
        )
        connectorAttachment = nil
    }

    public init(
        target: ScreenshotShapeAppearance,
        connector: ScreenshotLineAppearance,
        note: ScreenshotTextAppearance,
        connectorAttachment: ScreenshotCalloutConnectorAttachment? = nil
    ) {
        self.target = target
        self.connector = connector
        self.note = note
        self.connectorAttachment = connectorAttachment
    }

    private enum CodingKeys: String, CodingKey {
        case target, connector, note, connectorAttachment
        case backgroundColor, borderColor, textColor, borderWidth, cornerRadius
        case fontSize, weight, alignment, padding, opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let target = try container.decodeIfPresent(ScreenshotShapeAppearance.self, forKey: .target),
           let connector = try container.decodeIfPresent(ScreenshotLineAppearance.self, forKey: .connector),
           let note = try container.decodeIfPresent(ScreenshotTextAppearance.self, forKey: .note) {
            _ = try container.decodeIfPresent(
                ScreenshotCalloutConnectorAttachment.self,
                forKey: .connectorAttachment
            )
            self.init(
                target: target,
                connector: connector,
                note: note,
                connectorAttachment: nil
            )
            return
        }
        self.init(
            backgroundColor: try container.decodeIfPresent(ScreenshotColor.self, forKey: .backgroundColor)
                ?? .init(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.9),
            borderColor: try container.decodeIfPresent(ScreenshotColor.self, forKey: .borderColor) ?? .accentRed,
            textColor: try container.decodeIfPresent(ScreenshotColor.self, forKey: .textColor) ?? .white,
            borderWidth: try container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 2,
            cornerRadius: try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 10,
            fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18,
            weight: try container.decodeIfPresent(ScreenshotTextWeight.self, forKey: .weight) ?? .medium,
            alignment: try container.decodeIfPresent(ScreenshotTextAlignment.self, forKey: .alignment) ?? .leading,
            padding: try container.decodeIfPresent(Double.self, forKey: .padding) ?? 10,
            opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(connector, forKey: .connector)
        try container.encode(note, forKey: .note)
    }
}

public struct ScreenshotCalloutConnectorAttachment: Codable, Equatable, Sendable {
    /// Unit vector from an ellipse target's center to the connector endpoint.
    /// Point targets ignore this vector because their endpoint is the point itself.
    public var targetDirection: ScreenshotPixelPoint
    /// Unit coordinates within the note rectangle, constrained to its perimeter.
    public var notePosition: ScreenshotPixelPoint

    public init(targetDirection: ScreenshotPixelPoint, notePosition: ScreenshotPixelPoint) {
        self.targetDirection = targetDirection
        self.notePosition = notePosition
    }
}

public struct ScreenshotSpotlightAppearance: Codable, Equatable, Sendable {
    public var shape: ScreenshotEffectShape
    public var dimIntensity: Double
    public var feather: Double

    public init(shape: ScreenshotEffectShape = .ellipse, dimIntensity: Double = 0.62, feather: Double = 12) {
        self.shape = shape
        self.dimIntensity = dimIntensity
        self.feather = feather
    }
}

public struct ScreenshotRedactAppearance: Codable, Equatable, Sendable {
    public var mode: ScreenshotRedactMode
    public var shape: ScreenshotEffectShape
    public var color: ScreenshotColor
    public var intensity: Double

    public init(
        mode: ScreenshotRedactMode = .solid,
        shape: ScreenshotEffectShape = .rectangle,
        color: ScreenshotColor = .init(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
        intensity: Double = 18
    ) {
        self.mode = mode
        self.shape = shape
        self.color = color
        self.intensity = intensity
    }
}

public struct ScreenshotMagnifierAppearance: Codable, Equatable, Sendable {
    public var zoom: Double
    public var diameter: Double
    public var borderColor: ScreenshotColor
    public var borderWidth: Double
    public var shadow: Double

    public init(
        zoom: Double = 2,
        diameter: Double = 120,
        borderColor: ScreenshotColor = .white,
        borderWidth: Double = 3,
        shadow: Double = 0.35
    ) {
        self.zoom = zoom
        self.diameter = diameter
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.shadow = shadow
    }
}

public enum ScreenshotMagnifierMetrics {
    public static let defaultDiameter = 120.0
    public static let minimumDiameter = 60.0
    public static let maximumDiameter = 240.0
    public static let minimumZoom = 1.5
    public static let maximumZoom = 5.0

    public static func resolvedDiameter(_ proposed: Double) -> Double {
        guard proposed.isFinite else { return defaultDiameter }
        return min(maximumDiameter, max(minimumDiameter, proposed))
    }

    public static func resolvedZoom(_ proposed: Double) -> Double {
        guard proposed.isFinite else { return 2 }
        return min(maximumZoom, max(minimumZoom, proposed))
    }
}

public enum ScreenshotAppearancePayloadKind: String, Codable, CaseIterable, Sendable {
    case line, shape, freehand, text, highlight, effect, counter, step, callout, spotlight, redact, magnifier
}

public enum ScreenshotAppearancePayload: Codable, Equatable, Sendable {
    case line(ScreenshotLineAppearance)
    case shape(ScreenshotShapeAppearance)
    case freehand(ScreenshotFreehandAppearance)
    case text(ScreenshotTextAppearance)
    case highlight(ScreenshotHighlightAppearance)
    case effect(ScreenshotEffectAppearance)
    case counter(ScreenshotCounterAppearance)
    case step(ScreenshotStepAppearance)
    case callout(ScreenshotCalloutAppearance)
    case spotlight(ScreenshotSpotlightAppearance)
    case redact(ScreenshotRedactAppearance)
    case magnifier(ScreenshotMagnifierAppearance)

    public var kind: ScreenshotAppearancePayloadKind {
        switch self {
        case .line: .line
        case .shape: .shape
        case .freehand: .freehand
        case .text: .text
        case .highlight: .highlight
        case .effect: .effect
        case .counter: .counter
        case .step: .step
        case .callout: .callout
        case .spotlight: .spotlight
        case .redact: .redact
        case .magnifier: .magnifier
        }
    }
}

public struct ScreenshotElementAppearance: Codable, Equatable, Sendable {
    public var payload: ScreenshotAppearancePayload

    public init(payload: ScreenshotAppearancePayload) { self.payload = payload }

    public init(
        strokeColor: ScreenshotColor = .accentRed,
        fillColor: ScreenshotColor? = nil,
        lineWidth: Double = 3,
        opacity: Double = 1,
        startEnding: ScreenshotLineEnding = .none,
        endEnding: ScreenshotLineEnding = .none,
        linePattern: ScreenshotLinePattern = .solid,
        cornerRadius: Double = 0,
        smoothing: Double = 0.5,
        highlightMode: ScreenshotHighlightMode = .rectangle,
        fontSize: Double = 20,
        textWeight: ScreenshotTextWeight = .regular,
        textAlignment: ScreenshotTextAlignment = .leading,
        textBackgroundColor: ScreenshotColor? = nil,
        effectIntensity: Double = 8
    ) {
        if startEnding != .none || endEnding != .none || linePattern != .solid {
            payload = .line(.init(
                color: strokeColor,
                width: lineWidth,
                opacity: opacity,
                startEnding: startEnding,
                endEnding: endEnding,
                pattern: linePattern
            ))
        } else if textBackgroundColor != nil || fontSize != 20 || textWeight != .regular || textAlignment != .leading {
            payload = .text(.init(
                color: strokeColor,
                fontSize: fontSize,
                weight: textWeight,
                alignment: textAlignment,
                backgroundColor: textBackgroundColor,
                opacity: opacity
            ))
        } else if highlightMode != .rectangle {
            payload = .highlight(.init(color: strokeColor, width: lineWidth, opacity: opacity, mode: highlightMode))
        } else if smoothing != 0.5 {
            payload = .freehand(.init(color: strokeColor, width: lineWidth, opacity: opacity, smoothing: smoothing))
        } else if effectIntensity != 8 {
            payload = .effect(.init(intensity: effectIntensity))
        } else {
            payload = .shape(.init(
                strokeColor: strokeColor,
                fillColor: fillColor,
                fillOpacity: fillColor == nil ? 0.16 : 1,
                strokeWidth: lineWidth,
                opacity: opacity,
                cornerRadius: cornerRadius
            ))
        }
    }

    public static func line(_ value: ScreenshotLineAppearance = .init()) -> Self { .init(payload: .line(value)) }
    public static func shape(_ value: ScreenshotShapeAppearance = .init()) -> Self { .init(payload: .shape(value)) }
    public static func freehand(_ value: ScreenshotFreehandAppearance = .init()) -> Self { .init(payload: .freehand(value)) }
    public static func text(_ value: ScreenshotTextAppearance = .init()) -> Self { .init(payload: .text(value)) }
    public static func highlight(_ value: ScreenshotHighlightAppearance = .init()) -> Self { .init(payload: .highlight(value)) }
    public static func effect(_ value: ScreenshotEffectAppearance = .init()) -> Self { .init(payload: .effect(value)) }
    public static func counter(_ value: ScreenshotCounterAppearance = .init()) -> Self { .init(payload: .counter(value)) }
    public static func step(_ value: ScreenshotStepAppearance = .init()) -> Self { .init(payload: .step(value)) }
    public static func callout(_ value: ScreenshotCalloutAppearance = .init()) -> Self { .init(payload: .callout(value)) }
    public static func spotlight(_ value: ScreenshotSpotlightAppearance = .init()) -> Self { .init(payload: .spotlight(value)) }
    public static func redact(_ value: ScreenshotRedactAppearance = .init()) -> Self { .init(payload: .redact(value)) }
    public static func magnifier(_ value: ScreenshotMagnifierAppearance = .init()) -> Self { .init(payload: .magnifier(value)) }
}

public struct ScreenshotToolPreset: Codable, Equatable, Sendable {
    public let tool: ScreenshotEditorTool
    public var appearance: ScreenshotElementAppearance

    public init(tool: ScreenshotEditorTool, appearance: ScreenshotElementAppearance? = nil) {
        self.tool = tool
        self.appearance = appearance ?? ScreenshotElementAppearance.defaultValue(for: tool)
    }
}

public extension ScreenshotElementAppearance {
    static func defaultValue(for tool: ScreenshotEditorTool) -> ScreenshotElementAppearance {
        switch tool {
        case .select, .rectangle, .ellipse: .shape()
        case .arrow:
            .line(.init(endEnding: .filledArrow))
        case .line: .line(.init(endEnding: .filledArrow))
        case .freehand: .freehand()
        case .text: .text()
        case .highlight: .highlight()
        case .blur: .effect(.init(intensity: 8))
        case .pixelate: .effect(.init(intensity: 12))
        case .counter: .counter()
        case .step: .step()
        case .callout: .callout()
        case .spotlight: .spotlight()
        case .redact: .redact()
        case .magnifier: .magnifier()
        case .watermark: .shape()
        }
    }

    var strokeColor: ScreenshotColor {
        get {
            switch payload {
            case let .line(value): value.color
            case let .shape(value): value.strokeColor
            case let .freehand(value): value.color
            case let .text(value): value.color
            case let .highlight(value): value.color
            case let .counter(value): value.borderColor
            case let .step(value): value.badgeBorderColor
            case let .callout(value): value.borderColor
            case let .redact(value): value.color
            case let .magnifier(value): value.borderColor
            case .effect, .spotlight: .accentRed
            }
        }
        set {
            switch payload {
            case var .line(value): value.color = newValue; payload = .line(value)
            case var .shape(value): value.strokeColor = newValue; payload = .shape(value)
            case var .freehand(value): value.color = newValue; payload = .freehand(value)
            case var .text(value): value.color = newValue; payload = .text(value)
            case var .highlight(value): value.color = newValue; payload = .highlight(value)
            case var .counter(value): value.borderColor = newValue; payload = .counter(value)
            case var .step(value): value.badgeBorderColor = newValue; payload = .step(value)
            case var .callout(value): value.borderColor = newValue; payload = .callout(value)
            case var .redact(value): value.color = newValue; payload = .redact(value)
            case var .magnifier(value): value.borderColor = newValue; payload = .magnifier(value)
            case .effect, .spotlight: break
            }
        }
    }

    var fillColor: ScreenshotColor? {
        get {
            switch payload {
            case let .shape(value): value.fillColor
            case let .counter(value): value.fillColor
            case let .step(value): value.badgeFillColor
            case let .callout(value): value.backgroundColor
            default: nil
            }
        }
        set {
            switch payload {
            case var .shape(value): value.fillColor = newValue; payload = .shape(value)
            case var .counter(value): if let newValue { value.fillColor = newValue }; payload = .counter(value)
            case var .step(value): if let newValue { value.badgeFillColor = newValue }; payload = .step(value)
            case var .callout(value): if let newValue { value.backgroundColor = newValue }; payload = .callout(value)
            default: break
            }
        }
    }

    var fillColorValue: ScreenshotColor {
        get { fillColor ?? strokeColor }
        set { fillColor = newValue }
    }

    var fillOpacity: Double {
        get { if case let .shape(value) = payload { value.fillOpacity } else { 1 } }
        set { if case var .shape(value) = payload { value.fillOpacity = newValue; payload = .shape(value) } }
    }

    var counterShape: ScreenshotCounterShape {
        get { if case let .counter(value) = payload { value.shape } else { .circle } }
        set { if case var .counter(value) = payload { value.shape = newValue; payload = .counter(value) } }
    }

    var counterSize: Double {
        get { if case let .counter(value) = payload { value.size } else { 28 } }
        set { if case var .counter(value) = payload { value.size = newValue; payload = .counter(value) } }
    }

    var counterFillColor: ScreenshotColor {
        get { if case let .counter(value) = payload { value.fillColor } else { .accentRed } }
        set { if case var .counter(value) = payload { value.fillColor = newValue; payload = .counter(value) } }
    }

    var counterTextColor: ScreenshotColor {
        get { if case let .counter(value) = payload { value.textColor } else { .white } }
        set { if case var .counter(value) = payload { value.textColor = newValue; payload = .counter(value) } }
    }

    var stepAppearance: ScreenshotStepAppearance {
        get { if case let .step(value) = payload { value } else { .init() } }
        set { payload = .step(newValue) }
    }

    var calloutTextColor: ScreenshotColor {
        get { if case let .callout(value) = payload { value.textColor } else { .white } }
        set { if case var .callout(value) = payload { value.textColor = newValue; payload = .callout(value) } }
    }

    var calloutBackgroundColor: ScreenshotColor {
        get {
            if case let .callout(value) = payload { return value.backgroundColor }
            return .init(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.9)
        }
        set { if case var .callout(value) = payload { value.backgroundColor = newValue; payload = .callout(value) } }
    }

    var spotlightFeather: Double {
        get { if case let .spotlight(value) = payload { value.feather } else { 12 } }
        set { if case var .spotlight(value) = payload { value.feather = newValue; payload = .spotlight(value) } }
    }

    var magnifierDiameter: Double {
        get { if case let .magnifier(value) = payload { value.diameter } else { 120 } }
        set { if case var .magnifier(value) = payload { value.diameter = newValue; payload = .magnifier(value) } }
    }

    var magnifierShadow: Double {
        get { if case let .magnifier(value) = payload { value.shadow } else { 0.35 } }
        set { if case var .magnifier(value) = payload { value.shadow = newValue; payload = .magnifier(value) } }
    }

    var lineWidth: Double {
        get {
            switch payload {
            case let .line(value): value.width
            case let .shape(value): value.strokeWidth
            case let .freehand(value): value.width
            case let .highlight(value): value.width
            case let .counter(value): value.borderWidth
            case let .step(value): value.badgeBorderWidth
            case let .callout(value): value.borderWidth
            case let .magnifier(value): value.borderWidth
            default: 0
            }
        }
        set {
            switch payload {
            case var .line(value): value.width = newValue; payload = .line(value)
            case var .shape(value): value.strokeWidth = newValue; payload = .shape(value)
            case var .freehand(value): value.width = newValue; payload = .freehand(value)
            case var .highlight(value): value.width = newValue; payload = .highlight(value)
            case var .counter(value): value.borderWidth = newValue; payload = .counter(value)
            case var .step(value): value.badgeBorderWidth = newValue; payload = .step(value)
            case var .callout(value): value.borderWidth = newValue; payload = .callout(value)
            case var .magnifier(value): value.borderWidth = newValue; payload = .magnifier(value)
            default: break
            }
        }
    }

    var opacity: Double {
        get {
            switch payload {
            case let .line(value): value.opacity
            case let .shape(value): value.opacity
            case let .freehand(value): value.opacity
            case let .text(value): value.opacity
            case let .highlight(value): value.opacity
            case let .counter(value): value.opacity
            case let .step(value): value.opacity
            case let .callout(value): value.opacity
            default: 1
            }
        }
        set {
            switch payload {
            case var .line(value): value.opacity = newValue; payload = .line(value)
            case var .shape(value): value.opacity = newValue; payload = .shape(value)
            case var .freehand(value): value.opacity = newValue; payload = .freehand(value)
            case var .text(value): value.opacity = newValue; payload = .text(value)
            case var .highlight(value): value.opacity = newValue; payload = .highlight(value)
            case var .counter(value): value.opacity = newValue; payload = .counter(value)
            case var .step(value): value.opacity = newValue; payload = .step(value)
            case var .callout(value): value.opacity = newValue; payload = .callout(value)
            default: break
            }
        }
    }

    var startEnding: ScreenshotLineEnding {
        get { if case let .line(value) = payload { value.startEnding } else { .none } }
        set {
            var value = lineValue
            value.startEnding = newValue
            payload = .line(value)
        }
    }

    var endEnding: ScreenshotLineEnding {
        get { if case let .line(value) = payload { value.endEnding } else { .none } }
        set {
            var value = lineValue
            value.endEnding = newValue
            payload = .line(value)
        }
    }

    var linePattern: ScreenshotLinePattern {
        get { if case let .line(value) = payload { value.pattern } else { .solid } }
        set {
            var value = lineValue
            value.pattern = newValue
            payload = .line(value)
        }
    }

    var curvature: Double {
        get {
            switch payload {
            case let .line(value): value.curvature
            case let .step(value): value.connector.curvature
            case let .callout(value): value.connector.curvature
            default: 0
            }
        }
        set {
            switch payload {
            case var .line(value): value.curvature = newValue; payload = .line(value)
            case var .step(value): value.connector.curvature = newValue; payload = .step(value)
            case var .callout(value): value.connector.curvature = newValue; payload = .callout(value)
            default:
                var value = lineValue
                value.curvature = newValue
                payload = .line(value)
            }
        }
    }

    var arrowHeadSize: Double {
        get { if case let .line(value) = payload { value.arrowHeadSize } else { 1 } }
        set {
            var value = lineValue
            value.arrowHeadSize = newValue
            payload = .line(value)
        }
    }

    var cornerRadius: Double {
        get {
            switch payload {
            case let .shape(value): value.cornerRadius
            case let .callout(value): value.cornerRadius
            default: 0
            }
        }
        set {
            switch payload {
            case var .shape(value): value.cornerRadius = newValue; payload = .shape(value)
            case var .callout(value): value.cornerRadius = newValue; payload = .callout(value)
            default: break
            }
        }
    }

    var smoothing: Double {
        get { if case let .freehand(value) = payload { value.smoothing } else { 0 } }
        set { if case var .freehand(value) = payload { value.smoothing = newValue; payload = .freehand(value) } }
    }

    var highlightMode: ScreenshotHighlightMode {
        get { if case let .highlight(value) = payload { value.mode } else { .rectangle } }
        set { if case var .highlight(value) = payload { value.mode = newValue; payload = .highlight(value) } }
    }

    var fontSize: Double {
        get {
            switch payload {
            case let .text(value): value.fontSize
            case let .callout(value): value.fontSize
            case let .counter(value): value.size * 0.46
            case let .step(value): value.noteFontSize
            default: 20
            }
        }
        set {
            switch payload {
            case var .text(value): value.fontSize = newValue; payload = .text(value)
            case var .callout(value): value.fontSize = newValue; payload = .callout(value)
            case var .counter(value): value.size = max(value.size, newValue * 1.8); payload = .counter(value)
            case var .step(value): value.noteFontSize = newValue; payload = .step(value)
            default: break
            }
        }
    }

    var textWeight: ScreenshotTextWeight {
        get {
            switch payload {
            case let .text(value): value.weight
            case let .callout(value): value.weight
            case let .step(value): value.note.weight
            default: .regular
            }
        }
        set {
            switch payload {
            case var .text(value): value.weight = newValue; payload = .text(value)
            case var .callout(value): value.weight = newValue; payload = .callout(value)
            case var .step(value): value.note.weight = newValue; payload = .step(value)
            default: break
            }
        }
    }

    var textAlignment: ScreenshotTextAlignment {
        get {
            switch payload {
            case let .text(value): value.alignment
            case let .callout(value): value.alignment
            case let .step(value): value.note.alignment
            default: .leading
            }
        }
        set {
            switch payload {
            case var .text(value): value.alignment = newValue; payload = .text(value)
            case var .callout(value): value.alignment = newValue; payload = .callout(value)
            case var .step(value): value.note.alignment = newValue; payload = .step(value)
            default: break
            }
        }
    }

    var textBackgroundColor: ScreenshotColor? {
        get {
            switch payload {
            case let .text(value): value.backgroundColor
            case let .callout(value): value.backgroundColor
            case let .step(value): value.note.backgroundColor
            default: nil
            }
        }
        set {
            switch payload {
            case var .text(value): value.backgroundColor = newValue; payload = .text(value)
            case var .callout(value): if let newValue { value.backgroundColor = newValue }; payload = .callout(value)
            case var .step(value): value.note.backgroundColor = newValue; payload = .step(value)
            default: break
            }
        }
    }

    var textBackgroundColorValue: ScreenshotColor {
        get { textBackgroundColor ?? ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 0.62) }
        set { textBackgroundColor = newValue }
    }

    var textBackgroundPadding: Double {
        get {
            switch payload {
            case let .text(value): value.backgroundPadding
            case let .callout(value): value.padding
            case let .step(value): value.note.backgroundPadding
            default: 4
            }
        }
        set {
            switch payload {
            case var .text(value): value.backgroundPadding = newValue; payload = .text(value)
            case var .callout(value): value.padding = newValue; payload = .callout(value)
            case var .step(value): value.note.backgroundPadding = newValue; payload = .step(value)
            default: break
            }
        }
    }

    var textLineSpacing: Double {
        get {
            switch payload {
            case let .text(value): value.lineSpacing
            case let .step(value): value.note.lineSpacing
            default: 1.2
            }
        }
        set {
            switch payload {
            case var .text(value): value.lineSpacing = newValue; payload = .text(value)
            case var .step(value): value.note.lineSpacing = newValue; payload = .step(value)
            default: break
            }
        }
    }

    var effectIntensity: Double {
        get {
            switch payload {
            case let .effect(value): value.intensity
            case let .redact(value): value.intensity
            case let .spotlight(value): value.dimIntensity
            case let .magnifier(value): value.zoom
            default: 0
            }
        }
        set {
            switch payload {
            case var .effect(value): value.intensity = newValue; payload = .effect(value)
            case var .redact(value): value.intensity = newValue; payload = .redact(value)
            case var .spotlight(value): value.dimIntensity = newValue; payload = .spotlight(value)
            case var .magnifier(value): value.zoom = newValue; payload = .magnifier(value)
            default: break
            }
        }
    }

    var effectShape: ScreenshotEffectShape {
        get {
            switch payload {
            case let .effect(value): value.shape
            case let .spotlight(value): value.shape
            case let .redact(value): value.shape
            default: .rectangle
            }
        }
        set {
            switch payload {
            case var .effect(value): value.shape = newValue; payload = .effect(value)
            case var .spotlight(value): value.shape = newValue; payload = .spotlight(value)
            case var .redact(value): value.shape = newValue; payload = .redact(value)
            default: break
            }
        }
    }

    var redactMode: ScreenshotRedactMode {
        get { if case let .redact(value) = payload { value.mode } else { .solid } }
        set { if case var .redact(value) = payload { value.mode = newValue; payload = .redact(value) } }
    }

    private var lineValue: ScreenshotLineAppearance {
        if case let .line(value) = payload { return value }
        return .init(color: strokeColor, width: max(0.5, lineWidth), opacity: opacity)
    }
}

public extension ScreenshotColor {
    static let accentRed = ScreenshotColor(red: 0.96, green: 0.24, blue: 0.22, alpha: 1)
    static let white = ScreenshotColor(red: 1, green: 1, blue: 1, alpha: 1)
}

public struct ScreenshotTextLayout {
    public static let defaultMaximumAutoWidth: Double = 360

    public struct ViewMetrics: Equatable, Sendable {
        public let fontSize: Double
        public let characterSpacing: Double
        public let lineHeight: Double
    }

    public let fontName: String
    public let fontSize: Double
    public let foregroundColor: CGColor
    public let backgroundColor: CGColor?
    public let characterSpacing: Double
    public let lineHeight: Double
    public let strokeWidth: Double
    public let alignment: ScreenshotTextAlignment
    public let padding: Double

    public init(appearance: ScreenshotElementAppearance, padding: Double? = nil) {
        fontName = Self.fontName(for: appearance.textWeight)
        fontSize = max(1, appearance.fontSize)
        foregroundColor = ScreenshotResolvedColor(
            appearance.strokeColor,
            opacity: appearance.opacity
        ).cgColor
        backgroundColor = appearance.textBackgroundColor.map { color in
            ScreenshotResolvedColor(color, opacity: appearance.opacity).cgColor
        }
        characterSpacing = 0
        lineHeight = fontSize * max(0.8, appearance.textLineSpacing)
        strokeWidth = appearance.textWeight == .bold ? -2 : 0
        alignment = appearance.textAlignment
        self.padding = max(0, padding ?? appearance.textBackgroundPadding)
    }

    public func viewMetrics(sourceUnitsPerViewPoint: Double) -> ViewMetrics {
        let scale = sourceUnitsPerViewPoint > 0 ? sourceUnitsPerViewPoint : 1
        return .init(
            fontSize: fontSize / scale,
            characterSpacing: characterSpacing / scale,
            lineHeight: lineHeight / scale
        )
    }

    public func makeAttributedString(_ text: String) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foregroundColor,
                NSAttributedString.Key(kCTKernAttributeName as String): characterSpacing,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
        if strokeWidth != 0 {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = foregroundColor
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    public func measure(
        _ text: String,
        sizing: ScreenshotTextBoxSizing,
        constrainedTo width: Double
    ) -> CGSize {
        let minimumWidth = padding * 2 + 1
        let constrainedWidth = max(minimumWidth, width)
        let maximumContentWidth = max(1, constrainedWidth - padding * 2)
        let attributed = makeAttributedString(text.isEmpty ? " " : text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let contentWidth: Double
        switch sizing {
        case .auto:
            let natural = Self.suggestedSize(
                framesetter,
                width: .greatestFiniteMagnitude
            )
            contentWidth = min(maximumContentWidth, max(1, ceil(natural.width)))
        case .fixedWidth, .fixedBox:
            contentWidth = maximumContentWidth
        }

        let measured = Self.suggestedSize(framesetter, width: contentWidth)
        let contentHeight = max(lineHeight, ceil(measured.height))
        let outerWidth = switch sizing {
        case .auto: min(constrainedWidth, ceil(contentWidth + padding * 2))
        case .fixedWidth, .fixedBox: constrainedWidth
        }
        return CGSize(
            width: outerWidth,
            height: ceil(contentHeight + padding * 2)
        )
    }

    public func contentRect(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + padding,
            y: rect.minY + padding,
            width: max(0, rect.width - padding * 2),
            height: max(0, rect.height - padding * 2)
        )
    }

    public static func fontName(for weight: ScreenshotTextWeight) -> String {
        switch weight {
        case .regular: "PingFangSC-Regular"
        case .medium: "PingFangSC-Medium"
        case .semibold, .bold: "PingFangSC-Semibold"
        }
    }

    private var ctFont: CTFont {
        CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
    }

    private static func suggestedSize(_ framesetter: CTFramesetter, width: Double) -> CGSize {
        CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
    }

    private var paragraphStyle: CTParagraphStyle {
        var textAlignment: CTTextAlignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        var lineBreakMode = CTLineBreakMode.byWordWrapping
        var minimumLineHeight = CGFloat(lineHeight)
        var maximumLineHeight = CGFloat(lineHeight)
        var lineSpacingAdjustment: CGFloat = 0
        return withUnsafePointer(to: &textAlignment) { textAlignmentPointer in
            withUnsafePointer(to: &lineBreakMode) { lineBreakModePointer in
                withUnsafePointer(to: &minimumLineHeight) { minimumLineHeightPointer in
                    withUnsafePointer(to: &maximumLineHeight) { maximumLineHeightPointer in
                        withUnsafePointer(to: &lineSpacingAdjustment) { lineSpacingAdjustmentPointer in
                            var settings = [
                                CTParagraphStyleSetting(
                                    spec: .alignment,
                                    valueSize: MemoryLayout<CTTextAlignment>.size,
                                    value: UnsafeRawPointer(textAlignmentPointer)
                                ),
                                CTParagraphStyleSetting(
                                    spec: .lineBreakMode,
                                    valueSize: MemoryLayout<CTLineBreakMode>.size,
                                    value: UnsafeRawPointer(lineBreakModePointer)
                                ),
                                CTParagraphStyleSetting(
                                    spec: .minimumLineHeight,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: UnsafeRawPointer(minimumLineHeightPointer)
                                ),
                                CTParagraphStyleSetting(
                                    spec: .maximumLineHeight,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: UnsafeRawPointer(maximumLineHeightPointer)
                                ),
                                CTParagraphStyleSetting(
                                    spec: .lineSpacingAdjustment,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: UnsafeRawPointer(lineSpacingAdjustmentPointer)
                                ),
                            ]
                            return CTParagraphStyleCreate(&settings, settings.count)
                        }
                    }
                }
            }
        }
    }
}

public struct ScreenshotElement: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ScreenshotElementKind
    public var geometry: ScreenshotElementGeometry
    public var text: String?
    public var textBoxSizing: ScreenshotTextBoxSizing?
    public var stepNumber: Int?
    public var watermark: ScreenshotWatermarkInstance?
    public var appearance: ScreenshotElementAppearance

    public init(
        id: UUID = UUID(),
        kind: ScreenshotElementKind,
        geometry: ScreenshotElementGeometry,
        text: String? = nil,
        textBoxSizing: ScreenshotTextBoxSizing? = nil,
        stepNumber: Int? = nil,
        watermark: ScreenshotWatermarkInstance? = nil,
        appearance: ScreenshotElementAppearance? = nil
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.text = text
        self.textBoxSizing = [.text, .callout, .step].contains(kind) ? (textBoxSizing ?? .auto) : nil
        self.stepNumber = kind == .step ? stepNumber.flatMap { $0 > 0 ? $0 : nil } : nil
        self.watermark = kind == .watermark ? watermark : nil
        self.appearance = appearance ?? .defaultValue(for: kind.tool)
    }
}

public struct ScreenshotStepNumberChange: Equatable, Sendable {
    public let elementID: UUID
    public let oldNumber: Int
    public let newNumber: Int

    public init(elementID: UUID, oldNumber: Int, newNumber: Int) {
        self.elementID = elementID
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct ScreenshotStepNumberTransaction: Equatable, Sendable {
    public let changes: [ScreenshotStepNumberChange]

    public init(changes: [ScreenshotStepNumberChange]) {
        self.changes = changes
    }

    public func applying(to elements: [ScreenshotElement]) -> [ScreenshotElement] {
        var updates: [UUID: ScreenshotStepNumberChange] = [:]
        for change in changes { updates[change.elementID] = change }
        return elements.map { element in
            guard let change = updates[element.id],
                  element.kind == .step,
                  element.stepNumber == change.oldNumber else { return element }
            var updated = element
            updated.stepNumber = change.newNumber
            return updated
        }
    }
}

public enum ScreenshotStepNumbering {
    public static func nextNumber(in elements: [ScreenshotElement]) -> Int {
        let maximum = elements.lazy
            .filter { $0.kind == .step }
            .compactMap(\.stepNumber)
            .max() ?? 0
        return maximum == Int.max ? Int.max : maximum + 1
    }

    public static func numberForDuplicate(in elements: [ScreenshotElement]) -> Int {
        nextNumber(in: elements)
    }

    public static func transaction(
        moving elementID: UUID,
        to requestedNumber: Int,
        in elements: [ScreenshotElement]
    ) -> ScreenshotStepNumberTransaction? {
        guard requestedNumber > 0,
              let source = elements.first(where: { $0.id == elementID && $0.kind == .step }),
              let oldNumber = source.stepNumber else { return nil }
        guard requestedNumber != oldNumber else {
            return ScreenshotStepNumberTransaction(changes: [])
        }

        let occupied = elements.contains {
            $0.id != elementID && $0.kind == .step && $0.stepNumber == requestedNumber
        }
        var changes = [ScreenshotStepNumberChange]()
        for element in elements where element.kind == .step {
            guard let number = element.stepNumber else { continue }
            let newNumber: Int
            if element.id == elementID {
                newNumber = requestedNumber
            } else if occupied, requestedNumber < oldNumber,
                      number >= requestedNumber, number < oldNumber {
                newNumber = number + 1
            } else if occupied, requestedNumber > oldNumber,
                      number > oldNumber, number <= requestedNumber {
                newNumber = number - 1
            } else {
                continue
            }
            if newNumber != number {
                changes.append(.init(elementID: element.id, oldNumber: number, newNumber: newNumber))
            }
        }
        return ScreenshotStepNumberTransaction(changes: changes)
    }
}

public enum ScreenshotStrokeSmoothing {
    public static func points(
        for points: [ScreenshotPixelPoint],
        amount: Double
    ) -> [ScreenshotPixelPoint] {
        guard points.count > 2 else { return points }
        let amount = min(max(amount, 0), 1)
        guard amount > 0 else { return points }

        var result = points
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let point = points[index]
            let next = points[index + 1]
            let neighborMidpoint = ScreenshotPixelPoint(
                x: (previous.x + next.x) / 2,
                y: (previous.y + next.y) / 2
            )
            result[index] = ScreenshotPixelPoint(
                x: point.x + (neighborMidpoint.x - point.x) * amount * 0.5,
                y: point.y + (neighborMidpoint.y - point.y) * amount * 0.5
            )
        }
        return result
    }
}

public struct ScreenshotSceneSnapshot: Codable, Equatable, Sendable {
    public var cropRect: ScreenshotPixelRect
    public var elements: [ScreenshotElement]
    public var outputAppearance: ScreenshotOutputAppearance

    public init(
        cropRect: ScreenshotPixelRect,
        elements: [ScreenshotElement] = [],
        outputAppearance: ScreenshotOutputAppearance = .init()
    ) {
        self.cropRect = cropRect
        self.elements = elements
        self.outputAppearance = outputAppearance
    }

    private enum CodingKeys: String, CodingKey { case cropRect, elements, outputAppearance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cropRect = try container.decode(ScreenshotPixelRect.self, forKey: .cropRect)
        elements = try container.decodeIfPresent([ScreenshotElement].self, forKey: .elements) ?? []
        outputAppearance = try container.decodeIfPresent(
            ScreenshotOutputAppearance.self,
            forKey: .outputAppearance
        ) ?? .init()
    }
}

public struct ScreenshotSceneRevision: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct ScreenshotSceneRenderSnapshot: Equatable, Sendable {
    public let cropRect: ScreenshotPixelRect
    /// The document crop that constrains document-wide overlays while a
    /// larger editor preview is being rendered. Final output snapshots leave
    /// this nil so the output crop remains the single source of truth.
    public let watermarkClipRect: ScreenshotPixelRect?
    public let elements: [ScreenshotElement]
    public let outputAppearance: ScreenshotOutputAppearance

    public init(
        cropRect: ScreenshotPixelRect,
        watermarkClipRect: ScreenshotPixelRect? = nil,
        elements: [ScreenshotElement] = [],
        outputAppearance: ScreenshotOutputAppearance = .init()
    ) {
        self.cropRect = cropRect
        self.watermarkClipRect = watermarkClipRect
        self.elements = elements
        self.outputAppearance = outputAppearance
    }

    public init(_ snapshot: ScreenshotSceneSnapshot) {
        self.init(
            cropRect: snapshot.cropRect,
            watermarkClipRect: nil,
            elements: snapshot.elements,
            outputAppearance: snapshot.outputAppearance
        )
    }
}

public final class ScreenshotRenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }
}

public struct ScreenshotSceneRenderRequest: Sendable {
    public let revision: ScreenshotSceneRevision
    public let snapshot: ScreenshotSceneRenderSnapshot
    public let cancellation: ScreenshotRenderCancellation

    public init(
        revision: ScreenshotSceneRevision,
        snapshot: ScreenshotSceneRenderSnapshot,
        cancellation: ScreenshotRenderCancellation = .init()
    ) {
        self.revision = revision
        self.snapshot = snapshot
        self.cancellation = cancellation
    }
}

public final class ScreenshotSceneDocument {
    public let sourceContext: ScreenshotSourceContext
    public private(set) var snapshot: ScreenshotSceneSnapshot
    public private(set) var revision: UInt64
    public private(set) var renderRevision: ScreenshotSceneRevision

    private var draftSnapshot: ScreenshotSceneSnapshot?
    private var undoStack: [ScreenshotSceneSnapshot] = []
    private var redoStack: [ScreenshotSceneSnapshot] = []

    public init(
        sourceContext: ScreenshotSourceContext,
        snapshot: ScreenshotSceneSnapshot? = nil,
        revision: UInt64 = 0
    ) {
        self.sourceContext = sourceContext
        self.snapshot = snapshot ?? ScreenshotSceneSnapshot(cropRect: sourceContext.sourceBounds)
        self.revision = revision
        self.renderRevision = .init(rawValue: revision)
    }

    public var presentedSnapshot: ScreenshotSceneSnapshot { draftSnapshot ?? snapshot }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func makeRenderRequest() -> ScreenshotSceneRenderRequest {
        ScreenshotSceneRenderRequest(
            revision: renderRevision,
            snapshot: ScreenshotSceneRenderSnapshot(presentedSnapshot)
        )
    }

    public func isRenderRequestCurrent(_ request: ScreenshotSceneRenderRequest) -> Bool {
        request.revision == renderRevision && !request.cancellation.isCancelled
    }

    public var visibleElements: [ScreenshotElement] {
        let presented = presentedSnapshot
        return presented.elements.filter {
            $0.kind == .watermark || ScreenshotGeometry.intersects($0, rect: presented.cropRect)
        }
    }

    @discardableResult
    public func add(_ element: ScreenshotElement) -> Bool {
        guard !snapshot.elements.contains(where: { $0.id == element.id }) else { return false }
        return mutate { snapshot in
            if element.kind == .watermark {
                snapshot.elements.removeAll { $0.kind == .watermark }
            }
            snapshot.elements.append(element)
        }
    }

    @discardableResult
    public func updateElement(id: UUID, _ update: (inout ScreenshotElement) -> Void) -> Bool {
        guard let index = snapshot.elements.firstIndex(where: { $0.id == id }) else { return false }
        return mutate { update(&$0.elements[index]) }
    }

    @discardableResult
    public func removeElement(id: UUID) -> Bool {
        guard let index = snapshot.elements.firstIndex(where: { $0.id == id }) else { return false }
        return mutate { $0.elements.remove(at: index) }
    }

    /// Replaces one element with an ordered set as a single undoable document mutation.
    @discardableResult
    public func replaceElement(id: UUID, with replacements: [ScreenshotElement]) -> Bool {
        guard let index = snapshot.elements.firstIndex(where: { $0.id == id }),
              replacements.allSatisfy({ replacement in
                  replacement.id == id || !snapshot.elements.contains(where: { $0.id == replacement.id })
              }),
              Set(replacements.map(\.id)).count == replacements.count else { return false }
        return mutate { snapshot in
            snapshot.elements.replaceSubrange(index...index, with: replacements)
        }
    }

    @discardableResult
    public func duplicateElement(
        id: UUID,
        offsetX: Double = 12,
        offsetY: Double = 12
    ) -> ScreenshotElement? {
        guard let source = snapshot.elements.first(where: { $0.id == id }),
              source.kind != .watermark else { return nil }
        let duplicate = ScreenshotElement(
            kind: source.kind,
            geometry: ScreenshotGeometry.translateWithinBounds(
                source,
                dx: offsetX,
                dy: offsetY,
                bounds: sourceContext.sourceBounds
            ),
            text: source.text,
            textBoxSizing: source.textBoxSizing,
            stepNumber: source.kind == .step
                ? ScreenshotStepNumbering.numberForDuplicate(in: snapshot.elements)
                : nil,
            watermark: source.watermark,
            appearance: source.appearance
        )
        guard mutate({ $0.elements.append(duplicate) }) else { return nil }
        return duplicate
    }

    @discardableResult
    public func moveElementForward(id: UUID) -> Bool {
        guard let index = snapshot.elements.firstIndex(where: { $0.id == id }),
              index < snapshot.elements.index(before: snapshot.elements.endIndex) else { return false }
        return mutate { $0.elements.swapAt(index, index + 1) }
    }

    @discardableResult
    public func moveElementBackward(id: UUID) -> Bool {
        guard let index = snapshot.elements.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        return mutate { $0.elements.swapAt(index, index - 1) }
    }

    @discardableResult
    public func setCropRect(_ cropRect: ScreenshotPixelRect) -> Bool {
        guard let clamped = normalizedCropRect(cropRect) else { return false }
        return mutate { $0.cropRect = clamped }
    }

    @discardableResult
    public func setOutputAppearance(_ appearance: ScreenshotOutputAppearance) -> Bool {
        mutate { $0.outputAppearance = appearance }
    }

    @discardableResult
    public func applyStepNumberTransaction(_ transaction: ScreenshotStepNumberTransaction) -> Bool {
        guard !transaction.changes.isEmpty else { return true }
        return mutate { snapshot in
            snapshot.elements = transaction.applying(to: snapshot.elements)
        }
    }

    @discardableResult
    public func beginInteraction() -> Bool {
        guard draftSnapshot == nil else { return false }
        draftSnapshot = snapshot
        return true
    }

    @discardableResult
    public func updateInteraction(_ update: (inout ScreenshotSceneSnapshot) -> Void) -> Bool {
        guard var draft = draftSnapshot else { return false }
        update(&draft)
        guard let normalized = normalizedSnapshot(draft) else { return false }
        guard normalized != draftSnapshot else { return true }
        draftSnapshot = normalized
        advanceRenderRevision()
        return true
    }

    @discardableResult
    public func commitInteraction() -> Bool {
        guard let draft = draftSnapshot,
              let normalized = normalizedSnapshot(draft) else { return false }
        draftSnapshot = nil
        advanceRenderRevision()
        guard normalized != snapshot else { return true }
        recordCurrentSnapshot()
        snapshot = normalized
        revision &+= 1
        return true
    }

    @discardableResult
    public func cancelInteraction() -> Bool {
        guard draftSnapshot != nil else { return false }
        draftSnapshot = nil
        advanceRenderRevision()
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        guard draftSnapshot == nil, let previous = undoStack.popLast() else { return false }
        redoStack.append(snapshot)
        snapshot = previous
        revision &+= 1
        advanceRenderRevision()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard draftSnapshot == nil, let next = redoStack.popLast() else { return false }
        undoStack.append(snapshot)
        snapshot = next
        revision &+= 1
        advanceRenderRevision()
        return true
    }

    private func mutate(_ mutation: (inout ScreenshotSceneSnapshot) -> Void) -> Bool {
        guard draftSnapshot == nil else { return false }
        var next = snapshot
        mutation(&next)
        guard let normalized = normalizedSnapshot(next), normalized != snapshot else { return false }
        recordCurrentSnapshot()
        snapshot = normalized
        revision &+= 1
        advanceRenderRevision()
        return true
    }

    private func advanceRenderRevision() {
        renderRevision = .init(rawValue: renderRevision.rawValue &+ 1)
    }

    private func recordCurrentSnapshot() {
        undoStack.append(snapshot)
        redoStack.removeAll(keepingCapacity: true)
    }

    private func normalizedSnapshot(_ candidate: ScreenshotSceneSnapshot) -> ScreenshotSceneSnapshot? {
        var normalized = candidate
        guard let cropRect = normalizedCropRect(candidate.cropRect) else { return nil }
        normalized.cropRect = cropRect
        normalized.elements = normalized.elements.map { element in
            guard element.kind == .magnifier,
                  let layout = ScreenshotMagnifierResolvedLayout(
                      element: element,
                      constrainedTo: cropRect
                  ) else { return element }
            var next = element
            next.geometry = .magnifier(center: layout.center)
            next.appearance.magnifierDiameter = layout.diameter
            return next
        }
        if let lastWatermarkIndex = normalized.elements.lastIndex(where: { $0.kind == .watermark }) {
            normalized.elements = normalized.elements.enumerated().compactMap { index, element in
                element.kind != .watermark || index == lastWatermarkIndex ? element : nil
            }
        }
        return normalized
    }

    private func normalizedCropRect(_ candidate: ScreenshotPixelRect) -> ScreenshotPixelRect? {
        let bounds = sourceContext.sourceBounds
        let (candidateRight, candidateXOverflow) = candidate.x.addingReportingOverflow(candidate.width)
        let (candidateBottom, candidateYOverflow) = candidate.y.addingReportingOverflow(candidate.height)
        let (boundsRight, boundsXOverflow) = bounds.x.addingReportingOverflow(bounds.width)
        let (boundsBottom, boundsYOverflow) = bounds.y.addingReportingOverflow(bounds.height)
        guard !candidateXOverflow,
              !candidateYOverflow,
              !boundsXOverflow,
              !boundsYOverflow else { return nil }

        let left = max(min(candidate.x, candidateRight), min(bounds.x, boundsRight))
        let top = max(min(candidate.y, candidateBottom), min(bounds.y, boundsBottom))
        let right = min(max(candidate.x, candidateRight), max(bounds.x, boundsRight))
        let bottom = min(max(candidate.y, candidateBottom), max(bounds.y, boundsBottom))
        guard right > left, bottom > top else { return nil }
        return .init(x: left, y: top, width: right - left, height: bottom - top)
    }
}
