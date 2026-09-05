import ApplicationServices
import AppKit
import BlocksCore
import SwiftUI

enum PermissionAssistKind: Equatable {
    case screenRecording
    case accessibility
    case inputMonitoring

    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording:
            ScreenRecordingPermission.isAuthorized
        case .accessibility:
            AXIsProcessTrusted()
        case .inputMonitoring:
            CGPreflightListenEventAccess()
        }
    }

    var title: String {
        switch self {
        case .screenRecording:
            L10n.string("permission.assist.screenRecording.title")
        case .accessibility:
            L10n.string("permission.assist.accessibility.title")
        case .inputMonitoring:
            L10n.string("permission.assist.inputMonitoring.title")
        }
    }

    var detail: String {
        switch self {
        case .screenRecording:
            L10n.string("permission.assist.screenRecording.detail")
        case .accessibility:
            L10n.string("permission.assist.accessibility.detail")
        case .inputMonitoring:
            L10n.string("permission.assist.inputMonitoring.detail")
        }
    }

    var diagnosticKind: PermissionDiagnosticKind {
        switch self {
        case .screenRecording:
            .screenRecording
        case .accessibility:
            .accessibility
        case .inputMonitoring:
            .inputMonitoring
        }
    }
}

enum PermissionAssistSessionState: String, Equatable {
    case idle
    case openingSystemSettings
    case waitingForSettingsWindow
    case guiding
    case checkingPermission
    case granted
    case failed
    case cancelled
    case timedOut
}

struct PermissionAssistSession: Equatable {
    let kind: PermissionAssistKind
    var state: PermissionAssistSessionState
    let startedAt: Date
    var systemSettingsFrame: CGRect?
    var arrowDirection: PermissionAssistArrowDirection
    var lastFailureReason: String?
}

