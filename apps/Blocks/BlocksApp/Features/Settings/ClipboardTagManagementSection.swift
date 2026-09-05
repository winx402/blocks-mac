import AppKit
import BlocksCore
import Combine
import SwiftUI

struct ClipboardTagManagementSection: View {
    @ObservedObject var tagStore: ClipboardTagStore
    let onOpenScreenshotSettings: () -> Void
    @Binding var newTagName: String
    @State private var settingsTagFrames: [String: CGRect] = [:]
    @State private var settingsDraggedTagID: String?
    @State private var settingsDropInsertionTargetKey: String?
    @State private var settingsDragStartLocation: CGPoint?
    @State private var isSettingsTagDragging = false
    @State private var editingSettingsTagID: String?
    @State private var settingsDraftTagName = ""
    @State private var pendingDeleteTag: ClipboardTag?
    @State private var activeTagMutationID: UUID?
    @FocusState private var settingsTagEditorFocused: Bool

    private let settingsTagDropTargetKeyBeforeFirst = "__settings_tag_drop_before_first__"
    private let settingsTagDropCoordinateSpace = "ClipboardSettingsTagDropSpace"

    private var ordinaryTags: [ClipboardTag] {
        tagStore.tags.filter { !$0.isFavorite }
    }

    private var ordinaryTagIDs: [String] {
        ordinaryTags.map(\.id)
    }

    private var newTagValidationError: ClipboardTagOperationError? {
        guard !newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return tagStore.newTagValidationError(displayName: newTagName)
    }

    var body: some View {
        SettingsSection(title: L10n.string("settings.clipboardTags")) {
            SettingsActionRow(
                title: L10n.string("settings.clipboardTagsNew"),
                detail: newTagValidationError?.localizedMessage
                    ?? tagStore.operationError?.localizedMessage
                    ?? L10n.string("settings.clipboardTagsNewDetail")
            ) {
                TextField(L10n.string("settings.clipboardTagsNamePlaceholder"), text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(createNewTag)
                Button {
                    createNewTag()
                } label: {
                    Label(L10n.string("settings.clipboardTagsCreate"), systemImage: "plus")
                }
                .disabled(
                    newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newTagValidationError != nil
                )
            }

            SettingsRowDivider()

            VStack(spacing: 0) {
                if let favoriteTag = tagStore.favoriteTag {
                    settingsTagRow(favoriteTag)
                    SettingsRowDivider()
                }

                settingsTagDropInsertionIndicator(afterTagID: nil)

                ForEach(ordinaryTags) { tag in
                    settingsTagRow(tag)
                        .background(settingsTagFramePreference(tagID: tag.id))
                        .simultaneousGesture(settingsTagPointerGesture(tag: tag))
                        .contextMenu {
                            settingsTagContextMenu(for: tag)
                        }
                        .accessibilityAction(named: Text(L10n.string("settings.clipboardTagsMoveUp"))) {
                            moveSettingsTagUp(tag)
                        }
                        .accessibilityAction(named: Text(L10n.string("settings.clipboardTagsMoveDown"))) {
                            moveSettingsTagDown(tag)
                        }

                    settingsTagDropInsertionIndicator(afterTagID: tag.id)

                    if tag.id != ordinaryTags.last?.id {
                        SettingsRowDivider()
                    }
                }
            }
            .coordinateSpace(name: settingsTagDropCoordinateSpace)
            .onPreferenceChange(ClipboardSettingsTagFramePreferenceKey.self) { frames in
                guard frames != settingsTagFrames else { return }
                Task { @MainActor in
                    settingsTagFrames = frames
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissSettingsTagEditOnOutsideTap()
                },
                including: .gesture
            )
        }
        .onChange(of: settingsTagEditorFocused) { _, focused in
            if !focused, editingSettingsTagID != nil {
                commitSettingsTagEdit()
            }
        }
        .onChange(of: ordinaryTagIDs) { _, _ in
            clearSettingsTagDragState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            clearSettingsTagDragState()
        }
        .onDisappear {
            clearSettingsTagDragState()
        }
        .confirmationDialog(
            L10n.string("clipboard.tags.delete.confirmTitle"),
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("clipboard.tags.delete"), role: .destructive) {
                if let pendingDeleteTag {
                    submitDelete(tagID: pendingDeleteTag.id)
                }
                pendingDeleteTag = nil
            }
            Button(L10n.string("common.cancel"), role: .cancel) {
                pendingDeleteTag = nil
            }
        } message: {
            Text(L10n.format("clipboard.tags.delete.confirmMessage", pendingDeleteTag?.displayName ?? ""))
        }
    }

