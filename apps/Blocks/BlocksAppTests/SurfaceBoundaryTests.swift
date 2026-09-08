import AppKit
import XCTest
@testable import Blocks

@MainActor
final class SurfaceBoundaryTests: XCTestCase {
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