@MainActor
final class PermissionAssistPanelPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitorTimer: Timer?
    private var session: PermissionAssistSession? {
        didSet {
            panelSessionModel?.update(session: session, appURL: currentAppURL)
        }
    }
    private var panelSessionModel: PermissionAssistPanelSessionModel?
    private var currentAppURL: URL = Bundle.main.bundleURL
    private var onFlowEnded: (() -> Void)?
    private var didNotifyFlowEnded = false
    private var hasObservedSystemSettingsWindow = false
    private let mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession
    private let now: () -> Date
    private let permissionGranted: (PermissionAssistKind) -> Bool
    private let systemSettingsWindowFrame: () -> CGRect?
    private let isSystemSettingsRunning: () -> Bool
    private let isApplicationHidden: @MainActor () -> Bool
    private let openSystemSettings: (URL) -> Void
    private let panelPresentationCoordinator: BlocksFloatingPanelPresentationCoordinator
    private var presentationRequestGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var pendingCloseGeneration: UInt64?
    private let settingsLaunchGraceSeconds: TimeInterval = 5
    private let flowTimeoutSeconds: TimeInterval = 90
    private let settingsWindowFallbackSeconds: TimeInterval = 8

    init(
        mainWindowRestoreSession: PermissionAssistMainWindowRestoreSession? = nil,
        now: @escaping () -> Date = Date.init,
        permissionGranted: @escaping (PermissionAssistKind) -> Bool = { $0.isGranted },
        systemSettingsWindowFrame: @escaping () -> CGRect? = {
            SystemSettingsWindowLocator.visibleWindowFrame()
        },
        isSystemSettingsRunning: @escaping () -> Bool = {
            SystemSettingsWindowLocator.isSystemSettingsRunning
        },
        isApplicationHidden: @escaping @MainActor () -> Bool = {
            NSApp.isHidden
        },
        openSystemSettings: @escaping (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        panelPresentationCoordinator: BlocksFloatingPanelPresentationCoordinator? = nil
    ) {
        self.mainWindowRestoreSession = mainWindowRestoreSession
            ?? PermissionAssistMainWindowRestoreSession()
        self.now = now
        self.permissionGranted = permissionGranted
        self.systemSettingsWindowFrame = systemSettingsWindowFrame
        self.isSystemSettingsRunning = isSystemSettingsRunning
        self.isApplicationHidden = isApplicationHidden
        self.openSystemSettings = openSystemSettings
        self.panelPresentationCoordinator = panelPresentationCoordinator
            ?? BlocksFloatingPanelPresentationCoordinator()
    }

    func present(kind: PermissionAssistKind, appURL: URL = Bundle.main.bundleURL, onFlowEnded: (() -> Void)? = nil) {
        presentationRequestGeneration &+= 1
        let requestGeneration = presentationRequestGeneration
        finishCurrentLifecycleImmediatelyForReplacement()
        // Ending the previous flow invokes its callback synchronously. That
        // callback is allowed to start a newer permission flow; in that case
        // the newer request owns the presenter and this outer request must not
        // overwrite it when the callback returns.
        guard presentationRequestGeneration == requestGeneration else {
            return
        }
        currentAppURL = appURL
        self.onFlowEnded = onFlowEnded
        hasObservedSystemSettingsWindow = false
        session = PermissionAssistSession(
            kind: kind,
            state: .openingSystemSettings,
            startedAt: now(),
            systemSettingsFrame: nil,
            arrowDirection: .left,
            lastFailureReason: nil
        )
        didNotifyFlowEnded = false
        let generation = mainWindowRestoreSession.begin()
        activeGeneration = generation
        if let settingsURL = kind.settingsURL {
            openSystemSettings(settingsURL)
        }

        startMonitoring(for: generation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.showPanelIfNeeded(forceWaitingPanel: false, generation: generation)
        }
    }

    func shutdown() {
        if activeGeneration != nil {
            close()
        } else {
            finishPendingCloseImmediately()
        }
    }

    private func showPanelIfNeeded(
        forceWaitingPanel: Bool = false,
        generation: UInt64? = nil
    ) {
        guard isCurrent(generation) else {
            return
        }
        guard !isApplicationHidden() else {
            return
        }
        guard var session else {
            return
        }
        let placement = frame()
        if placement.systemSettingsFrame != nil {
            hasObservedSystemSettingsWindow = true
        }
        if placement.systemSettingsFrame == nil && !forceWaitingPanel && session.state != .failed {
            return
        }
        session.systemSettingsFrame = placement.systemSettingsFrame
        session.arrowDirection = placement.arrowDirection
        if session.state == .openingSystemSettings || session.state == .waitingForSettingsWindow {
            session.state = placement.systemSettingsFrame == nil ? .waitingForSettingsWindow : .guiding
        }
        self.session = session

        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            panelPresentationCoordinator.present(
                window: panel,
                frame: placement.frame,
                makeKey: false
            )
        } else {
            updatePanelPlacement(panel, placement: placement)
        }
    }

    func close() {
        guard let generation = activeGeneration else {
            return
        }
        activeGeneration = nil
        pendingCloseGeneration = generation
        monitorTimer?.invalidate()
        monitorTimer = nil
        hasObservedSystemSettingsWindow = false
        guard let panel, panel.isVisible else {
            panelPresentationCoordinator.reset(window: panel)
            finishPendingClose(for: generation)
            return
        }
        guard panelPresentationCoordinator.dismiss(window: panel, completion: { [weak self, weak panel] in
            guard let self,
                  self.pendingCloseGeneration == generation else {
                return
            }
            panel?.orderOut(nil)
            self.finishPendingClose(for: generation)
        }) else {
            panel.orderOut(nil)
            finishPendingClose(for: generation)
            return
        }
    }

    private func cancel() {
        session?.state = .cancelled
        close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.string("permission.assist.title")
        BlocksFloatingPanelWindowRole.assist.apply(to: panel)
        panel.delegate = self
        let sessionModel = panelSessionModel ?? PermissionAssistPanelSessionModel(
            session: session,
            appURL: currentAppURL
        )
        panelSessionModel = sessionModel
        panel.contentView = NSHostingView(
            rootView: PermissionAssistPanelView(
                sessionModel: sessionModel,
                onCompleted: { [weak self] in self?.completeFromUserAction() },
                onClose: { [weak self] in self?.cancel() }
            )
        )
        return panel
    }

    private func frame() -> PermissionAssistPlacement {
        let settingsFrame = systemSettingsWindowFrame()
        let visibleFrame = PermissionAssistPlacementGeometry.visibleFrame(
            containingCenterOf: settingsFrame,
            screens: NSScreen.screens.map {
                .init(frame: $0.frame, visibleFrame: $0.visibleFrame)
            },
            fallback: NSScreen.main?.visibleFrame
        ) ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width: CGFloat = min(440, visibleFrame.width - 48)
        let height = min(360, max(220, visibleFrame.height - 32))
        let preferredFrame: CGRect
        let arrowDirection: PermissionAssistArrowDirection
        if let settingsFrame {
            let rightX = settingsFrame.maxX + 16
            let leftX = settingsFrame.minX - width - 16
            let canPlaceRight = rightX + width <= visibleFrame.maxX
            let x = canPlaceRight ? rightX : max(visibleFrame.minX + 24, leftX)
            arrowDirection = canPlaceRight ? .left : .right
            preferredFrame = CGRect(
                x: x,
                y: settingsFrame.midY - height / 2,
                width: width,
                height: height
            )
        } else {
            arrowDirection = .left
            preferredFrame = CGRect(
                x: visibleFrame.maxX - width - 28,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
        }
        return PermissionAssistPlacement(
            frame: preferredFrame.clamped(to: visibleFrame.insetBy(dx: 16, dy: 16)),
            arrowDirection: arrowDirection,
            systemSettingsFrame: settingsFrame
        )
    }

    private func startMonitoring(for generation: UInt64) {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitorPermissionFlow(generation: generation)
            }
        }
    }

    private func monitorPermissionFlow(generation: UInt64) {
        guard isCurrent(generation) else {
            return
        }
        guard var session else {
            return
        }
        if permissionGranted(session.kind) {
            session.state = .granted
            self.session = session
            close()
            return
        }
        // Cmd-H hides every Blocks panel. Do not let the monitor revive or
        // reposition it until the app becomes visible again.
        guard !isApplicationHidden() else {
            return
        }
        if flowTimedOut {
            session.state = .timedOut
            self.session = session
            monitorTimer?.invalidate()
            monitorTimer = nil
            showPanelIfNeeded(forceWaitingPanel: true, generation: generation)
            return
        }
        let placement = frame()
        if placement.systemSettingsFrame != nil {
            hasObservedSystemSettingsWindow = true
        }
        guard let panel, panel.isVisible else {
            if placement.systemSettingsFrame != nil {
                showPanelIfNeeded(forceWaitingPanel: false, generation: generation)
                return
            }
            if waitingForSystemSettingsWindowTimedOut {
                session.state = .failed
                session.lastFailureReason = L10n.string("permission.assist.settingsWindowNotFound")
                self.session = session
                showPanelIfNeeded(forceWaitingPanel: true, generation: generation)
                return
            }
            session.state = .waitingForSettingsWindow
            self.session = session
            showPanelIfNeeded(
                forceWaitingPanel: !shouldKeepWaitingForSystemSettings,
                generation: generation
            )
            return
        }
        if hasObservedSystemSettingsWindow && !isSystemSettingsRunning() {
            session.state = .cancelled
            self.session = session
            close()
            return
        }
        session.systemSettingsFrame = placement.systemSettingsFrame
        session.arrowDirection = placement.arrowDirection
        if session.state != .failed {
            if placement.systemSettingsFrame != nil {
                session.state = .guiding
            } else if waitingForSystemSettingsWindowTimedOut {
                session.state = .failed
                session.lastFailureReason = L10n.string("permission.assist.settingsWindowNotFound")
            } else {
                session.state = .waitingForSettingsWindow
            }
        }
        self.session = session
        updatePanelPlacement(panel, placement: placement)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else {
            return
        }
        panel = nil
        if let generation = pendingCloseGeneration {
            panelPresentationCoordinator.reset()
            finishPendingClose(for: generation)
        } else {
            cancel()
        }
    }

    private var shouldKeepWaitingForSystemSettings: Bool {
        guard let session else {
            return false
        }
        return now().timeIntervalSince(session.startedAt) < settingsLaunchGraceSeconds
    }

    private var waitingForSystemSettingsWindowTimedOut: Bool {
        guard let session else {
            return false
        }
        return now().timeIntervalSince(session.startedAt) >= settingsWindowFallbackSeconds
    }

    private var flowTimedOut: Bool {
        guard let session else {
            return false
        }
        return now().timeIntervalSince(session.startedAt) >= flowTimeoutSeconds
    }

    private func notifyFlowEndedOnce() {
        guard !didNotifyFlowEnded else {
            return
        }
        didNotifyFlowEnded = true
        let callback = onFlowEnded
        onFlowEnded = nil
        callback?()
    }

    private func completeFromUserAction() {
        guard let generation = activeGeneration, var session else {
            return
        }
        session.state = .checkingPermission
        self.session = session
        guard isCurrent(generation) else {
            return
        }
        if permissionGranted(session.kind) {
            session.state = .granted
            self.session = session
            close()
            return
        }
        session.state = .failed
        session.lastFailureReason = L10n.string("permission.assist.notGrantedAfterCheck")
        self.session = session
        showPanelIfNeeded(forceWaitingPanel: true)
    }

    private func isCurrent(_ generation: UInt64?) -> Bool {
        guard let generation else {
            return activeGeneration != nil
        }
        return activeGeneration == generation
    }

    private func finishPendingClose(for generation: UInt64) {
        guard pendingCloseGeneration == generation else {
            return
        }
        pendingCloseGeneration = nil
        session = nil
        mainWindowRestoreSession.restore(for: generation)
        notifyFlowEndedOnce()
    }

    private func finishCurrentLifecycleImmediatelyForReplacement() {
        if let generation = activeGeneration {
            activeGeneration = nil
            pendingCloseGeneration = generation
            monitorTimer?.invalidate()
            monitorTimer = nil
            hasObservedSystemSettingsWindow = false
        }
        finishPendingCloseImmediately()
    }

    private func finishPendingCloseImmediately() {
        guard let generation = pendingCloseGeneration else {
            return
        }
        if let panel {
            panelPresentationCoordinator.closeImmediately(window: panel) {
                panel.orderOut(nil)
            }
        } else {
            panelPresentationCoordinator.reset()
        }
        finishPendingClose(for: generation)
    }

    private func updatePanelPlacement(
        _ panel: NSPanel,
        placement: PermissionAssistPlacement
    ) {
        guard panel.frame != placement.frame else {
            return
        }
        panel.setFrame(placement.frame, display: true)
    }

