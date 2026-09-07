import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class SettingsNavigationInteractionTests: XCTestCase {
    func testNativeSidebarPublishesRouteBeforeFocusRestoration() {
        var selected: AppSection? = .settings
        var selectionSeenByFocusRestoration: AppSection?
        let binding = Binding<AppSection?>(
            get: { selected },
            set: { selected = $0 }
        )
        let coordinator = SettingsSourceListBridge.Coordinator(
            selection: binding,
            onUserSelection: { _ in
                selectionSeenByFocusRestoration = selected
            }
        )

        coordinator.didSelect(.screenshot)

        XCTAssertEqual(selected, .screenshot)
        XCTAssertEqual(selectionSeenByFocusRestoration, .screenshot)
    }

    func testScrollBridgeRestoresAnUnvisitedRouteToTop() {
        var storedOffset: CGFloat = 0
        let binding = Binding<CGFloat>(
            get: { storedOffset },
            set: { storedOffset = $0 }
        )
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240)
        )
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 1_200)
        )
        let probe = SettingsScrollPositionBridge.ProbeView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        documentView.addSubview(probe)
        scrollView.documentView = documentView
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        let coordinator = SettingsScrollPositionBridge.Coordinator(
            restorationID: "settings.route.screenshot.root",
            offset: binding
        )
        coordinator.attach(from: probe)
        waitForScrollOffset(0, in: scrollView)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            0,
            accuracy: 0.5,
            "A new route must not inherit the outgoing page's position."
        )
    }

    func testScrollBridgeRestoresAVisitedRouteRelativeToItsActualTop() {
        var storedOffset: CGFloat = 86
        let binding = Binding<CGFloat>(
            get: { storedOffset },
            set: { storedOffset = $0 }
        )
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240)
        )
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 1_200)
        )
        let probe = SettingsScrollPositionBridge.ProbeView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        documentView.addSubview(probe)
        scrollView.documentView = documentView

        let coordinator = SettingsScrollPositionBridge.Coordinator(
            restorationID: "settings.route.clipboard.root",
            offset: binding
        )
        coordinator.attach(from: probe)
        waitForScrollOffset(86, in: scrollView)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 86, accuracy: 0.5)
        XCTAssertEqual(storedOffset, 86, accuracy: 0.5)
    }

    func testNativeContentInsetsPreserveTopAndSmallSavedOffsets() {
        var storedOffset: CGFloat = 0
        let binding = Binding<CGFloat>(get: { storedOffset }, set: { storedOffset = $0 })
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 640, height: 1_200))
        let probe = SettingsScrollPositionBridge.ProbeView(frame: .zero)
        document.addSubview(probe)
        scrollView.documentView = document
        let coordinator = SettingsScrollPositionBridge.Coordinator(
            restorationID: "inset-first", offset: binding
        )
        coordinator.attach(from: probe)
        waitForScrollOffset(-52, in: scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, -52, accuracy: 0.5)

        storedOffset = 20
        coordinator.update(restorationID: "inset-return", offset: binding)
        coordinator.attach(from: probe)
        waitForScrollOffset(-32, in: scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, -32, accuracy: 0.5)
        XCTAssertEqual(storedOffset, 20, accuracy: 0.5)
    }

    func testTitledToolbarHostPreservesInsetAwareTop() throws {
        let state = ToolbarScrollState()
        let hostingView = NSHostingView(
            rootView: ToolbarScrollFixture(state: state)
        )
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.toolbar = NSToolbar(identifier: "SettingsNavigationInteractionTests")
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = window.contentView!.bounds
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        let scrollView = try waitForScrollView(in: hostingView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let expectedTop = -scrollView.contentInsets.top
        waitForScrollOffset(expectedTop, in: scrollView)

        XCTAssertGreaterThan(scrollView.contentInsets.top, 0, "Fixture must exercise a real toolbar inset.")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, expectedTop, accuracy: 0.5)
    }

    private func waitForScrollOffset(
        _ expected: CGFloat,
        in scrollView: NSScrollView,
        timeout: TimeInterval = 1
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              abs(scrollView.contentView.bounds.origin.y - expected) > 0.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func waitForScrollView(
        in hostingView: NSHostingView<ToolbarScrollFixture>,
        timeout: TimeInterval = 1
    ) throws -> NSScrollView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let scrollView = firstDescendant(of: NSScrollView.self, in: hostingView) {
                return scrollView
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        throw XCTSkip("SwiftUI did not create a scroll view in the titled toolbar host")
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ToolbarScrollState: ObservableObject {
    let routeStateStore = SettingsRouteStateStore()
}

private struct ToolbarScrollFixture: View {
    @ObservedObject var state: ToolbarScrollState

    private let restorationID = "settings.route.screenshot.root"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(width: 720, height: 1_200)
                    .background {
                        SettingsScrollPositionBridge(
                            restorationID: restorationID,
                            offset: state.routeStateStore.scrollOffsetBinding(
                                key: restorationID
                            )
                        )
                        .frame(width: 0, height: 0)
                    }
            }
        }
    }
}

private func firstDescendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
    if let view = view as? T { return view }
    for child in view.subviews {
        if let result = firstDescendant(of: type, in: child) { return result }
    }
    return nil
}
