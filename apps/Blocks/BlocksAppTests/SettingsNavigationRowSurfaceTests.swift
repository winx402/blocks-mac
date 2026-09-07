import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class SettingsNavigationRowSurfaceTests: XCTestCase {
    func testHostingViewNavigationRowFillsSectionWithoutMovingTheTitle() {
        for width: CGFloat in [820, 980, 1_440] {
            let capture = SettingsNavigationGeometryCapture()
            let window = makeWindow(
                width: width,
                height: 180,
                rootView: SettingsSection(title: "Navigation section") {
                    SettingsNavigationRow(
                        title: "Manage items",
                        detail: "Opens the secondary page.",
                        value: "3"
                    ) {}
                }
                .frame(width: width, alignment: .top)
                .settingsGeometryProbeReporter { identifier, frame in
                    capture.frames[identifier] = frame
                }
                .blocksInteractionGeometryProbeReporter { identifier, frame in
                    capture.frames[identifier] = frame
                }
            )
            defer { close(window) }

            layout(window)

            guard
                let sectionSurface = capture.frames["section.surface.Navigation section"],
                let navigationSurface = capture.frames["navigation.surface.Manage items"],
                let sectionTitle = capture.frames["section.Navigation section"],
                let navigationTitle = capture.frames["row.Manage items"]
            else {
                return XCTFail("Expected NSHostingView navigation geometry at \(width)pt")
            }

            XCTAssertEqual(navigationSurface.minX, sectionSurface.minX, accuracy: 1)
            XCTAssertEqual(navigationSurface.maxX, sectionSurface.maxX, accuracy: 1)
            XCTAssertEqual(navigationSurface.minY, sectionSurface.minY, accuracy: 1)
            XCTAssertEqual(navigationSurface.maxY, sectionSurface.maxY, accuracy: 1)
            XCTAssertEqual(navigationTitle.minX, sectionTitle.minX, accuracy: 1)
        }
    }

    func testHostingViewMultiRowNavigationSurfacesShareTheSectionEdges() {
        let capture = SettingsNavigationGeometryCapture()
        let window = makeWindow(
            width: 980,
            height: 250,
            rootView: SettingsSection(title: "Navigation section") {
                SettingsNavigationRow(title: "First", detail: nil, sectionPosition: .first) {}
                SettingsRowDivider()
                SettingsNavigationRow(title: "Last", detail: nil, sectionPosition: .last) {}
            }
            .frame(width: 980, alignment: .top)
            .settingsGeometryProbeReporter { identifier, frame in
                capture.frames[identifier] = frame
            }
            .blocksInteractionGeometryProbeReporter { identifier, frame in
                capture.frames[identifier] = frame
            }
        )
        defer { close(window) }

        layout(window)

        guard
            let sectionSurface = capture.frames["section.surface.Navigation section"],
            let firstSurface = capture.frames["navigation.surface.First"],
            let lastSurface = capture.frames["navigation.surface.Last"]
        else {
            return XCTFail("Expected NSHostingView multi-row navigation geometry")
        }

        for surface in [firstSurface, lastSurface] {
            XCTAssertEqual(surface.minX, sectionSurface.minX, accuracy: 1)
            XCTAssertEqual(surface.maxX, sectionSurface.maxX, accuracy: 1)
        }
        XCTAssertFalse(firstSurface.intersects(lastSurface))
    }

    private func makeWindow<Content: View>(
        width: CGFloat,
        height: CGFloat,
        rootView: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: rootView)
        window.contentView = hostingView
        hostingView.frame = window.contentView!.bounds
        window.orderFront(nil)
        return window
    }

    private func layout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
private final class SettingsNavigationGeometryCapture {
    var frames: [String: CGRect] = [:]
}