#if DEBUG
    var panelForTesting: NSPanel? { panel }
    var sessionForTesting: PermissionAssistSession? { session }

    func monitorPermissionFlowForTesting() {
        guard let activeGeneration else {
            return
        }
        monitorPermissionFlow(generation: activeGeneration)
    }

    func completeFromUserActionForTesting() {
        completeFromUserAction()
    }
#endif
}

/// Captures just Blocks' currently active regular settings window while the
/// permission assistant guides the user in System Settings. It deliberately
/// does not enumerate floating panels: reopening one of those would revive a
/// separate task the user did not ask to resume.
@MainActor
final class PermissionAssistMainWindowRestoreSession {
    struct WindowHost {
        var windows: @MainActor () -> [NSWindow]
        var mainWindow: @MainActor () -> NSWindow?
        var keyWindow: @MainActor () -> NSWindow?
        var isMainWindow: @MainActor (NSWindow) -> Bool
        var isKeyWindow: @MainActor (NSWindow) -> Bool
        var activateApplication: @MainActor () -> Void
        var orderOut: @MainActor (NSWindow) -> Void
        var orderFront: @MainActor (NSWindow) -> Void
        var makeKey: @MainActor (NSWindow) -> Void
        var setFrame: @MainActor (NSWindow, CGRect) -> Void
        var animationBehavior: @MainActor (NSWindow) -> NSWindow.AnimationBehavior
        var setAnimationBehavior: @MainActor (NSWindow, NSWindow.AnimationBehavior) -> Void

