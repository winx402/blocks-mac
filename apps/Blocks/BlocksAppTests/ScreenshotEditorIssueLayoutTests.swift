import AppKit
import BlocksCore
import SwiftUI
import XCTest
@testable import Blocks
@testable import BlocksScreenshotCore

@MainActor
final class ScreenshotEditorIssueLayoutTests: XCTestCase {
    func testPropertiesStripUpdatesItsActualControlsWhenTheToolChanges() throws {
        let defaultsSuite = "ScreenshotEditorIssueLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let store = try ScreenshotEditorStore(
            capture: propertyStripCapture(),
            preferencesStore: ScreenshotPreferencesStore(userDefaults: defaults),
            onComplete: { _ in },
            onRetake: {},
            onClose: {}
        )
        let aspect = ScreenshotAspectControlModel(
            selection: ScreenshotAspectSelection(orientation: store.aspectOrientation, constraint: store.cropConstraint),
            customConstraints: store.preferencesStore.preferences.customConstraints
        )
        let host = NSHostingView(rootView: ScreenshotExpandedPropertiesRow(
            store: store, aspectControlModel: aspect, maximumWidth: 1200,
            maximumPluginInspectorHeight: 300
        ))
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 1_200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let selectionSize = host.fittingSize
        XCTAssertGreaterThan(selectionSize.width, 0)