    private func settingsTagRow(_ tag: ClipboardTag) -> some View {
        ClipboardTagRow(
            tag: tag,
            isEditing: editingSettingsTagID == tag.id,
            draftName: $settingsDraftTagName,
            tagEditorFocused: $settingsTagEditorFocused,
            beginSettingsTagEdit: {
                beginSettingsTagEdit(tag)
            },
            commitSettingsTagEdit: {
                commitSettingsTagEdit()
            },
            cancelSettingsTagEdit: {
                cancelSettingsTagEdit()
            },
            openScreenshotSettings: onOpenScreenshotSettings,
            deleteTag: {
                dismissSettingsTagEditOnOutsideTap()
                return requestDelete(tag)
            }
        )
    }

    private func beginSettingsTagEdit(_ tag: ClipboardTag) {
        guard !tag.isBuiltIn else {
            dismissSettingsTagEditOnOutsideTap()
            return
        }
        if editingSettingsTagID != tag.id {
            commitSettingsTagEdit()
            guard editingSettingsTagID == nil else {
                return
            }
        }
        editingSettingsTagID = tag.id
        settingsDraftTagName = tag.localizedDisplayName
        DispatchQueue.main.async {
            settingsTagEditorFocused = true
        }
    }

    private func commitSettingsTagEdit() {
        guard activeTagMutationID == nil else { return }
        guard let editingTagID = editingSettingsTagID,
              let tag = tagStore.tags.first(where: { $0.id == editingTagID }) else {
            cancelSettingsTagEdit()
            return
        }
        guard !tag.isBuiltIn else {
            cancelSettingsTagEdit()
            return
        }
        let trimmed = settingsDraftTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            settingsTagEditorFocused = true
            return
        }
        if trimmed == tag.localizedDisplayName {
            editingSettingsTagID = nil
            settingsDraftTagName = ""
            settingsTagEditorFocused = false
            return
        }
        let mutationID = UUID()
        activeTagMutationID = mutationID
        Task { @MainActor in
            let succeeded = await tagStore.renameTag(
                tagID: editingTagID,
                displayName: trimmed
            )
            guard activeTagMutationID == mutationID else { return }
            activeTagMutationID = nil
            guard editingSettingsTagID == editingTagID else { return }
            if succeeded {
                editingSettingsTagID = nil
                settingsDraftTagName = ""
                settingsTagEditorFocused = false
            } else {
                settingsTagEditorFocused = true
            }
        }
    }

    private func cancelSettingsTagEdit() {
        editingSettingsTagID = nil
        settingsDraftTagName = ""
        settingsTagEditorFocused = false
    }

    private func dismissSettingsTagEditOnOutsideTap() {
        guard editingSettingsTagID != nil else {
            return
        }
        commitSettingsTagEdit()
    }

    private func createNewTag() {
        guard activeTagMutationID == nil else { return }
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, tagStore.newTagValidationError(displayName: name) == nil else {
            return
        }
        let mutationID = UUID()
        activeTagMutationID = mutationID
        Task { @MainActor in
            let succeeded = await tagStore.createTag(displayName: name)
            guard activeTagMutationID == mutationID else { return }
            activeTagMutationID = nil
            if succeeded, newTagName.trimmingCharacters(in: .whitespacesAndNewlines) == name {
                newTagName = ""
            }
        }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteTag != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteTag = nil
                }
            }
        )
    }

    private func requestDelete(_ tag: ClipboardTag) -> Bool {
        guard !tag.isBuiltIn else {
            return false
        }
        if tagUseCount(tag.id) > 0 {
            pendingDeleteTag = tag
            return true
        }
        submitDelete(tagID: tag.id)
        return true
    }

    @ViewBuilder
    private func settingsTagContextMenu(for tag: ClipboardTag) -> some View {
        if !tag.isBuiltIn {
            Button {
                beginSettingsTagEdit(tag)
            } label: {
                Label(L10n.string("settings.clipboardTagsRename"), systemImage: "pencil")
            }

            Divider()

            Button {
                moveSettingsTagUp(tag)
            } label: {
                Label(L10n.string("settings.clipboardTagsMoveUp"), systemImage: "arrow.up")
            }
            .disabled(!canMoveSettingsTagUp(tag))

            Button {
                moveSettingsTagDown(tag)
            } label: {
                Label(L10n.string("settings.clipboardTagsMoveDown"), systemImage: "arrow.down")
            }
            .disabled(!canMoveSettingsTagDown(tag))

            Divider()

            Button(role: .destructive) {
                _ = requestDelete(tag)
            } label: {
                Label(L10n.string("settings.clipboardTagsDelete"), systemImage: "trash")
            }
        }
    }

    private func canMoveSettingsTagUp(_ tag: ClipboardTag) -> Bool {
        ordinaryTags.firstIndex(where: { $0.id == tag.id }).map { $0 > 0 } ?? false
    }

    private func canMoveSettingsTagDown(_ tag: ClipboardTag) -> Bool {
        ordinaryTags.firstIndex(where: { $0.id == tag.id }).map { $0 < ordinaryTags.count - 1 } ?? false
    }

    private func moveSettingsTagUp(_ tag: ClipboardTag) {
        guard activeTagMutationID == nil else { return }
        guard let index = ordinaryTags.firstIndex(where: { $0.id == tag.id }), index > 0 else {
            return
        }
        let afterTagID = index > 1 ? ordinaryTags[index - 2].id : nil
        clearSettingsTagDragState()
        submitMove(tagID: tag.id, afterTagID: afterTagID)
    }

    private func moveSettingsTagDown(_ tag: ClipboardTag) {
        guard activeTagMutationID == nil else { return }
        guard let index = ordinaryTags.firstIndex(where: { $0.id == tag.id }), index < ordinaryTags.count - 1 else {
            return
        }
        clearSettingsTagDragState()
        submitMove(tagID: tag.id, afterTagID: ordinaryTags[index + 1].id)
    }

    private func tagUseCount(_ tagID: String) -> Int {
        tagStore.recordTags.values.reduce(into: 0) { count, tags in
            if tags.contains(where: { $0.id == tagID }) {
                count += 1
            }
        }
    }

    private func settingsTagDropInsertionIndicator(afterTagID: String?) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .opacity(settingsDropInsertionTargetKey == settingsDropTargetKey(afterTagID: afterTagID) ? 1 : 0)
            .padding(.horizontal, 8)
            .blocksAnimation(.hoverFocus, value: settingsDropInsertionTargetKey)
            .accessibilityHidden(true)
    }

    private func settingsTagFramePreference(tagID: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ClipboardSettingsTagFramePreferenceKey.self,
                value: [tagID: proxy.frame(in: .named(settingsTagDropCoordinateSpace))]
            )
        }
    }

    private func settingsDropTargetKey(afterTagID: String?) -> String {
        afterTagID ?? settingsTagDropTargetKeyBeforeFirst
    }

    private func settingsTagPointerGesture(tag: ClipboardTag) -> some Gesture {
        DragGesture(
            minimumDistance: ClipboardFilterBarLayout.tagDragActivationDistance,
            coordinateSpace: .named(settingsTagDropCoordinateSpace)
        )
            .onChanged { value in
                handleSettingsTagPointerChanged(tagID: tag.id, value: value)
            }
            .onEnded { value in
                handleSettingsTagPointerEnded(value: value)
            }
    }

    private func handleSettingsTagPointerChanged(tagID: String, value: DragGesture.Value) {
        guard ordinaryTags.contains(where: { $0.id == tagID }) else {
            clearSettingsTagDragState()
            return
        }
        if settingsDragStartLocation == nil {
            settingsDragStartLocation = value.startLocation
        }
        let start = settingsDragStartLocation ?? value.startLocation
        let distance = hypot(value.location.x - start.x, value.location.y - start.y)
        guard distance >= 3 else {
            settingsDropInsertionTargetKey = nil
            return
        }
        dismissSettingsTagEditOnOutsideTap()
        isSettingsTagDragging = true
        beginSettingsTagDrag(tagID)
        updateSettingsTagDrag(location: value.location)
    }

    private func handleSettingsTagPointerEnded(value: DragGesture.Value) {
        if isSettingsTagDragging {
            finishSettingsTagDrag(location: value.location)
        } else {
            clearSettingsTagDragState()
        }
    }

    private func beginSettingsTagDrag(_ tagID: String) {
        guard ordinaryTags.contains(where: { $0.id == tagID }) else {
            return
        }
        if settingsDraggedTagID != tagID {
            settingsDraggedTagID = tagID
        }
    }

    private func updateSettingsTagDrag(location: CGPoint) {
        guard let draggedID = settingsDraggedOrdinaryTagID,
              let target = validSettingsInsertionTarget(for: draggedID, location: location) else {
            settingsDropInsertionTargetKey = nil
            return
        }
        settingsDropInsertionTargetKey = settingsDropTargetKey(afterTagID: target.afterTagID)
    }

    private func finishSettingsTagDrag(location: CGPoint) {
        defer { clearSettingsTagDragState() }
        guard activeTagMutationID == nil else { return }
        guard let draggedID = settingsDraggedOrdinaryTagID,
              let target = validSettingsInsertionTarget(for: draggedID, location: location) else {
            return
        }
        submitMove(tagID: draggedID, afterTagID: target.afterTagID)
    }

    private func submitMove(tagID: String, afterTagID: String?) {
        guard activeTagMutationID == nil else { return }
        let mutationID = UUID()
        activeTagMutationID = mutationID
        Task { @MainActor in
            _ = await tagStore.moveFilterTag(
                tagID: tagID,
                afterTagID: afterTagID
            )
            guard activeTagMutationID == mutationID else { return }
            activeTagMutationID = nil
        }
    }

    private func submitDelete(tagID: String) {
        guard activeTagMutationID == nil else { return }
        let mutationID = UUID()
        activeTagMutationID = mutationID
        Task { @MainActor in
            _ = await tagStore.deleteTag(tagID: tagID)
            guard activeTagMutationID == mutationID else { return }
            activeTagMutationID = nil
        }
    }

    private var settingsDraggedOrdinaryTagID: String? {
        guard let settingsDraggedTagID,
              ordinaryTags.contains(where: { $0.id == settingsDraggedTagID }) else {
            return nil
        }
        return settingsDraggedTagID
    }

    private func validSettingsInsertionTarget(for draggedID: String, location: CGPoint) -> ClipboardSettingsTagReorderTarget? {
        guard let target = calculateSettingsInsertionTarget(location: location),
              target.afterTagID != draggedID,
              currentPreviousSettingsTagID(for: draggedID) != target.afterTagID else {
            return nil
        }
        return target
    }

    private func calculateSettingsInsertionTarget(location: CGPoint) -> ClipboardSettingsTagReorderTarget? {
        let orderedFrames = ordinaryTags.compactMap { tag -> (id: String, frame: CGRect)? in
            guard let frame = settingsTagFrames[tag.id] else {
                return nil
            }
            return (id: tag.id, frame: frame)
        }
        .sorted { lhs, rhs in
            lhs.frame.minY < rhs.frame.minY
        }

        guard !orderedFrames.isEmpty else {
            return nil
        }

        var afterTagID: String?
        for item in orderedFrames {
            if location.y < item.frame.midY {
                break
            }
            afterTagID = item.id
        }
        return ClipboardSettingsTagReorderTarget(afterTagID: afterTagID)
    }

    private func currentPreviousSettingsTagID(for tagID: String) -> String? {
        let orderedIDs = ordinaryTags.map(\.id)
        guard let currentIndex = orderedIDs.firstIndex(of: tagID), currentIndex > 0 else {
            return nil
        }
        return orderedIDs[currentIndex - 1]
    }

    private func clearSettingsTagDragState() {
        settingsDraggedTagID = nil
        settingsDropInsertionTargetKey = nil
        settingsDragStartLocation = nil
        isSettingsTagDragging = false
    }
}

