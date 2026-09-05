import Foundation

public extension ClipboardRepository {
    func loadSearchDocument(recordID: String) throws -> ClipboardSearchDocument? {
        return try database.connection.withStatement(
            """
            SELECT
                record_id,
                revision,
                content_revision,
                preview_title,
                preview_body,
                preview_badge,
                content_kind,
                image_state,
                ocr_status,
                is_truncated,
                content_text,
                rich_text_plain_text,
                url_tokens_json,
                file_tokens_json,
                source_tokens_json,
                type_tokens_json,
                time_tokens_json,
                tag_tokens_json,
                ocr_text,
                ocr_text_source,
                ocr_error_code,
                ocr_attempt_count,
                ocr_last_attempt_at,
                ocr_next_retry_after,
                ocr_user_edited_at,
                ocr_locked_content_revision,
                index_truncated,
                payload_derivation_state,
                updated_at
            FROM clipboard_search_documents
            WHERE record_id = ?
            LIMIT 1
            """,
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            return try decodeSearchDocument(statement)
        }
    }

    func loadPreviewSnapshot(recordID: String) throws -> ClipboardContentPreviewSnapshot? {
        try loadPreviewSnapshots(recordIDs: [recordID])[recordID]
    }

    func loadPreviewSnapshots(recordIDs: [String]) throws -> [String: ClipboardContentPreviewSnapshot] {
        guard !recordIDs.isEmpty else {
            return [:]
        }
        let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
        return try database.connection.withStatement(
            """
            SELECT
                record_id,
                revision,
                content_revision,
                preview_title,
                preview_body,
                preview_badge,
                content_kind,
                image_state,
                ocr_status,
                is_truncated
            FROM clipboard_search_documents
            WHERE record_id IN (\(placeholders))
            """,
            bindings: recordIDs.map(SQLiteBinding.string)
        ) { statement in
            var snapshots: [String: ClipboardContentPreviewSnapshot] = [:]
            while try statement.step() {
                guard let recordID = statement.columnString(0) else {
                    continue
                }
                snapshots[recordID] = ClipboardContentPreviewSnapshot(
                    recordID: recordID,
                    revision: statement.columnString(1) ?? "",
                    title: statement.columnString(3) ?? "",
                    body: statement.columnString(4) ?? "",
                    badge: statement.columnString(5) ?? "",
                    contentKind: ClipboardRecorderItemKind(rawValue: statement.columnString(6) ?? "") ?? .unknown,
                    imageState: statement.columnString(7),
                    ocrState: ClipboardOCRState(rawValue: statement.columnString(8) ?? "") ?? .notRequired,
                    isTruncated: statement.columnBool(9)
                )
            }
            return snapshots
        }
    }