        store.selectTool(.rectangle)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            host.fittingSize.width, selectionSize.width + 100,
            "The actual rectangle controls must replace the compact selection hint without rebuilding the host."
        )
    }

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

    func testMultilineInspectorPluginUsesIndependentCappedScrollArea() throws {
        let baseline = NSHostingView(rootView: toolbar(pluginWidth: 0))
        let singleRow = NSHostingView(rootView: toolbar(
            pluginWidth: 0,
            inspectorPluginContent: inspectorPluginFixture(rowCount: 1)
        ))
        let plugin = NSHostingView(rootView: toolbar(
            pluginWidth: 0,
            inspectorPluginContent: inspectorPluginFixture(rowCount: 16)
        ))
        let baselineSize = baseline.fittingSize
        let singleRowSize = singleRow.fittingSize
        let pluginSize = plugin.fittingSize
        plugin.frame = CGRect(origin: .zero, size: pluginSize)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: pluginSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = plugin
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        plugin.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            baselineSize.height,
            ScreenshotEditorChromeMetrics.bottomToolbarHeight,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(
            singleRowSize.height,
            ScreenshotEditorChromeMetrics.bottomToolbarHeight
        )
        XCTAssertGreaterThan(pluginSize.height, singleRowSize.height)
        XCTAssertGreaterThan(
            pluginSize.height,
            ScreenshotEditorChromeMetrics.bottomToolbarHeight
                + ScreenshotDesignTokens.toolbarPropertyHeight
        )
        XCTAssertLessThanOrEqual(
            pluginSize.height,
            ScreenshotEditorChromeMetrics.bottomToolbarHeight
                + 180
                + BlocksVisualTokens.Spacing.xs
                + 1
        )
        XCTAssertEqual(pluginSize.width, plugin.fittingSize.width, accuracy: 0.5)
        XCTAssertEqual(pluginSize.height, plugin.fittingSize.height, accuracy: 0.5)
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ??
                view.subviews.flatMap { scrollViews(in: $0) }
        }
        let actualScrollViews = scrollViews(in: plugin)
        let scrollGeometry = actualScrollViews.map {
            ["viewport": $0.contentView.bounds.height, "document": $0.documentView?.bounds.height ?? 0]
        }
        let scroll = try XCTUnwrap(actualScrollViews.first { view in
            (view.documentView?.bounds.height ?? 0) > view.contentView.bounds.height + 1
        }, "Multiline inspector must have a real scrollable viewport: \(scrollGeometry)")
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.height, 181)
        let before = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: CGPoint(x: before.x, y: before.y + 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertNotEqual(scroll.contentView.bounds.origin, before,
                          "The lower plugin rows must be reachable by scrolling")
    }

    func testEmptyInspectorSlotHostDoesNotCreateAPropertiesSurface() {
        let manager = BlocksNativePluginManager(storageUnavailableBecause: NSError(
            domain: "ScreenshotEditorIssueLayoutTests",
            code: 1
        ))
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let slotHost = NSHostingView(rootView: BlocksPluginUISlotHost(
            manager: manager,
            runtime: runtime,
            slot: .screenshotInspectorSection
        ))

        XCTAssertFalse(BlocksPluginUISlotHost.hasRenderableContribution(
            manager: manager,
            slot: .screenshotInspectorSection
        ))
        XCTAssertEqual(slotHost.fittingSize, .zero)
    }

    func testExternalPluginActionErrorIsRoutedAwayFromFixedToolbarFlow() {
        var inlineError: String?
        var notificationDetail: String?

        BlocksPluginUIActionErrorRouting.report(
            "plugin fixture failure",
            onActionError: { notificationDetail = $0 },
            setInlineActionError: { inlineError = $0 }
        )

        XCTAssertEqual(notificationDetail, "plugin fixture failure")
        XCTAssertNil(inlineError)

        BlocksPluginUIActionErrorRouting.report(
            "default fixture failure",
            onActionError: nil,
            setInlineActionError: { inlineError = $0 }
        )
        XCTAssertEqual(inlineError, "default fixture failure")
    }

    func testStatusFirstFrameKeepsSharedGridAcrossLocalizedPluginContent() {
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
            XCTAssertEqual(first.width, 900, accuracy: 0.5)
            XCTAssertEqual(first.height, ScreenshotEditorChromeMetrics.statusBarHeight, accuracy: 0.5)
            XCTAssertEqual(first.width, host.fittingSize.width, accuracy: 0.5)
        }
    }

    private func toolbar(
        pluginWidth: CGFloat,
        inspectorPluginContent: AnyView? = nil
    ) -> some View {
        ScreenshotEditorToolbarPanelLayout(maximumWidth: 1200) {
            ScreenshotUnifiedEditorToolbar(
                state: .init(activeToolbarItemID: .arrow, canUndo: true, canRedo: false, isOutputPending: false, currentOutputCommand: nil),
                presentation: .make(quickTools: [.arrow, .rectangle, .text, .highlight, .pixelate], extendedTools: [.ellipse, .ocr], selectedItem: .arrow),
                pluginToolContent: pluginWidth > 0 ? AnyView(Button("Plugin tool") {}.frame(width: pluginWidth)) : nil,
                pluginOutputContent: pluginWidth > 0 ? AnyView(Button("Plugin output") {}.frame(width: pluginWidth)) : nil,
                moreToolsPresentation: .constant(.init()), moreToolsTriggerFocusRequestID: nil,
                onMoreToolsExit: {}, onCanvasAction: { _ in }
            )
            ScreenshotEditorPropertiesContentLayout(
                maximumWidth: 1200,
                maximumPluginInspectorHeight: 180,
                propertyContent: AnyView(
                    Text("Select an object")
                        .fixedSize()
                ),
                pluginContent: inspectorPluginContent
            )
        }
    }

    private func inspectorPluginFixture(rowCount: Int) -> AnyView {
        let rows: [JSONValue] = (0..<rowCount).map { index in
            .object([
                "title": .string("Plugin row \(index)"),
                "detail": .string(
                    "Multi-line inspector fixture content \(index)"
                ),
                "value": .string("value \(index)"),
            ])
        }
        return AnyView(BlocksPluginUIRenderer(
            contribution: .init(
                id: "multiline-inspector",
                slot: .screenshotInspectorSection,
                root: .init(
                    id: "root",
                    kind: .section,
                    title: "Plugin inspector",
                    children: [
                        .init(
                            id: "rows",
                            kind: .table,
                            properties: ["items": .array(rows)]
                        ),
                    ]
                )
            ),
            runtimeState: [:],
            performAction: { _, _ in }
        ))
    }

    private func propertyStripCapture() -> ScreenshotCapture {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 64, height: 64)
        return ScreenshotCapture(
            id: "property-strip-fixture",
            image: image,
            pixelSize: CGSize(width: 64, height: 64),
            sourceRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            kind: .region,
            displayScope: nil,
            sourceSummary: "property strip fixture",
            editingContext: ScreenshotEditingContext(
                sourceContext: ScreenshotSourceContext(
                    sourceBounds: bounds,
                    tileDescriptors: [ScreenshotSourceTileDescriptor(id: "display-1", bounds: bounds)],
                    compositeSource: cgImage
                ),
                sourceFrame: CGRect(x: 0, y: 0, width: 64, height: 64),
                screens: [ScreenshotEditingScreen(
                    displayID: 1,
                    frame: CGRect(x: 0, y: 0, width: 64, height: 64)
                )],
                initialCropRect: bounds,
                supportsRangeExpansion: true
            )
        )
    }

    private func accessibilityStrings(in view: NSView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: Any, depth: Int) -> [String] {
            guard depth < 32, let node = object as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(node as AnyObject)).inserted else { return [] }
            let label = node.accessibilityLabel().map { [$0] } ?? []
            let value = (node.accessibilityValue() as? String).map { [$0] } ?? []
            // SwiftUI exposes virtual AX children; they are not NSView.subviews.
            let children = (node.accessibilityChildren() ?? [])
                + ((object as? NSView)?.subviews ?? [])
            return label + value + children.flatMap { collect($0, depth: depth + 1) }
        }
        return collect(view, depth: 0)
    }
}
