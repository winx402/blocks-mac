import BlocksCore
import SwiftUI

enum ClipboardPanelVisualPolicy {
    static func showsBottomCardWidthResizeHandle(after index: Int, recordCount: Int) -> Bool {
        recordCount > 1 && index == 0
    }

    static func bottomCardWidthResizeHandleTrailingOffset(
        cardSpacing: CGFloat,
        handleWidth: CGFloat
    ) -> CGFloat {
        (cardSpacing + handleWidth) / 2
    }

    static func recordAccessibilitySortPriority(at index: Int) -> Double {
        -Double(max(index, 0))
    }
}

struct ClipboardPanelRecordValues {
    let record: ClipboardRecorderRecord
    let preview: ClipboardRecordPreview
    let ocrState: ClipboardOCRState
    let tagStore: ClipboardTagStore
    let isSelected: Bool
    let isFocused: Bool
    let isDetailPresented: Bool
    let itemFontSize: CGFloat
    let quickPasteIndex: Int?
    let accessibilitySortPriority: Double
    let panelSessionID: UUID?
    let pluginBadge: AnyView?
    let pluginContextActions: AnyView?
}

struct ClipboardPanelRecordActions {
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
}

struct ClipboardPanelBottomRecord: View {
    let values: ClipboardPanelRecordValues
    let actions: ClipboardPanelRecordActions
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let bodyLineLimit: Int

    var body: some View {
        ClipboardFloatingRecordCard(
            record: values.record,
            preview: values.preview,
            ocrState: values.ocrState,
            tagStore: values.tagStore,
            isSelected: values.isSelected,
            isFocused: values.isFocused,
            isDetailPresented: values.isDetailPresented,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            bodyLineLimit: bodyLineLimit,
            itemFontSize: values.itemFontSize,
            quickPasteIndex: values.quickPasteIndex,
            accessibilitySortPriority: values.accessibilitySortPriority,
            panelSessionID: values.panelSessionID,
            pluginBadge: values.pluginBadge,
            pluginContextActions: values.pluginContextActions,
            onPointerPress: actions.onPointerPress,
            onSingleClick: actions.onSingleClick,
            onDoubleClick: actions.onDoubleClick,
            onPaste: actions.onPaste,
            onTranslate: actions.onTranslate,
            onRetryOCR: actions.onRetryOCR,
            onToggleFavorite: actions.onToggleFavorite,
            onToggleTag: actions.onToggleTag,
            onCreateTag: actions.onCreateTag,
            onCopyPlainText: actions.onCopyPlainText,
            onRemove: actions.onRemove
        )
    }
}

struct ClipboardPanelSideRecord: View {
    let values: ClipboardPanelRecordValues
    let actions: ClipboardPanelRecordActions
    let rowHeight: CGFloat
    let bodyLineLimit: Int

    var body: some View {
        ClipboardFloatingRecordRow(
            record: values.record,
            preview: values.preview,
            ocrState: values.ocrState,
            tagStore: values.tagStore,
            isSelected: values.isSelected,
            isFocused: values.isFocused,
            isDetailPresented: values.isDetailPresented,
            rowHeight: rowHeight,
            bodyLineLimit: bodyLineLimit,
            itemFontSize: values.itemFontSize,
            quickPasteIndex: values.quickPasteIndex,
            accessibilitySortPriority: values.accessibilitySortPriority,
            panelSessionID: values.panelSessionID,
            pluginBadge: values.pluginBadge,
            pluginContextActions: values.pluginContextActions,
            onPointerPress: actions.onPointerPress,
            onSingleClick: actions.onSingleClick,
            onDoubleClick: actions.onDoubleClick,
            onPaste: actions.onPaste,
            onTranslate: actions.onTranslate,
            onRetryOCR: actions.onRetryOCR,
            onToggleFavorite: actions.onToggleFavorite,
            onToggleTag: actions.onToggleTag,
            onCreateTag: actions.onCreateTag,
            onCopyPlainText: actions.onCopyPlainText,
            onRemove: actions.onRemove
        )
    }
}

struct ClipboardPanelLayoutValues {
    let position: FloatingPanelPosition
    let emptyStatePresentation: ClipboardSearchStatusPresentation
    let records: [ClipboardRecorderRecord]
    let bottomRecordCardWidth: CGFloat
    let itemFontSize: CGFloat
    let sideRowHeight: CGFloat
    let hoveredSideRowHeightResizeHandleID: String?
}

