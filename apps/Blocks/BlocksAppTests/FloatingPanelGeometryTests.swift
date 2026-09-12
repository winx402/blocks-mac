import AppKit
import XCTest
@testable import Blocks

@MainActor
final class FloatingPanelGeometryTests: XCTestCase {
    func testTransientNonactivatingUtilityUsesStatusBarLevelAboveDock() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        BlocksFloatingPanelWindowRole.transientNonactivatingUtility.apply(
            to: panel
        )

        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.screenSaver.rawValue)
    }

    func testBottomFrameAlwaysUsesPhysicalBottomRegardlessOfDockInset() {
        let physicalScreen = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        let beforeDockChange = CGRect(x: -1_440, y: 24, width: 1_440, height: 876)
        let afterDockChange = CGRect(x: -1_440, y: 96, width: 1_440, height: 804)

        let before = FloatingPanelFrameStore.clipboardBottomFrame(
            visibleFrame: FloatingPanelFrameStore.clipboardBottomBounds(screenFrame: physicalScreen, visibleFrame: beforeDockChange),
            height: 320
        )
        let after = FloatingPanelFrameStore.clipboardBottomFrame(
            visibleFrame: FloatingPanelFrameStore.clipboardBottomBounds(screenFrame: physicalScreen, visibleFrame: afterDockChange),
            height: before.height
        )

        XCTAssertEqual(before.minY, physicalScreen.minY)
        XCTAssertEqual(after.minY, physicalScreen.minY)
        XCTAssertEqual(after.width, afterDockChange.width)
        XCTAssertEqual(after.height, before.height)
    }

    func testPhysicalBottomAnchorPreservesNegativeScreenOriginAndMenuBarCeiling() {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: -1000, width: 1920, height: 976)
        let bounds = FloatingPanelFrameStore.clipboardBottomBounds(screenFrame: screen, visibleFrame: visible)
        let panel = FloatingPanelFrameStore.clipboardBottomFrame(visibleFrame: bounds, height: 286)
        XCTAssertEqual(panel.minY, -1080)
        XCTAssertEqual(panel.minX, -1920)
        XCTAssertEqual(bounds.maxY, visible.maxY)
        XCTAssertEqual(panel.height, 286)
    }

    func testScreenResolverPrefersTheDisplayContainingMostOfThePanel() {
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
        ]

        XCTAssertEqual(
            FloatingPanelScreenResolver.screenIndex(
                containingMostOf: CGRect(x: -1_200, y: 32, width: 960, height: 300),
                screenFrames: screenFrames
            ),
            1
        )
        XCTAssertEqual(
            FloatingPanelScreenResolver.screenIndex(
                containingMostOf: CGRect(x: -180, y: 32, width: 1_000, height: 300),
                screenFrames: screenFrames
            ),
            0
        )
        XCTAssertNil(
            FloatingPanelScreenResolver.screenIndex(
                containingMostOf: CGRect(x: 2_000, y: 32, width: 320, height: 300),
                screenFrames: screenFrames
            )
        )
    }

    func testVisibleFrameObserverForwardsScreenParameterChangesAndStops() async {
        let center = NotificationCenter()
        let observer = FloatingPanelVisibleFrameObserver(notificationCenter: center)
        let forwarded = expectation(description: "screen parameters forwarded")

        observer.start {
            forwarded.fulfill()
        }
        XCTAssertTrue(observer.isObserving)

        center.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        await fulfillment(of: [forwarded], timeout: 1)

        observer.stop()
        XCTAssertFalse(observer.isObserving)
    }

    func testAppKitSurfaceBackingIsMaskedWhileItsHostKeepsShadowOverflow() {
        let surface = BlocksAppKitGlassSurfaceView(
            frame: CGRect(x: 0, y: 0, width: 240, height: 96)
        )
        surface.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .panel,
            cornerRadius: 18,
            drawsShadow: true
        )
        surface.layoutSubtreeIfNeeded()

        guard let backing = surface.subviews.first else {
            return XCTFail("Expected the surface to install one clipped backing view.")
        }
        XCTAssertEqual(surface.layer?.cornerRadius, 18)
        XCTAssertFalse(surface.layer?.masksToBounds ?? true)
        if surface.activeRenderingMode == .liquidGlass {
            XCTAssertFalse(backing.layer?.masksToBounds ?? false)
            XCTAssertEqual(surface.layer?.borderWidth, 0)
        } else {
            XCTAssertEqual(backing.layer?.cornerRadius, 18)
            XCTAssertTrue(backing.layer?.masksToBounds ?? false)
        }
        XCTAssertTrue(surface.blocksContentView.superview === surface)
    }
}
