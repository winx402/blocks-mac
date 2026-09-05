import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

public struct ScreenshotHistoryCommitRequest {
    public let record: ClipboardRecorderRecord
    public let pngData: Data
    public let ocrState: ClipboardOCRState

    public init(
        record: ClipboardRecorderRecord,
        pngData: Data,
        ocrState: ClipboardOCRState
    ) {
        self.record = record
        self.pngData = pngData
        self.ocrState = ocrState
    }
}

public struct ScreenshotHistoryCommitResult {
    public let record: ClipboardRecorderRecord
    public let replacedRecordID: String?

    public init(record: ClipboardRecorderRecord, replacedRecordID: String?) {
        self.record = record
        self.replacedRecordID = replacedRecordID
    }
}

/// Linearizes runtime revocation with the first physical screenshot-history
/// mutation. Its lock protects only this state transition; callers never hold
/// it while staging sidecars or mutating SQLite.
public final class ScreenshotHistoryCommitAdmission: @unchecked Sendable {
    private enum State {
        case pending
        case admitted
        case revoked
    }

    private let lock = NSLock()
    private var state: State = .pending

#if DEBUG
    private let beforeAdmitForTesting: (@Sendable () -> Void)?
    private let afterAdmitForTesting: (@Sendable () -> Void)?

    /// Test-only synchronous hooks run outside `lock`; callers must keep them
    /// bounded and must not perform repository I/O from either hook.
    public init(
        beforeAdmitForTesting: (@Sendable () -> Void)? = nil,
        afterAdmitForTesting: (@Sendable () -> Void)? = nil
    ) {
        self.beforeAdmitForTesting = beforeAdmitForTesting
        self.afterAdmitForTesting = afterAdmitForTesting
    }
#else
    public init() {}
#endif

    /// Revocation can win only before physical history admission.
    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return }
        state = .revoked
    }

    /// The successful transition is the history sink's irreversible boundary.
    /// A revoked admission cannot stage a sidecar or mutate SQLite.
    public func admit() throws {
#if DEBUG
        beforeAdmitForTesting?()
#endif
        lock.lock()
        switch state {
        case .pending:
            state = .admitted
            lock.unlock()
#if DEBUG
            afterAdmitForTesting?()
#endif
        case .revoked:
            lock.unlock()
            throw CancellationError()
        case .admitted:
            lock.unlock()
            preconditionFailure("Screenshot history admission was reused.")
        }
    }
}

enum ScreenshotHistoryCommitFailurePoint: CaseIterable, Sendable {
    case afterPayloadStaged
    case beforeDuplicateDelete
    case beforeFTSUpdate
    case beforeSQLiteCommit
    case afterSQLiteCommit
    case beforeSidecarPromote
    case beforeOldSidecarDelete
}