private struct ClipboardTagRow: View {
    let tag: ClipboardTag
    let isEditing: Bool
    @Binding var draftName: String
    let tagEditorFocused: FocusState<Bool>.Binding
    let beginSettingsTagEdit: () -> Void
    let commitSettingsTagEdit: () -> Void
    let cancelSettingsTagEdit: () -> Void
    let openScreenshotSettings: () -> Void
    let deleteTag: () -> Bool
    var body: some View {
        SettingsCustomLabelRow(
            detail: tag.isFavorite
                ? L10n.string("settings.clipboardTagsFavoriteDetail")
                : tag.isScreenshot
                    ? L10n.string("settings.clipboardTagsScreenshotDetail")
                    : L10n.string("settings.clipboardTagsOrdinaryDetail"),
            label: {
                tagIdentity
            }
        ) {
            HStack(spacing: 8) {
                if tag.isBuiltIn {
                    if tag.isScreenshot {
                        Button(action: openScreenshotSettings) {
                            HStack(spacing: 4) {
                                Text(L10n.string("clipboard.tags.screenshot.openSettings"))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .buttonStyle(.link)
                        .help(L10n.string("clipboard.tags.screenshot.openSettings"))
                    } else {
                        Text(L10n.string("settings.clipboardTagsBuiltIn"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .help(L10n.string("settings.clipboardTagsFavoriteImmutable"))
                    }
                } else {
                    BlocksCompactIconButton(
                        systemImage: "trash",
                        label: L10n.string("settings.clipboardTagsDelete"),
                        emphasis: .destructive
                    ) {
                        commitSettingsTagEdit()
                        _ = deleteTag()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tagIdentity: some View {
        if !tag.isBuiltIn, isEditing {
            HStack(spacing: 8) {
                Circle()
                    .fill(tag.displayColor)
                    .frame(width: 10, height: 10)
                    .frame(width: 14, height: 14)

                TextField("", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .blocksFont(size: 13)
                    .frame(width: 150)
                    .accessibilityLabel(L10n.string("settings.clipboardTagsNamePlaceholder"))
                    .focused(tagEditorFocused)
                    .onSubmit {
                        commitSettingsTagEdit()
                    }
                    .onExitCommand {
                        cancelSettingsTagEdit()
                    }
            }
        } else {
            if tag.isBuiltIn {
                ClipboardTagIdentityLabel(tag: tag)
            } else {
                Button(action: beginSettingsTagEdit) {
                    ClipboardTagIdentityLabel(tag: tag)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ClipboardSettingsTagFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct ClipboardSettingsTagReorderTarget {
    let afterTagID: String?
}

private struct ClipboardTagIdentityLabel: View {
    let tag: ClipboardTag
    @ScaledMetric(relativeTo: .body) private var colorDotSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var iconSlotSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage = tag.builtInSystemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tag.isFavorite ? Color.yellow.opacity(0.95) : Color.orange)
                    .frame(width: iconSlotSize, height: iconSlotSize)
            } else {
                Circle()
                    .fill(tag.displayColor)
                    .frame(width: colorDotSize, height: colorDotSize)
                    .frame(width: iconSlotSize, height: iconSlotSize)
            }

            Text(tag.localizedDisplayName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(tag.localizedDisplayName)
        .help(tag.localizedDisplayName)
    }
}
