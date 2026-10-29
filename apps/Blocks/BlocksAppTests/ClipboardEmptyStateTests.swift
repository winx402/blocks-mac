import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class ClipboardEmptyStateTests: XCTestCase {
    func testHostedEmptyStateCentersActualContentInRemainingRecordViewport() throws {
        let sizes: [(FloatingPanelPosition, CGSize)] = [
            (.bottom, CGSize(width: 640, height: 204)), // 112pt record viewport
            (.bottom, CGSize(width: 1_280, height: 430)),
            (.left, CGSize(width: 240, height: 360)),
            (.left, CGSize(width: 360, height: 700)),
            (.right, CGSize(width: 240, height: 360)),
            (.right, CGSize(width: 360, height: 700)),
        ]
        let presentations = [
            ClipboardSearchStatusPresentation(title: "没有匹配的记录", detail: "试试调整或清除筛选", systemImage: "tray"),
            ClipboardSearchStatusPresentation(title: "No matching records", detail: "Adjust or clear filters.", systemImage: "tray"),
            ClipboardSearchStatusPresentation(title: "一致する履歴がありません", detail: "フィルターを変更または解除", systemImage: "tray"),
        ]

        for (position, size) in sizes {
            for presentation in presentations {
                for scheme in [ColorScheme.light, .dark] {
                    let capture = ClipboardEmptyStateGeometryCapture()
                    var actionCount = 0
                    let window = makeWindow(
                        position: position, size: size, presentation: presentation,
                        scheme: scheme, capture: capture, onClearFilters: { actionCount += 1 }
                    )
                    defer { close(window) }
                    layout(window)

                    let viewport = try XCTUnwrap(capture.frames["clipboard.empty.viewport"])
                    let content = try XCTUnwrap(capture.frames["clipboard.empty.content"])
                    let header = try XCTUnwrap(capture.frames["clipboard.empty.testHeader"])
                    XCTAssertGreaterThan(viewport.height, 0)
                    XCTAssertLessThanOrEqual(viewport.maxY, header.minY - 8 + 1)
                    XCTAssertEqual(content.midX, viewport.midX, accuracy: 1)
                    XCTAssertEqual(content.midY, viewport.midY, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(content.minY, viewport.minY - 1)
                    XCTAssertLessThanOrEqual(content.maxY, viewport.maxY + 1)

                    // Checking the title/icon themselves catches the old row's
                    // trailing Spacer, even if its outer frame was centered.
                    for part in ["icon", "title", "detail", "action"] {
                        let frame = try XCTUnwrap(capture.frames["clipboard.empty.\(part)"])
                        XCTAssertEqual(frame.midX, viewport.midX, accuracy: 1, part)
                        XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, part)
                        XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, part)
                    }
                    XCTAssertEqual(actionCount, 0, "Layout must not clear filters automatically")
                }
            }
        }
    }

    func testLongDescriptionWrapsWithoutTruncatingOrOverflowingHorizontally() throws {
        let detail = String(repeating: "Adjust the selected filters to show more clipboard records. ", count: 12)
        let presentation = ClipboardSearchStatusPresentation(title: "No matching records", detail: detail, systemImage: "tray")
        var detailHeights: [CGFloat] = []
        for height: CGFloat in [204, 1_600] {
            let capture = ClipboardEmptyStateGeometryCapture()
            let window = makeWindow(
                position: .bottom, size: CGSize(width: 300, height: height),
                presentation: presentation, scheme: .light, capture: capture,
                onClearFilters: {}
            )
            defer { close(window) }
            layout(window)

            let viewport = try XCTUnwrap(capture.frames["clipboard.empty.viewport"])
            let detailFrame = try XCTUnwrap(capture.frames["clipboard.empty.detail"])
            let content = try XCTUnwrap(capture.frames["clipboard.empty.content"])
            detailHeights.append(detailFrame.height)
            XCTAssertGreaterThanOrEqual(detailFrame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(detailFrame.maxX, viewport.maxX)
            XCTAssertGreaterThan(detailFrame.height, 100)
            if height == 204 {
                XCTAssertGreaterThan(content.height, viewport.height)
            } else {
                XCTAssertEqual(content.midY, viewport.midY, accuracy: 1)
            }
        }
        XCTAssertEqual(detailHeights[0], detailHeights[1], accuracy: 1)
    }

    func testHistoryEmptyAndFailurePresentationsDoNotInventAFilterAction() throws {
        for image in ["tray", "externaldrive.badge.exclamationmark", "clock.badge.questionmark"] {
            let capture = ClipboardEmptyStateGeometryCapture()
            let window = makeWindow(
                position: .right, size: CGSize(width: 280, height: 360),
                presentation: ClipboardSearchStatusPresentation(title: "Status", detail: "Status detail", systemImage: image),
                scheme: .dark, capture: capture, onClearFilters: nil
            )
            defer { close(window) }
            layout(window)
            XCTAssertNotNil(capture.frames["clipboard.empty.title"])
            XCTAssertNil(capture.frames["clipboard.empty.action"])
        }
    }

    private func makeWindow(
        position: FloatingPanelPosition,
        size: CGSize,
        presentation: ClipboardSearchStatusPresentation,
        scheme: ColorScheme,
        capture: ClipboardEmptyStateGeometryCapture,
        onClearFilters: (() -> Void)?
    ) -> NSWindow {
        let root = ClipboardPanelLayout(
            values: ClipboardPanelLayoutValues(
                position: position, emptyStatePresentation: presentation,
                records: [], bottomRecordCardWidth: 270, itemFontSize: 13,
                sideRowHeight: 100, hoveredSideRowHeightResizeHandleID: nil
            ),
            actions: ClipboardPanelLayoutActions(
                onBottomCardWidthChanged: { _ in },
                onSideRowHeightResizeChanged: { _, _, _ in },
                onSideRowHeightResizeEnded: { _, _, _ in },
                onSideRowHeightResizeHoverChanged: { _, _ in },
                onClearFilters: onClearFilters
            ),
            header: Color.clear.frame(height: 64)
                .blocksInteractionGeometryProbe("clipboard.empty.testHeader"),
            bottomRecordBuilder: { _, _, _, _ in EmptyView() },
            sideRecordBuilder: { _, _, _, _ in EmptyView() }
        )
        .environment(\.colorScheme, scheme)
        .blocksInteractionGeometryProbeReporter { identifier, frame in
            capture.frames[identifier] = frame
        }
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        return window
    }

    private func layout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class ClipboardEmptyStateGeometryCapture {
    var frames: [String: CGRect] = [:]
}
