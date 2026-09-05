import AppKit
import BlocksCore
import Combine
import SwiftUI

extension ClipboardTag {
    var localizedDisplayName: String {
        switch builtInKind {
        case .favorite:
            L10n.string("settings.clipboardTagsFavorite")
        case .screenshot:
            L10n.string("clipboard.tags.screenshot")
        case .none:
            displayName
        }
    }

    var builtInSystemImage: String? {
        switch builtInKind {
        case .favorite:
            "star.fill"
        case .screenshot:
            "camera.fill"
        case .none:
            nil
        }
    }

    var displayColor: Color {
        switch colorToken {
        case "green":
            return .green
        case "purple":
            return .purple
        case "orange":
            return .orange
        case "pink":
            return .pink
        case "gray":
            return .gray
        case "cyan":
            return .cyan
        case "mint":
            return .mint
        case "favorite":
            return .yellow
        default:
            return .blue
        }
    }
}

struct ClipboardFlatTagFilterChips: View {
    private static let newTagDraftID = "__new_filter_tag__"
    private static let filterTagDropTargetKeyBeforeFirst = "__filter_tag_drop_before_first__"
    private static let tagDropCoordinateSpace = "ClipboardFlatTagFilterChipsDropSpace"

    let favoriteTag: ClipboardTag?
    let tags: [ClipboardTag]
    let selectedTagID: String?
    let operationErrorMessage: String?
    let tagUseCount: (String) -> Int
    let onSelectTag: (String?) -> Void
    let onCreateTag: (String, String?) async -> String?
    let onRenameTag: (String, String) async -> Bool
    let onDeleteTag: (String) async -> Bool
    let onMoveTag: (String, String?) async -> Bool

    @State private var editingTagID: String?
    @State private var draftTagName = ""
    @State private var draftInsertAfterTagID: String?
    @State private var pendingDeleteTag: ClipboardTag?
    @State private var dropInsertionTargetKey: String?
    @State private var draggedTagID: String?
    @State private var localTagDragStartLocation: CGPoint?
    @State private var isLocalTagDragging = false
    @State private var activeMutationID: UUID?
    @State private var tagFrames: [String: CGRect] = [:]
    @FocusState private var tagEditorFocused: Bool

    private var ordinaryTags: [ClipboardTag] {
        tags.filter { !$0.isFavorite }
    }

