import Combine
import Foundation
import BlocksCore

private enum ClipboardTagColorPalette {
    static let tokens = ["blue", "green", "purple", "orange", "pink", "gray", "cyan", "mint"]

    static func token(at index: Int) -> String {
        tokens[index % tokens.count]
    }

    static func isValidPaletteToken(_ token: String) -> Bool {
        tokens.contains(token)
    }
}

protocol ClipboardRepositoryMutationExecutor: Sendable {
    func enqueue(_ operation: @escaping @Sendable () -> Void)
}

private struct ClipboardTagRepositoryMutation: Sendable {
    let result: ClipboardTagMutationResult
    let createdTagID: String?
    let panelTagMutation: ClipboardPanelTagMutation?
    let contentRevision: Int64?
    let ensuredCreated: Bool?
    let ensuredAttached: Bool?

    init(
        result: ClipboardTagMutationResult,
        createdTagID: String? = nil,
        panelTagMutation: ClipboardPanelTagMutation? = nil,
        contentRevision: Int64? = nil,
        ensuredCreated: Bool? = nil,
        ensuredAttached: Bool? = nil
    ) {
        self.result = result
        self.createdTagID = createdTagID
        self.panelTagMutation = panelTagMutation
        self.contentRevision = contentRevision
        self.ensuredCreated = ensuredCreated
        self.ensuredAttached = ensuredAttached
    }
}

private struct ClipboardTagRepositorySnapshot: Sendable {
    let tags: [ClipboardTag]
    let recordTags: [String: [ClipboardTag]]
}

private enum ClipboardTagRepositoryMutationOutcome: Sendable {
    case committed(
        revision: UInt64,
        mutation: ClipboardTagRepositoryMutation,
        snapshot: ClipboardTagRepositorySnapshot?
    )
    case failed(revision: UInt64, error: ClipboardTagOperationError)
}

enum ClipboardPanelTagMutation: Equatable, Sendable {
    case attached(recordID: String, tagID: String)
    case detached(recordID: String, tagID: String)
    case createdAndAttached(recordID: String, tagID: String)

    var operation: String {
        switch self {
        case .attached:
            "attached"
        case .detached:
            "detached"
        case .createdAndAttached:
            "created_and_attached"
        }
    }

    var recordID: String {
        switch self {
        case let .attached(recordID, _),
             let .detached(recordID, _),
             let .createdAndAttached(recordID, _):
            recordID
        }
    }

    var tagID: String {
        switch self {
        case let .attached(_, tagID),
             let .detached(_, tagID),
             let .createdAndAttached(_, tagID):
            tagID
        }
    }
}

struct ClipboardPluginEnsureTagAttachment: Sendable {
    let tagID: String
    let created: Bool
    let attached: Bool
    let contentRevision: Int64
}

private final class ClipboardTagMutationPipeline: @unchecked Sendable {
    private let repository: ClipboardRepository
    private let executor: ClipboardRepositoryMutationExecutor
    private let applicationUpdateGate: ApplicationOperationAdmissionGate
    private var operationRevision: UInt64 = 0

    init(
        repository: ClipboardRepository,
        executor: ClipboardRepositoryMutationExecutor,
        applicationUpdateGate: ApplicationOperationAdmissionGate
    ) {
        self.repository = repository
        self.executor = executor
        self.applicationUpdateGate = applicationUpdateGate
    }

    func perform(
        recordIDs: [String],
        operation: @escaping @Sendable (ClipboardTagRepository) throws -> ClipboardTagRepositoryMutation
    ) async -> ClipboardTagRepositoryMutationOutcome {
        guard let lease = applicationUpdateGate.begin() else {
            // Rejected work still receives an ordered outcome, but never
            // touches the repository. The revision is owned by the executor.
            return await withCheckedContinuation { continuation in
                executor.enqueue {
                    self.operationRevision &+= 1
                    continuation.resume(returning: .failed(
                        revision: self.operationRevision,
                        error: .repositoryUnavailable
                    ))
                }
            }
        }
        defer { lease.release() }
        return await withCheckedContinuation { continuation in
            executor.enqueue { [repository] in
                let tagRepository = ClipboardTagRepository(repository: repository)
                self.operationRevision &+= 1
                let revision = self.operationRevision
                do {
                    let mutation = try operation(tagRepository)
                    let snapshot: ClipboardTagRepositorySnapshot?
                    do {
                        snapshot = ClipboardTagRepositorySnapshot(
                            tags: try tagRepository.loadTags(),
                            recordTags: try tagRepository.loadRecordTags(recordIDs: recordIDs)
                        )
                    } catch {
                        // The mutation is already committed. A follow-up read
                        // failure must not be reported as a failed write.
                        snapshot = nil
                    }
                    continuation.resume(returning: .committed(
                        revision: revision,
                        mutation: mutation,
                        snapshot: snapshot
                    ))
                } catch {
                    continuation.resume(returning: .failed(
                        revision: revision,
                        error: ClipboardTagOperationError(error)
                    ))
                }
            }
        }
    }
}

@MainActor
final class ClipboardTagStore: ObservableObject {
    @Published private(set) var tags: [ClipboardTag] = []
    @Published private(set) var recordTags: [String: [ClipboardTag]] = [:]
    @Published var selectedTagID: String?
    @Published private(set) var operationError: ClipboardTagOperationError?
    @Published private(set) var lastMutationResult: ClipboardTagMutationResult?

