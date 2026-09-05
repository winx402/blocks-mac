import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

public enum ScreenshotRenderError: Error, Equatable {
    case bitmapContextCreationFailed
    case invalidCrop
    case imageCreationFailed
    case filterCreationFailed
    case cancelled
}

public enum ScreenshotImageCompositeBlendMode {
    case normal
    case copy
}

public struct ScreenshotImageCompositeTile {
    public let image: CGImage
    public let destination: ScreenshotPixelRect
    public let blendMode: ScreenshotImageCompositeBlendMode

    public init(
        image: CGImage,
        destination: ScreenshotPixelRect,
        blendMode: ScreenshotImageCompositeBlendMode = .normal
    ) {
        self.image = image
        self.destination = destination
        self.blendMode = blendMode
    }
}

public enum ScreenshotImageCompositorError: Error, Equatable {
    case invalidSize
    case bitmapContextCreationFailed
    case imageCreationFailed
}

public enum ScreenshotImageCompositor {
    public static func compose(
        size: ScreenshotPixelSize,
        tiles: [ScreenshotImageCompositeTile]
    ) throws -> CGImage {
        guard size.width > 0, size.height > 0 else {
            throw ScreenshotImageCompositorError.invalidSize
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: size.width,
                  height: size.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotImageCompositorError.bitmapContextCreationFailed
        }

        context.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        for tile in tiles {
            let destination = CGRect(
                x: tile.destination.x,
                y: size.height - tile.destination.y - tile.destination.height,
                width: tile.destination.width,
                height: tile.destination.height
            )
            context.saveGState()
            context.setBlendMode(tile.blendMode == .copy ? .copy : .normal)
            context.interpolationQuality = tile.image.width == tile.destination.width ? .none : .high
            context.draw(tile.image, in: destination)
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            throw ScreenshotImageCompositorError.imageCreationFailed
        }
        return image
    }
}

struct ScreenshotRenderPlan: Equatable {
    let outputRect: CGRect
    let workingRect: CGRect
    let elementIndexes: [Int]
    let effectBoundaryCount: Int
    let vectorBatchCount: Int
}

private struct ScreenshotMagnifierRenderGeometry {
    let lensRect: CGRect
    let sampleRect: CGRect
}

private enum ScreenshotMagnifierRenderMetrics {
    static let shadowOffset: CGFloat = 3
    static let shadowBlur: CGFloat = 10
    static let shadowOutset = shadowOffset + shadowBlur
}

public struct ScreenshotRenderer {
    private let ciContext: CIContext

    public init(ciContext: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.ciContext = ciContext
    }

    public func render(
        sourceContext: ScreenshotSourceContext,
        snapshot: ScreenshotSceneSnapshot
    ) throws -> CGImage {
        try render(
            sourceContext: sourceContext,
            request: ScreenshotSceneRenderRequest(
                revision: .init(rawValue: 0),
                snapshot: ScreenshotSceneRenderSnapshot(snapshot)
            )
        )
    }

    public func render(
        sourceContext: ScreenshotSourceContext,
        request: ScreenshotSceneRenderRequest
    ) throws -> CGImage {
        let sourceBounds = sourceContext.sourceBounds
        return try render(
            source: sourceContext.compositeSource,
            snapshot: request.snapshot,
            cancellation: request.cancellation,
            sourceOrigin: CGPoint(x: sourceBounds.x, y: sourceBounds.y)
        )
    }

    public func render(source: CGImage, snapshot: ScreenshotSceneSnapshot) throws -> CGImage {
        try render(
            source: source,
            snapshot: ScreenshotSceneRenderSnapshot(snapshot),
            cancellation: .init(),
            sourceOrigin: .zero
        )
    }

    public func render(source: CGImage, request: ScreenshotSceneRenderRequest) throws -> CGImage {
        try render(
            source: source,
            snapshot: request.snapshot,
            cancellation: request.cancellation,
            sourceOrigin: .zero
        )
    }

    func makeRenderPlan(
        sourceWidth: Int,
        sourceHeight: Int,
        snapshot: ScreenshotSceneSnapshot
    ) throws -> ScreenshotRenderPlan {
        try makeRenderPlan(
            sourceBounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
            snapshot: ScreenshotSceneRenderSnapshot(snapshot)
        )
    }

