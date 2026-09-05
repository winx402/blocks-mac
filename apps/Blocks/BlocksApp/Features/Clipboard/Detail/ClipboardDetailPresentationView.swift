import AppKit
import BlocksCore
import SwiftUI

enum ClipboardDetailPresentationMonitoringPolicy {
    static func needsDetachedPanelMonitors(
        hasWindow: Bool,
        presentedRecordID: String?
    ) -> Bool {
        hasWindow && presentedRecordID != nil
    }
}

@MainActor
final class ClipboardDetailPresentationUpdateScheduler {
    private var task: Task<Void, Never>?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Owns the narrow AppKit edge that presents and dismisses detached record details.
final class ClipboardDetailPresentationView: NSView {
    var itemsByID: [String: ClipboardDetailPresentationItem] = [:]
    var recordFrames: [String: CGRect] = [:]
    var onOutsideInteraction: (() -> Void)?
    var presentedRecordID: String? {
        didSet {
            guard presentedRecordID != oldValue else {
                return
            }
            updateInteractionMonitorLifecycle()
            schedulePresentationRefresh()
        }
    }
    var panelPosition: FloatingPanelPosition = .bottom {
        didSet {
            guard panelPosition != oldValue else {
                return
            }
            schedulePresentationRefresh()
        }
    }

    private let detailCoordinator = ClipboardDetailPanelCoordinator()
    private let updateScheduler = ClipboardDetailPresentationUpdateScheduler()
    private var mouseDownMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?

    override var isFlipped: Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            detachWindowCloseObserver()
            stopMouseDownMonitor()
            hideDetailPanel()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            attachWindowCloseObserver(to: window)
            updateInteractionMonitorLifecycle()
        } else {
            shutdown()
        }
    }

    deinit {
        shutdown()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func shutdown() {
        updateScheduler.cancel()
        stopMouseDownMonitor()
        detachWindowCloseObserver()
        hideDetailPanel()
    }

    private func startMouseDownMonitor() {
        guard mouseDownMonitor == nil else {
            return
        }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if self?.handleMouseDown(event) == true {
                return nil
            }
            return event
        }
    }

    private func stopMouseDownMonitor() {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }

    private func updateInteractionMonitorLifecycle() {
        let needsMonitors = ClipboardDetailPresentationMonitoringPolicy.needsDetachedPanelMonitors(
            hasWindow: window != nil,
            presentedRecordID: presentedRecordID
        )
        if needsMonitors {
            startMouseDownMonitor()
        } else {
            stopMouseDownMonitor()
        }
    }

    private func attachWindowCloseObserver(to window: NSWindow) {
        guard windowCloseObserver == nil else {
            return
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.shutdown()
            }
        }
    }

    private func detachWindowCloseObserver() {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> Bool {
        guard presentedRecordID != nil else {
            return false
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if detailCoordinator.contains(screenPoint: screenPoint) {
            return false
        }

        if event.window === window {
            // Parent/child Key transitions are owned by the focus coordinator.
            // This monitor only detects outside interaction and never mutates
            // AppKit focus during the original mouse event.
            return false
        }

        onOutsideInteraction?()
        return false
    }

    func refreshAfterSwiftUIUpdate() {
        schedulePresentationRefresh()
    }

    private func schedulePresentationRefresh() {
        updateScheduler.schedule { [weak self] in
            self?.presentPresentedDetailIfNeeded()
        }
    }

    private func presentPresentedDetailIfNeeded() {
        guard isPresentationWindowVisible,
              let recordID = presentedRecordID else {
            hideDetailPanel()
            return
        }
        guard itemsByID[recordID] != nil,
              recordFrames[recordID] != nil else {
            hideDetailPanel()
            return
        }
        showDetail(for: recordID)
    }

    func hideDetailPanel() {
        detailCoordinator.hide()
    }


    private func recordScreenFrame(for recordID: String) -> CGRect? {
        guard let window, window.isVisible,
              let localFrame = recordFrames[recordID] else { return nil }
        return window.convertToScreen(convert(localFrame, to: nil))
    }

    private func showDetail(for recordID: String) {
        guard let item = itemsByID[recordID],
              let parentWindow = window,
              parentWindow.isVisible,
              let recordScreenFrame = recordScreenFrame(for: recordID) else {
            hideDetailPanel()
            return
        }
        detailCoordinator.show(
            item: item,
            parentWindow: parentWindow,
            recordScreenFrame: recordScreenFrame,
            panelPosition: panelPosition
        )
    }

    private var isPresentationWindowVisible: Bool {
        window?.isVisible == true
    }

}

struct ClipboardPanelDetailPresentationLayer: View {
    let records: [ClipboardRecorderRecord]
    let recordFrames: [String: Anchor<CGRect>]
    let proxy: GeometryProxy
    let presentedRecordID: String?
    let panelPosition: FloatingPanelPosition
    let clipboardStore: ClipboardStore
    let itemFontSize: CGFloat
    let focusCoordinator: ClipboardPanelFocusCoordinator
    let keyboardRouter: ClipboardPanelKeyboardCommandRouter
    let pluginManager: BlocksNativePluginManager?
    let pluginRuntime: BlocksPluginRuntimeCoordinator?
    let onOutsideInteraction: () -> Void

    var body: some View {
        let resolvedFrames = Dictionary(uniqueKeysWithValues: recordFrames.map { recordID, anchor in
            (recordID, proxy[anchor])
        })
        let item = presentedRecordID.flatMap { recordID -> ClipboardDetailPresentationItem? in
            guard recordFrames[recordID] != nil,
                  let record = records.first(where: { $0.id == recordID }) else {
                return nil
            }
            return ClipboardDetailPresentationItem(
                record: record,
                preview: clipboardStore.preview(for: record),
                clipboardStore: clipboardStore,
                itemFontSize: itemFontSize,
                focusCoordinator: focusCoordinator,
                keyboardRouter: keyboardRouter,
                pluginManager: pluginManager,
                pluginRuntime: pluginRuntime
            )
        }
        let itemsByID = item.map { [$0.id: $0] } ?? [:]

        ClipboardDetailPresentationOverlay(
            itemsByID: itemsByID,
            recordFrames: resolvedFrames,
            presentedRecordID: presentedRecordID,
            panelPosition: panelPosition,
            onOutsideInteraction: onOutsideInteraction
        )
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
}