    private let repository: ClipboardRepository?
    private let mutationPipeline: ClipboardTagMutationPipeline?
    private let applicationUpdateGate: ApplicationOperationAdmissionGate
    private var lastRecordIDs: [String] = []
    private var lastAppliedMutationRevision: UInt64 = 0
    private let normalizer = ClipboardTagNameNormalizer()

    init(
        repository: ClipboardRepository?,
        mutationExecutor: ClipboardRepositoryMutationExecutor? = nil,
        applicationUpdateGate: ApplicationOperationAdmissionGate = ApplicationOperationAdmissionGate(name: "Clipboard tags")
    ) {
        precondition(
            repository == nil || mutationExecutor != nil,
            "Repository-backed clipboard tags require the shared mutation executor."
        )
        self.repository = repository
        self.applicationUpdateGate = applicationUpdateGate
        if let repository, let mutationExecutor {
            self.mutationPipeline = ClipboardTagMutationPipeline(
                repository: repository,
                executor: mutationExecutor,
                applicationUpdateGate: applicationUpdateGate
            )
        } else {
            self.mutationPipeline = nil
        }
        if repository == nil {
            tags = [Self.inMemoryFavoriteTag]
        }
    }

    var tagsForFilter: [ClipboardTag] {
        tags
    }

    var favoriteTag: ClipboardTag? {
        tags.first { $0.builtInKind == .favorite }
    }

    func newTagValidationError(displayName: String) -> ClipboardTagOperationError? {
        do {
            let normalized = try normalizer.validateUserTagName(displayName)
            if tags.contains(where: { $0.normalizedName == normalized.normalizedName }) {
                return .duplicateName
            }
            return nil
        } catch {
            return ClipboardTagOperationError(error)
        }
    }

    func load(recordIDs: [String]) {
        lastRecordIDs = recordIDs
        operationError = nil
        guard let repository else {
            ensureInMemoryFavorite()
            do {
                try repairLoadedTagColorsIfNeeded()
            } catch {
                operationError = ClipboardTagOperationError(error)
            }
            recordTags = recordTags.filter { recordIDs.contains($0.key) }
            return
        }
        _ = repository
        // Repository-backed snapshots are supplied by ClipboardHistoryReadPipeline.
        // A synchronous fallback here would reintroduce database I/O on MainActor.
        operationError = .repositoryUnavailable
    }

    /// Applies data already read by `ClipboardHistoryReadPipeline`.
    /// No repository work is performed on the main actor.
    func applyReadSnapshot(
        tags loadedTags: [ClipboardTag]?,
        recordTags loadedRecordTags: [String: [ClipboardTag]],
        recordIDs: [String],
        replacesRecordTags: Bool
    ) {
        lastRecordIDs = recordIDs
        operationError = nil
        if let loadedTags {
            tags = loadedTags
            pruneSelectedTagIfNeeded()
        }
        if replacesRecordTags {
            recordTags = loadedRecordTags
        } else {
            for (recordID, loadedTags) in loadedRecordTags {
                recordTags[recordID] = loadedTags
            }
        }
        if repository == nil {
            ensureInMemoryFavorite()
        }
    }

    /// Removes a record that has already been durably deleted. This is a
    /// MainActor cache update only; repository deletion remains owned by the
    /// shared mutation queue.
    func removeRecordFromPublishedSnapshot(recordID: String) {
        lastRecordIDs.removeAll { $0 == recordID }
        recordTags.removeValue(forKey: recordID)
    }

    func tags(for recordID: String) -> [ClipboardTag] {
        recordTags[recordID] ?? []
    }

    func isTagged(recordID: String, tagID: String) -> Bool {
        tags(for: recordID).contains { $0.id == tagID }
    }

    func isFavorite(recordID: String) -> Bool {
        guard let favoriteTag else {
            return false
        }
        return isTagged(recordID: recordID, tagID: favoriteTag.id)
    }

    func recordCount(tagID: String) -> Int {
        recordIDs(containing: tagID).count
    }

    func setSelectedTagID(_ tagID: String?) {
        selectedTagID = tagID
    }

