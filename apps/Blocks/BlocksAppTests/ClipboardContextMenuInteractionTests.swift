import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class ClipboardContextMenuInteractionTests: XCTestCase {
    func testRightButtonSequencePassesThroughNativeOverlay() throws {
        let view = ClipboardRecordPointerSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 140)
        )
        for type: NSEvent.EventType in [.rightMouseDown, .rightMouseDragged, .rightMouseUp] {
            let event = try mouseEvent(type)
            view.eventProvider = { event }
            XCTAssertNil(view.hitTest(NSPoint(x: 120, y: 70)), "\(type)")
        }
    }

    func testControlClickSequencePassesThroughAndCannotRecognizePrimaryActions() throws {
        let view = ClipboardRecordPointerSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 140)
        )
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let event = try mouseEvent(type, modifiers: [.control])
            view.eventProvider = { event }
            XCTAssertNil(view.hitTest(NSPoint(x: 120, y: 70)), "\(type)")
            let recognizers: [NSGestureRecognizer] = [
                view.pressRecognizer, view.singleClickRecognizer, view.doubleClickRecognizer,
            ]
            for recognizer in recognizers {
                XCTAssertFalse(view.gestureRecognizer(
                    recognizer,
                    shouldAttemptToRecognizeWith: event
                ), "Control-click must never trigger press, selection, or paste")
            }
        }
    }

    func testPrimaryClicksAndUnrelatedEventsKeepNativeOverlayHitTesting() throws {
        let view = ClipboardRecordPointerSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 140)
        )
        let point = NSPoint(x: 120, y: 70)
        view.eventProvider = { nil }
        XCTAssertTrue(view.hitTest(point) === view)

        for modifiers: NSEvent.ModifierFlags in [[], [.shift], [.option], [.command]] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let event = try mouseEvent(type, modifiers: modifiers)
                view.eventProvider = { event }
                XCTAssertTrue(view.hitTest(point) === view)
                XCTAssertTrue(view.gestureRecognizer(
                    view.singleClickRecognizer,
                    shouldAttemptToRecognizeWith: event
                ))
            }
        }

        for type: NSEvent.EventType in [.otherMouseDown, .otherMouseDragged, .otherMouseUp] {
            let event = try mouseEvent(type, modifiers: [.control])
            view.eventProvider = { event }
            XCTAssertTrue(view.hitTest(point) === view, "Unrelated buttons must not change routing")
        }
    }

    func testPassThroughDoesNotExpandOverlayHitRegion() throws {
        let view = ClipboardRecordPointerSurfaceView(
            frame: NSRect(x: 20, y: 30, width: 100, height: 60)
        )
        let event = try mouseEvent(.leftMouseDown)
        view.eventProvider = { event }
        XCTAssertTrue(view.hitTest(NSPoint(x: 70, y: 60)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 60)))
        XCTAssertNil(view.hitTest(NSPoint(x: 130, y: 60)))
        XCTAssertNil(view.hitTest(NSPoint(x: 70, y: 20)))
        XCTAssertNil(view.hitTest(NSPoint(x: 70, y: 100)))
    }

    func testRealHostingOverlayLeavesSwiftUIContextMenuSurfaceReachableWithoutActions() throws {
        // This is a native hit-routing contract, not proof that a visible menu
        // opened. The installed-app/CUA check must perform actual secondary
        // clicks and Escape, including the favorite control, on all placements.
        for source in [ClipboardPanelActivationSource.bottomCard, .sideRow] {
            let actions = SyntheticRecordActions()
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SyntheticRecordMenuFixture(
                source: source,
                actions: actions
            ))
            panel.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
            defer { panel.close() }

            let pointer = try XCTUnwrap(pointerSurface(in: hosting))
            XCTAssertGreaterThan(pointer.bounds.width, 0)
            XCTAssertGreaterThan(pointer.bounds.height, 0)
            let points = [
                NSPoint(x: pointer.bounds.midX, y: pointer.bounds.midY),
                NSPoint(x: pointer.bounds.minX + 1, y: pointer.bounds.midY),
                NSPoint(x: pointer.bounds.maxX - 1, y: pointer.bounds.midY),
                NSPoint(x: pointer.bounds.maxX - 12, y: pointer.bounds.maxY - 12),
                NSPoint(x: pointer.bounds.maxX - 12, y: pointer.bounds.minY + 12),
            ]
            for event in [
                try mouseEvent(.rightMouseDown),
                try mouseEvent(.leftMouseDown, modifiers: [.control]),
            ] {
                pointer.eventProvider = { event }
                for point in points {
                    let nativePoint = pointer.convert(point, to: pointer.superview)
                    XCTAssertNil(pointer.hitTest(nativePoint))
                    let hostedPoint = pointer.convert(point, to: hosting.superview)
                    let hostedHit = try XCTUnwrap(hosting.hitTest(hostedPoint))
                    XCTAssertFalse(hostedHit === pointer)
                    XCTAssertFalse(hostedHit.isDescendant(of: pointer))
                }
            }
            XCTAssertEqual(actions.press, 0)
            XCTAssertEqual(actions.select, 0)
            XCTAssertEqual(actions.paste, 0)
            XCTAssertEqual(actions.favorite, 0)
            XCTAssertEqual(actions.remove, 0)
        }
    }

    private func pointerSurface(in view: NSView) -> ClipboardRecordPointerSurfaceView? {
        if let pointer = view as? ClipboardRecordPointerSurfaceView { return pointer }
        for child in view.subviews {
            if let pointer = pointerSurface(in: child) { return pointer }
        }
        return nil
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }
}

@MainActor
private final class SyntheticRecordActions {
    var press = 0
    var select = 0
    var paste = 0
    var favorite = 0
    var remove = 0
}

/// Uses the complete production pointer surface and the same overlay ordering
/// as a record card, but no clipboard/store/plugin data. No synthetic events
/// are dispatched: eventProvider is injected only for synchronous hit testing.
@MainActor
private struct SyntheticRecordMenuFixture: View {
    let source: ClipboardPanelActivationSource
    let actions: SyntheticRecordActions

    var body: some View {
        Text("Synthetic clipboard record")
            .frame(width: 260, height: 160)
            .background(Color.gray.opacity(0.1))
            .overlay {
                ClipboardRecordPointerSurface(
                    panelSessionID: nil,
                    recordID: "synthetic-record",
                    source: source,
                    onPointerPress: { actions.press += 1 },
                    onSingleClick: { actions.select += 1 },
                    onDoubleClick: { actions.paste += 1 }
                )
                .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    actions.favorite += 1
                } label: {
                    Image(systemName: "star")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .padding(5)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Synthetic paste") { actions.paste += 1 }
                Button("Synthetic favorite") { actions.favorite += 1 }
                Divider()
                Button("Synthetic remove", role: .destructive) { actions.remove += 1 }
            }
    }
}