    private func render(
        source: CGImage,
        snapshot: ScreenshotSceneRenderSnapshot,
        cancellation: ScreenshotRenderCancellation,
        sourceOrigin: CGPoint
    ) throws -> CGImage {
        try checkCancellation(cancellation)
        let plan = try makeRenderPlan(
            sourceBounds: CGRect(
                x: sourceOrigin.x,
                y: sourceOrigin.y,
                width: CGFloat(source.width),
                height: CGFloat(source.height)
            ),
            snapshot: snapshot
        )
        let localWorkingRect = plan.workingRect.offsetBy(dx: -sourceOrigin.x, dy: -sourceOrigin.y)
        guard let sourceRegion = source.cropping(to: localWorkingRect) else {
            throw ScreenshotRenderError.invalidCrop
        }
        let dx = -plan.workingRect.minX
        let dy = -plan.workingRect.minY
        let localElements = plan.elementIndexes.map { index in
            let element = snapshot.elements[index]
            var localElement = element
            localElement.geometry = ScreenshotGeometry.translate(element.geometry, dx: dx, dy: dy)
            return localElement
        }
        let width = Int(plan.workingRect.width)
        let height = Int(plan.workingRect.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let localOutputRect = ScreenshotPixelRect(
            x: Int(plan.outputRect.minX - plan.workingRect.minX),
            y: Int(plan.outputRect.minY - plan.workingRect.minY),
            width: Int(plan.outputRect.width),
            height: Int(plan.outputRect.height)
        )
        let watermarkRect = snapshot.watermarkClipRect ?? snapshot.cropRect
        let localWatermarkRect = ScreenshotPixelRect(
            x: Int(CGFloat(watermarkRect.x) - plan.workingRect.minX),
            y: Int(CGFloat(watermarkRect.y) - plan.workingRect.minY),
            width: watermarkRect.width,
            height: watermarkRect.height
        )
        var context = try bitmapContext(width: width, height: height, opaque: false)
        context.draw(sourceRegion, in: bounds)

        for element in localElements {
            try checkCancellation(cancellation)
            switch element.kind {
            case .blur, .pixelate:
                guard let current = context.makeImage() else {
                    throw ScreenshotRenderError.imageCreationFailed
                }
                let effected = try applyEffect(image: current, element: element)
                try checkCancellation(cancellation)
                context = try bitmapContext(width: width, height: height, opaque: false)
                context.draw(effected, in: bounds)
            case .redact where element.appearance.redactMode == .securePixelate:
                guard let current = context.makeImage() else { throw ScreenshotRenderError.imageCreationFailed }
                let effected = try applyEffect(image: current, element: element)
                context = try bitmapContext(width: width, height: height, opaque: false)
                context.draw(effected, in: bounds)
            default:
                break
            }
        }

        let spotlights = localElements.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            try drawSpotlightMask(spotlights, in: context, canvasHeight: height)
        }

        if let element = localElements.last(where: { $0.kind == .watermark }) {
            try checkCancellation(cancellation)
            drawWatermarkElement(
                element,
                in: context,
                canvasHeight: height,
                outputRect: localWatermarkRect
            )
        }

        for element in localElements where element.kind != .watermark {
            try checkCancellation(cancellation)
            switch element.kind {
            case .blur, .pixelate, .spotlight:
                break
            case .redact where element.appearance.redactMode == .securePixelate:
                break
            case .magnifier:
                guard let current = context.makeImage() else { throw ScreenshotRenderError.imageCreationFailed }
                context = try drawMagnifier(
                    over: current,
                    element: element,
                    constrainedTo: localOutputRect
                )
            default:
                draw(element, in: context, canvasHeight: height)
            }
        }

        try checkCancellation(cancellation)
        guard let rendered = context.makeImage() else {
            throw ScreenshotRenderError.imageCreationFailed
        }
        return try ScreenshotOutputProcessor.process(
            image: rendered,
            imageRect: .init(
                x: Int(plan.workingRect.minX),
                y: Int(plan.workingRect.minY),
                width: Int(plan.workingRect.width),
                height: Int(plan.workingRect.height)
            ),
            outputRect: .init(
                x: Int(plan.outputRect.minX),
                y: Int(plan.outputRect.minY),
                width: Int(plan.outputRect.width),
                height: Int(plan.outputRect.height)
            ),
            appearance: snapshot.outputAppearance
        )
    }