extension ClipboardRepository {
    public func commitScreenshotHistory(
        request: ScreenshotHistoryCommitRequest,
        admission: ScreenshotHistoryCommitAdmission = ScreenshotHistoryCommitAdmission(),
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws -> ScreenshotHistoryCommitResult {
        try withScreenshotHistorySerialization {
            guard request.record.kind == .image,
                  request.ocrState == .pending || request.ocrState == .notRequired,
                  let validatedPNG = validatedScreenshotPNG(request.pngData) else {
                throw ClipboardRepositoryError.invalidPayload(
                    recordID: request.record.id,
                    field: "screenshotHistory"
                )
            }
            try admission.admit()

            let pngData = request.pngData
            let signature = validatedPNG.visualSignature
            let signature12 = String(signature.prefix(12))
            var replacedRecordID: String?
            var oldSidecarPath: String?
            var staged: BlobStoreStagedFile?
            var sqliteCommitted = false

            if pngData.count > blobStore.sidecarThresholdBytes {
                staged = try blobStore.stage(data: pngData, recordID: request.record.id, fileExtension: "png")
            }

            do {
            try injectScreenshotHistoryFailure(.afterPayloadStaged)
            let resolved = try database.connection.transaction { () -> ClipboardRecorderRecord in
                let duplicateID = try database.connection.firstString(
                    """
                    SELECT clipboard_items.id
                    FROM clipboard_items
                    JOIN clipboard_payloads
                      ON clipboard_payloads.record_id = clipboard_items.id
                    WHERE clipboard_payloads.visual_signature_sha256 = ?
                      AND clipboard_items.kind = 'image'
                    LIMIT 1
                    """,
                    bindings: [.string(signature)]
                )
                if let duplicateID {
                    replacedRecordID = duplicateID == request.record.id ? nil : duplicateID
                    oldSidecarPath = try screenshotSidecarPath(recordID: duplicateID)
                }
                if let existingWithCurrentID = try loadRecord(recordID: request.record.id) {
                    guard existingWithCurrentID.kind == .image,
                          existingWithCurrentID.signatureSHA256 == signature,
                          duplicateID == request.record.id else {
                        throw ClipboardRepositoryError.invalidPayload(
                            recordID: request.record.id,
                            field: "recordIDCollision"
                        )
                    }
                }

                let duplicateSnapshot = try duplicateID.map { try screenshotDuplicateSnapshot(recordID: $0) }
                try injectScreenshotHistoryFailure(.beforeDuplicateDelete)
                if let duplicateID {
                    if let oldSidecarPath { try enqueueSidecarCleanup([oldSidecarPath]) }
                    try deleteSearchDocuments(recordIDs: [duplicateID])
                    try database.connection.withStatement(
                        "DELETE FROM clipboard_items WHERE id = ?",
                        bindings: [.string(duplicateID)]
                    ) { statement in _ = try statement.step() }
                }

                let title = nonEmpty(request.record.customTitle) ?? duplicateSnapshot?.customTitle
                let resolvedRecord = ClipboardRecorderRecord(
                    id: request.record.id,
                    createdAt: request.record.createdAt,
                    changeCount: request.record.changeCount,
                    kind: .image,
                    formatSummary: request.record.formatSummary,
                    sourceApp: request.record.sourceApp,
                    signatureSHA256: signature,
                    signatureSHA256_12: signature12,
                    fixtureOwned: request.record.fixtureOwned,
                    pinned: request.record.pinned,
                    restorable: true,
                    excluded: false,
                    snapshotSkipped: false,
                    customTitle: title,
                    lastCopiedAt: request.record.lastCopiedAt,
                    summary: request.record.summary,
                    origin: .screenshot
                )
                try insertRecord(resolvedRecord, compatibilitySearchText: nil)
                try storeScreenshotPayload(
                    pngData: pngData,
                    visualSignature: signature,
                    payloadSignature: validatedPNG.payloadSignature,
                    sidecarRelativePath: staged?.relativePath,
                    recordID: resolvedRecord.id
                )
                if let currentPath = staged?.relativePath {
                    // A same-ID replay stages to the deterministic current
                    // path. It may have been enqueued while replacing the old
                    // row; the new payload owns it now.
                    try database.connection.withStatement(
                        "DELETE FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
                        bindings: [.string(currentPath)]
                    ) { statement in _ = try statement.step() }
                }

                let tagRepository = ClipboardTagRepository(repository: self)
                for tagID in Set(duplicateSnapshot?.tagIDs ?? []) {
                    try attachTagForScreenshotHistory(recordID: resolvedRecord.id, tagID: tagID)
                }

                let tags = try tagRepository
                    .loadRecordTags(recordIDs: [resolvedRecord.id])[resolvedRecord.id, default: []]
                    .flatMap { [$0.displayName, $0.normalizedName] }
                var document = ClipboardSearchDocumentBuilder().build(
                    record: resolvedRecord,
                    payload: nil,
                    tags: tags,
                    ocrState: request.ocrState,
                    imagePayloadAvailable: true,
                    contentRevision: 1,
                    updatedAt: Date()
                )
                if let userOCR = duplicateSnapshot?.userOCR {
                    document = document.replacingOCR(
                        text: userOCR.text,
                        state: .succeeded,
                        source: .userEdited,
                        userEditedAt: userOCR.editedAt,
                        lockedContentRevision: document.contentRevision,
                        contentRevision: document.contentRevision,
                        updatedAt: Date()
                    )
                }
                try injectScreenshotHistoryFailure(.beforeFTSUpdate)
                try upsertSearchDocument(document)
                try injectScreenshotHistoryFailure(.beforeSQLiteCommit)
                return resolvedRecord
            }
            sqliteCommitted = true
            if let replacedRecordID {
                onCommittedDeletion([replacedRecordID])
            }
            try injectScreenshotHistoryFailure(.afterSQLiteCommit)

            if let staged {
                try injectScreenshotHistoryFailure(.beforeSidecarPromote)
                try blobStore.promote(staged)
            }

            if let oldSidecarPath, oldSidecarPath != staged?.relativePath {
                // Preserve the existing test failure point while durable work
                // is drained after SQLite commit.
                try? injectScreenshotHistoryFailure(.beforeOldSidecarDelete)
                _ = try? drainSidecarCleanupOutbox()
            }
            guard let stored = try loadRecord(recordID: resolved.id) else {
                throw ClipboardRepositoryError.recordNotFound(resolved.id)
            }
                return ScreenshotHistoryCommitResult(record: stored, replacedRecordID: replacedRecordID)
            } catch {
                if !sqliteCommitted, let staged {
                    try? blobStore.abort(staged)
                }
                throw error
            }
        }
    }

    public func loadPendingOCRBatch(limit: Int) throws -> [ClipboardSearchDocument] {
        try loadPendingOCRDocuments(limit: limit)
    }

    func recoverScreenshotHistorySidecars() throws {
        try withScreenshotHistorySerialization {
            let retainedPayloadDigests = try database.connection.withStatement(
                """
                SELECT png_sidecar_path, png_payload_sha256
                FROM clipboard_payloads
                WHERE png_sidecar_path IS NOT NULL
                """
            ) { statement in
                var payloadDigests: [String: String?] = [:]
                while try statement.step() {
                    if let path = statement.columnString(0), !path.isEmpty {
                        let digest = statement.columnString(1)
                        payloadDigests[path] = digest?.isEmpty == false ? digest : nil
                    }
                }
                return payloadDigests
            }
            try blobStore.recover(retainingPayloads: retainedPayloadDigests)
        }
    }
}

private extension ClipboardRepository {
    struct DuplicateSnapshot {
        struct UserOCR {
            let text: String
            let editedAt: Date?
        }