struct ClipboardPanelLayoutActions {
    let onBottomCardWidthChanged: (CGFloat) -> Void
    let onSideRowHeightResizeChanged: (String, CGFloat, CGFloat) -> Void
    let onSideRowHeightResizeEnded: (String, CGFloat, CGFloat) -> Void
    let onSideRowHeightResizeHoverChanged: (String, Bool) -> Void
}

private struct ClipboardSideRowHeightResizeHandle: View {
    private static let accessibilityStep: CGFloat = 12

    let handleID: String
    let currentHeight: CGFloat
    let isHovered: Bool
    let onHoverUpdate: (String, Bool) -> Void
    let onHeightChanged: (String, CGFloat, CGFloat) -> Void
    let onHeightChangeEnded: (String, CGFloat, CGFloat) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(isHovered ? 0.86 : 0.64))

            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.24 : 0.12))
                .frame(width: 52, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering in
            onHoverUpdate(handleID, hovering)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    onHeightChanged(handleID, currentHeight, value.translation.height)
                }
                .onEnded { value in
                    onHeightChangeEnded(handleID, currentHeight, value.translation.height)
                }
        )
        .help(L10n.string("clipboard.panel.resizeHeight"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("clipboard.panel.resizeHeight"))
        .accessibilityValue("\(Int(currentHeight.rounded())) pt")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onHeightChangeEnded(handleID, currentHeight, Self.accessibilityStep)
            case .decrement:
                onHeightChangeEnded(handleID, currentHeight, -Self.accessibilityStep)
            @unknown default:
                break
            }
        }
    }
}

struct ClipboardPanelLayout<Header: View, BottomRecord: View, SideRecord: View>: View {
    let values: ClipboardPanelLayoutValues
    let actions: ClipboardPanelLayoutActions
    let header: Header
    let bottomRecordBuilder: (ClipboardRecorderRecord, Int, CGFloat, Int) -> BottomRecord
    let sideRecordBuilder: (ClipboardRecorderRecord, Int, CGFloat, Int) -> SideRecord

    var body: some View {
        decoratedContent
    }

