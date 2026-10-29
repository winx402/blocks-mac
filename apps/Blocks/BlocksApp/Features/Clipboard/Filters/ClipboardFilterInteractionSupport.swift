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
    enum Stage: String, CaseIterable, Codable, Sendable {
        case panelMouseDown = "panel-mouse-down"
        case firstMouse = "first-mouse"
        case mouseDown = "mouse-down"
        case trackingBegan = "tracking-began"
        case makeKeyBefore = "make-key-before"
        case makeKeyAfter = "make-key-after"
        case mouseDownReturned = "mouse-down-returned"
        case nativeMenuOpen = "native-menu-open"
        case nativeMenuClose = "native-menu-close"
        case selectionDispatched = "selection-dispatched"
        case panelBecameKey = "panel-became-key"
        case panelResignedKey = "panel-resigned-key"
    }

    enum Group: String, Codable, Sendable {
        case format, time, source

        init(_ group: ClipboardFilterGroup) {
            switch group {
            case .format: self = .format
            case .time: self = .time
            case .source: self = .source
            }
        }
    }

    /// Retain only mouse correlation/coordinates, never the NSEvent or its payload.
    struct MouseAttempt {
        let eventNumber: Int
        let windowNumber: Int?
        let windowPoint: NSPoint

        @MainActor
        init?(_ event: NSEvent?) {
            guard let event, event.type == .leftMouseDown else { return nil }
            eventNumber = event.eventNumber
            windowNumber = event.windowNumber == 0 ? nil : event.windowNumber
            windowPoint = event.locationInWindow
        }
    }

    /// Deliberately numeric/Boolean: no window/control/menu titles, AX values,
    /// item identities, device identifiers, responder names or typed text.
    struct Snapshot: Codable, Sendable {
        let eventNumber: Int?
        let eventWindow: Int?
        let window: Int?
        let key: Bool?
        let visible: Bool?
        let appActive: Bool?
        let onActiveSpace: Bool?
        let trackingProtected: Bool?
        let focusGeneration: UInt64?
        let screenCount: Int
        let screenOrdinal: Int?
        let screenFrame: NSRect?
        let screenVisibleFrame: NSRect?
        let windowScale: CGFloat?
        let screenScale: CGFloat?
        let windowFrame: NSRect?
        let controlBounds: NSRect?
        let controlVisibleRect: NSRect?
        let eventWindowPoint: NSPoint?
        let eventControlPoint: NSPoint?
        let eventScreenPoint: NSPoint?
    }

    struct Event: Codable, Sendable {
        let sequence: UInt64
        let time: Date
        let uptime: TimeInterval
        let stage: Stage
        let group: Group?
        let snapshot: Snapshot
    }

    struct JournalSnapshot: Codable, Sendable {
        let capacity: Int
        let dropped: UInt64
        let events: [Event]
    }

    /// A separate content-free journal; does not alter ClipboardInteractionTrace.
    /// Process-memory only: export before restarting. No strings or NSEvents enter.
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity = 128
        private var events: [Event] = []
        private var sequence: UInt64 = 0
        private var dropped: UInt64 = 0

        func record(_ stage: Stage, group: ClipboardFilterGroup? = nil, snapshot: Snapshot) {
            lock.lock()
            defer { lock.unlock() }
            sequence &+= 1
            if events.count == capacity {
                events.removeFirst()
                dropped &+= 1
            }
            events.append(Event(sequence: sequence, time: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                                stage: stage, group: group.map(Group.init), snapshot: snapshot))
        }

        func snapshot() -> JournalSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return JournalSnapshot(capacity: capacity, dropped: dropped, events: events)
        }
    }

    static let journal = Journal()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-filter"
    )

    static func pointer(group: ClipboardFilterGroup, windowNumber: Int, isKeyWindow: Bool) {
        ClipboardInteractionTrace.shared.record(.filterPointer, group: group, window: windowNumber, key: isKeyWindow)
        logger.debug("stage=pointer-observed group=\(group.rawValue, privacy: .public) window=\(windowNumber) key=\(isKeyWindow)")
    }

    static func selection(group: ClipboardFilterGroup, snapshot: Snapshot? = nil) {
        ClipboardInteractionTrace.shared.record(.filterSelection, group: group)
        if let snapshot {
            record(.selectionDispatched, group: group, snapshot: snapshot)
        } else {
            logger.info("stage=selection-dispatched group=\(group.rawValue, privacy: .public)")
        }
    }

    static func nativeMenu(group: ClipboardFilterGroup, isOpen: Bool, snapshot: Snapshot? = nil) {
        ClipboardInteractionTrace.shared.record(isOpen ? .filterNativeMenuOpen : .filterNativeMenuClose, group: group)
        let stage: Stage = isOpen ? .nativeMenuOpen : .nativeMenuClose
        if let snapshot {
            record(stage, group: group, snapshot: snapshot)
        } else {
            logger.info("stage=\(stage.rawValue, privacy: .public) group=\(group.rawValue, privacy: .public)")
        }
    }

    @MainActor
    static func snapshot(window: NSWindow?, control: NSView? = nil, mouse: MouseAttempt? = nil,
                         trackingProtected: Bool? = nil, focusGeneration: UInt64? = nil) -> Snapshot {
        let screens = NSScreen.screens
        let screen = window?.screen
        let hasMatchingEventWindow = window != nil && mouse?.windowNumber == window?.windowNumber
        let eventWindowPoint = finitePoint(mouse?.windowPoint)
        let eventControlPoint: NSPoint?
        if hasMatchingEventWindow, let control, control.window === window, let eventWindowPoint {
            eventControlPoint = finitePoint(control.convert(eventWindowPoint, from: nil))
        } else {
            eventControlPoint = nil
        }
        let eventScreenPoint: NSPoint?
        if hasMatchingEventWindow, let window, let eventWindowPoint {
            eventScreenPoint = finitePoint(window.convertPoint(toScreen: eventWindowPoint))
        } else {
            eventScreenPoint = nil
        }
        return Snapshot(eventNumber: mouse?.eventNumber, eventWindow: mouse?.windowNumber,
            window: window?.windowNumber, key: window?.isKeyWindow, visible: window?.isVisible,
            appActive: NSApp?.isActive, onActiveSpace: window?.isOnActiveSpace,
            trackingProtected: trackingProtected, focusGeneration: focusGeneration,
            screenCount: screens.count, screenOrdinal: screen.flatMap { screen in screens.firstIndex { $0 === screen } },
            screenFrame: finiteRect(screen?.frame), screenVisibleFrame: finiteRect(screen?.visibleFrame),
            windowScale: finiteScale(window?.backingScaleFactor), screenScale: finiteScale(screen?.backingScaleFactor),
            windowFrame: finiteRect(window?.frame), controlBounds: finiteRect(control?.bounds), controlVisibleRect: finiteRect(control?.visibleRect),
            eventWindowPoint: eventWindowPoint, eventControlPoint: eventControlPoint, eventScreenPoint: eventScreenPoint)
    }

    // Validate at capture, before AppKit conversion and before Codable sees a
    // value. Invalid geometry stays nil; NaN/Inf never poison a whole export.
    static func finitePoint(_ point: NSPoint?) -> NSPoint? {
        guard let point, point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    static func finiteRect(_ rect: NSRect?) -> NSRect? {
        guard let rect, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width >= 0, rect.size.height >= 0 else { return nil }
        return rect
    }

    static func finiteScale(_ scale: CGFloat?) -> CGFloat? {
        guard let scale, scale.isFinite, scale > 0 else { return nil }
        return scale
    }

    static func record(_ stage: Stage, group: ClipboardFilterGroup? = nil, snapshot: Snapshot) {
        journal.record(stage, group: group, snapshot: snapshot)
        let line = formatted(stage, group: group, snapshot: snapshot)
        logger.info("\(line, privacy: .public)")
    }

    static func formatted(_ stage: Stage, group: ClipboardFilterGroup? = nil, snapshot: Snapshot) -> String {
        func value<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "nil" }
        func number(_ value: CGFloat) -> String { value.isFinite ? String(Double(value)) : "unknown" }
        func scale(_ value: CGFloat?) -> String { value.map(number) ?? "nil" }
        func point(_ value: NSPoint?) -> String {
            value.map { "[\(number($0.x)),\(number($0.y))]" } ?? "nil"
        }
        func rect(_ value: NSRect?) -> String {
            value.map { "[\(number($0.minX)),\(number($0.minY)),\(number($0.width)),\(number($0.height))]" } ?? "nil"
        }
        return "stage=\(stage.rawValue) group=\(group?.rawValue ?? "nil")"
            + " eventNumber=\(value(snapshot.eventNumber)) eventWindow=\(value(snapshot.eventWindow)) window=\(value(snapshot.window))"
            + " key=\(value(snapshot.key)) visible=\(value(snapshot.visible)) appActive=\(value(snapshot.appActive)) onActiveSpace=\(value(snapshot.onActiveSpace))"
            + " trackingProtected=\(value(snapshot.trackingProtected)) focusGeneration=\(value(snapshot.focusGeneration))"
            + " screens=\(snapshot.screenCount) screenOrdinal=\(value(snapshot.screenOrdinal))"
            + " screenFrame=\(rect(snapshot.screenFrame)) screenVisibleFrame=\(rect(snapshot.screenVisibleFrame))"
            + " windowScale=\(scale(snapshot.windowScale)) screenScale=\(scale(snapshot.screenScale)) windowFrame=\(rect(snapshot.windowFrame))"
            + " controlBounds=\(rect(snapshot.controlBounds)) controlVisibleRect=\(rect(snapshot.controlVisibleRect))"
            + " eventWindowPoint=\(point(snapshot.eventWindowPoint)) eventControlPoint=\(point(snapshot.eventControlPoint)) eventScreenPoint=\(point(snapshot.eventScreenPoint))"
    }
}

