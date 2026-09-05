import CoreGraphics
import Foundation

enum ClipboardPanelSettings {
    enum Keys {
        static let rememberSearch = "clipboard.filter.rememberSearch"
        static let lastSearch = "clipboard.filter.lastSearch"
        static let showActiveFilterLabels = "clipboard.filter.showActiveLabels"
        static let bottomCardWidth = "clipboard.panel.bottom.cardWidth"
        static let filterClearDelay = "clipboard.filter.clearDelay"
        static let itemFontSize = "clipboard.panel.itemFontSize"
        static let sideRowHeight = "clipboard.panel.side.rowHeight"
    }

    static let defaultItemFontSize: CGFloat = 12
    static let minItemFontSize: CGFloat = 10
    static let maxItemFontSize: CGFloat = 18

    static func clampItemFontSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else {
            return defaultItemFontSize
        }
        return min(max(size, minItemFontSize), maxItemFontSize)
    }
}

enum ClipboardBottomTrayLayout {
    static let bottomTrayMinHeight: CGFloat = 126
    static let bottomCardMinHeight: CGFloat = 118
    static let bottomCardMaxHeight: CGFloat = 330
    static let defaultBottomCardWidth: CGFloat = 270
    static let bottomCardMinWidth: CGFloat = 180
    static let bottomCardMaxWidth: CGFloat = 520
    // The resize surface lives entirely in the shared inter-card gap. Keeping
    // its width tied to that token prevents it from stealing pointer events
    // from either adjacent record card.
    static let cardWidthResizeHitWidth = BlocksVisualTokens.Spacing.sm
    static let topPadding: CGFloat = 5
    static let bottomPadding: CGFloat = 2

    static func clampCardWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else {
            return defaultBottomCardWidth
        }
        return min(max(width, bottomCardMinWidth), bottomCardMaxWidth)
    }
}

enum ClipboardSideListLayout {
    static let defaultRowHeight: CGFloat = 96
    static let minRowHeight: CGFloat = 76
    static let maxRowHeight: CGFloat = 160
    static let rowHeightResizeHitHeight: CGFloat = 8

    static func clampRowHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else {
            return defaultRowHeight
        }
        return min(max(height, minRowHeight), maxRowHeight)
    }
}