    func loadPendingOCRDocuments(limit: Int) throws -> [ClipboardSearchDocument] {
        try database.connection.withStatement(
            """
            SELECT
                record_id,
                revision,
                content_revision,
                preview_title,
                preview_body,
                preview_badge,
                content_kind,
                image_state,
                ocr_status,
                is_truncated,
                content_text,
                rich_text_plain_text,
                url_tokens_json,
                file_tokens_json,
                source_tokens_json,
                type_tokens_json,
                time_tokens_json,
                tag_tokens_json,
                ocr_text,
                ocr_text_source,
                ocr_error_code,
                ocr_attempt_count,
                ocr_last_attempt_at,
                ocr_next_retry_after,
                ocr_user_edited_at,
                ocr_locked_content_revision,
                index_truncated,
                payload_derivation_state,
                updated_at
            FROM clipboard_search_documents
            WHERE ocr_status = ?
                AND payload_derivation_state != ?
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            bindings: [
                .string(ClipboardOCRState.pending.rawValue),
                .string(ClipboardPayloadDerivationState.redacted.rawValue),
                .int(max(1, limit))
            ]
        ) { statement in
            var documents: [ClipboardSearchDocument] = []
            while try statement.step() {
                documents.append(try decodeSearchDocument(statement))
            }
            return documents
        }
    }

    func upsertSearchDocument(_ document: ClipboardSearchDocument) throws {
        let projection = document.isSearchIndexable ? document.ftsProjectionText : ""
        let compatibilityProjection = projection.isEmpty ? nil : projection
        try database.connection.transaction {
            try database.connection.withStatement(
            """
            INSERT INTO clipboard_search_documents (
                record_id,
                revision,
                content_revision,
                preview_title,
                preview_body,
                preview_badge,
                content_kind,
                image_state,
                ocr_status,
                is_truncated,
                content_text,
                rich_text_plain_text,
                url_tokens_json,
                file_tokens_json,
                source_tokens_json,
                type_tokens_json,
                time_tokens_json,
                tag_tokens_json,
                ocr_text,
                ocr_text_source,
                ocr_error_code,
                ocr_attempt_count,
                ocr_last_attempt_at,
                ocr_next_retry_after,
                ocr_user_edited_at,
                ocr_locked_content_revision,
                index_truncated,
                payload_derivation_state,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                revision = excluded.revision,
                content_revision = excluded.content_revision,
                preview_title = excluded.preview_title,
                preview_body = excluded.preview_body,
                preview_badge = excluded.preview_badge,
                content_kind = excluded.content_kind,
                image_state = excluded.image_state,
                ocr_status = excluded.ocr_status,
                is_truncated = excluded.is_truncated,
                content_text = excluded.content_text,
                rich_text_plain_text = excluded.rich_text_plain_text,
                url_tokens_json = excluded.url_tokens_json,
                file_tokens_json = excluded.file_tokens_json,
                source_tokens_json = excluded.source_tokens_json,
                type_tokens_json = excluded.type_tokens_json,
                time_tokens_json = excluded.time_tokens_json,
                tag_tokens_json = excluded.tag_tokens_json,
                ocr_text = excluded.ocr_text,
                ocr_text_source = excluded.ocr_text_source,
                ocr_error_code = excluded.ocr_error_code,
                ocr_attempt_count = excluded.ocr_attempt_count,
                ocr_last_attempt_at = excluded.ocr_last_attempt_at,
                ocr_next_retry_after = excluded.ocr_next_retry_after,
                ocr_user_edited_at = excluded.ocr_user_edited_at,
                ocr_locked_content_revision = excluded.ocr_locked_content_revision,
                index_truncated = excluded.index_truncated,
                payload_derivation_state = excluded.payload_derivation_state,
                updated_at = excluded.updated_at
            """,
            bindings: bindings(for: document)
            ) { statement in
                _ = try statement.step()
            }
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET search_text = ?, updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    optionalString(compatibilityProjection),
                    .double(document.updatedAt.timeIntervalSince1970),
                    .string(document.recordID)
                ]
            ) { statement in
                _ = try statement.step()
            }
            try replaceFTS(recordID: document.recordID, searchText: compatibilityProjection)
        }
    }

    func deleteSearchDocuments(recordIDs: [String]) throws {
        guard !recordIDs.isEmpty else {
            return
        }
        let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
        let bindings = recordIDs.map(SQLiteBinding.string)
        try database.connection.withStatement(
            "DELETE FROM clipboard_search_documents WHERE record_id IN (\(placeholders))",
            bindings: bindings
        ) { statement in
            _ = try statement.step()
        }
        if database.ftsEnabled {
            try database.connection.withStatement(
                "DELETE FROM clipboard_fts WHERE record_id IN (\(placeholders))",
                bindings: bindings
            ) { statement in
                _ = try statement.step()
            }
        }
        try database.connection.withStatement(
            "UPDATE clipboard_items SET search_text = NULL WHERE id IN (\(placeholders))",
            bindings: bindings
        ) { statement in
            _ = try statement.step()
        }
    }

    func markSearchDocumentRedacted(recordID: String, revision: String, summaryCode: String) throws {
        let now = Date()
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_search_documents (
                record_id,
                revision,
                preview_title,
                preview_body,
                preview_badge,
                content_kind,
                image_state,
                ocr_status,
                is_truncated,
                content_text,
                rich_text_plain_text,
                url_tokens_json,
                file_tokens_json,
                source_tokens_json,
                type_tokens_json,
                time_tokens_json,
                tag_tokens_json,
                ocr_text,
                ocr_error_code,
                ocr_attempt_count,
                ocr_last_attempt_at,
                ocr_next_retry_after,
                index_truncated,
                payload_derivation_state,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 0, NULL, NULL, ?, ?, ?, ?, ?, ?, NULL, NULL, 0, NULL, NULL, 0, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                revision = excluded.revision,
                preview_title = excluded.preview_title,
                preview_body = excluded.preview_body,
                preview_badge = excluded.preview_badge,
                image_state = excluded.image_state,
                ocr_status = excluded.ocr_status,
                is_truncated = excluded.is_truncated,
                content_text = excluded.content_text,
                rich_text_plain_text = excluded.rich_text_plain_text,
                url_tokens_json = excluded.url_tokens_json,
                file_tokens_json = excluded.file_tokens_json,
                source_tokens_json = excluded.source_tokens_json,
                type_tokens_json = excluded.type_tokens_json,
                time_tokens_json = excluded.time_tokens_json,
                tag_tokens_json = excluded.tag_tokens_json,
                ocr_text = excluded.ocr_text,
                ocr_error_code = excluded.ocr_error_code,
                ocr_attempt_count = excluded.ocr_attempt_count,
                ocr_last_attempt_at = excluded.ocr_last_attempt_at,
                ocr_next_retry_after = excluded.ocr_next_retry_after,
                index_truncated = excluded.index_truncated,
                payload_derivation_state = excluded.payload_derivation_state,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .string(recordID),
                .string(revision),
                .string("clipboard.capture.skipped"),
                .string(summaryCode),
                .string(ClipboardRecorderItemKind.unknown.rawValue),
                .string(ClipboardRecorderItemKind.unknown.rawValue),
                .string(ClipboardOCRState.notRequired.rawValue),
                .string("[]"),
                .string("[]"),
                .string("[]"),
                .string("[]"),
                .string("[]"),
                .string("[]"),
                .string(ClipboardPayloadDerivationState.redacted.rawValue),
                .double(now.timeIntervalSince1970)
            ]
        ) { statement in
            _ = try statement.step()
        }
        try database.connection.withStatement(
            "UPDATE clipboard_items SET search_text = NULL, updated_at = ? WHERE id = ?",
            bindings: [.double(now.timeIntervalSince1970), .string(recordID)]
        ) { statement in
            _ = try statement.step()
        }
        try replaceFTS(recordID: recordID, searchText: nil)
    }

    func markSearchDocumentTagsDirty(recordIDs: [String]) throws {
        let uniqueRecordIDs = Array(Set(recordIDs)).sorted()
        guard !uniqueRecordIDs.isEmpty else {
            return
        }
        for recordID in uniqueRecordIDs {
            guard let document = try loadSearchDocument(recordID: recordID) else {
                guard let record = try loadRecord(recordID: recordID) else {
                    continue
                }
                try upsertSearchDocument(searchDocument(record: record))
                continue
            }
            let tagTokens = try tagSearchTokens(recordID: recordID)
            try upsertSearchDocument(document.replacingTags(tagTokens: tagTokens))
        }
    }

    @discardableResult
    func updateOCRResult(
        recordID: String,
        revision: String,
        text: String?,
        state: ClipboardOCRState,
        errorCode: String? = nil
    ) throws -> Bool {
        try database.connection.transaction {
            guard let document = try loadSearchDocument(recordID: recordID),
                  document.revision == revision,
                  document.payloadDerivationState != .redacted else {
                return false
            }
            guard document.ocrTextSource != .userEdited,
                  document.ocrLockedContentRevision == nil else {
                return false
            }
            let advancesContentRevision = state == .succeeded && (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let newContentRevision = advancesContentRevision ? document.contentRevision + 1 : document.contentRevision
            if advancesContentRevision {
                try updateContentRevision(
                    recordID: recordID,
                    contentRevision: newContentRevision,
                    contentUpdatedAt: Date()
                )
            }
            let updated = document.replacingOCR(
                text: text,
                state: state,
                errorCode: errorCode,
                attemptCount: document.ocrAttemptCount + (state == .running ? 1 : 0),
                lastAttemptAt: state == .running ? Date() : document.ocrLastAttemptAt,
                source: advancesContentRevision ? .vision : ClipboardOCRTextSource.none,
                contentRevision: newContentRevision
            )
            try upsertSearchDocument(updated)
            return true
        }
    }

    @discardableResult
    func returnOCRToPending(recordID: String, revision: String) throws -> Bool {
        try database.connection.transaction {
            guard let document = try loadSearchDocument(recordID: recordID),
                  document.revision == revision,
                  document.ocrState == .running,
                  document.payloadDerivationState != .redacted,
                  document.ocrTextSource != .userEdited,
                  document.ocrLockedContentRevision == nil else {
                return false
            }
            try upsertSearchDocument(document.replacingOCR(
                text: nil,
                state: .pending,
                errorCode: nil,
                attemptCount: document.ocrAttemptCount,
                lastAttemptAt: document.ocrLastAttemptAt,
                source: ClipboardOCRTextSource.none
            ))
            return true
        }
    }

    @discardableResult
    func rebuildSearchDocuments(limit: Int) throws -> Int {
        let records = try loadRecent(limit: max(1, limit))
        var rebuilt = 0
        for record in records {
            guard try loadSearchDocument(recordID: record.id) == nil else {
                continue
            }
            try upsertSearchDocument(searchDocument(record: record))
            rebuilt += 1
        }
        return rebuilt
    }

    @discardableResult
    func recoverInterruptedOCR() throws -> Int {
        try database.connection.transaction {
            let interruptedCount = try database.connection.firstInt(
                """
                SELECT COUNT(*)
                FROM clipboard_search_documents
                WHERE ocr_status = ?
                    AND payload_derivation_state != ?
                    AND ocr_text_source != ?
                    AND ocr_locked_content_revision IS NULL
                """,
                bindings: [
                    .string(ClipboardOCRState.running.rawValue),
                    .string(ClipboardPayloadDerivationState.redacted.rawValue),
                    .string(ClipboardOCRTextSource.userEdited.rawValue)
                ]
            ) ?? 0
            guard interruptedCount > 0 else {
                return 0
            }
            try database.connection.withStatement(
                """
                UPDATE clipboard_search_documents
                SET ocr_status = ?,
                    ocr_error_code = NULL,
                    ocr_next_retry_after = NULL,
                    updated_at = ?
                WHERE ocr_status = ?
                    AND payload_derivation_state != ?
                    AND ocr_text_source != ?
                    AND ocr_locked_content_revision IS NULL
                """,
                bindings: [
                    .string(ClipboardOCRState.pending.rawValue),
                    .double(Date().timeIntervalSince1970),
                    .string(ClipboardOCRState.running.rawValue),
                    .string(ClipboardPayloadDerivationState.redacted.rawValue),
                    .string(ClipboardOCRTextSource.userEdited.rawValue)
                ]
            ) { statement in
                _ = try statement.step()
            }
            return interruptedCount
        }
    }

    @discardableResult
    func rebuildPendingSearchDocuments(limit: Int) throws -> Int {
        let recordIDs = try loadPendingIndexBatch(limit: limit)
        var rebuilt = 0
        for recordID in recordIDs {
            guard let record = try loadRecord(recordID: recordID) else {
                continue
            }
            let existingDocument = try loadSearchDocument(recordID: recordID)
            try upsertSearchDocument(searchDocument(record: record, preservingOCRFrom: existingDocument))
            rebuilt += 1
        }
        return rebuilt
    }

    func loadPendingIndexBatch(limit: Int) throws -> [String] {
        let ftsJoin = database.ftsEnabled
            ? "LEFT JOIN clipboard_fts ON clipboard_fts.record_id = clipboard_items.id"
            : ""
        let ftsRepairConditions = database.ftsEnabled
            ? "OR clipboard_fts.record_id IS NULL OR COALESCE(clipboard_fts.search_text, '') != COALESCE(clipboard_items.search_text, '')"
            : ""
        return try database.connection.withStatement(
            """
            SELECT clipboard_items.id
            FROM clipboard_items
            LEFT JOIN clipboard_search_documents
                ON clipboard_search_documents.record_id = clipboard_items.id
            \(ftsJoin)
            WHERE clipboard_search_documents.record_id IS NULL
                OR clipboard_search_documents.payload_derivation_state = ?
                OR clipboard_search_documents.revision != ('v2:' || CAST(clipboard_items.change_count AS TEXT) || ':' || clipboard_items.signature_sha256_12)
                OR (clipboard_items.search_text IS NULL AND clipboard_search_documents.payload_derivation_state = 'available')
                \(ftsRepairConditions)
            ORDER BY COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) DESC,
                clipboard_items.created_at DESC,
                clipboard_items.change_count DESC,
                clipboard_items.id DESC
            LIMIT ?
            """,
            bindings: [.string(ClipboardPayloadDerivationState.pendingIndex.rawValue), .int(max(1, limit))]
        ) { statement in
            var ids: [String] = []
            while try statement.step() {
                if let id = statement.columnString(0) {
                    ids.append(id)
                }
            }
            return ids
        }
    }

    func searchDocuments(
        query: String,
        limit: Int,
        filteringBatch: (([ClipboardRecorderRecord]) throws -> [ClipboardRecorderRecord])? = nil
    ) throws -> ClipboardSearchResultSet {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .idle(records: try search(trimmed, limit: limit, filteringBatch: filteringBatch))
        }
        let records = try search(trimmed, limit: limit, filteringBatch: filteringBatch)
        let activity = try searchIndexActivity()
        let state: ClipboardSearchResultState
        if records.isEmpty {
            state = activity.hasPendingWork ? .emptyIndexing : .empty
        } else {
            state = activity.hasPendingWork ? .partialIndexing : .results
        }
        return ClipboardSearchResultSet(
            query: trimmed,
            records: records,
            state: state,
            indexActivity: activity
        )
    }

    func searchIndexActivity() throws -> ClipboardSearchIndexActivity {
        let pendingIndexCount = try database.connection.firstInt(
            """
            SELECT COUNT(*)
            FROM clipboard_items
            LEFT JOIN clipboard_search_documents
                ON clipboard_search_documents.record_id = clipboard_items.id
            WHERE clipboard_search_documents.record_id IS NULL
                OR clipboard_search_documents.payload_derivation_state = ?
            """,
            bindings: [.string(ClipboardPayloadDerivationState.pendingIndex.rawValue)]
        ) ?? 0
        let pendingOCRCount = try database.connection.firstInt(
            """
            SELECT COUNT(*)
            FROM clipboard_search_documents
            WHERE ocr_status IN (?, ?)
            """,
            bindings: [.string(ClipboardOCRState.pending.rawValue), .string(ClipboardOCRState.running.rawValue)]
        ) ?? 0
        let failedOCRCount = try database.connection.firstInt(
            """
            SELECT COUNT(*)
            FROM clipboard_search_documents
            WHERE ocr_status = ?
            """,
            bindings: [.string(ClipboardOCRState.failed.rawValue)]
        ) ?? 0
        return ClipboardSearchIndexActivity(
            pendingIndexCount: pendingIndexCount,
            pendingOCRCount: pendingOCRCount,
            failedOCRCount: failedOCRCount
        )
    }

    func updateContentRevision(recordID: String, contentRevision: Int64, contentUpdatedAt: Date) throws {
        try database.connection.withStatement(
            """
            UPDATE clipboard_items
            SET content_revision = ?,
                content_updated_at = ?,
                updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .int64(max(1, contentRevision)),
                .double(contentUpdatedAt.timeIntervalSince1970),
                .double(contentUpdatedAt.timeIntervalSince1970),
                .string(recordID)
            ]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func tagSearchTokens(recordID: String) throws -> [String] {
        try database.connection.withStatement(
            """
            SELECT clipboard_tags.display_name, clipboard_tags.normalized_name
            FROM clipboard_record_tags
            JOIN clipboard_tags ON clipboard_tags.id = clipboard_record_tags.tag_id
            WHERE clipboard_record_tags.record_id = ?
            ORDER BY
                CASE WHEN clipboard_tags.built_in_kind = 'favorite' THEN 0 ELSE 1 END,
                clipboard_tags.sort_order ASC,
                clipboard_tags.display_name ASC
            """,
            bindings: [.string(recordID)]
        ) { statement in
            var tokens: [String] = []
            while try statement.step() {
                if let display = statement.columnString(0), !display.isEmpty {
                    tokens.append(display)
                }
                if let normalized = statement.columnString(1), !normalized.isEmpty {
                    tokens.append(normalized)
                }
            }
            return Array(Set(tokens)).sorted()
        }
    }

    private func searchDocument(record: ClipboardRecorderRecord) throws -> ClipboardSearchDocument {
        try searchDocument(record: record, preservingOCRFrom: nil)
    }

    private func searchDocument(
        record: ClipboardRecorderRecord,
        preservingOCRFrom existingDocument: ClipboardSearchDocument?
    ) throws -> ClipboardSearchDocument {
        let payload = try readPayload(recordID: record.id)
        let tagTokens = try tagSearchTokens(recordID: record.id)
        let contentRevision = try contentRevision(recordID: record.id)
        let rebuiltDocument = ClipboardSearchDocumentBuilder().build(
            record: record,
            payload: payload,
            tags: tagTokens,
            ocrText: existingDocument?.ocrText,
            ocrState: existingDocument?.ocrState,
            ocrTextSource: existingDocument?.ocrTextSource ?? .none,
            contentRevision: contentRevision
        )
        guard let existingDocument else {
            return rebuiltDocument
        }
        return rebuiltDocument.replacingOCR(
            text: existingDocument.ocrText,
            state: existingDocument.ocrState,
            errorCode: existingDocument.ocrErrorCode,
            attemptCount: existingDocument.ocrAttemptCount,
            lastAttemptAt: existingDocument.ocrLastAttemptAt,
            nextRetryAfter: existingDocument.ocrNextRetryAfter,
            source: existingDocument.ocrTextSource,
            userEditedAt: existingDocument.ocrUserEditedAt,
            lockedContentRevision: existingDocument.ocrLockedContentRevision,
            contentRevision: contentRevision
        )
    }

    private func contentRevision(recordID: String) throws -> Int64 {
        try database.connection.withStatement(
            "SELECT content_revision FROM clipboard_items WHERE id = ? LIMIT 1",
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                return 1
            }
            return max(1, statement.columnInt64(0))
        }
    }
}

