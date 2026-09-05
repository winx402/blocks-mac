import AppKit
import SwiftUI

struct ClipboardCardWidthResizeHandle: View {
    private static let accessibilityStep: CGFloat = 24

    let currentWidth: CGFloat
    let onWidthChanged: (CGFloat) -> Void

    var body: some View {
        WidthResizeRepresentable(
            currentWidth: currentWidth,
            onWidthChanged: onWidthChanged
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("clipboard.panel.cardWidthResize.label"))
        .accessibilityValue("\(Int(currentWidth.rounded())) pt")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onWidthChanged(currentWidth + Self.accessibilityStep)
            case .decrement:
                onWidthChanged(currentWidth - Self.accessibilityStep)
            @unknown default:
                break
            }
        }
    }

    private struct WidthResizeRepresentable: NSViewRepresentable {
        let currentWidth: CGFloat
        let onWidthChanged: (CGFloat) -> Void

        func makeNSView(context: Context) -> WidthResizeView {
            let view = WidthResizeView()
            view.toolTip = L10n.string("clipboard.panel.cardWidthResize.help")
            view.currentWidth = currentWidth
            view.onDrag = { dragStartWidth, deltaX in
                onWidthChanged(dragStartWidth + deltaX)
            }
            return view
        }

        func updateNSView(_ nsView: WidthResizeView, context: Context) {
            nsView.currentWidth = currentWidth
            nsView.toolTip = L10n.string("clipboard.panel.cardWidthResize.help")
            nsView.onDrag = { dragStartWidth, deltaX in
                onWidthChanged(dragStartWidth + deltaX)
            }
        }

        final class WidthResizeView: NSView {
            var currentWidth: CGFloat = ClipboardBottomTrayLayout.defaultBottomCardWidth
            var onDrag: ((CGFloat, CGFloat) -> Void)?
            private var dragStartX: CGFloat?
            private var dragStartWidth: CGFloat?
            private var resizeTrackingArea: NSTrackingArea?
            private var cursorIsPushed = false

            override var acceptsFirstResponder: Bool {
                true
            }

            override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
                true
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                window?.invalidateCursorRects(for: self)
                updateTrackingAreas()
            }

            override func viewWillMove(toWindow newWindow: NSWindow?) {
                if newWindow == nil {
                    resetResizeCursor()
                }
                super.viewWillMove(toWindow: newWindow)
            }

            override func removeFromSuperview() {
                resetResizeCursor()
                super.removeFromSuperview()
            }

            override func hitTest(_ point: NSPoint) -> NSView? {
                bounds.contains(point) ? self : nil
            }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()

                if let resizeTrackingArea {
                    removeTrackingArea(resizeTrackingArea)
                }

                let trackingArea = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                addTrackingArea(trackingArea)
                resizeTrackingArea = trackingArea
            }

            override func resetCursorRects() {
                addCursorRect(bounds.insetBy(dx: -2, dy: 0), cursor: NSCursor.resizeLeftRight)
            }

            override func cursorUpdate(with event: NSEvent) {
                showResizeCursor()
            }

            override func mouseEntered(with event: NSEvent) {
                showResizeCursor()
            }

            override func mouseMoved(with event: NSEvent) {
                showResizeCursor()
            }

            override func mouseExited(with event: NSEvent) {
                resetResizeCursor()
            }

            override func mouseDown(with event: NSEvent) {
                showResizeCursor()
                dragStartX = event.locationInWindow.x
                dragStartWidth = currentWidth
            }

            override func mouseDragged(with event: NSEvent) {
                guard let dragStartX, let dragStartWidth else {
                    return
                }
                onDrag?(dragStartWidth, event.locationInWindow.x - dragStartX)
            }

            override func mouseUp(with event: NSEvent) {
                dragStartX = nil
                dragStartWidth = nil
                resetResizeCursor()
            }

            private func showResizeCursor() {
                if !cursorIsPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorIsPushed = true
                }
            }

            private func resetResizeCursor() {
                if cursorIsPushed {
                    NSCursor.pop()
                    cursorIsPushed = false
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
    }
}
