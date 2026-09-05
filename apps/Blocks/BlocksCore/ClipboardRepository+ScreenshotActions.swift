import Foundation

public struct ScreenshotHistoryCursorKey: Equatable, Sendable {
    public let lastCopiedAt: Date
    public let createdAt: Date
    public let changeCount: Int
    public let recordID: String

    public init(lastCopiedAt: Date, createdAt: Date, changeCount: Int, recordID: String) {
        self.lastCopiedAt = lastCopiedAt
        self.createdAt = createdAt
        self.changeCount = changeCount
        self.recordID = recordID
    }
}

public enum ScreenshotHistoryRepositoryActionError: Error, Equatable {
    case recordNotFound
    case notImage
    case ocrLocked
    case alreadyRunning
    case retryRejected
}

extension ClipboardRepository {
    public func loadScreenshotHistory(
        after cursor: ScreenshotHistoryCursorKey?,
        limit: Int
    ) throws -> [ClipboardRecorderRecord] {
        try queryScreenshotRecords(
            ftsQuery: nil,
            fallbackQuery: nil,
            after: cursor,
            limit: limit
        )
    }

    public func searchScreenshotHistory(
        query: String,
        after cursor: ScreenshotHistoryCursorKey?,
        limit: Int
    ) throws -> [ClipboardRecorderRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try loadScreenshotHistory(after: cursor, limit: limit)
        }
        return try queryScreenshotRecords(
            ftsQuery: database.ftsEnabled ? makeFTSQuery(trimmed) : nil,
            fallbackQuery: trimmed,
            after: cursor,
            limit: limit
        )
    }

    public func loadScreenshotOCRDocuments(
        recordIDs: [String]
    ) throws -> [String: ClipboardSearchDocument] {
        var result: [String: ClipboardSearchDocument] = [:]
        for recordID in recordIDs {
            _ = try requireScreenshotRecord(recordID: recordID)
            guard let document = try loadSearchDocument(recordID: recordID) else {
                throw ScreenshotHistoryRepositoryActionError.recordNotFound
            }
            result[recordID] = document
        }
        return result
    }

    public func enqueueScreenshotOCRRetry(
        recordID: String
    ) throws -> ClipboardSearchDocument {
        _ = try requireScreenshotRecord(recordID: recordID)
        switch try prepareOCRRetry(recordID: recordID) {
        case let .ready(document):
            return document
        case let .alreadyPending(document):
            return document
        case .alreadyRunning:
            throw ScreenshotHistoryRepositoryActionError.alreadyRunning
        case .locked:
            throw ScreenshotHistoryRepositoryActionError.ocrLocked
        case .documentMissing:
            throw ScreenshotHistoryRepositoryActionError.recordNotFound
        }
    }

    public func requireScreenshotRecord(
        recordID: String
    ) throws -> ClipboardRecorderRecord {
        guard let record = try loadRecord(recordID: recordID) else {
            throw ScreenshotHistoryRepositoryActionError.recordNotFound
        }
        guard record.origin == .screenshot else {
            throw ScreenshotHistoryRepositoryActionError.recordNotFound
        }
        guard record.kind == .image else {
            throw ScreenshotHistoryRepositoryActionError.notImage
        }
        return record
    }

    private func queryScreenshotRecords(
        ftsQuery: String?,
        fallbackQuery: String?,
        after cursor: ScreenshotHistoryCursorKey?,
        limit: Int
    ) throws -> [ClipboardRecorderRecord] {
        var bindings: [SQLiteBinding] = []
        let source: String
        let searchCondition: String
        if let ftsQuery {
            source = "clipboard_fts JOIN clipboard_items ON clipboard_items.id = clipboard_fts.record_id"
            searchCondition = "AND clipboard_fts MATCH ?"
            bindings.append(.string(ftsQuery))
        } else if let fallbackQuery {
            source = "clipboard_items"
            searchCondition = "AND lower(coalesce(clipboard_items.search_text, '')) LIKE ?"
            bindings.append(.string("%\(fallbackQuery.lowercased())%"))
        } else {
            source = "clipboard_items"
            searchCondition = ""
        }

        let cursorCondition: String
        if let cursor {
            cursorCondition = """
                AND (
                    COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) < ?
                    OR (
                        COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) = ?
                        AND clipboard_items.created_at < ?
                    )
                    OR (
                        COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) = ?
                        AND clipboard_items.created_at = ?
                        AND clipboard_items.change_count < ?
                    )
                    OR (
                        COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) = ?
                        AND clipboard_items.created_at = ?
                        AND clipboard_items.change_count = ?
                        AND clipboard_items.id < ?
                    )
                )
                """
            let lastCopied = cursor.lastCopiedAt.timeIntervalSince1970
            let created = cursor.createdAt.timeIntervalSince1970
            bindings.append(contentsOf: [
                .double(lastCopied),
                .double(lastCopied), .double(created),
                .double(lastCopied), .double(created), .int(cursor.changeCount),
                .double(lastCopied), .double(created), .int(cursor.changeCount), .string(cursor.recordID),
            ])
        } else {
            cursorCondition = ""
        }
        bindings.append(.int(max(1, limit)))

        return try queryRecords(
            """
            SELECT \(recordColumns)
            FROM \(source)
            WHERE clipboard_items.origin_kind = 'screenshot'
            \(searchCondition)
            \(cursorCondition)
            ORDER BY COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) DESC,
                     clipboard_items.created_at DESC,
                     clipboard_items.change_count DESC,
                     clipboard_items.id DESC
            LIMIT ?
            """,
            bindings: bindings
        )
    }
}
