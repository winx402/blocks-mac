import AppKit
import OSLog
import SwiftUI

@MainActor
final class ClipboardQuickPasteHintState: ObservableObject {
    @Published private(set) var isCommandKeyPressed = false
    @Published private(set) var snapshotRecordIDs: [String] = []
    @Published private(set) var snapshotCaptured = false

    func setCommandKeyPressed(_ isPressed: Bool) {
        guard isCommandKeyPressed != isPressed else {
            return
        }
        isCommandKeyPressed = isPressed
        if !isPressed {
            snapshotRecordIDs = []
            snapshotCaptured = false
        }
    }

    func captureSnapshotIfNeeded(visibleRecordIDs: [String]) {
        guard isCommandKeyPressed, !snapshotCaptured else {
            return
        }
        snapshotRecordIDs = Array(visibleRecordIDs.prefix(9))
        snapshotCaptured = true
    }

    func reset() {
        isCommandKeyPressed = false
        snapshotRecordIDs = []
        snapshotCaptured = false
    }

    func quickPasteIndex(for recordID: String) -> Int? {
        guard isCommandKeyPressed,
              snapshotCaptured,
              let index = snapshotRecordIDs.firstIndex(of: recordID) else {
            return nil
        }
        return index + 1
    }

    func recordID(forQuickPasteIndex index: Int) -> String? {
        let zeroBasedIndex = index - 1
        guard zeroBasedIndex >= 0, zeroBasedIndex < snapshotRecordIDs.count else {
            return nil
        }
        return snapshotRecordIDs[zeroBasedIndex]
    }
}

@MainActor
final class ClipboardPanelPinState: ObservableObject {
    @Published private(set) var isPinned = false

    func setPinned(_ pinned: Bool) {
        guard isPinned != pinned else {
            return
        }
        isPinned = pinned
    }

    func toggle() {
        setPinned(!isPinned)
    }

    func reset() {
        setPinned(false)
    }
}

struct ClipboardPanelActions {
    let pasteQuickRecord: (Int) -> Void
    let pasteRecord: (String) -> Void
    let translateRecord: (String) -> Void
    let copyRecordAsPlainText: (String) -> Void
    let deleteHistoryItem: (String) async -> Bool
    let toggleFavorite: (String) -> Void
    let setTagFilter: (String?) -> Void
    let toggleTag: @MainActor (String, String) async -> Void
    let createTagAndAttach: @MainActor (String, String) async -> Void

    init(
        pasteQuickRecord: @escaping (Int) -> Void,
        pasteRecord: @escaping (String) -> Void,
        translateRecord: @escaping (String) -> Void,
        copyRecordAsPlainText: @escaping (String) -> Void,
        deleteHistoryItem: @escaping (String) async -> Bool,
        toggleFavorite: @escaping (String) -> Void,
        setTagFilter: @escaping (String?) -> Void,
        toggleTag: @escaping @MainActor (String, String) async -> Void = { _, _ in },
        createTagAndAttach: @escaping @MainActor (String, String) async -> Void = { _, _ in }
    ) {
        self.pasteQuickRecord = pasteQuickRecord
        self.pasteRecord = pasteRecord
        self.translateRecord = translateRecord
        self.copyRecordAsPlainText = copyRecordAsPlainText
        self.deleteHistoryItem = deleteHistoryItem
        self.toggleFavorite = toggleFavorite
        self.setTagFilter = setTagFilter
        self.toggleTag = toggleTag
        self.createTagAndAttach = createTagAndAttach
    }
}

enum ClipboardPanelInvocationSource: String {
    case floatingPanel = "floating-panel"
    case verification = "verification"
}

struct ClipboardPanelInvocationContext {
    let id: UUID
    let source: ClipboardPanelInvocationSource
    let openedAt: Date
    var targetContext: ClipboardPasteTargetContext?
}

enum ClipboardHistoryPanelStyle {
    /// The clipboard surface owns its own chrome and resize affordances. A
    /// hidden AppKit title bar still participates in Screen Sharing's window
    /// indicator lifecycle, where AppKit can transiently lay out an indicator
    /// at a negative size. Keeping this panel genuinely titleless removes that
    /// inaccessible duplicate chrome instead of masking the runtime warning.
    static let mask: NSWindow.StyleMask = [
        .resizable,
        .fullSizeContentView,
        .nonactivatingPanel,
    ]
}

