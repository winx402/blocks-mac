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
            XCTAssertEqual(defaultButton.focusRingType, .none)
            XCTAssertFalse(defaultButton.refusesFirstResponder)
            XCTAssertEqual(defaultButton.alignmentRectInsets.left + defaultButton.alignmentRectInsets.right, 0)
            XCTAssertEqual(defaultButton.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(defaultButton.bounds.height, ClipboardFilterBarLayout.filterHitHeight, accuracy: 0.5)
            XCTAssertEqual(defaultFrame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(defaultFrame.maxX, width, accuracy: 0.5)
            for x in [CGFloat(1), width / 2, width - 1] {
                let pointInParent = defaultButton.convert(NSPoint(x: x, y: 17), to: defaultButton.superview)
                XCTAssertTrue(defaultButton.hitTest(pointInParent) === defaultButton)
                let pointInHost = defaultButton.convert(NSPoint(x: x, y: 17), to: host)
                XCTAssertTrue(host.hitTest(host.convert(pointInHost, to: host.superview)) === defaultButton,
                              "The real hosting root must deliver visible-control clicks to the native menu")
            }
            host.rootView = makeGroup(group: group, active: true)
                .frame(width: width, height: 34)
                .frame(width: hostWidth, height: hostHeight, alignment: .topLeading)
            layout(host)
            let activeButton = try XCTUnwrap(nativeButtons(in: host).first)
            let activeFrame = activeButton.convert(activeButton.bounds, to: host)
            XCTAssertEqual(activeButton.focusRingType, .none)
            XCTAssertFalse(activeButton.refusesFirstResponder)
            XCTAssertEqual(activeButton.bounds.width + ClipboardFilterBarLayout.clearSlotWidth, width, accuracy: 0.5)
            XCTAssertEqual(activeFrame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(activeFrame.maxX, width - ClipboardFilterBarLayout.clearSlotWidth, accuracy: 0.5)
            for x in [CGFloat(1), activeFrame.width / 2, activeFrame.width - 1] {
                let pointInHost = activeButton.convert(NSPoint(x: x, y: 17), to: host)
                XCTAssertTrue(host.hitTest(host.convert(pointInHost, to: host.superview)) === activeButton)
            }
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

    func testHostedTwoCharacterActiveLabelsRetainTheirActualSwiftUITextBudget() throws {
        // Recreate the Chinese 91pt group / 71pt active menu even if the test
        // runner's language is English. Native-frame tests cannot detect an
        // oversized SF symbol shrinking Text inside this otherwise-correct box.
        for (group, title) in [(ClipboardFilterGroup.format, "图片"), (.time, "今天"), (.source, "预览")] {
            for showsIcon in [true, false] {
                let capture = ClipboardFilterLabelGeometryCapture()
                let labelWidth = ClipboardFilterBarLayout.islandTextSize * 2
                let menuWidth = labelWidth + ClipboardFilterBarLayout.menuIndicatorWidth
                    + ClipboardFilterBarLayout.islandHorizontalPadding * 2
                    + ClipboardFilterBarLayout.islandContentSpacing
                    + (showsIcon ? ClipboardFilterBarLayout.islandIconSize + ClipboardFilterBarLayout.islandContentSpacing : 0)
                let window = makeLabelWindow(group: group, title: title, showsIcon: showsIcon,
                    menuWidth: menuWidth, capture: capture)
                defer { window.contentView = nil; window.close() }
                layout(try XCTUnwrap(window.contentView))

                let prefix = "clipboard.filter.\(group.rawValue).label"
                let text = try XCTUnwrap(capture.frames["\(prefix).title"])
                let textSlot = try XCTUnwrap(capture.frames["\(prefix).titleSlot"])
                let idealText = try XCTUnwrap(capture.frames["test.filter.label.ideal"])
                let indicator = try XCTUnwrap(capture.frames["\(prefix).indicator"])
                let surface = try XCTUnwrap(capture.frames["\(prefix).surface"])
                XCTAssertEqual(surface.width, menuWidth, accuracy: 0.25)
                XCTAssertGreaterThanOrEqual(textSlot.width, idealText.width - 0.25,
                    "The actual active label slot must fit both Chinese characters, not just its ellipsis")
                XCTAssertGreaterThanOrEqual(text.width, idealText.width - 0.25)
                XCTAssertLessThanOrEqual(textSlot.maxX + ClipboardFilterBarLayout.islandContentSpacing, indicator.minX + 0.25)
                XCTAssertEqual(indicator.width, ClipboardFilterBarLayout.menuIndicatorWidth, accuracy: 0.25)
                if showsIcon {
                    let icon = try XCTUnwrap(capture.frames["\(prefix).icon"])
                    let unboundedIcon = try XCTUnwrap(capture.frames["test.filter.label.unboundedIcon"])
                    XCTContext.runActivity(named: "Active \(group.rawValue) label budget") { activity in
                        let attachment = XCTAttachment(string: "unboundedSystemSymbol=\(unboundedIcon.size) "
                            + "boundedSymbol=\(icon.size) textSlot=\(textSlot.size) "
                            + "text=\(text.size) idealText=\(idealText.size) surface=\(surface.size)")
                        attachment.lifetime = .keepAlways
                        activity.add(attachment)
                    }
                    XCTAssertEqual(icon.width, ClipboardFilterBarLayout.islandIconSize, accuracy: 0.25)
                    XCTAssertEqual(icon.height, ClipboardFilterBarLayout.islandIconSize, accuracy: 0.25)
                    XCTAssertLessThanOrEqual(icon.maxX + ClipboardFilterBarLayout.islandContentSpacing, textSlot.minX + 0.25)
                }
            }
        }
    }

    func testHostedLongSourceLabelStillTruncatesWithinItsFixedVisualBudget() throws {
        let capture = ClipboardFilterLabelGeometryCapture()
        let title = String(repeating: "Synthetic long source ", count: 12)
        let menuWidth = ClipboardFilterBarLayout.islandTextSize * 2
            + ClipboardFilterBarLayout.islandIconSize + ClipboardFilterBarLayout.menuIndicatorWidth
            + ClipboardFilterBarLayout.islandContentSpacing * 2
            + ClipboardFilterBarLayout.islandHorizontalPadding * 2
        let window = makeLabelWindow(group: .source, title: title, showsIcon: true,
            menuWidth: menuWidth, capture: capture)
        defer { window.contentView = nil; window.close() }
        layout(try XCTUnwrap(window.contentView))
        let text = try XCTUnwrap(capture.frames["clipboard.filter.source.label.title"])
        let slot = try XCTUnwrap(capture.frames["clipboard.filter.source.label.titleSlot"])
        let indicator = try XCTUnwrap(capture.frames["clipboard.filter.source.label.indicator"])
        let surface = try XCTUnwrap(capture.frames["clipboard.filter.source.label.surface"])
        let idealText = try XCTUnwrap(capture.frames["test.filter.label.ideal"])
        XCTAssertEqual(surface.width, menuWidth, accuracy: 0.25)
        XCTAssertLessThan(slot.width, idealText.width)
        XCTAssertLessThanOrEqual(text.width, slot.width + 0.25)
        XCTAssertGreaterThanOrEqual(text.minX, slot.minX - 0.25)
        XCTAssertLessThanOrEqual(text.maxX, indicator.minX - ClipboardFilterBarLayout.islandContentSpacing + 0.25)
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

    func testFilterDiagnosticFormatterExcludesPrivatePresentationAndUsesAppKitConversions() throws {
        let privatePresentation = "PRIVATE_WINDOW_FILTER_SOURCE_VALUE_NOT_FOR_LOGS"
        let window = makePanel(width: 200)
        window.title = privatePresentation
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(
            frame: NSRect(x: 20, y: 0, width: 100, height: 34), pullsDown: false)
        button.addItem(withTitle: privatePresentation)
        button.selectedItem?.representedObject = privatePresentation
        button.menu?.title = privatePresentation
        button.toolTip = privatePresentation
        button.setAccessibilityLabel(privatePresentation)
        button.setAccessibilityValue(privatePresentation)
        try XCTUnwrap(window.contentView).addSubview(button)
        defer { button.removeFromSuperview(); window.close() }

        let controlPoint = NSPoint(x: 6, y: 7)
        let windowPoint = button.convert(controlPoint, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 321, clickCount: 1, pressure: 1))
        let mouse = try XCTUnwrap(ClipboardFilterInteractionDiagnostics.MouseAttempt(event))
        let snapshot = ClipboardFilterInteractionDiagnostics.snapshot(window: window, control: button,
            mouse: mouse, trackingProtected: true, focusGeneration: 43)

        XCTAssertEqual(snapshot.eventNumber, 321)
        XCTAssertEqual(snapshot.eventWindow, window.windowNumber)
        XCTAssertEqual(snapshot.eventWindowPoint, windowPoint)
        XCTAssertEqual(snapshot.eventControlPoint, controlPoint)
        XCTAssertEqual(snapshot.eventScreenPoint, window.convertPoint(toScreen: windowPoint))
        XCTAssertEqual(snapshot.windowFrame, window.frame)
        XCTAssertEqual(snapshot.controlBounds, button.bounds)
        XCTAssertEqual(snapshot.controlVisibleRect, button.visibleRect)
        XCTAssertEqual(snapshot.windowScale, window.backingScaleFactor)
        for stage in ClipboardFilterInteractionDiagnostics.Stage.allCases {
            let line = ClipboardFilterInteractionDiagnostics.formatted(stage, group: .source, snapshot: snapshot)
            XCTAssertTrue(line.contains("stage=\(stage.rawValue) group=source"))
            XCTAssertTrue(line.contains("eventNumber=321"))
            XCTAssertTrue(line.contains("trackingProtected=true focusGeneration=43"))
            XCTAssertFalse(line.contains(privatePresentation))
            for forbiddenField in ["title=", "selectedID=", "bundle=", "uuid=", "keyCode=", "characters="] {
                XCTAssertFalse(line.contains(forbiddenField))
            }
        }
    }

    func testFilterDiagnosticsReportMissingWindowAndRejectKeyboardPayload() throws {
        let privateCharacters = "PRIVATE_TYPED_TEXT_NOT_FOR_LOGS"
        let keyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: privateCharacters, charactersIgnoringModifiers: privateCharacters,
            isARepeat: false, keyCode: 0))
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.MouseAttempt(keyEvent))
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.MouseAttempt(nil))
        let snapshot = ClipboardFilterInteractionDiagnostics.snapshot(window: nil)
        let line = ClipboardFilterInteractionDiagnostics.formatted(.nativeMenuOpen, snapshot: snapshot)
        for field in ["group=nil", "eventNumber=nil", "eventWindow=nil", "window=nil", "key=nil",
                      "visible=nil", "onActiveSpace=nil", "trackingProtected=nil", "focusGeneration=nil",
                      "screenOrdinal=nil", "screenFrame=nil", "screenVisibleFrame=nil", "windowScale=nil",
                      "screenScale=nil", "windowFrame=nil", "controlBounds=nil", "controlVisibleRect=nil",
                      "eventWindowPoint=nil", "eventControlPoint=nil", "eventScreenPoint=nil"] {
            XCTAssertTrue(line.contains(field), "Missing data must remain explicit: \(field)")
        }
        XCTAssertFalse(line.contains(privateCharacters))
    }

    func testKeyboardMenuDiagnosticsDoNotReuseAnEarlierFirstMouseAttempt() throws {
        let window = makePanel(width: 200)
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(
            frame: NSRect(x: 0, y: 0, width: 100, height: 34), pullsDown: false)
        try XCTUnwrap(window.contentView).addSubview(button)
        let coordinator = ClipboardNativeFilterMenu.Coordinator(group: .format)
        coordinator.attach(button)
        coordinator.update(configuration())
        defer { coordinator.detach(); button.removeFromSuperview(); window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 6, y: 7),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 654, clickCount: 1, pressure: 1))
        XCTAssertTrue(button.acceptsFirstMouse(for: event))
        XCTAssertEqual(button.diagnosticSnapshot().eventNumber, 654)
        XCTAssertFalse(coordinator.tracking.isActive, "Logging first mouse must not begin protection or activate the panel")
        XCTAssertFalse(window.isKeyWindow)

        // A delegate callback outside mouseDown models keyboard/AX opening,
        // not a claim that AppKit displayed a menu or that an external screen works.
        coordinator.menuWillOpen(try XCTUnwrap(button.menu))
        XCTAssertNil(button.diagnosticSnapshot().eventNumber)
        XCTAssertTrue(coordinator.tracking.isMenuOpen)
    }

    func testFilterDiagnosticCoordinatesStayNilWhenTheEventBelongsToAnotherWindow() throws {
        let window = makePanel(width: 200)
        let other = makePanel(width: 200)
        let button = ClipboardNativeFilterMenu.FirstMousePopUpButton(
            frame: NSRect(x: 0, y: 0, width: 100, height: 34), pullsDown: false)
        try XCTUnwrap(window.contentView).addSubview(button)
        defer { button.removeFromSuperview(); window.close(); other.close() }
        let point = NSPoint(x: 6, y: 7)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: other.windowNumber, context: nil,
            eventNumber: 987, clickCount: 1, pressure: 1))
        let snapshot = ClipboardFilterInteractionDiagnostics.snapshot(window: window, control: button,
            mouse: ClipboardFilterInteractionDiagnostics.MouseAttempt(event))
        XCTAssertEqual(snapshot.eventWindow, other.windowNumber)
        XCTAssertEqual(snapshot.eventWindowPoint, point)
        XCTAssertNil(snapshot.eventControlPoint)
        XCTAssertNil(snapshot.eventScreenPoint)
    }

    func testFilterDiagnosticJournalIsBoundedOrderedAndCodableWithoutChangingLegacyTrace() throws {
        let journal = ClipboardFilterInteractionDiagnostics.Journal()
        let geometry = ClipboardFilterInteractionDiagnostics.snapshot(window: nil)
        let legacySequence = ClipboardInteractionTrace.shared.snapshot().events.last?.sequence
        for _ in 0..<300 {
            journal.record(.mouseDown, group: .format, snapshot: geometry)
        }
        let snapshot = journal.snapshot()
        XCTAssertEqual(snapshot.capacity, 128)
        XCTAssertEqual(snapshot.events.count, 128)
        XCTAssertEqual(snapshot.dropped, 172)
        XCTAssertEqual(snapshot.events.map(\.sequence), Array(UInt64(173)...UInt64(300)))
        XCTAssertTrue(snapshot.events.allSatisfy { $0.stage == .mouseDown && $0.group == .format })
        XCTAssertEqual(ClipboardInteractionTrace.shared.snapshot().events.last?.sequence, legacySequence)

        let decoded = try JSONDecoder().decode(ClipboardFilterInteractionDiagnostics.JournalSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.capacity, 128)
        XCTAssertEqual(decoded.dropped, 172)
        XCTAssertEqual(decoded.events.map(\.sequence), snapshot.events.map(\.sequence))
        XCTAssertTrue(decoded.events.allSatisfy { $0.snapshot.window == nil && $0.snapshot.eventNumber == nil })
        journal.record(.nativeMenuClose, snapshot: geometry)
        XCTAssertEqual(snapshot.events.last?.sequence, 300, "An exported value snapshot must not change with later events")
        XCTAssertEqual(journal.snapshot().dropped, 173)
    }

    func testFilterDiagnosticJournalSerializesConcurrentWritersUnderItsBound() {
        let journal = ClipboardFilterInteractionDiagnostics.Journal()
        let geometry = ClipboardFilterInteractionDiagnostics.snapshot(window: nil)
        DispatchQueue.concurrentPerform(iterations: 300) { _ in
            journal.record(.panelMouseDown, snapshot: geometry)
        }
        let snapshot = journal.snapshot()
        XCTAssertEqual(snapshot.events.count, 128)
        XCTAssertEqual(snapshot.dropped, 172)
        XCTAssertEqual(snapshot.events.map(\.sequence), Array(UInt64(173)...UInt64(300)))
    }

    func testFilterDiagnosticCaptureDropsInvalidGeometryBeforeJSONEncoding() throws {
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.finitePoint(NSPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.finitePoint(NSPoint(x: 0, y: CGFloat.infinity)))
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.finiteRect(NSRect(x: -CGFloat.infinity, y: 0, width: 1, height: 1)))
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.finiteRect(NSRect(x: 0, y: 0, width: CGFloat.nan, height: 1)))
        XCTAssertNil(ClipboardFilterInteractionDiagnostics.finiteRect(NSRect(x: 0, y: 0, width: -1, height: 1)))
        let invalidScales: [CGFloat] = [.nan, .infinity, -.infinity, 0, -1]
        for scale in invalidScales {
            XCTAssertNil(ClipboardFilterInteractionDiagnostics.finiteScale(scale))
        }
        let externalOrigin = NSPoint(x: -1920, y: -1080)
        let externalFrame = NSRect(origin: externalOrigin, size: NSSize(width: 1920, height: 1080))
        XCTAssertEqual(ClipboardFilterInteractionDiagnostics.finitePoint(externalOrigin), externalOrigin)
        XCTAssertEqual(ClipboardFilterInteractionDiagnostics.finiteRect(externalFrame), externalFrame)
        XCTAssertEqual(ClipboardFilterInteractionDiagnostics.finiteScale(2), 2)

        let view = ClipboardNonFiniteDiagnosticView(frame: NSRect(x: 0, y: 0, width: 100, height: 34))
        let snapshot = ClipboardFilterInteractionDiagnostics.snapshot(window: nil, control: view)
        XCTAssertNil(snapshot.controlVisibleRect)
        XCTAssertEqual(snapshot.controlBounds, view.bounds)
        let journal = ClipboardFilterInteractionDiagnostics.Journal()
        journal.record(.mouseDown, snapshot: snapshot)
        XCTAssertNoThrow(try JSONEncoder().encode(journal.snapshot()))
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

    private func makeLabelWindow(group: ClipboardFilterGroup, title: String, showsIcon: Bool,
                                 menuWidth: CGFloat, capture: ClipboardFilterLabelGeometryCapture) -> NSWindow {
        let root = VStack(alignment: .leading, spacing: 8) {
            ClipboardFilterIslandButton(group: group, activeTitle: title, isExpanded: false,
                hasActiveFilter: true, reservesClearSlot: false, showsIcon: showsIcon)
                .frame(width: menuWidth, height: ClipboardFilterBarLayout.filterHitHeight)
            Text(title)
                .blocksFont(size: ClipboardFilterBarLayout.islandTextSize, weight: .semibold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .blocksInteractionGeometryProbe("test.filter.label.ideal")
            if showsIcon {
                // The pre-fix symbol configuration is measured, not assigned
                // an assumed width equal to its font's point size.
                Image(systemName: group.systemImage)
                    .font(.system(size: ClipboardFilterBarLayout.islandIconSize, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: true)
                    .blocksInteractionGeometryProbe("test.filter.label.unboundedIcon")
            }
        }
        .frame(width: 320, height: 100, alignment: .topLeading)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .blocksInteractionGeometryProbeReporter { identifier, frame in capture.frames[identifier] = frame }
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 320, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        return window
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

@MainActor
private final class ClipboardFilterLabelGeometryCapture {
    var frames: [String: CGRect] = [:]
}

@MainActor
private final class ClipboardNonFiniteDiagnosticView: NSView {
    override var visibleRect: NSRect {
        NSRect(x: CGFloat.infinity, y: 0, width: 100, height: 34)
    }
}
