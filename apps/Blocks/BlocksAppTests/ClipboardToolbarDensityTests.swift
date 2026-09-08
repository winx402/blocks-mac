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

    func testFilterWidthsFitLocalizedLabelAndReserveClearActionWithoutPerGroupSlack() {
        for group in ClipboardFilterGroup.nonTagCases {
            let labelWidth = ClipboardFilterBarLayout.filterLabelWidth(for: group)
            let expected = ceil(labelWidth) + ClipboardFilterBarLayout.islandIconSize
                + ClipboardFilterBarLayout.clearSlotWidth
                + ClipboardFilterBarLayout.islandContentSpacing * 2
                + ClipboardFilterBarLayout.islandHorizontalPadding * 2
            XCTAssertEqual(ClipboardFilterBarLayout.filterGroupFixedWidth(for: group), expected)
            XCTAssertEqual(
                ClipboardFilterBarLayout.sideFilterGroupFixedWidth(for: group, showsIcon: false),
                expected - ClipboardFilterBarLayout.islandIconSize - ClipboardFilterBarLayout.islandContentSpacing
            )
            let hosting = NSHostingView(rootView: ClipboardFilterIslandButton(
                group: group, activeTitle: nil, isExpanded: false, hasActiveFilter: false,
                reservesClearSlot: true, showsIcon: true
            ).frame(width: expected))
            hosting.frame = NSRect(x: 0, y: 0, width: expected, height: ClipboardPanelToolbarLayout.filterRowHeight)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, ClipboardPanelToolbarLayout.filterRowHeight)
        }
    }

    func testFixedFiltersBudgetTheirLongestKnownValueBeforeSelection() {
        for (group, titles) in [
            (ClipboardFilterGroup.format, ClipboardFormatFilter.allCases.map(\.localizedTitle)),
            (.time, ClipboardTimeFilter.allCases.map(\.localizedTitle)),
        ] {
            for title in titles {
                let width = (title as NSString).size(withAttributes: [
                    .font: BlocksTypography.nsFont(size: BlocksVisualTokens.Typography.body, weight: .semibold),
                ]).width
                XCTAssertGreaterThanOrEqual(ClipboardFilterBarLayout.filterLabelWidth(for: group), width)
            }
        }
    }
}
