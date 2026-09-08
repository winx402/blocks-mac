import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

@MainActor
protocol BlocksGlobalEscapeHotKeyLifecycle: AnyObject {
    @discardableResult
    func start() -> Bool
    func stop()
}

/// Shares one temporary Carbon Escape registration across transient Blocks UI.
/// The newest active owner receives Escape, so overlapping panels do not fight
/// over duplicate global registrations or require Accessibility permission.
@MainActor
final class BlocksGlobalEscapeHotKeyController: BlocksGlobalEscapeHotKeyLifecycle {
    private let id = UUID()
    private let onEscape: @MainActor () -> Void
    private var isStarted = false

    init(onEscape: @escaping @MainActor () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        guard isStarted else { return }
        let id = id
        Task { @MainActor in
            BlocksGlobalEscapeHotKeyCenter.shared.unregister(id: id)
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isStarted else { return true }
        guard BlocksGlobalEscapeHotKeyCenter.shared.register(
            id: id,
            onEscape: onEscape
        ) else { return false }
        isStarted = true
        return true
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        BlocksGlobalEscapeHotKeyCenter.shared.unregister(id: id)
    }

#if DEBUG
    var isRegisteredForTesting: Bool { isStarted }

    static func dispatchRegisteredEscapeForTesting() {
        BlocksGlobalEscapeHotKeyCenter.shared.dispatchEscape()
    }
#endif
}

@MainActor
private final class BlocksGlobalEscapeHotKeyCenter {
    private struct Owner {
        let id: UUID
        let onEscape: @MainActor () -> Void
    }

    static let shared = BlocksGlobalEscapeHotKeyCenter()
    private static let signature: OSType = 0x42455343 // "BESC"
    private static let identifier: UInt32 = 1

    private var owners: [Owner] = []
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    func register(id: UUID, onEscape: @escaping @MainActor () -> Void) -> Bool {
        if hotKey == nil, !installRegistration() { return false }
        owners.removeAll { $0.id == id }
        owners.append(Owner(id: id, onEscape: onEscape))
        return true
    }

    func unregister(id: UUID) {
        owners.removeAll { $0.id == id }
        guard owners.isEmpty else { return }
        uninstallRegistration()
    }

    fileprivate func dispatchEscape() {
        owners.last?.onEscape()
    }

    private func installRegistration() -> Bool {
        let target = GetApplicationEventTarget()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            target,
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var received = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &received
                )
                guard status == noErr,
                      received.signature == BlocksGlobalEscapeHotKeyCenter.signature,
                      received.id == BlocksGlobalEscapeHotKeyCenter.identifier else {
                    return status == noErr ? OSStatus(eventNotHandledErr) : status
                }
                let center = Unmanaged<BlocksGlobalEscapeHotKeyCenter>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor [weak center] in
                    center?.dispatchEscape()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            eventHandler = nil
            return false
        }

        var reference: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            target,
            0,
            &reference
        )
        guard registrationStatus == noErr, let reference else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            return false
        }
        hotKey = reference
        return true
    }

    private func uninstallRegistration() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

/// A shared, hit-testable window-drag region for panel title bars.
///
/// Panels opt out of background dragging so result cards, inputs and other
/// direct-manipulation surfaces never compete with window movement. Features
/// place this view only in the explicit title-bar space they own.
struct BlocksPanelWindowDragArea: NSViewRepresentable {
    let height: CGFloat

    init(
        height: CGFloat = BlocksVisualTokens.Control.compactHeight
    ) {
        self.height = height
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.dragHeight = height
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.dragHeight = height
        nsView.invalidateIntrinsicContentSize()
    }