        init(
            windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
            mainWindow: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow },
            keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
            isMainWindow: @escaping @MainActor (NSWindow) -> Bool = { $0.isMainWindow },
            isKeyWindow: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
            activateApplication: @escaping @MainActor () -> Void = {
                NSApp.activate(ignoringOtherApps: true)
            },
            orderOut: @escaping @MainActor (NSWindow) -> Void = { $0.orderOut(nil) },
            orderFront: @escaping @MainActor (NSWindow) -> Void = { $0.orderFront(nil) },
            makeKey: @escaping @MainActor (NSWindow) -> Void = { $0.makeKey() },
            setFrame: @escaping @MainActor (NSWindow, CGRect) -> Void = { window, frame in
                window.setFrame(frame, display: false)
            },
            animationBehavior: @escaping @MainActor (NSWindow) -> NSWindow.AnimationBehavior = {
                $0.animationBehavior
            },
            setAnimationBehavior: @escaping @MainActor (NSWindow, NSWindow.AnimationBehavior) -> Void = {
                $0.animationBehavior = $1
            }
        ) {
            self.windows = windows
            self.mainWindow = mainWindow
            self.keyWindow = keyWindow
            self.isMainWindow = isMainWindow
            self.isKeyWindow = isKeyWindow
            self.activateApplication = activateApplication
            self.orderOut = orderOut
            self.orderFront = orderFront
            self.makeKey = makeKey
            self.setFrame = setFrame
            self.animationBehavior = animationBehavior
            self.setAnimationBehavior = setAnimationBehavior
        }
    }

    @MainActor
    private final class CapturedWindow {
        weak var window: NSWindow?
        let frame: CGRect
        let wasVisible: Bool
        let wasKey: Bool
        let wasMain: Bool
        let animationBehavior: NSWindow.AnimationBehavior
        var wasClosed = false

        init(
            window: NSWindow,
            wasKey: Bool,
            wasMain: Bool,
            animationBehavior: NSWindow.AnimationBehavior
        ) {
            self.window = window
            frame = window.frame
            wasVisible = window.isVisible
            self.wasKey = wasKey
            self.wasMain = wasMain
            self.animationBehavior = animationBehavior
        }
    }

    private let host: WindowHost
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var capturedWindow: CapturedWindow?
    private var windowWillCloseObserver: NSObjectProtocol?

    init(host: WindowHost = .init()) {
        self.host = host
    }

    @discardableResult
    func begin() -> UInt64 {
        discard()
        generation &+= 1
        activeGeneration = generation

        guard let window = mainSettingsWindow() else {
            return generation
        }

        let captured = CapturedWindow(
            window: window,
            wasKey: host.isKeyWindow(window),
            wasMain: host.isMainWindow(window),
            animationBehavior: host.animationBehavior(window)
        )
        // AppKit can defer a window-transform animation beyond orderOut. Keep
        // this one restoration transaction non-animated, then put the user's
        // original behavior back when the session ends.
        capturedWindow = captured
        let capturedGeneration = generation
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.markCapturedWindowClosed(for: capturedGeneration)
            }
        }
        host.setAnimationBehavior(window, .none)
        host.orderOut(window)
        return generation
    }

    func restore(for generation: UInt64) {
        guard activeGeneration == generation else {
            return
        }
        guard let captured = capturedWindow else {
            discard()
            return
        }
        defer { discard() }
        guard
              captured.wasVisible,
              !captured.wasClosed,
              let window = captured.window,
              host.windows().contains(where: { $0 === window }) else {
            return
        }

        host.setFrame(window, captured.frame)
        host.orderFront(window)
        if captured.wasKey || captured.wasMain {
            host.activateApplication()
            host.makeKey(window)
        }
    }

    private func mainSettingsWindow() -> NSWindow? {
        [host.mainWindow(), host.keyWindow()]
            .compactMap { $0 }
            .first(where: isVisibleRegularMainWindow)
    }

    private func isVisibleRegularMainWindow(_ window: NSWindow) -> Bool {
        window.isVisible
            && !window.isMiniaturized
            && window.parent == nil
            && window.level == .normal
            && !(window is NSPanel)
            && window.styleMask.contains(.titled)
    }

    private func markCapturedWindowClosed(for generation: UInt64) {
        guard activeGeneration == generation else {
            return
        }
        capturedWindow?.wasClosed = true
    }

    private func discard() {
        if let captured = capturedWindow,
           let window = captured.window {
            host.setAnimationBehavior(window, captured.animationBehavior)
        }
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        windowWillCloseObserver = nil
        capturedWindow = nil
        activeGeneration = nil
    }
}