    @discardableResult
    func createTag(displayName: String, colorToken: String? = nil) async -> Bool {
        let resolvedColorToken = colorToken ?? nextTagColorToken()
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.createTag(
                        displayName: displayName,
                        colorToken: resolvedColorToken
                    )
                )
            } != nil
        }
        return performInMemory {
            let tag = try createInMemoryTag(displayName: displayName, colorToken: resolvedColorToken)
            return ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: [])
        }
    }

    @discardableResult
    func createFilterTag(
        displayName: String,
        afterTagID: String? = nil,
        colorToken: String? = nil
    ) async -> String? {
        let resolvedColorToken = colorToken ?? nextTagColorToken()
        if repository != nil {
            return await performRepositoryMutation { repository in
                let created = try repository.createTag(
                    displayName: displayName,
                    colorToken: resolvedColorToken
                )
                guard let createdTagID = created.changedTagIDs.first else {
                    return ClipboardTagRepositoryMutation(result: created)
                }
                guard let afterTagID else {
                    return ClipboardTagRepositoryMutation(
                        result: created,
                        createdTagID: createdTagID
                    )
                }
                var orderedIDs = try repository.loadTags()
                    .filter { !$0.isFavorite }
                    .map(\.id)
                orderedIDs.removeAll { $0 == createdTagID }
                if let targetIndex = orderedIDs.firstIndex(of: afterTagID) {
                    orderedIDs.insert(createdTagID, at: min(targetIndex + 1, orderedIDs.count))
                } else {
                    orderedIDs.insert(createdTagID, at: 0)
                }
                let reordered = try repository.reorderTags(
                    tagIDsInDisplayOrder: orderedIDs
                )
                return ClipboardTagRepositoryMutation(
                    result: ClipboardTagMutationResult(
                        changedTagIDs: Array(Set(created.changedTagIDs + reordered.changedTagIDs)),
                        affectedRecordIDs: Array(Set(created.affectedRecordIDs + reordered.affectedRecordIDs))
                    ),
                    createdTagID: createdTagID
                )
            }?.createdTagID
        }
        var createdTagID: String?
        let created = performInMemory {
            let tag = try createInMemoryTag(displayName: displayName, colorToken: resolvedColorToken)
            createdTagID = tag.id
            return ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: [])
        }
        guard created, let createdTagID else { return nil }
        if let afterTagID {
            _ = moveFilterTagInMemory(tagID: createdTagID, afterTagID: afterTagID)
        }
        return createdTagID
    }

    @discardableResult
    func createTagAndAttach(
        displayName: String,
        colorToken: String? = nil,
        recordID: String
    ) async -> Bool {
        await createTagAndAttachReturningID(
            displayName: displayName,
            colorToken: colorToken,
            recordID: recordID
        ) != nil
    }

    func createTagAndAttachReturningID(
        displayName: String,
        colorToken: String? = nil,
        recordID: String
    ) async -> String? {
        let resolvedColorToken = colorToken ?? nextTagColorToken()
        if repository != nil {
            return await performRepositoryMutation { repository in
                let result = try repository.createTagAndAttach(
                    displayName: displayName,
                    colorToken: resolvedColorToken,
                    recordID: recordID
                )
                return ClipboardTagRepositoryMutation(
                    result: result,
                    createdTagID: result.changedTagIDs.first
                )
            }?.createdTagID
        }
        var createdTagID: String?
        let created = performInMemory {
            let tag = try createInMemoryTag(displayName: displayName, colorToken: resolvedColorToken)
            createdTagID = tag.id
            recordTags[recordID, default: []].append(tag)
            return ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: [recordID])
        }
        return created ? createdTagID : nil
    }

    @discardableResult
    func toggleTag(recordID: String, tagID: String) async -> Bool {
        await toggleTagForPanel(recordID: recordID, tagID: tagID) != nil
    }

    func toggleTagForPanel(
        recordID: String,
        tagID: String
    ) async -> ClipboardPanelTagMutation? {
        if repository != nil {
            return await performRepositoryMutation { repository in
                let result = try repository.toggleTag(
                    recordID: recordID,
                    tagID: tagID
                )
                let isAttached = try repository.loadRecordTags(
                    recordIDs: [recordID]
                )[recordID, default: []].contains { $0.id == tagID }
                return ClipboardTagRepositoryMutation(
                    result: result,
                    panelTagMutation: isAttached
                        ? .attached(recordID: recordID, tagID: tagID)
                        : .detached(recordID: recordID, tagID: tagID)
                )
            }?.panelTagMutation
        }
        let changed: Bool
        if isTagged(recordID: recordID, tagID: tagID) {
            changed = await removeTag(recordID: recordID, tagID: tagID)
        } else {
            changed = await addTag(recordID: recordID, tagID: tagID)
        }
        guard changed else { return nil }
        return isTagged(recordID: recordID, tagID: tagID)
            ? .attached(recordID: recordID, tagID: tagID)
            : .detached(recordID: recordID, tagID: tagID)
    }

    func createTagAndAttachForPanel(
        displayName: String,
        colorToken: String? = nil,
        recordID: String
    ) async -> ClipboardPanelTagMutation? {
        let resolvedColorToken = colorToken ?? nextTagColorToken()
        if repository != nil {
            return await performRepositoryMutation { repository in
                let result = try repository.createTagAndAttach(
                    displayName: displayName,
                    colorToken: resolvedColorToken,
                    recordID: recordID
                )
                guard let tagID = result.changedTagIDs.first,
                      try repository.loadRecordTags(
                        recordIDs: [recordID]
                      )[recordID, default: []].contains(where: { $0.id == tagID }) else {
                    throw ClipboardTagMutationError.recordNotFound(recordID)
                }
                return ClipboardTagRepositoryMutation(
                    result: result,
                    createdTagID: tagID,
                    panelTagMutation: .createdAndAttached(
                        recordID: recordID,
                        tagID: tagID
                    )
                )
            }?.panelTagMutation
        }
        guard let tagID = await createTagAndAttachReturningID(
            displayName: displayName,
            colorToken: resolvedColorToken,
            recordID: recordID
        ), isTagged(recordID: recordID, tagID: tagID) else {
            return nil
        }
        return .createdAndAttached(recordID: recordID, tagID: tagID)
    }

    @discardableResult
    func addTag(recordID: String, tagID: String) async -> Bool {
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.addTag(recordID: recordID, tagID: tagID)
                )
            } != nil
        }
        return performInMemory {
            guard let tag = tags.first(where: { $0.id == tagID }) else {
                throw ClipboardTagMutationError.tagNotFound(tagID)
            }
            if !isTagged(recordID: recordID, tagID: tagID) {
                recordTags[recordID, default: []].append(tag)
            }
            return ClipboardTagMutationResult(changedTagIDs: [tagID], affectedRecordIDs: [recordID])
        }
    }

    @discardableResult
    func removeTag(recordID: String, tagID: String) async -> Bool {
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.removeTag(recordID: recordID, tagID: tagID)
                )
            } != nil
        }
        return performInMemory {
            recordTags[recordID] = tags(for: recordID).filter { $0.id != tagID }
            return ClipboardTagMutationResult(changedTagIDs: [tagID], affectedRecordIDs: [recordID])
        }
    }

    func addTagFromPlugin(
        recordID: String,
        tagID: String,
        expectedContentRevision: Int64
    ) async throws -> Int64 {
        try await performPluginTagMutation(
            tagID: tagID,
            expectedContentRevision: expectedContentRevision
        ) { repository in
            try repository.addTag(
                recordID: recordID,
                tagID: tagID,
                expectedContentRevision: expectedContentRevision
            )
        }
    }

    func ensureTagAndAttachFromPlugin(
        recordID: String,
        displayName: String
    ) async throws -> ClipboardPluginEnsureTagAttachment {
        guard let mutationPipeline else {
            throw ClipboardTagOperationError.repositoryUnavailable
        }
        let recordIDs = Array(Set(lastRecordIDs + [recordID]))
        let outcome = await mutationPipeline.perform(recordIDs: recordIDs) { repository in
            let ensured = try repository.ensureTagAndAttach(
                displayName: displayName,
                recordID: recordID
            )
            return ClipboardTagRepositoryMutation(
                result: ensured.mutation,
                createdTagID: ensured.tag.id,
                contentRevision: ensured.tag.contentRevision,
                ensuredCreated: ensured.created,
                ensuredAttached: ensured.attached
            )
        }
        switch outcome {
        case let .committed(revision, mutation, snapshot):
            guard revision > lastAppliedMutationRevision,
                  let tagID = mutation.createdTagID,
                  let contentRevision = mutation.contentRevision,
                  let created = mutation.ensuredCreated,
                  let attached = mutation.ensuredAttached else {
                throw ClipboardTagMutationError.revisionConflict
            }
            lastAppliedMutationRevision = revision
            lastMutationResult = mutation.result
            if let snapshot {
                operationError = nil
                tags = snapshot.tags
                recordTags = snapshot.recordTags
                pruneSelectedTagIfNeeded()
            } else {
                operationError = .repositoryUnavailable
            }
            return ClipboardPluginEnsureTagAttachment(
                tagID: tagID,
                created: created,
                attached: attached,
                contentRevision: contentRevision
            )
        case let .failed(revision, error):
            guard revision > lastAppliedMutationRevision else {
                throw ClipboardTagMutationError.revisionConflict
            }
            lastAppliedMutationRevision = revision
            operationError = error
            throw error
        }
    }

    func removeTagFromPlugin(
        recordID: String,
        tagID: String,
        expectedContentRevision: Int64
    ) async throws -> Int64 {
        try await performPluginTagMutation(
            tagID: tagID,
            expectedContentRevision: expectedContentRevision
        ) { repository in
            try repository.removeTag(
                recordID: recordID,
                tagID: tagID,
                expectedContentRevision: expectedContentRevision
            )
        }
    }

    func setFavoriteFromPlugin(
        recordID: String,
        isFavorite: Bool,
        expectedContentRevision: Int64
    ) async throws -> Int64 {
        try await performPluginTagMutation(
            tagID: ClipboardTagRepository.favoriteTagID,
            expectedContentRevision: expectedContentRevision
        ) { repository in
            try repository.setFavorite(
                recordID: recordID,
                isFavorite: isFavorite,
                expectedContentRevision: expectedContentRevision
            )
        }
    }

    @discardableResult
    func toggleFavorite(recordID: String) async -> Bool {
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.toggleFavorite(recordID: recordID)
                )
            } != nil
        }
        return performInMemory {
            ensureInMemoryFavorite()
            guard let favoriteTag else {
                throw ClipboardTagMutationError.tagNotFound("tag.favorite")
            }
            if isTagged(recordID: recordID, tagID: favoriteTag.id) {
                recordTags[recordID] = tags(for: recordID).filter { $0.id != favoriteTag.id }
            } else {
                recordTags[recordID, default: []].insert(favoriteTag, at: 0)
            }
            return ClipboardTagMutationResult(changedTagIDs: [favoriteTag.id], affectedRecordIDs: [recordID])
        }
    }

    @discardableResult
    func renameTag(tagID: String, displayName: String) async -> Bool {
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.renameTag(
                        tagID: tagID,
                        displayName: displayName
                    )
                )
            } != nil
        }
        return performInMemory {
            let tag = try mutableInMemoryTag(tagID)
            let normalized = try normalizer.validateUserTagName(displayName)
            guard !tags.contains(where: { $0.id != tagID && $0.normalizedName == normalized.normalizedName }) else {
                throw ClipboardTagMutationError.duplicateName
            }
            replaceInMemoryTag(
                tag,
                displayName: normalized.displayName,
                normalizedName: normalized.normalizedName,
                colorToken: tag.colorToken,
                sortOrder: tag.sortOrder
            )
            return ClipboardTagMutationResult(
                changedTagIDs: [tagID],
                affectedRecordIDs: recordIDs(containing: tagID)
            )
        }
    }

    @discardableResult
    func renameFilterTag(tagID: String, displayName: String) async -> Bool {
        await renameTag(tagID: tagID, displayName: displayName)
    }

    func renameFilterTagFromPlugin(
        tagID: String,
        displayName: String,
        expectedContentRevision: Int64
    ) async throws -> Int64 {
        try await performPluginTagMutation(
            tagID: tagID,
            expectedContentRevision: expectedContentRevision
        ) { repository in
            try repository.renameTag(
                tagID: tagID,
                displayName: displayName,
                expectedContentRevision: expectedContentRevision
            )
        }
    }

    @discardableResult
    func updateColor(tagID: String, colorToken: String) async -> Bool {
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.updateTagColor(
                        tagID: tagID,
                        colorToken: colorToken
                    )
                )
            } != nil
        }
        return performInMemory {
            let tag = try mutableInMemoryTag(tagID)
            replaceInMemoryTag(tag, displayName: tag.displayName, normalizedName: tag.normalizedName, colorToken: colorToken, sortOrder: tag.sortOrder)
            return ClipboardTagMutationResult(changedTagIDs: [tagID], affectedRecordIDs: [])
        }
    }

    @discardableResult
    func moveTag(tagID: String, direction: ClipboardTagMoveDirection) async -> Bool {
        guard let index = tags.firstIndex(where: { $0.id == tagID }), !tags[index].isFavorite else {
            operationError = .favoriteImmutable
            return false
        }
        let ordinary = tags.filter { !$0.isFavorite }
        guard let ordinaryIndex = ordinary.firstIndex(where: { $0.id == tagID }) else {
            return false
        }
        let nextIndex = direction == .up ? ordinaryIndex - 1 : ordinaryIndex + 1
        guard ordinary.indices.contains(nextIndex) else {
            return false
        }
        var reordered = ordinary
        reordered.swapAt(ordinaryIndex, nextIndex)
        return await reorderTags(tagIDsInDisplayOrder: reordered.map(\.id))
    }

    @discardableResult
    func reorderTags(tagIDsInDisplayOrder: [String]) async -> Bool {
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.reorderTags(
                        tagIDsInDisplayOrder: tagIDsInDisplayOrder
                    )
                )
            } != nil
        }
        return performInMemory {
            for (index, tagID) in tagIDsInDisplayOrder.enumerated() {
                let tag = try mutableInMemoryTag(tagID)
                replaceInMemoryTag(tag, displayName: tag.displayName, normalizedName: tag.normalizedName, colorToken: tag.colorToken, sortOrder: index + 1)
            }
            return ClipboardTagMutationResult(changedTagIDs: tagIDsInDisplayOrder, affectedRecordIDs: [])
        }
    }

    @discardableResult
    func moveFilterTag(tagID: String, afterTagID: String?) async -> Bool {
        guard let tag = tags.first(where: { $0.id == tagID }), !tag.isFavorite else {
            operationError = .favoriteImmutable
            return false
        }
        var orderedIDs = tags.filter { !$0.isFavorite }.map(\.id)
        guard orderedIDs.contains(tagID) else {
            operationError = .notFound
            return false
        }
        orderedIDs.removeAll { $0 == tagID }
        if let afterTagID, let targetIndex = orderedIDs.firstIndex(of: afterTagID) {
            orderedIDs.insert(tagID, at: min(targetIndex + 1, orderedIDs.count))
        } else {
            orderedIDs.insert(tagID, at: 0)
        }
        return await reorderTags(tagIDsInDisplayOrder: orderedIDs)
    }

    @discardableResult
    func deleteTag(tagID: String) async -> Bool {
        let currentSelectedTagID = selectedTagID
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.deleteTag(
                        tagID: tagID,
                        selectedTagID: currentSelectedTagID
                    )
                )
            } != nil
        }
        return performInMemory {
            let tag = try mutableInMemoryTag(tagID)
            let affected = recordIDs(containing: tag.id)
            tags.removeAll { $0.id == tag.id }
            for recordID in affected {
                recordTags[recordID] = tags(for: recordID).filter { $0.id != tag.id }
            }
            return ClipboardTagMutationResult(
                changedTagIDs: [],
                affectedRecordIDs: affected,
                removedTagIDs: [tag.id],
                selectedTagTransition: selectedTagID == tag.id ? .clear : .none
            )
        }
    }

    @discardableResult
    func deleteFilterTag(tagID: String) async -> Bool {
        await deleteTag(tagID: tagID)
    }

    @discardableResult
    func deleteFilterTagFromPlugin(
        tagID: String,
        expectedContentRevision: Int64
    ) async throws -> Bool {
        guard expectedContentRevision > 0, let mutationPipeline else {
            throw ClipboardTagMutationError.revisionConflict
        }
        let currentSelectedTagID = selectedTagID
        let outcome = await mutationPipeline.perform(recordIDs: lastRecordIDs) { repository in
            ClipboardTagRepositoryMutation(
                result: try repository.deleteTag(
                    tagID: tagID,
                    expectedContentRevision: expectedContentRevision,
                    selectedTagID: currentSelectedTagID
                )
            )
        }
        switch outcome {
        case let .committed(revision, mutation, snapshot):
            guard revision > lastAppliedMutationRevision else { return false }
            lastAppliedMutationRevision = revision
            lastMutationResult = mutation.result
            applySelectionTransition(mutation.result.selectedTagTransition)
            if let snapshot {
                operationError = nil
                tags = snapshot.tags
                recordTags = snapshot.recordTags
                pruneSelectedTagIfNeeded()
            } else {
                operationError = .repositoryUnavailable
            }
            // A committed repository mutation includes search document/FTS work.
            // Search invalidation failures throw and therefore never reach this case.
            return true
        case let .failed(revision, error):
            guard revision > lastAppliedMutationRevision else { return false }
            lastAppliedMutationRevision = revision
            operationError = error
            if error == .revisionConflict {
                throw ClipboardTagMutationError.revisionConflict
            }
            return false
        }
    }

    @discardableResult
    func setScreenshotTagEnabled(_ enabled: Bool) async -> Bool {
        let currentSelectedTagID = selectedTagID
        guard mutationPipeline != nil else {
            operationError = .repositoryUnavailable
            return false
        }
        return await performRepositoryMutation { repository in
            ClipboardTagRepositoryMutation(
                result: try repository.setScreenshotTagEnabled(
                    enabled,
                    selectedTagID: currentSelectedTagID
                )
            )
        } != nil
    }

    @discardableResult
    func mergeTag(sourceTagID: String, targetTagID: String) async -> Bool {
        let currentSelectedTagID = selectedTagID
        if repository != nil {
            return await performRepositoryMutation { repository in
                ClipboardTagRepositoryMutation(
                    result: try repository.mergeTag(
                        sourceTagID: sourceTagID,
                        targetTagID: targetTagID,
                        selectedTagID: currentSelectedTagID
                    )
                )
            } != nil
        }
        return performInMemory {
            guard sourceTagID != targetTagID else {
                throw ClipboardTagMutationError.sourceEqualsTarget
            }
            let source = try mutableInMemoryTag(sourceTagID)
            let target = try mutableInMemoryTag(targetTagID)
            guard !source.isFavorite, !target.isFavorite else {
                throw ClipboardTagMutationError.invalidMergeTarget
            }
            let affected = Array(Set(recordIDs(containing: source.id) + recordIDs(containing: target.id))).sorted()
            for recordID in affected where isTagged(recordID: recordID, tagID: source.id) {
                recordTags[recordID] = tags(for: recordID).filter { $0.id != source.id }
                if !isTagged(recordID: recordID, tagID: target.id) {
                    recordTags[recordID, default: []].append(target)
                }
            }
            tags.removeAll { $0.id == source.id }
            return ClipboardTagMutationResult(
                changedTagIDs: [target.id],
                affectedRecordIDs: affected,
                removedTagIDs: [source.id],
                selectedTagTransition: selectedTagID == source.id ? .switchTo(target.id) : .none
            )
        }
    }

    private func performRepositoryMutation(
        _ operation: @escaping @Sendable (ClipboardTagRepository) throws -> ClipboardTagRepositoryMutation
    ) async -> ClipboardTagRepositoryMutation? {
        guard let mutationPipeline else {
            operationError = .repositoryUnavailable
            return nil
        }
        let outcome = await mutationPipeline.perform(
            recordIDs: lastRecordIDs,
            operation: operation
        )
        switch outcome {
        case let .committed(revision, mutation, snapshot):
            guard revision > lastAppliedMutationRevision else {
                return mutation
            }
            lastAppliedMutationRevision = revision
            lastMutationResult = mutation.result
            applySelectionTransition(mutation.result.selectedTagTransition)
            if let snapshot {
                operationError = nil
                tags = snapshot.tags
                recordTags = snapshot.recordTags
                pruneSelectedTagIfNeeded()
            } else {
                operationError = .repositoryUnavailable
            }
            return mutation
        case let .failed(revision, error):
            guard revision > lastAppliedMutationRevision else { return nil }
            lastAppliedMutationRevision = revision
            operationError = error
            return nil
        }
    }

    private func performPluginTagMutation(
        tagID: String,
        expectedContentRevision: Int64,
        operation: @escaping @Sendable (ClipboardTagRepository) throws -> ClipboardTagMutationResult
    ) async throws -> Int64 {
        guard expectedContentRevision > 0, let mutationPipeline else {
            throw ClipboardTagMutationError.revisionConflict
        }
        let outcome = await mutationPipeline.perform(recordIDs: lastRecordIDs) { repository in
            let result = try operation(repository)
            guard let tag = try repository.loadTags().first(where: { $0.id == tagID }) else {
                throw ClipboardTagMutationError.tagNotFound(tagID)
            }
            return ClipboardTagRepositoryMutation(
                result: result,
                contentRevision: tag.contentRevision
            )
        }
        switch outcome {
        case let .committed(revision, mutation, snapshot):
            guard revision > lastAppliedMutationRevision else {
                throw ClipboardTagMutationError.revisionConflict
            }
            lastAppliedMutationRevision = revision
            lastMutationResult = mutation.result
            if let snapshot {
                operationError = nil
                tags = snapshot.tags
                recordTags = snapshot.recordTags
                pruneSelectedTagIfNeeded()
            } else {
                operationError = .repositoryUnavailable
            }
            guard let contentRevision = mutation.contentRevision else {
                throw ClipboardTagMutationError.tagNotFound(tagID)
            }
            return contentRevision
        case let .failed(revision, error):
            guard revision > lastAppliedMutationRevision else {
                throw ClipboardTagMutationError.revisionConflict
            }
            lastAppliedMutationRevision = revision
            operationError = error
            if error == .revisionConflict {
                throw ClipboardTagMutationError.revisionConflict
            }
            throw error
        }
    }

    private func performInMemory(_ operation: () throws -> ClipboardTagMutationResult) -> Bool {
        guard let lease = applicationUpdateGate.begin() else {
            return false
        }
        defer { lease.release() }
        do {
            let result = try operation()
            lastMutationResult = result
            applySelectionTransition(result.selectedTagTransition)
            load(recordIDs: lastRecordIDs)
            return result.searchInvalidation.succeeded
        } catch {
            operationError = ClipboardTagOperationError(error)
            return false
        }
    }

    private func moveFilterTagInMemory(tagID: String, afterTagID: String?) -> Bool {
        guard let tag = tags.first(where: { $0.id == tagID }), !tag.isFavorite else {
            operationError = .favoriteImmutable
            return false
        }
        var orderedIDs = tags.filter { !$0.isFavorite }.map(\.id)
        guard orderedIDs.contains(tagID) else {
            operationError = .notFound
            return false
        }
        orderedIDs.removeAll { $0 == tagID }
        if let afterTagID, let targetIndex = orderedIDs.firstIndex(of: afterTagID) {
            orderedIDs.insert(tagID, at: min(targetIndex + 1, orderedIDs.count))
        } else {
            orderedIDs.insert(tagID, at: 0)
        }
        return performInMemory {
            for (index, orderedTagID) in orderedIDs.enumerated() {
                let orderedTag = try mutableInMemoryTag(orderedTagID)
                replaceInMemoryTag(
                    orderedTag,
                    displayName: orderedTag.displayName,
                    normalizedName: orderedTag.normalizedName,
                    colorToken: orderedTag.colorToken,
                    sortOrder: index + 1
                )
            }
            return ClipboardTagMutationResult(
                changedTagIDs: orderedIDs,
                affectedRecordIDs: []
            )
        }
    }

    private func applySelectionTransition(_ transition: ClipboardTagSelectionTransition) {
        switch transition {
        case .none:
            break
        case .clear:
            selectedTagID = nil
        case let .switchTo(tagID):
            selectedTagID = tagID
        }
    }

    private func pruneSelectedTagIfNeeded() {
        guard let selectedTagID, !tags.contains(where: { $0.id == selectedTagID }) else {
            return
        }
        self.selectedTagID = nil
    }

    private func nextTagColorToken() -> String {
        let ordinaryTags = tags.filter { !$0.isFavorite }
        let usedTokens = Set(ordinaryTags.map(\.colorToken).filter(ClipboardTagColorPalette.isValidPaletteToken))
        if let unusedToken = ClipboardTagColorPalette.tokens.first(where: { !usedTokens.contains($0) }) {
            return unusedToken
        }
        return ClipboardTagColorPalette.token(at: ordinaryTags.count)
    }

    private func repairLoadedTagColorsIfNeeded() throws {
        let ordinaryTags = tags.filter { !$0.isFavorite }
        var usedTokens = Set(ordinaryTags.map(\.colorToken).filter(ClipboardTagColorPalette.isValidPaletteToken))
        let repairs = ordinaryTags.compactMap { tag -> (tag: ClipboardTag, colorToken: String)? in
            guard !ClipboardTagColorPalette.isValidPaletteToken(tag.colorToken) else {
                return nil
            }
            let nextToken = ClipboardTagColorPalette.tokens.first(where: { !usedTokens.contains($0) })
                ?? ClipboardTagColorPalette.token(at: usedTokens.count)
            usedTokens.insert(nextToken)
            return (tag, nextToken)
        }
        guard !repairs.isEmpty else {
            return
        }
        guard repository == nil else {
            throw ClipboardTagStoreError.repositoryUnavailable
        }
        for repair in repairs {
            replaceInMemoryTag(
                repair.tag,
                displayName: repair.tag.displayName,
                normalizedName: repair.tag.normalizedName,
                colorToken: repair.colorToken,
                sortOrder: repair.tag.sortOrder
            )
        }
    }

    private func createInMemoryTag(displayName: String, colorToken: String) throws -> ClipboardTag {
        let normalized = try normalizer.validateUserTagName(displayName)
        guard !tags.contains(where: { $0.normalizedName == normalized.normalizedName }) else {
            throw ClipboardTagMutationError.duplicateName
        }
        let tag = ClipboardTag(
            id: "tag.\(UUID().uuidString.lowercased())",
            displayName: normalized.displayName,
            normalizedName: normalized.normalizedName,
            colorToken: colorToken,
            sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1,
            builtInKind: .none,
            createdAt: Date(),
            updatedAt: Date()
        )
        tags.append(tag)
        sortInMemoryTags()
        return tag
    }

    private func mutableInMemoryTag(_ tagID: String) throws -> ClipboardTag {
        guard let tag = tags.first(where: { $0.id == tagID }) else {
            throw ClipboardTagMutationError.tagNotFound(tagID)
        }
        guard !tag.isFavorite else {
            throw ClipboardTagMutationError.favoriteImmutable
        }
        return tag
    }

    private func replaceInMemoryTag(
        _ tag: ClipboardTag,
        displayName: String,
        normalizedName: String,
        colorToken: String,
        sortOrder: Int
    ) {
        let replacement = ClipboardTag(
            id: tag.id,
            displayName: displayName,
            normalizedName: normalizedName,
            colorToken: colorToken,
            sortOrder: sortOrder,
            builtInKind: tag.builtInKind,
            createdAt: tag.createdAt,
            updatedAt: Date()
        )
        tags = tags.map { $0.id == tag.id ? replacement : $0 }
        for recordID in recordTags.keys {
            recordTags[recordID] = tags(for: recordID).map { $0.id == tag.id ? replacement : $0 }
        }
        sortInMemoryTags()
    }

    private func recordIDs(containing tagID: String) -> [String] {
        recordTags.compactMap { recordID, tags in
            tags.contains { $0.id == tagID } ? recordID : nil
        }
        .sorted()
    }

    private func ensureInMemoryFavorite() {
        guard !tags.contains(where: { $0.isFavorite }) else {
            return
        }
        tags.insert(Self.inMemoryFavoriteTag, at: 0)
    }

    private func sortInMemoryTags() {
        tags.sort {
            if $0.isFavorite != $1.isFavorite {
                return $0.isFavorite
            }
            if $0.sortOrder == $1.sortOrder {
                return $0.displayName < $1.displayName
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private static let inMemoryFavoriteTag = ClipboardTag(
        id: "tag.favorite",
        displayName: "收藏",
        normalizedName: "favorite",
        colorToken: "favorite",
        sortOrder: 0,
        builtInKind: .favorite,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private enum ClipboardTagStoreError: Error {
    case repositoryUnavailable
}

enum ClipboardTagMoveDirection {
    case up
    case down
}

enum ClipboardTagOperationError: Error, Equatable, Sendable {
    case duplicateName
    case emptyName
    case controlCharacter
    case reservedFavoriteName
    case reservedSystemName
    case favoriteImmutable
    case builtInImmutable
    case systemMembershipImmutable
    case notFound
    case invalidMerge
    case revisionConflict
    case repositoryUnavailable

    init(_ error: Error) {
        if let tagError = error as? ClipboardTagMutationError {
            switch tagError {
            case let .invalidName(nameError):
                switch nameError {
                case .empty:
                    self = .emptyName
                case .controlCharacter:
                    self = .controlCharacter
                case .reservedFavoriteName:
                    self = .reservedFavoriteName
                case .reservedSystemName:
                    self = .reservedSystemName
                }
            case .duplicateName:
                self = .duplicateName
            case .favoriteImmutable:
                self = .favoriteImmutable
            case .builtInImmutable:
                self = .builtInImmutable
            case .systemMembershipImmutable:
                self = .systemMembershipImmutable
            case .sourceEqualsTarget, .invalidMergeTarget:
                self = .invalidMerge
            case .revisionConflict:
                self = .revisionConflict
            case .tagNotFound, .recordNotFound:
                self = .notFound
            }
        } else {
            self = .repositoryUnavailable
        }
    }

    var localizedMessage: String {
        switch self {
        case .duplicateName:
            return L10n.string("clipboard.tags.error.duplicateName")
        case .emptyName:
            return L10n.string("clipboard.tags.error.emptyName")
        case .controlCharacter:
            return L10n.string("clipboard.tags.error.controlCharacter")
        case .reservedFavoriteName:
            return L10n.string("clipboard.tags.error.reservedFavoriteName")
        case .reservedSystemName:
            return L10n.string("clipboard.tags.error.reservedSystemName")
        case .favoriteImmutable:
            return L10n.string("clipboard.tags.error.favoriteImmutable")
        case .builtInImmutable:
            return L10n.string("clipboard.tags.error.builtInImmutable")
        case .systemMembershipImmutable:
            return L10n.string("clipboard.tags.error.systemMembershipImmutable")
        case .notFound:
            return L10n.string("clipboard.tags.error.notFound")
        case .invalidMerge:
            return L10n.string("clipboard.tags.error.invalidMerge")
        case .revisionConflict:
            return L10n.string("clipboard.tags.error.revisionConflict")
        case .repositoryUnavailable:
            return L10n.string("clipboard.tags.error.repositoryUnavailable")
        }
    }
}
