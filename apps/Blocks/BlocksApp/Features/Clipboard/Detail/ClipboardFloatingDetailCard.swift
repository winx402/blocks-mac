import AppKit
import BlocksCore
import SwiftUI

enum ClipboardDetailEditingPolicy {
    static func canBegin(
        currentRecordID: String,
        loadedRecordID: String?,
        isEditing: Bool,
        isBusy: Bool,
        editableKind: ClipboardDetailEditableKind?,
        requiredKind: ClipboardDetailEditableKind?
    ) -> Bool {
        guard !isEditing,
              !isBusy,
              loadedRecordID == currentRecordID,
              let editableKind else {
            return false
        }
        if let requiredKind {
            return editableKind == requiredKind
        }
        return editableKind != .imageOCRText
    }
}

struct ClipboardFloatingDetailCard: View {
    let record: ClipboardRecorderRecord
    let preview: ClipboardRecordPreview
    let clipboardStore: ClipboardStore
    @ObservedObject var detailStore: ClipboardDetailStore
    @ObservedObject var focusCoordinator: ClipboardPanelFocusCoordinator
    let itemFontSize: CGFloat
    let pluginManager: BlocksNativePluginManager?
    let pluginRuntime: BlocksPluginRuntimeCoordinator?
    @State private var detailPreviewImage: CGImage?
    @State private var detailPreviewFailure: ClipboardPayloadReadFailure?
    @State private var detailPreviewTask: Task<Void, Never>?
    @State private var fullDetailText: String?
    @State private var fullValueTarget: FullValueTarget?
    @FocusState private var detailEditorFocused: Bool

    private let fixedDetailInputHeight: CGFloat = 168
    private let fixedDetailOCRInputHeight: CGFloat = 128

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                detailHeader

                if record.kind == .image {
                    imageDetailContent
                    ocrDetailContent
                } else {
                    nonImageDetailContent
                }

                if let model = detailStore.readModel {
                    detailMetadataGrid(model.metadata)
                } else {
                    fallbackMetadata
                }

                if let pluginManager, let pluginRuntime {
                    BlocksPluginUISlotHost(
                        manager: pluginManager,
                        runtime: pluginRuntime,
                        slot: .clipboardDetailSection,
                        context: [
                            "record_id": .string(record.id),
                            "record_kind": .string(record.kind.rawValue)
                        ],
                        protectedContext: [
                            "record_summary": .string(record.summary)
                        ],
                        requiredDataPermission: .clipboardContent
                    )
                }

