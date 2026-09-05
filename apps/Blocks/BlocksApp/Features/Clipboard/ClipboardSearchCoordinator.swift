import BlocksCore
import Foundation

struct ClipboardSearchStatusPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
}

enum ClipboardSearchCoordinator {
    static func resultSet(
        query: String,
        records: [ClipboardRecorderRecord],
        filterState: ClipboardFilterState,
        recordTags: [String: [ClipboardTag]],
        indexActivity: ClipboardSearchIndexActivity,
        repositoryUnavailable: Bool,
        now: Date = Date()
    ) -> ClipboardSearchResultSet {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .idle(records: applyFilters(
                records,
                filterState: filterState,
                recordTags: recordTags,
                now: now
            ))
        }

        if repositoryUnavailable {
            return ClipboardSearchResultSet(
                query: trimmed,
                records: [],
                state: .failed,
                indexActivity: indexActivity
            )
        }

        let filtered = applyFilters(
            records,
            filterState: filterState,
            recordTags: recordTags,
            now: now
        )
        let state: ClipboardSearchResultState
        if filtered.isEmpty {
            state = indexActivity.hasPendingWork ? .emptyIndexing : .empty
        } else {
            state = indexActivity.hasPendingWork ? .partialIndexing : .results
        }

        return ClipboardSearchResultSet(
            query: trimmed,
            records: filtered,
            state: state,
            indexActivity: indexActivity
        )
    }

    static func applyFilters(
        _ records: [ClipboardRecorderRecord],
        filterState: ClipboardFilterState,
        recordTags: [String: [ClipboardTag]],
        now: Date = Date()
    ) -> [ClipboardRecorderRecord] {
        records.filter { record in
            guard filterState.format.matches(record) else {
                return false
            }
            guard filterState.time.matches(record.lastCopiedAt, now: now) else {
                return false
            }
            if let selectedTagID = filterState.selectedTagID {
                guard recordTags[record.id, default: []].contains(where: { $0.id == selectedTagID }) else {
                    return false
                }
            }
            if let sourceFilterKey = filterState.sourceFilterKey {
                guard sourceFilterKey.matches(record) else {
                    return false
                }
            }
            return true
        }
        .sorted { ClipboardRecordOrdering.isMoreRecent($0, than: $1) }
    }

    static func presentation(
        for resultSet: ClipboardSearchResultSet,
        repositoryUnavailable: Bool,
        recordsAreEmpty: Bool
    ) -> ClipboardSearchStatusPresentation? {
        if repositoryUnavailable {
            return ClipboardSearchStatusPresentation(
                title: L10n.string("clipboard.hardening.state.unavailable.title"),
                detail: L10n.string("clipboard.hardening.state.unavailable.detail"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
        }
        if recordsAreEmpty {
            return ClipboardSearchStatusPresentation(
                title: L10n.string("clipboard.hardening.state.empty.title"),
                detail: L10n.string("clipboard.hardening.state.empty.detail"),
                systemImage: "tray"
            )
        }
        switch resultSet.state {
        case .idle:
            return nil
        case .results:
            return nil
        case .empty:
            return ClipboardSearchStatusPresentation(
                title: L10n.string("clipboard.search.state.empty.title"),
                detail: L10n.string("clipboard.search.state.empty.detail"),
                systemImage: "magnifyingglass"
            )
        case .emptyIndexing:
            return ClipboardSearchStatusPresentation(
                title: L10n.string("clipboard.search.state.emptyIndexing.title"),
                detail: L10n.string("clipboard.search.state.emptyIndexing.detail"),
                systemImage: "clock.badge.questionmark"
            )
        case .partialIndexing:
            return nil
        case .failed:
            return ClipboardSearchStatusPresentation(
                title: L10n.string("clipboard.search.state.failed.title"),
                detail: L10n.string("clipboard.search.state.failed.detail"),
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}