    final class DragView: NSView {
        var dragHeight = BlocksVisualTokens.Control.compactHeight

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var intrinsicContentSize: NSSize {
            NSSize(
                width: NSView.noIntrinsicMetric,
                height: dragHeight
            )
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// Shared AppKit window behavior for Blocks' transient surfaces.
///
/// The role owns only window-level presentation defaults. Feature presenters
/// continue to own focus, dismissal, placement, persistence and business state.
enum BlocksFloatingPanelWindowRole {
    case transientNonactivatingUtility
    case nonactivatingSession
    case assist
    case passiveHUD
    case tooltip

    @MainActor
    func apply(to panel: NSPanel) {
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        switch self {
        case .transientNonactivatingUtility:
            applyTransparentTitlebar(to: panel)
            panel.hasShadow = true
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.acceptsMouseMovedEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            // This role owns its presentation lifecycle through
            // `BlocksAppKitMotion`; letting AppKit add a utility-window
            // transform creates a competing CA transaction during close.
            panel.animationBehavior = .none
            hideStandardWindowButtons(in: panel)

        case .nonactivatingSession:
            applyTransparentTitlebar(to: panel)
            panel.hasShadow = true
            panel.isMovableByWindowBackground = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.animationBehavior = .none
            panel.becomesKeyOnlyIfNeeded = true
            hideStandardWindowButtons(in: panel)

        case .assist:
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            // The presenter owns opacity through `BlocksAppKitMotion`; AppKit's
            // utility-window transform would otherwise run concurrently.
            panel.animationBehavior = .none

        case .passiveHUD:
            applyTransparentSurface(to: panel)
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .none

        case .tooltip:
            applyTransparentSurface(to: panel)
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.animationBehavior = .none
        }
    }

    @MainActor
    private func applyTransparentTitlebar(to panel: NSPanel) {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        applyTransparentSurface(to: panel)
    }

    @MainActor
    private func applyTransparentSurface(to panel: NSPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
    }

    @MainActor
    private func hideStandardWindowButtons(in panel: NSPanel) {
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { panel.standardWindowButton($0)?.isHidden = true }
    }
}

/// The single AppKit animation boundary for Blocks' panel windows.
///
/// SwiftUI owns content state; presenters use this helper only for imperative
/// window geometry and opacity changes. Zero-duration policies are applied
/// synchronously so Reduce Motion does not create an unnecessary animation
/// transaction.
enum BlocksAppKitMotion {
    @MainActor
    static func animate(
        window: NSWindow,
        to frame: CGRect,
        alphaValue: CGFloat,
        role: BlocksMotionRole,
        phase: BlocksMotionPhase = .standard,
        reduceMotion: Bool? = nil,
        completion: @escaping @MainActor () -> Void
    ) {
        let policy = role.policy(
            reduceMotion: reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            phase: phase
        )

        guard policy.duration > 0 else {
            window.setFrame(frame, display: true)
            window.alphaValue = alphaValue
            completion()
            return
        }

        // Frame changes are direct so the only explicit animation owned here
        // is opacity. Animating an already-current frame creates an
        // `_NSWindowTransformAnimation` with no visible geometry change.
        window.setFrame(frame, display: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = policy.duration
            context.timingFunction = policy.curve.mediaTimingFunction
            window.animator().alphaValue = alphaValue
        } completionHandler: {
            Task { @MainActor in
                completion()
            }
        }
    }

    @MainActor
    static func cancelAnimations(on window: NSWindow) {
        window.contentView?.layer?.removeAllAnimations()
        window.contentView?.superview?.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.setFrame(window.frame, display: true)
            window.alphaValue = window.alphaValue
        }
    }

    /// Applies the same semantic motion policy to an AppKit content view.
    ///
    /// Window presenters and embedded AppKit controls must not maintain
    /// separate duration, timing-curve, or Reduce Motion branches. Direct
    /// manipulation remains immediate; this helper is only for state feedback
    /// such as revealing or hiding a compact toolbar.
    @MainActor
    static func animate(
        view: NSView,
        alphaValue: CGFloat,
        role: BlocksMotionRole,
        phase: BlocksMotionPhase = .standard,
        completion: @escaping @MainActor () -> Void
    ) {
        cancelAnimations(on: view)
        let policy = role.policy(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            phase: phase
        )

        guard policy.duration > 0 else {
            view.alphaValue = alphaValue
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = policy.duration
            context.timingFunction = policy.curve.mediaTimingFunction
            view.animator().alphaValue = alphaValue
        } completionHandler: {
            Task { @MainActor in
                completion()
            }
        }
    }

    @MainActor
    static func cancelAnimations(on view: NSView) {
        view.layer?.removeAllAnimations()
        view.superview?.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            view.alphaValue = view.alphaValue
        }
    }
}

/// Owns the visible lifecycle of one AppKit panel.
///
/// Presenters remain responsible for their feature state and close policy. This
/// coordinator is the single boundary for first-frame geometry, opacity,
/// interaction suppression during dismissal, and stale animation completion
/// rejection. Direct manipulation (moving and resizing) stays outside this
/// type and therefore remains immediate.
@MainActor
final class BlocksFloatingPanelPresentationCoordinator {
    enum Phase: Equatable {
        case hidden
        case presenting
        case visible
        case dismissing
        case suspended
    }

