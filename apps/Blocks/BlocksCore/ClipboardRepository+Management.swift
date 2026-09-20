import CryptoKit
import Foundation

public extension ClipboardRepository {
    /// Executes against one consistent SQLite snapshot. All payload/FTS/tag
    /// changes share the outer sidecar rollback scope; previews execute no writes.
    func executeManagement(_ input: ClipboardManagementActionInput,
                           isCancelled: @Sendable () -> Bool = { false }) throws -> ClipboardManagementResult {
        try executeManagement(input, selectionNow: Date(), selectionTimeZone: .current,
                              isCancelled: isCancelled)
    }
}

extension ClipboardRepository {
    /// Internal deterministic clock seam for relative-date selection tests.
    /// The public entry point captures one clock/time-zone context per request.
    func executeManagement(_ input: ClipboardManagementActionInput, selectionNow: Date,
                           selectionTimeZone: TimeZone,
                           isCancelled: @Sendable () -> Bool = { false }) throws -> ClipboardManagementResult {
        do {
            if isCancelled() { throw CancellationError() }
            return try withScreenshotHistorySerialization {
                try withSidecarRollbackTransaction { tracker in
                    if isCancelled() { throw CancellationError() }
                    let result = try managementExecute(input, tracker: tracker, selectionNow: selectionNow,
                                                       selectionTimeZone: selectionTimeZone, isCancelled: isCancelled)
                    if isCancelled() { throw CancellationError() }
                    return result
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClipboardManagementError { throw error }
        catch { throw ClipboardManagementError("transaction_failed") }
    }
}

private extension ClipboardRepository {
    func managementExecute(_ input: ClipboardManagementActionInput, tracker: ClipboardSidecarRollbackTracker,
                           selectionNow: Date, selectionTimeZone: TimeZone,
                           isCancelled: @Sendable () -> Bool) throws -> ClipboardManagementResult {
        let operations = ["list", "search", "show", "export", "import", "pin", "unpin", "move", "tag_add", "tag_remove", "pinboard_list", "pinboard_create", "pinboard_rename", "delete"]
        guard operations.contains(input.operation) else { throw ClipboardManagementError("unsupported_operation") }
        try managementValidateFields(input)
        guard (1...ClipboardManagementLimits.maxRecords).contains(input.limit), input.offset >= 0,
              input.offset <= 1_000_000, input.recordIDs.count <= ClipboardManagementLimits.maxRecords else { throw ClipboardManagementError("invalid_pagination") }
        let boards = try loadPinboards()
        var result = ClipboardManagementResult(operation: input.operation, dryRun: input.dryRun)
        result.pinboards = boards.map { ClipboardManagementPinboard(id: $0.id, name: $0.name) }
        if input.operation == "pinboard_list" { return result }
        if ["import", "pinboard_create", "pinboard_rename"].contains(input.operation) {
            let token = try managementToken(input)
            if let expected = input.confirmationToken, expected != token { throw ClipboardManagementError("revision_conflict") }
            result.confirmationToken = token
        }
        if input.operation == "import" {
            return try managementImport(input, result: result, tracker: tracker, isCancelled: isCancelled)
        }
        if input.operation == "pinboard_create" || input.operation == "pinboard_rename" {
            guard let raw = input.name else { throw ClipboardManagementError("name_required") }
            let name = try managementName(raw)
            if boards.contains(where: { $0.name == name && $0.id != input.pinboardID }) { throw ClipboardManagementError("pinboard_name_conflict") }
            if input.operation == "pinboard_rename" {
                guard let id = input.pinboardID, boards.contains(where: { $0.id == id }) else { throw ClipboardManagementError("pinboard_not_found") }
                guard !["pinboard.unfiled", "pinboard.work", "pinboard.personal"].contains(id) else { throw ClipboardManagementError("builtin_pinboard_immutable") }
                if !input.dryRun { try managementSQL("UPDATE clipboard_pinboards SET name = ?, updated_at = ? WHERE id = ?", [.string(name), .double(Date().timeIntervalSince1970), .string(id)]) }
                result.counts.updated = 1
            } else {
                if !input.dryRun { _ = try managementCreatePinboard(name) }
                result.counts.pinboardsCreated = 1
            }
            result.pinboards = try loadPinboards().map { ClipboardManagementPinboard(id: $0.id, name: $0.name) }
            return result
        }
        let readPage = ["list", "search"].contains(input.operation)
        let requiresSelection = !readPage
        let tagIsSelector = ["list", "search", "show", "export", "delete"].contains(input.operation)
        let hasSelector = !input.recordIDs.isEmpty || !(input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.pinboardID != nil || (tagIsSelector && input.tag != nil)
        guard !requiresSelection || input.all || hasSelector else { throw ClipboardManagementError("selection_required") }
        guard readPage || input.offset == 0 else { throw ClipboardManagementError("pagination_not_allowed") }
        if input.operation == "search", (input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ClipboardManagementError("query_required") }
        if let id = input.pinboardID, !boards.contains(where: { $0.id == id }) { throw ClipboardManagementError("pinboard_not_found") }
        let pinned = try loadPinnedMetadata()
        let requested = Set(input.recordIDs)
        if !requested.isEmpty {
            let placeholders = requested.map { _ in "?" }.joined(separator: ",")
            let count = try database.connection.firstInt("SELECT COUNT(*) FROM clipboard_items WHERE id IN (\(placeholders))", bindings: requested.map(SQLiteBinding.string)) ?? 0
            guard count == requested.count else { throw ClipboardManagementError("record_not_found") }
        }
        var tagMembers: Set<String>?
        if tagIsSelector, let tag = input.tag {
            let raw = try ClipboardTagNameNormalizer().normalizedName(tag)
            let normalized = ClipboardTagNameNormalizer.reservedAliases.contains(raw) ? "favorite" : raw
            tagMembers = try database.connection.withStatement("""
                SELECT rt.record_id FROM clipboard_record_tags rt
                JOIN clipboard_tags t ON t.id = rt.tag_id WHERE t.normalized_name = ?
                """, bindings: [.string(normalized)]) { statement in
                var ids = Set<String>()
                while try statement.step() { if let id = statement.columnString(0) { ids.insert(id) } }
                return ids
            }
        }
        // For pin/move pinboardID is the destination, not a selector.
        let destination = ["pin", "move"].contains(input.operation)
        if destination && requested.isEmpty && (input.query ?? "").isEmpty && !input.all { throw ClipboardManagementError("selection_required") }
        let cap = readPage ? input.offset + input.limit : ClipboardManagementLimits.maxRecords + 1
        let selectionQuery = managementResolvedQuery(input.query ?? "", now: selectionNow, timeZone: selectionTimeZone)
        let matches = try search(selectionQuery, limit: cap, filteringBatch: { records in
            records.filter { record in
                (requested.isEmpty || requested.contains(record.id)) &&
                (tagMembers == nil || tagMembers!.contains(record.id)) &&
                (destination || input.pinboardID == nil || pinned[record.id]?.pinboardID == input.pinboardID)
            }
        })
        guard readPage || matches.count <= ClipboardManagementLimits.maxRecords else { throw ClipboardManagementError("selection_too_large") }
        let records = readPage ? Array(matches.dropFirst(input.offset).prefix(input.limit)) : matches
        result.records = try records.map { try managementMetadata($0, pinned: pinned) }
        result.counts.selected = records.count
        if readPage { return result }
        // Relative date queries can select a different set across midnight or
        // a time-zone change even when every database row is unchanged. Bind
        // confirmation to the actual selection from this same transaction.
        let token = try managementToken(input, selectedRecordIDs: records.map(\.id))
        if let expected = input.confirmationToken, expected != token { throw ClipboardManagementError("revision_conflict") }
        result.confirmationToken = token
        if ["show", "export"].contains(input.operation) {
            let wire = try records.map { try managementExportRecord($0, pinned: pinned, boards: boards) }
            let names = Set(wire.compactMap(\.pinboard))
            let document = ClipboardImportDocument(pinboards: boards.filter { input.all || names.contains($0.name) }.map(\.name), records: wire)
            _ = try document.encoded()
            result.document = document
            return result
        }
        if input.operation == "move" && input.pinboardID == nil { throw ClipboardManagementError("pinboard_required") }
        if ["tag_add", "tag_remove"].contains(input.operation) {
            guard let tag = input.tag else { throw ClipboardManagementError("tag_required") }
            _ = try ClipboardImportRecord(kind: "text", text: "", tags: [tag]).validated()
        }
        if input.operation == "delete" && input.confirmationToken == nil { result.dryRun = true }
        if input.operation == "delete" { result.counts.deleted = records.count }
        else { result.counts.updated = records.count }
        guard !result.dryRun else { return result }
        result.mutatedRecordIDs = records.map(\.id)
        let tags = ClipboardTagRepository(database: database)
        if input.operation == "delete" {
            _ = try deleteRecordsFromDatabase(records.map(\.id))
            result.records = []
            // Cleanup is durably queued, never unlink sidecars before commit.
            return result
        }
        for record in records {
            if isCancelled() { throw CancellationError() }
            switch input.operation {
            case "pin", "move":
                let destination = input.pinboardID ?? pinned[record.id]?.pinboardID ?? "pinboard.unfiled"
                try move(recordID: record.id, toPinboard: destination)
                let favorite = try tags.ensureFavoriteTag()
                _ = try tags.addTag(recordID: record.id, tagID: favorite.id)
            case "unpin":
                try unpin(recordID: record.id)
                let favorite = try tags.ensureFavoriteTag()
                _ = try tags.removeTag(recordID: record.id, tagID: favorite.id)
            case "tag_add": try managementAddTag(input.tag!, recordID: record.id, repository: tags)
            case "tag_remove":
                let rawNormalized = try ClipboardTagNameNormalizer().normalizedName(input.tag!)
                let normalized = ClipboardTagNameNormalizer.reservedAliases.contains(rawNormalized) ? "favorite" : rawNormalized
                if let id = try database.connection.firstString("SELECT id FROM clipboard_tags WHERE normalized_name = ?", bindings: [.string(normalized)]) {
                    _ = try tags.removeTag(recordID: record.id, tagID: id)
                }
            default: throw ClipboardManagementError("unsupported_operation")
            }
        }
        let freshPinned = try loadPinnedMetadata()
        result.records = try records.compactMap { try loadRecord(recordID: $0.id) }.map { try managementMetadata($0, pinned: freshPinned) }
        return result
    }

    func managementImport(_ input: ClipboardManagementActionInput, result initial: ClipboardManagementResult,
                          tracker: ClipboardSidecarRollbackTracker,
                          isCancelled: @Sendable () -> Bool) throws -> ClipboardManagementResult {
        guard let document = input.document, document.schemaVersion == 1 else { throw ClipboardManagementError("unsupported_schema") }
        guard document.records.count <= ClipboardManagementLimits.maxRecords, document.pinboards.count <= ClipboardManagementLimits.maxRecords else { throw ClipboardManagementError("document_too_large") }
        _ = try document.encoded()
        let validated = try document.records.map { record in
            if isCancelled() { throw CancellationError() }
            return try record.validated()
        }
        var boardNames = Set(try document.pinboards.map(managementName))
        for record in validated { if let name = record.wire.pinboard { boardNames.insert(try managementName(name)) } }
        let existingBoards = try loadPinboards()
        var boardIDs: [String: String] = [:]
        for board in existingBoards {
            guard boardIDs[board.name] == nil else { throw ClipboardManagementError("pinboard_name_conflict") }
            boardIDs[board.name] = board.id
        }
        let pinned = try loadPinnedMetadata()
        var existingIDs: [String: String] = [:]
        var grouped: [String: [ValidatedClipboardImport]] = [:]
        for item in validated { grouped[item.signature, default: []].append(item) }
        // Validate every existing and batch association before any SQL/sidecar write.
        for (signature, items) in grouped {
            var assignments = Set(try items.compactMap(\.wire.pinboard).map(managementName))
            if let id = try managementExistingRecord(signature: signature, payload: items[0].payload) {
                existingIDs[signature] = id
                if let metadata = pinned[id], metadata.pinboardID != "pinboard.unfiled",
                   let name = existingBoards.first(where: { $0.id == metadata.pinboardID })?.name { assignments.insert(name) }
            }
            guard assignments.count <= 1 else { throw ClipboardManagementError("pinboard_conflict") }
        }
        var result = initial
        result.counts.selected = validated.count
        result.counts.inserted = grouped.count - existingIDs.count
        result.counts.duplicates = validated.count - result.counts.inserted
        result.counts.updated = existingIDs.count
        result.counts.pinboardsCreated = boardNames.filter { boardIDs[$0] == nil }.count
        result.warnings = ["unprotected_imports_follow_normal_retention", "existing_payload_title_and_ocr_preserved"]
        if input.dryRun { return result }
        for name in boardNames.sorted() where boardIDs[name] == nil { boardIDs[name] = try managementCreatePinboard(name) }
        let tags = ClipboardTagRepository(database: database)
        var affected: [String] = []
        for signature in grouped.keys.sorted() {
            if isCancelled() { throw CancellationError() }
            let items = grouped[signature]!
            let first = items[0]
            let id: String
            if let existing = existingIDs[signature] { id = existing }
            else {
                id = "clip.import.\(UUID().uuidString.lowercased())"
                let created = try managementDate(first.wire.createdAt) ?? Date()
                let copied = try managementDate(first.wire.lastCopiedAt) ?? created
                let payload = ClipboardRecorderPayload(recordID: id, kind: first.payload.kind, text: first.payload.text,
                    rtfData: first.payload.rtfData, pngData: first.payload.pngData, urlString: first.payload.urlString)
                let record = ClipboardRecorderRecord(id: id, createdAt: created, changeCount: 0, kind: payload.kind,
                    formatSummary: ClipboardRecorderFormatSummary(itemCount: 1, types: [], textLength: payload.text?.count,
                        byteCount: (payload.rtfData?.count ?? 0) + (payload.pngData?.count ?? 0), fileCount: payload.kind == .fileURL ? 1 : nil),
                    sourceApp: nil, signatureSHA256: signature, signatureSHA256_12: String(signature.prefix(12)),
                    fixtureOwned: false, restorable: true, customTitle: first.wire.title, lastCopiedAt: copied,
                    summary: String((payload.text ?? "Imported image").prefix(160)))
                let search = ClipboardSearchDocumentBuilder().build(record: record, payload: payload)
                try insertRecord(record, compatibilitySearchText: search.ftsProjectionText)
                try storePayload(payload, forRecordID: id, rollbackTracker: tracker)
                try upsertSearchDocument(search)
            }
            if let name = try items.compactMap(\.wire.pinboard).map(managementName).first, let board = boardIDs[name] {
                try move(recordID: id, toPinboard: board)
                if !items.contains(where: { $0.wire.isFavorite == false }) {
                    let favorite = try tags.ensureFavoriteTag()
                    _ = try tags.addTag(recordID: id, tagID: favorite.id)
                }
            }
            if items.contains(where: { $0.wire.isFavorite == true }) {
                let favorite = try tags.ensureFavoriteTag()
                _ = try tags.addTag(recordID: id, tagID: favorite.id)
            }
            for name in Set(items.flatMap(\.wire.tags)).sorted() { try managementAddTag(name, recordID: id, repository: tags) }
            affected.append(id)
        }
        let metadata = try loadPinnedMetadata()
        result.records = try affected.compactMap { try loadRecord(recordID: $0) }.map { try managementMetadata($0, pinned: metadata) }
        result.mutatedRecordIDs = affected
        result.pinboards = try loadPinboards().map { ClipboardManagementPinboard(id: $0.id, name: $0.name) }
        return result
    }

    func managementTags(_ id: String) throws -> [(name: String, builtin: String)] {
        try database.connection.withStatement("""
            SELECT t.display_name, t.built_in_kind FROM clipboard_tags t
            JOIN clipboard_record_tags rt ON rt.tag_id = t.id
            WHERE rt.record_id = ? ORDER BY t.normalized_name
            """, bindings: [.string(id)]) { statement in
            var result: [(String, String)] = []
            while try statement.step() { result.append((statement.columnString(0) ?? "", statement.columnString(1) ?? "none")) }
            return result
        }
    }
    func managementExistingRecord(signature: String, payload: ClipboardRecorderPayload) throws -> String? {
        var candidates = Set<String>()
        if let id = try database.connection.firstString("SELECT id FROM clipboard_items WHERE signature_sha256 = ?", bindings: [.string(signature)]) { candidates.insert(id) }
        if let png = payload.pngData, payload.kind == .image {
            // Screenshot history keys items by decoded visual signature, while
            // live clipboard capture uses kind+PNG bytes. Exact payload hashes
            // bridge these identities without trusting an imported id/hash or
            // merging distinct images on user-supplied metadata.
            let payloadHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            try database.connection.withStatement("""
                SELECT i.id FROM clipboard_items i JOIN clipboard_payloads p ON p.record_id = i.id
                WHERE i.kind = 'image' AND p.png_payload_sha256 = ?
                """, bindings: [.string(payloadHash)]) { statement in
                while try statement.step() { if let id = statement.columnString(0) { candidates.insert(id) } }
            }
        }
        guard candidates.count <= 1 else { throw ClipboardManagementError("duplicate_identity_conflict") }
        return candidates.first
    }
    func managementMetadata(_ record: ClipboardRecorderRecord, pinned: [String: ClipboardRepositoryPinnedMetadata]) throws -> ClipboardManagementRecord {
        ClipboardManagementRecord(id: record.id, kind: record.kind.rawValue, title: record.customTitle,
            pinned: record.pinned, pinboardID: pinned[record.id]?.pinboardID,
            tags: try managementTags(record.id).map(\.name),
            contentRevision: try loadSearchDocument(recordID: record.id)?.contentRevision ?? 1, createdAt: record.createdAt.ISO8601Format())
    }
    func managementExportRecord(_ record: ClipboardRecorderRecord, pinned: [String: ClipboardRepositoryPinnedMetadata],
                                boards: [ClipboardRepositoryPinboard]) throws -> ClipboardImportRecord {
        guard !record.snapshotSkipped, !record.excluded, record.restorable,
              let payload = try readPayload(recordID: record.id), payload.kind != .unknown, payload.kind != .mixed else { throw ClipboardManagementError("unexportable_record") }
        let tags = try managementTags(record.id)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wire = ClipboardImportRecord(kind: payload.kind.rawValue, text: payload.text,
            url: payload.kind == .url ? payload.urlString : nil,
            rtfBase64: payload.rtfData?.base64EncodedString(), pngBase64: payload.pngData?.base64EncodedString(),
            fileURLs: payload.kind == .fileURL ? payload.urlString.map { [$0] } : nil,
            pinboard: pinned[record.id].flatMap { metadata in boards.first { $0.id == metadata.pinboardID }?.name },
            tags: tags.filter { $0.builtin == "none" }.map(\.name), title: record.customTitle,
            createdAt: formatter.string(from: record.createdAt), lastCopiedAt: formatter.string(from: record.lastCopiedAt),
            isFavorite: tags.contains { $0.builtin == "favorite" })
        _ = try wire.validated()
        return wire
    }
    func managementAddTag(_ name: String, recordID: String, repository: ClipboardTagRepository) throws {
        let normalized = try ClipboardTagNameNormalizer().normalizedName(name)
        if ClipboardTagNameNormalizer.reservedAliases.contains(normalized) {
            let tag = try repository.ensureFavoriteTag()
            _ = try repository.addTag(recordID: recordID, tagID: tag.id)
        } else { _ = try repository.ensureTagAndAttach(displayName: name, recordID: recordID) }
    }
    func managementCreatePinboard(_ name: String) throws -> String {
        let id = "pinboard.import.\(UUID().uuidString.lowercased())"
        let now = Date().timeIntervalSince1970
        try managementSQL("""
            INSERT INTO clipboard_pinboards(id, name, color_name, sort_index, created_at, updated_at)
            VALUES (?, ?, 'blue', (SELECT COALESCE(MAX(sort_index), 0) + 1 FROM clipboard_pinboards), ?, ?)
            """, [.string(id), .string(name), .double(now), .double(now)])
        return id
    }
    func managementSQL(_ sql: String, _ bindings: [SQLiteBinding]) throws {
        try database.connection.withStatement(sql, bindings: bindings) { _ = try $0.step() }
    }
    func managementValidateFields(_ input: ClipboardManagementActionInput) throws {
        let recordOperations = ["list", "search", "show", "export", "delete", "pin", "unpin", "move", "tag_add", "tag_remove"]
        func require(_ condition: Bool) throws {
            if !condition { throw ClipboardManagementError("invalid_operation_fields") }
        }
        try require(input.document == nil || input.operation == "import")
        try require(input.recordIDs.isEmpty || recordOperations.contains(input.operation))
        try require(input.query == nil || recordOperations.contains(input.operation))
        try require(!input.all || recordOperations.contains(input.operation))
        try require(input.pinboardID == nil || recordOperations.contains(input.operation) || input.operation == "pinboard_rename")
        try require(input.name == nil || ["pinboard_create", "pinboard_rename"].contains(input.operation))
        try require(input.tag == nil || ["list", "search", "show", "export", "delete", "tag_add", "tag_remove"].contains(input.operation))
        try require(input.confirmationToken == nil || input.isMutating || ["show", "export"].contains(input.operation))
        try require((input.limit == 100 && input.offset == 0) || ["list", "search"].contains(input.operation))
        if input.all {
            let destinationPinboard = ["pin", "move"].contains(input.operation)
            try require(input.recordIDs.isEmpty && input.query == nil && input.tag == nil &&
                (input.pinboardID == nil || destinationPinboard))
        }
        if ["tag_add", "tag_remove"].contains(input.operation) {
            try require(!input.recordIDs.isEmpty && input.query == nil && input.pinboardID == nil && !input.all)
        }
    }
    func managementResolvedQuery(_ query: String, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func token(_ date: Date) -> String {
            let values = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
        }
        let today = token(now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map(token) ?? today
        return query.split(whereSeparator: { $0.isWhitespace }).map {
            switch $0.lowercased() {
            case "today", "今天", "今日": return today
            case "yesterday", "昨天", "昨日": return yesterday
            default: return String($0)
            }
        }.joined(separator: " ")
    }
    func managementToken(_ input: ClipboardManagementActionInput, selectedRecordIDs: [String]? = nil) throws -> String {
        let canonical = ClipboardManagementActionInput(operation: input.operation, document: input.document,
            recordIDs: input.recordIDs.sorted(), query: input.query, pinboardID: input.pinboardID,
            tag: input.tag, name: input.name, limit: input.limit, offset: input.offset, all: input.all)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256(); hash.update(data: try encoder.encode(canonical))
        if let selectedRecordIDs {
            hash.update(data: Data("management.selected-record-ids.v1".utf8))
            hash.update(data: try encoder.encode(selectedRecordIDs.sorted()))
        }
        // A conservative global snapshot invalidates confirmation after any
        // relevant record, membership, board, or tag change (including ABA).
        let projections = [
            "SELECT id, signature_sha256, CAST(updated_at AS TEXT), CAST(pinned AS TEXT), COALESCE(custom_title, '') FROM clipboard_items ORDER BY id",
            "SELECT record_id, CAST(content_revision AS TEXT), revision, CAST(updated_at AS TEXT) FROM clipboard_search_documents ORDER BY record_id",
            "SELECT id, name, CAST(updated_at AS TEXT) FROM clipboard_pinboards ORDER BY id",
            "SELECT record_id, pinboard_id, COALESCE(display_name, ''), CAST(updated_at AS TEXT) FROM clipboard_pinned_metadata ORDER BY record_id",
            "SELECT id, normalized_name, CAST(content_revision AS TEXT) FROM clipboard_tags ORDER BY id",
            "SELECT record_id, tag_id, CAST(created_at AS TEXT) FROM clipboard_record_tags ORDER BY record_id, tag_id"
        ]
        let widths = [5, 4, 3, 4, 3, 3]
        for (index, sql) in projections.enumerated() {
            hash.update(data: Data(sql.utf8))
            try database.connection.withStatement(sql) { statement in
                while try statement.step() {
                    let row = (0..<widths[index]).map { statement.columnString(Int32($0)) ?? "" }
                    hash.update(data: try encoder.encode(row))
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