struct ClipboardNativeFilterMenuEntry: Equatable {
    let id: String
    let title: String
    var systemImage: String? = nil
    var sourceBundleIdentifier: String? = nil
    var usesSourceIcon = false
}

/// Protection starts when this control receives its mouse interaction and ends
/// after native tracking and its closing event unwind. Window activation can
/// happen before mouseDown. This is not menu-open evidence;
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
        // SwiftUI supplies the entire visible surface. Suppress only AppKit's
        // extra rectangle, not keyboard focus or first-mouse activation.
        button.focusRingType = .none
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
        private var diagnosticMouseAttempt: ClipboardFilterInteractionDiagnostics.MouseAttempt?
        private var isHandlingMouseDown = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            if let mouse = ClipboardFilterInteractionDiagnostics.MouseAttempt(event) {
                diagnosticMouseAttempt = mouse
                recordDiagnostic(.firstMouse)
            }
            return true
        }
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
            recordDiagnostic(.trackingBegan)
            recordDiagnostic(.makeKeyBefore)
            window?.makeKey()
            recordDiagnostic(.makeKeyAfter)
        }

        func diagnosticSnapshot() -> ClipboardFilterInteractionDiagnostics.Snapshot {
            ClipboardFilterInteractionDiagnostics.snapshot(window: window, control: self,
                mouse: diagnosticMouseAttempt, trackingProtected: tracking?.isActive)
        }

        func beginNativeMenuDiagnostics() {
            // Keyboard/AX opening must not inherit a prior first-mouse query.
            if !isHandlingMouseDown { clearDiagnosticMouseAttempt() }
        }

        func clearDiagnosticMouseAttempt() {
            diagnosticMouseAttempt = nil
        }

        private func recordDiagnostic(_ stage: ClipboardFilterInteractionDiagnostics.Stage) {
            ClipboardFilterInteractionDiagnostics.record(stage, group: group, snapshot: diagnosticSnapshot())
        }

        override func mouseDown(with event: NSEvent) {
            diagnosticMouseAttempt = ClipboardFilterInteractionDiagnostics.MouseAttempt(event)
            isHandlingMouseDown = true
            recordDiagnostic(.mouseDown)
            if let window {
                ClipboardFilterInteractionDiagnostics.pointer(group: group,
                    windowNumber: window.windowNumber, isKeyWindow: window.isKeyWindow)
            }
            prepareForMenuInteraction()
            defer {
                tracking?.mouseInteractionDidReturn()
                recordDiagnostic(.mouseDownReturned)
                isHandlingMouseDown = false
            }
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
            if !active {
                button?.clearDiagnosticMouseAttempt()
                applyPendingUpdates()
            }
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
            ClipboardFilterInteractionDiagnostics.selection(group: group, snapshot: button?.diagnosticSnapshot())
            configuration.onSelection(id)
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard menu === button?.menu else { return }
            button?.beginNativeMenuDiagnostics()
            tracking.menuWillOpen()
            ClipboardFilterInteractionDiagnostics.nativeMenu(group: group, isOpen: true, snapshot: button?.diagnosticSnapshot())
        }

        func menuDidClose(_ menu: NSMenu) {
            guard menu === button?.menu else { return }
            ClipboardFilterInteractionDiagnostics.nativeMenu(group: group, isOpen: false, snapshot: button?.diagnosticSnapshot())
            tracking.menuDidClose()
        }

        func detach() {
            isDetaching = true
            button?.menu?.cancelTracking()
            button?.menu?.delegate = nil
            button?.target = nil
            button?.action = nil
            button?.tracking = nil
            button?.clearDiagnosticMouseAttempt()
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
