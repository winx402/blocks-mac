import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class ClipboardFilterInteractionTests: XCTestCase {
    func testDiagnosticTraceIsBoundedOrderedAndRotatesSession() throws {
        let trace = ClipboardInteractionTrace()
        trace.record(.openRequested)
        let firstSession = try XCTUnwrap(trace.snapshot().events.first?.session)
        for _ in 0..<300 { trace.record(.rowHover, hovered: true, favorite: false) }
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.events.count, 256)
        XCTAssertEqual(snapshot.dropped, 45)
        XCTAssertEqual(snapshot.events.first?.sequence, 46)
        XCTAssertEqual(snapshot.events.last?.sequence, 301)
        trace.record(.openRequested)
        XCTAssertNotEqual(trace.snapshot().events.last?.session, firstSession)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClipboardInteractionTrace.Snapshot.self, from: encoded)
        XCTAssertEqual(decoded.events.count, 256)
        XCTAssertTrue(decoded.events.allSatisfy { $0.control == nil && $0.group == nil })
    }

    func testFilterCallbacksProduceContentFreeDiagnosticSequence() {
        let before = ClipboardInteractionTrace.shared.snapshot().events.last?.sequence ?? 0
        ClipboardFilterInteractionDiagnostics.pointer(group: .format, windowNumber: 123, isKeyWindow: false)
        ClipboardFilterInteractionDiagnostics.selection(group: .format)
        let events = ClipboardInteractionTrace.shared.snapshot().events.filter { $0.sequence > before }
        XCTAssertEqual(events.map(\.stage), [.filterPointer, .filterSelection])
        XCTAssertEqual(events.first?.window, 123)
        XCTAssertEqual(events.first?.key, false)
        XCTAssertEqual(events.first?.session, events.last?.session)
    }

    func testProbeDoesNotInterceptAndOnlyObservesPressesInsideItsOwnVisibleBounds() throws {
        let window = makeWindow()
        let probe = ClipboardFilterPointerProbeView(frame: NSRect(x: 20, y: 30, width: 100, height: 28))
        window.contentView?.addSubview(probe)
        defer { probe.removeFromSuperview(); window.close() }

        XCTAssertNil(probe.hitTest(NSPoint(x: 40, y: 40)))
        let inside = try mouseEvent(.leftMouseDown, window: window, point: NSPoint(x: 40, y: 40))
        XCTAssertTrue(probe.containsMenuPress(inside))
        XCTAssertTrue(probe.processLocalEvent(inside) === inside)

        let outside = try mouseEvent(.leftMouseDown, window: window, point: NSPoint(x: 170, y: 40))
        XCTAssertFalse(probe.containsMenuPress(outside))
        XCTAssertTrue(probe.processLocalEvent(outside) === outside)
        XCTAssertFalse(probe.containsMenuPress(try mouseEvent(.rightMouseDown, window: window, point: NSPoint(x: 40, y: 40))))
        probe.isHidden = true
        XCTAssertFalse(probe.containsMenuPress(inside))
    }

    func testProbeExcludesAnotherWindowAndRemovesMonitorWhenDetached() throws {
        let first = makeWindow()
        let second = makeWindow()
        let probe = ClipboardFilterPointerProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        first.contentView?.addSubview(probe)
        defer { probe.removeFromSuperview(); first.close(); second.close() }

        XCTAssertTrue(probe.isMonitoring)
        let other = try mouseEvent(.leftMouseDown, window: second, point: NSPoint(x: 10, y: 10))
        XCTAssertFalse(probe.containsMenuPress(other))
        XCTAssertTrue(probe.processLocalEvent(other) === other)
        probe.removeFromSuperview()
        XCTAssertFalse(probe.isMonitoring)
        probe.stopMonitoring() // dismantling after detachment is idempotent
        XCTAssertFalse(probe.isMonitoring)
    }

    func testCursorSurfaceDoesNotInterceptAndDisabledChipsHaveNoHandRect() {
        let window = makeWindow()
        let view = ClipboardFilterCursorView(frame: NSRect(x: 20, y: 30, width: 100, height: 28))
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview(); window.close() }
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertEqual(view.pointingHandCursorRect, view.bounds)
        view.frame.origin.x = 220
        XCTAssertEqual(view.pointingHandCursorRect?.width, 20)
        view.isEnabled = false
        XCTAssertNil(view.pointingHandCursorRect)
    }

    func testChipHoverAndPressUseSharedTransientAppearanceWithoutChangingSelection() {
        XCTAssertEqual(BlocksChipInteraction.state(isEnabled: true, isHovered: false, isPressed: false), .idle)
        XCTAssertEqual(BlocksChipInteraction.state(isEnabled: true, isHovered: true, isPressed: false), .hovered)
        XCTAssertEqual(BlocksChipInteraction.state(isEnabled: true, isHovered: true, isPressed: true), .pressed)
        XCTAssertEqual(BlocksChipInteraction.state(isEnabled: false, isHovered: true, isPressed: true), .disabled)
        XCTAssertGreaterThan(BlocksInteractionAppearance.resolve(.hovered).fillOpacity, BlocksInteractionAppearance.resolve(.idle).fillOpacity)
    }

    func testAllNativeMenusRemainLayoutableWithActivationPolicyInNonKeyPanel() {
        let window = makeWindow()
        defer { window.close() }
        XCTAssertFalse(window.isKeyWindow)
        for group in ClipboardFilterGroup.nonTagCases {
            let view = NSHostingView(rootView: ClipboardFilterMenuGroup(
                group: group, activeTitle: nil, hasActiveFilter: false,
                sourceOptions: [], filterState: ClipboardFilterState(),
                onSelectFormat: { _ in }, onSelectTime: { _ in },
                onSelectSource: { _ in }, onClearGroup: {}
            ))
            view.frame = NSRect(x: 0, y: 0, width: 200, height: 36)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.width, 0)
            XCTAssertGreaterThan(view.fittingSize.height, 0)
        }
        // Layout is not a runtime first-click acceptance test. That check must
        // exercise the installed app with a non-key/pinned panel.
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func mouseEvent(_ type: NSEvent.EventType, window: NSWindow, point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }
}