struct PermissionAssistPlacement {
    let frame: CGRect
    let arrowDirection: PermissionAssistArrowDirection
    let systemSettingsFrame: CGRect?
}

enum PermissionAssistPlacementGeometry {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct CoordinateSpace: Equatable {
        let quartzFrame: CGRect
        let appKitFrame: CGRect
    }

    /// Uses the screen containing System Settings' frame center. Screen frames
    /// can have negative origins, so this intentionally never infers a screen
    /// from a coordinate sign or from the main display.
    static func visibleFrame(
        containingCenterOf settingsFrame: CGRect?,
        screens: [Screen],
        fallback: CGRect?
    ) -> CGRect? {
        guard let settingsFrame else {
            return fallback
        }
        let center = CGPoint(x: settingsFrame.midX, y: settingsFrame.midY)
        return screens.first(where: { $0.frame.contains(center) })?.visibleFrame ?? fallback
    }

    /// Converts the top-left-origin Quartz window coordinates into the
    /// bottom-left-origin AppKit coordinates of the same physical display.
    /// Using the display's real Quartz bounds is required for vertically
    /// stacked displays whose horizontal ranges overlap.
    static func appKitFrame(
        forQuartzWindow frame: CGRect,
        coordinateSpaces: [CoordinateSpace]
    ) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let space = coordinateSpaces.first(where: {
            $0.quartzFrame.contains(center)
        }) else {
            return nil
        }
        return CGRect(
            x: space.appKitFrame.minX + frame.minX - space.quartzFrame.minX,
            y:
                space.appKitFrame.maxY
                - (frame.minY - space.quartzFrame.minY)
                - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

enum PermissionAssistArrowDirection: Equatable {
    case left
    case right
}

private enum SystemSettingsWindowLocator {
    static var isSystemSettingsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.apple.SystemSettings"
                || app.bundleIdentifier == "com.apple.systempreferences"
                || (app.localizedName ?? "").localizedCaseInsensitiveContains("System Settings")
                || (app.localizedName ?? "").contains("系统设置")
        }
    }

    static func visibleWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleIdentifier == "com.apple.SystemSettings"
                || app.bundleIdentifier == "com.apple.systempreferences"
                || (app.localizedName ?? "").localizedCaseInsensitiveContains("System Settings")
                || (app.localizedName ?? "").contains("系统设置")
        }) else {
            return nil
        }
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates = windowList.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rawFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rawFrame.width > 120,
                  rawFrame.height > 120 else {
                return nil
            }
            return convertQuartzWindowFrame(rawFrame)
        }
        return candidates.max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func convertQuartzWindowFrame(_ frame: CGRect) -> CGRect {
        let coordinateSpaces = NSScreen.screens.compactMap { screen -> PermissionAssistPlacementGeometry.CoordinateSpace? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return .init(
                quartzFrame: CGDisplayBounds(displayID),
                appKitFrame: screen.frame
            )
        }
        return PermissionAssistPlacementGeometry.appKitFrame(
            forQuartzWindow: frame,
            coordinateSpaces: coordinateSpaces
        ) ?? frame
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(minX, bounds.minX), max(bounds.minX, bounds.maxX - width)),
            y: min(max(minY, bounds.minY), max(bounds.minY, bounds.maxY - height)),
            width: width,
            height: height
        )
    }
}
