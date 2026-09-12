import AppKit
import SwiftUI
import XCTest
@testable import Blocks
@testable import BlocksCore

@MainActor
final class TranslationInlineFeedbackTests: XCTestCase {
    func testInlineFeedbackKeepsItsReservedHeaderHeightForLongDetail() {
        let state = BlocksNotificationPresentationState()
        let host = NSHostingView(
            rootView: TranslationPanelInlineFeedbackView(state: state)
                .frame(width: 280)
        )
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        host.layoutSubtreeIfNeeded()
        let emptyHeight = host.fittingSize.height

        state.present(
            BlocksNotificationDescriptor(
                level: .error,
                title: "Translation failed",
                detail: String(repeating: "A localized recovery detail. ", count: 12),
                dismissPolicy: .manual
            )
        )
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            host.fittingSize.height,
            emptyHeight,
            accuracy: 0.5,
            "inline feedback must use the pre-reserved source-header row"
        )
        XCTAssertEqual(
            host.fittingSize.height,
            TranslationPanelMetrics.compactIconHitTarget,
            accuracy: 0.5
        )
    }

    func testPresenterRendersFeedbackWithoutAnIndependentHUDPanel() throws {
        let suiteName = "TranslationInlineFeedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )
        presenter.present()
        defer { presenter.forceClose() }

        let panel = try XCTUnwrap(presenter.panelForTesting)
        let originalFrame = panel.frame
        presenter.notificationStateForTesting.present(
            BlocksNotificationDescriptor(
                level: .warning,
                title: "Selection unavailable",
                detail: "Use a selectable text field and try again.",
                dismissPolicy: .manual
            )
        )

        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertNotNil(presenter.notificationStateForTesting.current)
        XCTAssertNil(
            presenter.notificationPanelForTesting,
            "translation feedback must not create a separate notification HUD"
        )
    }

    func testRealHostedHeaderDragAreaHasUsableGeometryAndExcludesControls() throws {
        let suiteName = "TranslationHeaderDrag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: TranslationStore(defaults: defaults)
        )
        let presenter = TranslationPanelPresenter(
            model: model,
            actions: translationPanelActions(),
            onClose: { _ in }
        )
        presenter.present()
        defer { presenter.forceClose() }
        let panel = try XCTUnwrap(presenter.panelForTesting)
        let host = try XCTUnwrap(panel.contentView)
        let container = try XCTUnwrap(host.superview)

        XCTAssertTrue(
            panel.styleMask.contains(.titled),
            "native titled chrome must retain the system outer corners"
        )
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertEqual(
            TranslationPanelMetrics.headerTotalHeight,
            50,
            accuracy: 0.5,
            "consuming the native inset must preserve the 50pt content drag lane"
        )

        for width: CGFloat in [420, 640, 980] {
            panel.setContentSize(NSSize(width: width, height: 520))
            host.layoutSubtreeIfNeeded()
            let dragAreas = descendants(of: host).compactMap {
                $0 as? TranslationPanelWindowDragArea.DragView
            }
            let topEdge = try XCTUnwrap(dragAreas.map {
                $0.convert($0.bounds, to: nil).maxY
            }.max())
            let headerAreas = dragAreas.filter {
                abs($0.convert($0.bounds, to: nil).maxY - topEdge) < 0.5
            }
            let titleDrag = try XCTUnwrap(headerAreas.max { $0.bounds.width < $1.bounds.width })
            let rect = titleDrag.convert(titleDrag.bounds, to: nil)
            XCTAssertEqual(rect.maxY, host.convert(host.bounds, to: nil).maxY, accuracy: 0.5,
                           "the content header must start at the window top, not below a transparent titlebar")
            XCTAssertGreaterThan(rect.width, 40, "title whitespace must not collapse")
            XCTAssertEqual(
                rect.height, TranslationPanelMetrics.headerTotalHeight, accuracy: 0.5,
                "the existing full header height must be draggable without growing the header"
            )
            XCTAssertGreaterThan(rect.height, TranslationPanelMetrics.headerContentHeight)
            XCTAssertEqual(host.bounds.height, 520, accuracy: 0.5)
            for titlePoint in [
                NSPoint(x: rect.midX, y: rect.midY),
                NSPoint(x: rect.midX, y: rect.minY + TranslationPanelMetrics.headerVerticalPadding / 2),
                NSPoint(x: rect.midX, y: rect.maxY - TranslationPanelMetrics.headerVerticalPadding / 2),
                NSPoint(x: rect.minX + TranslationPanelMetrics.contentInset / 2, y: rect.midY),
            ] {
                XCTAssertTrue(
                    host.hitTest(container.convert(titlePoint, from: nil)) === titleDrag,
                    "title, top/bottom padding and leading inset must all support dragging"
                )
            }
            let trailingArea = try XCTUnwrap(headerAreas.first { $0 !== titleDrag })
            let trailingRect = trailingArea.convert(trailingArea.bounds, to: nil)
            let actionPoint = NSPoint(x: (rect.maxX + trailingRect.minX) / 2, y: rect.midY)
            XCTAssertFalse(
                host.hitTest(container.convert(actionPoint, from: nil))
                    is TranslationPanelWindowDragArea.DragView,
                "the disjoint compact action group must retain its own hit testing"
            )
            let emptyArea = try XCTUnwrap(dragAreas.first {
                $0.convert($0.bounds, to: nil).maxY < rect.minY
            })
            let emptyRect = emptyArea.convert(
                emptyArea.visibleRect.intersection(emptyArea.bounds), to: nil
            )
            XCTAssertGreaterThanOrEqual(emptyRect.height, TranslationPanelMetrics.passiveContentHeight - 0.5)
            for fraction: CGFloat in [0.1, 0.5, 0.9] {
                let point = NSPoint(
                    x: emptyRect.minX + emptyRect.width * fraction,
                    y: emptyRect.minY + emptyRect.height * fraction
                )
                XCTAssertTrue(
                    host.hitTest(container.convert(point, from: nil)) === emptyArea,
                    "the real passive result region must not collapse to a 28pt drag strip"
                )
            }
            for editor in descendants(of: host).compactMap({ $0 as? NSTextView }) {
                let editorRect = editor.convert(editor.bounds, to: nil)
                XCTAssertFalse(
                    rect.intersects(editorRect),
                    "the title drag area must not overlap source text selection"
                )
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testHostedDragEventsMoveWindowAndMouseUpEndsTheSession() throws {
        let (panel, host, dragView, startPoint) = try makeDragFixture()
        defer { panel.contentView = nil }
        let initialOrigin = panel.frame.origin
        let startScreen = panel.convertPoint(toScreen: startPoint)
        let target = try XCTUnwrap(
            host.hitTest(try XCTUnwrap(host.superview).convert(startPoint, from: nil))
        )
        XCTAssertTrue(target === dragView)
        target.mouseDown(with: try mouseEvent(.leftMouseDown, screenPoint: startScreen, window: panel))
        target.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            screenPoint: NSPoint(x: startScreen.x + 110, y: startScreen.y - 70),
            window: panel
        ))
        XCTAssertEqual(panel.frame.origin.x, initialOrigin.x + 110, accuracy: 0.5)
        XCTAssertEqual(panel.frame.origin.y, initialOrigin.y - 70, accuracy: 0.5)

        // Event coordinates must be converted against the window's new origin.
        // A second event at the same screen point must not accumulate movement.
        let endScreen = NSPoint(x: startScreen.x + 110, y: startScreen.y - 70)
        let movedOrigin = panel.frame.origin
        target.mouseDragged(with: try mouseEvent(.leftMouseDragged, screenPoint: endScreen, window: panel))
        XCTAssertEqual(panel.frame.origin, movedOrigin)
        target.mouseUp(with: try mouseEvent(.leftMouseUp, screenPoint: endScreen, window: panel))
        target.mouseDragged(with: try mouseEvent(.leftMouseDragged, screenPoint: startScreen, window: panel))
        XCTAssertEqual(panel.frame.origin, movedOrigin, "mouseUp must discard the captured drag origin")

        let editor = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextView }.first)
        let editorPoint = editor.convert(NSPoint(x: 20, y: 10), to: nil)
        XCTAssertTrue(
            host.hitTest(try XCTUnwrap(host.superview).convert(editorPoint, from: nil)) is NSTextView,
            "source text must retain native text hit testing after a window drag"
        )
    }

    func testHostedDragClearsWhenDetachedOrCancelled() throws {
        let (panel, host, dragView, startPoint) = try makeDragFixture()
        defer { panel.contentView = nil }
        let initialOrigin = panel.frame.origin
        let startScreen = panel.convertPoint(toScreen: startPoint)
        let endScreen = NSPoint(x: startScreen.x + 30, y: startScreen.y - 20)

        dragView.mouseDown(with: try mouseEvent(.leftMouseDown, screenPoint: startScreen, window: panel))
        panel.contentView = nil
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        dragView.mouseDragged(with: try mouseEvent(.leftMouseDragged, screenPoint: endScreen, window: panel))
        XCTAssertEqual(panel.frame.origin, initialOrigin, "reattachment must not revive an old drag")

        dragView.mouseDown(with: try mouseEvent(.leftMouseDown, screenPoint: startScreen, window: panel))
        dragView.cancelOperation(nil)
        dragView.mouseDragged(with: try mouseEvent(.leftMouseDragged, screenPoint: endScreen, window: panel))
        XCTAssertEqual(panel.frame.origin, initialOrigin, "cancellation must discard the drag session")
    }

    private func makeDragFixture() throws -> (
        NSPanel, NSView, TranslationPanelWindowDragArea.DragView, NSPoint
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 420, height: 320),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            TranslationPanelWindowDragArea().frame(height: 28)
            TextEditor(text: .constant("Native source selection"))
        })
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let dragView = try XCTUnwrap(descendants(of: host).compactMap {
            $0 as? TranslationPanelWindowDragArea.DragView
        }.first)
        let rect = dragView.convert(dragView.bounds, to: nil)
        return (panel, host, dragView, NSPoint(x: rect.midX, y: rect.midY))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        screenPoint: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func translationPanelActions() -> TranslationPanelActions {
        TranslationPanelActions(
            copyText: { _ in .copiedAndRecorded },
            openFavorites: {},
            openTranslationSettings: {},
            retakeScreenshot: {}
        )
    }
}