        let customTitle: String?
        let tagIDs: [String]
        let userOCR: UserOCR?
    }

    func screenshotDuplicateSnapshot(recordID: String) throws -> DuplicateSnapshot {
        let record = try loadRecord(recordID: recordID)
        let tags = try ClipboardTagRepository(repository: self)
            .loadRecordTags(recordIDs: [recordID])[recordID, default: []]
        let document = try loadSearchDocument(recordID: recordID)
        let userOCR: DuplicateSnapshot.UserOCR?
        if document?.ocrTextSource == .userEdited {
            userOCR = DuplicateSnapshot.UserOCR(
                text: document?.ocrText ?? "",
                editedAt: document?.ocrUserEditedAt
            )
        } else {
            userOCR = nil
        }
        return DuplicateSnapshot(
            customTitle: record?.customTitle,
            tagIDs: tags.filter { !$0.isScreenshot }.map(\.id),
            userOCR: userOCR
        )
    }

    func storeScreenshotPayload(
        pngData: Data,
        visualSignature: String,
        payloadSignature: String,
        sidecarRelativePath: String?,
        recordID: String
    ) throws {
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_payloads (
                record_id, kind, text, rtf_data, png_data, png_sidecar_path,
                visual_signature_sha256, png_payload_sha256, url_string,
                payload_byte_count, created_at
            ) VALUES (?, ?, NULL, NULL, ?, ?, ?, ?, NULL, ?, ?)
            """,
            bindings: [
                .string(recordID),
                .string(ClipboardRecorderItemKind.image.rawValue),
                sidecarRelativePath == nil ? .data(pngData) : .null,
                sidecarRelativePath.map(SQLiteBinding.string) ?? .null,
                .string(visualSignature),
                .string(payloadSignature),
                .int(pngData.count),
                .double(Date().timeIntervalSince1970),
            ]
        ) { statement in _ = try statement.step() }
    }

    func attachTagForScreenshotHistory(recordID: String, tagID: String) throws {
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_record_tags (record_id, tag_id, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(record_id, tag_id) DO NOTHING
            """,
            bindings: [.string(recordID), .string(tagID), .double(Date().timeIntervalSince1970)]
        ) { statement in _ = try statement.step() }
    }

    func screenshotSidecarPath(recordID: String) throws -> String? {
        try database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(recordID)]
        )
    }

    func injectScreenshotHistoryFailure(_ point: ScreenshotHistoryCommitFailurePoint) throws {
        try screenshotHistoryFailureInjector?(point)
    }

    func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    struct ValidatedScreenshotPNG {
        let visualSignature: String
        let payloadSignature: String
    }

    func validatedScreenshotPNG(_ data: Data) -> ValidatedScreenshotPNG? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == "public.png" as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= 32_768,
              height <= 32_768 else {
            return nil
        }

        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow,
              pixelCount <= 120_000_000,
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              sourceImage.width == width,
              sourceImage.height == height,
              let provider = sourceImage.dataProvider,
              let providerData = provider.data else {
            return nil
        }

        let colorSpace = sourceImage.colorSpace?.name.map { $0 as String } ?? "unnamed"
        let visualHeader = [
            "blocks.screenshot.visual.v1",
            String(width),
            String(height),
            String(sourceImage.bitsPerComponent),
            String(sourceImage.bitsPerPixel),
            String(sourceImage.bytesPerRow),
            String(sourceImage.bitmapInfo.rawValue),
            colorSpace,
        ].joined(separator: ":")
        var visualHasher = SHA256()
        visualHasher.update(data: Data(visualHeader.utf8))
        visualHasher.update(data: providerData as Data)

        return ValidatedScreenshotPNG(
            visualSignature: visualHasher.finalize().hexString,
            payloadSignature: SHA256.hash(data: data).hexString
        )
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
