import CryptoKit
import Foundation

public struct ClipboardRepositoryPinboard: Equatable {
    public let id: String
    public let name: String
    public let colorName: String
    public let sortIndex: Int

    public init(id: String, name: String, colorName: String, sortIndex: Int) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.sortIndex = sortIndex
    }
}

public struct ClipboardRepositoryPinnedMetadata: Equatable {
    public var displayName: String?
    public var pinboardID: String

    public init(displayName: String?, pinboardID: String) {
        self.displayName = displayName
        self.pinboardID = pinboardID
    }
}

public struct ClipboardRepositoryInsertResult {
    public let record: ClipboardRecorderRecord
    public let inserted: Bool
    public let duplicate: Bool
    public let skipped: Bool
    public let skippedReason: ClipboardCaptureSkipReason?
}

public struct ClipboardRepositoryPrunePolicy: Sendable {
    public let retentionSeconds: Int?
    public let maxItems: Int?
    public let preserveFavorite: Bool
    public let now: Date

    public init(
        retentionSeconds: Int?,
        maxItems: Int?,
        preserveFavorite: Bool,
        now: Date = Date()
    ) {
        self.retentionSeconds = retentionSeconds.map { max(0, $0) }
        self.maxItems = maxItems.map { max(1, $0) }
        self.preserveFavorite = preserveFavorite
        self.now = now
    }
}

public struct ClipboardRepositoryPruneResult {
    public let deletedCount: Int
    public let redactedCount: Int
    public let deletedRecordIDs: [String]

    public init(
        deletedCount: Int,
        redactedCount: Int,
        deletedRecordIDs: [String] = []
    ) {
        self.deletedCount = deletedCount
        self.redactedCount = redactedCount
        self.deletedRecordIDs = deletedRecordIDs
    }
}

/// Opaque capability returned by a zero-write policy preview.  The record set
/// deliberately remains private to BlocksCore; callers can retain the token
/// and submit it, but cannot turn a preview into a different deletion list.
public struct ClipboardRepositoryPrunePlanToken: Equatable, Sendable {
    public let opaqueValue: String
    fileprivate let deleteRecordIDs: Set<String>

    fileprivate init(deleteRecordIDs: Set<String>) {
        self.deleteRecordIDs = deleteRecordIDs
        opaqueValue = SHA256.hash(data: Data(deleteRecordIDs.sorted().joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate func matches(_ other: ClipboardRepositoryPrunePlanToken) -> Bool {
        deleteRecordIDs == other.deleteRecordIDs
    }
}

public struct ClipboardRepositoryPrunePlan: Sendable {
    public let deleteCount: Int
    public let token: ClipboardRepositoryPrunePlanToken

    fileprivate init(deleteRecordIDs: Set<String>) {
        deleteCount = deleteRecordIDs.count
        token = ClipboardRepositoryPrunePlanToken(deleteRecordIDs: deleteRecordIDs)
    }
}

public struct ClipboardRepositoryClearResult: Equatable {
    public let deletedCount: Int
    public let remainingCount: Int
    public let deletedRecordIDs: [String]

    public init(
        deletedCount: Int,
        remainingCount: Int,
        deletedRecordIDs: [String] = []
    ) {
        self.deletedCount = deletedCount
        self.remainingCount = remainingCount
        self.deletedRecordIDs = deletedRecordIDs
    }
}

public enum ScreenshotHistoryMaintenanceStatus: Equatable, Sendable {
    case notStarted
    case completed
    case recoveryFailed(code: String)
    case cleanupFailed(code: String)
}

public enum ClipboardOCRRetryPreparationResult: Equatable {
    case ready(ClipboardSearchDocument)
    case alreadyPending(ClipboardSearchDocument)
    case alreadyRunning(ClipboardSearchDocument)
    case locked
    case documentMissing
}

public enum ClipboardRepositoryError: Error, LocalizedError {
    case invalidPayload(recordID: String, field: String)
    case pinboardNotFound(String)
    case recordNotFound(String)
    case sidecarCleanupPersistenceFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidPayload(recordID, field):
            return "Invalid clipboard payload \(field) for record \(recordID)."
        case let .pinboardNotFound(pinboardID):
            return "Clipboard pinboard \(pinboardID) was not found."
        case let .recordNotFound(recordID):
            return "Clipboard record \(recordID) was not found."
        case .sidecarCleanupPersistenceFailed:
            return "Clipboard sidecar cleanup could not be persisted."
        }
    }
}

public enum ClipboardRepositoryConditionalDeleteResult: Equatable, Sendable {
    case deleted
    case recordNotFound
    case revisionConflict
}

final class ClipboardSidecarRollbackTracker {
    private(set) var relativePaths = Set<String>()

    func record(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }
        relativePaths.insert(relativePath)
    }
}

public final class ClipboardRepository: @unchecked Sendable {
    let database: AppDatabase
    let blobStore: BlobStore
    let screenshotHistoryFailureInjector: ((ScreenshotHistoryCommitFailurePoint) throws -> Void)?
    let sidecarDeletionFailureInjector: (@Sendable (String) throws -> Void)?
    private let screenshotHistoryMaintenanceFailureInjector: (() throws -> Void)?
    private let screenshotHistoryLock: NSRecursiveLock
    private var screenshotHistoryRecoverySucceeded = false
    public private(set) var screenshotHistoryMaintenanceStatus: ScreenshotHistoryMaintenanceStatus = .notStarted

    public init(database: AppDatabase, blobStore: BlobStore? = nil) {
        self.database = database
        self.blobStore = blobStore ?? BlobStore(directory: database.environment.blobDirectory)
        self.screenshotHistoryLock = ScreenshotHistorySerializationRegistry.shared.lock(
            for: self.blobStore.directory
        )
        self.screenshotHistoryFailureInjector = nil
        self.sidecarDeletionFailureInjector = nil
        self.screenshotHistoryMaintenanceFailureInjector = nil
        performScreenshotHistoryStartupMaintenance()
    }

    /// Database-only helper for callers which already hold a database
    /// transaction and only need repository SQL.  In particular, it must not
    /// acquire screenshot serialization or perform filesystem maintenance.
    init(database: AppDatabase, blobStore: BlobStore? = nil, databaseOnly: Void = ()) {
        self.database = database
        self.blobStore = blobStore ?? BlobStore(directory: database.environment.blobDirectory)
        self.screenshotHistoryLock = ScreenshotHistorySerializationRegistry.shared.lock(
            for: self.blobStore.directory
        )
        self.screenshotHistoryFailureInjector = nil
        self.sidecarDeletionFailureInjector = nil
        self.screenshotHistoryMaintenanceFailureInjector = nil
    }

