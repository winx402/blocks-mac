import AppKit
import BlocksCore
import SwiftUI

/// Publishes geometry only for the record whose detached detail is visible.
struct ClipboardRecordFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

enum ClipboardRecordFramePublicationPolicy {
    static func shouldPublishFrame(isDetailPresented: Bool) -> Bool {
        isDetailPresented
    }
}

struct ClipboardDetailPresentationItem {
    let record: ClipboardRecorderRecord
    let preview: ClipboardRecordPreview
    let clipboardStore: ClipboardStore
    let itemFontSize: CGFloat
    let focusCoordinator: ClipboardPanelFocusCoordinator
    let keyboardRouter: ClipboardPanelKeyboardCommandRouter
    let pluginManager: BlocksNativePluginManager?
    let pluginRuntime: BlocksPluginRuntimeCoordinator?

    var id: String {
        record.id
    }
}

struct ClipboardDetailPresentationOverlay: NSViewRepresentable {
    let itemsByID: [String: ClipboardDetailPresentationItem]
    let recordFrames: [String: CGRect]
    let presentedRecordID: String?
    let panelPosition: FloatingPanelPosition
    let onOutsideInteraction: () -> Void

    func makeNSView(context: Context) -> ClipboardDetailPresentationView {
        let view = ClipboardDetailPresentationView()
        view.onOutsideInteraction = onOutsideInteraction
        return view
    }

    func updateNSView(_ nsView: ClipboardDetailPresentationView, context: Context) {
        nsView.itemsByID = itemsByID
        nsView.recordFrames = recordFrames
        nsView.onOutsideInteraction = onOutsideInteraction
        nsView.presentedRecordID = presentedRecordID
        nsView.panelPosition = panelPosition
        nsView.refreshAfterSwiftUIUpdate()
    }

    static func dismantleNSView(_ nsView: ClipboardDetailPresentationView, coordinator: ()) {
        nsView.shutdown()
    }
}
