import AppKit
import BlocksCore
import SwiftUI

struct ClipboardFloatingRecordRow: View {
    @State private var isHovered = false

    let record: ClipboardRecorderRecord
    let preview: ClipboardRecordPreview
    let ocrState: ClipboardOCRState
    let tagStore: ClipboardTagStore
    let isSelected: Bool
    let isFocused: Bool
    let isDetailPresented: Bool
    let rowHeight: CGFloat
    let bodyLineLimit: Int
    let itemFontSize: CGFloat
    let quickPasteIndex: Int?
    let accessibilitySortPriority: Double
    let panelSessionID: UUID?
    let pluginBadge: AnyView?
    let pluginContextActions: AnyView?
    let onPointerPress: () -> Void
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onPaste: () -> Void
    let onTranslate: () -> Void
    let onRetryOCR: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleTag: (String) -> Void
    let onCreateTag: (String) -> Void
    let onCopyPlainText: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = preview.image {
                    sideImageRowContent(image)
                } else {
                    sideTextRowContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: rowHeight, alignment: .topLeading)
            .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.control,
                isActive: interactionState != .idle
            )
            .blocksInteractionChrome(interactionState)
        }
        .overlay {
            ClipboardRecordPointerSurface(
                panelSessionID: panelSessionID,
                recordID: record.id,
                source: .sideRow,
                onPointerPress: onPointerPress,
                onSingleClick: onSingleClick,
                onDoubleClick: onDoubleClick
            )
            .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottomTrailing) {
            if let quickPasteIndex {
                ClipboardQuickPasteNumberBadge(index: quickPasteIndex)
                    .padding(.trailing, 8)
                    .padding(.bottom, 7)
            }
        }
        .contentShape(Rectangle())
        .anchorPreference(key: ClipboardRecordFramePreferenceKey.self, value: .bounds) { anchor in
            ClipboardRecordFramePublicationPolicy.shouldPublishFrame(
                isDetailPresented: isDetailPresented
            ) ? [record.id: anchor] : [:]
        }
        .accessibilityElement(children: .ignore)
        .accessibilitySortPriority(accessibilitySortPriority)
        .accessibilityLabel(clipboardRecordAccessibilityLabel(preview: preview))
        .accessibilityValue(
            clipboardRecordAccessibilityValue(
                record: record,
                preview: preview,
                isDetailPresented: isDetailPresented,
                quickPasteIndex: quickPasteIndex
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            onSingleClick()
        }
        .accessibilityAction(named: Text(L10n.string("clipboard.panel.detailTitle"))) {
            onSingleClick()
        }
        .accessibilityAction(named: Text(L10n.string("clipboard.context.paste"))) {
            performAccessiblePasteAction()
        }
        .accessibilityAction(named: Text(
            tagStore.isFavorite(recordID: record.id)
                ? L10n.string("clipboard.tags.unfavorite")
                : L10n.string("clipboard.tags.favorite")
        )) {
            onToggleFavorite()
        }
        .contextMenu {
            ClipboardRecordContextMenu(
                record: record,
                ocrState: ocrState,
                tagStore: tagStore,
                onPaste: onPaste,
                onTranslate: onTranslate,
                onRetryOCR: onRetryOCR,
                onToggleFavorite: onToggleFavorite,
                onToggleTag: onToggleTag,
                onCreateTag: onCreateTag,
                onCopyPlainText: onCopyPlainText,
                onRemove: onRemove,
                pluginActions: pluginContextActions
            )
        }
        .blocksAnimation(.hoverFocus, value: interactionState)
    }

    private func performAccessiblePasteAction() {
        let pasteAction = onPaste
        pasteAction()
    }

    private var sideTextRowContent: some View {
        GeometryReader { proxy in
            let contentHeight = ClipboardRecordDensityMetrics.sideRowContentHeight(totalHeight: proxy.size.height)

            VStack(alignment: .leading, spacing: ClipboardRecordDensityMetrics.cardContentSpacing) {
                sideRowHeader(foregroundContext: .content)
                    .frame(height: ClipboardRecordDensityMetrics.cardHeaderSlotHeight, alignment: .center)
                    .layoutPriority(2)

                ClipboardDirectContentPreview(
                    record: record,
                    preview: preview,
                    lineLimit: bodyLineLimit,
                    itemFontSize: itemFontSize
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(maxHeight: contentHeight, alignment: .topLeading)
                .frame(height: contentHeight, alignment: .topLeading)
                .layoutPriority(1)
                .clipped()

                sideRowFooter(foregroundContext: .content)
                    .frame(height: ClipboardRecordDensityMetrics.cardFooterSlotHeight, alignment: .leading)
                    .layoutPriority(2)
            }
            .padding(.horizontal, ClipboardRecordDensityMetrics.cardContentPadding)
            .padding(.vertical, ClipboardRecordDensityMetrics.cardVerticalPadding)
        }
    }

    private func sideImageRowContent(_ image: NSImage) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.48),
                        Color.black.opacity(0.06),
                        Color.black.opacity(0.44)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: ClipboardRecordDensityMetrics.cardContentSpacing) {
                    sideRowHeader(foregroundContext: .imageOverlay)
                        .frame(height: ClipboardRecordDensityMetrics.cardHeaderSlotHeight, alignment: .center)
                        .layoutPriority(2)
                    Spacer(minLength: 0)
                    sideRowFooter(foregroundContext: .imageOverlay)
                        .frame(height: ClipboardRecordDensityMetrics.cardFooterSlotHeight, alignment: .leading)
                        .layoutPriority(2)
                }
                .padding(.horizontal, ClipboardRecordDensityMetrics.cardContentPadding)
                .padding(.vertical, ClipboardRecordDensityMetrics.cardVerticalPadding)
            }
        }
    }

    private func sideRowHeader(
        foregroundContext: ClipboardCardForegroundContext
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ClipboardRecordFormatIcon(
                recordKind: record.kind,
                size: 9,
                foregroundContext: foregroundContext
            )

            ClipboardCardMetaLabel(
                text: preview.title,
                size: 11,
                weight: .semibold,
                opacity: foregroundContext == .imageOverlay ? 0.82 : 0.68,
                foregroundContext: foregroundContext
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            pluginBadge

            if record.excluded || record.snapshotSkipped {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(foregroundContext.color(opacity: 0.84))
            }

            if tagStore.isFavorite(recordID: record.id) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.95))
            }
        }
    }

    private func sideRowFooter(
        foregroundContext: ClipboardCardForegroundContext
    ) -> some View {
        HStack(spacing: 6) {
            ClipboardCardMetaLabel(
                text: record.lastCopiedAt.formatted(date: .omitted, time: .shortened),
                size: 10,
                weight: .medium,
                opacity: foregroundContext == .imageOverlay ? 0.72 : 0.54,
                foregroundContext: foregroundContext
            )
            Spacer(minLength: 0)
        }
        .frame(minHeight: ClipboardRecordDensityMetrics.metadataSlotHeight, alignment: .leading)
    }

    private var interactionState: BlocksInteractionState {
        ClipboardRecordInteractionState.resolve(
            isSelected: isSelected,
            isFocused: isFocused,
            isHovered: isHovered,
            isDetailPresented: isDetailPresented
        )
    }

}