    init(
        database: AppDatabase,
        blobStore: BlobStore? = nil,
        screenshotHistoryFailureInjector: @escaping (ScreenshotHistoryCommitFailurePoint) throws -> Void,
        screenshotHistoryMaintenanceFailureInjector: (() throws -> Void)? = nil,
        sidecarDeletionFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.database = database
        self.blobStore = blobStore ?? BlobStore(directory: database.environment.blobDirectory)
        self.screenshotHistoryLock = ScreenshotHistorySerializationRegistry.shared.lock(
            for: self.blobStore.directory
        )
        self.screenshotHistoryFailureInjector = screenshotHistoryFailureInjector
        self.sidecarDeletionFailureInjector = sidecarDeletionFailureInjector
        self.screenshotHistoryMaintenanceFailureInjector = screenshotHistoryMaintenanceFailureInjector
        performScreenshotHistoryStartupMaintenance()
    }

    init(
        database: AppDatabase,
        blobStore: BlobStore? = nil,
        sidecarDeletionFailureInjector: @escaping @Sendable (String) throws -> Void
    ) {
        self.database = database
        self.blobStore = blobStore ?? BlobStore(directory: database.environment.blobDirectory)
        self.screenshotHistoryLock = ScreenshotHistorySerializationRegistry.shared.lock(for: self.blobStore.directory)
        self.screenshotHistoryFailureInjector = nil
        self.screenshotHistoryMaintenanceFailureInjector = nil
        self.sidecarDeletionFailureInjector = sidecarDeletionFailureInjector
        performScreenshotHistoryStartupMaintenance()
    }

    private func performScreenshotHistoryStartupMaintenance() {
        do {
            try withScreenshotHistorySerialization {
                do {
                    try screenshotHistoryMaintenanceFailureInjector?()
                    try recoverScreenshotHistorySidecars()
                    screenshotHistoryRecoverySucceeded = true
                } catch {
                    screenshotHistoryRecoverySucceeded = false
                    throw ScreenshotHistoryStartupMaintenanceError.recoveryFailed
                }
                do {
                    _ = try drainSidecarCleanupOutbox()
                    try cleanupUnreferencedSidecars()
                } catch {
                    throw ScreenshotHistoryStartupMaintenanceError.cleanupFailed
                }
            }
            screenshotHistoryMaintenanceStatus = .completed
        } catch ScreenshotHistoryStartupMaintenanceError.cleanupFailed {
            screenshotHistoryMaintenanceStatus = .cleanupFailed(code: "sidecar_cleanup_failed")
        } catch {
            screenshotHistoryMaintenanceStatus = .recoveryFailed(code: "sidecar_recovery_failed")
        }
    }

    public func prepareOCRRetry(recordID: String) throws -> ClipboardOCRRetryPreparationResult {
        try database.connection.transaction {
            guard let document = try loadSearchDocument(recordID: recordID) else {
                return .documentMissing
            }
            guard document.ocrTextSource != .userEdited,
                  document.ocrLockedContentRevision == nil else {
                return .locked
            }
            switch document.ocrState {
            case .running:
                return .alreadyRunning(document)
            case .pending:
                return .alreadyPending(document)
            case .notRequired, .succeeded, .failed:
                let pending = document.replacingOCR(
                    text: nil,
                    state: .pending,
                    errorCode: nil,
                    attemptCount: document.ocrAttemptCount,
                    source: ClipboardOCRTextSource.none
                )
                try upsertSearchDocument(pending)
                guard let canonical = try loadSearchDocument(recordID: recordID) else {
                    return .documentMissing
                }
                return .ready(canonical)
            }
        }
    }

    @discardableResult
    public func insert(
        record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload?,
        capturePolicy: ClipboardCapturePolicy = ClipboardCapturePolicy()
    ) throws -> ClipboardRepositoryInsertResult {
        let decision = capturePolicy.evaluate(record: record, payload: payload)
        let resolvedRecord = decision.record

        return try withSidecarRollbackTransaction { rollbackTracker in
                if !decision.skipped,
                   let placeholder = try loadRecord(recordID: resolvedRecord.id),
                   placeholder.snapshotSkipped,
                   placeholder.changeCount == resolvedRecord.changeCount,
                   let payload = decision.payload {
                    let searchDocument = ClipboardSearchDocumentBuilder().build(
                        record: resolvedRecord,
                        payload: payload
                    )
                    try upgradeSkippedPlaceholder(
                        placeholder,
                        with: resolvedRecord,
                        payload: payload,
                        searchDocument: searchDocument,
                        rollbackTracker: rollbackTracker
                    )
                    return ClipboardRepositoryInsertResult(
                        record: try loadRecord(recordID: resolvedRecord.id) ?? resolvedRecord,
                        inserted: true,
                        duplicate: false,
                        skipped: false,
                        skippedReason: nil
                    )
                }

                if let existing = try recordID(signature: resolvedRecord.signatureSHA256) {
                    if !decision.skipped {
                        try updateLastCopiedAt(recordID: existing, date: resolvedRecord.createdAt)
                    }
                    return ClipboardRepositoryInsertResult(
                        record: try loadRecord(recordID: existing) ?? resolvedRecord,
                        inserted: false,
                        duplicate: true,
                        skipped: decision.skipped,
                        skippedReason: decision.skippedReason
                    )
                }

                let searchDocument = ClipboardSearchDocumentBuilder().build(
                    record: resolvedRecord,
                    payload: decision.skipped ? nil : decision.payload
                )
                try insertRecord(resolvedRecord, compatibilitySearchText: searchDocument.ftsProjectionText)
                if decision.shouldPersistPayload, let payload = decision.payload {
                    try storePayload(
                        payload,
                        forRecordID: resolvedRecord.id,
                        rollbackTracker: rollbackTracker
                    )
                }
                try upsertSearchDocument(searchDocument)
                if resolvedRecord.pinned {
                    try upsertPinnedMetadata(recordID: resolvedRecord.id, pinboardID: defaultPinboardID, displayName: nil)
                }
                return ClipboardRepositoryInsertResult(
                    record: resolvedRecord,
                    inserted: !decision.skipped,
                    duplicate: false,
                    skipped: decision.skipped,
                    skippedReason: decision.skippedReason
                )
        }
    }

    public func loadRecent(limit: Int) throws -> [ClipboardRecorderRecord] {
        try queryRecords(
            """
            SELECT \(recordColumns)
            FROM clipboard_items
            ORDER BY COALESCE(last_copied_at, created_at) DESC,
                     created_at DESC,
                     change_count DESC,
                     id DESC
            LIMIT ?
            """,
            bindings: [.int(max(1, limit))]
        )
    }

    public func readPayload(recordID: String) throws -> ClipboardRecorderPayload? {
        try database.connection.withStatement(
            """
            SELECT kind, text, rtf_data, png_data, png_sidecar_path,
                   png_payload_sha256, url_string
            FROM clipboard_payloads
            WHERE record_id = ?
            """,
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            let kind = ClipboardRecorderItemKind(rawValue: statement.columnString(0) ?? "") ?? .unknown
            let text = statement.columnString(1)
            let rtfData = statement.columnData(2)
            let pngData: Data?
            if let sidecarPath = statement.columnString(4), !sidecarPath.isEmpty {
                pngData = try blobStore.read(
                    relativePath: sidecarPath,
                    expectedSHA256: statement.columnString(5)
                )
            } else {
                pngData = statement.columnData(3)
            }
            return ClipboardRecorderPayload(
                recordID: recordID,
                kind: kind,
                text: text,
                rtfData: rtfData,
                pngData: pngData,
                urlString: statement.columnString(6)
            )
        }
    }