    typealias AnimationDriver = @MainActor (
        _ window: NSWindow,
        _ frame: CGRect,
        _ alphaValue: CGFloat,
        _ role: BlocksMotionRole,
        _ phase: BlocksMotionPhase,
        _ completion: @escaping @MainActor () -> Void
    ) -> Void

    private(set) var phase: Phase = .hidden
    private var generation: UInt64 = 0
    private let animationDriver: AnimationDriver

    init(
        animationDriver: @escaping AnimationDriver = {
            window,
            frame,
            alphaValue,
            role,
            phase,
            completion in
            BlocksAppKitMotion.animate(
                window: window,
                to: frame,
                alphaValue: alphaValue,
                role: role,
                phase: phase,
                completion: completion
            )
        }
    ) {
        self.animationDriver = animationDriver
    }

    func present(
        window: NSWindow,
        frame: CGRect,
        makeKey: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        generation &+= 1
        let presentationGeneration = generation
        BlocksAppKitMotion.cancelAnimations(on: window)
        window.ignoresMouseEvents = false
        window.setFrame(frame, display: false)
        window.alphaValue = 0
        phase = .presenting
        window.orderFrontRegardless()
        if makeKey {
            window.makeKey()
        }
        animationDriver(
            window,
            frame,
            1,
            .panel,
            .insertion
        ) { [weak self, weak window] in
            guard let self,
                  let window,
                  self.generation == presentationGeneration else {
                return
            }
            window.alphaValue = 1
            self.phase = .visible
            completion()
        }
    }

    @discardableResult
    func dismiss(
        window: NSWindow,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        guard phase != .hidden,
              phase != .dismissing else {
            return false
        }
        generation &+= 1
        let dismissalGeneration = generation
        BlocksAppKitMotion.cancelAnimations(on: window)
        window.resignKey()
        window.ignoresMouseEvents = true
        phase = .dismissing
        animationDriver(
            window,
            window.frame,
            0,
            .confirmation,
            .removal
        ) { [weak self, weak window] in
            guard let self,
                  let window,
                  self.generation == dismissalGeneration else {
                return
            }
            // Keep the completed removal state until the presenter closes or
            // re-presents the window. Restoring alpha before `close()` exposes
            // one fully opaque frame and lets AppKit appear to run a second
            // dismissal animation.
            window.alphaValue = 0
            self.phase = .hidden
            completion()
        }
        return true
    }

    func closeImmediately(
        window: NSWindow,
        completion: @escaping @MainActor () -> Void
    ) {
        generation &+= 1
        BlocksAppKitMotion.cancelAnimations(on: window)
        window.ignoresMouseEvents = false
        window.alphaValue = 1
        phase = .hidden
        completion()
    }

    func suspend(window: NSWindow) {
        generation &+= 1
        BlocksAppKitMotion.cancelAnimations(on: window)
        window.ignoresMouseEvents = false
        window.alphaValue = 1
        window.orderOut(nil)
        phase = .suspended
    }

    func bringForward(window: NSWindow, makeKey: Bool) {
        generation &+= 1
        BlocksAppKitMotion.cancelAnimations(on: window)
        window.ignoresMouseEvents = false
        window.alphaValue = 1
        window.orderFrontRegardless()
        if makeKey {
            window.makeKey()
        }
        phase = .visible
    }

    func reset(window: NSWindow? = nil) {
        generation &+= 1
        if let window {
            BlocksAppKitMotion.cancelAnimations(on: window)
            window.ignoresMouseEvents = false
            window.alphaValue = 1
        }
        phase = .hidden
    }

}

/// Temporarily removes Blocks' regular windows while a nonactivating utility
/// panel is in use, then restores only the windows that were actually visible.
/// This prevents a transient panel from permanently erasing the user's prior
/// Blocks window context.
@MainActor
final class BlocksRegularWindowVisibilitySession {
    private final class Entry {
        weak var window: NSWindow?
        let wasKey: Bool