private func decodeSearchDocument(_ statement: SQLiteStatement) throws -> ClipboardSearchDocument {
    let recordID = statement.columnString(0) ?? ""
    let revision = statement.columnString(1) ?? ""
    let contentRevision = max(1, statement.columnInt64(2))
    let contentKind = ClipboardRecorderItemKind(rawValue: statement.columnString(6) ?? "") ?? .unknown
    let ocrState = ClipboardOCRState(rawValue: statement.columnString(8) ?? "") ?? .notRequired
    let preview = ClipboardContentPreviewSnapshot(
        recordID: recordID,
        revision: revision,
        title: statement.columnString(3) ?? "",
        body: statement.columnString(4) ?? "",
        badge: statement.columnString(5) ?? "",
        contentKind: contentKind,
        imageState: statement.columnString(7),
        ocrState: ocrState,
        isTruncated: statement.columnBool(9)
    )
    return ClipboardSearchDocument(
        recordID: recordID,
        revision: revision,
        contentRevision: contentRevision,
        updatedAt: Date(timeIntervalSince1970: statement.columnDouble(28)),
        preview: preview,
        contentText: statement.columnString(10),
        richTextPlainText: statement.columnString(11),
        urlTokens: try decodeStringArray(statement.columnString(12)),
        fileTokens: try decodeStringArray(statement.columnString(13)),
        sourceTokens: try decodeStringArray(statement.columnString(14)),
        typeTokens: try decodeStringArray(statement.columnString(15)),
        timeTokens: try decodeStringArray(statement.columnString(16)),
        tagTokens: try decodeStringArray(statement.columnString(17)),
        ocrText: statement.columnString(18),
        ocrState: ocrState,
        ocrTextSource: ClipboardOCRTextSource(rawValue: statement.columnString(19) ?? "") ?? .none,
        ocrErrorCode: statement.columnString(20),
        ocrAttemptCount: statement.columnInt(21),
        ocrLastAttemptAt: date(column: statement.columnDouble(22), isNull: statement.columnString(22) == nil),
        ocrNextRetryAfter: date(column: statement.columnDouble(23), isNull: statement.columnString(23) == nil),
        ocrUserEditedAt: date(column: statement.columnDouble(24), isNull: statement.columnString(24) == nil),
        ocrLockedContentRevision: optionalInt64(statement, 25),
        indexTruncated: statement.columnBool(26),
        payloadDerivationState: ClipboardPayloadDerivationState(rawValue: statement.columnString(27) ?? "") ?? .degraded
    )
}