                Label(
                    record.restorable ? L10n.string("clipboard.panel.doubleClickPasteHint") : L10n.string("clipboard.panel.restoreUnavailable"),
                    systemImage: record.restorable ? "cursorarrow.click.2" : "lock.shield"
                )
                .blocksFont(size: footerFontSize)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .blocksSurface(
            .panel,
            cornerRadius: BlocksVisualTokens.CornerRadius.section
        )
        .onAppear {
            loadSurfaceState()
        }
        .onChange(of: record.id) { _, _ in
            detailPreviewTask?.cancel()
            detailPreviewImage = nil
            detailPreviewFailure = nil
            fullDetailText = nil
            fullValueTarget = nil
            loadSurfaceState()
        }
        .onChange(of: detailStore.status) { _, status in
            if status == .editClean {
                focusCoordinator.beginDetailEditing(recordID: record.id)
                detailEditorFocused = true
                reportDetailEditorFocus()
            }
            if status == .saveSuccess || status == .savedIndexPending {
                detailEditorFocused = false
                fullDetailText = nil
                fullValueTarget = nil
            }
        }
        .onChange(of: isEditing) { wasEditing, isEditing in
            guard wasEditing, !isEditing else {
                return
            }
            detailEditorFocused = false
            Task { @MainActor in
                await Task.yield()
                focusCoordinator.finishDetailEditing(recordID: record.id)
            }
        }
        .onChange(of: focusCoordinator.generation) { _, _ in
            detailEditorFocused = focusCoordinator.target == .detailEdit(recordID: record.id)
            if detailEditorFocused {
                reportDetailEditorFocus()
            }
        }
        .onChange(of: detailStore.readModel?.updatedAt) { _, _ in
            guard !isEditing else {
                return
            }
            fullDetailText = nil
            fullValueTarget = nil
        }
        .onChange(of: detailStore.revealedFullBodyText) { _, text in
            fullDetailText = text
        }
        .onDisappear {
            detailPreviewTask?.cancel()
            detailPreviewTask = nil
            detailEditorFocused = false
            fullValueTarget = nil
            detailStore.dismissFullValuePresentation()
        }
        .popover(isPresented: fullValuePopoverPresented, arrowEdge: .trailing) {
            fullValuePopover
        }
        .confirmationDialog(
            L10n.string("clipboard.detail.unsaved.title"),
            isPresented: dirtyNavigationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("clipboard.detail.saveAndContinue")) {
                detailStore.saveAndContinue()
            }
            Button(L10n.string("clipboard.detail.discardChanges"), role: .destructive) {
                detailStore.discardChangesAndContinue()
            }
            Button(L10n.string("clipboard.detail.continueEditing"), role: .cancel) {
                detailStore.continueEditing()
            }
        } message: {
            Text(L10n.string("clipboard.detail.unsaved.confirmationMessage"))
        }
    }

    @ViewBuilder
    private var imageDetailContent: some View {
        if let image = detailPreviewImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(minHeight: 132, maxHeight: 228)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.control,
                        style: .continuous
                    )
                )
                .background {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.control,
                        style: .continuous
                    )
                        .fill(Color.black.opacity(0.14))
                }
        } else {
            detailTextBlock(detailPreviewFailure == nil ? L10n.string("clipboard.detail.loading") : unavailableDetailText)
                .frame(minHeight: 132, maxHeight: 228, alignment: .topLeading)
        }
    }

    private var ocrDetailContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.string("clipboard.detail.ocr"), systemImage: "text.viewfinder")
                .blocksFont(size: detailFontSize, weight: .semibold)
                .foregroundStyle(.secondary)

            detailInputBox(
                text: ocrDisplayText,
                height: fixedDetailOCRInputHeight,
                requiresEditableKind: .imageOCRText,
                offersFullValue: detailStore.editableKind == .imageOCRText
            )
        }
    }

    private var nonImageDetailContent: some View {
        detailInputBox(
            text: detailPreviewDisplayText,
            height: fixedDetailInputHeight,
            requiresEditableKind: nil,
            offersFullValue: detailStore.editableKind != nil
        )
    }

    private func contentEditContainer<Content: View>(
        requiresEditableKind: ClipboardDetailEditableKind? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: BlocksVisualTokens.CornerRadius.control,
                    style: .continuous
                )
            )
            .onTapGesture {
                beginFloatingEdit(requiresEditableKind: requiresEditableKind)
            }
    }

    private func detailInputBox(
        text: String,
        height: CGFloat,
        requiresEditableKind: ClipboardDetailEditableKind?,
        offersFullValue: Bool
    ) -> some View {
        let editingThisInput = isEditing(requiresEditableKind: requiresEditableKind)
        return contentEditContainer(requiresEditableKind: requiresEditableKind) {
            ZStack(alignment: .topLeading) {
                if editingThisInput {
                    detailTextEditor
                        .padding(.bottom, 24)
                } else {
                    detailTextBlock(text)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.control,
                isActive: editingThisInput
            )
            .blocksInteractionChrome(editingThisInput ? .focused : .idle)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !editingThisInput, offersFullValue {
                    BlocksCompactIconButton(
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        label: L10n.string("clipboard.detail.showFullValue"),
                        density: .micro,
                        action: presentFullBodyValue
                    )
                    .accessibilityHint(L10n.string("clipboard.detail.showFullValue.accessibilityHint"))
                    .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if editingThisInput {
                    HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                        Text(detailStore.validationMessage ?? "")
                            .blocksFont(size: footerFontSize)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(detailStore.validationMessage ?? "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(detailStore.validationMessage == nil ? 0 : 1)
                            .accessibilityHidden(detailStore.validationMessage == nil)

                        floatingDetailActionBar
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 7)
                }
            }
        }
    }

    private var detailTextEditor: some View {
        TextEditor(text: Binding(
            get: { detailStore.draftText },
            set: { detailStore.updateDraft($0) }
        ))
        .blocksFont(size: itemFontSize)
        .focused($detailEditorFocused)
        .accessibilityLabel(
            L10n.string(
                detailStore.editableKind == .imageOCRText
                    ? "clipboard.detail.ocrEditor.accessibilityLabel"
                    : "clipboard.detail.editor.accessibilityLabel"
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func detailTextBlock(_ text: String) -> some View {
        Text(text)
            .blocksFont(size: itemFontSize)
            .foregroundStyle(.primary)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var floatingDetailActionBar: some View {
        BlocksCompactActionGroup(density: .micro) {
            BlocksCompactIconButton(
                systemImage: "xmark",
                label: L10n.string("common.cancel"),
                density: .micro,
                action: cancelFloatingEdit
            )

            BlocksCompactIconButton(
                systemImage: "checkmark",
                label: L10n.string("common.save"),
                isEnabled: detailStore.canSave,
                isLoading: detailStore.isSaving,
                emphasis: .accent,
                density: .micro,
                action: detailStore.save
            )
        }
    }

    private var detailHeader: some View {
        BlocksPanelChrome {
            if isEditing {
                TextField(L10n.string("clipboard.detail.title"), text: Binding(
                    get: { detailStore.draftTitle },
                    set: { detailStore.updateDraftTitle($0) }
                ))
                .blocksFont(size: 13, weight: .semibold)
                .textFieldStyle(.plain)
            } else {
                Text(detailDisplayTitle)
                    .blocksFont(size: 13, weight: .semibold)
                    .lineLimit(1)
            }
        } actions: {
            Text(record.lastCopiedAt.formatted(date: .omitted, time: .shortened))
                .blocksFont(size: footerFontSize)
                .foregroundStyle(.secondary)

            let canEdit = canBeginEditing(requiresEditableKind: nil)
            let showsEditProgress = detailStore.isLoadingDocument && !isEditing
            BlocksCompactIconButton(
                systemImage: "pencil",
                label: L10n.string("clipboard.detail.edit"),
                isEnabled: canEdit,
                isLoading: showsEditProgress,
                density: .micro
            ) {
                beginFloatingEdit(requiresEditableKind: nil)
            }
            .opacity(canEdit || showsEditProgress ? 1 : 0)
            .allowsHitTesting(canEdit)
            .accessibilityHidden(!canEdit && !showsEditProgress)
        }
    }

    private var fallbackMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailLine(L10n.string("clipboard.detail.kind"), record.kind.localizedTitle)
            detailLine(L10n.string("clipboard.detail.source"), record.sourceDisplayName)
            detailLine(L10n.string("clipboard.detail.items"), "\(record.formatSummary.itemCount)")
            detailLine(L10n.string("clipboard.detail.types"), summarizedTypes, monospaced: true)
            detailLine(L10n.string("clipboard.detail.hash"), record.signatureSHA256_12, monospaced: true)
        }
    }

    private func detailMetadataGrid(_ metadata: ClipboardMetadataSnapshot) -> some View {
        let shortMetadataItems = metadata.items.filter { item in item.category != .long }
        let longMetadataItems = metadata.items.filter { item in item.category == .long }

        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(shortMetadataItems) { item in
                    metadataItem(item)
                }
            }

            ForEach(longMetadataItems) { item in
                metadataItem(item)
            }
        }
    }

    private func metadataItem(_ item: ClipboardMetadataItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metadataTitle(item))
                .blocksFont(size: 9, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                metadataValueView(item)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.fullValueAvailable,
                   item.copyPurpose == .detailFullValueRead {
                    BlocksCompactIconButton(
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        label: L10n.format(
                            "clipboard.detail.fullValue.accessibilityLabel",
                            metadataTitle(item)
                        ),
                        density: .micro
                    ) {
                        presentFullMetadataValue(item)
                    }
                    .accessibilityHint(L10n.string("clipboard.detail.showFullValue.accessibilityHint"))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blocksSurface(
            .interactive,
            cornerRadius: BlocksVisualTokens.CornerRadius.control
        )
        .accessibilityElement(children: .contain)
    }

    private func metadataValueView(_ item: ClipboardMetadataItem) -> some View {
        Text(metadataValue(item))
            .blocksFont(size: detailFontSize)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(fullMetadataValue(for: item))
    }

    private var detailPreviewDisplayText: String {
        if let direct = detailStore.readModel?.boundedPreview.body {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let previewText = preview.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previewText.isEmpty {
            return previewText
        }
        if detailPreviewFailure != nil {
            return unavailableDetailText
        }
        return L10n.string("clipboard.detail.loading")
    }

    private var detailDisplayTitle: String {
        if let model = detailStore.readModel, model.titleIsCustom {
            return model.title
        }
        return record.kind.localizedTitle
    }

    private var unavailableDetailText: String {
        if let skipReason = ClipboardCaptureSkipReason(summaryCode: record.summary) {
            return skipReason.localizedPreviewBody
        }
        return L10n.string("clipboard.detail.unavailable")
    }

    private var ocrDisplayText: String {
        if let text = fullDetailText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let text = detailStore.readModel?.boundedPreview.body.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let validationMessage = detailStore.validationMessage {
            return validationMessage
        }
        return L10n.string("clipboard.detail.ocr.pending")
    }

    private func loadDetailPreview() {
        detailPreviewTask?.cancel()
        let recordID = record.id
        detailPreviewTask = Task { @MainActor in
            let result = await clipboardStore.readDetailPreview(recordID: recordID)
            guard !Task.isCancelled, record.id == recordID else { return }
            detailPreviewImage = result.thumbnailImage
            detailPreviewFailure = result.failure
            detailPreviewTask = nil
        }
    }

    private func loadSurfaceState() {
        if record.kind == .image {
            loadDetailPreview()
        }
        fullDetailText = nil
        fullValueTarget = nil
    }

    private func presentFullBodyValue() {
        fullDetailText = nil
        fullValueTarget = .body
        detailStore.revealFullBodyValue()
    }

    private func presentFullMetadataValue(_ item: ClipboardMetadataItem) {
        fullValueTarget = .metadata(itemID: item.id, title: metadataTitle(item))
        detailStore.revealFullValue(item: item)
    }

    private var fullValuePopoverPresented: Binding<Bool> {
        Binding(
            get: { fullValueTarget != nil },
            set: { presented in
                guard !presented else { return }
                fullValueTarget = nil
                detailStore.dismissFullValuePresentation()
            }
        )
    }

    @ViewBuilder
    private var fullValuePopover: some View {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.sm) {
            Text(fullValuePopoverTitle)
                .blocksFont(size: 13, weight: .semibold)

            if let value = fullValuePopoverText, !value.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(value)
                        .blocksFont(size: detailFontSize)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if detailStore.isLoadingAuxiliary {
                HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("clipboard.detail.loading"))
                        .blocksFont(size: detailFontSize)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(detailStore.fullValueFeedback ?? L10n.string("clipboard.detail.fullValueUnavailable"))
                    .blocksFont(size: detailFontSize)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(BlocksVisualTokens.Spacing.md)
        .frame(width: 420, height: 240, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var fullValuePopoverTitle: String {
        switch fullValueTarget {
        case .some(.body), .none:
            return L10n.string("clipboard.detail.showFullValue")
        case let .some(.metadata(_, title)):
            return title
        }
    }

    private var fullValuePopoverText: String? {
        switch fullValueTarget {
        case .some(.body):
            return detailStore.revealedFullBodyText
        case let .some(.metadata(itemID, _)):
            guard detailStore.expandedFullValueItemID == itemID else {
                return nil
            }
            return detailStore.expandedFullValueText
        case .none:
            return nil
        }
    }

    private func canBeginEditing(requiresEditableKind: ClipboardDetailEditableKind?) -> Bool {
        ClipboardDetailEditingPolicy.canBegin(
            currentRecordID: record.id,
            loadedRecordID: detailStore.readModel?.recordID,
            isEditing: isEditing,
            isBusy: detailStore.isBusy,
            editableKind: detailStore.editableKind,
            requiredKind: requiresEditableKind
        )
    }

    private func beginFloatingEdit(requiresEditableKind: ClipboardDetailEditableKind?) {
        guard canBeginEditing(requiresEditableKind: requiresEditableKind) else {
            return
        }
        detailStore.beginEditing()
        detailEditorFocused = false
    }

    private func reportDetailEditorFocus() {
        let requestedGeneration = focusCoordinator.generation
        Task { @MainActor in
            await Task.yield()
            focusCoordinator.reportEndpointResult(
                surface: .detail,
                expectedTarget: .detailEdit(recordID: record.id),
                generation: requestedGeneration,
                applied: focusCoordinator.accepts(generation: requestedGeneration)
                    && focusCoordinator.target == .detailEdit(recordID: record.id)
                    && detailEditorFocused,
                failureReason: detailEditorFocused ? nil : "swiftui-detail-focus-rejected"
            )
        }
    }

    private func cancelFloatingEdit() {
        detailStore.cancel()
        if detailStore.dirtyNavigation {
            detailStore.discardDirtyNavigation()
        }
    }

    private var dirtyNavigationConfirmationPresented: Binding<Bool> {
        Binding(
            get: { detailStore.dirtyNavigation },
            set: { presented in
                if !presented, detailStore.dirtyNavigation {
                    detailStore.continueEditing()
                }
            }
        )
    }

    private func isEditing(requiresEditableKind: ClipboardDetailEditableKind?) -> Bool {
        guard isEditing else {
            return false
        }
        if let requiresEditableKind {
            return detailStore.editableKind == requiresEditableKind
        }
        return detailStore.editableKind != .imageOCRText
    }

    private var isEditing: Bool {
        switch detailStore.status {
        case .editClean, .dirty, .invalid, .saving, .saveFailed, .dirtyNavigation:
            true
        default:
            false
        }
    }

    private var detailFontSize: CGFloat {
        11
    }

    private var footerFontSize: CGFloat {
        10
    }

    private var summarizedTypes: String {
        let types = record.formatSummary.types
        guard !types.isEmpty else {
            return L10n.string("clipboard.detail.none")
        }
        let prefix = types.prefix(4).joined(separator: ", ")
        guard types.count > 4 else {
            return prefix
        }
        return L10n.format("clipboard.detail.moreTypes", prefix, types.count - 4)
    }

    private func detailLine(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .fontDesign(monospaced ? .monospaced : .default)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .blocksFont(size: detailFontSize)
    }

    private func metadataTitle(_ item: ClipboardMetadataItem) -> String {
        guard let titleKey = item.titleKey else {
            return item.title
        }
        return L10n.string(titleKey)
    }

    private func metadataValue(_ item: ClipboardMetadataItem) -> String {
        switch item.id {
        case "kind":
            return ClipboardRecorderItemKind(rawValue: item.boundedValue)?.localizedTitle ?? item.boundedValue
        case "ocr":
            return localizedOCRValue(item.boundedValue)
        case "privacy":
            return localizedPrivacyValue(item.boundedValue)
        case "sourceConfidence":
            return localizedSourceConfidenceValue(item.boundedValue)
        default:
            return item.boundedValue
        }
    }

    private func fullMetadataValue(for item: ClipboardMetadataItem) -> String {
        if detailStore.expandedFullValueItemID == item.id,
           let value = detailStore.expandedFullValueText {
            return value
        }
        return metadataValue(item)
    }

    private func localizedOCRValue(_ value: String) -> String {
        let parts = value.components(separatedBy: " / ")
        let state = localizedOCRState(parts.first ?? value)
        guard parts.count > 1 else {
            return state
        }
        return L10n.format("clipboard.detail.ocrWithSource", state, localizedOCRSource(parts[1]))
    }

    private func localizedOCRState(_ value: String) -> String {
        switch value {
        case "notRequired":
            L10n.string("clipboard.detail.ocr.notRequired")
        case "pending":
            L10n.string("clipboard.detail.ocr.pending")
        case "running":
            L10n.string("clipboard.detail.ocr.running")
        case "succeeded":
            L10n.string("clipboard.detail.ocr.succeeded")
        case "failed":
            L10n.string("clipboard.detail.ocr.failed")
        default:
            value
        }
    }

    private func localizedOCRSource(_ value: String) -> String {
        switch value {
        case "vision":
            L10n.string("clipboard.detail.ocr.source.vision")
        case "userEdited":
            L10n.string("clipboard.detail.ocr.source.userEdited")
        case "none":
            L10n.string("clipboard.detail.ocr.source.none")
        default:
            value
        }
    }

    private func localizedPrivacyValue(_ value: String) -> String {
        switch value {
        case "Excluded":
            L10n.string("clipboard.detail.privacy.excluded")
        case "Snapshot skipped":
            L10n.string("clipboard.detail.privacy.snapshotSkipped")
        case "Not restorable":
            L10n.string("clipboard.detail.privacy.notRestorable")
        case "Allowed":
            L10n.string("clipboard.detail.privacy.allowed")
        default:
            value
        }
    }

    private func localizedSourceConfidenceValue(_ value: String) -> String {
        switch value {
        case "Best effort":
            L10n.string("clipboard.detail.sourceConfidence.bestEffort")
        case "Verified":
            L10n.string("clipboard.detail.sourceConfidence.verified")
        default:
            value
        }
    }

    private func flagBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .blocksFont(size: footerFontSize, weight: .medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.pill
            )
    }

    private enum FullValueTarget: Equatable {
        case body
        case metadata(itemID: String, title: String)
    }
}