    /// Reads only the textual representation needed by lightweight consumers.
    ///
    /// The SQL projection deliberately excludes rich-text and image columns so
    /// translation and similar actions never open an image sidecar or
    /// Base64-encode a stored blob. SQLite's `substr` bounds the value before it
    /// crosses the repository boundary.
    public func readBoundedText(
        recordID: String,
        maximumCharacterCount: Int
    ) throws -> String? {
        let limit = max(1, maximumCharacterCount)
        return try database.connection.withStatement(
            """
            SELECT substr(COALESCE(NULLIF(text, ''), url_string), 1, ?)
            FROM clipboard_payloads
            WHERE record_id = ?
            """,
            bindings: [
                .int(limit),
                .string(recordID),
            ]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            return statement.columnString(0)
        }
    }

    /// Reads the stored image bytes without rebuilding the full clipboard
    /// payload or Base64-encoding a multi-megabyte image.
    ///
    /// Preview generation uses this path on a background queue so SwiftUI body
    /// evaluation never performs database I/O or full-payload conversion.
    public func readImageData(recordID: String) throws -> Data? {
        try database.connection.withStatement(
            """
            SELECT png_data, png_sidecar_path, png_payload_sha256
            FROM clipboard_payloads
            WHERE record_id = ?
            """,
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            if let sidecarPath = statement.columnString(1), !sidecarPath.isEmpty {
                return try blobStore.read(
                    relativePath: sidecarPath,
                    expectedSHA256: statement.columnString(2)
                )
            }
            return statement.columnData(0)
        }
    }

    @discardableResult
    public func markCopied(recordID: String, at date: Date = Date()) throws -> Date {
        try ensureRecordExists(recordID)
        return try updateLastCopiedAt(recordID: recordID, date: date)
    }

    public func search(
        _ query: String,
        limit: Int,
        filteringBatch: (([ClipboardRecorderRecord]) throws -> [ClipboardRecorderRecord])? = nil
    ) throws -> [ClipboardRecorderRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if filteringBatch != nil {
                return try querySearchRecords(
                    """
                    SELECT \(recordColumns) FROM clipboard_items
                    ORDER BY COALESCE(last_copied_at, created_at) DESC,
                             created_at DESC, change_count DESC, id DESC
                    """,
                    limit: limit,
                    filteringBatch: filteringBatch
                )
            }
            return try loadRecent(limit: limit)
        }
        let expandedQuery = expandedRelativeDateQuery(trimmed)

        if database.ftsEnabled, let ftsQuery = makeFTSQuery(expandedQuery) {
            do {
                return try querySearchRecords(
                    """
                    SELECT \(recordColumns)
                    FROM clipboard_fts
                    JOIN clipboard_items ON clipboard_items.id = clipboard_fts.record_id
                    WHERE clipboard_fts MATCH ?
                    ORDER BY COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at) DESC,
                             clipboard_items.created_at DESC,
                             clipboard_items.change_count DESC,
                             clipboard_items.id DESC
                    LIMIT ?
                    """,
                    bindings: [.string(ftsQuery), .int(filteringBatch == nil ? max(1, limit) : -1)],
                    limit: limit,
                    filteringBatch: filteringBatch
                )
            } catch let error as ClipboardSearchBatchFilterError {
                // A failed filter is not an FTS failure. Retrying it against
                // LIKE could turn a partial/failed read into apparent success.
                throw error
            } catch {
                return try fallbackSearch(expandedQuery, limit: limit, filteringBatch: filteringBatch)
            }
        }