    private func draw(_ element: ScreenshotElement, in context: CGContext, canvasHeight: Int) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(canvasHeight))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAlpha(clampUnit(element.appearance.opacity))
        configureStroke(element.appearance, in: context)

        switch element.kind {
        case .arrow, .line:
            drawLineElement(element, in: context)
        case .rectangle:
            drawShapeElement(element, ellipse: false, in: context)
        case .ellipse:
            drawShapeElement(element, ellipse: true, in: context)
        case .freehand:
            drawPathElement(element, in: context)
        case .text:
            drawTextElement(element, in: context, canvasHeight: canvasHeight)
        case .highlight:
            drawHighlightElement(element, in: context)
        case .blur, .pixelate:
            break
        case .counter:
            drawCounterElement(element, in: context, canvasHeight: canvasHeight)
        case .step:
            drawStepElement(element, in: context, canvasHeight: canvasHeight)
        case .callout:
            drawCalloutElement(element, in: context, canvasHeight: canvasHeight)
        case .spotlight:
            break
        case .redact:
            if element.appearance.redactMode == .solid { drawRedactElement(element, in: context) }
        case .magnifier:
            break
        case .watermark:
            break
        }

        context.restoreGState()
    }

    private func drawLineElement(_ element: ScreenshotElement, in context: CGContext) {
        guard case let .line(start, end) = element.geometry else { return }
        let appearance = ScreenshotLineAppearance(
            color: element.appearance.strokeColor,
            width: element.appearance.lineWidth,
            opacity: element.appearance.opacity,
            startEnding: element.appearance.startEnding,
            endEnding: element.appearance.endEnding,
            pattern: element.appearance.linePattern,
            curvature: element.appearance.curvature,
            arrowHeadSize: element.appearance.arrowHeadSize
        )
        let control = lineControlPoint(start: start, end: end, curvature: appearance.curvature)
        drawLine(
            from: start,
            to: end,
            control: control,
            appearance: appearance,
            in: context
        )
    }

    private func drawLine(
        from start: ScreenshotPixelPoint,
        to end: ScreenshotPixelPoint,
        control: ScreenshotPixelPoint,
        appearance: ScreenshotLineAppearance,
        in context: CGContext
    ) {
        let wrappedAppearance = ScreenshotElementAppearance.line(appearance)
        context.saveGState()
        context.setAlpha(clampUnit(appearance.opacity))
        configureStroke(wrappedAppearance, in: context)
        context.move(to: cgPoint(start))
        context.addQuadCurve(to: cgPoint(end), control: cgPoint(control))
        context.strokePath()
        drawEnding(appearance.startEnding, at: start, awayFrom: control, appearance: wrappedAppearance, in: context)
        drawEnding(appearance.endEnding, at: end, awayFrom: control, appearance: wrappedAppearance, in: context)
        context.restoreGState()
    }

    private func drawEnding(
        _ ending: ScreenshotLineEnding,
        at tip: ScreenshotPixelPoint,
        awayFrom other: ScreenshotPixelPoint,
        appearance: ScreenshotElementAppearance,
        in context: CGContext
    ) {
        guard ending != .none else { return }
        let angle = atan2(tip.y - other.y, tip.x - other.x)
        let length = max(8, appearance.lineWidth * 4 * appearance.arrowHeadSize)
        let spread = Double.pi / 7
        let first = ScreenshotPixelPoint(
            x: tip.x - length * cos(angle - spread),
            y: tip.y - length * sin(angle - spread)
        )
        let second = ScreenshotPixelPoint(
            x: tip.x - length * cos(angle + spread),
            y: tip.y - length * sin(angle + spread)
        )
        switch ending {
        case .none:
            break
        case .openArrow:
            context.move(to: cgPoint(first))
            context.addLine(to: cgPoint(tip))
            context.addLine(to: cgPoint(second))
            context.strokePath()
        case .filledArrow:
            setFillColor(appearance.strokeColor, in: context)
            context.move(to: cgPoint(tip))
            context.addLine(to: cgPoint(first))
            context.addLine(to: cgPoint(second))
            context.closePath()
            context.fillPath()
        case .circle:
            setFillColor(appearance.strokeColor, in: context)
            let diameter = max(6, appearance.lineWidth * 2.5 * appearance.arrowHeadSize)
            context.fillEllipse(in: CGRect(
                x: tip.x - diameter / 2,
                y: tip.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
    }

    private func drawShapeElement(_ element: ScreenshotElement, ellipse: Bool, in context: CGContext) {
        guard case let .rect(pixelRect) = element.geometry else { return }
        let rect = cgRect(pixelRect)
        let path: CGPath
        if ellipse {
            path = CGPath(ellipseIn: rect, transform: nil)
        } else if element.appearance.cornerRadius > 0 {
            path = CGPath(
                roundedRect: rect,
                cornerWidth: min(element.appearance.cornerRadius, rect.width / 2),
                cornerHeight: min(element.appearance.cornerRadius, rect.height / 2),
                transform: nil
            )
        } else {
            path = CGPath(rect: rect, transform: nil)
        }
        if let fillColor = element.appearance.fillColor {
            let color = ScreenshotColor(
                red: fillColor.red,
                green: fillColor.green,
                blue: fillColor.blue,
                alpha: fillColor.alpha * element.appearance.fillOpacity
            )
            setFillColor(color, in: context)
            context.addPath(path)
            context.fillPath()
        }
        setStrokeColor(element.appearance.strokeColor, in: context)
        context.addPath(path)
        context.strokePath()
    }

    private func drawPathElement(_ element: ScreenshotElement, in context: CGContext) {
        guard case let .path(rawPoints) = element.geometry else { return }
        let points = ScreenshotStrokeSmoothing.points(
            for: rawPoints,
            amount: element.appearance.smoothing
        )
        guard let first = points.first else { return }
        context.move(to: cgPoint(first))
        if points.count == 1 {
            context.addLine(to: cgPoint(first))
        } else if element.appearance.smoothing > 0, points.count > 2 {
            for index in 1..<(points.count - 1) {
                let point = points[index]
                let next = points[index + 1]
                let midpoint = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
                context.addQuadCurve(to: midpoint, control: cgPoint(point))
            }
            if let last = points.last { context.addLine(to: cgPoint(last)) }
        } else {
            for point in points.dropFirst() { context.addLine(to: cgPoint(point)) }
        }
        context.strokePath()
    }

    private func drawHighlightElement(_ element: ScreenshotElement, in context: CGContext) {
        switch (element.appearance.highlightMode, element.geometry) {
        case let (.freehand, .path(points)):
            drawPathElement(
                ScreenshotElement(kind: .freehand, geometry: .path(points), appearance: element.appearance),
                in: context
            )
        case let (_, .rect(rect)):
            setFillColor(element.appearance.strokeColor, in: context)
            context.fill(cgRect(rect))
        default:
            break
        }
    }

    private func drawTextElement(_ element: ScreenshotElement, in context: CGContext, canvasHeight: Int) {
        guard case let .rect(pixelRect) = element.geometry else { return }
        let rect = cgRect(pixelRect)
        let layout = ScreenshotTextLayout(appearance: element.appearance)
        // Text colors already include element opacity so CoreText and the editor share one alpha contract.
        context.setAlpha(1)
        if case let .text(appearance) = element.appearance.payload,
           layout.backgroundColor != nil || appearance.backgroundBorderColor != nil {
            let radius = min(max(0, appearance.backgroundCornerRadius), min(rect.width, rect.height) / 2)
            let backgroundPath = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            if let background = layout.backgroundColor {
                context.setFillColor(background)
                context.addPath(backgroundPath)
                context.fillPath()
            }
            if let border = appearance.backgroundBorderColor,
               appearance.backgroundBorderWidth > 0 {
                context.setStrokeColor(
                    ScreenshotResolvedColor(border, opacity: appearance.opacity).cgColor
                )
                context.setLineWidth(appearance.backgroundBorderWidth)
                context.addPath(backgroundPath)
                context.strokePath()
            }
        } else if let background = layout.backgroundColor {
            context.setFillColor(background)
            context.fill(rect)
        }
        guard let text = element.text, !text.isEmpty else { return }
        let contentRect = layout.contentRect(in: rect)
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        let attributed = layout.makeAttributedString(text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(
            x: contentRect.minX,
            y: CGFloat(canvasHeight) - contentRect.maxY,
            width: contentRect.width,
            height: contentRect.height
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            CGPath(rect: textRect, transform: nil),
            nil
        )

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(canvasHeight))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.clip(to: textRect)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawCounterElement(_ element: ScreenshotElement, in context: CGContext, canvasHeight: Int) {
        guard case let .counter(center) = element.geometry,
              case let .counter(value) = element.appearance.payload else { return }
        let size = max(16, value.size)
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let path = value.shape == .circle
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(roundedRect: rect, cornerWidth: size * 0.28, cornerHeight: size * 0.28, transform: nil)
        setFillColor(value.fillColor, in: context)
        context.addPath(path)
        context.fillPath()
        setStrokeColor(value.borderColor, in: context)
        context.setLineWidth(max(0, value.borderWidth))
        context.addPath(path)
        context.strokePath()
        drawBadgeText(
            element.text ?? "1",
            in: rect,
            fontSize: size * 0.46,
            color: value.textColor,
            opacity: value.opacity,
            context: context,
            canvasHeight: canvasHeight
        )
    }

    private func drawStepElement(_ element: ScreenshotElement, in context: CGContext, canvasHeight: Int) {
        guard case let .step(value) = element.appearance.payload,
              let layout = ScreenshotStepResolvedLayout(element: element) else { return }
        let hasNoteText = !(element.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let badgeSize = layout.badgeDiameter
        let badgeRect = CGRect(
            x: layout.badgeCenter.x - badgeSize / 2,
            y: layout.badgeCenter.y - badgeSize / 2,
            width: badgeSize,
            height: badgeSize
        )
        let badgePath = value.badge.shape == .circle
            ? CGPath(ellipseIn: badgeRect, transform: nil)
            : CGPath(
                roundedRect: badgeRect,
                cornerWidth: badgeSize * 0.28,
                cornerHeight: badgeSize * 0.28,
                transform: nil
            )

        if hasNoteText,
           let connector = layout.connector,
           let control = layout.connectorControlPoint {
            drawLine(
                from: connector.start,
                to: connector.end,
                control: control,
                appearance: value.connector,
                in: context
            )
        }

        if hasNoteText, let noteRect = layout.noteRect {
            drawTextElement(
                ScreenshotElement(
                    kind: .text,
                    geometry: .rect(noteRect),
                    text: element.text ?? "",
                    textBoxSizing: .fixedWidth,
                    appearance: .text(value.note)
                ),
                in: context,
                canvasHeight: canvasHeight
            )
        }

        context.saveGState()
        context.setAlpha(clampUnit(value.badge.opacity))
        setFillColor(value.badgeFillColor, in: context)
        context.addPath(badgePath)
        context.fillPath()
        setStrokeColor(value.badgeBorderColor, in: context)
        context.setLineWidth(max(0, value.badgeBorderWidth))
        context.addPath(badgePath)
        context.strokePath()
        context.restoreGState()

        drawBadgeText(
            String(element.stepNumber ?? 1),
            in: badgeRect,
            fontSize: layout.badgeFontSize,
            color: value.badgeTextColor,
            opacity: value.badge.opacity,
            context: context,
            canvasHeight: canvasHeight
        )

    }

    private func drawBadgeText(
        _ text: String,
        in rect: CGRect,
        fontSize: Double,
        color: ScreenshotColor,
        opacity: Double,
        context: CGContext,
        canvasHeight: Int
    ) {
        let layout = ScreenshotBadgeTextLayout(text: text, fontSize: fontSize)
        let line = layout.makeLine(color: ScreenshotResolvedColor(color, opacity: opacity).cgColor)
        let origin = layout.baselineOrigin(inTopLeftRect: rect, canvasHeight: Double(canvasHeight))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(canvasHeight))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawWatermarkElement(
        _ element: ScreenshotElement,
        in context: CGContext,
        canvasHeight: Int,
        outputRect: ScreenshotPixelRect
    ) {
        guard let watermark = element.watermark else { return }
        let style = watermark.style
        let text = style.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, outputRect.width > 0, outputRect.height > 0 else { return }

        let fontSize = max(8, Double(outputRect.width) * style.fontSizeFraction)
        let font = CTFontCreateWithName(
            ScreenshotTextLayout.fontName(for: style.weight) as CFString,
            CGFloat(fontSize),
            nil
        )
        let color = ScreenshotResolvedColor(style.color, opacity: style.opacity).cgColor
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = max(1, CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)))
        let lineHeight = max(1, ascent + descent + leading)
        let angle = CGFloat(style.angleDegrees * .pi / 180)
        let rotatedWidth = abs(cos(angle)) * lineWidth + abs(sin(angle)) * lineHeight
        let rotatedHeight = abs(sin(angle)) * lineWidth + abs(cos(angle)) * lineHeight
        let density = CGFloat(style.density)
        let horizontalStep = max(
            fontSize * 2,
            rotatedWidth + CGFloat(fontSize) * (3.0 - density * 1.7)
        )
        let verticalStep = max(
            fontSize * 2,
            rotatedHeight + CGFloat(fontSize) * (3.2 - density * 1.9)
        )
        let topLeftBounds = cgRect(outputRect)
        let clipRect = CGRect(
            x: topLeftBounds.minX,
            y: CGFloat(canvasHeight) - topLeftBounds.maxY,
            width: topLeftBounds.width,
            height: topLeftBounds.height
        )

        context.saveGState()
        context.clip(to: clipRect)
        context.textMatrix = .identity
        var row = 0
        var y = topLeftBounds.minY - verticalStep
        while y <= topLeftBounds.maxY + verticalStep {
            let stagger = row.isMultiple(of: 2) ? 0 : horizontalStep / 2
            var x = topLeftBounds.minX - horizontalStep + stagger
            while x <= topLeftBounds.maxX + horizontalStep {
                context.saveGState()
                context.translateBy(x: x, y: CGFloat(canvasHeight) - y)
                context.rotate(by: -angle)
                context.textPosition = CGPoint(
                    x: -lineWidth / 2,
                    y: -(ascent - descent) / 2
                )
                CTLineDraw(line, context)
                context.restoreGState()
                x += horizontalStep
            }
            row += 1
            y += verticalStep
        }
        context.restoreGState()
    }

    private func drawCalloutElement(_ element: ScreenshotElement, in context: CGContext, canvasHeight: Int) {
        guard case let .callout(value) = element.appearance.payload,
              let layout = ScreenshotCalloutResolvedLayout(element: element),
              !(element.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        drawLine(
            from: layout.connector.start,
            to: layout.connector.end,
            control: layout.connectorControlPoint,
            appearance: value.connector,
            in: context
        )

        if let targetRect = layout.targetRect {
            let rect = cgRect(targetRect)
            context.saveGState()
            context.setAlpha(clampUnit(value.target.opacity))
            if let fill = value.target.fillColor,
               fill.alpha * value.target.fillOpacity > 0 {
                context.setFillColor(
                    ScreenshotResolvedColor(fill, opacity: value.target.fillOpacity).cgColor
                )
                context.fillEllipse(in: rect)
            }
            setStrokeColor(value.target.strokeColor, in: context)
            context.setLineWidth(max(0.5, value.target.strokeWidth))
            context.strokeEllipse(in: rect)
            context.restoreGState()
        }

        drawTextElement(
            ScreenshotElement(
                kind: .text,
                geometry: .rect(layout.noteRect),
                text: element.text,
                textBoxSizing: .fixedWidth,
                appearance: .text(value.note)
            ),
            in: context,
            canvasHeight: canvasHeight
        )
    }

    private func drawSpotlightMask(
        _ elements: [ScreenshotElement],
        in context: CGContext,
        canvasHeight: Int
    ) throws {
        let resolved = elements.compactMap { element -> (CGRect, ScreenshotSpotlightAppearance)? in
            guard case let .rect(pixelRect) = element.geometry,
                  case let .spotlight(appearance) = element.appearance.payload else { return nil }
            return (cgRect(pixelRect), appearance)
        }
        guard let dimIntensity = resolved.map({ clampUnit($0.1.dimIntensity) }).max(),
              dimIntensity > 0 else { return }

        let width = context.width
        let canvas = CGRect(x: 0, y: 0, width: width, height: canvasHeight)
        let overlay = try bitmapContext(width: width, height: canvasHeight, opaque: false)
        overlay.saveGState()
        overlay.translateBy(x: 0, y: CGFloat(canvasHeight))
        overlay.scaleBy(x: 1, y: -1)
        overlay.setFillColor(CGColor(gray: 0, alpha: dimIntensity))
        overlay.fill(canvas)
        overlay.restoreGState()

        let cutout = try bitmapContext(width: width, height: canvasHeight, opaque: false)

        for (focus, appearance) in resolved {
            let mask = try bitmapContext(width: width, height: canvasHeight, opaque: false)
            mask.saveGState()
            mask.translateBy(x: 0, y: CGFloat(canvasHeight))
            mask.scaleBy(x: 1, y: -1)
            mask.setFillColor(CGColor(gray: 1, alpha: 1))
            let feather = min(max(0, appearance.feather), min(focus.width, focus.height) / 2)
            let steps = min(32, max(0, Int(feather.rounded(.up))))
            if steps == 0 {
                mask.setAlpha(1)
                fillSpotlightShape(focus, shape: appearance.shape, in: mask)
            } else {
                for step in 0..<steps {
                    let inset = CGFloat(step)
                    let featherRect = focus.insetBy(dx: inset, dy: inset)
                    guard featherRect.width > 0, featherRect.height > 0 else { break }
                    mask.setAlpha(1 / CGFloat(steps - step))
                    fillSpotlightShape(featherRect, shape: appearance.shape, in: mask)
                }
                let clearRect = focus.insetBy(dx: feather, dy: feather)
                if clearRect.width > 0, clearRect.height > 0 {
                    mask.setAlpha(1)
                    fillSpotlightShape(clearRect, shape: appearance.shape, in: mask)
                }
            }
            mask.restoreGState()
            try mergeMaximumAlpha(from: mask, into: cutout)
        }
        guard let cutoutImage = cutout.makeImage() else {
            throw ScreenshotRenderError.imageCreationFailed
        }
        overlay.setBlendMode(.destinationOut)
        overlay.setAlpha(1)
        overlay.draw(cutoutImage, in: canvas)
        guard let image = overlay.makeImage() else { throw ScreenshotRenderError.imageCreationFailed }
        context.draw(image, in: canvas)
    }

    private func mergeMaximumAlpha(from source: CGContext, into destination: CGContext) throws {
        guard source.width == destination.width,
              source.height == destination.height,
              let sourceData = source.data,
              let destinationData = destination.data else {
            throw ScreenshotRenderError.imageCreationFailed
        }
        let sourceBytes = sourceData.assumingMemoryBound(to: UInt8.self)
        let destinationBytes = destinationData.assumingMemoryBound(to: UInt8.self)
        for y in 0..<source.height {
            let sourceRow = y * source.bytesPerRow
            let destinationRow = y * destination.bytesPerRow
            for x in 0..<source.width {
                let sourceIndex = sourceRow + x * 4
                let destinationIndex = destinationRow + x * 4
                let alpha = sourceBytes[sourceIndex + 3]
                guard alpha > destinationBytes[destinationIndex + 3] else { continue }
                destinationBytes[destinationIndex] = alpha
                destinationBytes[destinationIndex + 1] = alpha
                destinationBytes[destinationIndex + 2] = alpha
                destinationBytes[destinationIndex + 3] = alpha
            }
        }
    }

    private func fillSpotlightShape(
        _ rect: CGRect,
        shape: ScreenshotEffectShape,
        in context: CGContext
    ) {
        if shape == .ellipse {
            context.fillEllipse(in: rect)
        } else {
            context.fill(rect)
        }
    }

    private func drawRedactElement(_ element: ScreenshotElement, in context: CGContext) {
        guard case let .rect(rect) = element.geometry,
              case let .redact(value) = element.appearance.payload else { return }
        setFillColor(value.color, in: context)
        if value.shape == .ellipse { context.fillEllipse(in: cgRect(rect)) } else { context.fill(cgRect(rect)) }
    }

    private func drawMagnifier(
        over image: CGImage,
        element: ScreenshotElement,
        constrainedTo constraintBounds: ScreenshotPixelRect
    ) throws -> CGContext {
        guard case let .magnifier(value) = element.appearance.payload else {
            throw ScreenshotRenderError.filterCreationFailed
        }
        let context = try bitmapContext(width: image.width, height: image.height, opaque: false)
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: canvas)

        guard let geometry = magnifierRenderGeometry(
            element: element,
            constrainedTo: constraintBounds
        ) else { return context }
        let lensRect = geometry.lensRect
        let sourceRect = geometry.sampleRect
        let destinationRect = CGRect(
            x: lensRect.minX,
            y: Double(image.height) - lensRect.maxY,
            width: lensRect.width,
            height: lensRect.height
        )
        if value.shadow > 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -ScreenshotMagnifierRenderMetrics.shadowOffset),
                blur: ScreenshotMagnifierRenderMetrics.shadowBlur,
                color: CGColor(gray: 0, alpha: min(0.8, value.shadow))
            )
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillEllipse(in: destinationRect)
            context.restoreGState()
        }
        if let sample = image.cropping(to: sourceRect.integral) {
            context.saveGState()
            context.addEllipse(in: destinationRect)
            context.clip()
            context.interpolationQuality = .high
            // The opaque shadow caster above exists only to produce pixels
            // outside the lens. Replace it inside the clip so transparent
            // source pixels stay transparent instead of revealing black.
            context.setBlendMode(.copy)
            context.draw(sample, in: destinationRect)
            context.restoreGState()
        }
        setStrokeColor(value.borderColor, in: context)
        let borderWidth = min(max(0, value.borderWidth), min(destinationRect.width, destinationRect.height))
        context.setLineWidth(borderWidth)
        context.strokeEllipse(in: destinationRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
        return context
    }

    private func magnifierRenderGeometry(
        element: ScreenshotElement,
        constrainedTo canvas: ScreenshotPixelRect
    ) -> ScreenshotMagnifierRenderGeometry? {
        guard let layout = ScreenshotMagnifierResolvedLayout(element: element, constrainedTo: canvas),
              case let .magnifier(appearance) = element.appearance.payload else { return nil }
        let canvasRect = cgRect(canvas).standardized
        let lensRect = cgRect(layout.lensRect)
        let sampleSize = layout.diameter / ScreenshotMagnifierMetrics.resolvedZoom(appearance.zoom)
        let sampleRect = CGRect(
            x: min(
                max(canvasRect.minX, layout.center.x - sampleSize / 2),
                canvasRect.maxX - sampleSize
            ),
            y: min(
                max(canvasRect.minY, layout.center.y - sampleSize / 2),
                canvasRect.maxY - sampleSize
            ),
            width: sampleSize,
            height: sampleSize
        )
        return ScreenshotMagnifierRenderGeometry(lensRect: lensRect, sampleRect: sampleRect)
    }

    private func lineControlPoint(
        start: ScreenshotPixelPoint,
        end: ScreenshotPixelPoint,
        curvature: Double
    ) -> ScreenshotPixelPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return start }
        let offset = length * curvature * 0.5
        return .init(
            x: (start.x + end.x) / 2 - dy / length * offset,
            y: (start.y + end.y) / 2 + dx / length * offset
        )
    }

    private func applyEffect(image: CGImage, element: ScreenshotElement) throws -> CGImage {
        let name: String
        let inputKey: String
        switch element.kind {
        case .blur:
            name = "CIGaussianBlur"
            inputKey = kCIInputRadiusKey
        case .pixelate:
            name = "CIPixellate"
            inputKey = kCIInputScaleKey
        case .redact:
            name = "CIPixellate"
            inputKey = kCIInputScaleKey
        default:
            throw ScreenshotRenderError.filterCreationFailed
        }
        guard case let .rect(pixelRect) = element.geometry,
              let filter = CIFilter(name: name) else { throw ScreenshotRenderError.filterCreationFailed }
        let input = CIImage(cgImage: image)
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(1, element.appearance.effectIntensity), forKey: inputKey)
        if name == "CIPixellate" {
            filter.setValue(
                CIVector(
                    x: Double(pixelRect.x) + Double(pixelRect.width) / 2,
                    y: Double(image.height - pixelRect.y) - Double(pixelRect.height) / 2
                ),
                forKey: kCIInputCenterKey
            )
        }
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let filtered = ciContext.createCGImage(output, from: input.extent) else {
            throw ScreenshotRenderError.imageCreationFailed
        }

        let context = try bitmapContext(width: image.width, height: image.height, opaque: false)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        let effectRect = CGRect(
            x: pixelRect.x,
            y: image.height - pixelRect.y - pixelRect.height,
            width: pixelRect.width,
            height: pixelRect.height
        ).intersection(bounds)
        if !effectRect.isNull, effectRect.width > 0, effectRect.height > 0 {
            context.saveGState()
            if element.appearance.effectShape == .ellipse {
                context.addEllipse(in: effectRect)
                context.clip()
            } else {
                context.clip(to: effectRect)
            }
            context.setAlpha(clampUnit(element.appearance.opacity))
            context.draw(filtered, in: bounds)
            context.restoreGState()
        }
        guard let composited = context.makeImage() else { throw ScreenshotRenderError.imageCreationFailed }
        return composited
    }

    private func makeRenderPlan(
        sourceBounds: CGRect,
        snapshot: ScreenshotSceneRenderSnapshot
    ) throws -> ScreenshotRenderPlan {
        let requestedOutput = cgRect(snapshot.cropRect).integral
        let outputRect = requestedOutput.intersection(sourceBounds)
        guard !outputRect.isNull, outputRect.width > 0, outputRect.height > 0 else {
            throw ScreenshotRenderError.invalidCrop
        }

        var requiredRect = outputRect
        var requiredElements = [Bool](repeating: false, count: snapshot.elements.count)
        for index in snapshot.elements.indices.reversed() {
            let element = snapshot.elements[index]
            if case let .magnifier(appearance) = element.appearance.payload,
               let magnifier = magnifierRenderGeometry(
                   element: element,
                   constrainedTo: .init(
                       x: Int(outputRect.minX),
                       y: Int(outputRect.minY),
                       width: Int(outputRect.width),
                       height: Int(outputRect.height)
                   )
               ) {
                let shadowOutset = appearance.shadow > 0
                    ? ScreenshotMagnifierRenderMetrics.shadowOutset
                    : 0
                let renderRect = magnifier.lensRect.insetBy(
                    dx: -shadowOutset,
                    dy: -shadowOutset
                )
                let affectedRect = requiredRect.intersection(renderRect)
                guard !affectedRect.isNull, affectedRect.width > 0, affectedRect.height > 0 else { continue }
                requiredElements[index] = true
                requiredRect = requiredRect
                    .union(renderRect)
                    .union(magnifier.lensRect)
                    .union(magnifier.sampleRect)
                continue
            }
            guard let effectRect = effectRect(for: element) else { continue }
            let affectedRect = requiredRect.intersection(effectRect)
            guard !affectedRect.isNull, affectedRect.width > 0, affectedRect.height > 0 else { continue }
            requiredElements[index] = true
            let samplingRect = affectedRect.insetBy(
                dx: -effectSamplingOutset(for: element),
                dy: -effectSamplingOutset(for: element)
            )
            requiredRect = requiredRect.union(samplingRect)
        }
        let workingRect = requiredRect.integral.intersection(sourceBounds)

        for index in snapshot.elements.indices where effectRect(for: snapshot.elements[index]) == nil {
            let element = snapshot.elements[index]
            guard element.kind != .magnifier else { continue }
            requiredElements[index] = element.kind == .watermark
                || vectorRenderRect(for: element).intersects(workingRect)
        }
        let elementIndexes = requiredElements.indices.filter { requiredElements[$0] }

        var vectorBatchCount = 0
        var previousWasVector = false
        var effectBoundaryCount = 0
        for index in elementIndexes {
            let element = snapshot.elements[index]
            if effectRect(for: element) != nil || element.kind == .magnifier {
                effectBoundaryCount += 1
                previousWasVector = false
            } else if !previousWasVector {
                vectorBatchCount += 1
                previousWasVector = true
            }
        }
        return ScreenshotRenderPlan(
            outputRect: outputRect,
            workingRect: workingRect,
            elementIndexes: elementIndexes,
            effectBoundaryCount: effectBoundaryCount,
            vectorBatchCount: vectorBatchCount
        )
    }

    private func effectRect(for element: ScreenshotElement) -> CGRect? {
        guard element.kind == .blur || element.kind == .pixelate || (element.kind == .redact && element.appearance.redactMode == .securePixelate),
              case let .rect(rect) = element.geometry else { return nil }
        return cgRect(rect).standardized
    }

    private func effectSamplingOutset(for element: ScreenshotElement) -> CGFloat {
        let intensity = max(1, element.appearance.effectIntensity)
        return element.kind == .blur ? ceil(intensity * 4) : ceil(intensity)
    }

    private func vectorRenderRect(for element: ScreenshotElement) -> CGRect {
        var bounds = cgRect(ScreenshotGeometry.bounds(of: element)).standardized
        if bounds.width == 0 { bounds.size.width = 1 }
        if bounds.height == 0 { bounds.size.height = 1 }

        let lineWidth: Double
        if case let .step(value) = element.appearance.payload {
            lineWidth = max(1, value.badgeBorderWidth, value.noteBorderWidth)
        } else {
            lineWidth = max(0.5, element.appearance.lineWidth)
        }
        var outset = lineWidth / 2 + 1
        if element.appearance.startEnding != .none || element.appearance.endEnding != .none {
            outset = max(outset, max(8, lineWidth * 4) + 1)
        }
        return bounds.insetBy(dx: -outset, dy: -outset)
    }

    private func checkCancellation(_ cancellation: ScreenshotRenderCancellation) throws {
        if cancellation.isCancelled {
            throw ScreenshotRenderError.cancelled
        }
    }

    private func configureStroke(_ appearance: ScreenshotElementAppearance, in context: CGContext) {
        setStrokeColor(appearance.strokeColor, in: context)
        context.setLineWidth(max(0.5, appearance.lineWidth))
        switch appearance.linePattern {
        case .solid: context.setLineDash(phase: 0, lengths: [])
        case .dashed:
            let unit = max(2, appearance.lineWidth * 2)
            context.setLineDash(phase: 0, lengths: [unit, unit])
        }
    }

}