@MainActor
final class ClipboardExternalTargetTracker {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-target"
    )
    private var activationObserver: NSObjectProtocol?
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private let frontmostVisibleApplication: @MainActor () -> NSRunningApplication?
    private let eligibleApplication: @MainActor (NSRunningApplication?) -> NSRunningApplication?
    private let captureContext: @MainActor (NSRunningApplication) -> ClipboardPasteTargetContext
    var onTargetActivated: ((ClipboardPasteTargetContext) -> Void)?

    init(
        frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        frontmostVisibleApplication: @escaping @MainActor () -> NSRunningApplication? = {
            ClipboardPasteTargetEligibility.frontmostVisibleEligibleApplication()
        },
        eligibleApplication: @escaping @MainActor (NSRunningApplication?) -> NSRunningApplication? = {
            ClipboardPasteTargetEligibility.eligibleApplication($0)
        },
        captureContext: @escaping @MainActor (NSRunningApplication) -> ClipboardPasteTargetContext = {
            ClipboardAutoPasteCoordinator.capturePasteTargetContext(application: $0)
        },
        observesActivations: Bool = true
    ) {
        self.frontmostApplication = frontmostApplication
        self.frontmostVisibleApplication = frontmostVisibleApplication
        self.eligibleApplication = eligibleApplication
        self.captureContext = captureContext
        guard observesActivations else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                guard let self,
                      !self.recordExplicitActivation(application) else {
                    return
                }
                // Some applications publish their activation notification just
                // before the first layer-0 window becomes visible. Re-check the
                // same explicitly activated app once instead of losing the new
                // pinned-panel target or accepting an unrelated process.
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard self.frontmostApplication()?.processIdentifier
                        == application.processIdentifier else {
                    return
                }
                self.recordExplicitActivation(application)
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func contextForInvocation() -> ClipboardPasteTargetContext? {
        guard let application = resolvedCurrentApplication() else {
            Self.logger.info("stage=invocation-target-missing")
            return nil
        }
        let context = captureContext(application)
        Self.logger.info(
            "stage=invocation-target-refreshed targetPID=\(context.target.processIdentifier) targetBundle=\(context.target.bundleIdentifier ?? "none", privacy: .public)"
        )
        return context
    }

    @discardableResult
    func recordExplicitActivation(_ application: NSRunningApplication) -> Bool {
        guard let application = eligibleApplication(application) else {
            return false
        }
        let context = captureContext(application)
        onTargetActivated?(context)
        Self.logger.info(
            "stage=external-target-activated targetPID=\(context.target.processIdentifier) targetBundle=\(context.target.bundleIdentifier ?? "none", privacy: .public) capturedWindow=\(context.focusedWindow != nil) capturedRole=\(context.focusedIdentity?.role ?? "missing", privacy: .public)"
        )
        return true
    }

    private func resolvedCurrentApplication() -> NSRunningApplication? {
        let reportedApplication = frontmostApplication()
        if let application = eligibleApplication(reportedApplication) {
            return application
        }
        guard ClipboardPasteTargetEligibility.shouldUseVisibleWindowFallback(
            after: reportedApplication
        ) else {
            return nil
        }
        return eligibleApplication(frontmostVisibleApplication())
    }

}

@MainActor
final class ClipboardHistoryPanelPresenter: NSObject, NSWindowDelegate {
    enum PresentationResult {
        case shown
        case suppressed
    }

