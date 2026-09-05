import Foundation

public struct ClipboardTagEnsureAndAttachResult: Sendable {
    public let tag: ClipboardTag
    public let created: Bool
    public let attached: Bool
    public let mutation: ClipboardTagMutationResult

    public init(
        tag: ClipboardTag,
        created: Bool,
        attached: Bool,
        mutation: ClipboardTagMutationResult
    ) {
        self.tag = tag
        self.created = created
        self.attached = attached
        self.mutation = mutation
    }
}

public final class ClipboardTagRepository {
    private let database: AppDatabase
    private let repository: ClipboardRepository?
    private let normalizer = ClipboardTagNameNormalizer()

    public init(database: AppDatabase) {
        self.database = database
        self.repository = nil
    }

    public init(repository: ClipboardRepository) {
        self.database = repository.database
        self.repository = repository
    }

    @discardableResult
    public func ensureFavoriteTag() throws -> ClipboardTag {
        let now = Date()
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_tags
                (id, display_name, normalized_name, color_token, sort_order, built_in_kind, is_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                normalized_name = excluded.normalized_name,
                color_token = excluded.color_token,
                sort_order = excluded.sort_order,
                built_in_kind = excluded.built_in_kind,
                is_enabled = 1,
                updated_at = excluded.updated_at,
                content_revision = clipboard_tags.content_revision + 1
            WHERE clipboard_tags.display_name != excluded.display_name
               OR clipboard_tags.normalized_name != excluded.normalized_name
               OR clipboard_tags.color_token != excluded.color_token
               OR clipboard_tags.sort_order != excluded.sort_order
               OR clipboard_tags.built_in_kind != excluded.built_in_kind
               OR clipboard_tags.is_enabled != 1
            """,
            bindings: [
                .string(Self.favoriteTagID),
                .string(Self.favoriteDisplayName),
                .string(Self.favoriteNormalizedName),
                .string(Self.favoriteColorToken),
                .int(0),
                .string(ClipboardTagBuiltInKind.favorite.rawValue),
                .double(now.timeIntervalSince1970),
                .double(now.timeIntervalSince1970)
            ]
        ) { statement in
            _ = try statement.step()
        }
        guard let tag = try loadTag(id: Self.favoriteTagID) else {
            throw ClipboardTagMutationError.tagNotFound(Self.favoriteTagID)
        }
        return tag
    }

    public func loadTags() throws -> [ClipboardTag] {
        try ensureFavoriteTag()
        try ensureScreenshotTag()
        return try database.connection.withStatement(
            """
            SELECT id, display_name, normalized_name, color_token, sort_order, built_in_kind, is_enabled, content_revision, created_at, updated_at
            FROM clipboard_tags
            WHERE is_enabled = 1
            ORDER BY
                CASE WHEN built_in_kind = 'favorite' THEN 0 ELSE 1 END,
                sort_order ASC,
                display_name ASC
            """
        ) { statement in
            var tags: [ClipboardTag] = []
            while try statement.step() {
                tags.append(decodeTag(statement))
            }
            return tags
        }
    }

    public func loadRecordTags(recordIDs: [String]) throws -> [String: [ClipboardTag]] {
        guard !recordIDs.isEmpty else {
            return [:]
        }
        let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
        var tagsByRecord = try database.connection.withStatement(
            """
            SELECT
                clipboard_record_tags.record_id,
                clipboard_tags.id,
                clipboard_tags.display_name,
                clipboard_tags.normalized_name,
                clipboard_tags.color_token,
                clipboard_tags.sort_order,
                clipboard_tags.built_in_kind,
                clipboard_tags.is_enabled,
                clipboard_tags.content_revision,
                clipboard_tags.created_at,
                clipboard_tags.updated_at
            FROM clipboard_record_tags
            JOIN clipboard_tags ON clipboard_tags.id = clipboard_record_tags.tag_id
            WHERE clipboard_record_tags.record_id IN (\(placeholders))
              AND clipboard_tags.is_enabled = 1
            ORDER BY
                CASE WHEN clipboard_tags.built_in_kind = 'favorite' THEN 0 ELSE 1 END,
                clipboard_tags.sort_order ASC,
                clipboard_tags.display_name ASC
            """,
            bindings: recordIDs.map(SQLiteBinding.string)
        ) { statement in
            var tagsByRecord: [String: [ClipboardTag]] = [:]
            while try statement.step() {
                guard let recordID = statement.columnString(0) else {
                    continue
                }
                tagsByRecord[recordID, default: []].append(decodeJoinedTag(statement))
            }
            return tagsByRecord
        }
        let screenshotTag = try ensureScreenshotTag()
        guard screenshotTag.isEnabled else { return tagsByRecord }
        let screenshotRecordIDs = try database.connection.withStatement(
            """
            SELECT id
            FROM clipboard_items
            WHERE id IN (\(placeholders)) AND origin_kind = ?
            """,
            bindings: recordIDs.map(SQLiteBinding.string) + [.string(ClipboardRecordOrigin.screenshot.rawValue)]
        ) { statement in
            var result: [String] = []
            while try statement.step() {
                if let recordID = statement.columnString(0) { result.append(recordID) }
            }
            return result
        }
        for recordID in screenshotRecordIDs where !tagsByRecord[recordID, default: []].contains(where: { $0.id == screenshotTag.id }) {
            tagsByRecord[recordID, default: []].append(screenshotTag)
        }
        return tagsByRecord
    }

    public func createTag(displayName: String, colorToken: String = "blue") throws -> ClipboardTagMutationResult {
        let tag = try database.connection.transaction {
            try createTagInTransaction(displayName: displayName, colorToken: colorToken)
        }
        return ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: [])
    }

    public func createTagAndAttach(
        displayName: String,
        colorToken: String = "blue",
        recordID: String
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            try ensureRecordExists(recordID)
            let tag = try createTagInTransaction(displayName: displayName, colorToken: colorToken)
            try insertRecordTag(recordID: recordID, tagID: tag.id)
            return try markSearchDocumentsDirtyInTransaction(
                for: ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: [recordID])
            )
        }
    }

    /// Atomically creates (when needed) a user tag and attaches it to a record.
    /// This is intentionally distinct from `createTagAndAttach`: UI creation
    /// retains its duplicate-name error while plugin ensure operations converge
    /// concurrent first creates on the normalized-name uniqueness constraint.
    public func ensureTagAndAttach(
        displayName: String,
        colorToken: String = "blue",
        recordID: String
    ) throws -> ClipboardTagEnsureAndAttachResult {
        try database.connection.transaction {
            try ensureRecordExists(recordID)
            let normalized = try normalizeUserName(displayName)
            let id = "tag.\(UUID().uuidString.lowercased())"
            let now = Date()
            let sortOrder = try nextOrdinarySortOrder()
            try database.connection.withStatement(
                """
                INSERT INTO clipboard_tags
                    (id, display_name, normalized_name, color_token, sort_order, built_in_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(normalized_name) DO NOTHING
                """,
                bindings: [
                    .string(id),
                    .string(normalized.displayName),
                    .string(normalized.normalizedName),
                    .string(colorToken),
                    .int(sortOrder),
                    .string(ClipboardTagBuiltInKind.none.rawValue),
                    .double(now.timeIntervalSince1970),
                    .double(now.timeIntervalSince1970)
                ]
            ) { statement in
                _ = try statement.step()
            }
            // Read this immediately: a later membership insert also changes
            // SQLite's changes() value through its own statement.
            let created = (try database.connection.firstInt("SELECT changes()")) == 1
            guard let ensuredTag = try loadTag(normalizedName: normalized.normalizedName) else {
                throw ClipboardTagMutationError.duplicateName
            }
            try insertRecordTag(recordID: recordID, tagID: ensuredTag.id)
            let attached = (try database.connection.firstInt("SELECT changes()")) == 1
            let mutation = try markSearchDocumentsDirtyInTransaction(
                for: ClipboardTagMutationResult(
                    changedTagIDs: attached ? [ensuredTag.id] : [],
                    affectedRecordIDs: attached ? [recordID] : []
                )
            )
            // Membership triggers advance the tag revision, so return the
            // durable value after the insert rather than a pre-trigger snapshot.
            guard let actualTag = try loadTag(id: ensuredTag.id) else {
                throw ClipboardTagMutationError.tagNotFound(ensuredTag.id)
            }
            return ClipboardTagEnsureAndAttachResult(
                tag: actualTag,
                created: created,
                attached: attached,
                mutation: mutation
            )
        }
    }

    public func renameTag(
        tagID: String,
        displayName: String,
        expectedContentRevision: Int64? = nil
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            if let expectedContentRevision,
               expectedContentRevision <= 0 || expectedContentRevision == .max {
                throw ClipboardTagMutationError.revisionConflict
            }
            let tag = try mutableTag(tagID: tagID)
            let normalized = try normalizeUserName(displayName)
            try ensureNameAvailable(normalized.normalizedName, excluding: tag.id)
            let affected = try recordIDs(tagID: tag.id)
            var bindings: [SQLiteBinding] = [
                .string(normalized.displayName),
                .string(normalized.normalizedName),
                .double(Date().timeIntervalSince1970),
                .string(tag.id),
            ]
            var revisionPredicate = ""
            if let expectedContentRevision {
                revisionPredicate = " AND content_revision = ?"
                bindings.append(.int64(expectedContentRevision))
            }
            bindings += [
                .string(normalized.displayName),
                .string(normalized.normalizedName),
            ]
            try database.connection.withStatement(
                """
                UPDATE clipboard_tags
                SET display_name = ?, normalized_name = ?, updated_at = ?,
                    content_revision = content_revision + 1
                WHERE id = ?\(revisionPredicate)
                  AND (display_name != ? OR normalized_name != ?)
                """,
                bindings: bindings
            ) { statement in
                _ = try statement.step()
            }
            if let expectedContentRevision {
                let didMutate = (try database.connection.firstInt("SELECT changes()")) == 1
                guard let actual = try loadTag(id: tag.id) else {
                    throw ClipboardTagMutationError.tagNotFound(tag.id)
                }
                let isIdempotent = actual.displayName == normalized.displayName &&
                    actual.normalizedName == normalized.normalizedName &&
                    actual.contentRevision == expectedContentRevision
                let didCommit = actual.displayName == normalized.displayName &&
                    actual.normalizedName == normalized.normalizedName &&
                    actual.contentRevision == expectedContentRevision + 1
                guard (didMutate && didCommit) || (!didMutate && isIdempotent) else {
                    throw ClipboardTagMutationError.revisionConflict
                }
            }
            return try markSearchDocumentsDirtyInTransaction(
                for: ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: affected)
            )
        }
    }

    public func updateTagColor(tagID: String, colorToken: String) throws -> ClipboardTagMutationResult {
        let tag = try mutableTag(tagID: tagID)
        try database.connection.withStatement(
            """
            UPDATE clipboard_tags
            SET color_token = ?, updated_at = ?, content_revision = content_revision + 1
            WHERE id = ? AND color_token != ?
            """,
            bindings: [.string(colorToken), .double(Date().timeIntervalSince1970), .string(tag.id), .string(colorToken)]
        ) { statement in
            _ = try statement.step()
        }
        return ClipboardTagMutationResult(changedTagIDs: [tag.id], affectedRecordIDs: [])
    }

    public func reorderTags(tagIDsInDisplayOrder: [String]) throws -> ClipboardTagMutationResult {
        let changed = try database.connection.transaction {
            var changedIDs: [String] = []
            for (offset, tagID) in tagIDsInDisplayOrder.enumerated() {
                let tag = try reorderableTag(tagID: tagID)
                try database.connection.withStatement(
                    """
                    UPDATE clipboard_tags
                    SET sort_order = ?, updated_at = ?, content_revision = content_revision + 1
                    WHERE id = ? AND sort_order != ?
                    """,
                    bindings: [.int(offset + 1), .double(Date().timeIntervalSince1970), .string(tag.id), .int(offset + 1)]
                ) { statement in
                    _ = try statement.step()
                }
                changedIDs.append(tag.id)
            }
            return changedIDs
        }
        return ClipboardTagMutationResult(changedTagIDs: changed, affectedRecordIDs: [])
    }

    public func deleteTag(
        tagID: String,
        expectedContentRevision: Int64? = nil,
        selectedTagID: String? = nil
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            let tag = try mutableTag(tagID: tagID)
            if let expectedContentRevision, tag.contentRevision != expectedContentRevision {
                throw ClipboardTagMutationError.revisionConflict
            }
            let affected = try recordIDs(tagID: tag.id)
            try database.connection.withStatement(
                "DELETE FROM clipboard_record_tags WHERE tag_id = ?",
                bindings: [.string(tag.id)]
            ) { statement in
                _ = try statement.step()
            }
            try database.connection.withStatement(
                "DELETE FROM clipboard_tags WHERE id = ?",
                bindings: [.string(tag.id)]
            ) { statement in
                _ = try statement.step()
            }
            return try markSearchDocumentsDirtyInTransaction(for: ClipboardTagMutationResult(
                changedTagIDs: [],
                affectedRecordIDs: affected,
                removedTagIDs: [tag.id],
                selectedTagTransition: selectedTagID == tag.id ? .clear : .none
            ))
        }
    }

    public func mergeTag(
        sourceTagID: String,
        targetTagID: String,
        selectedTagID: String? = nil
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            guard sourceTagID != targetTagID else {
                throw ClipboardTagMutationError.sourceEqualsTarget
            }
            let source = try mutableTag(tagID: sourceTagID)
            let target = try mutableTag(tagID: targetTagID)
            // rejectFavorite handles merge source and merge target immutability.
            try rejectFavorite(source, context: "merge source")
            try rejectFavorite(target, context: "merge target")
            let sourceAffected = try recordIDs(tagID: source.id)
            let targetAffected = try recordIDs(tagID: target.id)
            try database.connection.withStatement(
                """
                INSERT INTO clipboard_record_tags (record_id, tag_id, created_at)
                SELECT record_id, ?, ?
                FROM clipboard_record_tags
                WHERE tag_id = ?
                ON CONFLICT(record_id, tag_id) DO NOTHING
                """,
                bindings: [.string(target.id), .double(Date().timeIntervalSince1970), .string(source.id)]
            ) { statement in
                _ = try statement.step()
            }
            try database.connection.withStatement(
                "DELETE FROM clipboard_record_tags WHERE tag_id = ?",
                bindings: [.string(source.id)]
            ) { statement in
                _ = try statement.step()
            }
            try database.connection.withStatement(
                "DELETE FROM clipboard_tags WHERE id = ?",
                bindings: [.string(source.id)]
            ) { statement in
                _ = try statement.step()
            }
            let transition: ClipboardTagSelectionTransition = selectedTagID == source.id ? .switchTo(target.id) : .none
            return try markSearchDocumentsDirtyInTransaction(for: ClipboardTagMutationResult(
                changedTagIDs: [target.id],
                affectedRecordIDs: sourceAffected + targetAffected,
                removedTagIDs: [source.id],
                selectedTagTransition: transition
            ))
        }
    }

    public func addTag(
        recordID: String,
        tagID: String,
        expectedContentRevision: Int64? = nil
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            if let expectedContentRevision,
               expectedContentRevision <= 0 || expectedContentRevision == .max {
                throw ClipboardTagMutationError.revisionConflict
            }
            try ensureRecordExists(recordID)
            let tag = try tag(tagID: tagID)
            guard !tag.isScreenshot else {
                throw ClipboardTagMutationError.systemMembershipImmutable
            }
            if let expectedContentRevision {
                try database.connection.withStatement(
                    """
                    INSERT INTO clipboard_record_tags (record_id, tag_id, created_at)
                    SELECT ?, id, ?
                    FROM clipboard_tags
                    WHERE id = ? AND content_revision = ?
                    ON CONFLICT(record_id, tag_id) DO NOTHING
                    """,
                    bindings: [
                        .string(recordID), .double(Date().timeIntervalSince1970),
                        .string(tagID), .int64(expectedContentRevision),
                    ]
                ) { statement in _ = try statement.step() }
                let didMutate = (try database.connection.firstInt("SELECT changes()")) == 1
                try verifyCASMembershipOutcome(
                    recordID: recordID,
                    tagID: tagID,
                    expectedContentRevision: expectedContentRevision,
                    attached: true,
                    didMutate: didMutate
                )
            } else {
                try insertRecordTag(recordID: recordID, tagID: tagID)
            }
            return try markSearchDocumentsDirtyInTransaction(
                for: ClipboardTagMutationResult(changedTagIDs: [tagID], affectedRecordIDs: [recordID])
            )
        }
    }

    public func removeTag(
        recordID: String,
        tagID: String,
        expectedContentRevision: Int64? = nil
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            if let expectedContentRevision,
               expectedContentRevision <= 0 || expectedContentRevision == .max {
                throw ClipboardTagMutationError.revisionConflict
            }
            try ensureRecordExists(recordID)
            let tag = try tag(tagID: tagID)
            guard !tag.isScreenshot else {
                throw ClipboardTagMutationError.systemMembershipImmutable
            }
            if let expectedContentRevision {
                try database.connection.withStatement(
                    """
                    DELETE FROM clipboard_record_tags
                    WHERE record_id = ? AND tag_id = ?
                      AND EXISTS (
                          SELECT 1 FROM clipboard_tags
                          WHERE id = ? AND content_revision = ?
                      )
                    """,
                    bindings: [
                        .string(recordID), .string(tagID),
                        .string(tagID), .int64(expectedContentRevision),
                    ]
                ) { statement in _ = try statement.step() }
                let didMutate = (try database.connection.firstInt("SELECT changes()")) == 1
                try verifyCASMembershipOutcome(
                    recordID: recordID,
                    tagID: tagID,
                    expectedContentRevision: expectedContentRevision,
                    attached: false,
                    didMutate: didMutate
                )
            } else {
                try database.connection.withStatement(
                    "DELETE FROM clipboard_record_tags WHERE record_id = ? AND tag_id = ?",
                    bindings: [.string(recordID), .string(tagID)]
                ) { statement in
                    _ = try statement.step()
                }
            }
            return try markSearchDocumentsDirtyInTransaction(
                for: ClipboardTagMutationResult(changedTagIDs: [tagID], affectedRecordIDs: [recordID])
            )
        }
    }

    /// Toggles one record membership at the database transaction boundary.
    /// The decision cannot safely be made from an asynchronously published UI
    /// snapshot because a second queued gesture may otherwise choose the same
    /// branch before the first write commits.
    public func toggleTag(recordID: String, tagID: String) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            try ensureRecordExists(recordID)
            let tag = try tag(tagID: tagID)
            guard !tag.isScreenshot else {
                throw ClipboardTagMutationError.systemMembershipImmutable
            }
            if try hasRecordTag(recordID: recordID, tagID: tagID) {
                try database.connection.withStatement(
                    "DELETE FROM clipboard_record_tags WHERE record_id = ? AND tag_id = ?",
                    bindings: [.string(recordID), .string(tagID)]
                ) { statement in
                    _ = try statement.step()
                }
            } else {
                try insertRecordTag(recordID: recordID, tagID: tagID)
            }
            return try markSearchDocumentsDirtyInTransaction(for: ClipboardTagMutationResult(
                changedTagIDs: [tagID],
                affectedRecordIDs: [recordID]
            ))
        }
    }

    public func toggleFavorite(recordID: String) throws -> ClipboardTagMutationResult {
        let favorite = try ensureFavoriteTag()
        return try toggleTag(recordID: recordID, tagID: favorite.id)
    }

    /// Sets the favorite membership against the favorite tag's aggregate
    /// content revision. Unlike `toggleFavorite`, this is safe for an external
    /// caller that may resume after another tag or membership mutation.
    public func setFavorite(
        recordID: String,
        isFavorite: Bool,
        expectedContentRevision: Int64
    ) throws -> ClipboardTagMutationResult {
        let favorite = try ensureFavoriteTag()
        if isFavorite {
            return try addTag(
                recordID: recordID,
                tagID: favorite.id,
                expectedContentRevision: expectedContentRevision
            )
        }
        return try removeTag(
            recordID: recordID,
            tagID: favorite.id,
            expectedContentRevision: expectedContentRevision
        )
    }

    public func loadFavoriteTag() throws -> ClipboardTag {
        try ensureFavoriteTag()
    }

    @discardableResult
    public func ensureScreenshotTag() throws -> ClipboardTag {
        let now = Date()
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_tags
                (id, display_name, normalized_name, color_token, sort_order, built_in_kind, is_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            bindings: [
                .string(Self.screenshotTagID),
                .string(Self.screenshotDisplayName),
                .string(Self.screenshotNormalizedName),
                .string(Self.screenshotColorToken),
                .int(1),
                .string(ClipboardTagBuiltInKind.screenshot.rawValue),
                .double(now.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
            ]
        ) { statement in _ = try statement.step() }
        guard let tag = try loadTag(id: Self.screenshotTagID) else {
            throw ClipboardTagMutationError.tagNotFound(Self.screenshotTagID)
        }
        return tag
    }

    func attachScreenshotTag(recordID: String) throws {
        try ensureRecordExists(recordID)
        let screenshot = try ensureScreenshotTag()
        guard screenshot.isEnabled else {
            return
        }
        try insertRecordTag(recordID: recordID, tagID: screenshot.id)
    }

    @discardableResult
    public func setScreenshotTagEnabled(
        _ enabled: Bool,
        selectedTagID: String? = nil
    ) throws -> ClipboardTagMutationResult {
        try database.connection.transaction {
            let screenshot = try ensureScreenshotTag()
            let affectedRecordIDs = try screenshotOriginRecordIDs()
            try database.connection.withStatement(
                """
                UPDATE clipboard_tags
                SET is_enabled = ?, updated_at = ?, content_revision = content_revision + 1
                WHERE id = ? AND is_enabled != ?
                """,
                bindings: [
                    .bool(enabled),
                    .double(Date().timeIntervalSince1970),
                    .string(screenshot.id),
                    .bool(enabled),
                ]
            ) { statement in
                _ = try statement.step()
            }
            return try markSearchDocumentsDirtyInTransaction(for: ClipboardTagMutationResult(
                changedTagIDs: [screenshot.id],
                affectedRecordIDs: affectedRecordIDs,
                selectedTagTransition: !enabled && selectedTagID == screenshot.id ? .clear : .none
            ))
        }
    }

    private func screenshotOriginRecordIDs() throws -> [String] {
        try database.connection.withStatement(
            "SELECT id FROM clipboard_items WHERE origin_kind = ?",
            bindings: [.string(ClipboardRecordOrigin.screenshot.rawValue)]
        ) { statement in
            var result: [String] = []
            while try statement.step() {
                if let id = statement.columnString(0) { result.append(id) }
            }
            return result
        }
    }

    private func createTagInTransaction(displayName: String, colorToken: String) throws -> ClipboardTag {
        let normalized = try normalizeUserName(displayName)
        try ensureNameAvailable(normalized.normalizedName, excluding: nil)
        let id = "tag.\(UUID().uuidString.lowercased())"
        let now = Date()
        let sortOrder = try nextOrdinarySortOrder()
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_tags
                (id, display_name, normalized_name, color_token, sort_order, built_in_kind, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .string(id),
                .string(normalized.displayName),
                .string(normalized.normalizedName),
                .string(colorToken),
                .int(sortOrder),
                .string(ClipboardTagBuiltInKind.none.rawValue),
                .double(now.timeIntervalSince1970),
                .double(now.timeIntervalSince1970)
            ]
        ) { statement in
            _ = try statement.step()
        }
        guard let tag = try loadTag(id: id) else {
            throw ClipboardTagMutationError.tagNotFound(id)
        }
        return tag
    }

    /// Must run inside the enclosing tag mutation transaction. `upsertSearchDocument`
    /// nests through SQLiteConnection's transaction depth, so a failure rolls back
    /// membership/tag changes together with the search document and FTS writes.
    private func markSearchDocumentsDirtyInTransaction(
        for result: ClipboardTagMutationResult
    ) throws -> ClipboardTagMutationResult {
        guard !result.affectedRecordIDs.isEmpty else {
            return result
        }
        // This path runs inside the tag mutation transaction. Its fallback is
        // SQL-only so it cannot invert the database -> screenshot-lock order.
        let repository = repository ?? ClipboardRepository(database: database, databaseOnly: ())
        try repository.markSearchDocumentTagsDirty(recordIDs: result.affectedRecordIDs)
        return ClipboardTagMutationResult(
            changedTagIDs: result.changedTagIDs,
            affectedRecordIDs: result.affectedRecordIDs,
            removedTagIDs: result.removedTagIDs,
            selectedTagTransition: result.selectedTagTransition,
            searchInvalidation: ClipboardTagSearchInvalidation(affectedRecordIDs: result.affectedRecordIDs)
        )
    }

    private func normalizeUserName(_ value: String) throws -> (displayName: String, normalizedName: String) {
        do {
            return try normalizer.validateUserTagName(value)
        } catch let error as ClipboardTagNameValidationError {
            throw ClipboardTagMutationError.invalidName(error)
        }
    }

    private func ensureNameAvailable(_ normalizedName: String, excluding excludedID: String?) throws {
        let existing = try database.connection.withStatement(
            """
            SELECT id
            FROM clipboard_tags
            WHERE normalized_name = ?
            LIMIT 1
            """,
            bindings: [.string(normalizedName)]
        ) { statement in
            try statement.step() ? statement.columnString(0) : nil
        }
        if let existing, existing != excludedID {
            throw ClipboardTagMutationError.duplicateName
        }
    }

    private func mutableTag(tagID: String) throws -> ClipboardTag {
        let tag = try tag(tagID: tagID)
        if tag.isFavorite {
            throw ClipboardTagMutationError.favoriteImmutable
        }
        guard !tag.isBuiltIn else {
            throw ClipboardTagMutationError.builtInImmutable
        }
        return tag
    }

    private func reorderableTag(tagID: String) throws -> ClipboardTag {
        let tag = try tag(tagID: tagID)
        guard !tag.isFavorite else {
            throw ClipboardTagMutationError.favoriteImmutable
        }
        return tag
    }

    private func tag(tagID: String) throws -> ClipboardTag {
        guard let tag = try loadTag(id: tagID) else {
            throw ClipboardTagMutationError.tagNotFound(tagID)
        }
        return tag
    }

    private func rejectFavorite(_ tag: ClipboardTag, context: String) throws {
        guard !tag.isFavorite else {
            _ = "ClipboardTagMutationError.favoriteImmutable \(context)"
            throw ClipboardTagMutationError.favoriteImmutable
        }
    }

    private func loadTag(id: String) throws -> ClipboardTag? {
        try database.connection.withStatement(
            """
            SELECT id, display_name, normalized_name, color_token, sort_order, built_in_kind, is_enabled, content_revision, created_at, updated_at
            FROM clipboard_tags
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.string(id)]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            return decodeTag(statement)
        }
    }

