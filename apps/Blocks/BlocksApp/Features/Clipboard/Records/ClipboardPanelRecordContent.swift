import BlocksCore
import SwiftUI

@MainActor
struct ClipboardPanelRecordContent {
    let clipboardStore: ClipboardStore
    let panelActions: ClipboardPanelActions
    let pluginManager: BlocksNativePluginManager?
    let pluginRuntime: BlocksPluginRuntimeCoordinator?
    let selectedRecordID: String?
    let focusedRecordID: String?
    let detailRecordID: String?
    let itemFontSize: CGFloat
    let bottomCardWidth: CGFloat
    let quickPasteIndex: (String) -> Int?
    let panelSessionID: UUID?
    let onPointerPress: (String, ClipboardPanelActivationSource) -> Void
    let onPrimaryActivation: (String, ClipboardPanelActivationSource, ClipboardPanelActivationTrigger) -> Void
    let onRecordAction: (String, ClipboardPanelActivationSource, ClipboardPanelActivationTrigger, ClipboardPanelActionKind) -> Void
    let onRemove: (String) -> Void
    let onRecordAppeared: (Int) -> Void

    func bottomRecordCard(
        _ record: ClipboardRecorderRecord,
        offset: Int,
        cardHeight: CGFloat,
        bodyLineLimit: Int
    ) -> some View {
        ClipboardPanelBottomRecord(
            values: recordValues(for: record, offset: offset),
            actions: recordActions(for: record.id, source: .bottomCard),
            cardWidth: bottomCardWidth,
            cardHeight: cardHeight,
            bodyLineLimit: bodyLineLimit
        )
        .onAppear { onRecordAppeared(offset) }
    }

    func sideRecordRow(
        _ record: ClipboardRecorderRecord,
        offset: Int,
        rowHeight: CGFloat,
        bodyLineLimit: Int
    ) -> some View {
        ClipboardPanelSideRecord(
            values: recordValues(for: record, offset: offset),
            actions: recordActions(for: record.id, source: .sideRow),
            rowHeight: rowHeight,
            bodyLineLimit: bodyLineLimit
        )
        .onAppear { onRecordAppeared(offset) }
    }

    private func recordValues(
        for record: ClipboardRecorderRecord,
        offset: Int
    ) -> ClipboardPanelRecordValues {
        ClipboardPanelRecordValues(
            record: record,
            preview: clipboardStore.preview(for: record),
            ocrState: clipboardStore.ocrState(for: record),
            tagStore: clipboardStore.tagStore,
            isSelected: selectedRecordID == record.id,
            isFocused: focusedRecordID == record.id,
            isDetailPresented: detailRecordID == record.id,
            itemFontSize: itemFontSize,
            quickPasteIndex: quickPasteIndex(record.id),
            accessibilitySortPriority: ClipboardPanelVisualPolicy.recordAccessibilitySortPriority(
                at: offset
            ),
            panelSessionID: panelSessionID,
            pluginBadge: pluginBadge(for: record),
            pluginContextActions: pluginContextActions(for: record)
        )
    }

    private func pluginContextActions(
        for record: ClipboardRecorderRecord
    ) -> AnyView? {
        guard let pluginManager, let pluginRuntime else { return nil }
        return AnyView(
            BlocksPluginUISlotHost(
                manager: pluginManager,
                runtime: pluginRuntime,
                slot: .clipboardContextAction,
                context: [
                    "record_id": .string(record.id),
                    "record_kind": .string(record.kind.rawValue)
                ],
                protectedContext: [
                    "record_summary": .string(record.summary)
                ],
                requiredDataPermission: .clipboardContent
            )
        )
    }

    private func pluginBadge(for record: ClipboardRecorderRecord) -> AnyView? {
        guard let pluginManager, let pluginRuntime else {
            return nil
        }
        return AnyView(
            BlocksPluginUISlotHost(
                manager: pluginManager,
                runtime: pluginRuntime,
                slot: .clipboardRecordBadge,
                context: [
                    "record_id": .string(record.id),
                    "record_kind": .string(record.kind.rawValue)
                ],
                protectedContext: [
                    "record_summary": .string(record.summary)
                ],
                requiredDataPermission: .clipboardContent
            )
        )
    }

    private func recordActions(
        for recordID: String,
        source: ClipboardPanelActivationSource
    ) -> ClipboardPanelRecordActions {
        ClipboardPanelRecordActions(
            onPointerPress: { onPointerPress(recordID, source) },
            onSingleClick: { onPrimaryActivation(recordID, source, .singleClick) },
            onDoubleClick: { onPrimaryActivation(recordID, source, .doubleClick) },
            onPaste: { onRecordAction(recordID, .contextMenu, .contextMenu, .paste) },
            onTranslate: { panelActions.translateRecord(recordID) },
            onRetryOCR: { onRecordAction(recordID, .contextMenu, .contextMenu, .ocrRetry) },
            onToggleFavorite: { panelActions.toggleFavorite(recordID) },
            onToggleTag: { tagID in
                Task { @MainActor in
                    await panelActions.toggleTag(recordID, tagID)
                }
            },
            onCreateTag: { name in
                Task { @MainActor in
                    await panelActions.createTagAndAttach(recordID, name)
                }
            },
            onCopyPlainText: { onRecordAction(recordID, .contextMenu, .contextMenu, .copyPlainText) },
            onRemove: { onRemove(recordID) }
        )
    }
}
