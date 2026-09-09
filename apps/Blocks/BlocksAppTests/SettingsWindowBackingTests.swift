import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class SettingsWindowBackingTests: XCTestCase {
    func testSingleBackingSpansTitlebarAndDetailWithoutRemovingForegroundSafeArea() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [820, 980, 1_440] {
                let window = makeWindow(width: width, appearance: appearance)
                defer { close(window) }
                try assertBackingGeometry(window)
            }
        }
    }

    func testBackingResizesWithWindowAndDoesNotMultiplyWhenAppearanceChanges() throws {
        let window = makeWindow(width: 980, appearance: .aqua)
        defer { close(window) }
        for width: CGFloat in [820, 1_440, 980] {
            window.setContentSize(NSSize(width: width, height: 680))
            window.appearance = NSAppearance(named: .darkAqua)
            try assertBackingGeometry(window)
            window.appearance = NSAppearance(named: .aqua)
            try assertBackingGeometry(window)
        }
    }

    private func assertBackingGeometry(_ window: NSWindow) throws {
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "Material-view geometry requires transparency; opaque fallback needs separate visual acceptance"
        )
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        root.layoutSubtreeIfNeeded()

        let surfaces = descendants(root).compactMap { $0 as? BlocksAppKitGlassSurfaceView }
        let contentSurfaces = surfaces.filter { $0.blocksSurfaceConfiguration.role == .content }
        XCTAssertEqual(contentSurfaces.count, 1, "Titlebar and detail must share one backing")
        let backing = try XCTUnwrap(contentSurfaces.first)
        let backingFrame = backing.convert(backing.bounds, to: root)
        XCTAssertEqual(backingFrame.minX, root.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(backingFrame.minY, root.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(backingFrame.width, root.bounds.width, accuracy: 0.5)
        XCTAssertEqual(backingFrame.height, root.bounds.height, accuracy: 0.5)
        XCTAssertGreaterThan(root.safeAreaInsets.top, 0, "Foreground still respects native titlebar")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(backing.blocksSurfaceConfiguration.cornerRadius, 0)
        XCTAssertEqual(surfaces.filter { $0.blocksSurfaceConfiguration.role == .sidebar }.count, 1)
        XCTAssertEqual(BlocksSurfaceRole.sidebar.appKitMaterial, .sidebar)

        let marker = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "settings.backing.foreground" })
        let markerFrame = marker.convert(marker.bounds, to: root)
        XCTAssertGreaterThanOrEqual(markerFrame.minY, root.safeAreaInsets.top - 0.5)
    }

    private func makeWindow(width: CGFloat, appearance: NSAppearance.Name) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: width, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(rootView: SettingsBackingFixture())
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct SettingsBackingFixture: View {
    var body: some View {
        NavigationSplitView {
            Text("Sidebar")
                .blocksBackground(.sidebar)
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 248)
        } detail: {
            ScrollView {
                SettingsBackingForegroundMarker()
                    .frame(height: 24)
                Color.clear.frame(height: 1_000)
            }
            .navigationTitle("Settings")
            .modifier(BlocksSettingsDetailBacking())
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(BlocksSettingsWindowBacking())
    }
}

private struct SettingsBackingForegroundMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("settings.backing.foreground")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
