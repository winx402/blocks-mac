import AppKit
import BlocksCore
import Combine
import OSLog
import SwiftUI

struct TranslationPanelActions {
    let copyText:
        @MainActor (String) async -> ClipboardExplicitTextCopyOutcome
    let openFavorites: @MainActor () -> Void
    let openTranslationSettings: @MainActor () -> Void
    let retakeScreenshot: @MainActor () -> Void

    init(
        copyText:
            @escaping @MainActor (String) async
                -> ClipboardExplicitTextCopyOutcome,
        openFavorites: @escaping @MainActor () -> Void,
        openTranslationSettings: @escaping @MainActor () -> Void,
        retakeScreenshot: @escaping @MainActor () -> Void
    ) {
        self.copyText = copyText
        self.openFavorites = openFavorites
        self.openTranslationSettings = openTranslationSettings
        self.retakeScreenshot = retakeScreenshot
    }
}

struct TranslationPanelSuspension: Equatable {
    let frame: CGRect
    let wasVisible: Bool
    let wasKey: Bool
}

@MainActor
final class TranslationPanelPresenter: NSObject, NSWindowDelegate {
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationPanelFrame"
    )

    let id: UUID
    let model: TranslationPanelSessionModel

    private let actions: TranslationPanelActions
    private let pluginManager: BlocksNativePluginManager?
    private let pluginRuntime: BlocksPluginRuntimeCoordinator?
    private let notificationState = BlocksNotificationPresentationState()
    private lazy var notificationPresenter =
        BlocksNotificationPanelPresenter(state: notificationState)
    private var notificationObservation: AnyCancellable?
    private let presentationCoordinator =
        BlocksFloatingPanelPresentationCoordinator()
    private let onClose: @MainActor (UUID) -> Void
    private var panel: TranslationSessionPanel?
    private var pinObservation: AnyCancellable?
    private var systemInteractionObservation: AnyCancellable?
    private var directInteractionObservation: AnyCancellable?
    private let resultOrderDragCoordinator =
        TranslationServiceOrderDragCoordinator()
    private var isSuspended = false
    private var isForcingClose = false
    private var isClosePending = false
    private var didFinishClose = false
    private lazy var dismissalController =
        TranslationPanelDismissalController { [weak self] in
            self?.requestAnimatedClose()
        }

    init(
        model: TranslationPanelSessionModel,
        actions: TranslationPanelActions,
        pluginManager: BlocksNativePluginManager? = nil,
        pluginRuntime: BlocksPluginRuntimeCoordinator? = nil,
        onClose: @escaping @MainActor (UUID) -> Void
    ) {
        id = model.id
        self.model = model
        self.actions = actions
        self.pluginManager = pluginManager
        self.pluginRuntime = pluginRuntime
        self.onClose = onClose
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func present() {
        guard !didFinishClose else { return }
        let frame = centeredFrame(
            preferredSize: CGSize(width: 640, height: 520),
            inputContext: model.inputContext,
            restoresSavedSize: true
        )
        let contentView = TranslationFloatingPanelView(
            model: model,
            actions: actions,
            notificationState: notificationState,
            pluginManager: pluginManager,
            pluginRuntime: pluginRuntime,
            resultOrderDragCoordinator: resultOrderDragCoordinator,
            onExit: { [weak self] in
                self?.dismissalController.requestDismissIfAllowed()
            },
            onClose: { [weak self] in self?.requestAnimatedClose() }
        )

        let panel = panel ?? makePanel(initialFrame: frame)
        panel.minSize = CGSize(
            width: min(TranslationPanelMetrics.minimumWidth, frame.width),
            height: min(TranslationPanelMetrics.minimumHeight, frame.height)
        )
        panel.setFrame(frame, display: false)
        panel.contentView = TranslationFirstMouseHostingView(
            rootView: contentView
        )
        panel.onEscape = { [weak self] in
            self?.dismissalController.requestDismissIfAllowed()
        }
        panel.onRequestClose = { [weak self] in
            self?.requestAnimatedClose()
        }
        logFrame(
            frame,
            reason: "initial",
            screen: TranslationPanelScreenResolver.screen(
                for: model.inputContext
            )
        )
        self.panel = panel
        dismissalController.attach(panel: panel)
        isSuspended = false
        startPinObservation()
        startSystemInteractionObservation()
        startDirectInteractionObservation()
        presentationCoordinator.present(
            window: panel,
            frame: frame,
            makeKey: TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation(
                inputSource: model.inputSource
            )
        )
        startNotificationObservation()
        updateDismissalHandling()
    }

    func focus() {
        guard let panel, panel.isVisible else { return }
        presentationCoordinator.bringForward(window: panel, makeKey: true)
    }

    func focusSourceEditorIfPanelIsNotKey() {
        guard let panel,
              TranslationPanelSourceFocusPolicy.shouldRequestSourceFocus(
                isVisible: panel.isVisible,
                isKeyWindow: panel.isKeyWindow
              ) else {
            return
        }
        presentationCoordinator.bringForward(window: panel, makeKey: true)
        model.requestSourceFocus()
    }

    @discardableResult
    func suspendForCapture() -> TranslationPanelSuspension? {
        guard !didFinishClose, let panel else { return nil }
        let suspension = TranslationPanelSuspension(
            frame: panel.frame,
            wasVisible: panel.isVisible,
            wasKey: panel.isKeyWindow
        )
        isSuspended = true
        notificationState.setHostVisible(false)
        notificationPresenter.hide()
        updateDismissalHandling()
        presentationCoordinator.suspend(window: panel)
        return suspension
    }

    func resumeAfterCapture(
        _ suspension: TranslationPanelSuspension?,
        anchor: TranslationInputAnchor? = nil
    ) {
        guard !didFinishClose, let panel, let suspension else { return }
        let fallbackContext = anchor.map {
            TranslationInputContext(anchor: $0)
        }
        let context = model.inputContext ?? fallbackContext
        let frame = centeredFrame(
            preferredSize: suspension.frame.size,
            inputContext: context,
            restoresSavedSize: false
        )
        panel.setFrame(frame, display: true)
        logFrame(
            frame,
            reason: "resume-after-capture",
            screen: TranslationPanelScreenResolver.screen(for: context)
        )
        isSuspended = false
        guard suspension.wasVisible else { return }
        presentationCoordinator.present(
            window: panel,
            frame: frame,
            makeKey: suspension.wasKey
        )
        notificationState.setHostVisible(true)
        synchronizeNotification()
        updateDismissalHandling()
    }

    func close() {
        close(animated: false, allowDuringSystemInteraction: false)
    }

    func forceClose() {
        close(animated: false, allowDuringSystemInteraction: true)
    }

    private func requestAnimatedClose() {
        close(animated: true, allowDuringSystemInteraction: false)
    }

    private func close(
        animated: Bool,
        allowDuringSystemInteraction: Bool
    ) {
        guard !didFinishClose else { return }
        if animated && isClosePending {
            return
        }
        guard allowDuringSystemInteraction
                || !AppleTranslationSystemInteractionGuard.shared
                    .isActive else {
            return
        }
        guard let panel else {
            finishClose(panel: nil)
            return
        }
        let completeClose = { [self, weak panel] in
            guard let panel else {
                finishClose(panel: nil)
                return
            }
            isForcingClose = allowDuringSystemInteraction
            panel.close()
            isForcingClose = false
            if self.panel != nil {
                finishClose(panel: panel)
            }
        }
        guard panel.isVisible else {
            presentationCoordinator.closeImmediately(
                window: panel,
                completion: completeClose
            )
            return
        }
        if !animated || allowDuringSystemInteraction {
            presentationCoordinator.closeImmediately(
                window: panel,
                completion: completeClose
            )
            return
        }
        isClosePending = true
        _ = presentationCoordinator.dismiss(
            window: panel,
            completion: completeClose
        )
    }

    private func makePanel(initialFrame: CGRect) -> TranslationSessionPanel {
        let panel = TranslationSessionPanel(
            contentRect: initialFrame,
            styleMask: [
                .nonactivatingPanel,
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.string("translation.panel.title")
        BlocksFloatingPanelWindowRole.nonactivatingSession.apply(to: panel)
        panel.delegate = self
        return panel
    }

    private func centeredFrame(
        preferredSize: CGSize,
        inputContext: TranslationInputContext?,
        restoresSavedSize: Bool
    ) -> CGRect {
        let screen = TranslationPanelScreenResolver.screen(
            for: inputContext
        )
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let resolvedSize: CGSize
        if restoresSavedSize {
            resolvedSize = FloatingPanelFrameStore.frame(
                kind: .translation,
                position: nil,
                defaultSize: preferredSize,
                minSize: CGSize(
                    width: TranslationPanelMetrics.minimumWidth,
                    height: TranslationPanelMetrics.minimumHeight
                ),
                screen: screen
            ).size
        } else {
            resolvedSize = preferredSize
        }
        return TranslationPanelGeometry.centeredFrame(
            preferredSize: resolvedSize,
            visibleFrame: visible
        )
    }

    private func logFrame(
        _ frame: CGRect,
        reason: String,
        screen: NSScreen?
    ) {
        let displayID = TranslationPanelScreenResolver
            .displayIdentifier(for: screen) ?? "unknown"
        Self.logger.info(
            "entry=\(self.model.inputSource.rawValue, privacy: .public) reason=\(reason, privacy: .public) display=\(displayID, privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public)"
        )
    }

    private func updateDismissalHandling() {
        dismissalController.update(
            TranslationPanelDismissalState(
                isVisible: panel?.isVisible == true,
                isPinned: model.isPinned,
                isSuspended: isSuspended,
                isSystemInteractionActive:
                    AppleTranslationSystemInteractionGuard.shared.isActive,
                isDirectInteractionActive:
                    resultOrderDragCoordinator.activeServiceID != nil
            )
        )
    }

    private func startPinObservation() {
        guard pinObservation == nil else { return }
        pinObservation = model.$isPinned
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateDismissalHandling()
            }
    }

    private func startNotificationObservation() {
        guard notificationObservation == nil else { return }
        notificationObservation = notificationState.$presentationRevision
            .sink { [weak self] _ in
                self?.synchronizeNotification()
            }
    }

    private func synchronizeNotification() {
        guard let panel, panel.isVisible, !isSuspended,
              !didFinishClose, !isClosePending else {
            notificationPresenter.hide()
            return
        }
        notificationPresenter.synchronize(
            on: panel.screen ?? TranslationPanelScreenResolver.screen(
                for: model.inputContext
            ),
            avoiding: [panel.frame]
        )
    }

    private func startSystemInteractionObservation() {
        guard systemInteractionObservation == nil else { return }
        systemInteractionObservation =
            AppleTranslationSystemInteractionGuard.shared.$isActive
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.updateDismissalHandling()
                }
    }

    private func startDirectInteractionObservation() {
        guard directInteractionObservation == nil else { return }
        directInteractionObservation = resultOrderDragCoordinator
            .$activeServiceID
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateDismissalHandling()
            }
    }

    private func finishClose(panel closingPanel: NSPanel?) {
        guard !didFinishClose else { return }
        didFinishClose = true
        isClosePending = false
        presentationCoordinator.reset()
        dismissalController.shutdown()
        pinObservation?.cancel()
        pinObservation = nil
        systemInteractionObservation?.cancel()
        systemInteractionObservation = nil
        directInteractionObservation?.cancel()
        directInteractionObservation = nil
        notificationObservation?.cancel()
        notificationObservation = nil
        notificationPresenter.shutdown()
        if let closingPanel {
            savePanelFrame(closingPanel.frame)
        }
        panel = nil
        model.cancel()
        onClose(id)
    }

    private func savePanelFrame(_ frame: CGRect) {
        FloatingPanelFrameStore.save(
            frame: frame,
            kind: .translation,
            position: nil
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        savePanelFrame(panel.frame)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        logFrame(
            panel.frame,
            reason: "user-or-system-move",
            screen: panel.screen
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        finishClose(panel: notification.object as? NSPanel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isForcingClose
            || !AppleTranslationSystemInteractionGuard.shared.isActive
    }

#if DEBUG
    var panelForTesting: TranslationSessionPanel? {
        panel
    }

    var notificationStateForTesting:
        BlocksNotificationPresentationState {
        notificationState
    }

    var notificationPanelForTesting: NSPanel? {
        notificationPresenter.panelForTesting
    }
#endif
}

enum TranslationPanelActivationPolicy {
    static func shouldBecomeKeyOnPresentation(
        inputSource: TranslationInputSource
    ) -> Bool {
        inputSource == .manual
    }

}

enum TranslationPanelSourceFocusPolicy {
    static func shouldRequestSourceFocus(
        isVisible: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        isVisible && !isKeyWindow
    }
}

enum TranslationPanelGeometry {
    static let screenInset: CGFloat = 12

    static func centeredFrame(
        preferredSize: CGSize,
        visibleFrame visible: CGRect
    ) -> CGRect {
        let size = CGSize(
            width: min(
                preferredSize.width,
                max(1, visible.width - screenInset * 2)
            ),
            height: min(
                preferredSize.height,
                max(1, visible.height - screenInset * 2)
            )
        )
        return clampedFrame(
            CGRect(
                origin: CGPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                ),
                size: size
            ),
            visibleFrame: visible
        )
    }

    static func clampedFrame(
        _ proposed: CGRect,
        visibleFrame visible: CGRect
    ) -> CGRect {
        let size = CGSize(
            width: min(
                max(1, proposed.width),
                max(1, visible.width - screenInset * 2)
            ),
            height: min(
                max(1, proposed.height),
                max(1, visible.height - screenInset * 2)
            )
        )
        let origin = CGPoint(
            x: min(
                max(proposed.minX, visible.minX + screenInset),
                visible.maxX - size.width - screenInset
            ),
            y: min(
                max(proposed.minY, visible.minY + screenInset),
                visible.maxY - size.height - screenInset
            )
        )
        return CGRect(origin: origin, size: size)
    }
}

enum TranslationPanelScreenResolver {
    static func screen(
        for inputContext: TranslationInputContext?,
        mouseLocation: CGPoint = NSEvent.mouseLocation,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        if let displayIdentifier = inputContext?.displayIdentifier,
           let exact = screens.first(where: {
               Self.displayIdentifier(for: $0) == displayIdentifier
           }) {
            return exact
        }
        if let anchor = inputContext?.anchor {
            let anchorRect = CGRect(
                x: anchor.x,
                y: anchor.y,
                width: anchor.width,
                height: anchor.height
            )
            if let intersecting = screens.max(by: {
                translationPanelIntersectionArea(
                    $0.frame.intersection(anchorRect)
                ) < translationPanelIntersectionArea(
                    $1.frame.intersection(anchorRect)
                )
            }),
               translationPanelIntersectionArea(
                   intersecting.frame.intersection(anchorRect)
               ) > 0 {
                return intersecting
            }
        }
        return screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? screens.first
    }

    static func displayIdentifier(for screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return String(number.uint32Value)
    }
}

final class TranslationSessionPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onRequestClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        guard let onEscape else {
            super.cancelOperation(sender)
            return
        }
        onEscape()
    }

    override func performClose(_ sender: Any?) {
        guard let onRequestClose else {
            super.performClose(sender)
            return
        }
        onRequestClose()
    }

}

final class TranslationFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private func translationPanelIntersectionArea(_ rect: CGRect) -> CGFloat {
    guard !rect.isNull,
          !rect.isInfinite,
          rect.width > 0,
          rect.height > 0 else {
        return 0
    }
    return rect.width * rect.height
}
