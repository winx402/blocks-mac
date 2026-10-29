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
    static let menuIndicatorWidth: CGFloat = 8
    static let filterHitHeight: CGFloat = 34
    static let filterHitHorizontalPadding: CGFloat = 0
    static let tagDropIndicatorHitWidth: CGFloat = 14
    static let tagDragActivationDistance: CGFloat = 3

    static func filterGroupFixedWidth(for group: ClipboardFilterGroup) -> CGFloat {
        // Budget only the short group label. Long selected values truncate,
        // with their complete value retained in native help/accessibility.
        // The default menu occupies the entire width; an active filter splits
        // off its clear action without moving any neighbouring controls.
        return filterLabelWidth(for: group) + islandIconSize + clearSlotWidth
            + menuIndicatorWidth + islandContentSpacing * 2 + islandHorizontalPadding * 2
    }

    static func filterLabelWidth(for group: ClipboardFilterGroup) -> CGFloat {
        let width = (group.localizedTitle as NSString).size(withAttributes: [
            .font: BlocksTypography.nsFont(size: islandTextSize, weight: .semibold),
        ]).width
        return ceil(min(max(width, islandTextSize * 2), islandTextSize * 5))
    }

    static func menuWidth(groupWidth: CGFloat, hasActiveFilter: Bool) -> CGFloat {
        groupWidth - (hasActiveFilter ? clearSlotWidth : 0)
    }

    static func sideFilterGroupFixedWidth(for group: ClipboardFilterGroup, showsIcon: Bool) -> CGFloat {
        filterGroupFixedWidth(for: group)
            - (showsIcon ? 0 : islandIconSize + islandContentSpacing)
    }
}

enum ClipboardTagCreateTargetViewportLayout {
    /// Returns the unoccupied portion of a tag filter viewport. This target is
    /// deliberately an overlay rather than scroll content: adding a flexible
    /// empty view to the chip HStack makes that empty space horizontally
    /// scrollable once the chips overflow.
    static func frame(
        viewportWidth: CGFloat,
        scrollContentWidth: CGFloat,
        tagChipsTrailingX: CGFloat
    ) -> CGRect? {
        guard viewportWidth.isFinite,
              scrollContentWidth.isFinite,
              tagChipsTrailingX.isFinite,
              viewportWidth > 0,
              scrollContentWidth > 0,
              scrollContentWidth <= viewportWidth,
              tagChipsTrailingX > 0,
              tagChipsTrailingX < viewportWidth else {
            return nil
        }

        return CGRect(
            x: tagChipsTrailingX,
            y: 0,
            width: viewportWidth - tagChipsTrailingX,
            height: ClipboardFilterBarLayout.chipMinHeight
        )
    }
}