public enum ScreenshotImageEncodingError: Error, Equatable {
    case destinationCreationFailed
    case finalizationFailed
    case opaqueCanvasCreationFailed
}

public struct ScreenshotImageEncoder {
    public init() {}

    public func pngData(_ image: CGImage) throws -> Data {
        try encode(image, typeIdentifier: "public.png" as CFString, properties: [:])
    }

    public func jpegData(_ image: CGImage, quality: Double = 0.9) throws -> Data {
        let opaqueImage: CGImage
        do {
            let context = try bitmapContext(width: image.width, height: image.height, opaque: true)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let rendered = context.makeImage() else {
                throw ScreenshotImageEncodingError.opaqueCanvasCreationFailed
            }
            opaqueImage = rendered
        } catch {
            throw ScreenshotImageEncodingError.opaqueCanvasCreationFailed
        }
        return try encode(
            opaqueImage,
            typeIdentifier: "public.jpeg" as CFString,
            properties: [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)]
        )
    }

    private func encode(
        _ image: CGImage,
        typeIdentifier: CFString,
        properties: [CFString: Any]
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier, 1, nil) else {
            throw ScreenshotImageEncodingError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotImageEncodingError.finalizationFailed
        }
        return data as Data
    }
}

private func bitmapContext(width: Int, height: Int, opaque: Bool) throws -> CGContext {
    guard width > 0,
          height > 0,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: opaque
                  ? CGImageAlphaInfo.noneSkipLast.rawValue
                  : CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
          ) else { throw ScreenshotRenderError.bitmapContextCreationFailed }
    return context
}

