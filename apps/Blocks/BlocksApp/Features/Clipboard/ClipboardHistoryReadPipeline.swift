@preconcurrency import BlocksCore
import Foundation
import os

struct ClipboardHistoryReadRequest {
    let generation: UInt64
    let query: String
    let limit: Int
    let filterState: ClipboardFilterState
    let recordTags: [String: [ClipboardTag]]
    let fallbackRecords: [ClipboardRecorderRecord]
    let repositoryWasUnavailable: Bool
}

struct ClipboardHistoryReadSnapshot {
    let generation: UInt64
    let loadedRecords: [ClipboardRecorderRecord]?
    let previewSnapshots: [String: ClipboardContentPreviewSnapshot]
    let tags: [ClipboardTag]?
    let recordTags: [String: [ClipboardTag]]
    let resultSet: ClipboardSearchResultSet
    let repositoryHistoryExhausted: Bool?
    let repositoryUnavailable: Bool
}

/// Owns every high-frequency clipboard history read used by the floating panel.
///
/// SQLite is already serialized by `SQLiteConnection`; this additional serial
/// queue gives the UI one cancellation/generation boundary and keeps the
/// connection work off `MainActor`.
final class ClipboardHistoryReadPipeline: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-history-read"
    )

    private let repository: ClipboardRepository?
    private let tagRepository: ClipboardTagRepository?
    private let queue = DispatchQueue(
        label: "app.blocks.clipboard.history-read",
        qos: .userInitiated
    )

    init(repository: ClipboardRepository?) {
        self.repository = repository
        self.tagRepository = repository.map(ClipboardTagRepository.init(repository:))
    }

    func read(_ request: ClipboardHistoryReadRequest) async -> ClipboardHistoryReadSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [repository, tagRepository] in
                let interval = Self.signposter.beginInterval("Read")
                defer { Self.signposter.endInterval("Read", interval) }
                continuation.resume(returning: Self.resolve(
                    request,
                    repository: repository,
                    tagRepository: tagRepository
                ))
            }
        }
    }

    private static func resolve(
        _ request: ClipboardHistoryReadRequest,
        repository: ClipboardRepository?,
        tagRepository: ClipboardTagRepository?
    ) -> ClipboardHistoryReadSnapshot {
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLimit = max(1, request.limit)

        guard let repository else {
            return ClipboardHistoryReadSnapshot(
                generation: request.generation,
                loadedRecords: trimmed.isEmpty ? request.fallbackRecords : nil,
                previewSnapshots: [:],
                tags: nil,
                recordTags: request.recordTags,
                resultSet: ClipboardSearchCoordinator.resultSet(
                    query: trimmed,
                    records: request.fallbackRecords,
                    filterState: request.filterState,
                    recordTags: request.recordTags,
                    indexActivity: ClipboardSearchIndexActivity(),
                    repositoryUnavailable: request.repositoryWasUnavailable
                ),
                repositoryHistoryExhausted: trimmed.isEmpty
                    ? request.fallbackRecords.count < safeLimit
                    : nil,
                repositoryUnavailable: request.repositoryWasUnavailable
            )
        }

        do {
            let sourceRecords: [ClipboardRecorderRecord]
            let indexActivity: ClipboardSearchIndexActivity
            let loadedRecords: [ClipboardRecorderRecord]?
            let historyExhausted: Bool?
            let loadedRecordTags: [String: [ClipboardTag]]

            if trimmed.isEmpty {
                let recent = try repository.loadRecent(limit: safeLimit)
                sourceRecords = recent
                loadedRecords = recent
                historyExhausted = recent.count < safeLimit
                indexActivity = ClipboardSearchIndexActivity()
                loadedRecordTags = try tagRepository?.loadRecordTags(
                    recordIDs: recent.map(\.id)
                ) ?? [:]
            } else {
                let result = try searchRepository(
                    repository,
                    tagRepository: tagRepository,
                    query: trimmed,
                    visibleLimit: safeLimit,
                    filterState: request.filterState
                )
                sourceRecords = result.records
                loadedRecords = nil
                historyExhausted = nil
                indexActivity = result.indexActivity
                loadedRecordTags = result.recordTags
            }

            var mergedRecordTags = request.recordTags
            for (recordID, tags) in loadedRecordTags {
                mergedRecordTags[recordID] = tags
            }
            let tags = trimmed.isEmpty ? try tagRepository?.loadTags() : nil
            let filtered = ClipboardSearchCoordinator.applyFilters(
                sourceRecords,
                filterState: request.filterState,
                recordTags: mergedRecordTags
            )
            let limited = Array(filtered.prefix(safeLimit))
            let previews = try repository.loadPreviewSnapshots(
                recordIDs: limited.map(\.id)
            )
            let state: ClipboardSearchResultState
            if trimmed.isEmpty {
                state = .idle
            } else if limited.isEmpty {
                state = indexActivity.hasPendingWork ? .emptyIndexing : .empty
            } else {
                state = indexActivity.hasPendingWork ? .partialIndexing : .results
            }

            return ClipboardHistoryReadSnapshot(
                generation: request.generation,
                loadedRecords: loadedRecords,
                previewSnapshots: previews,
                tags: tags,
                recordTags: loadedRecordTags,
                resultSet: ClipboardSearchResultSet(
                    query: trimmed,
                    records: limited,
                    state: state,
                    indexActivity: indexActivity
                ),
                repositoryHistoryExhausted: historyExhausted,
                repositoryUnavailable: false
            )
        } catch {
            return ClipboardHistoryReadSnapshot(
                generation: request.generation,
                loadedRecords: nil,
                previewSnapshots: [:],
                tags: nil,
                recordTags: [:],
                resultSet: ClipboardSearchResultSet(
                    query: trimmed,
                    records: [],
                    state: .failed,
                    indexActivity: ClipboardSearchIndexActivity()
                ),
                repositoryHistoryExhausted: nil,
                repositoryUnavailable: true
            )
        }
    }

    private static func searchRepository(
        _ repository: ClipboardRepository,
        tagRepository: ClipboardTagRepository?,
        query: String,
        visibleLimit: Int,
        filterState: ClipboardFilterState
    ) throws -> (
        records: [ClipboardRecorderRecord],
        recordTags: [String: [ClipboardTag]],
        indexActivity: ClipboardSearchIndexActivity
    ) {
        let now = Date()
        let result = try repository.searchDocuments(
            query: query,
            limit: visibleLimit,
            filteringBatch: { candidates in
                let candidateTags = filterState.selectedTagID == nil ? [:]
                    : try tagRepository?.loadRecordTags(recordIDs: candidates.map(\.id)) ?? [:]
                return ClipboardSearchCoordinator.applyFilters(
                    candidates,
                    filterState: filterState,
                    recordTags: candidateTags,
                    now: now
                )
            }
        )
        let recordTags = try tagRepository?.loadRecordTags(recordIDs: result.records.map(\.id)) ?? [:]
        return (result.records, recordTags, result.indexActivity)
    }
}
