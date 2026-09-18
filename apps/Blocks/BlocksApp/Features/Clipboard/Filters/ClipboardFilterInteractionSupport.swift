import AppKit
import OSLog
import SwiftUI

/// Keep the native menu's pointer, keyboard and accessibility paths together.
/// The hosting view already accepts first mouse on macOS 14; newer SwiftUI
/// controls also have an explicit window-activation policy of their own.
struct ClipboardFilterWindowActivationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.allowsWindowActivationEvents(true)
        } else {
            content
        }
    }
}

enum ClipboardFilterInteractionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-filter"
    )

    static func pointer(group: ClipboardFilterGroup, windowNumber: Int, isKeyWindow: Bool) {
        logger.debug("stage=pointer-observed group=\(group.rawValue, privacy: .public) window=\(windowNumber) key=\(isKeyWindow)")
    }

    static func selection(group: ClipboardFilterGroup) {
        logger.debug("stage=selection-dispatched group=\(group.rawValue, privacy: .public)")
    }
}

/// A non-hit-testing observer: seeing a press here proves only that the local
/// monitor saw a press in the menu bounds, not that SwiftUI opened its menu.
struct ClipboardFilterPointerProbe: NSViewRepresentable {
    let group: ClipboardFilterGroup

    func makeNSView(context: Context) -> ClipboardFilterPointerProbeView {
        let view = ClipboardFilterPointerProbeView()
        view.group = group
        return view
    }

    func updateNSView(_ nsView: ClipboardFilterPointerProbeView, context: Context) {
        nsView.group = group
    }

    static func dismantleNSView(_ nsView: ClipboardFilterPointerProbeView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class ClipboardFilterPointerProbeView: NSView {
    var group: ClipboardFilterGroup = .format
    private var localMonitor: Any?
    var isMonitoring: Bool { localMonitor != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.processLocalEvent(event) ?? event
        }
    }

    func stopMonitoring() {
        guard let localMonitor else { return }
        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }

    /// This predicate deliberately excludes every other window and control.
    func containsMenuPress(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window, event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(event.locationInWindow, from: nil)
        // Non-clipping AppKit views can report a visibleRect larger than bounds.
        // Never expand observation into neighbouring controls in that case.
        return bounds.intersection(visibleRect).contains(point)
    }

    func processLocalEvent(_ event: NSEvent) -> NSEvent {
        observe(event)
        return event
    }

    private func observe(_ event: NSEvent) {
        guard containsMenuPress(event), let window else { return }
        ClipboardFilterInteractionDiagnostics.pointer(
            group: group, windowNumber: window.windowNumber, isKeyWindow: window.isKeyWindow
        )
    }
}

/// Native cursor rectangles are invalidated/removed with their view. Unlike a
/// push/pop cursor stack, they cannot leak a hand cursor when a chip disappears.
struct ClipboardFilterPointingHand: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ClipboardFilterCursorView {
        let view = ClipboardFilterCursorView()
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: ClipboardFilterCursorView, context: Context) {
        guard nsView.isEnabled != isEnabled else { return }
        nsView.isEnabled = isEnabled
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

@MainActor
final class ClipboardFilterCursorView: NSView {
    var isEnabled = true
    var pointingHandCursorRect: NSRect? {
        let rect = bounds.intersection(visibleRect)
        return isEnabled && !rect.isEmpty ? rect : nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let pointingHandCursorRect {
            addCursorRect(pointingHandCursorRect, cursor: .pointingHand)
        }
    }
}