        return try fallbackSearch(expandedQuery, limit: limit, filteringBatch: filteringBatch)
    }

    public func loadPinboards() throws -> [ClipboardRepositoryPinboard] {
        try database.connection.withStatement(
            """
            SELECT id, name, color_name, sort_index
            FROM clipboard_pinboards
            ORDER BY sort_index ASC, name ASC
            """
        ) { statement in
            var pinboards: [ClipboardRepositoryPinboard] = []
            while try statement.step() {
                pinboards.append(
                    ClipboardRepositoryPinboard(
                        id: statement.columnString(0) ?? "",
                        name: statement.columnString(1) ?? "",
                        colorName: statement.columnString(2) ?? "gray",
                        sortIndex: statement.columnInt(3)
                    )
                )
            }
            return pinboards
        }
    }

    public func loadPinnedMetadata() throws -> [String: ClipboardRepositoryPinnedMetadata] {
        try database.connection.withStatement(
            """
            SELECT record_id, pinboard_id, display_name
            FROM clipboard_pinned_metadata
            """
        ) { statement in
            var metadata: [String: ClipboardRepositoryPinnedMetadata] = [:]
            while try statement.step() {
                guard let recordID = statement.columnString(0) else {
                    continue
                }
                metadata[recordID] = ClipboardRepositoryPinnedMetadata(
                    displayName: statement.columnString(2),
                    pinboardID: statement.columnString(1) ?? defaultPinboardID
                )
            }
            return metadata
        }
    }

    public func pin(recordID: String, pinboardID: String = "pinboard.unfiled") throws {
        try ensureRecordExists(recordID)
        try ensurePinboardExists(pinboardID)
        try database.connection.transaction {
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET pinned = 1, updated_at = ?
                WHERE id = ?
                """,
                bindings: [.double(Date().timeIntervalSince1970), .string(recordID)]
            ) { statement in
                _ = try statement.step()
            }
            try upsertPinnedMetadata(recordID: recordID, pinboardID: pinboardID, displayName: nil)
        }
    }

    public func unpin(recordID: String) throws {
        try database.connection.transaction {
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET pinned = 0, updated_at = ?
                WHERE id = ?
                """,
                bindings: [.double(Date().timeIntervalSince1970), .string(recordID)]
            ) { statement in
                _ = try statement.step()
            }
            try database.connection.withStatement(
                "DELETE FROM clipboard_pinned_metadata WHERE record_id = ?",
                bindings: [.string(recordID)]
            ) { statement in
                _ = try statement.step()
            }
        }
    }

    public func move(recordID: String, toPinboard pinboardID: String) throws {
        try ensureRecordExists(recordID)
        try ensurePinboardExists(pinboardID)
        let existingName = try loadPinnedMetadata()[recordID]?.displayName
        try database.connection.transaction {
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET pinned = 1, updated_at = ?
                WHERE id = ?
                """,
                bindings: [.double(Date().timeIntervalSince1970), .string(recordID)]
            ) { statement in
                _ = try statement.step()
            }
            try upsertPinnedMetadata(recordID: recordID, pinboardID: pinboardID, displayName: existingName)
        }
    }

    public func renamePinnedRecord(recordID: String, displayName: String) throws {
        try ensureRecordExists(recordID)
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPinboard = try loadPinnedMetadata()[recordID]?.pinboardID ?? defaultPinboardID
        try database.connection.transaction {
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET pinned = 1, updated_at = ?
                WHERE id = ?
                """,
                bindings: [.double(Date().timeIntervalSince1970), .string(recordID)]
            ) { statement in
                _ = try statement.step()
            }
            try upsertPinnedMetadata(
                recordID: recordID,
                pinboardID: existingPinboard,
                displayName: trimmed.isEmpty ? nil : trimmed
            )
        }
    }

    public func delete(
        recordID: String,
        expectedContentRevision: Int64? = nil,
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws -> ClipboardRepositoryConditionalDeleteResult {
        enum TransactionOutcome {
            case deleted([String])
            case recordNotFound
            case revisionConflict
        }
        let outcome: TransactionOutcome = try database.connection.transaction {
            let currentRevision: Int64? = try database.connection.withStatement(
                "SELECT content_revision FROM clipboard_items WHERE id = ?",
                bindings: [.string(recordID)]
            ) { statement in
                guard try statement.step() else { return nil }
                return statement.columnInt64(0)
            }
            guard let currentRevision else { return .recordNotFound }
            guard expectedContentRevision == nil
                    || expectedContentRevision == currentRevision else {
                return .revisionConflict
            }
            return .deleted(try deleteRecordsFromDatabase([recordID]))
        }
        switch outcome {
        case let .deleted(sidecars):
            onCommittedDeletion([recordID])
            deleteSidecars(sidecars)
            return .deleted
        case .recordNotFound:
            return .recordNotFound
        case .revisionConflict:
            return .revisionConflict
        }
    }

    public func clearUnfavorited(
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws -> ClipboardRepositoryClearResult {
        let favorite = try ClipboardTagRepository(database: database).ensureFavoriteTag()
        let outcome = try database.connection.transaction {
            let recordIDs = try database.connection.withStatement(
                """
                SELECT clipboard_items.id
                FROM clipboard_items
                LEFT JOIN clipboard_record_tags
                    ON clipboard_record_tags.record_id = clipboard_items.id
                    AND clipboard_record_tags.tag_id = ?
                WHERE clipboard_record_tags.tag_id IS NULL
                """,
                bindings: [.string(favorite.id)]
            ) { statement in
                var ids: [String] = []
                while try statement.step() {
                    if let id = statement.columnString(0) {
                        ids.append(id)
                    }
                }
                return ids
            }
            let sidecars = try deleteRecordsFromDatabase(recordIDs)
            let remainingCount = try database.connection.firstInt(
                "SELECT COUNT(*) FROM clipboard_items"
            ) ?? 0
            return (
                deletedCount: recordIDs.count,
                remainingCount: remainingCount,
                deletedRecordIDs: recordIDs.sorted(),
                sidecars: sidecars
            )
        }
        if !outcome.deletedRecordIDs.isEmpty {
            onCommittedDeletion(outcome.deletedRecordIDs)
        }
        deleteSidecars(outcome.sidecars)
        return ClipboardRepositoryClearResult(
            deletedCount: outcome.deletedCount,
            remainingCount: outcome.remainingCount,
            deletedRecordIDs: outcome.deletedRecordIDs
        )
    }

    /// Generates the exact records a policy would delete without mutating the
    /// database. The calculation is the same one used by `applyPolicy`.
    public func makePrunePlan(
        _ policy: ClipboardRepositoryPrunePolicy
    ) throws -> ClipboardRepositoryPrunePlan {
        try database.connection.transaction {
            try makePrunePlanInCurrentTransaction(policy)
        }
    }

    /// Replans and compares in one transaction. A stale preview performs no
    /// deletion, allowing the caller to request a new confirmation.
    public func applyPolicyConfirming(
        _ policy: ClipboardRepositoryPrunePolicy,
        expectedPlanToken: ClipboardRepositoryPrunePlanToken,
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws -> ClipboardRepositoryPruneResult? {
        let outcome = try database.connection.transaction { () -> ([String], [String])? in
            let plan = try makePrunePlanInCurrentTransaction(policy)
            guard expectedPlanToken.matches(plan.token) else { return nil }
            let deleteIDs = plan.token.deleteRecordIDs.sorted()
            return (deleteIDs, try deleteRecordsFromDatabase(deleteIDs))
        }
        guard let outcome else { return nil }
        if !outcome.0.isEmpty {
            onCommittedDeletion(outcome.0)
        }
        deleteSidecars(outcome.1)
        return ClipboardRepositoryPruneResult(
            deletedCount: outcome.0.count,
            redactedCount: 0,
            deletedRecordIDs: outcome.0
        )
    }

    /// Non-interactive callers (for example capture retention) keep the
    /// established behavior. Settings changes use `applyPolicyConfirming`.
    public func applyPolicy(
        _ policy: ClipboardRepositoryPrunePolicy,
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws -> ClipboardRepositoryPruneResult {
        let outcome = try database.connection.transaction { () -> ([String], [String]) in
            let plan = try makePrunePlanInCurrentTransaction(policy)
            let deleteIDs = plan.token.deleteRecordIDs.sorted()
            return (deleteIDs, try deleteRecordsFromDatabase(deleteIDs))
        }
        if !outcome.0.isEmpty {
            onCommittedDeletion(outcome.0)
        }
        deleteSidecars(outcome.1)
        return ClipboardRepositoryPruneResult(
            deletedCount: outcome.0.count,
            redactedCount: 0,
            deletedRecordIDs: outcome.0
        )
    }

    private func makePrunePlanInCurrentTransaction(
        _ policy: ClipboardRepositoryPrunePolicy
    ) throws -> ClipboardRepositoryPrunePlan {
        let favoriteRecordIDs = policy.preserveFavorite ? try favoriteRecordIDs() : []
        let retainedRecords = try loadAllRecords()
            .filter { record in
                if policy.preserveFavorite, favoriteRecordIDs.contains(record.id) {
                    return true
                }
                guard let retentionSeconds = policy.retentionSeconds else {
                    return true
                }
                return record.lastCopiedAt >= policy.now.addingTimeInterval(-TimeInterval(retentionSeconds))
            }
            .sorted { ClipboardRecordOrdering.isMoreRecent($0, than: $1) }

        let keepIDs: Set<String>
        if let maxItems = policy.maxItems, policy.preserveFavorite {
            let favorites = retainedRecords.filter { favoriteRecordIDs.contains($0.id) }
            let ordinaryLimit = max(0, maxItems - favorites.count)
            let ordinary = retainedRecords.filter { !favoriteRecordIDs.contains($0.id) }.prefix(ordinaryLimit)
            keepIDs = Set((favorites + ordinary).map(\.id))
        } else if let maxItems = policy.maxItems {
            keepIDs = Set(retainedRecords.prefix(maxItems).map(\.id))
        } else {
            keepIDs = Set(retainedRecords.map(\.id))
        }

        let allIDs = Set(try loadAllRecords().map(\.id))
        return ClipboardRepositoryPrunePlan(
            deleteRecordIDs: allIDs.subtracting(keepIDs)
        )
    }

    private var defaultPinboardID: String {
        "pinboard.unfiled"
    }

    var recordColumns: String {
        """
        clipboard_items.id,
        clipboard_items.created_at,
        clipboard_items.change_count,
        clipboard_items.kind,
        clipboard_items.format_summary_json,
        clipboard_items.source_app_json,
        clipboard_items.signature_sha256,
        clipboard_items.signature_sha256_12,
        clipboard_items.fixture_owned,
        clipboard_items.pinned,
        clipboard_items.restorable,
        clipboard_items.excluded,
        clipboard_items.snapshot_skipped,
        clipboard_items.custom_title,
        COALESCE(clipboard_items.last_copied_at, clipboard_items.created_at),
        clipboard_items.summary,
        clipboard_items.origin_kind
        """
    }

    func insertRecord(_ record: ClipboardRecorderRecord, compatibilitySearchText: String?) throws {
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_items (
                id,
                created_at,
                updated_at,
                change_count,
                kind,
                format_summary_json,
                source_app_json,
                signature_sha256,
                signature_sha256_12,
                fixture_owned,
                pinned,
                restorable,
                excluded,
                snapshot_skipped,
                custom_title,
                summary,
                search_text,
                last_copied_at,
                content_revision,
                content_updated_at,
                origin_kind
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .string(record.id),
                .double(record.createdAt.timeIntervalSince1970),
                .double(Date().timeIntervalSince1970),
                .int(record.changeCount),
                .string(record.kind.rawValue),
                .string(try encodeJSONString(record.formatSummary)),
                optionalString(try record.sourceApp.map { try encodeJSONString($0) }),
                .string(record.signatureSHA256),
                .string(record.signatureSHA256_12),
                .bool(record.fixtureOwned),
                .bool(record.pinned),
                .bool(record.restorable),
                .bool(record.excluded),
                .bool(record.snapshotSkipped),
                optionalString(record.customTitle),
                .string(record.summary),
                optionalString(compatibilitySearchText?.isEmpty == false ? compatibilitySearchText : nil),
                .double(record.createdAt.timeIntervalSince1970),
                .int64(1),
                .double(Date().timeIntervalSince1970),
                .string(record.origin.rawValue)
            ]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func upgradeSkippedPlaceholder(
        _ placeholder: ClipboardRecorderRecord,
        with record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload,
        searchDocument: ClipboardSearchDocument,
        rollbackTracker: ClipboardSidecarRollbackTracker
    ) throws {
        let now = Date()
        try database.connection.withStatement(
            """
            UPDATE clipboard_items
            SET created_at = ?,
                updated_at = ?,
                change_count = ?,
                kind = ?,
                format_summary_json = ?,
                source_app_json = ?,
                signature_sha256 = ?,
                signature_sha256_12 = ?,
                fixture_owned = ?,
                pinned = ?,
                restorable = ?,
                excluded = ?,
                snapshot_skipped = ?,
                custom_title = ?,
                summary = ?,
                search_text = ?,
                last_copied_at = ?,
                content_revision = ?,
                content_updated_at = ?
            WHERE id = ? AND change_count = ? AND snapshot_skipped = 1
            """,
            bindings: [
                .double(record.createdAt.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
                .int(record.changeCount),
                .string(record.kind.rawValue),
                .string(try encodeJSONString(record.formatSummary)),
                optionalString(try record.sourceApp.map { try encodeJSONString($0) }),
                .string(record.signatureSHA256),
                .string(record.signatureSHA256_12),
                .bool(record.fixtureOwned),
                .bool(record.pinned),
                .bool(record.restorable),
                .bool(record.excluded),
                .bool(record.snapshotSkipped),
                optionalString(record.customTitle),
                .string(record.summary),
                optionalString(searchDocument.ftsProjectionText.isEmpty ? nil : searchDocument.ftsProjectionText),
                .double(record.createdAt.timeIntervalSince1970),
                .int64(1),
                .double(now.timeIntervalSince1970),
                .string(placeholder.id),
                .int(placeholder.changeCount)
            ]
        ) { statement in
            _ = try statement.step()
        }
        try storePayload(
            payload,
            forRecordID: placeholder.id,
            rollbackTracker: rollbackTracker
        )
        try upsertSearchDocument(searchDocument)
        if record.pinned {
            try upsertPinnedMetadata(recordID: placeholder.id, pinboardID: defaultPinboardID, displayName: nil)
        }
    }

    public func updateCustomTitle(recordID: String, title: String?) throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let now = Date()
        try database.connection.transaction {
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET custom_title = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    optionalString(trimmed.isEmpty ? nil : trimmed),
                    .double(now.timeIntervalSince1970),
                    .string(recordID)
                ]
            ) { statement in
                _ = try statement.step()
            }
            guard let record = try loadRecord(recordID: recordID) else {
                throw ClipboardRepositoryError.recordNotFound(recordID)
            }
            let payload = try readPayload(recordID: recordID)
            let existingDocument = try loadSearchDocument(recordID: recordID)
            let tags = try ClipboardTagRepository(repository: self)
                .loadRecordTags(recordIDs: [recordID])[recordID, default: []]
                .flatMap { [$0.displayName, $0.normalizedName] }
            let document = ClipboardSearchDocumentBuilder().build(
                record: record,
                payload: payload,
                tags: tags,
                ocrText: existingDocument?.ocrText,
                ocrState: existingDocument?.ocrState,
                ocrTextSource: existingDocument?.ocrTextSource ?? .none,
                contentRevision: existingDocument?.contentRevision ?? 1,
                updatedAt: now
            )
            try upsertSearchDocument(document)
        }
    }

    func storePayload(
        _ payload: ClipboardRecorderPayload,
        forRecordID recordID: String,
        rollbackTracker: ClipboardSidecarRollbackTracker
    ) throws {
        let rtfData = payload.rtfData
        let pngData = payload.pngData
        let pngSidecarPath: String?
        let pngDataForDatabase: Data?
        let pngPayloadSignature = pngData.map(Self.sha256Hex)
        if let pngData, pngData.count > blobStore.sidecarThresholdBytes {
            // A replacement must never reuse the path still referenced by the
            // committed row.  The database transaction may fail after this
            // function returns, so only an atomic database pointer switch can
            // retire the old sidecar safely.
            let storageKey = "\(recordID)-\(UUID().uuidString.lowercased())"
            let relativePath = try blobStore.write(
                data: pngData,
                recordID: storageKey,
                fileExtension: "png"
            )
            pngSidecarPath = relativePath
            rollbackTracker.record(relativePath)
            pngDataForDatabase = nil
        } else {
            pngSidecarPath = nil
            pngDataForDatabase = pngData
        }

        let payloadByteCount = (payload.text?.utf8.count ?? 0)
            + (payload.urlString?.utf8.count ?? 0)
            + (rtfData?.count ?? 0)
            + (pngData?.count ?? 0)

        do {
            try database.connection.transaction {
                let replacedSidecarPath = try database.connection.firstString(
                    "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
                    bindings: [.string(recordID)]
                )
                if let replacedSidecarPath, replacedSidecarPath != pngSidecarPath {
                    try enqueueSidecarCleanup([replacedSidecarPath])
                }
                try database.connection.withStatement(
                    """
                    INSERT OR REPLACE INTO clipboard_payloads (
                    record_id,
                    kind,
                    text,
                    rtf_data,
                    png_data,
                    png_sidecar_path,
                    png_payload_sha256,
                    url_string,
                    payload_byte_count,
                    created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .string(recordID),
                        .string(payload.kind.rawValue),
                        optionalString(payload.text),
                        optionalData(rtfData),
                        optionalData(pngDataForDatabase),
                        optionalString(pngSidecarPath),
                        optionalString(pngPayloadSignature),
                        optionalString(payload.urlString),
                        .int(payloadByteCount),
                        .double(Date().timeIntervalSince1970)
                    ]
                ) { statement in
                    _ = try statement.step()
                }
                if let pngSidecarPath {
                    try database.connection.withStatement(
                        "DELETE FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
                        bindings: [.string(pngSidecarPath)]
                    ) { statement in _ = try statement.step() }
                }
            }
        } catch {
            if let pngSidecarPath {
                try? blobStore.delete(relativePath: pngSidecarPath)
            }
            throw error
        }
    }

    private func fallbackSearch(
        _ query: String,
        limit: Int,
        filteringBatch: (([ClipboardRecorderRecord]) throws -> [ClipboardRecorderRecord])?
    ) throws -> [ClipboardRecorderRecord] {
        let like = "%\(query.lowercased())%"
        return try querySearchRecords(
            """
            SELECT \(recordColumns)
            FROM clipboard_items
            WHERE lower(coalesce(search_text, '')) LIKE ?
            ORDER BY COALESCE(last_copied_at, created_at) DESC,
                     created_at DESC,
                     change_count DESC,
                     id DESC
            LIMIT ?
            """,
            bindings: [.string(like), .int(filteringBatch == nil ? max(1, limit) : -1)],
            limit: limit,
            filteringBatch: filteringBatch
        )
    }

    private struct ClipboardSearchBatchFilterError: Error {
        let underlying: Error
    }

    /// Apply panel filters before the result limit without retaining the entire
    /// search candidate set. The callback must preserve batch order/subset.
    private func querySearchRecords(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        limit: Int,
        filteringBatch: (([ClipboardRecorderRecord]) throws -> [ClipboardRecorderRecord])?
    ) throws -> [ClipboardRecorderRecord] {
        guard let filteringBatch else {
            return try queryRecords(sql, bindings: bindings)
        }
        let safeLimit = max(1, limit)
        return try database.connection.withStatement(sql, bindings: bindings) { statement in
            var records: [ClipboardRecorderRecord] = []
            while records.count < safeLimit {
                var batch: [ClipboardRecorderRecord] = []
                while batch.count < 256, try statement.step() {
                    batch.append(try decodeRecord(statement))
                }
                guard !batch.isEmpty else { break }
                let matching: [ClipboardRecorderRecord]
                do {
                    matching = try filteringBatch(batch)
                } catch {
                    throw ClipboardSearchBatchFilterError(underlying: error)
                }
                records.append(contentsOf: matching.prefix(safeLimit - records.count))
                if batch.count < 256 { break }
            }
            return records
        }
    }

    func queryRecords(_ sql: String, bindings: [SQLiteBinding] = []) throws -> [ClipboardRecorderRecord] {
        try database.connection.withStatement(sql, bindings: bindings) { statement in
            var records: [ClipboardRecorderRecord] = []
            while try statement.step() {
                records.append(try decodeRecord(statement))
            }
            return records
        }
    }

    private func loadAllRecords() throws -> [ClipboardRecorderRecord] {
        try queryRecords(
            """
            SELECT \(recordColumns)
            FROM clipboard_items
            ORDER BY COALESCE(last_copied_at, created_at) DESC,
                     created_at DESC,
                     change_count DESC,
                     id DESC
            """
        )
    }

    @discardableResult
    private func updateLastCopiedAt(recordID: String, date: Date) throws -> Date {
        try database.connection.transaction {
            let latestTimestamp = try database.connection.firstDouble(
                "SELECT MAX(COALESCE(last_copied_at, created_at)) FROM clipboard_items"
            ) ?? 0
            let requestedTimestamp = date.timeIntervalSince1970
            let resolvedTimestamp = requestedTimestamp > latestTimestamp
                ? requestedTimestamp
                : latestTimestamp + 0.000_001
            let resolvedDate = Date(timeIntervalSince1970: resolvedTimestamp)
            let now = Date()
            try database.connection.withStatement(
                """
                UPDATE clipboard_items
                SET last_copied_at = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .double(resolvedTimestamp),
                    .double(now.timeIntervalSince1970),
                    .string(recordID)
                ]
            ) { statement in
                _ = try statement.step()
            }
            // Recency is stored on clipboard_items and every search query joins
            // that table for ordering. Rebuilding the content search document
            // here used to reread payload sidecars and tags for a timestamp-only
            // mutation, making a successful copy depend on unrelated index I/O.
            return resolvedDate
        }
    }

    private func rebuildSearchDocumentPreservingDerivedState(recordID: String, updatedAt: Date) throws {
        guard let record = try loadRecord(recordID: recordID) else {
            throw ClipboardRepositoryError.recordNotFound(recordID)
        }
        let payload = try readPayload(recordID: recordID)
        let existingDocument = try loadSearchDocument(recordID: recordID)
        let tags = try ClipboardTagRepository(repository: self)
            .loadRecordTags(recordIDs: [recordID])[recordID, default: []]
            .flatMap { [$0.displayName, $0.normalizedName] }
        let document = ClipboardSearchDocumentBuilder().build(
            record: record,
            payload: payload,
            tags: tags,
            ocrText: existingDocument?.ocrText,
            ocrState: existingDocument?.ocrState,
            ocrTextSource: existingDocument?.ocrTextSource ?? .none,
            contentRevision: existingDocument?.contentRevision ?? 1,
            updatedAt: updatedAt
        )
        try upsertSearchDocument(document)
    }

    private func favoriteRecordIDs() throws -> Set<String> {
        let favorite = try ClipboardTagRepository(database: database).ensureFavoriteTag()
        let ids = try database.connection.withStatement(
            """
            SELECT record_id
            FROM clipboard_record_tags
            WHERE tag_id = ?
            """,
            bindings: [.string(favorite.id)]
        ) { statement in
            var ids: [String] = []
            while try statement.step() {
                if let id = statement.columnString(0) {
                    ids.append(id)
                }
            }
            return ids
        }
        return Set(ids)
    }

    public func loadRecord(recordID: String) throws -> ClipboardRecorderRecord? {
        try queryRecords(
            """
            SELECT \(recordColumns)
            FROM clipboard_items
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.string(recordID)]
        ).first
    }

    private func recordID(signature: String) throws -> String? {
        try database.connection.firstString(
            "SELECT id FROM clipboard_items WHERE signature_sha256 = ? LIMIT 1",
            bindings: [.string(signature)]
        )
    }

    private func ensureRecordExists(_ recordID: String) throws {
        let exists = try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_items WHERE id = ?",
            bindings: [.string(recordID)]
        ) ?? 0
        guard exists > 0 else {
            throw ClipboardRepositoryError.recordNotFound(recordID)
        }
    }

    private func ensurePinboardExists(_ pinboardID: String) throws {
        let exists = try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_pinboards WHERE id = ?",
            bindings: [.string(pinboardID)]
        ) ?? 0
        guard exists > 0 else {
            throw ClipboardRepositoryError.pinboardNotFound(pinboardID)
        }
    }

    private func upsertPinnedMetadata(recordID: String, pinboardID: String, displayName: String?) throws {
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_pinned_metadata (record_id, pinboard_id, display_name, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                pinboard_id = excluded.pinboard_id,
                display_name = excluded.display_name,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .string(recordID),
                .string(pinboardID),
                optionalString(displayName),
                .double(Date().timeIntervalSince1970)
            ]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func redactRecordForPolicy(_ record: ClipboardRecorderRecord) throws {
        let reason = ClipboardCaptureSkipReason.excludedSource
        let signature = ClipboardCapturePolicy.sanitizedSkippedSignature(
            recordID: record.id,
            reason: reason
        )
        let signature12 = String(signature.prefix(12))
        let redactedFormatData = try JSONEncoder().encode(
            ClipboardRecorderFormatSummary(itemCount: 1, types: [])
        )
        guard let redactedFormatJSON = String(data: redactedFormatData, encoding: .utf8) else {
            throw ClipboardRepositoryError.invalidPayload(recordID: record.id, field: "formatSummary")
        }
        try enqueueSidecarCleanup(try sidecarPaths(recordIDs: [record.id]))
        try database.connection.withStatement(
            """
            UPDATE clipboard_items
            SET kind = ?,
                format_summary_json = ?,
                signature_sha256 = ?,
                signature_sha256_12 = ?,
                restorable = 0,
                excluded = 1,
                snapshot_skipped = 1,
                summary = ?,
                search_text = NULL,
                updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .string(ClipboardRecorderItemKind.unknown.rawValue),
                .string(redactedFormatJSON),
                .string(signature),
                .string(signature12),
                .string(reason.summaryCode),
                .double(Date().timeIntervalSince1970),
                .string(record.id)
            ]
        ) { statement in
            _ = try statement.step()
        }
        try database.connection.withStatement(
            "DELETE FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ) { statement in
            _ = try statement.step()
        }
        try markSearchDocumentRedacted(
            recordID: record.id,
            revision: "v2:\(record.changeCount):\(signature12)",
            summaryCode: reason.summaryCode
        )
    }

    private func deleteRecords(
        _ recordIDs: [String],
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws {
        guard !recordIDs.isEmpty else {
            return
        }
        let outcome = try database.connection.transaction {
            let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
            let bindings = recordIDs.map(SQLiteBinding.string)
            let existingRecordIDs = try database.connection.withStatement(
                "SELECT id FROM clipboard_items WHERE id IN (\(placeholders))",
                bindings: bindings
            ) { statement in
                var ids: [String] = []
                while try statement.step() {
                    if let id = statement.columnString(0) {
                        ids.append(id)
                    }
                }
                return ids.sorted()
            }
            return (
                recordIDs: existingRecordIDs,
                sidecars: try deleteRecordsFromDatabase(existingRecordIDs)
            )
        }
        if !outcome.recordIDs.isEmpty {
            onCommittedDeletion(outcome.recordIDs)
        }
        deleteSidecars(outcome.sidecars)
    }

    private func deleteRecordsFromDatabase(_ recordIDs: [String]) throws -> [String] {
        guard !recordIDs.isEmpty else { return [] }
        let sidecars = try sidecarPaths(recordIDs: recordIDs)
        try enqueueSidecarCleanup(sidecars)
        let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
        let bindings = recordIDs.map(SQLiteBinding.string)
        try deleteSearchDocuments(recordIDs: recordIDs)
        try database.connection.withStatement(
            "DELETE FROM clipboard_items WHERE id IN (\(placeholders))",
            bindings: bindings
        ) { statement in
            _ = try statement.step()
        }
        return sidecars
    }

    private func deleteSidecars(_ relativePaths: [String]) {
        // Rows were durably enqueued by the deletion transaction. Drain all
        // pending work so a previous failure is retried with later cleanup.
        _ = relativePaths
        _ = try? drainSidecarCleanupOutbox()
    }

    /// Tracks every sidecar created by a database mutation until its outermost
    /// transaction commits. If that transaction rolls back, the exact paths
    /// become durable cleanup work before the original error is returned.
    func withSidecarRollbackTransaction<T>(
        _ body: (ClipboardSidecarRollbackTracker) throws -> T
    ) throws -> T {
        let rollbackTracker = ClipboardSidecarRollbackTracker()
        do {
            return try database.connection.transaction {
                try body(rollbackTracker)
            }
        } catch {
            let operationError = error
            try persistRolledBackSidecarCleanup(rollbackTracker.relativePaths)
            throw operationError
        }
    }

    func persistRolledBackSidecarCleanup(_ relativePaths: Set<String>) throws {
        guard !relativePaths.isEmpty else { return }
        do {
            try database.connection.transaction {
                try enqueueSidecarCleanup(Array(relativePaths))
            }
        } catch {
            // If the cleanup journal itself is unavailable, an immediately
            // durable unlink is the only safe fallback. Never silently lose
            // both the file cleanup and its retry record.
            var deletionFailed = false
            for relativePath in relativePaths {
                do {
                    try blobStore.delete(relativePath: relativePath)
                } catch {
                    deletionFailed = true
                }
            }
            if deletionFailed {
                throw ClipboardRepositoryError.sidecarCleanupPersistenceFailed
            }
            return
        }
        // Deletion remains best-effort, but its retry fact is already durable.
        _ = try? drainSidecarCleanupOutbox()
    }

    /// Returns outstanding low-sensitivity sidecar cleanup work. Database
    /// deletion remains committed truth even when this value is non-zero.
    public func pendingSidecarCleanupCount() throws -> Int {
        try database.connection.firstInt("SELECT COUNT(*) FROM clipboard_sidecar_cleanup") ?? 0
    }

    @discardableResult
    func drainSidecarCleanupOutbox() throws -> Int {
        try withScreenshotHistorySerialization {
            let paths = try database.connection.withStatement(
                "SELECT relative_path FROM clipboard_sidecar_cleanup ORDER BY enqueued_at ASC"
            ) { statement in
                var values: [String] = []
                while try statement.step() {
                    if let value = statement.columnString(0), !value.isEmpty { values.append(value) }
                }
                return values
            }
            for path in paths {
                try database.connection.transaction {
                    let isCurrentPayload = (try database.connection.firstInt(
                        "SELECT COUNT(*) FROM clipboard_payloads WHERE png_sidecar_path = ?",
                        bindings: [.string(path)]
                    ) ?? 0) > 0
                    do {
                        if !isCurrentPayload {
                            try sidecarDeletionFailureInjector?(path)
                            try blobStore.delete(relativePath: path)
                        }
                        try database.connection.withStatement(
                            "DELETE FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
                            bindings: [.string(path)]
                        ) { statement in _ = try statement.step() }
                    } catch {
                        try database.connection.withStatement(
                            """
                            UPDATE clipboard_sidecar_cleanup
                            SET attempt_count = attempt_count + 1,
                                last_attempt_at = ?, last_error_code = 'delete_failed'
                            WHERE relative_path = ?
                            """,
                            bindings: [.double(Date().timeIntervalSince1970), .string(path)]
                        ) { statement in _ = try statement.step() }
                    }
                }
            }
            return try pendingSidecarCleanupCount()
        }
    }

    func enqueueSidecarCleanup(_ relativePaths: [String]) throws {
        let now = Date().timeIntervalSince1970
        for path in Set(relativePaths) where !path.isEmpty {
            try database.connection.withStatement(
                """
                INSERT INTO clipboard_sidecar_cleanup (relative_path, enqueued_at, attempt_count)
                VALUES (?, ?, 0)
                ON CONFLICT(relative_path) DO NOTHING
                """,
                bindings: [.string(path), .double(now)]
            ) { statement in _ = try statement.step() }
        }
    }

    func cleanupUnreferencedSidecars() throws {
        try withScreenshotHistorySerialization {
            guard screenshotHistoryRecoverySucceeded else {
                throw ScreenshotHistoryStartupMaintenanceError.recoveryRequired
            }
            try database.connection.transaction {
                let retainedPaths = try database.connection.withStatement(
                    "SELECT png_sidecar_path FROM clipboard_payloads WHERE png_sidecar_path IS NOT NULL"
                ) { statement in
                    var paths = Set<String>()
                    while try statement.step() {
                        if let path = statement.columnString(0), !path.isEmpty {
                            paths.insert(path)
                        }
                    }
                    return paths
                }
                let pendingPaths = try database.connection.withStatement(
                    "SELECT relative_path FROM clipboard_sidecar_cleanup"
                ) { statement in
                    var paths = Set<String>()
                    while try statement.step() {
                        if let path = statement.columnString(0), !path.isEmpty { paths.insert(path) }
                    }
                    return paths
                }
                try blobStore.cleanupOrphans(retaining: retainedPaths.union(pendingPaths))
            }
        }
    }

    func withScreenshotHistorySerialization<T>(_ body: () throws -> T) rethrows -> T {
        screenshotHistoryLock.lock()
        defer { screenshotHistoryLock.unlock() }
        return try body()
    }

    func sidecarPaths(recordIDs: [String]) throws -> [String] {
        guard !recordIDs.isEmpty else {
            return []
        }
        let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
        return try database.connection.withStatement(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id IN (\(placeholders)) AND png_sidecar_path IS NOT NULL",
            bindings: recordIDs.map(SQLiteBinding.string)
        ) { statement in
            var paths: [String] = []
            while try statement.step() {
                if let value = statement.columnString(0), !value.isEmpty {
                    paths.append(value)
                }
            }
            return paths
        }
    }

    func replaceFTS(recordID: String, searchText: String?) throws {
        guard database.ftsEnabled else {
            return
        }
        try database.connection.withStatement(
            "DELETE FROM clipboard_fts WHERE record_id = ?",
            bindings: [.string(recordID)]
        ) { statement in
            _ = try statement.step()
        }
        guard let searchText, !searchText.isEmpty else {
            return
        }
        try database.connection.withStatement(
            "INSERT INTO clipboard_fts (record_id, search_text) VALUES (?, ?)",
            bindings: [.string(recordID), .string(searchText)]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func decodeRecord(_ statement: SQLiteStatement) throws -> ClipboardRecorderRecord {
        let kind = ClipboardRecorderItemKind(rawValue: statement.columnString(3) ?? "") ?? .unknown
        let formatSummary: ClipboardRecorderFormatSummary = try decodeJSONString(statement.columnString(4) ?? "{}")
        let sourceApp: ClipboardRecorderSourceApp?
        if let sourceJSON = statement.columnString(5), !sourceJSON.isEmpty {
            sourceApp = try decodeJSONString(sourceJSON)
        } else {
            sourceApp = nil
        }
        return ClipboardRecorderRecord(
            id: statement.columnString(0) ?? "",
            createdAt: Date(timeIntervalSince1970: statement.columnDouble(1)),
            changeCount: statement.columnInt(2),
            kind: kind,
            formatSummary: formatSummary,
            sourceApp: sourceApp,
            signatureSHA256: statement.columnString(6),
            signatureSHA256_12: statement.columnString(7) ?? "",
            fixtureOwned: statement.columnBool(8),
            pinned: statement.columnBool(9),
            restorable: statement.columnBool(10),
            excluded: statement.columnBool(11),
            snapshotSkipped: statement.columnBool(12),
            customTitle: statement.columnString(13),
            lastCopiedAt: Date(timeIntervalSince1970: statement.columnDouble(14)),
            summary: statement.columnString(15) ?? "",
            origin: ClipboardRecordOrigin(rawValue: statement.columnString(16) ?? "") ?? .clipboard
        )
    }

    func makeFTSQuery(_ query: String) -> String? {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                token.replacingOccurrences(of: "\"", with: "\"\"")
            }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return nil
        }
        return tokens.map { "\"\($0)\"" }.joined(separator: " ")
    }

    private func expandedRelativeDateQuery(_ query: String, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let today = stableDateToken(now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
            .map { stableDateToken($0, calendar: calendar) } ?? today
        return query
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                switch token.lowercased() {
                case "today", "今天", "今日":
                    return today
                case "yesterday", "昨天", "昨日":
                    return yesterday
                default:
                    return String(token)
                }
            }
            .joined(separator: " ")
    }

    private func stableDateToken(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func decodeJSONString<T: Decodable>(_ value: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(value.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func optionalString(_ value: String?) -> SQLiteBinding {
        guard let value else {
            return .null
        }
        return .string(value)
    }

    private func optionalData(_ value: Data?) -> SQLiteBinding {
        guard let value else {
            return .null
        }
        return .data(value)
    }
}

private final class ScreenshotHistorySerializationRegistry: @unchecked Sendable {
    static let shared = ScreenshotHistorySerializationRegistry()

    private let registryLock = NSLock()
    private var locksByDirectory: [String: NSRecursiveLock] = [:]

    func lock(for directory: URL) -> NSRecursiveLock {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locksByDirectory[key] {
            return existing
        }
        let created = NSRecursiveLock()
        locksByDirectory[key] = created
        return created
    }
}

private enum ScreenshotHistoryStartupMaintenanceError: Error {
    case recoveryFailed
    case cleanupFailed
    case recoveryRequired
}
