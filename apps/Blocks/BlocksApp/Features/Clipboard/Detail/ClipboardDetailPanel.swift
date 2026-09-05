import AppKit
import BlocksCore
import OSLog
import SwiftUI

private struct ClipboardDetailPresentedContent: View {
    let item: ClipboardDetailPresentationItem
    let panelSize: CGSize
    @ObservedObject var focusCoordinator: ClipboardPanelFocusCoordinator

    var body: some View {
        ClipboardFloatingDetailCard(
            record: item.record,
            preview: item.preview,
            clipboardStore: item.clipboardStore,
            detailStore: item.clipboardStore.detailStore,
            focusCoordinator: focusCoordinator,
            itemFontSize: item.itemFontSize,
            pluginManager: item.pluginManager,
            pluginRuntime: item.pluginRuntime
        )
        .id(item.id)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
    }
}

struct ClipboardDetailPresentationIdentity: Equatable {
    let recordID: String
    let itemFontSize: CGFloat
    let contentRevision: Int64?
}

enum ClipboardDetailPanelPlacement {
    static let screenInset: CGFloat = 12
    static let panelGap: CGFloat = 8

    static func frame(
        recordFrame: CGRect,
        parentFrame: CGRect,
        panelSize: CGSize,
        position: FloatingPanelPosition,
        visibleFrame: CGRect
    ) -> CGRect {
        let minX = visibleFrame.minX + screenInset
        let maxX = max(minX, visibleFrame.maxX - screenInset - panelSize.width)
        let minY = visibleFrame.minY + screenInset
        let maxY = max(minY, visibleFrame.maxY - screenInset - panelSize.height)
        let x: CGFloat
        let y: CGFloat

        switch position {
        case .bottom:
            x = min(max(recordFrame.midX - panelSize.width / 2, minX), maxX)
            y = min(max(parentFrame.maxY + panelGap, minY), maxY)
        case .left:
            x = min(max(parentFrame.maxX + panelGap, minX), maxX)
            y = min(max(recordFrame.midY - panelSize.height / 2, minY), maxY)
        case .right:
            x = min(max(parentFrame.minX - panelGap - panelSize.width, minX), maxX)
            y = min(max(recordFrame.midY - panelSize.height / 2, minY), maxY)
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: panelSize)
    }
}

enum ClipboardDetailMotionGeometry {
    static func revealFrame(
        targetFrame: CGRect,
        sourceFrame: CGRect,
        maximumOffset: CGFloat = 8
    ) -> CGRect {
        guard sourceFrame != .zero else {
            return targetFrame
        }
        let horizontalOffset = min(max(sourceFrame.midX - targetFrame.midX, -maximumOffset), maximumOffset)
        let verticalOffset = min(max(sourceFrame.midY - targetFrame.midY, -maximumOffset), maximumOffset)
        return targetFrame.offsetBy(dx: horizontalOffset, dy: verticalOffset)
    }
}

