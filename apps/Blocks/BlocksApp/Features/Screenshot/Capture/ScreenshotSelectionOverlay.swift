import AppKit

@MainActor
enum ScreenshotAccessibilityAnnouncer {
    static func announce(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        guard !message.isEmpty, let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }

    static func focus(_ element: Any) {
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
    }
}

class ScreenshotSelectionPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        isOpaque = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScreenshotSelectionOverlayView: NSView {
    let canvasView: ScreenshotSelectionCanvasView
    let eventView: ScreenshotSelectionEventView

    init(frame: CGRect, controller: ScreenshotSelectionController) {
        canvasView = ScreenshotSelectionCanvasView(frame: frame, controller: controller)
        eventView = ScreenshotSelectionEventView(frame: frame, controller: controller)
        super.init(frame: frame)
        addSubview(canvasView)
        addSubview(eventView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        canvasView.frame = bounds
        eventView.frame = bounds
    }
}

final class ScreenshotSelectionCanvasView: NSView {
    private weak var controller: ScreenshotSelectionController?

    init(frame: CGRect, controller: ScreenshotSelectionController) {
        self.controller = controller
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        controller?.draw(in: self, dirtyRect: dirtyRect)
    }

    func convertGlobalToLocal(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
    }

    func convertGlobalToLocal(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }
}

final class ScreenshotSelectionEventView: NSView {
    static let defaultHitSurfaceAlpha: CGFloat = 1.0 / 255.0

    private weak var controller: ScreenshotSelectionController?
    private var trackingArea: NSTrackingArea?
    private var hasAnnouncedInstructions = false
    let hitSurfaceAlpha: CGFloat

    init(
        frame: CGRect,
        controller: ScreenshotSelectionController,
        hitSurfaceAlpha: CGFloat = ScreenshotSelectionEventView.defaultHitSurfaceAlpha
    ) {
        self.controller = controller
        self.hitSurfaceAlpha = hitSurfaceAlpha
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(hitSurfaceAlpha).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("screenshot.selection.accessibility.canvas"))
        setAccessibilityValue(L10n.string("screenshot.selection.hint.ready"))
        setAccessibilityHelp(L10n.string("screenshot.selection.hint.ready"))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        ScreenshotAccessibilityAnnouncer.focus(self)
        if !hasAnnouncedInstructions {
            hasAnnouncedInstructions = true
            ScreenshotAccessibilityAnnouncer.announce(
                L10n.string("screenshot.selection.accessibility.readyAnnouncement")
            )
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(globalPoint: convertLocalToGlobal(event.locationInWindow))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        controller?.mouseDown(globalPoint: convertLocalToGlobal(event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(globalPoint: convertLocalToGlobal(event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(globalPoint: convertLocalToGlobal(event.locationInWindow))
    }

    override func keyDown(with event: NSEvent) {
        controller?.keyDown(with: event)
    }

    private func convertLocalToGlobal(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return CGPoint(x: point.x + window.frame.minX, y: point.y + window.frame.minY)
    }
}
