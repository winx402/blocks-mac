import AppKit
import BlocksCore
import SwiftUI

/// Coordinates one recovery presentation for the restored main window. SwiftUI
/// continues to own the scene and restoration; this only closes the gap where
/// activation finishes before AppKit attaches the restored window.
@MainActor
final class MainWindowPresentationCoordinator {
    struct Attachment {
        let identity: ObjectIdentifier
        let isAttached: @MainActor () -> Bool
        let isVisible: @MainActor () -> Bool
        let isMiniaturized: @MainActor () -> Bool
        let present: @MainActor () -> Void

        init(
            identity: ObjectIdentifier,
            isAttached: @escaping @MainActor () -> Bool,
            isVisible: @escaping @MainActor () -> Bool,
            isMiniaturized: @escaping @MainActor () -> Bool,
            present: @escaping @MainActor () -> Void
        ) {
            self.identity = identity
            self.isAttached = isAttached
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.present = present
        }

        init(window: NSWindow) {
            identity = ObjectIdentifier(window)
            isAttached = { [weak window] in window != nil }
            isVisible = { [weak window] in window?.isVisible ?? false }
            isMiniaturized = { [weak window] in
                window?.isMiniaturized ?? false
            }
            present = { [weak window] in window?.orderFront(nil) }
        }
    }

    private let isUnitTestHost: () -> Bool
    private let isApplicationActive: @MainActor () -> Bool
    private var attachedMainWindow: Attachment?
    private var didFinishLaunching = false
    private var didBecomeActive = false
    private var didFinishRestoringWindows = false
    private var didHandleInitialPresentation = false

    init(
        isUnitTestHost: @escaping () -> Bool = {
            BlocksRuntimeEnvironment.isUnitTestHost
        },
        isApplicationActive: @escaping @MainActor () -> Bool = {
            NSApp.isActive
        }
    ) {
        self.isUnitTestHost = isUnitTestHost
        self.isApplicationActive = isApplicationActive
    }

    func applicationDidFinishLaunching() {
        didFinishLaunching = true
        resolveInitialPresentationIfReady()
    }

    func applicationDidBecomeActive() {
        didBecomeActive = true
        resolveInitialPresentationIfReady()
    }

    func applicationDidFinishRestoringWindows() {
        didFinishRestoringWindows = true
        resolveInitialPresentationIfReady()
    }

    func attachMainWindow(_ window: NSWindow) {
        attachMainWindow(Attachment(window: window))
    }

    func attachMainWindow(_ window: Attachment) {
        attachedMainWindow = window
        resolveInitialPresentationIfReady()
    }

    func detachMainWindow(_ window: NSWindow) {
        guard attachedMainWindow?.identity == ObjectIdentifier(window) else {
            return
        }
        attachedMainWindow = nil
    }

    private func resolveInitialPresentationIfReady() {
        guard !isUnitTestHost(),
              !didHandleInitialPresentation,
              didFinishLaunching,
              didBecomeActive,
              didFinishRestoringWindows,
              isApplicationActive(),
              let window = attachedMainWindow,
              window.isAttached() else {
            return
        }

        didHandleInitialPresentation = true
        guard !window.isVisible(), !window.isMiniaturized() else { return }
        window.present()
    }
}

/// Observes the actual `NSWindow` that hosts the singleton `Window(id: "main")`
/// scene without creating another window or participating in layout.
@MainActor
struct MainWindowAttachmentObserver: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void
    let onDetach: (NSWindow) -> Void

    func makeNSView(context _: Context) -> AttachmentView {
        AttachmentView(onAttach: onAttach, onDetach: onDetach)
    }

    func updateNSView(_ nsView: AttachmentView, context _: Context) {
        nsView.updateCallbacks(onAttach: onAttach, onDetach: onDetach)
        nsView.reportAttachmentIfNeeded()
    }

    static func dismantleNSView(
        _ nsView: AttachmentView,
        coordinator _: ()
    ) {
        nsView.detach()
    }

    final class AttachmentView: NSView {
        private var onAttach: (NSWindow) -> Void
        private var onDetach: (NSWindow) -> Void
        private weak var attachedWindow: NSWindow?

        init(
            onAttach: @escaping (NSWindow) -> Void,
            onDetach: @escaping (NSWindow) -> Void
        ) {
            self.onAttach = onAttach
            self.onDetach = onDetach
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportAttachmentIfNeeded()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func updateCallbacks(
            onAttach: @escaping (NSWindow) -> Void,
            onDetach: @escaping (NSWindow) -> Void
        ) {
            self.onAttach = onAttach
            self.onDetach = onDetach
        }

        func reportAttachmentIfNeeded() {
            guard attachedWindow !== window else { return }
            detach()
            guard let window else { return }
            attachedWindow = window
            onAttach(window)
        }

        func detach() {
            guard let attachedWindow else { return }
            self.attachedWindow = nil
            onDetach(attachedWindow)
        }
    }
}