@MainActor
/// Owns one detached detail panel for the current clipboard panel session.
final class ClipboardDetailPanelCoordinator: NSObject, NSWindowDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-panel-detail-window"
    )
    private var detailPanel: ClipboardDetailPanel?
    private weak var parentWindow: NSWindow?
    private weak var focusCoordinator: ClipboardPanelFocusCoordinator?
    private var activePresentationIdentity: ClipboardDetailPresentationIdentity?
    private var lastRecordScreenFrame: CGRect = .zero
    private var animationToken = 0
    private var detailPanelScreenFrame: CGRect = .zero
    private var detailHostingView: NSHostingView<ClipboardDetailPresentedContent>?

    func show(
        item: ClipboardDetailPresentationItem,
        parentWindow: NSWindow,
        recordScreenFrame: CGRect,
        panelPosition: FloatingPanelPosition
    ) {
        guard parentWindow.isVisible else {
            hide()
            return
        }
        let panel = detailPanel ?? makePanel()
        detailPanel = panel
        panel.keyboardRouter = item.keyboardRouter
        if focusCoordinator !== item.focusCoordinator {
            focusCoordinator?.unregisterDetailWindow(panel)
            focusCoordinator = item.focusCoordinator
            item.focusCoordinator.registerDetailWindow(panel)
        }

        attach(panel: panel, to: parentWindow)

        let wasVisible = panel.isVisible && activePresentationIdentity != nil
        let panelSize = detailPanelSize(for: item.record)
        let visibleFrame = (parentWindow.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let panelFrame = ClipboardDetailPanelPlacement.frame(
            recordFrame: recordScreenFrame,
            parentFrame: parentWindow.frame,
            panelSize: panelSize,
            position: panelPosition,
            visibleFrame: visibleFrame
        )
        detailPanelScreenFrame = panelFrame
        lastRecordScreenFrame = recordScreenFrame

        let presentationIdentity = ClipboardDetailPresentationIdentity(
            recordID: item.id,
            itemFontSize: item.itemFontSize,
            contentRevision: item.clipboardStore.detailStore.readModel?.contentRevision
        )
        let contentChanged = activePresentationIdentity != presentationIdentity
        let presentedContent = ClipboardDetailPresentedContent(
            item: item,
            panelSize: panelSize,
            focusCoordinator: item.focusCoordinator
        )
        if panel.contentView == nil || detailHostingView == nil {
            let hostingView = ClipboardDetailFirstMouseHostingView(rootView: presentedContent)
            detailHostingView = hostingView
            panel.contentView = ClipboardDetailPanelContainer(
                hostingView: hostingView
            )
        } else {
            if contentChanged, let hostingView = detailHostingView {
                hostingView.rootView = presentedContent
            }
        }
        activePresentationIdentity = presentationIdentity

        if wasVisible,
           !contentChanged,
           framesNearlyMatch(panel.frame, panelFrame) {
            panel.alphaValue = 1
            panel.contentView?.alphaValue = 1
            orderPanelAboveExternalWindows(panel, parentWindow: parentWindow)
            return
        }

        animationToken += 1
        let token = animationToken
        cancelPanelAnimations(panel)
        let motion = BlocksMotionRole.reveal.policy(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if !wasVisible {
            panel.alphaValue = 0
            panel.setFrame(
                motion.allowsSpatialMotion
                    ? ClipboardDetailMotionGeometry.revealFrame(
                        targetFrame: panelFrame,
                        sourceFrame: recordScreenFrame
                    )
                    : panelFrame,
                display: false
            )
            orderPanelAboveExternalWindows(panel, parentWindow: parentWindow)
        } else {
            orderPanelAboveExternalWindows(panel, parentWindow: parentWindow)
        }
        animatePanel(
            panel,
            to: panelFrame,
            alphaValue: 1,
            token: token
        )
    }

    func hide() {
        guard let detailPanel else {
            resetHiddenState()
            return
        }
        let targetFrame: CGRect
        let motion = BlocksMotionRole.reveal.policy(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if lastRecordScreenFrame == .zero || !motion.allowsSpatialMotion {
            targetFrame = detailPanel.frame
        } else {
            targetFrame = ClipboardDetailMotionGeometry.revealFrame(
                targetFrame: detailPanel.frame,
                sourceFrame: lastRecordScreenFrame
            )
        }

        animationToken += 1
        let token = animationToken
        cancelPanelAnimations(detailPanel)
        activePresentationIdentity = nil

        guard detailPanel.isVisible else {
            parentWindow?.removeChildWindow(detailPanel)
            detailPanel.orderOut(nil)
            resetHiddenState()
            return
        }

        animatePanel(
            detailPanel,
            to: targetFrame,
            alphaValue: 0,
            token: token
        ) { [weak self, weak detailPanel] in
            guard let self else { return }
            if let detailPanel {
                self.parentWindow?.removeChildWindow(detailPanel)
                detailPanel.orderOut(nil)
                detailPanel.alphaValue = 1
            }
            self.resetHiddenState()
        }
    }

    func contains(screenPoint: CGPoint) -> Bool {
        detailPanelScreenFrame.insetBy(dx: -2, dy: -2).contains(screenPoint)
    }

    private func makePanel() -> ClipboardDetailPanel {
        let panel = ClipboardDetailPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        BlocksFloatingPanelWindowRole.nonactivatingSession.apply(to: panel)
        panel.isMovable = false
        panel.delegate = self
        return panel
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        focusCoordinator?.windowBecameKey(.detail, window: window)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        focusCoordinator?.windowResignedKey(.detail, window: window)
    }

    private func animatePanel(
        _ panel: NSPanel,
        to targetFrame: CGRect,
        alphaValue targetAlphaValue: CGFloat,
        token: Int,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        BlocksAppKitMotion.animate(
            window: panel,
            to: targetFrame,
            alphaValue: targetAlphaValue,
            role: .reveal
        ) { [weak self, weak panel] in
            guard let self, self.animationToken == token, panel != nil else {
                return
            }
            completion()
        }
    }

    private func cancelPanelAnimations(_ panel: NSPanel) {
        BlocksAppKitMotion.cancelAnimations(on: panel)
    }

    private func resetHiddenState() {
        if let detailPanel {
            focusCoordinator?.unregisterDetailWindow(detailPanel)
        }
        activePresentationIdentity = nil
        parentWindow = nil
        focusCoordinator = nil
        detailPanelScreenFrame = .zero
        lastRecordScreenFrame = .zero
    }

    private func attach(panel: NSPanel, to parentWindow: NSWindow) {
        panel.level = parentWindow.level
        if self.parentWindow !== parentWindow {
            if let oldParent = self.parentWindow {
                oldParent.removeChildWindow(panel)
            }
            parentWindow.addChildWindow(panel, ordered: .above)
            self.parentWindow = parentWindow
            return
        }
        if !(parentWindow.childWindows ?? []).contains(where: { $0 === panel }) {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func orderPanelAboveExternalWindows(
        _ panel: NSPanel,
        parentWindow: NSWindow
    ) {
        // The clipboard panel deliberately does not activate Blocks. Using
        // `orderFront` here therefore leaves a newly-created detail panel
        // behind the external target app even though its state is visible.
        // Use the same floating level as the parent. The child-window relation
        // supplies the relative ordering; `orderFrontRegardless` only keeps
        // the detached detail visible while Blocks remains nonactivating.
        panel.level = parentWindow.level
        panel.orderFrontRegardless()
        Self.logger.info(
            "stage=ordered-front parentWindow=\(parentWindow.windowNumber) detailWindow=\(panel.windowNumber) parentLevel=\(parentWindow.level.rawValue) detailLevel=\(panel.level.rawValue) frameX=\(Int(panel.frame.minX)) frameY=\(Int(panel.frame.minY)) frameW=\(Int(panel.frame.width)) frameH=\(Int(panel.frame.height))"
        )
    }

    private func detailPanelSize(for record: ClipboardRecorderRecord) -> CGSize {
        record.kind == .image ? CGSize(width: 420, height: 360) : CGSize(width: 380, height: 300)
    }

    private func framesNearlyMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

final class ClipboardDetailPanel: NSPanel {
    weak var keyboardRouter: ClipboardPanelKeyboardCommandRouter?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        if keyboardRouter?.route(event) == true {
            return
        }
        super.sendEvent(event)
    }

}

final class ClipboardDetailPanelContainer: NSView {
    init(hostingView: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class ClipboardDetailFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
