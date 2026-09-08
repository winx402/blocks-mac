import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class SurfaceBoundaryTests: XCTestCase {
    func testScreenshotUnionChromeUsesRealDisplaySafeBounds() {
        let source = CGRect(x: -1512, y: 0, width: 3024, height: 982)
        let insets = ScreenshotEditorChromeSafeArea.resolve(sourceFrame: source, displays: [
            (CGRect(x: -1512, y: 0, width: 1512, height: 982),
             NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)),
            (CGRect(x: 0, y: 0, width: 1200, height: 800),
             NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
        ])
        XCTAssertEqual(insets.top, 32)
        XCTAssertEqual(insets.leading, 0)
        XCTAssertEqual(insets.trailing, 1512)
        XCTAssertEqual(insets.bottom, 0)
    }

    func testSingleDisplayChromePreservesNotchInsets() {
        let frame = CGRect(x: -1512, y: -982, width: 1512, height: 982)
        let insets = ScreenshotEditorChromeSafeArea.resolve(sourceFrame: frame, displays: [
            (frame, NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)),
        ])
        XCTAssertEqual(insets.top, 32)
        XCTAssertEqual(insets.leading, 0)
        XCTAssertEqual(insets.trailing, 0)
        XCTAssertEqual(insets.bottom, 0)
    }

    func testOffsetDisplaysAndGapKeepChromeOnLargerRightScreen() {
        let source = CGRect(x: -1000, y: 0, width: 2500, height: 1000)
        let insets = ScreenshotEditorChromeSafeArea.resolve(sourceFrame: source, displays: [
            (CGRect(x: -1000, y: 0, width: 800, height: 600), NSEdgeInsets()),
            (CGRect(x: 0, y: 200, width: 1500, height: 800),
             NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)),
        ])
        XCTAssertEqual(insets.top, 32)
        XCTAssertEqual(insets.leading, 1000)
        XCTAssertEqual(insets.trailing, 0)
        XCTAssertEqual(insets.bottom, 200)
    }

    func testWindowBackgroundCoversNativeTitlebar() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            throw XCTSkip("This test measures the normal material backing; reduced-transparency uses a SwiftUI Color backing")
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(rootView:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blocksBackground(.content)
                .blocksBackground(.window)
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()

        func surfaces(in view: NSView) -> [BlocksAppKitGlassSurfaceView] {
            (view as? BlocksAppKitGlassSurfaceView).map { [$0] } ??
                view.subviews.flatMap { surfaces(in: $0) }
        }
        let found = surfaces(in: hosting)
        let surface = try XCTUnwrap(found.first { $0.blocksSurfaceConfiguration.role == .window })
        let content = try XCTUnwrap(found.first { $0.blocksSurfaceConfiguration.role == .content })
        let fullBounds = hosting.convert(hosting.bounds, to: nil)
        let backgroundBounds = surface.convert(surface.bounds, to: nil)
        XCTAssertGreaterThan(fullBounds.maxY - window.contentLayoutRect.maxY, 1,
                             "Fixture must expose a real titlebar safe area")
        XCTAssertEqual(backgroundBounds.minX, fullBounds.minX, accuracy: 1)
        XCTAssertEqual(backgroundBounds.maxX, fullBounds.maxX, accuracy: 1)
        XCTAssertEqual(backgroundBounds.minY, fullBounds.minY, accuracy: 1)
        XCTAssertEqual(backgroundBounds.maxY, fullBounds.maxY, accuracy: 1)
        XCTAssertGreaterThan(backgroundBounds.maxY, window.contentLayoutRect.maxY + 1)
        XCTAssertGreaterThan(content.bounds.height, 0)
        XCTAssertEqual(content.convert(content.bounds, to: nil).maxY,
                       window.contentLayoutRect.maxY, accuracy: 1,
                       "Non-window surfaces must keep the foreground safe area")
    }

    func testBackingNeverOwnsForegroundControlsAcrossRenderingModes() throws {
        // .window exercises the NSVisualEffectView fallback and .section the
        // opaque path without modifying global accessibility preferences.
        for role: BlocksSurfaceRole in [.window, .section, .panel] {
            let surface = BlocksAppKitGlassSurfaceView(
                frame: CGRect(x: 0, y: 0, width: 240, height: 96)
            )
            surface.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
                role: role,
                cornerRadius: BlocksVisualTokens.CornerRadius.large,
                drawsShadow: false
            )
            let control = NSButton(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
            surface.addBlocksContentSubview(control)
            surface.layoutSubtreeIfNeeded()

            XCTAssertTrue(surface.blocksContentView.superview === surface)
            XCTAssertFalse(surface.blocksContentView.layer?.masksToBounds ?? false)
            XCTAssertFalse(surface.layer?.masksToBounds ?? false)
            let backing = try XCTUnwrap(surface.subviews.first)
            XCTAssertFalse(backing === surface.blocksContentView)
            XCTAssertFalse(control.isDescendant(of: backing))
            XCTAssertEqual(surface.blocksContentView.frame, surface.bounds)

            if surface.activeRenderingMode == .liquidGlass {
                XCTAssertFalse(backing.layer?.masksToBounds ?? false)
                XCTAssertEqual(surface.layer?.borderWidth, 0)
                if #available(macOS 26.0, *) {
                    let container = try XCTUnwrap(backing as? NSGlassEffectContainerView)
                    let glass = try XCTUnwrap(container.contentView as? NSGlassEffectView)
                    XCTAssertEqual(glass.cornerRadius, BlocksVisualTokens.CornerRadius.large)
                    // The system may implement its own glass clipping. Our
                    // foreground controls must not be inside that boundary.
                    XCTAssertFalse(glass.contentView === surface.blocksContentView)
                }
            } else {
                XCTAssertTrue(backing.layer?.masksToBounds ?? false)
                XCTAssertEqual(backing.layer?.cornerRadius, BlocksVisualTokens.CornerRadius.large)
            }

            surface.updateBlocksSurface()
            XCTAssertTrue(control.superview === surface.blocksContentView)
            XCTAssertTrue(surface.blocksContentView.superview === surface)
        }
    }

    func testExternalNotificationSynchronizationPreservesIdentityAndActions() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a screen") }
        let state = BlocksNotificationPresentationState()
        let presenter = BlocksNotificationPanelPresenter(state: state)
        defer { presenter.shutdown() }
        var actionCount = 0
        let descriptor = BlocksNotificationDescriptor(
            level: .error,
            title: "Translation failed",
            deduplicationKey: "translation.operation.error",
            action: BlocksNotificationAction(title: "Retry") { actionCount += 1 }
        )
        state.present(descriptor)
        presenter.synchronize(on: screen)
        let panel = try XCTUnwrap(presenter.panelForTesting)
        XCTAssertNil(panel.parent)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(state.current?.occurrenceCount, 1)
        XCTAssertEqual(state.current?.id, descriptor.id)

        presenter.synchronize(on: screen)
        XCTAssertEqual(state.current?.occurrenceCount, 1)
        state.present(descriptor)
        presenter.synchronize(on: screen)
        XCTAssertEqual(state.current?.occurrenceCount, 2)
        state.current?.descriptor.action?.handler()
        XCTAssertEqual(actionCount, 1)
        presenter.hide()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(state.current)
        presenter.shutdown()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(state.current)
    }
}