        init(window: NSWindow, wasKey: Bool) {
            self.window = window
            self.wasKey = wasKey
        }
    }

    private let windowsProvider: @MainActor () -> [NSWindow]
    private let applicationIsActive: @MainActor () -> Bool
    private var entries: [Entry] = []
    private var applicationWasActive = false
    private var isCapturing = false

    init(
        windowsProvider: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        self.windowsProvider = windowsProvider
        self.applicationIsActive = applicationIsActive
    }

    func hideRegularWindows(excluding excludedWindow: NSWindow) {
        guard !isCapturing else { return }
        isCapturing = true
        applicationWasActive = applicationIsActive()
        entries = windowsProvider().compactMap { window in
            guard window !== excludedWindow,
                  window.isVisible,
                  !window.isMiniaturized,
                  window.parent == nil,
                  window.level == .normal,
                  window.styleMask.contains(.titled) else {
                return nil
            }
            return Entry(window: window, wasKey: window.isKeyWindow)
        }
        entries.forEach { $0.window?.orderOut(nil) }
    }

    func restore() {
        guard isCapturing else { return }
        let entriesToRestore = entries
        let shouldRestoreKeyWindow = applicationWasActive
        discard()
        entriesToRestore.forEach { entry in
            guard let window = entry.window,
                  !window.isVisible else {
                return
            }
            if shouldRestoreKeyWindow && entry.wasKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        }
    }

    func discard() {
        entries.removeAll()
        applicationWasActive = false
        isCapturing = false
    }
}

private extension BlocksMotionPolicy.Curve {
    var mediaTimingFunction: CAMediaTimingFunction {
        switch self {
        case .linear:
            CAMediaTimingFunction(name: .linear)
        case .easeIn:
            CAMediaTimingFunction(name: .easeIn)
        case .easeOut:
            CAMediaTimingFunction(name: .easeOut)
        case .easeInOut:
            CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}

enum FloatingPanelKind: String {
    case clipboard
    case translation
}

/// Owns the process-wide screen-parameter subscription for one visible panel.
///
/// `NSScreen.visibleFrame` is intentionally read by the presenter when this
/// fires; caching it here would leave an anchored surface using stale Dock or
/// display geometry. Screen-parameter notifications do not replace the
/// window-delegate screen-change callback: a panel can move to a different
/// display without a global configuration change.
@MainActor
final class FloatingPanelVisibleFrameObserver {
    private let notificationCenter: NotificationCenter
    private var screenParametersObserver: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var onVisibleFrameChange: (@MainActor () -> Void)?

    private(set) var isObserving = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        if let screenParametersObserver {
            notificationCenter.removeObserver(screenParametersObserver)
        }
    }

    func start(onVisibleFrameChange: @escaping @MainActor () -> Void) {
        self.onVisibleFrameChange = onVisibleFrameChange
        guard screenParametersObserver == nil else {
            return
        }
        generation &+= 1
        let observerGeneration = generation
        screenParametersObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.generation == observerGeneration else {
                    return
                }
                self.onVisibleFrameChange?()
            }
        }
        isObserving = true
    }

    func stop() {
        generation &+= 1
        if let screenParametersObserver {
            notificationCenter.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        onVisibleFrameChange = nil
        isObserving = false
    }
}

enum FloatingPanelScreenResolver {
    /// Resolves a current `NSScreen` instead of retaining a possibly stale
    /// screen object across display-parameter changes. It preserves AppKit's
    /// display identity first, then falls back only to a real intersection.
    @MainActor
    static func screen(
        for panel: NSPanel,
        screens: [NSScreen] = NSScreen.screens,
        fallback: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        if let currentDisplayIdentifier = displayIdentifier(for: panel.screen),
           let exact = screens.first(where: {
               displayIdentifier(for: $0) == currentDisplayIdentifier
           }) {
            return exact
        }
        guard let screenIndex = screenIndex(
            containingMostOf: panel.frame,
            screenFrames: screens.map(\.frame)
        ) else {
            return fallback
        }
        return screens[screenIndex]
    }

    static func screenIndex(
        containingMostOf frame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        guard !screenFrames.isEmpty,
              let index = screenFrames.indices.max(by: { lhs, rhs in
            intersectionArea(frame, with: screenFrames[lhs])
                < intersectionArea(frame, with: screenFrames[rhs])
              }),
              intersectionArea(frame, with: screenFrames[index]) > 0 else {
            return nil
        }
        return index
    }