    private static let pasteLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-panel-paste"
    )
    private var panel: NSPanel?
    private weak var detailStore: ClipboardDetailStore?
    private let dismissMonitor = FloatingPanelDismissMonitor()
    private let presentationCoordinator: BlocksFloatingPanelPresentationCoordinator
    private let regularWindowVisibilitySession =
        BlocksRegularWindowVisibilitySession()
    private var currentPosition: FloatingPanelPosition = .bottom
    private var invocationContext: ClipboardPanelInvocationContext?
    private var isApplyingAnchoredFrame = false
    private var recentCloseGuard = FloatingPanelRecentCloseGuard()
    private let shouldSuppressRecentOpen: (() -> Bool)?
    private var isClosePending = false
    // A non-nil value means this close was initiated by the matching paste
    // transaction, not by the user or the system.
    private var pasteInitiatedCloseSessionID: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var afterCloseActions: [() -> Void] = []
    private var onCloseStarted: ((UUID?, UUID?) -> Void) = { _, _ in }
    private var closeStartNotified = false
    private var onClosed: ((UUID?) -> Void)?
    private var appResignActiveObserver: NSObjectProtocol?
    private let quickPasteHintState = ClipboardQuickPasteHintState()
    private let pinState = ClipboardPanelPinState()
    private let externalTargetTracker: ClipboardExternalTargetTracker
    private let eligiblePasteTarget: @MainActor (NSRunningApplication?) -> Bool
    private let focusCoordinator = ClipboardPanelFocusCoordinator()
    private var notificationPresenter: BlocksAnchoredNotificationPanelPresenter?
    private weak var pluginManager: BlocksNativePluginManager?
    private weak var pluginRuntime: BlocksPluginRuntimeCoordinator?
    private lazy var keyboardRouter = ClipboardPanelKeyboardCommandRouter(
        focusCoordinator: focusCoordinator
    )

    override init() {
        presentationCoordinator = BlocksFloatingPanelPresentationCoordinator()
        shouldSuppressRecentOpen = nil
        externalTargetTracker = ClipboardExternalTargetTracker()
        eligiblePasteTarget = { ClipboardPasteTargetEligibility.eligibleApplication($0) != nil }
        super.init()
        configureExternalTargetTracker()
    }

    init(
        presentationCoordinator: BlocksFloatingPanelPresentationCoordinator,
        shouldSuppressRecentOpen: (() -> Bool)? = nil,
        externalTargetTracker: ClipboardExternalTargetTracker? = nil,
        eligiblePasteTarget: @escaping @MainActor (NSRunningApplication?) -> Bool = {
            ClipboardPasteTargetEligibility.eligibleApplication($0) != nil
        }
    ) {
        self.presentationCoordinator = presentationCoordinator
        self.shouldSuppressRecentOpen = shouldSuppressRecentOpen
        self.externalTargetTracker = externalTargetTracker
            ?? ClipboardExternalTargetTracker()
        self.eligiblePasteTarget = eligiblePasteTarget
        super.init()
        configureExternalTargetTracker()
    }

    private func configureExternalTargetTracker() {
        externalTargetTracker.onTargetActivated = { [weak self] context in
            self?.updatePinnedTargetContext(context)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var usesNonactivatingPanel: Bool {
        panel?.styleMask.contains(.nonactivatingPanel) == true
    }

    var invocationID: UUID? {
        invocationContext?.id
    }

    var isApplicationObservationActive: Bool {
        appResignActiveObserver != nil
    }

    var invocationTargetPID: pid_t? {
        invocationContext?.targetContext?.target.processIdentifier
    }

    // Internal testing accessors; test bundles may be compiled with Release settings.
    var pinStateForTesting: ClipboardPanelPinState { pinState }
    var focusCoordinatorForTesting: ClipboardPanelFocusCoordinator { focusCoordinator }

    func shouldSuppressOpen() -> Bool {
        guard panel?.isVisible != true else {
            return false
        }
        return shouldSuppressRecentOpen?() ?? recentCloseGuard.shouldSuppressOpen()
    }

    func configurePluginPlatform(
        manager: BlocksNativePluginManager?,
        runtime: BlocksPluginRuntimeCoordinator?
    ) {
        pluginManager = manager
        pluginRuntime = runtime
    }

    func captureInvocation(
        source: ClipboardPanelInvocationSource
    ) -> ClipboardPanelInvocationContext {
        let targetContext = externalTargetTracker.contextForInvocation()
        let context = ClipboardPanelInvocationContext(
            id: UUID(),
            source: source,
            openedAt: Date(),
            targetContext: targetContext
        )
        Self.pasteLogger.info(
            "stage=invocation-captured invocation=\(context.id.uuidString, privacy: .public) source=\(source.rawValue, privacy: .public) targetPID=\(targetContext?.target.processIdentifier ?? 0) targetBundle=\(targetContext?.target.bundleIdentifier ?? "none", privacy: .public)"
        )
        return context
    }

    func present(
        clipboardStore: ClipboardStore,
        notificationState: BlocksNotificationPresentationState,
        actions: ClipboardPanelActions,
        position: FloatingPanelPosition,
        invocationContext: ClipboardPanelInvocationContext,
        openMainWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        onCloseStarted: @escaping (UUID?, UUID?) -> Void = { _, _ in },
        onClosed: @escaping (UUID?) -> Void
    ) -> PresentationResult {
        if shouldSuppressOpen() {
            return .suppressed
        }
        let replacedPendingClose = replacePendingCloseForNewInvocation()
        if let panel, panel.isVisible, !replacedPendingClose {
            startApplicationObservationIfNeeded()
            recentCloseGuard.clear()
            focus()
            if pinState.isPinned {
                dismissMonitor.stop()
            } else {
                startDismissMonitor(for: panel)
            }
            notificationPresenter?.attach(to: panel)
            notificationPresenter?.reposition()
            return .shown
        }
        currentPosition = position
        self.onCloseStarted = onCloseStarted
        closeStartNotified = false
        self.onClosed = onClosed
        self.invocationContext = invocationContext
        detailStore = clipboardStore.detailStore
        pinState.reset()
        focusCoordinator.beginSession(sessionID: invocationContext.id)
        recentCloseGuard.clear()
        startApplicationObservationIfNeeded()

        let initialFrame = frame(for: position)
        let contentView = ClipboardFloatingPanelView(
            position: position,
            actions: actions,
            quickPasteHintState: quickPasteHintState,
            pinState: pinState,
            focusCoordinator: focusCoordinator,
            keyboardRouter: keyboardRouter,
            pluginManager: pluginManager,
            pluginRuntime: pluginRuntime,
            onOpenMainWindow: openMainWindow,
            onOpenSettings: { [weak self] in
                self?.openSettingsFromPanel(openSettings)
            },
            onTogglePin: { [weak self] in
                self?.togglePanelPinned()
            },
            onRootEscape: { [weak self] in self?.handleRootEscape() }
        )
        .environmentObject(clipboardStore)

        let panel = panel ?? makePanel(initialFrame: initialFrame)
        if let clipboardPanel = panel as? ClipboardHistoryPanel {
            clipboardPanel.keyboardRouter = keyboardRouter
            clipboardPanel.onCommandModifierChanged = { [weak self] isPressed in
                self?.quickPasteHintState.setCommandKeyPressed(isPressed)
            }
        }
        let topResizeView = ClipboardTopBorderResizeView()
        topResizeView.isEnabled = position == .bottom
        topResizeView.onTopBorderResize = { [weak self, weak panel] proposedHeight in
            guard let self, let panel else {
                return
            }
            self.applyTopBorderResize(proposedHeight: proposedHeight, panel: panel)
        }
        topResizeView.onTopBorderResizeEnded = { [weak self, weak panel] in
            guard let self, let panel else {
                return
            }
            self.finishTopBorderResize(panel: panel)
        }
        let sideResizeView = ClipboardSideBorderResizeView()
        sideResizeView.position = position
        sideResizeView.isEnabled = position != .bottom
        sideResizeView.onSideBorderResize = { [weak self, weak panel] proposedWidth in
            guard let self, let panel else {
                return
            }
            self.applySideBorderResize(proposedWidth: proposedWidth, panel: panel)
        }
        sideResizeView.onSideBorderResizeEnded = { [weak self, weak panel] in
            guard let self, let panel else {
                return
            }
            self.finishSideBorderResize(panel: panel)
        }
        panel.contentView = ClipboardPanelContentContainer(
            hostingView: ClipboardFirstMouseHostingView(rootView: contentView),
            topResizeView: topResizeView,
            sideResizeView: sideResizeView,
            position: position
        )
        focusCoordinator.registerParentWindow(panel)
        panel.minSize = minSize(for: position)
        panel.maxSize = maxSize(for: position)
        panel.setFrame(initialFrame, display: false)
        anchorPanel(panel)
        dismissMonitor.stop()
        self.panel = panel
        regularWindowVisibilitySession.hideRegularWindows(excluding: panel)
        presentationCoordinator.present(
            window: panel,
            frame: panel.frame,
            makeKey: true
        ) { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.panel === panel else {
                return
            }
            self.startDismissMonitor(for: panel)
            let notificationPresenter = self.notificationPresenter
                ?? BlocksAnchoredNotificationPanelPresenter(
                    state: notificationState
                )
            self.notificationPresenter = notificationPresenter
            notificationPresenter.attach(to: panel)
            notificationPresenter.reposition()
        }
        Self.pasteLogger.info(
            "stage=panel-presented invocation=\(invocationContext.id.uuidString, privacy: .public) targetPID=\(invocationContext.targetContext?.target.processIdentifier ?? 0) targetBundle=\(invocationContext.targetContext?.target.bundleIdentifier ?? "none", privacy: .public) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none", privacy: .public)"
        )
        return .shown
    }

    func close() {
        requestClosePanel()
    }

    func forceCloseForRuntimeDisable() {
        detailStore?.forceCloseForRuntimeDisable()
        closePanel(animated: false, interruptingPendingClose: true)
    }

    func close(afterClose: @escaping () -> Void) {
        requestDirtyAction(after: afterClose)
    }

    func authorizePasteAction(_ action: @escaping () -> Void) {
        guard let detailStore else {
            action()
            return
        }
        detailStore.requestAction(after: action)
    }

    @discardableResult
    func releasePanelForPaste(
        sessionID: UUID,
        expectedInvocationID: UUID
    ) -> Bool {
        guard !isClosePending,
              let panel,
              panel.isVisible,
              invocationContext?.id == expectedInvocationID else {
            Self.pasteLogger.info(
                "stage=panel-release-skipped session=\(sessionID.uuidString, privacy: .public) expectedInvocation=\(expectedInvocationID.uuidString, privacy: .public) actualInvocation=\(self.invocationContext?.id.uuidString ?? "none", privacy: .public) reason=close-pending-not-visible-or-stale-invocation"
            )
            return false
        }
        dismissMonitor.stop()
        if pinState.isPinned {
            panel.resignKey()
            focusCoordinator.releasePinnedPanel()
            presentationCoordinator.bringForward(
                window: panel,
                makeKey: false
            )
            Self.pasteLogger.info(
                "stage=panel-released session=\(sessionID.uuidString, privacy: .public) pinned=true visible=true"
            )
            return true
        } else {
            Self.pasteLogger.info(
                "stage=panel-closing-after-copy session=\(sessionID.uuidString, privacy: .public) pinned=false"
            )
            closePanel(animated: false, pasteInitiatedSessionID: sessionID)
            return true
        }
    }

    private func requestDirtyAction(after action: @escaping () -> Void) {
        let shouldClosePanel = !pinState.isPinned
        let guardedAction: () -> Void = { [weak self] in
            if shouldClosePanel {
                guard let self else { return }
                self.closePanel(animated: true, afterClose: action)
            } else {
                action()
            }
        }
        guard let detailStore else {
            guardedAction()
            return
        }
        detailStore.requestAction(after: guardedAction)
    }

    private func requestClosePanel(afterClose: (() -> Void)? = nil) {
        guard !pinState.isPinned else {
            return
        }
        if let detailStore, detailStore.isDirty {
            detailStore.requestPanelClose { [weak self] in
                self?.closePanel(animated: true, afterClose: afterClose)
            }
            return
        }
        detailStore?.requestClose()
        guard panel?.isVisible == true else {
            closePanel(animated: false)
            afterClose?()
            return
        }
        closePanel(animated: true, afterClose: afterClose)
    }

    private func closePanel(
        animated: Bool,
        afterClose: (() -> Void)? = nil,
        interruptingPendingClose: Bool = false,
        pasteInitiatedSessionID: UUID? = nil
    ) {
        if let afterClose {
            afterCloseActions.append(afterClose)
        }
        guard !isClosePending || interruptingPendingClose else { return }
        guard let panel else {
            finishCloseLifecycle(panel: nil)
            return
        }
        pasteInitiatedCloseSessionID = pasteInitiatedSessionID
        isClosePending = true
        notifyCloseStartedIfNeeded()
        lifecycleGeneration &+= 1
        let closeGeneration = lifecycleGeneration
        dismissMonitor.stop()
        notificationPresenter?.detach()
        ClipboardPanelChildWindowLifecycle.dismissChildren(of: panel)
        let complete = { [weak self, weak panel] in
            guard let self,
                  let panel else {
                return
            }
            guard self.lifecycleGeneration == closeGeneration,
                  self.isClosePending,
                  self.panel === panel else {
                return
            }
            panel.close()
            if self.isClosePending {
                self.finishCloseWithoutWindowNotification(panel: panel)
            }
        }
        if animated, panel.isVisible {
            if presentationCoordinator.dismiss(
                window: panel,
                completion: complete
            ) {
                return
            }
        }
        presentationCoordinator.closeImmediately(
            window: panel,
            completion: complete
        )
    }

    @discardableResult
    private func replacePendingCloseForNewInvocation() -> Bool {
        lifecycleGeneration &+= 1
        guard isClosePending else { return false }
        isClosePending = false
        pasteInitiatedCloseSessionID = nil
        closeStartNotified = false
        afterCloseActions.removeAll()
        return true
    }

    private func handleRootEscape() {
        guard pinState.isPinned else {
            requestClosePanel()
            return
        }
        panel?.resignKey()
        focusCoordinator.releasePinnedPanel()
    }

    private func openSettingsFromPanel(_ openSettings: @escaping () -> Void) {
        if pinState.isPinned {
            requestDirtyAction(after: openSettings)
        } else {
            requestClosePanel(afterClose: openSettings)
        }
    }

    private func togglePanelPinned() {
        pinState.toggle()
        guard let panel, panel.isVisible else {
            return
        }
        if pinState.isPinned {
            dismissMonitor.stop()
            capturePinnedTargetIfEligible()
            regularWindowVisibilitySession.restore()
        } else {
            startDismissMonitor(for: panel)
        }
    }

    func focus() {
        guard let panel, panel.isVisible else {
            return
        }
        regularWindowVisibilitySession.hideRegularWindows(excluding: panel)
        anchorPanel(panel)
        presentationCoordinator.bringForward(window: panel, makeKey: true)
        if focusCoordinator.target == .inactive {
            focusCoordinator.focusSearch(reason: .panelRefocused)
        } else {
            focusCoordinator.restoreKeyWindowForCurrentTarget()
        }
    }

    private func startDismissMonitor(for panel: NSPanel) {
        guard panel.isVisible,
              !pinState.isPinned else {
            return
        }
        dismissMonitor.start(panel: panel) { [weak self] in
            self?.requestClosePanel()
        }
    }

    func targetContextForPaste() -> ClipboardPasteTargetContext? {
        guard isVisible else { return nil }
        if pinState.isPinned {
            guard let current = externalTargetTracker.contextForInvocation() else { return nil }
            updatePinnedTargetContext(current)
        }
        guard let targetContext = invocationContext?.targetContext,
              isEligiblePasteTarget(targetContext.target.runningApplication) else {
            return nil
        }
        return targetContext
    }

    func targetContextForDirectAction() -> ClipboardPasteTargetContext? {
        externalTargetTracker.contextForInvocation()
    }

    func quickPasteSnapshotRecordID(index: Int) -> String? {
        quickPasteHintState.recordID(forQuickPasteIndex: index)
    }

    func captureQuickPasteSnapshotIfNeeded(visibleRecordIDs: [String]) {
        quickPasteHintState.captureSnapshotIfNeeded(visibleRecordIDs: visibleRecordIDs)
    }

    private func makePanel(initialFrame: CGRect) -> NSPanel {
        let panel = ClipboardHistoryPanel(
            contentRect: initialFrame,
            styleMask: ClipboardHistoryPanelStyle.mask,
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.string("clipboard.panel.title")
        BlocksFloatingPanelWindowRole.transientNonactivatingUtility.apply(to: panel)
        panel.delegate = self
        return panel
    }

    private func frame(for position: FloatingPanelPosition) -> CGRect {
        FloatingPanelFrameStore.clipboardFrame(position: position)
    }

    private func anchorPanel(_ panel: NSPanel, preservingBottomHeight height: CGFloat? = nil) {
        guard !isApplyingAnchoredFrame else {
            return
        }
        let anchorFrame = anchoredFrame(for: panel, preservingBottomHeight: height ?? panel.frame.height)
        guard !panel.frame.nearlyMatches(anchorFrame) else {
            notificationPresenter?.reposition()
            return
        }
        isApplyingAnchoredFrame = true
        defer { isApplyingAnchoredFrame = false }
        panel.setFrame(anchorFrame, display: true)
        notificationPresenter?.reposition()
    }

    private func anchoredFrame(
        for panel: NSPanel,
        preservingBottomHeight height: CGFloat? = nil
    ) -> CGRect {
        let screen = panel.screen ?? NSScreen.main
        switch currentPosition {
        case .bottom:
            return FloatingPanelFrameStore.clipboardBottomFrame(screen: screen, height: height)
        case .left, .right:
            return FloatingPanelFrameStore.clipboardSideFrame(position: currentPosition, screen: screen)
        }
    }

    private func applyTopBorderResize(proposedHeight: CGFloat, panel: NSPanel) {
        guard currentPosition == .bottom else {
            return
        }
        anchorPanel(panel, preservingBottomHeight: proposedHeight)
    }

    private func finishTopBorderResize(panel: NSPanel) {
        guard currentPosition == .bottom else {
            anchorPanel(panel)
            return
        }
        anchorPanel(panel, preservingBottomHeight: panel.frame.height)
        FloatingPanelFrameStore.saveClipboard(frame: panel.frame, position: currentPosition)
    }

    private func applySideBorderResize(proposedWidth: CGFloat, panel: NSPanel) {
        guard currentPosition != .bottom else {
            return
        }
        let frame = FloatingPanelFrameStore.clipboardSideFrame(
            position: currentPosition,
            screen: panel.screen ?? NSScreen.main,
            width: proposedWidth
        )
        isApplyingAnchoredFrame = true
        defer { isApplyingAnchoredFrame = false }
        panel.setFrame(frame, display: true)
        notificationPresenter?.reposition()
    }

    private func finishSideBorderResize(panel: NSPanel) {
        guard currentPosition != .bottom else {
            return
        }
        applySideBorderResize(proposedWidth: panel.frame.width, panel: panel)
        FloatingPanelFrameStore.saveClipboardSideWidth(frame: panel.frame, position: currentPosition)
    }

    private func minSize(for position: FloatingPanelPosition) -> CGSize {
        switch position {
        case .bottom:
            return FloatingPanelFrameStore.clipboardResizeSize(
                proposedSize: .zero,
                position: position
            )
        case .left, .right:
            let frame = FloatingPanelFrameStore.clipboardFrame(position: position)
            return CGSize(width: FloatingPanelFrameStore.clipboardSideMinWidth, height: frame.height)
        }
    }

    private func maxSize(for position: FloatingPanelPosition) -> CGSize {
        switch position {
        case .bottom:
            return FloatingPanelFrameStore.clipboardResizeSize(
                proposedSize: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                position: position
            )
        case .left, .right:
            return FloatingPanelFrameStore.clipboardResizeSize(
                proposedSize: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                position: position
            )
        }
    }

    private func capturePinnedTargetIfEligible() {
        guard pinState.isPinned,
              let targetContext = externalTargetTracker.contextForInvocation() else {
            return
        }
        updatePinnedTargetContext(targetContext)
    }

    private func startApplicationObservationIfNeeded() {
        if appResignActiveObserver == nil {
            appResignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.quickPasteHintState.reset()
                }
            }
        }
    }

    private func stopApplicationObservation() {
        if let appResignActiveObserver {
            NotificationCenter.default.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }
    }

    private func updatePinnedTargetContext(_ targetContext: ClipboardPasteTargetContext) {
        guard pinState.isPinned,
              isEligiblePasteTarget(targetContext.target.runningApplication) else {
            return
        }
        invocationContext?.targetContext = targetContext
        Self.pasteLogger.info(
            "stage=pinned-target-updated invocation=\(self.invocationContext?.id.uuidString ?? "none", privacy: .public) targetPID=\(targetContext.target.processIdentifier) targetBundle=\(targetContext.target.bundleIdentifier ?? "none", privacy: .public)"
        )
    }

    private func isEligiblePasteTarget(_ application: NSRunningApplication?) -> Bool {
        eligiblePasteTarget(application)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        FloatingPanelFrameStore.clipboardResizeSize(
            proposedSize: frameSize,
            position: currentPosition,
            screen: sender.screen ?? NSScreen.main
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard currentPosition == .bottom,
              let panel = notification.object as? NSPanel else {
            return
        }
        anchorPanel(panel, preservingBottomHeight: panel.frame.height)
        notificationPresenter?.reposition()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else {
            return
        }
        if currentPosition != .bottom {
            anchorPanel(panel)
        } else {
            anchorPanel(panel, preservingBottomHeight: panel.frame.height)
        }
        FloatingPanelFrameStore.saveClipboard(frame: panel.frame, position: currentPosition)
        notificationPresenter?.reposition()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else {
            return
        }
        guard !isApplyingAnchoredFrame else {
            return
        }
        anchorPanel(panel)
        notificationPresenter?.reposition()
    }

    func windowDidResignKey(_ notification: Notification) {
        quickPasteHintState.reset()
        guard let window = notification.object as? NSWindow else {
            return
        }
        focusCoordinator.windowResignedKey(.parent, window: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        focusCoordinator.windowBecameKey(.parent, window: window)
    }

    func windowWillClose(_ notification: Notification) {
        Self.pasteLogger.info(
            "stage=panel-window-closed invocation=\(self.invocationContext?.id.uuidString ?? "none", privacy: .public)"
        )
        guard let panel = notification.object as? NSPanel else {
            return
        }
        notifyCloseStartedIfNeeded()
        finishCloseLifecycle(panel: panel)
    }

    private func finishCloseWithoutWindowNotification(panel: NSPanel) {
        finishCloseLifecycle(panel: panel)
    }

    private func finishCloseLifecycle(panel: NSPanel?) {
        if let panel, panel !== self.panel {
            return
        }
        let closedPasteSessionID = pasteInitiatedCloseSessionID
        invocationContext = nil
        stopApplicationObservation()
        notificationPresenter?.detach()
        presentationCoordinator.reset()
        if let panel {
            recentCloseGuard.recordClose(panel: panel)
            panel.childWindows?.forEach { childWindow in
                panel.removeChildWindow(childWindow)
                childWindow.orderOut(nil)
            }
            FloatingPanelFrameStore.saveClipboard(frame: panel.frame, position: currentPosition)
            FloatingPanelFrameStore.saveClipboardSideWidth(frame: panel.frame, position: currentPosition)
        }
        if let clipboardPanel = panel as? ClipboardHistoryPanel {
            clipboardPanel.keyboardRouter = nil
            clipboardPanel.onCommandModifierChanged = nil
        }
        keyboardRouter.reset()
        focusCoordinator.endSession()
        quickPasteHintState.reset()
        pinState.reset()
        dismissMonitor.stop()
        regularWindowVisibilitySession.restore()
        isClosePending = false
        onClosed?(closedPasteSessionID)
        onClosed = nil
        pasteInitiatedCloseSessionID = nil
        closeStartNotified = false
        detailStore = nil
        self.panel = nil
        runAfterCloseActions()
    }

    private func runAfterCloseActions() {
        let actions = afterCloseActions
        afterCloseActions.removeAll()
        actions.forEach { $0() }
    }

    private func notifyCloseStartedIfNeeded() {
        guard !closeStartNotified else { return }
        closeStartNotified = true
        onCloseStarted(pasteInitiatedCloseSessionID, invocationContext?.id)
    }
}

private extension CGRect {
    func nearlyMatches(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

@MainActor
enum ClipboardPanelChildWindowLifecycle {
    static func dismissChildren(of panel: NSPanel) {
        panel.childWindows?.forEach { childWindow in
            BlocksAppKitMotion.cancelAnimations(on: childWindow)
            panel.removeChildWindow(childWindow)
            childWindow.orderOut(nil)
            childWindow.alphaValue = 1
        }
    }
}

private final class ClipboardHistoryPanel: NSPanel {
    weak var keyboardRouter: ClipboardPanelKeyboardCommandRouter?
    var onCommandModifierChanged: ((Bool) -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            onCommandModifierChanged?(Self.commandModifierPressed(in: event))
        }
        if keyboardRouter?.route(event) == true {
            if event.modifierFlags.contains(.command) {
                onCommandModifierChanged?(true)
            }
            return
        }
        super.sendEvent(event)
    }

    private static func commandModifierPressed(in event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command]).contains(.command)
    }

}

