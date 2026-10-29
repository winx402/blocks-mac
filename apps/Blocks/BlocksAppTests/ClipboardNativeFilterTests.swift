import AppKit
import BlocksCore
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class ClipboardNativeFilterTests: XCTestCase {
    func testFirstMouseBeginsProtectionWithoutClaimingMenuOpened() {
        let before = ClipboardInteractionTrace.shared.snapshot().events.last?.sequence ?? 0
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        var transitions: [Bool] = []
        let coordinator = ClipboardNativeFilterMenu.Coordinator(group: .format)
        coordinator.attach(button)
        coordinator.update(configuration(tracking: { transitions.append($0) }))
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertTrue(button.needsPanelToBecomeKey)
        button.prepareForMenuInteraction()
        XCTAssertTrue(coordinator.tracking.isActive)
        XCTAssertFalse(coordinator.tracking.isMenuOpen)
        XCTAssertEqual(transitions, [true])
        let events = ClipboardInteractionTrace.shared.snapshot().events.filter { $0.sequence > before }
        XCTAssertFalse(events.contains { $0.stage == .filterNativeMenuOpen })
        coordinator.detach()
        XCTAssertEqual(transitions, [true, false])
    }

    func testOnlyRealDelegateCallbacksProduceContentFreeNativeOpenAndCloseStages() throws {
        var releases: [() -> Void] = []
        let before = ClipboardInteractionTrace.shared.snapshot().events.last?.sequence ?? 0
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        let coordinator = ClipboardNativeFilterMenu.Coordinator(group: .source, scheduleRelease: { releases.append($0) })
        coordinator.attach(button)
        coordinator.update(configuration())
        defer { coordinator.detach() }
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(NSMenu()) // A stale/foreign menu is not evidence.
        coordinator.menuWillOpen(menu)
        XCTAssertTrue(coordinator.tracking.isMenuOpen)
        coordinator.menuDidClose(menu)
        XCTAssertTrue(coordinator.tracking.isActive)
        XCTAssertFalse(coordinator.tracking.isMenuOpen)
        releases.removeFirst()()
        let events = ClipboardInteractionTrace.shared.snapshot().events.filter { $0.sequence > before }
        XCTAssertEqual(events.map(\.stage), [.filterNativeMenuOpen, .filterNativeMenuClose])
        XCTAssertTrue(events.allSatisfy { $0.group == "source" && $0.control == nil })
    }

    func testNativeMenuFreezesItemsSelectionAndCallbackUntilClosingEventUnwinds() throws {
        var releases: [() -> Void] = []
        var oldSelections: [String] = []
        var newSelections: [String] = []
        var oldTracking: [Bool] = []
        var newTracking: [Bool] = []
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        let coordinator = ClipboardNativeFilterMenu.Coordinator(group: .format, scheduleRelease: { releases.append($0) })
        coordinator.attach(button)
        coordinator.update(configuration(selection: { oldSelections.append($0) }, tracking: { oldTracking.append($0) }))
        defer { coordinator.detach() }
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.update(configuration(entries: [.init(id: "new", title: "New synthetic choice")], selectedID: "new",
            selection: { newSelections.append($0) }, tracking: { newTracking.append($0) }))
        XCTAssertTrue(button.menu === menu)
        XCTAssertEqual(button.itemArray.map(\.title), ["All", "Synthetic value"])
        coordinator.menuDidClose(menu)
        button.selectItem(at: 1)
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
        XCTAssertEqual(oldSelections, ["synthetic"])
        XCTAssertTrue(newSelections.isEmpty)
        XCTAssertEqual(oldTracking, [true])
        releases.removeFirst()()
        XCTAssertEqual(oldTracking, [true, false])
        XCTAssertTrue(newTracking.isEmpty)
        XCTAssertEqual(button.itemArray.map(\.title), ["New synthetic choice"])
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "new")
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
        XCTAssertEqual(newSelections, ["new"])
    }

    func testNewMenuInvalidatesOldReleaseAndMouseReturnDoesNotEndOpenTracking() {
        var releases: [() -> Void] = []
        var transitions: [Bool] = []
        let tracking = ClipboardFilterMenuTracking(onChange: { transitions.append($0) }, scheduleRelease: { releases.append($0) })
        tracking.begin()
        tracking.menuWillOpen()
        tracking.mouseInteractionDidReturn()
        XCTAssertTrue(releases.isEmpty)
        tracking.menuDidClose()
        tracking.menuWillOpen()
        releases.removeFirst()()
        XCTAssertTrue(tracking.isActive)
        XCTAssertTrue(tracking.isMenuOpen)
        tracking.menuDidClose()
        releases.removeFirst()()
        XCTAssertEqual(transitions, [true, false])
    }

    func testClosingEscapeRemainsProtectedInEventTrackingModeUntilDefaultRunLoopTail() {
        var protected = false
        let tracking = ClipboardFilterMenuTracking { protected = $0 }
        tracking.menuWillOpen()
        tracking.menuDidClose()
        XCTAssertTrue(protected)
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        XCTAssertTrue(protected)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertFalse(protected)
    }

    func testDismantlingCancelsTrackingAndUnbindsNativeCallbacks() throws {
        var releases: [() -> Void] = []
        var selections = 0
        var transitions: [Bool] = []
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(frame: .zero, pullsDown: false)
        let coordinator = ClipboardNativeFilterMenu.Coordinator(group: .time, scheduleRelease: { releases.append($0) })
        coordinator.attach(button)
        coordinator.update(configuration(selection: { _ in selections += 1 }, tracking: { transitions.append($0) }))
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.menuDidClose(menu)
        coordinator.detach()
        XCTAssertNil(menu.delegate)
        XCTAssertNil(button.target)
        XCTAssertNil(button.action)
        XCTAssertNil(button.tracking)
        XCTAssertFalse(coordinator.tracking.isActive)
        XCTAssertEqual(transitions, [true, false])
        releases.forEach { $0() }
        coordinator.selectFilter(button)
        XCTAssertEqual(selections, 0)
        coordinator.detach()
        XCTAssertEqual(transitions, [true, false])
    }

    func testHostedDefaultMenuOwnsWholeWidthAndActiveClearIsSeparateWithStableGroupWidth() throws {
        let hostWidth: CGFloat = 320
        let hostHeight: CGFloat = 80
        for group in ClipboardFilterGroup.nonTagCases {
            let width = ClipboardFilterBarLayout.filterGroupFixedWidth(for: group)
            let window = makePanel(width: hostWidth)
            defer { window.contentView = nil; window.close() }
            // A control-sized window conflates NSHostingView/window sizing
            // with the interior control budget. Keep the fixed group inside
            // a larger, stable viewport, as in the production toolbar.
            let host = NSHostingView(rootView: makeGroup(group: group, active: false)
                .frame(width: width, height: 34)
                .frame(width: hostWidth, height: hostHeight, alignment: .topLeading))
            window.setContentSize(NSSize(width: hostWidth, height: hostHeight))
            window.contentView = host
            layout(host)
            let defaultButton = try XCTUnwrap(nativeButtons(in: host).first)
            let defaultFrame = defaultButton.convert(defaultButton.bounds, to: host)
            let systemPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            systemPopup.isBordered = false
            XCTContext.runActivity(named: "Native \(group.rawValue) geometry") { activity in
                let attachment = XCTAttachment(string: "systemInsets=\(systemPopup.alignmentRectInsets) "
                    + "bridgeInsets=\(defaultButton.alignmentRectInsets) "
                    + "allocatedWidth=\(width) actualFrame=\(defaultFrame) hostBounds=\(host.bounds)")
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertEqual(nativeButtons(in: host).count, 1)
            XCTAssertEqual(defaultButton.alignmentRectInsets.left + defaultButton.alignmentRectInsets.right, 0)
            XCTAssertEqual(defaultButton.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(defaultButton.bounds.height, ClipboardFilterBarLayout.filterHitHeight, accuracy: 0.5)
            XCTAssertEqual(defaultFrame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(defaultFrame.maxX, width, accuracy: 0.5)
            for x in [CGFloat(1), width / 2, width - 1] {
                let pointInParent = defaultButton.convert(NSPoint(x: x, y: 17), to: defaultButton.superview)
                XCTAssertTrue(defaultButton.hitTest(pointInParent) === defaultButton)
            }
            host.rootView = makeGroup(group: group, active: true)
                .frame(width: width, height: 34)
                .frame(width: hostWidth, height: hostHeight, alignment: .topLeading)
            layout(host)
            let activeButton = try XCTUnwrap(nativeButtons(in: host).first)
            let activeFrame = activeButton.convert(activeButton.bounds, to: host)
            XCTAssertEqual(activeButton.bounds.width + ClipboardFilterBarLayout.clearSlotWidth, width, accuracy: 0.5)
            XCTAssertEqual(activeFrame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(activeFrame.maxX, width - ClipboardFilterBarLayout.clearSlotWidth, accuracy: 0.5)
            for offset in [CGFloat(1), ClipboardFilterBarLayout.clearSlotWidth / 2, ClipboardFilterBarLayout.clearSlotWidth - 1] {
                let clearPoint = NSPoint(x: width - ClipboardFilterBarLayout.clearSlotWidth + offset, y: activeFrame.midY)
                let hit = host.hitTest(host.convert(clearPoint, to: host.superview))
                XCTAssertNotNil(hit)
                XCTAssertFalse(hit === activeButton)
                XCTAssertFalse(hit?.isDescendant(of: activeButton) == true)
            }
            XCTAssertEqual(host.bounds.width, hostWidth, accuracy: 0.5)
            XCTAssertEqual(host.bounds.height, hostHeight, accuracy: 0.5)
        }
    }

    func testNativeAccessibilityAndTooltipRetainFullTruncatedValueAndSourceIcon() throws {
        let longTitle = String(repeating: "Synthetic long source ", count: 12)
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 34), pullsDown: false)
        let coordinator = ClipboardNativeFilterMenu.Coordinator(group: .source)
        coordinator.attach(button)
        coordinator.update(configuration(entries: [.init(id: "source", title: longTitle, usesSourceIcon: true)],
            selectedID: "source", value: longTitle))
        defer { coordinator.detach() }
        XCTAssertEqual(button.accessibilityIdentifier(), "clipboard.filter.menu.source")
        XCTAssertEqual(button.accessibilityValue() as? String, longTitle)
        XCTAssertTrue(try XCTUnwrap(button.toolTip).contains(longTitle))
        XCTAssertNotNil(button.item(at: 0)?.image)
    }

    func testEmptyRecoveryIsOffDuringLoadingFailureOrIndexingAndNeverAutomaticallyMutatesFilters() {
        let result = ClipboardSearchResultSet(query: "synthetic", records: [], state: .empty)
        func allowed(_ result: ClipboardSearchResultSet, query: String = "synthetic", loading: Bool = false,
                     unavailable: Bool = false, captureUnavailable: Bool = false, empty: Bool = false) -> Bool {
            ClipboardEmptyFilterRecoveryPolicy.canOfferRecovery(result: result, query: query,
                hasActiveFilters: true, recordsAreEmpty: empty, isLoading: loading,
                repositoryUnavailable: unavailable, captureServiceUnavailable: captureUnavailable)
        }
        XCTAssertTrue(allowed(result))
        XCTAssertFalse(allowed(result, loading: true))
        XCTAssertFalse(allowed(result, unavailable: true))
        XCTAssertFalse(allowed(result, captureUnavailable: true))
        XCTAssertFalse(allowed(result, empty: true))
        XCTAssertFalse(allowed(result, query: "a newer query"))
        for state in [ClipboardSearchResultState.failed, .emptyIndexing, .partialIndexing, .results] {
            XCTAssertFalse(allowed(ClipboardSearchResultSet(query: "synthetic", records: [], state: state)))
        }
        XCTAssertFalse(allowed(ClipboardSearchResultSet(query: "synthetic", records: [], state: .empty,
            indexActivity: ClipboardSearchIndexActivity(pendingIndexCount: 1))))
        XCTAssertTrue(allowed(.idle(records: []), query: ""))
        XCTAssertFalse(ClipboardEmptyFilterRecoveryPolicy.canOfferRecovery(result: .idle(records: []), query: "",
            hasActiveFilters: false, recordsAreEmpty: false, isLoading: false,
            repositoryUnavailable: false, captureServiceUnavailable: false))
    }

    func testExternalDismissProtectionEndsWhenLastFilterMenuFinishes() {
        let motion = BlocksFloatingPanelPresentationCoordinator { panel, _, alpha, _, _, completion in
            panel.alphaValue = alpha
            completion()
        }
        let presenter = ClipboardHistoryPanelPresenter(presentationCoordinator: motion)
        let store = ClipboardStore(repository: nil)
        _ = presenter.present(clipboardStore: store, notificationState: BlocksNotificationPresentationState(),
            actions: ClipboardPanelActions(pasteQuickRecord: { _ in }, pasteRecord: { _ in },
                translateRecord: { _ in }, copyRecordAsPlainText: { _ in }, deleteHistoryItem: { _ in true },
                toggleFavorite: { _ in }, setTagFilter: { _ in }), position: .bottom,
            invocationContext: ClipboardPanelInvocationContext(id: UUID(), source: .floatingPanel, openedAt: Date(), targetContext: nil),
            openMainWindow: {}, openSettings: {}, onClosed: { _ in })
        defer { presenter.forceCloseForRuntimeDisable() }
        presenter.setFilterMenuTracking(.format, isTracking: true)
        presenter.setFilterMenuTracking(.source, isTracking: true)
        presenter.dismissForExternalInteraction()
        XCTAssertTrue(presenter.isVisible)
        presenter.setFilterMenuTracking(.format, isTracking: false)
        XCTAssertTrue(presenter.isFilterMenuInteractionProtected)
        presenter.setFilterMenuTracking(.source, isTracking: false)
        XCTAssertFalse(presenter.isFilterMenuInteractionProtected)
        presenter.dismissForExternalInteraction()
        XCTAssertFalse(presenter.isVisible)
    }

    private func configuration(
        entries: [ClipboardNativeFilterMenuEntry] = [.init(id: "all", title: "All"), .init(id: "synthetic", title: "Synthetic value")],
        selectedID: String = "all", value: String = "All",
        selection: @escaping (String) -> Void = { _ in }, tracking: @escaping (Bool) -> Void = { _ in }
    ) -> ClipboardNativeFilterMenu.Configuration {
        ClipboardNativeFilterMenu.Configuration(entries: entries, selectedID: selectedID,
            accessibilityPresentation: .init(label: "Synthetic filter", value: value, help: "Open synthetic filter"),
            onSelection: selection, onTrackingChange: tracking)
    }

    private func makeGroup(group: ClipboardFilterGroup, active: Bool) -> ClipboardFilterMenuGroup {
        var state = ClipboardFilterState()
        if active { state.format = .image; state.time = .recentThreeDays; state.sourceFilterKey = .sourceIdentity("synthetic") }
        return ClipboardFilterMenuGroup(group: group, activeTitle: active ? "Synthetic selected value" : nil,
            hasActiveFilter: active, sourceOptions: [], filterState: state, onSelectFormat: { _ in },
            onSelectTime: { _ in }, onSelectSource: { _ in }, onClearGroup: {})
    }

    private func makePanel(width: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 34),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
    }

    private func nativeButtons(in view: NSView) -> [ClipboardNativeFilterMenu.FirstMousePopUpButton] {
        (view as? ClipboardNativeFilterMenu.FirstMousePopUpButton).map { [$0] } ?? view.subviews.flatMap { nativeButtons(in: $0) }
    }
}
