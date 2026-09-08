import AppKit
import SwiftUI

enum ClipboardFilterBarLayout {
    static let tagGroupLeadingSpacing = BlocksVisualTokens.Spacing.xs
    static let tagTextFontSize = BlocksVisualTokens.Typography.body
    static let tagIconSize: CGFloat = 8
    static let chipMinHeight: CGFloat = 24
    static let fixedFilterGroupHeight: CGFloat = 28
    static let islandVerticalPadding: CGFloat = 3
    static let islandIconSize = BlocksVisualTokens.Control.compactIconSize
    static let islandTextSize = BlocksVisualTokens.Typography.body
    static let islandContentSpacing = BlocksVisualTokens.Spacing.xs
    static let islandHorizontalPadding = BlocksVisualTokens.Spacing.sm
    static let clearSlotWidth: CGFloat = 20
    static let filterHitHeight: CGFloat = 34
    static let filterHitHorizontalPadding: CGFloat = 2
    static let tagDropIndicatorHitWidth: CGFloat = 14
    static let tagBlankCreateTargetMinWidth: CGFloat = 120
    static let tagDragActivationDistance: CGFloat = 3

    static func filterGroupFixedWidth(for group: ClipboardFilterGroup) -> CGFloat {
        // Resolve once from the localized group label, not the selected value:
        // changing a filter never pushes adjacent controls around. Every group
        // retains its clear-action slot without arbitrary per-group whitespace.
        return filterLabelWidth(for: group) + islandIconSize + clearSlotWidth
            + islandContentSpacing * 2 + islandHorizontalPadding * 2
    }

    static func filterLabelWidth(for group: ClipboardFilterGroup) -> CGFloat {
        let values: [String]
        switch group {
        case .format: values = ClipboardFormatFilter.allCases.map(\.localizedTitle)
        case .time: values = ClipboardTimeFilter.allCases.map(\.localizedTitle)
        case .source: values = []
        }
        let width = ([group.localizedTitle] + values).map { title in
            (title as NSString).size(withAttributes: [
                .font: BlocksTypography.nsFont(size: islandTextSize, weight: .semibold),
            ]).width
        }.max() ?? 0
        // App names are unbounded; reserve a compact four-em label and retain
        // the full source name through the existing tooltip/AX value.
        return ceil(max(width, group == .source ? islandTextSize * 4 : 0))
    }

    static func sideFilterGroupFixedWidth(for group: ClipboardFilterGroup, showsIcon: Bool) -> CGFloat {
        filterGroupFixedWidth(for: group)
            - (showsIcon ? 0 : islandIconSize + islandContentSpacing)
    }
}
