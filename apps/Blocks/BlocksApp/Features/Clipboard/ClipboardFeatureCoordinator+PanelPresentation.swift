import BlocksCore
import Foundation

@MainActor
extension ClipboardFeatureCoordinator {
    func resolvedFloatingPanelPosition() -> FloatingPanelPosition {
        let rawPosition = UserDefaults.standard.string(forKey: "clipboard.panel.position")
            ?? FloatingPanelPosition.bottom.rawValue
        return FloatingPanelPosition(rawValue: rawPosition) ?? .bottom
    }

    func makeClipboardPanelActions() -> ClipboardPanelActions {
        ClipboardPanelActions(
            pasteQuickRecord: { [weak self] in self?.pasteQuickRecord(index: $0) },
            pasteRecord: { [weak self] in self?.pasteRecord(recordID: $0) },
            translateRecord: { [weak self] in self?.translateRecord($0) },
            copyRecordAsPlainText: { [weak self] in self?.copyRecordAsPlainText(recordID: $0) },
            deleteHistoryItem: { [weak self] recordID in
                guard let self else { return false }
                return await self.deleteHistoryItem(recordID: recordID)
            },
            toggleFavorite: { [weak self] in self?.toggleFavorite(recordID: $0) },
            setTagFilter: { [weak self] in self?.setTagFilter($0) },
            toggleTag: { [weak self] recordID, tagID in
                guard let self,
                      let mutation = await self.tagStore.toggleTagForPanel(
                        recordID: recordID,
                        tagID: tagID
                      ) else {
                    return
                }
                await self.dispatchPanelTagMutation(mutation)
            },
            createTagAndAttach: { [weak self] recordID, displayName in
                guard let self,
                      let mutation = await self.tagStore.createTagAndAttachForPanel(
                        displayName: displayName,
                        recordID: recordID
                      ) else {
                    return
                }
                await self.dispatchPanelTagMutation(mutation)
            }
        )
    }

    private func dispatchPanelTagMutation(
        _ mutation: ClipboardPanelTagMutation
    ) async {
        _ = await dispatchPluginEvent(
            BlocksPluginEventEnvelope(
                name: .clipboardTagChanged,
                payload: [
                    "operation": .string(mutation.operation),
                    "record_id": .string(mutation.recordID),
                    "tag_id": .string(mutation.tagID),
                ]
            )
        )
    }
}
