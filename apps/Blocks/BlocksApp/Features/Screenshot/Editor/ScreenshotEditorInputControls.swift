import AppKit
import BlocksScreenshotCore

/// Owns the AppKit text-input behavior used by the canvas. Keeping this view
/// separate from canvas drawing prevents input-method state from leaking into
/// render invalidation.
final class ScreenshotInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMarkedTextChange: (() -> Void)?
    var resolvedMarkedTextAttributes: [NSAttributedString.Key: Any] = [:]

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        let resolved = ScreenshotInlineMarkedTextResolver.resolve(
            string,
            applying: resolvedMarkedTextAttributes
        )
        super.setMarkedText(
            resolved,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        let range = markedRange()
        if range.location != NSNotFound,
           range.location + range.length <= (textStorage?.length ?? 0),
           range.length > 0 {
            resolved.enumerateAttributes(
                in: NSRange(location: 0, length: min(resolved.length, range.length)),
                options: []
            ) { attributes, sourceRange, _ in
                textStorage?.addAttributes(
                    attributes,
                    range: NSRange(
                        location: range.location + sourceRange.location,
                        length: sourceRange.length
                    )
                )
            }
            textStorage?.addAttributes(resolvedMarkedTextAttributes, range: range)
        }
        var markedAttributes = markedTextAttributes ?? [:]
        for (key, value) in resolvedMarkedTextAttributes {
            markedAttributes[key] = value
        }
        markedTextAttributes = markedAttributes
        typingAttributes = resolvedMarkedTextAttributes
        if let foreground = resolvedMarkedTextAttributes[.foregroundColor] as? NSColor {
            textColor = foreground
            insertionPointColor = foreground
        }
        onMarkedTextChange?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, hasMarkedText() {
            super.keyDown(with: event)
        } else if event.keyCode == 53 {
            onCancel?()
        } else if flags.contains(.command), event.keyCode == 36 {
            onCommit?()
        } else {
            super.keyDown(with: event)
        }
    }
}

enum ScreenshotToolCursorProvider {
    static func cursor(for handle: ScreenshotResizeHandle) -> NSCursor {
        switch handle {
        case .north, .south:
            return .resizeUpDown
        case .east, .west:
            return .resizeLeftRight
        case .northWest, .southEast:
            return symbolCursor("arrow.up.left.and.arrow.down.right")
        case .northEast, .southWest:
            return symbolCursor("arrow.up.right.and.arrow.down.left")
        }
    }

    static func cursor(for tool: ScreenshotEditorTool) -> NSCursor {
        switch tool {
        case .select:
            return .arrow
        case .text:
            return .iBeam
        case .freehand:
            return symbolCursor("pencil.tip")
        case .highlight:
            return symbolCursor("highlighter")
        case .arrow:
            return symbolCursor("arrow.up.right")
        case .line:
            return symbolCursor("line.diagonal")
        case .rectangle:
            return symbolCursor("rectangle")
        case .ellipse:
            return symbolCursor("circle")
        case .blur:
            return symbolCursor("drop.halffull")
        case .pixelate:
            return symbolCursor("square.grid.3x3")
        case .counter:
            return symbolCursor("number.circle")
        case .step:
            return symbolCursor("list.number")
        case .callout:
            return symbolCursor("text.bubble")
        case .spotlight:
            return symbolCursor("scope")
        case .redact:
            return symbolCursor("eye.slash")
        case .magnifier:
            return symbolCursor("magnifyingglass.circle")
        case .watermark:
            return symbolCursor("seal")
        }
    }

    private static func symbolCursor(_ systemName: String) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let canvas = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let crosshair = NSBezierPath()
            crosshair.move(to: NSPoint(x: rect.midX, y: rect.minY + 1))
            crosshair.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1))
            crosshair.move(to: NSPoint(x: rect.minX + 1, y: rect.midY))
            crosshair.line(to: NSPoint(x: rect.maxX - 1, y: rect.midY))
            crosshair.lineWidth = 1
            crosshair.stroke()
            guard let symbol = NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: nil
            ) else {
                return true
            }
            symbol.draw(in: NSRect(x: rect.maxX - 11, y: rect.minY, width: 11, height: 11))
            return true
        }
        return NSCursor(image: canvas, hotSpot: NSPoint(x: 12, y: 12))
    }
}
