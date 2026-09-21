import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class SettingsNavigationInteractionTests: XCTestCase {
    func testHistoryContextClickRoutingIsLimitedToOwnEnabledButtonAndWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer { window.close(); otherWindow.close() }
        let group = SettingsHistoryButtonGroup(frame: NSRect(x: 10, y: 10, width: 58, height: 28))
        let button = SettingsHistoryButton(backward: true)
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        button.configure(entries: [.init(index: 0, title: "General")], primaryAction: {}, jump: { _ in })
        group.addArrangedSubview(button)
        XCTAssertFalse(group.isMonitoringContextClicks)
        window.contentView?.addSubview(group)
        window.orderFront(nil)
        otherWindow.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.isMonitoringContextClicks)

        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(in target: NSWindow, at point: NSPoint, type: NSEvent.EventType = .rightMouseDown) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(group.historyButton(for: try event(in: window, at: center)) === button)
        XCTAssertNil(group.historyButton(for: try event(in: otherWindow, at: center)))
        XCTAssertNil(group.historyButton(for: try event(in: window, at: NSPoint(x: 190, y: 90))))
        XCTAssertNil(group.historyButton(for: try event(in: window, at: center, type: .leftMouseDown)))
        button.isEnabled = false
        XCTAssertNil(group.historyButton(for: try event(in: window, at: center)))
        group.removeFromSuperview()
        XCTAssertFalse(group.isMonitoringContextClicks)
    }

    func testNativeHistoryButtonsExposeMenuEntriesAndKeepPrimaryActionSeparate() throws {
        let button = SettingsHistoryButton(backward: true)
        var primaryCount = 0
        var selectedIndex: Int?
        button.configure(
            entries: [.init(index: 4, title: "Watermarks"), .init(index: 1, title: "General")],
            primaryAction: { primaryCount += 1 },
            jump: { selectedIndex = $0 }
        )
        XCTAssertEqual(button.keyEquivalent, "", "Scene commands exclusively own keyboard shortcuts.")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.menu?.items.map(\.title), ["Watermarks", "General"])
        button.performClick(nil)
        XCTAssertEqual(primaryCount, 1)
        XCTAssertNil(selectedIndex)
        let item = try XCTUnwrap(button.menu?.items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(selectedIndex, 1)
        XCTAssertEqual(primaryCount, 1)
    }

    func testNativeForwardButtonDisablesWhenHistoryIsEmpty() {
        let button = SettingsHistoryButton(backward: false)
        var actionCount = 0
        button.configure(entries: [], primaryAction: { actionCount += 1 }, jump: { _ in actionCount += 1 })
        XCTAssertEqual(button.keyEquivalent, "", "Scene commands exclusively own keyboard shortcuts.")
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(button.menu?.items.isEmpty == true)
        button.performClick(nil)
        XCTAssertEqual(actionCount, 0)
    }

    func testHistoryRecordsRootAndNestedPagesAndReplaysActualRouteBindings() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.settings)
        store.recordSectionSelection(.screenshot)
        let screenshot = store.secondaryRouteBinding(for: .screenshot, default: "root")
        screenshot.wrappedValue = "watermarks"
        store.recordSectionSelection(.translationSettings)
        let translation = store.secondaryRouteBinding(for: .translation, default: "root")
        translation.wrappedValue = "services"

        XCTAssertEqual(store.history.count, 5)
        XCTAssertEqual(store.navigate(backward: true), .translationSettings)
        XCTAssertEqual(translation.wrappedValue, "root")
        XCTAssertEqual(store.navigate(backward: true), .screenshot)
        XCTAssertEqual(screenshot.wrappedValue, "watermarks")
        XCTAssertEqual(store.navigate(backward: true), .screenshot)
        XCTAssertEqual(screenshot.wrappedValue, "root")
        XCTAssertEqual(store.navigate(backward: false), .screenshot)
        XCTAssertEqual(screenshot.wrappedValue, "watermarks")
    }

    func testHistoryDeduplicatesSelectionAndClearsOnlyForwardBranch() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.settings)
        store.recordSectionSelection(.settings)
        store.secondaryRouteBinding(for: .general, default: "root").wrappedValue = "root"
        XCTAssertEqual(store.history.count, 1)
        store.recordSectionSelection(.screenshot)
        store.recordSectionSelection(.permissions)
        XCTAssertEqual(store.navigate(backward: true), .screenshot)
        // The app-model onChange echo must not append or clear the branch.
        store.recordSectionSelection(.screenshot)
        XCTAssertEqual(store.history.count, 3)
        store.recordSectionSelection(.shortcuts)
        XCTAssertEqual(store.history.map(\.section), [.settings, .screenshot, .shortcuts])
        XCTAssertNil(store.navigate(backward: false))
    }

    func testHistorySkipsRemovedPluginAndSupportsMenuJumpsBothDirections() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.hooks)
        let plugin = store.secondaryRouteBinding(for: .hooks, default: "catalog")
        plugin.wrappedValue = "installed:deleted-plugin"
        store.recordSectionSelection(.permissions)
        let valid: (SettingsNavigationLocation) -> Bool = { $0.routeToken != "installed:deleted-plugin" }
        XCTAssertEqual(store.historyIndices(backward: true, validating: valid), [0])
        XCTAssertEqual(store.navigate(backward: true, validating: valid), .hooks)
        XCTAssertEqual(plugin.wrappedValue, "catalog")
        XCTAssertEqual(store.historyIndices(backward: false, validating: valid), [2])
        XCTAssertNil(store.navigate(toHistoryIndex: 1, validating: valid))
        XCTAssertEqual(store.navigate(toHistoryIndex: 2, validating: valid), .permissions)
    }

    func testHistoryPreservesIndependentScrollDraftAndFocusState() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.providers)
        let provider = store.secondaryRouteBinding(for: .providers, default: "overview")
        provider.wrappedValue = "details"
        store.scrollOffsetBinding(for: .providers).wrappedValue = 183
        store.recordFocusTarget("model", for: .providers, routeToken: "details")
        let draft = ProviderDetailsRouteDraft(apiBaseURLDraft: "https://example.test", accountAliasDraft: "alias", modelNameDraft: "unsaved-model", baseURLValidationFailed: false)
        store.updateProviderDetailsDraft(draft, for: "details")
        store.recordSectionSelection(.settings)
        XCTAssertEqual(store.navigate(backward: true), .providers)
        XCTAssertEqual(provider.wrappedValue, "details")
        XCTAssertEqual(store.scrollOffsetBinding(for: .providers).wrappedValue, 183)
        XCTAssertEqual(store.providerDetailsDraft(for: "details"), draft)
        XCTAssertEqual(store.focusRestorationRequest?.target, "model")
        XCTAssertEqual(store.currentLocation, SettingsNavigationLocation(section: .providers, routeToken: "details"))
    }

    func testPluginCatalogIsRootAndOverviewExistsOnlyForMainCategories() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.hooks)
        XCTAssertEqual(store.currentLocation?.routeToken, "catalog")
        XCTAssertFalse(store.isSecondaryPage(for: .hooks))
        XCTAssertTrue(SettingsViewMode.general.showsRootOverview)
        XCTAssertTrue(SettingsViewMode.screenshot.showsRootOverview)
        XCTAssertTrue(SettingsViewMode.clipboard.showsRootOverview)
        XCTAssertTrue(SettingsViewMode.translation.showsRootOverview)
        for mode in [SettingsViewMode.hooks, .providers, .permissions, .shortcuts, .agentCLI, .dataAudit, .translationFavorites, .clipboardPrivacy] {
            XCTAssertFalse(mode.showsRootOverview)
        }
    }

    func testDelayedOffscreenRouteChangesCannotHijackCurrentHistory() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.hooks)
        store.recordSectionSelection(.settings)
        store.secondaryRouteBinding(for: .hooks, default: "catalog").wrappedValue = "installed:example"
        XCTAssertEqual(store.history.count, 2)
        XCTAssertEqual(store.currentLocation?.section, .settings)
        store.recordSectionSelection(.hooks)
        XCTAssertEqual(store.currentLocation?.routeToken, "installed:example")
    }

    func testAsyncNavigationGenerationRejectsSameSectionHistoryChanges() {
        let store = SettingsRouteStateStore()
        store.recordSectionSelection(.hooks)
        let route = store.secondaryRouteBinding(for: .hooks, default: "catalog")
        route.wrappedValue = "builtin:example"
        let installationGeneration = store.navigationGeneration
        store.recordSectionSelection(.hooks)
        XCTAssertTrue(store.isCurrentNavigation(generation: installationGeneration, section: .hooks), "Selection echoes do not invalidate an otherwise current completion.")

        XCTAssertEqual(store.navigate(backward: true), .hooks)
        XCTAssertFalse(store.isCurrentNavigation(generation: installationGeneration, section: .hooks))
        XCTAssertEqual(store.navigate(backward: false), .hooks)
        XCTAssertEqual(route.wrappedValue, "builtin:example")
        XCTAssertFalse(store.isCurrentNavigation(generation: installationGeneration, section: .hooks), "Returning to the same route must not revive a stale completion.")

        let newGeneration = store.navigationGeneration
        route.wrappedValue = "builtin:another"
        XCTAssertFalse(store.isCurrentNavigation(generation: newGeneration, section: .hooks))
    }

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
