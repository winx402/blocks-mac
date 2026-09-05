import AppKit
import BlocksCore
import SwiftUI

enum ClipboardPanelActivationTrigger: String {
    case singleClick
    case doubleClick
    case keyboard
    case contextMenu
    case button
}

func clipboardRecordAccessibilityLabel(preview: ClipboardRecordPreview) -> String {
    let trimmedTitle = preview.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
        return trimmedTitle
    }

    let trimmedBody = preview.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else {
        return L10n.string("clipboard.preview.unknownTitle")
    }
    return String(trimmedBody.prefix(80))
}

func clipboardRecordAccessibilityValue(
    record: ClipboardRecorderRecord,
    preview: ClipboardRecordPreview,
    isDetailPresented: Bool,
    quickPasteIndex: Int?
) -> String {
    var components: [String] = []
    let trimmedBody = preview.body
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if !trimmedBody.isEmpty {
        components.append(String(trimmedBody.prefix(160)))
    }

    components.append(record.lastCopiedAt.formatted(date: .omitted, time: .shortened))

    if let quickPasteIndex {
        components.append(L10n.format("clipboard.quickPaste.numberHint", quickPasteIndex))
    }

    if isDetailPresented {
        components.append(L10n.string("clipboard.panel.detailTitle"))
    }

    return components.joined(separator: ", ")
}

enum ClipboardRecordInteractionState {
    static func resolve(
        isSelected: Bool,
        isFocused: Bool,
        isHovered: Bool,
        isDetailPresented: Bool
    ) -> BlocksInteractionState {
        if isDetailPresented || isSelected {
            return .selected
        }
        if isFocused {
            return .focused
        }
        if isHovered {
            return .hovered
        }
        return .idle
    }
}

struct ClipboardFloatingRecordCard: View {
    @State private var isHovered = false

    let record: ClipboardRecorderRecord
    let preview: ClipboardRecordPreview
    let ocrState: ClipboardOCRState
    let tagStore: ClipboardTagStore
    let isSelected: Bool
    let isFocused: Bool
    let isDetailPresented: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
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

    private let cardFavoriteActionReservedTrailingSpace: CGFloat = 22

    private var interactionState: BlocksInteractionState {
        ClipboardRecordInteractionState.resolve(
            isSelected: isSelected,
            isFocused: isFocused,
            isHovered: isHovered,
            isDetailPresented: isDetailPresented
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = preview.image {
                    imageCardContent(image)
                } else {
                    textCardContent
                }
            }
            .frame(
                width: cardWidth,
                height: cardHeight,
                alignment: .topLeading
            )
            .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.section,
                isActive: interactionState != .idle
            )
            .blocksInteractionChrome(
                interactionState,
                cornerRadius: BlocksVisualTokens.CornerRadius.section
            )
        }
        .overlay {
            ClipboardRecordPointerSurface(
                panelSessionID: panelSessionID,
                recordID: record.id,
                source: .bottomCard,
                onPointerPress: onPointerPress,
                onSingleClick: onSingleClick,
                onDoubleClick: onDoubleClick
            )
            .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
        .overlay(alignment: .topTrailing) {
            if isHovered || tagStore.isFavorite(recordID: record.id) {
                BlocksCompactIconButton(
                    systemImage: tagStore.isFavorite(recordID: record.id) ? "star.fill" : "star",
                    label: tagStore.isFavorite(recordID: record.id)
                        ? L10n.string("clipboard.tags.unfavorite")
                        : L10n.string("clipboard.tags.favorite"),
                    isSelected: tagStore.isFavorite(recordID: record.id),
                    emphasis: .accent,
                    density: .micro,
                    showsHelp: true,
                    action: onToggleFavorite
                )
                .accessibilityHidden(true)
                .padding(.top, 5)
                .padding(.trailing, 5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let quickPasteIndex {
                ClipboardQuickPasteNumberBadge(index: quickPasteIndex)
                    .padding(.trailing, 10)
                    .padding(.bottom, 9)
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

    private var textCardContent: some View {
        GeometryReader { proxy in
            let contentHeight = ClipboardRecordDensityMetrics.cardTextContentHeight(totalHeight: proxy.size.height)

            VStack(alignment: .leading, spacing: ClipboardRecordDensityMetrics.cardContentSpacing) {
                HStack(alignment: .center, spacing: 8) {
                    ClipboardRecordFormatIcon(recordKind: record.kind, size: 9)

                    ClipboardCardMetaLabel(
                        text: preview.title,
                        size: 11,
                        weight: .semibold,
                        opacity: 0.68
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    pluginBadge

                    if record.excluded || record.snapshotSkipped {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Color.clear
                        .frame(width: cardFavoriteActionReservedTrailingSpace, height: 1)
                        .accessibilityHidden(true)

                    Spacer(minLength: 0)
                }
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

                HStack(spacing: 6) {
                    ClipboardCardMetaLabel(
                        text: record.lastCopiedAt.formatted(date: .omitted, time: .shortened),
                        size: 10,
                        weight: .medium,
                        opacity: 0.54
                    )
                    Spacer(minLength: 0)
                }
                .frame(height: ClipboardRecordDensityMetrics.cardFooterSlotHeight, alignment: .leading)
                .layoutPriority(2)
            }
            .padding(.horizontal, ClipboardRecordDensityMetrics.cardContentPadding)
            .padding(.vertical, ClipboardRecordDensityMetrics.cardVerticalPadding)
        }
    }

    private func imageCardContent(_ image: NSImage) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.50),
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.46)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: ClipboardRecordDensityMetrics.cardContentSpacing) {
                HStack(alignment: .center, spacing: 8) {
                    ClipboardRecordFormatIcon(
                        recordKind: record.kind,
                        size: 9,
                        foregroundContext: .imageOverlay
                    )

                    ClipboardCardMetaLabel(
                        text: preview.title,
                        size: 11,
                        weight: .semibold,
                        opacity: 0.82,
                        foregroundContext: .imageOverlay
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    pluginBadge

                    if record.excluded || record.snapshotSkipped {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.84))
                    }


                    Color.clear
                        .frame(width: cardFavoriteActionReservedTrailingSpace, height: 1)
                        .accessibilityHidden(true)

                    Spacer(minLength: 0)
                }
                .frame(height: ClipboardRecordDensityMetrics.cardHeaderSlotHeight, alignment: .center)
                .layoutPriority(2)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    ClipboardCardMetaLabel(
                        text: record.lastCopiedAt.formatted(date: .omitted, time: .shortened),
                        size: 10,
                        weight: .medium,
                        opacity: 0.72,
                        foregroundContext: .imageOverlay
                    )
                    Spacer(minLength: 0)
                }
                .frame(height: ClipboardRecordDensityMetrics.cardFooterSlotHeight, alignment: .leading)
                .layoutPriority(2)
            }
            .padding(.horizontal, ClipboardRecordDensityMetrics.cardContentPadding)
            .padding(.vertical, ClipboardRecordDensityMetrics.cardVerticalPadding)
        }
    }
}
