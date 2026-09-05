import BlocksCore
import Foundation
import OSLog

enum ClipboardDetailPendingNavigationAction: Equatable {
    case close
    case closePanel
    case open(recordID: String)
    case exitEditing
    case performAction
}

struct ClipboardDetailNavigationResolution: Equatable {
    let generation: UInt64
    let recordID: String?
}

private enum ClipboardDetailAuxiliaryOperation: Hashable {
    case metadata
    case fullValue
}

struct ClipboardDetailPipelineHooks: Sendable {
    var beforeSave: @Sendable (String) async -> Void = { _ in }
    var beforeMetadataRead: @Sendable (String) async -> Void = { _ in }
    var beforeFullValueRead: @Sendable (String) async -> Void = { _ in }
}

@MainActor
final class ClipboardDetailStore: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-detail-session"
    )
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-detail-performance"
    )

    private let pipeline: ClipboardDetailPipeline?
    private var onCommittedSave: ((ClipboardDetailSaveResult) async -> Void)?
    private var pendingPanelCloseHandler: (() -> Void)?
    private var pendingActionHandler: (() -> Void)?
    private var documentTask: Task<Void, Never>?
    private var documentGeneration: UInt64 = 0
    private var auxiliaryTasks: [ClipboardDetailAuxiliaryOperation: Task<Void, Never>] = [:]
    private var auxiliaryGenerations: [ClipboardDetailAuxiliaryOperation: UInt64] = [:]

    @Published private(set) var readModel: ClipboardDetailReadModel?
    @Published private(set) var editableKind: ClipboardDetailEditableKind?
    @Published private(set) var status: ClipboardDetailSaveStatus = .view
    @Published private(set) var validationMessage: String?
    @Published private(set) var lastSaveResult: ClipboardDetailSaveResult?
    @Published private(set) var dirtyNavigation = false
    @Published private(set) var pendingNavigationAction: ClipboardDetailPendingNavigationAction?
    @Published private(set) var navigationResolution = ClipboardDetailNavigationResolution(
        generation: 0,
        recordID: nil
    )
    @Published private(set) var expandedFullValueItemID: String?
    @Published private(set) var expandedFullValueText: String?
    @Published private(set) var fullValueFeedback: String?
    @Published private(set) var revealedFullBodyText: String?
    @Published private(set) var isLoadingDocument = false
    @Published private(set) var isSaving = false
    @Published private(set) var isLoadingAuxiliary = false
    @Published var draftTitle = ""
    @Published var draftText = ""

    private var originalDraftTitle = ""
    private var originalDraftText = ""

    init(
        repository: ClipboardRepository?,
        mutationExecutor: ClipboardRepositoryMutationExecutor? = nil,
        pipelineHooks: ClipboardDetailPipelineHooks = ClipboardDetailPipelineHooks(),
        recordCommitGate: ClipboardRecordCommitGate? = nil,
        onCommittedDeletion: @escaping @Sendable ([String]) -> Void = { _ in }
    ) {
        self.pipeline = repository.map {
            ClipboardDetailPipeline(
                repository: $0,
                mutationExecutor: mutationExecutor,
                hooks: pipelineHooks,
                recordCommitGate: recordCommitGate,
                onCommittedDeletion: onCommittedDeletion
            )
        }
    }

    deinit {
        documentTask?.cancel()
        auxiliaryTasks.values.forEach { $0.cancel() }
    }

    func configure(
        onCommittedSave: @escaping (ClipboardDetailSaveResult) async -> Void
    ) {
        self.onCommittedSave = onCommittedSave
    }

    var isBusy: Bool {
        isLoadingDocument || isSaving
    }

    var isPresented: Bool {
        readModel != nil
    }

    var isDirty: Bool {
        draftTitle != originalDraftTitle || draftText != originalDraftText
    }

    var canSave: Bool {
        guard isDirty else {
            return false
        }
        switch status {
        case .dirty, .saveFailed, .dirtyNavigation:
            return true
        default:
            return false
        }
    }

    func open(recordID: String) {
        requestOpen(recordID: recordID)
    }

    func requestOpen(recordID: String) {
        requestNavigation(.open(recordID: recordID))
    }

    func prepare(recordID: String) {
        guard !isDirty else { return }
        loadRecord(recordID: recordID)
    }

    func requestClose() {
        requestNavigation(.close)
    }

    func requestPanelClose(after handler: @escaping () -> Void) {
        pendingPanelCloseHandler = handler
        requestNavigation(.closePanel)
    }

    func requestAction(after handler: @escaping () -> Void) {
        pendingActionHandler = handler
        requestNavigation(.performAction)
    }

    func load(recordID: String) {
        requestOpen(recordID: recordID)
    }

    func refreshPresentedOCRIfNeeded(recordID: String) {
        guard readModel?.recordID == recordID,
              !isDirty else {
            return
        }
        switch status {
        case .view, .readOnly, .saveSuccess, .savedIndexPending, .reindexFailed:
            loadRecord(recordID: recordID)
        default:
            break
        }
    }

    func refreshAfterExternalUpdate(recordID: String) async {
        guard readModel?.recordID == recordID,
              !isDirty,
              !isSaving else {
            return
        }
        let task = loadRecord(recordID: recordID)
        await task?.value
    }

    @discardableResult
    private func loadRecord(recordID: String) -> Task<Void, Never>? {
        cancelAllAuxiliaryOperations(reason: "record-load")
        clearPendingNavigation()
        clearFullValueState()
        if readModel?.recordID != recordID {
            readModel = nil
            editableKind = nil
            clearDrafts()
        }
        guard let pipeline else {
            readModel = nil
            editableKind = nil
            draftTitle = ""
            draftText = ""
            originalDraftTitle = ""
            originalDraftText = ""
            validationMessage = L10n.string("clipboard.detail.error.repositoryUnavailable")
            status = .recordUnavailable
            return nil
        }
        let generation = beginDocumentOperation(stage: "load", recordID: recordID)
        documentTask = Task { [weak self] in
            let signpost = Self.signposter.beginInterval("DetailLoad")
            defer { Self.signposter.endInterval("DetailLoad", signpost) }
            let result = await pipeline.load(recordID: recordID)
            guard let self, self.acceptsDocument(generation) else { return }
            self.finishDocumentOperation(stage: "load", recordID: recordID)
            switch result {
            case let .success(model):
                self.applyLoadedModel(model)
            case let .failure(error):
                Self.logger.error(
                    "failed stage=load generation=\(generation, privacy: .public) record=\(recordID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                self.readModel = nil
                self.editableKind = nil
                self.clearDrafts()
                self.validationMessage = L10n.string("clipboard.detail.error.recordUnavailable")
                self.status = .recordUnavailable
            }
        }
        return documentTask
    }

    func beginEditing() {
        guard let model = readModel else {
            status = .recordUnavailable
            return
        }
        guard let pipeline else {
            status = .recordUnavailable
            return
        }
        let generation = beginDocumentOperation(stage: "begin-edit", recordID: model.recordID)
        documentTask = Task { [weak self] in
            let signpost = Self.signposter.beginInterval("DetailEditLoad")
            defer { Self.signposter.endInterval("DetailEditLoad", signpost) }
            let result = await pipeline.editingSnapshot(for: model)
            guard let self, self.acceptsDocument(generation) else { return }
            self.finishDocumentOperation(stage: "begin-edit", recordID: model.recordID)
            switch result {
            case let .success(snapshot):
                self.editableKind = snapshot.kind
                self.draftTitle = snapshot.title
                self.originalDraftTitle = snapshot.title
                self.draftText = snapshot.text
                self.originalDraftText = snapshot.text
                self.clearPendingNavigation()
                self.dirtyNavigation = false
                self.validationMessage = nil
                self.status = .editClean
            case let .failure(error):
                Self.logger.error(
                    "failed stage=begin-edit generation=\(generation, privacy: .public) record=\(model.recordID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                self.validationMessage = L10n.string("clipboard.detail.error.editableUnavailable")
                self.status = .saveFailed
            }
        }
    }

    func updateDraft(_ value: String) {
        draftText = value
        validateDraft()
    }

    func updateDraftTitle(_ value: String) {
        draftTitle = value
        validateDraft()
    }

    func cancel() {
        guard isDirty else {
            exitEditing()
            return
        }
        requestNavigation(.exitEditing)
    }

    func discardDirtyNavigation() {
        discardChangesAndContinue()
    }

    func close() {
        requestClose()
    }

    func continueEditing() {
        pendingNavigationAction = nil
        pendingPanelCloseHandler = nil
        pendingActionHandler = nil
        dirtyNavigation = false
        validationMessage = nil
        status = isDirty ? .dirty : (readModel == nil ? .view : .editClean)
    }

    func discardChangesAndContinue() {
        // A repository save has already been submitted. Cancelling its task
        // would only hide a completion that may still commit after an await.
        guard !isSaving else {
            return
        }
        let action = pendingNavigationAction ?? .exitEditing
        pendingNavigationAction = nil
        dirtyNavigation = false
        performNavigation(action)
    }

    func saveAndContinue() {
        save()
    }

    private func forceClose() {
        cancelDocumentOperation(reason: "force-close")
        cancelAllAuxiliaryOperations(reason: "force-close")
        readModel = nil
        editableKind = nil
        draftTitle = ""
        draftText = ""
        originalDraftTitle = ""
        originalDraftText = ""
        dirtyNavigation = false
        pendingNavigationAction = nil
        pendingPanelCloseHandler = nil
        pendingActionHandler = nil
        validationMessage = nil
        status = .view
        clearFullValueState()
    }

    func forceCloseForRuntimeDisable() {
        forceClose()
    }

    func save() {
        guard !isSaving else {
            return
        }
        guard let pipeline, let model = readModel else {
            status = .recordUnavailable
            return
        }
        validateDraft()
        guard status != .invalid else {
            return
        }

        guard let kind = editableKind else {
            status = .recordUnavailable
            return
        }
        let titleChanged = draftTitle != originalDraftTitle
        let textChanged = draftText != originalDraftText
        let request = ClipboardDetailSaveRequest(
            model: model,
            kind: kind,
            draftTitle: draftTitle,
            draftText: draftText,
            titleChanged: titleChanged,
            textChanged: textChanged
        )
        status = .saving
        let generation = beginDocumentOperation(stage: "save", recordID: model.recordID)
        let onCommittedSave = self.onCommittedSave
        documentTask = Task { [weak self, onCommittedSave] in
            let signpost = Self.signposter.beginInterval("DetailSave")
            defer { Self.signposter.endInterval("DetailSave", signpost) }
            let result = await pipeline.save(request)
            if case let .success(snapshot) = result,
               let committedResult = snapshot.result {
                // A submitted repository mutation is allowed to settle even
                // when the editor generation changes. Publish the committed
                // fact before applying UI-generation guards so plugins never
                // miss an edit that is already durable.
                await onCommittedSave?(committedResult)
            }
            guard let self, self.acceptsDocument(generation) else { return }
            self.finishDocumentOperation(stage: "save", recordID: model.recordID)
            switch result {
            case let .success(snapshot):
                self.readModel = snapshot.model
                self.lastSaveResult = snapshot.result
                let savedTitle = snapshot.model.titleIsCustom ? snapshot.model.title : ""
                if self.draftTitle == request.draftTitle {
                    self.draftTitle = savedTitle
                }
                self.originalDraftTitle = savedTitle
                self.originalDraftText = request.draftText
                let hasUnsavedChanges = self.isDirty
                self.dirtyNavigation = hasUnsavedChanges && self.pendingNavigationAction != nil
                self.validationMessage = nil
                if hasUnsavedChanges {
                    self.status = self.dirtyNavigation ? .dirtyNavigation : .dirty
                } else {
                    self.status = snapshot.result?.searchIndexState == .completed || snapshot.result == nil
                        ? .saveSuccess
                        : .savedIndexPending
                }
                if !hasUnsavedChanges, let action = self.pendingNavigationAction {
                    self.pendingNavigationAction = nil
                    self.performNavigation(action)
                }
            case let .failure(error):
                Self.logger.error(
                    "failed stage=save generation=\(generation, privacy: .public) record=\(model.recordID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                // The queued navigation was contingent on a successful save.
                // Keep the editor and its error visible when the write fails.
                self.clearPendingNavigation()
                self.dirtyNavigation = false
                self.applySaveFailure(error)
            }
        }
    }

    func revealFullValue(item: ClipboardMetadataItem) {
        expandedFullValueItemID = item.id
        expandedFullValueText = nil
        fullValueFeedback = nil
        guard item.fullValueAvailable,
              item.copyPurpose == .detailFullValueRead,
              let pipeline,
              let model = readModel else {
            fullValueFeedback = L10n.string("clipboard.detail.fullValueUnavailable")
            return
        }
        let generation = beginAuxiliaryOperation(
            .metadata,
            stage: "metadata",
            recordID: model.recordID
        )
        auxiliaryTasks[.metadata] = Task { [weak self] in
            let text = await pipeline.metadataFullValue(
                recordID: model.recordID,
                itemID: item.id,
                purpose: ClipboardPayloadReadPurpose.detailFullValueRead.rawValue
            )
            guard let self, self.acceptsAuxiliary(.metadata, generation: generation) else { return }
            self.finishAuxiliaryOperation(.metadata, stage: "metadata", recordID: model.recordID)
            self.expandedFullValueText = text
            self.fullValueFeedback = text == nil
                ? L10n.string("clipboard.detail.fullValueUnavailable")
                : L10n.string("clipboard.detail.fullValueLoaded")
        }
    }

    func revealFullBodyValue(
        purpose: ClipboardPayloadReadPurpose = .detailFullValueRead
    ) {
        guard let pipeline, let model = readModel else {
            revealedFullBodyText = nil
            return
        }
        let generation = beginAuxiliaryOperation(
            .fullValue,
            stage: "full-value",
            recordID: model.recordID
        )
        auxiliaryTasks[.fullValue] = Task { [weak self] in
            let text = await pipeline.fullValue(model: model, purpose: purpose.rawValue)
            guard let self, self.acceptsAuxiliary(.fullValue, generation: generation) else { return }
            self.finishAuxiliaryOperation(.fullValue, stage: "full-value", recordID: model.recordID)
            self.revealedFullBodyText = text
        }
    }

    func dismissFullValuePresentation() {
        cancelAllAuxiliaryOperations(reason: "full-value-dismissed")
        clearFullValueState()
    }

    private func validateDraft() {
        if editableKind == .url {
            let validation = ClipboardDetailURLValidator().validate(draftText)
            guard case .success = validation else {
                validationMessage = L10n.string("clipboard.detail.error.invalidURL")
                status = .invalid
                return
            }
        }
        validationMessage = nil
        if pendingNavigationAction == nil {
            dirtyNavigation = false
        }
        status = isDirty ? .dirty : .editClean
    }

    private func requestNavigation(_ action: ClipboardDetailPendingNavigationAction) {
        if action != .closePanel {
            pendingPanelCloseHandler = nil
        }
        if action != .performAction {
            pendingActionHandler = nil
        }
        // Once save begins, the repository operation is intentionally allowed
        // to finish even if its task is cancelled. Do not let close/discard
        // invalidate the UI completion and falsely promise that edits were
        // discarded; retain only the newest requested destination instead.
        guard !isSaving else {
            pendingNavigationAction = action
            dirtyNavigation = false
            status = .saving
            validationMessage = nil
            return
        }
        guard isDirty else {
            performNavigation(action)
            return
        }
        pendingNavigationAction = action
        dirtyNavigation = true
        status = .dirtyNavigation
        validationMessage = L10n.string("clipboard.detail.unsaved.message")
    }

    private func performNavigation(_ action: ClipboardDetailPendingNavigationAction) {
        switch action {
        case .close:
            forceClose()
            publishNavigationResolution(recordID: nil)
        case .closePanel:
            let handler = pendingPanelCloseHandler
            pendingPanelCloseHandler = nil
            forceClose()
            publishNavigationResolution(recordID: nil)
            handler?()
        case let .open(recordID):
            publishNavigationResolution(recordID: recordID)
            loadRecord(recordID: recordID)
        case .exitEditing:
            exitEditing()
            publishNavigationResolution(recordID: readModel?.recordID)
        case .performAction:
            let handler = pendingActionHandler
            pendingActionHandler = nil
            forceClose()
            publishNavigationResolution(recordID: nil)
            handler?()
        }
    }

    private func publishNavigationResolution(recordID: String?) {
        navigationResolution = ClipboardDetailNavigationResolution(
            generation: navigationResolution.generation &+ 1,
            recordID: recordID
        )
    }

    private func exitEditing() {
        cancelDocumentOperation(reason: "exit-editing")
        draftTitle = ""
        draftText = ""
        originalDraftTitle = ""
        originalDraftText = ""
        dirtyNavigation = false
        pendingNavigationAction = nil
        pendingPanelCloseHandler = nil
        pendingActionHandler = nil
        validationMessage = nil
        status = readModel == nil ? .view : .view
        clearFullValueState()
    }

    private func clearFullValueState() {
        expandedFullValueItemID = nil
        expandedFullValueText = nil
        fullValueFeedback = nil
        revealedFullBodyText = nil
    }

    private func beginDocumentOperation(stage: String, recordID: String) -> UInt64 {
        if documentTask != nil {
            documentTask?.cancel()
            Self.logger.debug(
                "document-cancel-previous nextStage=\(stage, privacy: .public) generation=\(self.documentGeneration, privacy: .public)"
            )
        }
        documentGeneration &+= 1
        isLoadingDocument = stage != "save"
        isSaving = stage == "save"
        Self.logger.debug(
            "document-begin stage=\(stage, privacy: .public) generation=\(self.documentGeneration) record=\(recordID, privacy: .public)"
        )
        return documentGeneration
    }

    private func acceptsDocument(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == documentGeneration
    }

    private func finishDocumentOperation(stage: String, recordID: String) {
        isLoadingDocument = false
        isSaving = false
        documentTask = nil
        Self.logger.debug(
            "document-finish stage=\(stage, privacy: .public) generation=\(self.documentGeneration) record=\(recordID, privacy: .public)"
        )
    }

    private func cancelDocumentOperation(reason: String) {
        guard documentTask != nil || isBusy else { return }
        documentTask?.cancel()
        documentTask = nil
        documentGeneration &+= 1
        isLoadingDocument = false
        isSaving = false
        Self.logger.info(
            "document-cancel reason=\(reason, privacy: .public) generation=\(self.documentGeneration, privacy: .public)"
        )
    }

    private func beginAuxiliaryOperation(
        _ operation: ClipboardDetailAuxiliaryOperation,
        stage: String,
        recordID: String
    ) -> UInt64 {
        auxiliaryTasks.removeValue(forKey: operation)?.cancel()
        let generation = (auxiliaryGenerations[operation] ?? 0) &+ 1
        auxiliaryGenerations[operation] = generation
        isLoadingAuxiliary = true
        Self.logger.debug(
            "auxiliary-begin stage=\(stage, privacy: .public) generation=\(generation) record=\(recordID, privacy: .public)"
        )
        return generation
    }

    private func acceptsAuxiliary(
        _ operation: ClipboardDetailAuxiliaryOperation,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled && auxiliaryGenerations[operation] == generation
    }

    private func finishAuxiliaryOperation(
        _ operation: ClipboardDetailAuxiliaryOperation,
        stage: String,
        recordID: String
    ) {
        auxiliaryTasks[operation] = nil
        isLoadingAuxiliary = !auxiliaryTasks.isEmpty
        Self.logger.debug(
            "auxiliary-finish stage=\(stage, privacy: .public) generation=\(self.auxiliaryGenerations[operation] ?? 0) record=\(recordID, privacy: .public)"
        )
    }

    private func cancelAllAuxiliaryOperations(reason: String) {
        guard !auxiliaryTasks.isEmpty || isLoadingAuxiliary else { return }
        auxiliaryTasks.values.forEach { $0.cancel() }
        auxiliaryTasks.removeAll()
        for operation in [ClipboardDetailAuxiliaryOperation.metadata, .fullValue] {
            auxiliaryGenerations[operation] = (auxiliaryGenerations[operation] ?? 0) &+ 1
        }
        isLoadingAuxiliary = false
        Self.logger.info("auxiliary-cancel-all reason=\(reason, privacy: .public)")
    }

    private func applyLoadedModel(_ model: ClipboardDetailReadModel) {
        readModel = model
        lastSaveResult = nil
        dirtyNavigation = false
        clearPendingNavigation()
        validationMessage = nil
        clearDrafts()
        switch model.editability {
        case let .editable(kind):
            editableKind = kind
            status = .view
        case let .readOnly(reason):
            editableKind = nil
            validationMessage = reason
            status = .readOnly
        }
    }

    private func clearDrafts() {
        draftTitle = ""
        draftText = ""
        originalDraftTitle = ""
        originalDraftText = ""
    }

    private func clearPendingNavigation() {
        pendingNavigationAction = nil
        pendingPanelCloseHandler = nil
        pendingActionHandler = nil
    }

    private func applySaveFailure(_ error: ClipboardDetailSaveFailure) {
        switch error {
        case .richTextFidelityFailed:
            validationMessage = L10n.string("clipboard.detail.error.richTextFidelity")
            status = .saveFailed
        case .invalidURL:
            validationMessage = L10n.string("clipboard.detail.error.invalidURL")
            status = .invalid
        case .revisionConflict:
            validationMessage = L10n.string("clipboard.detail.error.revisionConflict")
            status = .saveFailed
        case .recordNotFound:
            validationMessage = L10n.string("clipboard.detail.error.recordUnavailable")
            status = .recordUnavailable
        default:
            validationMessage = L10n.string("clipboard.detail.error.saveFailed")
            status = .saveFailed
        }
    }
}

private struct ClipboardDetailEditingSnapshot {
    let kind: ClipboardDetailEditableKind?
    let title: String
    let text: String
}

private struct ClipboardDetailSaveRequest {
    let model: ClipboardDetailReadModel
    let kind: ClipboardDetailEditableKind
    let draftTitle: String
    let draftText: String
    let titleChanged: Bool
    let textChanged: Bool
}

private struct ClipboardDetailSaveSnapshot {
    let model: ClipboardDetailReadModel
    let result: ClipboardDetailSaveResult?
}

private actor ClipboardDetailPipeline {
    private let repository: ClipboardRepository
    private let mutationExecutor: ClipboardRepositoryMutationExecutor?
    private let hooks: ClipboardDetailPipelineHooks
    private let recordCommitGate: ClipboardRecordCommitGate?
    private let onCommittedDeletion: @Sendable ([String]) -> Void

    init(
        repository: ClipboardRepository,
        mutationExecutor: ClipboardRepositoryMutationExecutor?,
        hooks: ClipboardDetailPipelineHooks,
        recordCommitGate: ClipboardRecordCommitGate?,
        onCommittedDeletion: @escaping @Sendable ([String]) -> Void
    ) {
        self.repository = repository
        self.mutationExecutor = mutationExecutor
        self.hooks = hooks
        self.recordCommitGate = recordCommitGate
        self.onCommittedDeletion = onCommittedDeletion
    }

    func load(recordID: String) -> Result<ClipboardDetailReadModel, Error> {
        Result { try repository.loadDetailReadModel(recordID: recordID) }
    }

    func editingSnapshot(
        for model: ClipboardDetailReadModel
    ) -> Result<ClipboardDetailEditingSnapshot, Error> {
        Result {
            let kind: ClipboardDetailEditableKind?
            switch model.editability {
            case let .editable(editableKind):
                kind = editableKind
            case .readOnly:
                kind = nil
            }
            let text: String
            switch kind {
            case .some(.plainText), .some(.richText):
                text = try repository.readDetailEditablePayload(
                    recordID: model.recordID,
                    purpose: ClipboardPayloadReadPurpose.detailEditRead.rawValue
                )?.text ?? ""
            case .some(.url):
                let payload = try repository.readDetailEditablePayload(
                    recordID: model.recordID,
                    purpose: ClipboardPayloadReadPurpose.detailEditRead.rawValue
                )
                text = payload?.urlString ?? payload?.text ?? ""
            case .some(.imageOCRText):
                text = try repository.loadSearchDocument(recordID: model.recordID)?.ocrText ?? ""
            case nil:
                text = ""
            }
            return ClipboardDetailEditingSnapshot(
                kind: kind,
                title: model.titleIsCustom ? model.title : "",
                text: text
            )
        }
    }

    func save(
        _ request: ClipboardDetailSaveRequest
    ) async -> Result<ClipboardDetailSaveSnapshot, ClipboardDetailSaveFailure> {
        await hooks.beforeSave(request.model.recordID)
        let permit = await recordCommitGate?.acquire()
        if recordCommitGate != nil, permit == nil {
            return .failure(.transactionFailed)
        }
        guard !Task.isCancelled else {
            if let permit, let recordCommitGate {
                await recordCommitGate.release(permit)
            }
            return .failure(.transactionFailed)
        }
        let result: Result<ClipboardDetailSaveSnapshot, ClipboardDetailSaveFailure>
        guard let mutationExecutor else {
            result = Self.performSave(
                request,
                repository: repository,
                onCommittedDeletion: onCommittedDeletion
            )
            if let permit, let recordCommitGate {
                await recordCommitGate.release(permit)
            }
            return result
        }
        let onCommittedDeletion = self.onCommittedDeletion
        result = await withCheckedContinuation { continuation in
            mutationExecutor.enqueue { [repository] in
                continuation.resume(
                    returning: Self.performSave(
                        request,
                        repository: repository,
                        onCommittedDeletion: onCommittedDeletion
                    )
                )
            }
        }
        if let permit, let recordCommitGate {
            await recordCommitGate.release(permit)
        }
        return result
    }

    private nonisolated static func performSave(
        _ request: ClipboardDetailSaveRequest,
        repository: ClipboardRepository,
        onCommittedDeletion: @escaping @Sendable ([String]) -> Void
    ) -> Result<ClipboardDetailSaveSnapshot, ClipboardDetailSaveFailure> {
        do {
            let result: ClipboardDetailSaveResult?
            if request.textChanged || request.titleChanged {
                let command = ClipboardDetailEditCommand(
                    recordID: request.model.recordID,
                    expectedContentRevision: request.model.contentRevision,
                    editableKind: request.kind,
                    draft: ClipboardDetailDraft(text: request.draftText),
                    customTitle: request.titleChanged ? request.draftTitle : nil,
                    updatesPayload: request.textChanged,
                    updatesCustomTitle: request.titleChanged,
                    purpose: ClipboardPayloadReadPurpose.detailEditSave.rawValue
                )
                result = try repository.saveDetailEdit(
                    command: command,
                    onCommittedDeletion: onCommittedDeletion
                )
            } else {
                result = nil
            }
            let model = try result?.updatedDetailReadModel
                ?? repository.loadDetailReadModel(recordID: request.model.recordID)
            return .success(ClipboardDetailSaveSnapshot(model: model, result: result))
        } catch let failure as ClipboardDetailSaveFailure {
            return .failure(failure)
        } catch {
            return .failure(.transactionFailed)
        }
    }

    func metadataFullValue(recordID: String, itemID: String, purpose: String) async -> String? {
        await hooks.beforeMetadataRead(recordID)
        return try? repository.readDetailMetadataFullValue(
            recordID: recordID,
            itemID: itemID,
            purpose: purpose
        )
    }

    func fullValue(model: ClipboardDetailReadModel, purpose: String) async -> String? {
        await hooks.beforeFullValueRead(model.recordID)
        switch model.editability {
        case .editable(.imageOCRText), .readOnly:
            return try? repository.loadSearchDocument(recordID: model.recordID)?.ocrText
        case .editable(.url):
            let payload = try? repository.readDetailEditablePayload(
                recordID: model.recordID,
                purpose: purpose
            )
            return payload?.urlString ?? payload?.text
        case .editable(.plainText), .editable(.richText):
            return try? repository.readDetailEditablePayload(
                recordID: model.recordID,
                purpose: purpose
            )?.text
        }
    }
}