private func cgPoint(_ point: ScreenshotPixelPoint) -> CGPoint {
    CGPoint(x: point.x, y: point.y)
}

private func cgRect(_ rect: ScreenshotPixelRect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
}

private func setStrokeColor(_ color: ScreenshotColor, in context: CGContext) {
    context.setStrokeColor(red: clampUnit(color.red), green: clampUnit(color.green), blue: clampUnit(color.blue), alpha: clampUnit(color.alpha))
}

private func setFillColor(_ color: ScreenshotColor, in context: CGContext) {
    context.setFillColor(red: clampUnit(color.red), green: clampUnit(color.green), blue: clampUnit(color.blue), alpha: clampUnit(color.alpha))
}

private func clampUnit(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func glyphName(for scalar: Unicode.Scalar) -> String {
    if CharacterSet.letters.contains(scalar) { return String(scalar) }
    switch scalar.value {
    case 32: return "space"
    case 33: return "exclam"
    case 44: return "comma"
    case 45: return "hyphen"
    case 46: return "period"
    case 47: return "slash"
    case 48: return "zero"
    case 49: return "one"
    case 50: return "two"
    case 51: return "three"
    case 52: return "four"
    case 53: return "five"
    case 54: return "six"
    case 55: return "seven"
    case 56: return "eight"
    case 57: return "nine"
    case 58: return "colon"
    case 59: return "semicolon"
    case 63: return "question"
    default: return ".notdef"
    }
}
