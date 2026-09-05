import CoreGraphics
import CoreText
import Foundation

/// Shared single-line optical layout for counter and step badges.
public struct ScreenshotBadgeTextLayout {
    public let text: String
    public let fontName: String
    public let fontSize: Double
    public let opticalBounds: CGRect

    public init(text: String, fontSize: Double, weight: ScreenshotTextWeight = .bold) {
        self.text = text
        self.fontName = ScreenshotTextLayout.fontName(for: weight)
        self.fontSize = max(1, fontSize.isFinite ? fontSize : 1)
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(self.fontSize), nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .excludeTypographicLeading])
        if bounds.isNull || bounds.isEmpty {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            bounds = CGRect(x: 0, y: -self.fontSize * 0.22, width: width, height: self.fontSize)
        }
        opticalBounds = bounds
    }

    /// Core Text baseline origin in a bottom-left coordinate system.
    public func baselineOrigin(inTopLeftRect rect: CGRect, canvasHeight: Double) -> CGPoint {
        CGPoint(
            x: rect.midX - opticalBounds.midX,
            y: canvasHeight - rect.midY - opticalBounds.midY
        )
    }

    public func makeLine(color: CGColor) -> CTLine {
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
        return CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
        ))
    }
}
