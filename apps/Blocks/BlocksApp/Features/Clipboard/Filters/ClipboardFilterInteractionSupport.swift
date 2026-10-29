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
        ClipboardInteractionTrace.shared.record(.filterPointer, group: group, window: windowNumber, key: isKeyWindow)
        logger.debug("stage=pointer-observed group=\(group.rawValue, privacy: .public) window=\(windowNumber) key=\(isKeyWindow)")
    }

    static func selection(group: ClipboardFilterGroup) {
        ClipboardInteractionTrace.shared.record(.filterSelection, group: group)
        logger.info("stage=selection-dispatched group=\(group.rawValue, privacy: .public)")
    }

    static func nativeMenu(group: ClipboardFilterGroup, isOpen: Bool) {
        ClipboardInteractionTrace.shared.record(isOpen ? .filterNativeMenuOpen : .filterNativeMenuClose, group: group)
        let stage = isOpen ? "native-menu-open" : "native-menu-close"
        logger.info("stage=\(stage, privacy: .public) group=\(group.rawValue, privacy: .public)")
    }
}

struct ClipboardNativeFilterMenuEntry: Equatable {
    let id: String
    let title: String
    var systemImage: String? = nil
    var sourceBundleIdentifier: String? = nil
    var usesSourceIcon = false
}

/// Protection starts before first-mouse activation and ends only after native
/// tracking and its closing event unwind. This is not menu-open evidence;
/// only NSMenuDelegate callbacks emit native open/close diagnostics.
@MainActor
final class ClipboardFilterMenuTracking {
    private(set) var isActive = false
    private(set) var isMenuOpen = false
    private var generation: UInt = 0
    private let onChange: (Bool) -> Void
    private let scheduleRelease: (@escaping () -> Void) -> Void

    init(
        onChange: @escaping (Bool) -> Void,
        scheduleRelease: @escaping (@escaping () -> Void) -> Void = { release in
            // A main-queue block can run inside NSMenu's nested event loop.
            // Default-mode work also protects the closing Escape/action.
            RunLoop.main.perform(inModes: [.default]) { release() }
        }
    ) {
        self.onChange = onChange
        self.scheduleRelease = scheduleRelease
    }

    func begin() {
        generation &+= 1
        guard !isActive else { return }
        isActive = true
        onChange(true)
    }

    func menuWillOpen() {
        isMenuOpen = true
        begin()
    }

    func mouseInteractionDidReturn() {
        guard !isMenuOpen else { return }
        endAfterCurrentEvent()
    }

    func menuDidClose() {
        isMenuOpen = false
        endAfterCurrentEvent()
    }

    private func endAfterCurrentEvent() {
        let closingGeneration = generation
        scheduleRelease { [weak self] in
            guard let self, generation == closingGeneration, !isMenuOpen else { return }
            reset()
        }
    }

    func reset() {
        generation &+= 1
        isMenuOpen = false
        guard isActive else { return }
        isActive = false
        onChange(false)
    }
}

/// SwiftUI owns filter values and rendering; this narrow bridge owns the native
/// first-click, target/action and menu lifetime. Visible menu items AND their
/// selection callback are frozen together until the closing event has finished.
struct ClipboardNativeFilterMenu: NSViewRepresentable {
    let group: ClipboardFilterGroup
    let entries: [ClipboardNativeFilterMenuEntry]
    let selectedID: String
    let accessibilityPresentation: ClipboardFilterAccessibilityPresentation
    let onSelection: (String) -> Void
    let onTrackingChange: (Bool) -> Void

    struct Configuration {
        let entries: [ClipboardNativeFilterMenuEntry]
        let selectedID: String
        let accessibilityPresentation: ClipboardFilterAccessibilityPresentation
        let onSelection: (String) -> Void
        let onTrackingChange: (Bool) -> Void
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(group: group)
    }

