import SwiftUI

enum ClipboardFilterBarLayout {
    static let tagGroupLeadingSpacing: CGFloat = 12
    static let tagTextFontSize: CGFloat = 12
    static let tagIconSize: CGFloat = 8
    static let chipMinHeight: CGFloat = 24
    static let fixedFilterGroupHeight: CGFloat = 28
    static let islandVerticalPadding: CGFloat = 3
    static let islandIconSize: CGFloat = 13
    static let islandTextSize: CGFloat = 12
    static let clearSlotWidth: CGFloat = 20
    static let filterHitHeight: CGFloat = 34
    static let filterHitHorizontalPadding: CGFloat = 2
    static let tagDropIndicatorHitWidth: CGFloat = 14
    static let tagBlankCreateTargetMinWidth: CGFloat = 120
    static let tagDragActivationDistance: CGFloat = 3

    static func filterGroupFixedWidth(for group: ClipboardFilterGroup) -> CGFloat {
        switch group {
        case .format:
            return 96
        case .time:
            return 104
        case .source:
            return 128
        }
    }

    static func sideFilterGroupFixedWidth(for group: ClipboardFilterGroup, showsIcon: Bool) -> CGFloat {
        switch group {
        case .format:
            return showsIcon ? 60 : 44
        case .time:
            return showsIcon ? 60 : 44
        case .source:
            return showsIcon ? 68 : 52
        }
    }
}
