import AppKit
import SwiftUI
import XCTest
@testable import Blocks
@testable import BlocksScreenshotCore

@MainActor
final class ScreenshotEditorIssueLayoutTests: XCTestCase {
    func testDisplayCaptureKeepsEveryPixelInFullCanvasWithChromeInside() {
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 900, height: 1440), CGSize(width: 5120, height: 1440)] {
            let pixels = ScreenshotPixelRect(x: 0, y: 0, width: Int(size.width * 2), height: Int(size.height * 2))
            let frames = ScreenshotEditorCropChromeLayout.resolve(
                availableSize: size, sourceRect: pixels, cropRect: pixels, zoomScale: 1, panOffset: .zero,
                statusWidth: 240, toolbarWidth: 800, presentation: .displayOverlay
            )
            XCTAssertEqual(frames.canvas, CGRect(origin: .zero, size: size))
            XCTAssertEqual(frames.crop, frames.canvas)
            XCTAssertTrue(frames.crop.contains(frames.status))
            XCTAssertTrue(frames.crop.contains(frames.toolbar))
            XCTAssertEqual(frames.crop.width / frames.crop.height, CGFloat(pixels.width) / CGFloat(pixels.height), accuracy: 0.0001)
        }
    }

    func testNotchMovesOnlyChromeAndDoesNotShrinkTheImage() {
        let size = CGSize(width: 1512, height: 982)
        let pixels = ScreenshotPixelRect(x: 0, y: 0, width: 3024, height: 1964)
        let frames = ScreenshotEditorCropChromeLayout.resolve(
            availableSize: size, sourceRect: pixels, cropRect: pixels, zoomScale: 1, panOffset: .zero,
            statusWidth: 260, toolbarWidth: 900, presentation: .displayOverlay,
            safeAreaInsets: EdgeInsets(top: 32, leading: 0, bottom: 0, trailing: 0)
        )
        XCTAssertEqual(frames.crop, CGRect(origin: .zero, size: size))
        XCTAssertGreaterThanOrEqual(frames.status.minY, 32 + ScreenshotEditorChromeMetrics.edgeInset)
    }

    func testOnlyCompleteDisplaySourcesOptIntoOverlayIncludingNegativeCoordinates() {
        let display = CGRect(x: -1440, y: -300, width: 1440, height: 900)
        XCTAssertEqual(ScreenshotEditorCanvasPresentation.resolve(sourceFrame: display, captureFrame: display, displayFrames: [display]), .displayOverlay)
        XCTAssertEqual(ScreenshotEditorCanvasPresentation.resolve(sourceFrame: display, captureFrame: display.insetBy(dx: 120, dy: 75), displayFrames: [display]), .cropSurround)
        XCTAssertEqual(ScreenshotEditorCanvasPresentation.resolve(sourceFrame: display, captureFrame: display, displayFrames: []), .cropSurround)
        XCTAssertEqual(ScreenshotEditorCanvasPresentation.resolve(sourceFrame: display, captureFrame: display, displayFrames: [display], isLongImage: true), .cropSurround)
        let other = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let union = display.union(other)
        XCTAssertEqual(ScreenshotEditorCanvasPresentation.resolve(sourceFrame: union, captureFrame: union, displayFrames: [display, other]), .displayOverlay)
        XCTAssertEqual(ScreenshotEditorCanvasPresentation.resolve(sourceFrame: union, captureFrame: display, displayFrames: [display, other]), .cropSurround)
    }

    func testOrdinaryRegionKeepsItsExistingSurroundLayout() {
        let frames = ScreenshotEditorCropChromeLayout.resolve(
            availableSize: CGSize(width: 1200, height: 800),
            sourceRect: .init(x: 0, y: 0, width: 1200, height: 800),
            cropRect: .init(x: 200, y: 200, width: 600, height: 300),
            zoomScale: 1, panOffset: .zero, statusWidth: 180, toolbarWidth: 620
        )
        XCTAssertEqual(frames.crop, CGRect(x: 200, y: 200, width: 600, height: 300))
        XCTAssertFalse(frames.status.intersects(frames.crop))
        XCTAssertFalse(frames.toolbar.intersects(frames.crop))
    }

    func testToolbarWidthIsBoundedByDisplayInsteadOf760PointCeiling() {
        XCTAssertEqual(ScreenshotEditorChromeMetrics.maximumWidth(in: 1440), 1392)
        XCTAssertEqual(ScreenshotEditorChromeMetrics.maximumWidth(in: 560), 512)
    }

    func testActualToolbarIntrinsicSizeIncludesBothPluginSlotsWithoutDeferredMeasurement() {
        let baseline = NSHostingView(rootView: toolbar(pluginWidth: 0))
        let plugins = NSHostingView(rootView: toolbar(pluginWidth: 180))
        let first = plugins.fittingSize
        plugins.frame = CGRect(origin: .zero, size: first)
        plugins.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(first.width, baseline.fittingSize.width + 300)
        XCTAssertGreaterThan(first.width, 760)
        XCTAssertLessThanOrEqual(first.width, 1200)
        XCTAssertEqual(first.width, plugins.fittingSize.width, accuracy: 0.5)
        XCTAssertEqual(first.height, ScreenshotEditorChromeMetrics.bottomToolbarHeight, accuracy: 0.5)
    }

    func testStatusFirstFrameHugsRealLocalizedContentAndPluginWithoutWidthCallback() {
        for title in ["插件状态", "Plugin status and dimensions", "プラグインのステータスと寸法"] {
            let host = NSHostingView(rootView: ScreenshotEditorStatusBar(
                elements: [], selectedElementID: nil, isRoundedOutput: false, width: 900,
                isSizePanelPresented: .constant(false), sizePanel: AnyView(EmptyView()),
                onToggleRounded: {}, onSelectElement: { _ in }, onDeleteElement: { _, _ in },
                pluginContent: AnyView(Button(title) {})
            ))
            let first = host.fittingSize
            host.frame = CGRect(origin: .zero, size: first)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(first.width, 160)
            XCTAssertLessThan(first.width, 900)
            XCTAssertEqual(first.height, ScreenshotEditorChromeMetrics.statusBarHeight, accuracy: 0.5)
            XCTAssertEqual(first.width, host.fittingSize.width, accuracy: 0.5)
        }
    }

    private func toolbar(pluginWidth: CGFloat) -> some View {
        ScreenshotEditorToolbarPanelLayout(maximumWidth: 1200) {
            ScreenshotUnifiedEditorToolbar(
                state: .init(activeToolbarItemID: .arrow, canUndo: true, canRedo: false, isOutputPending: false, currentOutputCommand: nil),
                presentation: .make(quickTools: [.arrow, .rectangle, .text, .highlight, .pixelate], extendedTools: [.ellipse, .ocr], selectedItem: .arrow),
                pluginToolContent: pluginWidth > 0 ? AnyView(Button("Plugin tool") {}.frame(width: pluginWidth)) : nil,
                pluginOutputContent: pluginWidth > 0 ? AnyView(Button("Plugin output") {}.frame(width: pluginWidth)) : nil,
                moreToolsPresentation: .constant(.init()), moreToolsTriggerFocusRequestID: nil,
                onMoreToolsExit: {}, onCanvasAction: { _ in }
            )
            Text("Select an object")
                .fixedSize()
                .frame(height: ScreenshotDesignTokens.toolbarPropertyHeight)
        }
    }
}