    func makeNSView(context: Context) -> FirstMousePopUpButton {
        let button = FirstMousePopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.attach(button)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: FirstMousePopUpButton, context: Context) {
        context.coordinator.update(Configuration(entries: entries, selectedID: selectedID,
            accessibilityPresentation: accessibilityPresentation,
            onSelection: onSelection, onTrackingChange: onTrackingChange))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FirstMousePopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? ClipboardFilterBarLayout.filterGroupFixedWidth(for: group),
               height: ClipboardFilterBarLayout.filterHitHeight)
    }

    static func dismantleNSView(_ button: FirstMousePopUpButton, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class FirstMousePopUpButton: NSPopUpButton {
        var tracking: ClipboardFilterMenuTracking?
        var group: ClipboardFilterGroup = .format

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var needsPanelToBecomeKey: Bool { true }
        override var alignmentRectInsets: NSEdgeInsets {
            // SwiftUI supplies the entire visual surface. Native popup optical
            // insets would make its real hit frame wider than that allocation,
            // bleeding into the adjacent, independent clear action.
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        // The existing SwiftUI label supplies the complete surface. The native
        // control still owns every pixel of its frame for hit testing and AX.
        override func draw(_ dirtyRect: NSRect) {}

        func prepareForMenuInteraction() {
            tracking?.begin()
            window?.makeKey()
        }

        override func mouseDown(with event: NSEvent) {
            if let window {
                ClipboardFilterInteractionDiagnostics.pointer(group: group,
                    windowNumber: window.windowNumber, isKeyWindow: window.isKeyWindow)
            }
            prepareForMenuInteraction()
            defer { tracking?.mouseInteractionDidReturn() }
            super.mouseDown(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        private let group: ClipboardFilterGroup
        private weak var button: FirstMousePopUpButton?
        private var configuration: Configuration?
        private var pendingConfiguration: Configuration?
        private var isDetaching = false
        private let scheduleRelease: (@escaping () -> Void) -> Void
        lazy var tracking = ClipboardFilterMenuTracking(onChange: { [weak self] active in
            guard let self else { return }
            // Finish the callback pair that began this session before adopting
            // a newer closure supplied by a SwiftUI update during tracking.
            configuration?.onTrackingChange(active)
            if !active { applyPendingUpdates() }
        }, scheduleRelease: scheduleRelease)

        init(group: ClipboardFilterGroup,
             scheduleRelease: @escaping (@escaping () -> Void) -> Void = { release in
                 RunLoop.main.perform(inModes: [.default]) { release() }
             }) {
            self.group = group
            self.scheduleRelease = scheduleRelease
        }

        func attach(_ button: FirstMousePopUpButton) {
            isDetaching = false
            self.button = button
            button.group = group
            button.tracking = tracking
            button.target = self
            button.action = #selector(selectFilter(_:))
        }

        func update(_ configuration: Configuration) {
            pendingConfiguration = configuration
            applyPendingUpdates()
        }

        private func applyPendingUpdates() {
            guard let button, !isDetaching, !tracking.isActive,
                  let pendingConfiguration else { return }
            if configuration?.entries != pendingConfiguration.entries {
                button.menu?.delegate = nil
                let menu = NSMenu()
                menu.autoenablesItems = false
                for entry in pendingConfiguration.entries {
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.representedObject = entry.id
                    if entry.usesSourceIcon {
                        item.image = ClipboardSourceAppIconResolver.icon(for: entry.sourceBundleIdentifier)
                            ?? ClipboardSourceAppIconResolver.defaultAppIcon
                    } else if let systemImage = entry.systemImage {
                        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
                    }
                    menu.addItem(item)
                }
                menu.delegate = self
                button.menu = menu
            }
            configuration = pendingConfiguration
            for item in button.itemArray {
                item.state = (item.representedObject as? String) == pendingConfiguration.selectedID ? .on : .off
            }
            if let index = pendingConfiguration.entries.firstIndex(where: { $0.id == pendingConfiguration.selectedID }) {
                button.selectItem(at: index)
            }
            let presentation = pendingConfiguration.accessibilityPresentation
            button.setAccessibilityIdentifier("clipboard.filter.menu.\(group.rawValue)")
            button.setAccessibilityLabel(presentation.label)
            button.setAccessibilityValue(presentation.value)
            button.setAccessibilityHelp(presentation.help)
            button.toolTip = "\(presentation.value)\n\(presentation.help)"
        }

        @objc func selectFilter(_ sender: NSPopUpButton) {
            guard !isDetaching, sender === button, let configuration,
                  let id = sender.selectedItem?.representedObject as? String,
                  configuration.entries.contains(where: { $0.id == id }) else { return }
            ClipboardFilterInteractionDiagnostics.selection(group: group)
            configuration.onSelection(id)
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard menu === button?.menu else { return }
            tracking.menuWillOpen()
            ClipboardFilterInteractionDiagnostics.nativeMenu(group: group, isOpen: true)
        }

        func menuDidClose(_ menu: NSMenu) {
            guard menu === button?.menu else { return }
            ClipboardFilterInteractionDiagnostics.nativeMenu(group: group, isOpen: false)
            tracking.menuDidClose()
        }

        func detach() {
            isDetaching = true
            button?.menu?.cancelTracking()
            button?.menu?.delegate = nil
            button?.target = nil
            button?.action = nil
            button?.tracking = nil
            button = nil
            tracking.reset()
            configuration = nil
            pendingConfiguration = nil
        }
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
        ClipboardInteractionTrace.shared.record(.probeAttached, group: group, window: window?.windowNumber)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.processLocalEvent(event) ?? event
        }
    }

    func stopMonitoring() {
        guard let localMonitor else { return }
        ClipboardInteractionTrace.shared.record(.probeDetached, group: group, window: window?.windowNumber)
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