    var body: some View {
        HStack(spacing: 0) {
            if let favoriteTag {
                tagChip(tag: favoriteTag, selected: selectedTagID == favoriteTag.id)
            }

            insertionIndicator(afterTagID: nil)

            ForEach(ordinaryTags) { tag in
                if editingTagID == tag.id {
                    editingChip()
                } else {
                    draggableTagChip(tag: tag, selected: selectedTagID == tag.id)
                        .background(tagFramePreference(tagID: tag.id))
                        .contextMenu {
                            tagContextMenu(for: tag)
                        }
                }

                if editingTagID == Self.newTagDraftID && draftInsertAfterTagID == tag.id {
                    editingChip()
                }

                insertionIndicator(afterTagID: tag.id)
            }

            if editingTagID == Self.newTagDraftID && draftInsertAfterTagID == nil {
                editingChip()
            }

            blankCreateTarget
        }
        .padding(.leading, ClipboardFilterBarLayout.tagGroupLeadingSpacing)
        .coordinateSpace(name: Self.tagDropCoordinateSpace)
        .onPreferenceChange(ClipboardTagFramePreferenceKey.self) { frames in
            tagFrames = frames
        }
        .overlay(alignment: .leading) {
            panelTagInsertionCursor
        }
        .confirmationDialog(
            L10n.string("clipboard.tags.delete.confirmTitle"),
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("clipboard.tags.delete"), role: .destructive) {
                if let pendingDeleteTag {
                    deleteFilterTag(pendingDeleteTag)
                }
                pendingDeleteTag = nil
            }
            Button(L10n.string("common.cancel"), role: .cancel) {
                pendingDeleteTag = nil
            }
        } message: {
            Text(L10n.format("clipboard.tags.delete.confirmMessage", pendingDeleteTag?.localizedDisplayName ?? ""))
        }
        .onChange(of: tagEditorFocused) { _, focused in
            if !focused, editingTagID != nil {
                commitEditing()
            }
        }
        .onChange(of: tags) { _, _ in
            clearLocalTagDragState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            clearLocalTagDragState()
        }
        .onDisappear {
            clearLocalTagDragState()
        }
    }

    @ViewBuilder
    private var panelTagInsertionCursor: some View {
        GeometryReader { _ in
            if let x = panelTagInsertionCursorX {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: ClipboardFilterBarLayout.chipMinHeight - 4)
                    .offset(x: x - 1, y: 2)
                    .blocksAnimation(.hoverFocus, value: x)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private var panelTagInsertionCursorX: CGFloat? {
        guard let dropInsertionTargetKey else {
            return nil
        }
        if dropInsertionTargetKey == dropTargetKey(afterTagID: nil) {
            return tagDropTargetFrame(afterTagID: nil)?.minX
        }
        guard let afterTagID = ordinaryTags.first(where: { dropTargetKey(afterTagID: $0.id) == dropInsertionTargetKey })?.id else {
            return nil
        }
        return tagDropTargetFrame(afterTagID: afterTagID)?.maxX
    }

    private func tagDropTargetFrame(afterTagID: String?) -> CGRect? {
        let orderedFrames = ordinaryTags.compactMap { tag -> (id: String, frame: CGRect)? in
            guard let frame = tagFrames[tag.id] else {
                return nil
            }
            return (tag.id, frame)
        }
        .sorted { lhs, rhs in
            lhs.frame.minX < rhs.frame.minX
        }
        guard !orderedFrames.isEmpty else {
            return nil
        }
        guard let afterTagID else {
            return orderedFrames.first?.frame.offsetBy(dx: -ClipboardFilterBarLayout.tagDropIndicatorHitWidth / 2, dy: 0)
        }
        return orderedFrames.first(where: { $0.id == afterTagID })?.frame.offsetBy(dx: ClipboardFilterBarLayout.tagDropIndicatorHitWidth / 2, dy: 0)
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

    private func tagChip(tag: ClipboardTag, selected: Bool) -> some View {
        Button {
            onSelectTag(selected ? nil : tag.id)
        } label: {
            tagChipSurface(tag: tag, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag.localizedDisplayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tag.localizedDisplayName)
    }

    private func draggableTagChip(tag: ClipboardTag, selected: Bool) -> some View {
        Button {
            onSelectTag(selected ? nil : tag.id)
        } label: {
            tagChipSurface(tag: tag, selected: selected)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(localTagDragGesture(tag: tag))
        .accessibilityLabel(tag.localizedDisplayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(L10n.string("settings.clipboardTagsMoveUp"))) {
            moveFilterTagUp(tag)
        }
        .accessibilityAction(named: Text(L10n.string("settings.clipboardTagsMoveDown"))) {
            moveFilterTagDown(tag)
        }
        .help(tag.localizedDisplayName)
    }

    private func localTagDragGesture(tag: ClipboardTag) -> some Gesture {
        DragGesture(
            minimumDistance: ClipboardFilterBarLayout.tagDragActivationDistance,
            coordinateSpace: .named(Self.tagDropCoordinateSpace)
        )
            .onChanged { value in
                handleTagPointerChanged(tagID: tag.id, value: value)
            }
            .onEnded { value in
                handleTagPointerEnded(value: value)
            }
    }

    private func tagChipSurface(tag: ClipboardTag, selected: Bool) -> some View {
        HStack(spacing: 5) {
            if let systemImage = tag.builtInSystemImage {
                Image(systemName: systemImage)
                    .font(.system(size: ClipboardFilterBarLayout.tagTextFontSize, weight: .semibold))
                    .foregroundStyle(tag.isFavorite ? Color.yellow.opacity(0.95) : Color.orange)
            } else {
                Circle()
                    .fill(tag.displayColor)
                    .frame(width: ClipboardFilterBarLayout.tagIconSize, height: ClipboardFilterBarLayout.tagIconSize)
            }
            Text(tag.localizedDisplayName)
                .blocksFont(size: ClipboardFilterBarLayout.tagTextFontSize, weight: .semibold)
                .lineLimit(1)
        }
        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.94))
        .padding(.leading, 9)
        .padding(.trailing, 9)
        .frame(minHeight: ClipboardFilterBarLayout.chipMinHeight)
        .contentShape(Rectangle())
        .background {
            Capsule(style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.06))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    selected ? Color.accentColor.opacity(0.60) : Color.primary.opacity(0.10),
                    lineWidth: BlocksVisualTokens.Stroke.width
                )
        }
        .blocksAnimation(.selection, value: selected)
    }

    @ViewBuilder
    private func tagContextMenu(for tag: ClipboardTag) -> some View {
        if !tag.isBuiltIn {
            Button {
                beginRenaming(tag)
            } label: {
                Label(L10n.string("clipboard.tags.rename"), systemImage: "pencil")
            }

            Button(role: .destructive) {
                requestDelete(tag)
            } label: {
                Label(L10n.string("clipboard.tags.delete"), systemImage: "trash")
            }

            Divider()
        }

        Button {
            moveFilterTagUp(tag)
        } label: {
            Label(L10n.string("settings.clipboardTagsMoveUp"), systemImage: "arrow.up")
        }
        .disabled(!canMoveFilterTagUp(tag))

        Button {
            moveFilterTagDown(tag)
        } label: {
            Label(L10n.string("settings.clipboardTagsMoveDown"), systemImage: "arrow.down")
        }
        .disabled(!canMoveFilterTagDown(tag))

        if !tag.isBuiltIn {
            Divider()

            Button {
                beginCreating(afterTagID: tag.id)
            } label: {
                Label(L10n.string("clipboard.tags.new"), systemImage: "plus")
            }
        }
    }

    private var blankCreateTarget: some View {
        Color.clear
            .frame(minWidth: ClipboardFilterBarLayout.tagBlankCreateTargetMinWidth, maxWidth: .infinity, minHeight: ClipboardFilterBarLayout.chipMinHeight)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    beginCreating(afterTagID: nil)
                } label: {
                    Label(L10n.string("clipboard.tags.new"), systemImage: "plus")
                }
            }
    }

    private func insertionIndicator(afterTagID: String?) -> some View {
        ClipboardTagDropInsertionIndicator(isVisible: isDropInsertionTargetVisible(afterTagID: afterTagID))
            .frame(width: ClipboardFilterBarLayout.tagDropIndicatorHitWidth, height: ClipboardFilterBarLayout.chipMinHeight)
            .contentShape(Rectangle())
    }

    private func tagFramePreference(tagID: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ClipboardTagFramePreferenceKey.self,
                value: [tagID: proxy.frame(in: .named(Self.tagDropCoordinateSpace))]
            )
        }
    }

    private func isDropInsertionTargetVisible(afterTagID: String?) -> Bool {
        dropInsertionTargetKey == dropTargetKey(afterTagID: afterTagID)
    }

    private func dropTargetKey(afterTagID: String?) -> String {
        afterTagID ?? Self.filterTagDropTargetKeyBeforeFirst
    }

    private func handleTagPointerChanged(tagID: String, value: DragGesture.Value) {
        guard ordinaryTags.contains(where: { $0.id == tagID }) else {
            clearLocalTagDragState()
            return
        }
        if localTagDragStartLocation == nil {
            localTagDragStartLocation = value.startLocation
        }
        let start = localTagDragStartLocation ?? value.startLocation
        let distance = hypot(value.location.x - start.x, value.location.y - start.y)
        guard distance >= ClipboardFilterBarLayout.tagDragActivationDistance else {
            dropInsertionTargetKey = nil
            return
        }
        isLocalTagDragging = true
        beginLocalTagDrag(tagID)
        updateLocalTagDrag(location: value.location)
    }

    private func handleTagPointerEnded(value: DragGesture.Value) {
        if isLocalTagDragging {
            finishLocalTagDrag(location: value.location)
        } else {
            clearLocalTagDragState()
        }
    }

    private func canMoveFilterTagUp(_ tag: ClipboardTag) -> Bool {
        ordinaryTags.firstIndex(where: { $0.id == tag.id }).map { $0 > 0 } ?? false
    }

    private func canMoveFilterTagDown(_ tag: ClipboardTag) -> Bool {
        ordinaryTags.firstIndex(where: { $0.id == tag.id }).map { $0 < ordinaryTags.count - 1 } ?? false
    }

    private func moveFilterTagUp(_ tag: ClipboardTag) {
        guard activeMutationID == nil else { return }
        guard let index = ordinaryTags.firstIndex(where: { $0.id == tag.id }), index > 0 else {
            return
        }
        let afterTagID = index > 1 ? ordinaryTags[index - 2].id : nil
        clearLocalTagDragState()
        submitMove(tagID: tag.id, afterTagID: afterTagID)
    }

    private func moveFilterTagDown(_ tag: ClipboardTag) {
        guard activeMutationID == nil else { return }
        guard let index = ordinaryTags.firstIndex(where: { $0.id == tag.id }), index < ordinaryTags.count - 1 else {
            return
        }
        clearLocalTagDragState()
        submitMove(tagID: tag.id, afterTagID: ordinaryTags[index + 1].id)
    }

    private func beginLocalTagDrag(_ tagID: String) {
        guard ordinaryTags.contains(where: { $0.id == tagID }) else {
            return
        }
        if draggedTagID != tagID {
            draggedTagID = tagID
        }
    }

    private func updateLocalTagDrag(location: CGPoint) {
        guard let draggedID = draggedOrdinaryTagID,
              let target = validInsertionTarget(for: draggedID, location: location) else {
            dropInsertionTargetKey = nil
            return
        }
        dropInsertionTargetKey = dropTargetKey(afterTagID: target.afterTagID)
    }

    private func finishLocalTagDrag(location: CGPoint) {
        defer { clearLocalTagDragState() }
        guard activeMutationID == nil else { return }
        guard let draggedID = draggedOrdinaryTagID,
              let target = validInsertionTarget(for: draggedID, location: location) else {
            return
        }
        submitMove(tagID: draggedID, afterTagID: target.afterTagID)
    }

    private var draggedOrdinaryTagID: String? {
        guard let draggedTagID, ordinaryTags.contains(where: { $0.id == draggedTagID }) else {
            return nil
        }
        return draggedTagID
    }

    private func validInsertionTarget(for draggedID: String, location: CGPoint) -> ClipboardTagReorderTarget? {
        guard let target = calculateInsertionTarget(location: location),
              target.afterTagID != draggedID,
              currentPreviousTagID(for: draggedID) != target.afterTagID else {
            return nil
        }
        return target
    }

    private func calculateInsertionTarget(location: CGPoint) -> ClipboardTagReorderTarget? {
        let orderedFrames = ordinaryTags.compactMap { tag -> (id: String, frame: CGRect)? in
            guard let frame = tagFrames[tag.id] else {
                return nil
            }
            return (id: tag.id, frame: frame)
        }
        .sorted { lhs, rhs in
            lhs.frame.minX < rhs.frame.minX
        }

        guard !orderedFrames.isEmpty else {
            return nil
        }

        var afterTagID: String?
        for item in orderedFrames {
            if location.x < item.frame.midX {
                break
            }
            afterTagID = item.id
        }
        return ClipboardTagReorderTarget(afterTagID: afterTagID)
    }

    private func currentPreviousTagID(for tagID: String) -> String? {
        let orderedIDs = ordinaryTags.map(\.id)
        guard let currentIndex = orderedIDs.firstIndex(of: tagID), currentIndex > 0 else {
            return nil
        }
        return orderedIDs[currentIndex - 1]
    }

    private func clearLocalTagDragState() {
        draggedTagID = nil
        dropInsertionTargetKey = nil
        localTagDragStartLocation = nil
        isLocalTagDragging = false
    }

    private func editingChip() -> some View {
        TextField("", text: $draftTagName)
            .textFieldStyle(.plain)
            .blocksFont(size: ClipboardFilterBarLayout.tagTextFontSize, weight: .semibold)
            .frame(width: max(72, min(150, CGFloat(max(draftTagName.count, 4)) * 8 + 24)))
            .padding(.horizontal, 9)
            .frame(minHeight: ClipboardFilterBarLayout.chipMinHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(operationErrorMessage == nil ? Color.accentColor.opacity(0.60) : Color.red.opacity(0.72), lineWidth: 1)
            }
            .focused($tagEditorFocused)
            .disabled(activeMutationID != nil)
            .help(operationErrorMessage ?? "")
            .onSubmit {
                commitEditing()
            }
            .onExitCommand {
                cancelEditing()
            }
    }

    private func beginRenaming(_ tag: ClipboardTag) {
        guard !tag.isBuiltIn else {
            return
        }
        editingTagID = tag.id
        draftTagName = tag.localizedDisplayName
        draftInsertAfterTagID = nil
        focusEditor()
    }

    private func beginCreating(afterTagID: String?) {
        editingTagID = Self.newTagDraftID
        draftTagName = L10n.string("clipboard.tags.defaultName")
        draftInsertAfterTagID = afterTagID
        focusEditor()
    }

    private func commitEditing() {
        guard activeMutationID == nil else { return }
        guard let editingTagID else {
            return
        }
        let name = draftTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            focusEditor()
            return
        }
        let mutationID = UUID()
        let insertAfterTagID = draftInsertAfterTagID
        activeMutationID = mutationID
        Task { @MainActor in
            let succeeded: Bool
            if editingTagID == Self.newTagDraftID {
                succeeded = await onCreateTag(name, insertAfterTagID) != nil
            } else {
                succeeded = await onRenameTag(editingTagID, name)
            }
            guard activeMutationID == mutationID else { return }
            activeMutationID = nil
            guard self.editingTagID == editingTagID else { return }
            if succeeded {
                cancelEditing()
            } else {
                focusEditor()
            }
        }
    }

    private func cancelEditing() {
        editingTagID = nil
        draftTagName = ""
        draftInsertAfterTagID = nil
        tagEditorFocused = false
    }

    private func requestDelete(_ tag: ClipboardTag) {
        guard !tag.isBuiltIn else {
            return
        }
        if tagUseCount(tag.id) > 0 {
            pendingDeleteTag = tag
        } else {
            deleteFilterTag(tag)
        }
    }

    private func deleteFilterTag(_ tag: ClipboardTag) {
        guard !tag.isBuiltIn, activeMutationID == nil else {
            return
        }
        let mutationID = UUID()
        activeMutationID = mutationID
        Task { @MainActor in
            _ = await onDeleteTag(tag.id)
            guard activeMutationID == mutationID else { return }
            activeMutationID = nil
        }
    }

    private func submitMove(tagID: String, afterTagID: String?) {
        guard activeMutationID == nil else { return }
        let mutationID = UUID()
        activeMutationID = mutationID
        Task { @MainActor in
            _ = await onMoveTag(tagID, afterTagID)
            guard activeMutationID == mutationID else { return }
            activeMutationID = nil
        }
    }

    private func focusEditor() {
        DispatchQueue.main.async {
            tagEditorFocused = true
        }
    }
}

private struct ClipboardTagDropInsertionIndicator: View {
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: ClipboardFilterBarLayout.chipMinHeight - 6)
            .opacity(isVisible ? 1 : 0)
            .blocksAnimation(.hoverFocus, value: isVisible)
            .accessibilityHidden(true)
    }
}

private struct ClipboardTagFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct ClipboardTagReorderTarget {
    let afterTagID: String?
}