    @ViewBuilder
    private var decoratedContent: some View {
        if values.position == .bottom {
            content
                .blocksSurface(
                    .panel,
                    shape: UnevenRoundedRectangle(
                        topLeadingRadius: BlocksVisualTokens.CornerRadius.large,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: BlocksVisualTokens.CornerRadius.large,
                        style: .continuous
                    ),
                    contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14)
                )
        } else {
            content
                .blocksSurface(
                    .panel,
                    cornerRadius: BlocksVisualTokens.CornerRadius.large,
                    padding: BlocksVisualTokens.Spacing.lg
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        if values.position == .bottom {
            bottomContent
        } else {
            sideContent
        }
    }

    private var bottomContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if values.records.isEmpty {
                emptyState
            } else {
                pasteStyleTray
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sideContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if values.records.isEmpty {
                emptyState
            } else {
                recordsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Label(values.emptyStatePresentation.title, systemImage: values.emptyStatePresentation.systemImage)
                .blocksFont(size: 13, weight: .semibold)
            Text(values.emptyStatePresentation.detail)
                .blocksFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: values.position == .bottom ? 112 : 180, alignment: .center)
        .padding(.horizontal, 14)
        .blocksSurface(
            .section,
            cornerRadius: BlocksVisualTokens.CornerRadius.section
        )
    }

    private var recordsContent: some View {
        Group {
            if values.position == .bottom {
                pasteStyleTray
            } else {
                recordList
            }
        }
    }

    private var pasteStyleTray: some View {
        GeometryReader { proxy in
            let cardHeight = bottomRecordCardHeight(for: proxy.size.height)
            let bodyLineLimit = bottomRecordCardBodyLineLimit(for: cardHeight, itemFontSize: values.itemFontSize)
            let bottomRecordCardWidth = values.bottomRecordCardWidth
            let records = values.records

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: BlocksVisualTokens.Spacing.sm) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { offset, record in
                        let showsResizeHandle = ClipboardPanelVisualPolicy.showsBottomCardWidthResizeHandle(
                            after: offset,
                            recordCount: records.count
                        )

                        bottomRecordBuilder(record, offset, cardHeight, bodyLineLimit)
                            .overlay(alignment: .trailing) {
                                if showsResizeHandle {
                                    ClipboardCardWidthResizeHandle(
                                        currentWidth: bottomRecordCardWidth,
                                        onWidthChanged: actions.onBottomCardWidthChanged
                                    )
                                    .frame(
                                        width: ClipboardBottomTrayLayout.cardWidthResizeHitWidth,
                                        height: cardHeight
                                    )
                                    .offset(
                                        x: ClipboardPanelVisualPolicy.bottomCardWidthResizeHandleTrailingOffset(
                                            cardSpacing: BlocksVisualTokens.Spacing.sm,
                                            handleWidth: ClipboardBottomTrayLayout.cardWidthResizeHitWidth
                                        )
                                    )
                                }
                            }
                            .zIndex(showsResizeHandle ? 1 : 0)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 5)
                .padding(.bottom, 2)
                .frame(height: proxy.size.height, alignment: .bottom)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(minHeight: ClipboardBottomTrayLayout.bottomTrayMinHeight, maxHeight: .infinity, alignment: .bottom)
    }

    private func bottomRecordCardHeight(for trayHeight: CGFloat) -> CGFloat {
        let availableHeight = trayHeight - ClipboardBottomTrayLayout.topPadding - ClipboardBottomTrayLayout.bottomPadding
        return min(
            max(availableHeight, ClipboardBottomTrayLayout.bottomCardMinHeight),
            ClipboardBottomTrayLayout.bottomCardMaxHeight
        )
    }

    private func bottomRecordCardBodyLineLimit(for cardHeight: CGFloat, itemFontSize: CGFloat) -> Int {
        let reservedHeight = ClipboardRecordDensityMetrics.metadataSlotHeight + 26
        let contentHeight = max(itemFontSize * 2.4, cardHeight - reservedHeight)
        let lineHeight = max(itemFontSize + 3, itemFontSize * 1.22)
        let computedLimit = Int(floor(contentHeight / lineHeight))
        return max(2, min(12, computedLimit))
    }

    private var recordList: some View {
        let rowHeight = values.sideRowHeight
        let bodyLineLimit = sideRecordBodyLineLimit(for: rowHeight, itemFontSize: values.itemFontSize)

        return GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 0)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(values.records.enumerated()), id: \.element.id) { offset, record in
                            sideRecordBuilder(record, offset, rowHeight, bodyLineLimit)
                                .frame(width: availableWidth, alignment: .topLeading)
                        }
                    }
                    .frame(width: availableWidth, alignment: .topLeading)

                    if let handleID = sideRowResizeHandleID {
                        sideRowResizeHandle(
                            handleID: handleID,
                            currentHeight: rowHeight,
                            isHovered: values.hoveredSideRowHeightResizeHandleID == handleID,
                            onHoverUpdate: actions.onSideRowHeightResizeHoverChanged,
                            onHeightChanged: actions.onSideRowHeightResizeChanged,
                            onHeightChangeEnded: actions.onSideRowHeightResizeEnded
                        )
                        .padding(.top, 2)
                    }
                }
                .frame(width: availableWidth, alignment: .topLeading)
            }
            .frame(width: availableWidth, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private func sideRecordBodyLineLimit(for rowHeight: CGFloat, itemFontSize: CGFloat) -> Int {
        let reservedHeight = ClipboardRecordDensityMetrics.metadataSlotHeight + 42
        let contentHeight = max(itemFontSize * 2.6, rowHeight - reservedHeight)
        let lineHeight = max(itemFontSize + 3, itemFontSize * 1.22)
        let computedLimit = Int(floor(contentHeight / lineHeight))
        return max(1, min(10, computedLimit))
    }

    private var sideRowResizeHandleID: String? {
        values.records.dropLast().last?.id ?? values.records.first?.id
    }

    private func sideRowResizeHandle(
        handleID: String,
        currentHeight: CGFloat,
        isHovered: Bool,
        onHoverUpdate: @escaping (String, Bool) -> Void,
        onHeightChanged: @escaping (String, CGFloat, CGFloat) -> Void,
        onHeightChangeEnded: @escaping (String, CGFloat, CGFloat) -> Void
    ) -> some View {
        ClipboardSideRowHeightResizeHandle(
            handleID: handleID,
            currentHeight: currentHeight,
            isHovered: isHovered,
            onHoverUpdate: onHoverUpdate,
            onHeightChanged: onHeightChanged,
            onHeightChangeEnded: onHeightChangeEnded
        )
    }
}
