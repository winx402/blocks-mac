import AppKit
import SwiftUI
import XCTest
@testable import Blocks

@MainActor
final class ClipboardToolbarDensityTests: XCTestCase {
    func testToolbarLabelsUseSharedBodyTypographyAndCompactSpacing() {
        XCTAssertEqual(ClipboardFilterBarLayout.islandTextSize, BlocksVisualTokens.Typography.body)
        XCTAssertEqual(ClipboardFilterBarLayout.tagTextFontSize, BlocksVisualTokens.Typography.body)
        XCTAssertEqual(ClipboardFilterBarLayout.tagGroupLeadingSpacing, BlocksVisualTokens.Spacing.xs)
        XCTAssertEqual(ClipboardFilterBarLayout.islandContentSpacing, BlocksVisualTokens.Spacing.xs)
    }

    func testFilterWidthsUseBoundedGroupLabelsAndStableTotalWidth() {
        for group in ClipboardFilterGroup.nonTagCases {
            let labelWidth = ClipboardFilterBarLayout.filterLabelWidth(for: group)
            let expected = ceil(labelWidth) + ClipboardFilterBarLayout.islandIconSize
                + ClipboardFilterBarLayout.clearSlotWidth
                + ClipboardFilterBarLayout.menuIndicatorWidth
                + ClipboardFilterBarLayout.islandContentSpacing * 2
                + ClipboardFilterBarLayout.islandHorizontalPadding * 2
            XCTAssertEqual(ClipboardFilterBarLayout.filterGroupFixedWidth(for: group), expected)
            XCTAssertEqual(
                ClipboardFilterBarLayout.sideFilterGroupFixedWidth(for: group, showsIcon: false),
                expected - ClipboardFilterBarLayout.islandIconSize - ClipboardFilterBarLayout.islandContentSpacing
            )
            let hosting = NSHostingView(rootView: ClipboardFilterIslandButton(
                group: group, activeTitle: nil, isExpanded: false, hasActiveFilter: false,
                reservesClearSlot: false, showsIcon: true
            ).frame(width: expected))
            hosting.frame = NSRect(x: 0, y: 0, width: expected, height: ClipboardPanelToolbarLayout.filterRowHeight)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, ClipboardPanelToolbarLayout.filterRowHeight)
        }
    }

    func testLongCandidateTitlesDoNotIncreaseTheCollapsedControlBudget() {
        for group in ClipboardFilterGroup.nonTagCases {
            let labelWidth = ClipboardFilterBarLayout.filterLabelWidth(for: group)
            XCTAssertGreaterThanOrEqual(labelWidth, ClipboardFilterBarLayout.islandTextSize * 2)
            XCTAssertLessThanOrEqual(labelWidth, ClipboardFilterBarLayout.islandTextSize * 5)
            let total = ClipboardFilterBarLayout.filterGroupFixedWidth(for: group)
            XCTAssertEqual(ClipboardFilterBarLayout.menuWidth(groupWidth: total, hasActiveFilter: false), total)
            XCTAssertEqual(
                ClipboardFilterBarLayout.menuWidth(groupWidth: total, hasActiveFilter: true)
                    + ClipboardFilterBarLayout.clearSlotWidth,
                total,
                "clear is carved out only when active; neighbours remain fixed"
            )
        }
    }
}
