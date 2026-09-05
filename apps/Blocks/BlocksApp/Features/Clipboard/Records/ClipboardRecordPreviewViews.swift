import AppKit
import BlocksCore
import SwiftUI

enum ClipboardRecordDensityMetrics {
    static let rowMinHeight: CGFloat = 86
    static let rowHorizontalPadding: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 8
    static let metadataSlotHeight: CGFloat = 14
    static let statusSlotMinWidth: CGFloat = 54
    static let cardContentPadding: CGFloat = 8
    static let cardVerticalPadding: CGFloat = 6
    static let cardHeaderSlotHeight: CGFloat = 16
    static let cardFooterSlotHeight: CGFloat = 14
    static let cardContentSpacing: CGFloat = 3

    static func cardTextContentHeight(totalHeight: CGFloat) -> CGFloat {
        max(
            12,
            totalHeight
                - cardVerticalPadding * 2
                - cardHeaderSlotHeight
                - cardFooterSlotHeight
                - cardContentSpacing * 2
        )
    }

    static func sideRowContentHeight(totalHeight: CGFloat) -> CGFloat {
        cardTextContentHeight(totalHeight: totalHeight)
    }
}

enum ClipboardCardForegroundContext: Equatable {
    case content
    case imageOverlay

    func color(opacity: CGFloat) -> Color {
        switch self {
        case .content:
            Color.primary.opacity(opacity)
        case .imageOverlay:
            Color.white.opacity(opacity)
        }
    }
}

struct ClipboardCardMetaLabel: View {
    let text: String
    let size: CGFloat
    let weight: BlocksTypographyWeight
    let opacity: CGFloat
    var foregroundContext: ClipboardCardForegroundContext = .content

    var body: some View {
        Text(text)
            .blocksFont(size: size, weight: weight)
            .foregroundStyle(foregroundContext.color(opacity: opacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(text)
    }
}

private extension ClipboardRecorderItemKind {
    var formatFilterIcon: String {
        ClipboardFormatFilter(recordKind: self).systemImage
    }
}

struct ClipboardRecordFormatIcon: View {
    let recordKind: ClipboardRecorderItemKind
    let size: CGFloat
    var foregroundContext: ClipboardCardForegroundContext = .content

    var body: some View {
        Image(systemName: recordKind.formatFilterIcon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(foregroundContext.color(opacity: 0.62))
            .frame(width: size + 3, height: size + 3)
            .accessibilityHidden(true)
    }
}

struct ClipboardDirectContentPreview: View {
    let record: ClipboardRecorderRecord
    let preview: ClipboardRecordPreview
    let lineLimit: Int
    let itemFontSize: CGFloat

    var body: some View {
        Group {
            if case let image? = preview.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ClipboardPreviewText(
                    text: preview.body,
                    lineLimit: lineLimit,
                    fontSize: itemFontSize,
                    preserveSourceFont: record.kind == .richText
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
    }

}

private struct ClipboardPreviewText: NSViewRepresentable {
    let text: String
    let lineLimit: Int
    let fontSize: CGFloat
    let preserveSourceFont: Bool

    func makeNSView(context: Context) -> ClipboardPreviewTextField {
        let textField = ClipboardPreviewTextField(labelWithString: "")
        textField.cell = ClipboardPreviewTextCell(textCell: "")
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.alignment = .left
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = max(1, lineLimit)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)

        if let cell = textField.cell {
            cell.wraps = true
            cell.isScrollable = false
            cell.lineBreakMode = .byWordWrapping
            cell.usesSingleLineMode = false
            cell.truncatesLastVisibleLine = false
        }

        return textField
    }

    func updateNSView(_ textField: ClipboardPreviewTextField, context: Context) {
        let lineBreakMode = preferredLineBreakMode(for: text)
        let font = preserveSourceFont ? NSFont.systemFont(ofSize: fontSize) : BlocksTypography.nsFont(size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        if lineBreakMode == .byCharWrapping {
            paragraphStyle.lineBreakMode = .byCharWrapping
        } else {
            paragraphStyle.lineBreakMode = .byWordWrapping
        }

        textField.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        textField.textColor = NSColor.labelColor
        textField.alignment = .left
        if lineBreakMode == .byCharWrapping {
            textField.lineBreakMode = .byCharWrapping
        } else {
            textField.lineBreakMode = .byWordWrapping
        }
        textField.maximumNumberOfLines = max(1, lineLimit)
        textField.preferredMaxLayoutWidth = textField.bounds.width

        if let cell = textField.cell {
            cell.wraps = true
            cell.isScrollable = false
            if lineBreakMode == .byCharWrapping {
                cell.lineBreakMode = .byCharWrapping
            } else {
                cell.lineBreakMode = .byWordWrapping
            }
            cell.usesSingleLineMode = false
            cell.truncatesLastVisibleLine = false
        }
    }

    private func preferredLineBreakMode(for text: String) -> NSLineBreakMode {
        requiresCharacterFallback(for: text) ? .byCharWrapping : .byWordWrapping
    }

    private func requiresCharacterFallback(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed.contains("://") || trimmed.contains("/") || trimmed.contains("\\") {
            return true
        }
        let longestTokenLength = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(\.count)
            .max() ?? 0
        return longestTokenLength >= 28
    }
}

private final class ClipboardPreviewTextField: NSTextField {
    override func layout() {
        super.layout()
        preferredMaxLayoutWidth = bounds.width
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private final class ClipboardPreviewTextCell: NSTextFieldCell {
    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        bounds
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        rect
    }
}