private func bindings(for document: ClipboardSearchDocument) throws -> [SQLiteBinding] {
    [
        .string(document.recordID),
        .string(document.revision),
        .int64(document.contentRevision),
        .string(document.preview.title),
        .string(document.preview.body),
        .string(document.preview.badge),
        .string(document.preview.contentKind.rawValue),
        optionalString(document.preview.imageState),
        .string(document.ocrState.rawValue),
        .bool(document.preview.isTruncated),
        optionalString(document.contentText),
        optionalString(document.richTextPlainText),
        .string(try encodeStringArray(document.urlTokens)),
        .string(try encodeStringArray(document.fileTokens)),
        .string(try encodeStringArray(document.sourceTokens)),
        .string(try encodeStringArray(document.typeTokens)),
        .string(try encodeStringArray(document.timeTokens)),
        .string(try encodeStringArray(document.tagTokens)),
        optionalString(document.ocrText),
        .string(document.ocrTextSource.rawValue),
        optionalString(document.ocrErrorCode),
        .int(document.ocrAttemptCount),
        optionalDate(document.ocrLastAttemptAt),
        optionalDate(document.ocrNextRetryAfter),
        optionalDate(document.ocrUserEditedAt),
        optionalInt64(document.ocrLockedContentRevision),
        .bool(document.indexTruncated),
        .string(document.payloadDerivationState.rawValue),
        .double(document.updatedAt.timeIntervalSince1970)
    ]
}

private func encodeStringArray(_ value: [String]) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func decodeStringArray(_ value: String?) throws -> [String] {
    guard let value, !value.isEmpty else {
        return []
    }
    return try JSONDecoder().decode([String].self, from: Data(value.utf8))
}

private func optionalString(_ value: String?) -> SQLiteBinding {
    guard let value else {
        return .null
    }
    return .string(value)
}

private func optionalDate(_ value: Date?) -> SQLiteBinding {
    guard let value else {
        return .null
    }
    return .double(value.timeIntervalSince1970)
}

private func optionalInt64(_ value: Int64?) -> SQLiteBinding {
    guard let value else {
        return .null
    }
    return .int64(value)
}

private func optionalInt64(_ statement: SQLiteStatement, _ index: Int32) -> Int64? {
    statement.columnString(index) == nil ? nil : statement.columnInt64(index)
}

private func date(column: Double, isNull: Bool) -> Date? {
    isNull ? nil : Date(timeIntervalSince1970: column)
}