private final class ClipboardFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

private final class ClipboardPanelContentContainer: NSView {
    init(
        hostingView: NSView,
        topResizeView: ClipboardTopBorderResizeView,
        sideResizeView: ClipboardSideBorderResizeView,
        position: FloatingPanelPosition
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        addSubview(topResizeView)
        addSubview(sideResizeView)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        topResizeView.translatesAutoresizingMaskIntoConstraints = false
        sideResizeView.translatesAutoresizingMaskIntoConstraints = false

        var constraints = [
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            topResizeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topResizeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topResizeView.topAnchor.constraint(equalTo: hostingView.safeAreaLayoutGuide.topAnchor, constant: -2),
            topResizeView.heightAnchor.constraint(equalToConstant: ClipboardTopBorderResizeView.topBorderResizeHitHeight),
            sideResizeView.topAnchor.constraint(equalTo: topAnchor),
            sideResizeView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sideResizeView.widthAnchor.constraint(equalToConstant: ClipboardSideBorderResizeView.sideBorderResizeHitWidth)
        ]
        switch position {
        case .left:
            constraints.append(sideResizeView.trailingAnchor.constraint(equalTo: trailingAnchor))
        case .right:
            constraints.append(sideResizeView.leadingAnchor.constraint(equalTo: leadingAnchor))
        case .bottom:
            constraints.append(sideResizeView.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

private final class ClipboardSideBorderResizeView: NSView {
    static let sideBorderResizeHitWidth: CGFloat = 16

    var position: FloatingPanelPosition = .left
    var isEnabled = false {
        didSet {
            discardCursorRects()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onSideBorderResize: ((CGFloat) -> Void)?
    var onSideBorderResizeEnded: (() -> Void)?

    private var startScreenX: CGFloat?
    private var startWidth: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isEnabled else {
            super.cursorUpdate(with: event)
            return
        }
        NSCursor.resizeLeftRight.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }
        startScreenX = NSEvent.mouseLocation.x
        startWidth = window?.frame.width
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled,
              let startScreenX,
              let startWidth else {
            return
        }
        let delta = NSEvent.mouseLocation.x - startScreenX
        let proposedWidth = position == .left ? startWidth + delta : startWidth - delta
        onSideBorderResize?(proposedWidth)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            super.mouseUp(with: event)
            return
        }
        startScreenX = nil
        startWidth = nil
        onSideBorderResizeEnded?()
    }
}

private final class ClipboardTopBorderResizeView: NSView {
    static let topBorderResizeHitHeight: CGFloat = 16

    var isEnabled = false {
        didSet {
            discardCursorRects()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onTopBorderResize: ((CGFloat) -> Void)?
    var onTopBorderResizeEnded: (() -> Void)?

    private var startScreenY: CGFloat?
    private var startHeight: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isEnabled else {
            super.cursorUpdate(with: event)
            return
        }
        NSCursor.resizeUpDown.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }
        startScreenY = NSEvent.mouseLocation.y
        startHeight = window?.frame.height
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled,
              let startScreenY,
              let startHeight else {
            super.mouseDragged(with: event)
            return
        }
        let deltaY = NSEvent.mouseLocation.y - startScreenY
        onTopBorderResize?(startHeight + deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            super.mouseUp(with: event)
            return
        }
        startScreenY = nil
        startHeight = nil
        onTopBorderResizeEnded?()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