    static func displayIdentifier(for screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return String(number.uint32Value)
    }

    private static func intersectionArea(_ lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

enum FloatingPanelFrameStore {
    private static let margin: CGFloat = 22
    private static let clipboardSideDefaultWidth: CGFloat = 390
    static let clipboardSideMinWidth: CGFloat = 390
    static let clipboardSideMaxWidth: CGFloat = 560
    private static let clipboardBottomMinHeight: CGFloat = 260
    private static let clipboardBottomMaxHeight: CGFloat = 430
    private static let clipboardBottomHeightKey = "floatingPanel.clipboard.bottom.height"
    private static let clipboardSideWidthKey = "floatingPanel.clipboard.side.width"

    static func visibleFrame(screen: NSScreen? = NSScreen.main) -> CGRect {
        screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    static func frame(
        kind: FloatingPanelKind,
        position: FloatingPanelPosition?,
        defaultSize: CGSize,
        minSize: CGSize,
        screen: NSScreen? = NSScreen.main
    ) -> CGRect {
        let visibleFrame = visibleFrame(screen: screen)
        let maxSize = CGSize(
            width: max(minSize.width, visibleFrame.width - margin * 2),
            height: max(minSize.height, visibleFrame.height - margin * 2)
        )
        let savedSize = savedSize(kind: kind, position: position)
        let size = clamp(savedSize ?? defaultSize, minSize: minSize, maxSize: maxSize)

        switch position {
        case .bottom:
            return CGRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.minY + margin,
                width: size.width,
                height: size.height
            )
        case .left:
            return CGRect(
                x: visibleFrame.minX + margin,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .right:
            return CGRect(
                x: visibleFrame.maxX - size.width - margin,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .none:
            return CGRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    static func save(frame: CGRect, kind: FloatingPanelKind, position: FloatingPanelPosition?) {
        let key = sizeKey(kind: kind, position: position)
        UserDefaults.standard.set([frame.width, frame.height], forKey: key)
    }

    private static func savedSize(kind: FloatingPanelKind, position: FloatingPanelPosition?) -> CGSize? {
        let values = UserDefaults.standard.array(forKey: sizeKey(kind: kind, position: position)) as? [Double]
        guard let values, values.count == 2 else {
            return nil
        }
        return CGSize(width: values[0], height: values[1])
    }

    private static func clamp(_ size: CGSize, minSize: CGSize, maxSize: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }

    private static func sizeKey(kind: FloatingPanelKind, position: FloatingPanelPosition?) -> String {
        let positionValue = position?.rawValue ?? "center"
        return "floatingPanel.\(kind.rawValue).\(positionValue).size"
    }

    static func clipboardFrame(
        position: FloatingPanelPosition,
        screen: NSScreen? = NSScreen.main
    ) -> CGRect {
        switch position {
        case .bottom:
            return clipboardBottomFrame(screen: screen)
        case .left:
            return clipboardSideFrame(position: position, screen: screen)
        case .right:
            return clipboardSideFrame(position: position, screen: screen)
        }
    }

    static func clipboardSideFrame(
        position: FloatingPanelPosition,
        screen: NSScreen? = NSScreen.main,
        width: CGFloat? = nil
    ) -> CGRect {
        let visibleFrame = visibleFrame(screen: screen)
        let resolvedWidth = width.map { clipboardSideWidth(proposedWidth: $0, visibleFrame: visibleFrame) }
            ?? savedClipboardSideWidth(visibleFrame: visibleFrame)
        switch position {
        case .left:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: resolvedWidth,
                height: max(420, visibleFrame.height)
            )
        case .right:
            return CGRect(
                x: visibleFrame.maxX - resolvedWidth,
                y: visibleFrame.minY,
                width: resolvedWidth,
                height: max(420, visibleFrame.height)
            )
        case .bottom:
            return clipboardBottomFrame(screen: screen)
        }
    }

    static func clipboardBottomFrame(
        screen: NSScreen? = NSScreen.main,
        height: CGFloat? = nil
    ) -> CGRect {
        let visible = visibleFrame(screen: screen)
        let bounds = clipboardBottomBounds(screenFrame: screen?.frame ?? visible, visibleFrame: visible)
        let resolvedHeight = height.map { clipboardBottomHeight(proposedHeight: $0, visibleFrame: bounds) }
            ?? savedClipboardBottomHeight(defaultHeight: 286, visibleFrame: bounds)
        return clipboardBottomFrame(visibleFrame: bounds, height: resolvedHeight)
    }

    static func clipboardBottomBounds(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        // Bottom is a physical-display anchor, not a Dock avoidance region.
        // Retain horizontal usable bounds and the menu-bar ceiling only.
        CGRect(
            x: visibleFrame.minX,
            y: screenFrame.minY,
            width: visibleFrame.width,
            height: max(0, visibleFrame.maxY - screenFrame.minY)
        )
    }

    static func clipboardBottomFrame(
        visibleFrame: CGRect,
        height: CGFloat
    ) -> CGRect {
        CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: clipboardBottomHeight(proposedHeight: height, visibleFrame: visibleFrame)
        )
    }

    static func clipboardBottomHeight(
        proposedHeight: CGFloat,
        visibleFrame: CGRect
    ) -> CGFloat {
        min(
            max(proposedHeight, clipboardBottomMinHeight),
            min(visibleFrame.height, clipboardBottomMaxHeight)
        )
    }

    static func clipboardResizeSize(
        proposedSize: CGSize,
        position: FloatingPanelPosition,
        screen: NSScreen? = NSScreen.main
    ) -> CGSize {
        let frame = clipboardFrame(position: position, screen: screen)
        switch position {
        case .bottom:
            let visibleFrame = visibleFrame(screen: screen)
            return CGSize(
                width: frame.width,
                height: clipboardBottomHeight(proposedHeight: proposedSize.height, visibleFrame: visibleFrame)
            )
        case .left, .right:
            let visibleFrame = visibleFrame(screen: screen)
            return CGSize(
                width: clipboardSideWidth(proposedWidth: proposedSize.width, visibleFrame: visibleFrame),
                height: frame.height
            )
        }
    }

    static func saveClipboard(frame: CGRect, position: FloatingPanelPosition) {
        guard position == .bottom else {
            return
        }
        UserDefaults.standard.set(frame.height, forKey: clipboardBottomHeightKey)
    }

    static func saveClipboardSideWidth(frame: CGRect, position: FloatingPanelPosition) {
        guard position != .bottom else {
            return
        }
        let visibleFrame = visibleFrame(screen: NSScreen.main)
        UserDefaults.standard.set(clipboardSideWidth(proposedWidth: frame.width, visibleFrame: visibleFrame), forKey: clipboardSideWidthKey)
    }

    static func clipboardSideWidth(
        proposedWidth: CGFloat,
        visibleFrame: CGRect
    ) -> CGFloat {
        let screenBoundMax = max(clipboardSideMinWidth, min(clipboardSideMaxWidth, visibleFrame.width * 0.45))
        guard proposedWidth.isFinite else {
            return min(clipboardSideDefaultWidth, screenBoundMax)
        }
        return min(max(proposedWidth, clipboardSideMinWidth), screenBoundMax)
    }

    private static func savedClipboardBottomHeight(defaultHeight: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let savedHeight = UserDefaults.standard.object(forKey: clipboardBottomHeightKey) as? Double
        let height = savedHeight.map { CGFloat($0) } ?? defaultHeight
        return min(
            max(height, clipboardBottomMinHeight),
            max(clipboardBottomMinHeight, min(visibleFrame.height, clipboardBottomMaxHeight))
        )
    }

    private static func savedClipboardSideWidth(visibleFrame: CGRect) -> CGFloat {
        let savedWidth = UserDefaults.standard.object(forKey: clipboardSideWidthKey) as? Double
        let width = savedWidth.map { CGFloat($0) } ?? clipboardSideDefaultWidth
        return clipboardSideWidth(proposedWidth: width, visibleFrame: visibleFrame)
    }
}

enum FloatingPanelInteractionGeometry {
    static func windows(for panel: NSPanel) -> [NSWindow] {
        [panel] + (panel.childWindows ?? [])
    }

    static func frame(for panel: NSPanel) -> CGRect {
        windows(for: panel)
            .map(\.frame)
            .reduce(panel.frame) { partialResult, frame in
                partialResult.union(frame)
            }
    }
}

@MainActor
struct FloatingPanelRecentCloseGuard {
    private struct CloseSnapshot {
        let frame: CGRect
        let closedAt: Date
    }

    private let minimumReopenSuppressionInterval: TimeInterval
    private let interactionFrameExpansion: CGFloat
    private var snapshot: CloseSnapshot?

    init(
        minimumReopenSuppressionInterval: TimeInterval = 0.25,
        interactionFrameExpansion: CGFloat = 8
    ) {
        self.minimumReopenSuppressionInterval = minimumReopenSuppressionInterval
        self.interactionFrameExpansion = interactionFrameExpansion
    }

    mutating func recordClose(
        panel: NSPanel,
        at closedAt: Date = Date(),
        mouseLocation: CGPoint = NSEvent.mouseLocation,
        isAppActive: Bool? = nil
    ) {
        let isAppActive = isAppActive ?? NSApp.isActive
        let interactionFrame = FloatingPanelInteractionGeometry.frame(for: panel)
            .insetBy(dx: -interactionFrameExpansion, dy: -interactionFrameExpansion)
        guard isAppActive, interactionFrame.contains(mouseLocation) else {
            clear()
            return
        }
        snapshot = CloseSnapshot(frame: interactionFrame, closedAt: closedAt)
    }

    mutating func shouldSuppressOpen(
        at now: Date = Date(),
        mouseLocation: CGPoint = NSEvent.mouseLocation,
        isAppActive: Bool? = nil
    ) -> Bool {
        let isAppActive = isAppActive ?? NSApp.isActive
        guard let snapshot else {
            return false
        }
        guard isAppActive else {
            clear()
            return false
        }
        guard now.timeIntervalSince(snapshot.closedAt) <= minimumReopenSuppressionInterval else {
            clear()
            return false
        }
        guard snapshot.frame.contains(mouseLocation) else {
            clear()
            return false
        }
        return true
    }

    mutating func clear() {
        snapshot = nil
    }
}

@MainActor
final class FloatingPanelDismissMonitor {
    private struct NotificationObserver {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var notificationObservers: [NotificationObserver] = []

    func start(panel: NSPanel, onDismiss: @escaping () -> Void) {
        stop()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak panel] event in
            guard let panel else {
                return event
            }
            if Self.isEventInsideInteractionIsland(event, panel: panel) {
                return event
            }
            onDismiss()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                Self.dismissIfPanelIsVisible(panel, onDismiss: onDismiss)
            }
        }
        addDismissObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, panel: panel, onDismiss: onDismiss)
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        for observer in notificationObservers {
            observer.center.removeObserver(observer.token)
        }
        notificationObservers.removeAll()
    }

    private func addDismissObserver(
        center: NotificationCenter = .default,
        forName name: Notification.Name,
        object: Any?,
        panel: NSPanel,
        onDismiss: @escaping () -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: nil) { [weak panel] _ in
            Task { @MainActor in
                Self.dismissIfPanelIsVisible(panel, onDismiss: onDismiss)
            }
        }
        notificationObservers.append(NotificationObserver(center: center, token: token))
    }

    private static func dismissIfPanelIsVisible(_ panel: NSPanel?, onDismiss: () -> Void) {
        guard let panel, panel.isVisible else {
            return
        }
        onDismiss()
    }

    private static func isEventInsideInteractionIsland(_ event: NSEvent, panel: NSPanel) -> Bool {
        let windows = FloatingPanelInteractionGeometry.windows(for: panel)
        if let eventWindow = event.window {
            if windows.contains(where: { $0 === eventWindow }) {
                return true
            }
            if isPanelRelatedTransientWindow(eventWindow, panel: panel) {
                return true
            }
            return false
        }
        let screenPoint = NSEvent.mouseLocation
        return windows.contains { window in
            window.frame.insetBy(dx: -2, dy: -2).contains(screenPoint)
        }
    }

    private static func isPanelRelatedTransientWindow(_ window: NSWindow, panel: NSPanel) -> Bool {
        guard window.isVisible, isTransientInteractionWindow(window) else {
            return false
        }
        return FloatingPanelInteractionGeometry.frame(for: panel)
            .insetBy(dx: -48, dy: -48)
            .intersects(window.frame)
    }

    private static func isTransientInteractionWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window)).lowercased()
        return className.contains("menu")
            || className.contains("popover")
            || window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
    }
}