    private func loadTag(normalizedName: String) throws -> ClipboardTag? {
        try database.connection.withStatement(
            """
            SELECT id, display_name, normalized_name, color_token, sort_order, built_in_kind, is_enabled, content_revision, created_at, updated_at
            FROM clipboard_tags
            WHERE normalized_name = ?
            LIMIT 1
            """,
            bindings: [.string(normalizedName)]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            return decodeTag(statement)
        }
    }

    private func insertRecordTag(recordID: String, tagID: String) throws {
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_record_tags (record_id, tag_id, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(record_id, tag_id) DO NOTHING
            """,
            bindings: [.string(recordID), .string(tagID), .double(Date().timeIntervalSince1970)]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func verifyCASMembershipOutcome(
        recordID: String,
        tagID: String,
        expectedContentRevision: Int64,
        attached: Bool,
        didMutate: Bool
    ) throws {
        guard let actual = try loadTag(id: tagID) else {
            throw ClipboardTagMutationError.tagNotFound(tagID)
        }
        let membershipMatches = try hasRecordTag(recordID: recordID, tagID: tagID) == attached
        // A successful insert/delete advances the tag revision via its trigger.
        // An idempotent operation leaves it unchanged. Any other revision means
        // the conditional SQL did not own this state transition.
        let expectedActualRevision = expectedContentRevision + (didMutate ? 1 : 0)
        guard membershipMatches, actual.contentRevision == expectedActualRevision else {
            throw ClipboardTagMutationError.revisionConflict
        }
    }

    private func hasRecordTag(recordID: String, tagID: String) throws -> Bool {
        let count = try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_record_tags WHERE record_id = ? AND tag_id = ?",
            bindings: [.string(recordID), .string(tagID)]
        ) ?? 0
        return count > 0
    }

    private func ensureRecordExists(_ recordID: String) throws {
        let exists = try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_items WHERE id = ?",
            bindings: [.string(recordID)]
        ) ?? 0
        guard exists > 0 else {
            throw ClipboardTagMutationError.recordNotFound(recordID)
        }
    }

    private func recordIDs(tagID: String) throws -> [String] {
        try database.connection.withStatement(
            """
            SELECT record_id
            FROM clipboard_record_tags
            WHERE tag_id = ?
            ORDER BY record_id ASC
            """,
            bindings: [.string(tagID)]
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

    private func nextOrdinarySortOrder() throws -> Int {
        let current = try database.connection.firstInt(
            "SELECT COALESCE(MAX(sort_order), 0) FROM clipboard_tags WHERE built_in_kind != ?",
            bindings: [.string(ClipboardTagBuiltInKind.favorite.rawValue)]
        ) ?? 0
        return current + 1
    }

    private func decodeTag(_ statement: SQLiteStatement) -> ClipboardTag {
        ClipboardTag(
            id: statement.columnString(0) ?? "",
            displayName: statement.columnString(1) ?? "",
            normalizedName: statement.columnString(2) ?? "",
            colorToken: statement.columnString(3) ?? "blue",
            sortOrder: statement.columnInt(4),
            builtInKind: ClipboardTagBuiltInKind(rawValue: statement.columnString(5) ?? "") ?? .none,
            isEnabled: statement.columnBool(6),
            contentRevision: max(1, statement.columnInt64(7)),
            createdAt: Date(timeIntervalSince1970: statement.columnDouble(8)),
            updatedAt: Date(timeIntervalSince1970: statement.columnDouble(9))
        )
    }

    private func decodeJoinedTag(_ statement: SQLiteStatement) -> ClipboardTag {
        ClipboardTag(
            id: statement.columnString(1) ?? "",
            displayName: statement.columnString(2) ?? "",
            normalizedName: statement.columnString(3) ?? "",
            colorToken: statement.columnString(4) ?? "blue",
            sortOrder: statement.columnInt(5),
            builtInKind: ClipboardTagBuiltInKind(rawValue: statement.columnString(6) ?? "") ?? .none,
            isEnabled: statement.columnBool(7),
            contentRevision: max(1, statement.columnInt64(8)),
            createdAt: Date(timeIntervalSince1970: statement.columnDouble(9)),
            updatedAt: Date(timeIntervalSince1970: statement.columnDouble(10))
        )
    }

    public static let favoriteTagID = "tag.favorite"
    private static let favoriteDisplayName = "收藏"
    private static let favoriteNormalizedName = "favorite"
    private static let favoriteColorToken = "favorite"
    public static let screenshotTagID = "tag.screenshot"
    private static let screenshotDisplayName = "Screenshot"
    private static let screenshotNormalizedName = "screenshot"
    private static let screenshotColorToken = "orange"
}
