import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import BlocksCore

final class ClipboardScreenshotHistoryRepositoryTests: XCTestCase {
    func testDeletingMissingClipboardRecordDoesNotReportCommittedDeletion() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let committedDeletionRecorder = ThreadSafeCommittedDeletionRecorder()

        _ = try fixture.repository.delete(
            recordID: "missing-record",
            onCommittedDeletion: { ids in
                committedDeletionRecorder.record(ids)
            }
        )

        let committedDeletionSnapshot = committedDeletionRecorder.snapshot
        XCTAssertEqual(committedDeletionSnapshot.count, 0)
        XCTAssertEqual(committedDeletionSnapshot.ids, [])
    }

    func testClipboardPayloadCodableKeepsLegacyJSONKeysAndBinaryPlistData() throws {
        let rtfData = Data("{\\rtf1\\ansi payload}".utf8)
        let pngData = Data([0, 1, 2, 3, 254, 255])
        let payload = ClipboardRecorderPayload(
            recordID: "wire-compatible",
            kind: .richText,
            text: "payload",
            rtfData: rtfData,
            pngData: pngData
        )

        let jsonData = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )
        XCTAssertEqual(json["rtf_data_base64"] as? String, rtfData.base64EncodedString())
        XCTAssertEqual(json["png_data_base64"] as? String, pngData.base64EncodedString())
        XCTAssertNil(json["rtfData"])
        XCTAssertNil(json["pngData"])

        let decodedJSON = try JSONDecoder().decode(ClipboardRecorderPayload.self, from: jsonData)
        XCTAssertEqual(decodedJSON.rtfData, rtfData)
        XCTAssertEqual(decodedJSON.pngData, pngData)

        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        let plistData = try plistEncoder.encode(payload)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["rtf_data_base64"] as? Data, rtfData)
        XCTAssertEqual(plist["png_data_base64"] as? Data, pngData)
        let decodedPlist = try PropertyListDecoder().decode(
            ClipboardRecorderPayload.self,
            from: plistData
        )
        XCTAssertEqual(decodedPlist.rtfData, rtfData)
        XCTAssertEqual(decodedPlist.pngData, pngData)
    }

    func testClipboardPayloadRepositoryStoresRichTextDataWithoutBase64RoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let rtfData = Data("{\\rtf1\\ansi direct data}".utf8)
        let record = ClipboardRecorderRecord(
            id: "rich-data",
            createdAt: Date(),
            changeCount: 41,
            kind: .richText,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.rtf"],
                textLength: 11,
                byteCount: rtfData.count
            ),
            sourceApp: nil,
            signatureSHA256: String(repeating: "4", count: 64),
            signatureSHA256_12: String(repeating: "4", count: 12),
            fixtureOwned: false,
            restorable: true,
            summary: "Rich text"
        )

        _ = try fixture.repository.insert(
            record: record,
            payload: ClipboardRecorderPayload(
                recordID: record.id,
                kind: .richText,
                text: "direct data",
                rtfData: rtfData
            )
        )

        let stored = try XCTUnwrap(fixture.repository.readPayload(recordID: record.id))
        XCTAssertEqual(stored.rtfData, rtfData)
        XCTAssertNil(stored.pngData)
    }

    func testClipboardDetailPayloadSignaturePreservesCanonicalBytes() throws {
        let rtfData = Data("{\\rtf1\\ansi hash}".utf8)
        let payload = ClipboardRecorderPayload(
            recordID: "rich-hash",
            kind: .richText,
            text: "hash",
            rtfData: rtfData
        )
        var legacyCanonical = Data("\(payload.kind.rawValue):".utf8)
        legacyCanonical.append(rtfData)
        let expected = SHA256.hash(data: legacyCanonical)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            ClipboardDetailPayloadSignature.canonicalSHA256(for: payload),
            expected
        )
    }

    func testDatabaseMigratesToVersionSeventeenAndAddsBuiltInPluginMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }

        XCTAssertEqual(try fixture.database.userVersion(), 17)
        let payloadColumns = try fixture.database.connection.withStatement(
            "PRAGMA table_info(clipboard_payloads)"
        ) { statement in
            var names: Set<String> = []
            while try statement.step() {
                if let name = statement.columnString(1) { names.insert(name) }
            }
            return names
        }
        XCTAssertTrue(payloadColumns.contains("visual_signature_sha256"))
        XCTAssertTrue(payloadColumns.contains("png_payload_sha256"))
        let itemColumns = try columnNames(table: "clipboard_items", database: fixture.database)
        let tagColumns = try columnNames(table: "clipboard_tags", database: fixture.database)
        XCTAssertTrue(itemColumns.contains("origin_kind"))
        XCTAssertTrue(tagColumns.contains("is_enabled"))
        XCTAssertTrue(tagColumns.contains("content_revision"))
        XCTAssertTrue(try fixture.database.tableExists("clipboard_sidecar_cleanup"))
        XCTAssertEqual(
            try fixture.database.connection.firstInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name IN ('clipboard_record_tags_content_revision_insert', 'clipboard_record_tags_content_revision_delete')"
            ),
            2
        )
        XCTAssertTrue(try fixture.database.tableExists("translation_favorites"))
        XCTAssertTrue(try fixture.database.tableExists("translation_favorite_results"))
        XCTAssertTrue(try fixture.database.tableExists("plugin_metadata"))
        XCTAssertTrue(try fixture.database.tableExists("plugin_hook_bindings"))
        XCTAssertTrue(try fixture.database.tableExists("plugin_storage"))
        XCTAssertTrue(try fixture.database.tableExists("plugin_shared_state"))
        XCTAssertTrue(try fixture.database.tableExists("plugin_schedules"))
        XCTAssertTrue(try fixture.database.tableExists("plugin_audit_events"))
        let pluginColumns = try columnNames(
            table: "plugin_metadata",
            database: fixture.database
        )
        XCTAssertTrue(pluginColumns.contains("installation_origin"))
        XCTAssertTrue(pluginColumns.contains("built_in_catalog_version"))
        XCTAssertTrue(
            try fixture.database.tableExists(
                "translation_favorites_fts"
            )
        )
        XCTAssertTrue(
            try fixture.database.tableExists(
                "translation_service_profiles"
            )
        )
        let screenshot = try fixture.database.connection.withStatement(
            """
            SELECT id, normalized_name, color_token, sort_order, built_in_kind, is_enabled
            FROM clipboard_tags
            WHERE built_in_kind = 'screenshot'
            """
        ) { statement -> (String, String, String, Int, String, Bool)? in
            guard try statement.step() else {
                return nil
            }
            return (
                statement.columnString(0) ?? "",
                statement.columnString(1) ?? "",
                statement.columnString(2) ?? "",
                statement.columnInt(3),
                statement.columnString(4) ?? "",
                statement.columnBool(5)
            )
        }

        XCTAssertEqual(screenshot?.0, "tag.screenshot")
        XCTAssertEqual(screenshot?.1, "screenshot")
        XCTAssertEqual(screenshot?.2, "orange")
        XCTAssertEqual(screenshot?.3, 1)
        XCTAssertEqual(screenshot?.4, "screenshot")
        XCTAssertEqual(screenshot?.5, true)
    }

    func testSidecarDeleteFailureCommitsDatabaseAndPersistsOutbox() throws {
        let fixture = try makeFixture(sidecarDeletionFailureInjector: { _ in throw SidecarDeleteFailure() })
        defer { fixture.close() }
        let record = makeImageRecord(id: "outbox-failure", png: pngData(seed: 101))
        _ = try fixture.repository.insert(record: record, payload: makePayload(recordID: record.id, png: pngData(seed: 101)))

        XCTAssertEqual(try fixture.repository.delete(recordID: record.id), .deleted)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
        XCTAssertNil(try fixture.repository.loadSearchDocument(recordID: record.id))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
    }

    func testRestartDrainsPendingSidecarCleanupAndAcknowledgesMissingFile() throws {
        let fixture = try makeFixture(sidecarDeletionFailureInjector: { _ in throw SidecarDeleteFailure() })
        let record = makeImageRecord(id: "outbox-restart", png: pngData(seed: 102))
        _ = try fixture.repository.insert(record: record, payload: makePayload(recordID: record.id, png: pngData(seed: 102)))
        let path = try XCTUnwrap(try fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?", bindings: [.string(record.id)]
        ))
        _ = try fixture.repository.delete(recordID: record.id)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
        try FileManager.default.removeItem(at: fixture.blobStore.directory.appendingPathComponent(path))
        fixture.database.close()
        let reopened = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer { reopened.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let repository = ClipboardRepository(database: reopened, blobStore: BlobStore(directory: reopened.environment.blobDirectory, sidecarThresholdBytes: 32))
        XCTAssertEqual(try repository.pendingSidecarCleanupCount(), 0)
    }

    func testPhysicalSidecarDeletionWithFailedOutboxAcknowledgementRetriesOnRestart() throws {
        let fixture = try makeFixture()
        let record = makeImageRecord(id: "outbox-ack-failure", png: pngData(seed: 112))
        _ = try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: pngData(seed: 112))
        )
        let path = try XCTUnwrap(try fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ))
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER sidecar_cleanup_ack_failure
            BEFORE DELETE ON clipboard_sidecar_cleanup
            BEGIN
                SELECT RAISE(FAIL, 'injected outbox acknowledgement failure');
            END;
            """
        )

        XCTAssertEqual(try fixture.repository.delete(recordID: record.id), .deleted)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.blobStore.directory.appendingPathComponent(path).path
            )
        )
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)

        try fixture.database.connection.execute("DROP TRIGGER sidecar_cleanup_ack_failure")
        fixture.database.close()
        let reopened = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let recovered = ClipboardRepository(database: reopened)
        XCTAssertEqual(try recovered.pendingSidecarCleanupCount(), 0)
    }

    func testDatabaseOnlyRepositoryDoesNotRunStartupSidecarMaintenance() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        _ = try fixture.blobStore.stage(
            data: pngData(seed: 113),
            recordID: "database-only-staged",
            fileExtension: "png"
        )

        let repository = ClipboardRepository(
            database: fixture.database,
            blobStore: fixture.blobStore,
            databaseOnly: ()
        )

        XCTAssertEqual(repository.screenshotHistoryMaintenanceStatus, .notStarted)
        XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 1)
    }

    func testDatabaseOnlyTagFallbackDoesNotWaitForScreenshotSerialization() throws {
        let payloadStaged = expectation(description: "screenshot payload staged")
        let allowScreenshotCommit = DispatchSemaphore(value: 0)
        let fixture = try makeFixture(screenshotHistoryFailureInjector: { point in
            guard point == .afterPayloadStaged else { return }
            payloadStaged.fulfill()
            guard allowScreenshotCommit.wait(timeout: .now() + 5) == .success else {
                throw InjectedFailure(point: point)
            }
        })
        let screenshotFinished = DispatchSemaphore(value: 0)
        var screenshotJoined = false
        defer {
            if !screenshotJoined {
                allowScreenshotCommit.signal()
                _ = screenshotFinished.wait(timeout: .now() + 5)
            }
            fixture.close()
        }

        let taggedRecord = makeTextRecord(id: "database-only-tag-fallback", text: "tag fallback")
        _ = try fixture.repository.insert(
            record: taggedRecord,
            payload: .init(recordID: taggedRecord.id, kind: .text, text: "tag fallback")
        )

        let tagFinished = expectation(description: "database-only tag mutation finished")
        let screenshotError = ThreadSafeErrorBox()
        let tagError = ThreadSafeErrorBox()
        let screenshotPNG = pngData(seed: 115)
        let screenshotRecord = makeImageRecord(id: "database-only-tag-lock-order", png: screenshotPNG)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { screenshotFinished.signal() }
            do {
                _ = try fixture.repository.commitScreenshotHistory(
                    request: ScreenshotHistoryCommitRequest(
                        record: screenshotRecord,
                        pngData: screenshotPNG,
                        ocrState: .notRequired
                    )
                )
            } catch {
                screenshotError.store(error)
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [payloadStaged], timeout: 2), .completed)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { tagFinished.fulfill() }
            do {
                _ = try ClipboardTagRepository(database: fixture.database).createTagAndAttach(
                    displayName: "Lock Order Tag",
                    recordID: taggedRecord.id
                )
            } catch {
                tagError.store(error)
            }
        }

        // The screenshot repository still owns its serialization lock here.
        // A database-only tag fallback must remain SQL-only and finish without
        // trying to acquire that lock from inside its SQLite transaction.
        XCTAssertEqual(XCTWaiter().wait(for: [tagFinished], timeout: 2), .completed)
        XCTAssertNil(tagError.value)
        let document = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: taggedRecord.id))
        XCTAssertTrue(document.tagTokens.contains("Lock Order Tag"))
        XCTAssertTrue(document.tagTokens.contains("lock order tag"))

        allowScreenshotCommit.signal()
        XCTAssertEqual(screenshotFinished.wait(timeout: .now() + 5), .success)
        screenshotJoined = true
        XCTAssertNil(screenshotError.value)
        XCTAssertNotNil(try fixture.repository.loadRecord(recordID: screenshotRecord.id))
    }

    func testSidecarOutboxRetainsOnlyFailuresAndIsIdempotent() throws {
        let failingPaths = ThreadSafeStringArrayBox()
        let fixture = try makeFixture(sidecarDeletionFailureInjector: { path in
            if failingPaths.value.contains(path) { throw SidecarDeleteFailure() }
        })
        defer { fixture.close() }
        for (id, seed) in [("outbox-ok", UInt8(103)), ("outbox-fail", UInt8(104))] {
            let png = pngData(seed: seed)
            let record = makeImageRecord(id: id, png: png)
            _ = try fixture.repository.insert(
                record: record,
                payload: makePayload(recordID: id, png: png)
            )
            if id == "outbox-fail" {
                failingPaths.append(contentsOf: [try XCTUnwrap(
                    fixture.database.connection.firstString(
                        "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
                        bindings: [.string(id)]
                    )
                )])
            }
            _ = try fixture.repository.delete(recordID: id)
        }
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
        _ = try fixture.repository.drainSidecarCleanupOutbox()
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
    }

    func testRestartDrainsExistingPendingSidecarFile() throws {
        let fixture = try makeFixture(sidecarDeletionFailureInjector: { _ in throw SidecarDeleteFailure() })
        let record = makeImageRecord(id: "outbox-restart-existing", png: pngData(seed: 105))
        _ = try fixture.repository.insert(record: record, payload: makePayload(recordID: record.id, png: pngData(seed: 105)))
        let path = try XCTUnwrap(try fixture.database.connection.firstString("SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?", bindings: [.string(record.id)]))
        _ = try fixture.repository.delete(recordID: record.id)
        fixture.database.close()
        let reopened = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer { reopened.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let repository = ClipboardRepository(database: reopened)
        XCTAssertEqual(try repository.pendingSidecarCleanupCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.environment.blobDirectory.appendingPathComponent(path).path))
    }

    func testV17RepairRestoresDroppedSidecarOutboxWithoutRemovingTagRevisionSchema() throws {
        let fixture = try makeFixture()
        fixture.database.close()
        let connection = try SQLiteConnection(url: fixture.database.environment.databaseURL)
        try connection.execute("DROP TABLE clipboard_sidecar_cleanup")
        connection.close()
        let reopened = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer { reopened.close(); try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(try reopened.userVersion(), 17)
        XCTAssertTrue(try reopened.tableExists("clipboard_sidecar_cleanup"))
        XCTAssertTrue(try columnNames(table: "clipboard_tags", database: reopened).contains("content_revision"))
    }

    func testPayloadReplacementAndDetailConflictEnqueueOldSidecarsInTheirTransactions() throws {
        let fixture = try makeFixture(sidecarDeletionFailureInjector: { _ in throw SidecarDeleteFailure() })
        defer { fixture.close() }
        let first = makeImageRecord(id: "replace-sidecar", png: pngData(seed: 106))
        _ = try fixture.repository.insert(record: first, payload: makePayload(recordID: first.id, png: pngData(seed: 106)))
        let oldSidecarPath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(first.id)]
        ))

        // Each replacement receives a distinct path, so the committed old
        // path is durable cleanup work and the current path is never queued.
        try fixture.repository.withSidecarRollbackTransaction { rollbackTracker in
            try fixture.repository.storePayload(
                makePayload(recordID: first.id, png: pngData(seed: 107)),
                forRecordID: first.id,
                rollbackTracker: rollbackTracker
            )
        }
        let currentSidecarPath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(first.id)]
        ))
        XCTAssertNotEqual(currentSidecarPath, oldSidecarPath)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
        XCTAssertEqual(
            try fixture.database.connection.firstInt(
                "SELECT COUNT(*) FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
                bindings: [.string(currentSidecarPath)]
            ),
            0
        )

        // A real large-sidecar -> inline replacement has a distinct retired
        // path and therefore keeps durable cleanup work.
        try fixture.repository.withSidecarRollbackTransaction { rollbackTracker in
            try fixture.repository.storePayload(
                ClipboardRecorderPayload(recordID: first.id, kind: .image, pngData: Data([0x00])),
                forRecordID: first.id,
                rollbackTracker: rollbackTracker
            )
        }
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 2)

        let replacementText = "conflicting text"
        let replacementPayload = ClipboardRecorderPayload(
            recordID: "detail-target", kind: .text, text: replacementText
        )
        let replacementSignature = try XCTUnwrap(
            ClipboardDetailPayloadSignature.canonicalSHA256(for: replacementPayload)
        )
        let target = makeTextRecord(id: "detail-target", text: "before")
        _ = try fixture.repository.insert(
            record: target,
            payload: ClipboardRecorderPayload(recordID: target.id, kind: .text, text: "before")
        )
        let conflict = makeImageRecord(
            id: "detail-conflict",
            png: pngData(seed: 108),
            signatureOverride: replacementSignature
        )
        _ = try fixture.repository.insert(record: conflict, payload: makePayload(recordID: conflict.id, png: pngData(seed: 108)))
        _ = try fixture.repository.saveDetailEdit(
            command: ClipboardDetailEditCommand(
                recordID: target.id,
                expectedContentRevision: 1,
                editableKind: .plainText,
                draft: ClipboardDetailDraft(text: replacementText),
                purpose: "detailEditSave"
            )
        )
        XCTAssertNil(try fixture.repository.loadRecord(recordID: conflict.id))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 3)
    }

    func testPayloadReplacementKeepsOldSidecarWhenOuterTransactionRollsBack() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let oldPNG = pngData(seed: 113)
        let replacementPNG = pngData(seed: 114)
        let record = makeImageRecord(id: "replace-outer-rollback", png: oldPNG)
        _ = try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: oldPNG)
        )
        let oldSidecarPath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ))
        let oldSidecarURL = fixture.blobStore.directory.appendingPathComponent(oldSidecarPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSidecarURL.path))

        XCTAssertThrowsError(try fixture.repository.withSidecarRollbackTransaction { rollbackTracker in
            try fixture.repository.storePayload(
                makePayload(recordID: record.id, png: replacementPNG),
                forRecordID: record.id,
                rollbackTracker: rollbackTracker
            )
            throw SidecarDeleteFailure()
        })

        XCTAssertEqual(try fixture.repository.readPayload(recordID: record.id)?.pngData, oldPNG)
        XCTAssertEqual(
            try fixture.database.connection.firstString(
                "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
                bindings: [.string(record.id)]
            ),
            oldSidecarPath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSidecarURL.path))
        let sidecarPaths = try fixture.database.connection.withStatement(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE png_sidecar_path IS NOT NULL"
        ) { statement in
            var paths: [String] = []
            while try statement.step() {
                if let path = statement.columnString(0) { paths.append(path) }
            }
            return paths
        }
        XCTAssertEqual(sidecarPaths, [oldSidecarPath])

        try fixture.repository.cleanupUnreferencedSidecars()
        XCTAssertEqual(try payloadURLs(in: fixture.blobStore).map(\.lastPathComponent), [oldSidecarPath])
    }

    func testPayloadReplacementSQLFailureRollsBackCleanupAndDeletesNewSidecar() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let oldPNG = pngData(seed: 115)
        let replacementPNG = pngData(seed: 116)
        let record = makeImageRecord(id: "replace-local-sql-failure", png: oldPNG)
        _ = try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: oldPNG)
        )
        let oldSidecarPath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ))
        let oldSidecarURL = fixture.blobStore.directory.appendingPathComponent(oldSidecarPath)
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_payload_replacement
            BEFORE INSERT ON clipboard_payloads
            WHEN NEW.record_id = 'replace-local-sql-failure'
            BEGIN
                SELECT RAISE(ABORT, 'injected payload replacement failure');
            END;
            """
        )

        XCTAssertThrowsError(try fixture.repository.withSidecarRollbackTransaction { rollbackTracker in
            try fixture.repository.storePayload(
                makePayload(recordID: record.id, png: replacementPNG),
                forRecordID: record.id,
                rollbackTracker: rollbackTracker
            )
        })

        XCTAssertEqual(try fixture.repository.readPayload(recordID: record.id)?.pngData, oldPNG)
        XCTAssertEqual(
            try fixture.database.connection.firstString(
                "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
                bindings: [.string(record.id)]
            ),
            oldSidecarPath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSidecarURL.path))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
        XCTAssertEqual(try payloadURLs(in: fixture.blobStore).map(\.lastPathComponent), [oldSidecarPath])
    }

    func testVersionNineSetsUserVersionInsideMigrationTransaction() throws {
        let fixture = try makeFixture()
        try fixture.database.connection.execute("DELETE FROM clipboard_tags WHERE built_in_kind = 'screenshot'")
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER require_v9_before_screenshot_seed
            BEFORE INSERT ON clipboard_tags
            WHEN NEW.id = 'tag.screenshot'
            BEGIN
                SELECT CASE
                    WHEN (SELECT user_version FROM pragma_user_version) < 9
                    THEN RAISE(ABORT, 'user_version must reach v9 inside the screenshot tag transaction')
                END;
            END;
            """
        )
        try fixture.database.connection.execute("PRAGMA user_version = 8")
        fixture.database.close()

        let migrated = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer {
            migrated.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        XCTAssertEqual(try migrated.userVersion(), 17)
        XCTAssertEqual(try ClipboardTagRepository(database: migrated).ensureScreenshotTag().sortOrder, 1)
    }

    func testVersionNineReplayDoesNotChangeTagSortOrder() throws {
        let fixture = try makeFixture()
        let tags = ClipboardTagRepository(database: fixture.database)
        _ = try tags.createTag(displayName: "Work")
        _ = try tags.createTag(displayName: "Reference")
        let beforeReplay = try tagSortOrders(database: fixture.database)
        try fixture.database.connection.execute("PRAGMA user_version = 8")
        fixture.database.close()

        let replayed = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer {
            replayed.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        XCTAssertEqual(try replayed.userVersion(), 17)
        XCTAssertEqual(try tagSortOrders(database: replayed), beforeReplay)
    }

    func testMigrationRenamesReservedAliasesAndPreservesIDsAndRelationships() throws {
        let fixture = try makeFixture()
        let record = makeImageRecord(id: "legacy-record", png: pngData(seed: 1))
        _ = try fixture.repository.insert(record: record, payload: makePayload(recordID: record.id, png: pngData(seed: 1)))
        try fixture.database.connection.withStatement(
            "DELETE FROM clipboard_tags WHERE built_in_kind = 'screenshot'"
        ) { statement in _ = try statement.step() }
        let aliases = [
            ("tag.legacy.en", "screenshot", "screenshot"),
            ("tag.legacy.zh", "截图", "截图"),
            ("tag.legacy.ja", "スクリーンショット", "スクリーンショット"),
        ]
        for (offset, alias) in aliases.enumerated() {
            try insertOrdinaryTag(
                database: fixture.database,
                id: alias.0,
                displayName: alias.1,
                normalizedName: alias.2,
                sortOrder: offset + 1
            )
            try fixture.database.connection.withStatement(
                "INSERT INTO clipboard_record_tags (record_id, tag_id, created_at) VALUES (?, ?, ?)",
                bindings: [.string(record.id), .string(alias.0), .double(Date().timeIntervalSince1970)]
            ) { statement in _ = try statement.step() }
        }
        try fixture.database.connection.execute("PRAGMA user_version = 8")
        fixture.database.close()

        let migrated = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer {
            migrated.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        XCTAssertEqual(try migrated.userVersion(), 17)
        let tags = try ClipboardTagRepository(database: migrated).loadRecordTags(recordIDs: [record.id])[record.id, default: []]
        XCTAssertEqual(Set(tags.map(\.id)), Set(aliases.map(\.0)))
        XCTAssertEqual(Set(tags.map(\.displayName)), ["Screenshot (Custom)", "截图（自定义）", "スクリーンショット（カスタム）"])
        XCTAssertTrue(tags.allSatisfy { $0.builtInKind == .none })
        let screenshot = try ClipboardTagRepository(database: migrated).ensureScreenshotTag()
        XCTAssertEqual(screenshot.id, ClipboardTagRepository.screenshotTagID)
        XCTAssertEqual(screenshot.sortOrder, 1)
    }

    func testScreenshotTagCanReorderButRejectsEditingAndPublicMembership() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let tags = ClipboardTagRepository(database: fixture.database)
        let ordinaryID = try createdTagID(tags.createTag(displayName: "Work"))
        let screenshot = try tags.ensureScreenshotTag()

        _ = try tags.reorderTags(tagIDsInDisplayOrder: [ordinaryID, screenshot.id])
        XCTAssertEqual(try tags.ensureScreenshotTag().sortOrder, 2)
        XCTAssertEqual(try tags.loadTags().first(where: { $0.id == ordinaryID })?.sortOrder, 1)
        XCTAssertThrowsError(try tags.reorderTags(tagIDsInDisplayOrder: [ClipboardTagRepository.favoriteTagID])) {
            XCTAssertEqual($0 as? ClipboardTagMutationError, .favoriteImmutable)
        }
        for mutation in [
            { try tags.renameTag(tagID: screenshot.id, displayName: "Renamed") },
            { try tags.updateTagColor(tagID: screenshot.id, colorToken: "blue") },
            { try tags.deleteTag(tagID: screenshot.id) },
            { try tags.mergeTag(sourceTagID: screenshot.id, targetTagID: ordinaryID) },
            { try tags.mergeTag(sourceTagID: ordinaryID, targetTagID: screenshot.id) },
        ] {
            XCTAssertThrowsError(try mutation()) {
                XCTAssertEqual($0 as? ClipboardTagMutationError, .builtInImmutable)
            }
        }

        let record = makeImageRecord(id: "membership", png: pngData(seed: 2))
        _ = try fixture.repository.insert(record: record, payload: makePayload(recordID: record.id, png: pngData(seed: 2)))
        XCTAssertThrowsError(try tags.addTag(recordID: record.id, tagID: screenshot.id)) {
            XCTAssertEqual($0 as? ClipboardTagMutationError, .systemMembershipImmutable)
        }
        try tags.attachScreenshotTag(recordID: record.id)
        XCTAssertThrowsError(try tags.removeTag(recordID: record.id, tagID: screenshot.id)) {
            XCTAssertEqual($0 as? ClipboardTagMutationError, .systemMembershipImmutable)
        }
    }

    func testVersionSeventeenMigrationAddsTagRevisionAndMembershipTriggers() throws {
        let fixture = try makeFixture()
        let tags = ClipboardTagRepository(database: fixture.database)
        let tagID = try createdTagID(tags.createTag(displayName: "Legacy tag"))
        try fixture.database.connection.execute(
            "DROP TRIGGER IF EXISTS clipboard_record_tags_content_revision_insert"
        )
        try fixture.database.connection.execute(
            "DROP TRIGGER IF EXISTS clipboard_record_tags_content_revision_delete"
        )
        try fixture.database.connection.execute(
            "ALTER TABLE clipboard_tags DROP COLUMN content_revision"
        )
        try fixture.database.connection.execute("PRAGMA user_version = 16")
        fixture.database.close()

        let migrated = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer {
            migrated.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        XCTAssertEqual(try migrated.userVersion(), 17)
        XCTAssertEqual(
            try ClipboardTagRepository(database: migrated).loadTags()
                .first(where: { $0.id == tagID })?.contentRevision,
            1
        )
        for trigger in [
            "clipboard_record_tags_content_revision_insert",
            "clipboard_record_tags_content_revision_delete",
        ] {
            XCTAssertEqual(
                try migrated.connection.firstInt(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?",
                    bindings: [.string(trigger)]
                ),
                1
            )
        }

        let repository = ClipboardRepository(database: migrated)
        let record = makeTextRecord(id: "repaired-trigger-membership", text: "revision")
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "revision")
        )
        let repairedTags = ClipboardTagRepository(database: migrated)
        func revision() throws -> Int64 {
            try XCTUnwrap(
                try repairedTags.loadTags().first(where: { $0.id == tagID })?.contentRevision
            )
        }

        XCTAssertEqual(try revision(), 1)
        _ = try repairedTags.addTag(recordID: record.id, tagID: tagID)
        XCTAssertEqual(try revision(), 2)
        _ = try repairedTags.removeTag(recordID: record.id, tagID: tagID)
        XCTAssertEqual(try revision(), 3)
    }

    func testTagContentRevisionTracksActualMutationsAndDeleteUsesCAS() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let tags = ClipboardTagRepository(database: fixture.database)
        let tagID = try createdTagID(tags.createTag(displayName: "Revision tag"))
        let record = makeTextRecord(id: "revision-membership", text: "revision")
        _ = try fixture.repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "revision")
        )

        func revision() throws -> Int64 {
            try XCTUnwrap(
                try tags.loadTags().first(where: { $0.id == tagID })?.contentRevision
            )
        }

        XCTAssertEqual(try revision(), 1)
        _ = try tags.renameTag(tagID: tagID, displayName: "Renamed tag")
        XCTAssertEqual(try revision(), 2)
        _ = try tags.renameTag(tagID: tagID, displayName: "Renamed tag")
        XCTAssertEqual(try revision(), 2)
        _ = try tags.updateTagColor(tagID: tagID, colorToken: "green")
        XCTAssertEqual(try revision(), 3)
        _ = try tags.updateTagColor(tagID: tagID, colorToken: "green")
        XCTAssertEqual(try revision(), 3)
        _ = try tags.reorderTags(tagIDsInDisplayOrder: [tagID])
        XCTAssertEqual(try revision(), 4)
        _ = try tags.reorderTags(tagIDsInDisplayOrder: [tagID])
        XCTAssertEqual(try revision(), 4)
        _ = try tags.addTag(recordID: record.id, tagID: tagID)
        XCTAssertEqual(try revision(), 5)
        _ = try tags.addTag(recordID: record.id, tagID: tagID)
        XCTAssertEqual(try revision(), 5)
        _ = try tags.removeTag(recordID: record.id, tagID: tagID)
        XCTAssertEqual(try revision(), 6)
        _ = try tags.removeTag(recordID: record.id, tagID: tagID)
        XCTAssertEqual(try revision(), 6)
        _ = try tags.addTag(recordID: record.id, tagID: tagID)
        let currentRevision = try revision()

        let screenshot = try tags.ensureScreenshotTag()
        _ = try tags.setScreenshotTagEnabled(false)
        XCTAssertEqual(
            try tags.ensureScreenshotTag().contentRevision,
            screenshot.contentRevision + 1
        )
        _ = try tags.setScreenshotTagEnabled(false)
        XCTAssertEqual(
            try tags.ensureScreenshotTag().contentRevision,
            screenshot.contentRevision + 1
        )
        _ = try tags.setScreenshotTagEnabled(true)
        XCTAssertEqual(
            try tags.ensureScreenshotTag().contentRevision,
            screenshot.contentRevision + 2
        )

        XCTAssertThrowsError(
            try tags.deleteTag(
                tagID: tagID,
                expectedContentRevision: currentRevision + 1
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardTagMutationError, .revisionConflict)
        }
        XCTAssertTrue(try tags.loadTags().contains(where: { $0.id == tagID }))
        XCTAssertEqual(
            try tags.loadRecordTags(recordIDs: [record.id])[record.id]?.map(\.id),
            [tagID]
        )
        _ = try tags.deleteTag(tagID: tagID, expectedContentRevision: currentRevision)
        XCTAssertFalse(try tags.loadTags().contains(where: { $0.id == tagID }))
        XCTAssertTrue(
            try tags.loadRecordTags(recordIDs: [record.id])[record.id]?.isEmpty ?? true
        )
    }

    func testScreenshotAliasesAreReservedForNewUserTags() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let tags = ClipboardTagRepository(database: fixture.database)

        for alias in ["screenshot", "截图", "スクリーンショット", "ＳＣＲＥＥＮＳＨＯＴ"] {
            XCTAssertThrowsError(try tags.createTag(displayName: alias)) {
                XCTAssertEqual($0 as? ClipboardTagMutationError, .invalidName(.reservedSystemName))
            }
        }
    }

    func testVersionElevenBackfillsScreenshotOriginFromExistingSystemTag() throws {
        let fixture = try makeFixture()
        let tagged = makeImageRecord(id: "legacy-screenshot", png: pngData(seed: 40))
        let ordinary = makeImageRecord(id: "legacy-clipboard", png: pngData(seed: 41))
        _ = try fixture.repository.insert(
            record: tagged,
            payload: makePayload(recordID: tagged.id, png: pngData(seed: 40))
        )
        _ = try fixture.repository.insert(
            record: ordinary,
            payload: makePayload(recordID: ordinary.id, png: pngData(seed: 41))
        )
        try ClipboardTagRepository(database: fixture.database).attachScreenshotTag(recordID: tagged.id)
        try fixture.database.connection.execute(
            "UPDATE clipboard_items SET origin_kind = 'clipboard'"
        )
        try fixture.database.connection.execute("PRAGMA user_version = 10")
        fixture.database.close()

        let migrated = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer {
            migrated.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = ClipboardRepository(database: migrated)
        XCTAssertEqual(try migrated.userVersion(), 17)
        XCTAssertEqual(try repository.loadRecord(recordID: tagged.id)?.origin, .screenshot)
        XCTAssertEqual(try repository.loadRecord(recordID: ordinary.id)?.origin, .clipboard)
    }

    func testLegacyRecordJSONDefaultsOriginToClipboard() throws {
        let record = makeImageRecord(id: "legacy-json", png: pngData(seed: 42))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        object.removeValue(forKey: "origin_kind")

        let decoded = try JSONDecoder().decode(
            ClipboardRecorderRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.origin, .clipboard)
    }

    func testClipboardOrderingUsesLastCopyCreatedChangeCountAndRecordID() {
        let oldCreatedAt = Date(timeIntervalSince1970: 1_000)
        let newCreatedAt = Date(timeIntervalSince1970: 2_000)
        let newestCopyAt = Date(timeIntervalSince1970: 3_000)
        let olderCopyAt = Date(timeIntervalSince1970: 1_500)
        let records = [
            makeImageRecord(id: "z-id", png: pngData(seed: 70), createdAt: oldCreatedAt, changeCount: 3),
            makeImageRecord(id: "a-id", png: pngData(seed: 71), createdAt: oldCreatedAt, changeCount: 3),
            makeImageRecord(id: "change-4", png: pngData(seed: 72), createdAt: oldCreatedAt, changeCount: 4),
            makeImageRecord(id: "new-created", png: pngData(seed: 73), createdAt: newCreatedAt, changeCount: 1),
            makeImageRecord(
                id: "latest-copy",
                png: pngData(seed: 74),
                createdAt: oldCreatedAt,
                changeCount: 1,
                lastCopiedAt: newestCopyAt
            ),
            makeImageRecord(
                id: "older-recopy",
                png: pngData(seed: 78),
                createdAt: oldCreatedAt,
                changeCount: 1,
                lastCopiedAt: olderCopyAt
            ),
        ]

        XCTAssertEqual(
            ClipboardRecordOrdering.sorted(records).map(\.id),
            ["latest-copy", "new-created", "older-recopy", "change-4", "z-id", "a-id"]
        )
    }

    func testRepositoryLoadRecentUsesTheSameStrictClipboardOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let createdAt = Date(timeIntervalSince1970: 4_000)
        let records = [
            makeImageRecord(id: "a", png: pngData(seed: 75), createdAt: createdAt, changeCount: 5),
            makeImageRecord(id: "z", png: pngData(seed: 76), createdAt: createdAt, changeCount: 5),
            makeImageRecord(id: "middle", png: pngData(seed: 77), createdAt: createdAt, changeCount: 6),
        ]
        for (offset, record) in records.enumerated() {
            let png = pngData(seed: UInt8(75 + offset))
            _ = try fixture.repository.insert(
                record: record,
                payload: makePayload(recordID: record.id, png: png)
            )
        }

        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).map(\.id), ["middle", "z", "a"])
    }

    func testRepositoryCopyPromotionIsMonotonicWithoutRebuildingPayloadIndex() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let firstPNG = pngData(seed: 79)
        let secondPNG = pngData(seed: 80)
        let first = makeImageRecord(
            id: "copy-first",
            png: firstPNG,
            createdAt: Date(timeIntervalSince1970: 5_000),
            changeCount: 1
        )
        let second = makeImageRecord(
            id: "copy-second",
            png: secondPNG,
            createdAt: Date(timeIntervalSince1970: 5_001),
            changeCount: 2
        )
        _ = try fixture.repository.insert(
            record: first,
            payload: makePayload(recordID: first.id, png: firstPNG)
        )
        _ = try fixture.repository.insert(
            record: second,
            payload: makePayload(recordID: second.id, png: secondPNG)
        )
        let missingSidecar = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(first.id)]
        ))
        try FileManager.default.removeItem(
            at: fixture.database.environment.blobDirectory.appendingPathComponent(missingSidecar)
        )

        let requested = Date(timeIntervalSince1970: 4_000)
        let firstPromotion = try fixture.repository.markCopied(recordID: first.id, at: requested)
        let secondPromotion = try fixture.repository.markCopied(recordID: second.id, at: requested)

        XCTAssertGreaterThan(firstPromotion, second.createdAt)
        XCTAssertGreaterThan(secondPromotion, firstPromotion)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 2).map(\.id), [second.id, first.id])
    }

    func testRepeatedExternalCopyReusesExistingRecordAndPromotesItsTimestamp() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 81)
        let original = makeImageRecord(
            id: "external-original",
            png: png,
            createdAt: Date(timeIntervalSince1970: 6_000),
            changeCount: 1
        )
        let repeated = makeImageRecord(
            id: "external-repeat",
            png: png,
            createdAt: Date(timeIntervalSince1970: 7_000),
            changeCount: 2
        )
        _ = try fixture.repository.insert(
            record: original,
            payload: makePayload(recordID: original.id, png: png)
        )

        let result = try fixture.repository.insert(
            record: repeated,
            payload: makePayload(recordID: repeated.id, png: png)
        )

        XCTAssertTrue(result.duplicate)
        XCTAssertEqual(result.record.id, original.id)
        XCTAssertEqual(result.record.lastCopiedAt, repeated.createdAt)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).map(\.id), [original.id])
    }

    func testCommitStoresCurrentRecordWithScreenshotTagAndExplicitNotRequiredOCR() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 3)
        let record = makeImageRecord(id: "current", png: png, signatureOverride: "caller-supplied-signature")

        let result = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: png,
                ocrState: .notRequired
            )
        )

        XCTAssertEqual(result.record.id, record.id)
        XCTAssertEqual(result.record.origin, .screenshot)
        XCTAssertNil(result.replacedRecordID)
        let storedPNG = try XCTUnwrap(
            fixture.repository.readPayload(recordID: record.id)?.pngData
        )
        XCTAssertEqual(storedPNG, png)
        let signatures = try payloadSignatures(database: fixture.database, recordID: record.id)
        XCTAssertEqual(signatures.visual, result.record.signatureSHA256)
        XCTAssertEqual(signatures.payload, sha256(png))
        let document = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: record.id))
        XCTAssertEqual(document.ocrState, .notRequired)
        XCTAssertEqual(document.ocrTextSource, .none)
        XCTAssertTrue(document.tagTokens.contains("screenshot"))
        XCTAssertEqual(try fixture.repository.loadPendingOCRBatch(limit: 20).map(\.recordID), [])
        XCTAssertEqual(try fixture.repository.search("screenshot", limit: 10).map(\.id), [record.id])
    }

    func testRevokedScreenshotHistoryAdmissionDoesNotWriteRecordPayloadOrSidecar() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 93)
        let record = makeImageRecord(id: "revoked-before-admission", png: png)
        let admission = ScreenshotHistoryCommitAdmission()
        admission.revoke()

        XCTAssertThrowsError(try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: png,
                ocrState: .notRequired
            ),
            admission: admission
        )) {
            XCTAssertTrue($0 is CancellationError)
        }

        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
        XCTAssertNil(try fixture.repository.readPayload(recordID: record.id))
        XCTAssertTrue(try stagedURLs(in: fixture.blobStore).isEmpty)
        XCTAssertTrue(try payloadURLs(in: fixture.blobStore).isEmpty)
    }

    func testScreenshotTagCanBeHiddenWithoutDeletingOriginsAndReenableDerivesAllHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let tags = ClipboardTagRepository(repository: fixture.repository)
        let firstPNG = pngData(seed: 43)
        let first = makeImageRecord(id: "tagged-before-disable", png: firstPNG)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: first,
                pngData: firstPNG,
                ocrState: .notRequired
            )
        )
        let ordinaryTagID = try createdTagID(tags.createTag(displayName: "Reference"))
        _ = try tags.addTag(recordID: first.id, tagID: ordinaryTagID)

        let disabled = try tags.setScreenshotTagEnabled(
            false,
            selectedTagID: ClipboardTagRepository.screenshotTagID
        )
        XCTAssertEqual(disabled.affectedRecordIDs, [first.id])
        XCTAssertEqual(disabled.selectedTagTransition, .clear)
        XCTAssertFalse(try tags.ensureScreenshotTag().isEnabled)
        XCTAssertFalse(try tags.loadTags().contains(where: \.isScreenshot))
        XCTAssertEqual(
            try tags.loadRecordTags(recordIDs: [first.id])[first.id, default: []].map(\.id),
            [ordinaryTagID]
        )
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: first.id)?.origin, .screenshot)
        XCTAssertEqual(try fixture.repository.loadScreenshotHistory(after: nil, limit: 10).map(\.id), [first.id])

        let secondPNG = pngData(seed: 44)
        let second = makeImageRecord(id: "while-disabled", png: secondPNG)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: second,
                pngData: secondPNG,
                ocrState: .notRequired
            )
        )
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: second.id)?.origin, .screenshot)
        XCTAssertTrue(try tags.loadRecordTags(recordIDs: [second.id])[second.id, default: []].isEmpty)

        _ = try tags.setScreenshotTagEnabled(true)
        XCTAssertTrue(try tags.ensureScreenshotTag().isEnabled)
        XCTAssertTrue(try tags.loadTags().contains(where: \.isScreenshot))
        let tagsAfterReenable = try tags.loadRecordTags(recordIDs: [first.id, second.id])
        XCTAssertEqual(
            tagsAfterReenable[first.id, default: []].map(\.id),
            [ordinaryTagID, ClipboardTagRepository.screenshotTagID]
        )
        XCTAssertEqual(
            tagsAfterReenable[second.id, default: []].map(\.id),
            [ClipboardTagRepository.screenshotTagID]
        )

        let optOutPNG = pngData(seed: 47)
        let optOut = makeImageRecord(id: "request-without-tag", png: optOutPNG)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: optOut,
                pngData: optOutPNG,
                ocrState: .notRequired
            )
        )
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: optOut.id)?.origin, .screenshot)
        XCTAssertEqual(
            try tags.loadRecordTags(recordIDs: [optOut.id])[optOut.id, default: []].map(\.id),
            [ClipboardTagRepository.screenshotTagID]
        )

        let thirdPNG = pngData(seed: 45)
        let third = makeImageRecord(id: "tagged-after-enable", png: thirdPNG)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: third,
                pngData: thirdPNG,
                ocrState: .notRequired
            )
        )
        XCTAssertEqual(
            try tags.loadRecordTags(recordIDs: [third.id])[third.id, default: []].map(\.id),
            [ClipboardTagRepository.screenshotTagID]
        )
    }

    func testDisablingScreenshotTagDoesNotDeleteMaterializedAssociations() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let tags = ClipboardTagRepository(database: fixture.database)
        let png = pngData(seed: 46)
        let record = makeImageRecord(id: "disable-rollback", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: record, pngData: png, ocrState: .notRequired)
        )
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_screenshot_tag_removal
            BEFORE DELETE ON clipboard_record_tags
            WHEN OLD.tag_id = 'tag.screenshot'
            BEGIN
                SELECT RAISE(ABORT, 'injected screenshot tag removal failure');
            END;
            """
        )

        _ = try tags.setScreenshotTagEnabled(false)
        XCTAssertFalse(try tags.ensureScreenshotTag().isEnabled)
        XCTAssertTrue(try tags.loadRecordTags(recordIDs: [record.id])[record.id, default: []].isEmpty)
    }

    func testScreenshotQueriesAndEligibilityUseOriginInsteadOfTagMembership() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let tags = ClipboardTagRepository(database: fixture.database)
        let ordinaryPNG = pngData(seed: 48)
        let ordinary = makeImageRecord(id: "ordinary-with-system-tag", png: ordinaryPNG)
        _ = try fixture.repository.insert(
            record: ordinary,
            payload: makePayload(recordID: ordinary.id, png: ordinaryPNG)
        )
        try tags.attachScreenshotTag(recordID: ordinary.id)

        let screenshotPNG = pngData(seed: 49)
        let screenshot = makeImageRecord(id: "screenshot-without-tag", png: screenshotPNG)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: screenshot,
                pngData: screenshotPNG,
                ocrState: .notRequired
            )
        )

        XCTAssertThrowsError(try fixture.repository.requireScreenshotRecord(recordID: ordinary.id)) {
            XCTAssertEqual($0 as? ScreenshotHistoryRepositoryActionError, .recordNotFound)
        }
        XCTAssertEqual(try fixture.repository.requireScreenshotRecord(recordID: screenshot.id).id, screenshot.id)
        XCTAssertEqual(
            try fixture.repository.loadScreenshotHistory(after: nil, limit: 10).map(\.id),
            [screenshot.id]
        )
    }

    func testDuplicateCommitKeepsCurrentIDAndMergesFavoriteOrdinaryTagsTitleAndUserOCR() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 4)
        let old = makeImageRecord(id: "old", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: old,
                pngData: png,
                ocrState: .pending
            )
        )
        let tags = ClipboardTagRepository(database: fixture.database)
        let ordinaryID = try createdTagID(tags.createTag(displayName: "Research"))
        _ = try tags.addTag(recordID: old.id, tagID: ordinaryID)
        _ = try tags.toggleFavorite(recordID: old.id)
        try fixture.repository.updateCustomTitle(recordID: old.id, title: "Pinned capture")
        _ = try fixture.repository.saveDetailEdit(
            command: ClipboardDetailEditCommand(
                recordID: old.id,
                expectedContentRevision: 1,
                editableKind: .imageOCRText,
                draft: ClipboardDetailDraft(text: "human corrected words"),
                purpose: "detailEditSave"
            )
        )

        let current = makeImageRecord(id: "current", png: png)
        let result = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: current,
                pngData: png,
                ocrState: .pending
            )
        )

        XCTAssertEqual(result.record.id, current.id)
        XCTAssertEqual(result.replacedRecordID, old.id)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: old.id))
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: current.id)?.customTitle, "Pinned capture")
        let mergedTags = try tags.loadRecordTags(recordIDs: [current.id])[current.id, default: []]
        XCTAssertEqual(Set(mergedTags.map(\.builtInKind)), [.favorite, .screenshot, .none])
        XCTAssertTrue(mergedTags.contains(where: { $0.id == ordinaryID }))
        let document = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: current.id))
        XCTAssertEqual(document.ocrText, "human corrected words")
        XCTAssertEqual(document.ocrState, .succeeded)
        XCTAssertEqual(document.ocrTextSource, .userEdited)
        XCTAssertEqual(document.ocrLockedContentRevision, document.contentRevision)
        XCTAssertFalse(try fixture.repository.loadPendingOCRBatch(limit: 20).contains(where: { $0.recordID == current.id }))
        XCTAssertEqual(try fixture.repository.search("corrected", limit: 10).map(\.id), [current.id])
        XCTAssertEqual(try fixture.repository.search("Research", limit: 10).map(\.id), [current.id])
    }

    func testSameIDScreenshotReplayDoesNotDeleteItsCurrentSidecarDuringLaterDrain() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 110)
        let record = makeImageRecord(id: "same-id-replay", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: record, pngData: png, ocrState: .notRequired)
        )
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: record, pngData: png, ocrState: .notRequired)
        )
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)

        let other = makeImageRecord(id: "drain-trigger", png: pngData(seed: 111))
        _ = try fixture.repository.insert(record: other, payload: makePayload(recordID: other.id, png: pngData(seed: 111)))
        _ = try fixture.repository.delete(recordID: other.id)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
        XCTAssertEqual(try fixture.repository.readPayload(recordID: record.id)?.pngData, png)
    }

    func testDrainAndSameIDReplaySerializeWithoutDeletingReReferencedSidecar() throws {
        let payloadStaged = expectation(description: "replay payload staged")
        let allowCommit = DispatchSemaphore(value: 0)
        let fixture = try makeFixture(screenshotHistoryFailureInjector: { point in
            guard point == .afterPayloadStaged else { return }
            payloadStaged.fulfill()
            guard allowCommit.wait(timeout: .now() + 5) == .success else {
                throw InjectedFailure(point: point)
            }
        })
        defer { fixture.close() }
        let png = pngData(seed: 114)
        let record = makeImageRecord(id: "serialized-same-id-replay", png: png)
        // Seed through the production screenshot-history path so the stored
        // record carries the validated visual signature required by a
        // legitimate same-ID replay. A plain repository insert would retain
        // the raw PNG digest from makeImageRecord and exercise the collision
        // rejection path instead of serialization.
        let seedRepository = ClipboardRepository(
            database: fixture.database,
            blobStore: fixture.blobStore
        )
        _ = try seedRepository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: png,
                ocrState: .notRequired
            )
        )
        let path = try XCTUnwrap(try fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ))
        try fixture.repository.enqueueSidecarCleanup([path])

        let commitFinished = expectation(description: "replay commit finished")
        let drainStarted = expectation(description: "drain started")
        let drainFinished = DispatchSemaphore(value: 0)
        let commitError = ThreadSafeErrorBox()
        let drainError = ThreadSafeErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { commitFinished.fulfill() }
            do {
                _ = try fixture.repository.commitScreenshotHistory(
                    request: ScreenshotHistoryCommitRequest(
                        record: record,
                        pngData: png,
                        ocrState: .notRequired
                    )
                )
            } catch {
                commitError.store(error)
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [payloadStaged], timeout: 2), .completed)

        DispatchQueue.global(qos: .userInitiated).async {
            drainStarted.fulfill()
            defer { drainFinished.signal() }
            do {
                _ = try fixture.repository.drainSidecarCleanupOutbox()
            } catch {
                drainError.store(error)
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [drainStarted], timeout: 2), .completed)
        XCTAssertEqual(drainFinished.wait(timeout: .now() + 0.2), .timedOut)
        allowCommit.signal()
        XCTAssertEqual(XCTWaiter().wait(for: [commitFinished], timeout: 5), .completed)
        XCTAssertEqual(drainFinished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(commitError.value)
        XCTAssertNil(drainError.value)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
        XCTAssertEqual(try fixture.repository.readPayload(recordID: record.id)?.pngData, png)
        XCTAssertEqual(
            try fixture.database.connection.firstString(
                "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
                bindings: [.string(record.id)]
            ),
            path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.blobStore.directory.appendingPathComponent(path).path
            )
        )
    }

    func testDetailEditConflictReportsCommittedDeletionExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let target = makeTextRecord(id: "detail-target", text: "before")
        let replacementText = "after"
        let conflictPayload = ClipboardRecorderPayload(
            recordID: "detail-conflict",
            kind: .text,
            text: replacementText
        )
        let conflictSignature = try XCTUnwrap(
            ClipboardDetailPayloadSignature.canonicalSHA256(for: conflictPayload)
        )
        let conflict = makeTextRecord(
            id: "detail-conflict",
            text: replacementText,
            signature: conflictSignature
        )
        _ = try fixture.repository.insert(
            record: target,
            payload: ClipboardRecorderPayload(recordID: target.id, kind: .text, text: "before")
        )
        _ = try fixture.repository.insert(record: conflict, payload: conflictPayload)
        let deletions = ThreadSafeStringArrayBox()

        let result = try fixture.repository.saveDetailEdit(
            command: ClipboardDetailEditCommand(
                recordID: target.id,
                expectedContentRevision: 1,
                editableKind: .plainText,
                draft: ClipboardDetailDraft(text: replacementText),
                purpose: "detailEditSave"
            ),
            onCommittedDeletion: { deletions.append(contentsOf: $0) }
        )

        XCTAssertTrue(result.changedFields.contains(.conflictMerged))
        XCTAssertEqual(deletions.value, [conflict.id])
        XCTAssertNil(try fixture.repository.loadRecord(recordID: conflict.id))
    }

    func testScreenshotDuplicateReportsCommittedDeletion() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 91)
        let old = makeImageRecord(id: "callback-old", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: old, pngData: png, ocrState: .notRequired)
        )
        let deletions = ThreadSafeStringArrayBox()
        let current = makeImageRecord(id: "callback-current", png: png)

        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: current, pngData: png, ocrState: .notRequired),
            onCommittedDeletion: { deletions.append(contentsOf: $0) }
        )

        XCTAssertEqual(deletions.value, [old.id])
    }

    func testScreenshotBeforeSQLiteCommitFailureDoesNotReportDeletion() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 92)
        let old = makeImageRecord(id: "before-commit-old", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: old, pngData: png, ocrState: .notRequired)
        )
        let failingRepository = ClipboardRepository(
            database: fixture.database,
            blobStore: fixture.blobStore,
            screenshotHistoryFailureInjector: { point in
                guard point == .beforeSQLiteCommit else { return }
                throw InjectedFailure(point: point)
            }
        )
        let deletions = ThreadSafeStringArrayBox()
        let current = makeImageRecord(id: "before-commit-current", png: png)

        XCTAssertThrowsError(try failingRepository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: current, pngData: png, ocrState: .notRequired),
            onCommittedDeletion: { deletions.append(contentsOf: $0) }
        )) { XCTAssertEqual($0 as? InjectedFailure, InjectedFailure(point: .beforeSQLiteCommit)) }

        XCTAssertEqual(deletions.value, [])
    }

    func testScreenshotAfterSQLiteCommitFailureStillReportsDeletion() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 93)
        let old = makeImageRecord(id: "after-commit-old", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: old, pngData: png, ocrState: .notRequired)
        )
        let failingRepository = ClipboardRepository(
            database: fixture.database,
            blobStore: fixture.blobStore,
            screenshotHistoryFailureInjector: { point in
                guard point == .afterSQLiteCommit else { return }
                throw InjectedFailure(point: point)
            }
        )
        let deletions = ThreadSafeStringArrayBox()
        let current = makeImageRecord(id: "after-commit-current", png: png)

        XCTAssertThrowsError(try failingRepository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: current, pngData: png, ocrState: .notRequired),
            onCommittedDeletion: { deletions.append(contentsOf: $0) }
        )) { XCTAssertEqual($0 as? InjectedFailure, InjectedFailure(point: .afterSQLiteCommit)) }

        XCTAssertEqual(deletions.value, [old.id])
    }

    func testDuplicateCommitDoesNotMergeVisionOCR() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 5)
        let old = makeImageRecord(id: "vision-old", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: old,
                pngData: png,
                ocrState: .pending
            )
        )
        let oldDocument = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: old.id))
        XCTAssertTrue(try fixture.repository.updateOCRResult(
            recordID: old.id,
            revision: oldDocument.revision,
            text: "vision-only-text",
            state: .succeeded
        ))

        let current = makeImageRecord(id: "vision-current", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: current,
                pngData: png,
                ocrState: .pending
            )
        )

        let currentDocument = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: current.id))
        XCTAssertEqual(currentDocument.ocrState, .pending)
        XCTAssertNil(currentDocument.ocrText)
        XCTAssertEqual(currentDocument.ocrTextSource, .none)
        XCTAssertTrue(try fixture.repository.search("vision-only-text", limit: 10).isEmpty)
    }

    func testDuplicateCommitPreservesEmptyUserEditedOCRLockAndDoesNotQueuePendingOCR() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 6)
        let old = makeImageRecord(id: "empty-user-ocr-old", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: old,
                pngData: png,
                ocrState: .pending
            )
        )
        _ = try fixture.repository.saveDetailEdit(
            command: ClipboardDetailEditCommand(
                recordID: old.id,
                expectedContentRevision: 1,
                editableKind: .imageOCRText,
                draft: ClipboardDetailDraft(text: ""),
                purpose: "detailEditSave"
            )
        )
        let oldDocument = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: old.id))
        XCTAssertEqual(oldDocument.ocrTextSource, .userEdited)
        XCTAssertEqual(oldDocument.ocrText, "")
        XCTAssertNotNil(oldDocument.ocrLockedContentRevision)

        let current = makeImageRecord(id: "empty-user-ocr-current", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: current,
                pngData: png,
                ocrState: .pending
            )
        )

        let currentDocument = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: current.id))
        XCTAssertEqual(currentDocument.ocrTextSource, .userEdited)
        XCTAssertEqual(currentDocument.ocrText, "")
        XCTAssertEqual(currentDocument.ocrState, .succeeded)
        XCTAssertEqual(currentDocument.ocrLockedContentRevision, currentDocument.contentRevision)
        XCTAssertFalse(try fixture.repository.loadPendingOCRBatch(limit: 20).contains { $0.recordID == current.id })
    }

    func testCommitUsesDecodedPixelsForDedupeAndStoresOriginalPNG() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let plain = pngData(seed: 7)
        let metadataVariant = pngData(seed: 7, metadataLabel: "same pixels, different PNG metadata")
        XCTAssertNotEqual(plain, metadataVariant)

        let old = makeImageRecord(id: "normalized-old", png: plain)
        let first = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: old,
                pngData: plain,
                ocrState: .notRequired
            )
        )
        let current = makeImageRecord(id: "normalized-current", png: metadataVariant)
        let second = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: current,
                pngData: metadataVariant,
                ocrState: .notRequired
            )
        )

        XCTAssertEqual(second.replacedRecordID, old.id)
        XCTAssertEqual(second.record.signatureSHA256, first.record.signatureSHA256)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: old.id))
        XCTAssertEqual(
            try fixture.repository.readPayload(recordID: current.id)?.pngData,
            metadataVariant
        )
        let signatures = try payloadSignatures(database: fixture.database, recordID: current.id)
        XCTAssertEqual(signatures.visual, second.record.signatureSHA256)
        XCTAssertEqual(signatures.payload, sha256(metadataVariant))
    }

    func testCommitRejectsRawDataThatIsNotDecodablePNG() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let invalid = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3])
        let record = makeImageRecord(id: "invalid-png", png: invalid)

        XCTAssertThrowsError(try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: invalid,
                ocrState: .notRequired
            )
        )) {
            guard case let ClipboardRepositoryError.invalidPayload(recordID, field) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(recordID, record.id)
            XCTAssertEqual(field, "screenshotHistory")
        }
        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
    }

    func testPreCommitFailurePointsRollbackDatabaseFTSAndStaging() throws {
        for point in [
            ScreenshotHistoryCommitFailurePoint.afterPayloadStaged,
            .beforeDuplicateDelete,
            .beforeFTSUpdate,
            .beforeSQLiteCommit,
        ] {
            let fixture = try makeFixture(injectedFailurePoint: point)
            let png = pngData(seed: UInt8(10 + point.testOrdinal))
            if point == .beforeDuplicateDelete {
                let old = makeImageRecord(id: "old-\(point.testOrdinal)", png: png)
                _ = try fixture.repository.insert(record: old, payload: makePayload(recordID: old.id, png: png))
            }
            let current = makeImageRecord(id: "current-\(point.testOrdinal)", png: png)

            XCTAssertThrowsError(try fixture.repository.commitScreenshotHistory(
                request: ScreenshotHistoryCommitRequest(
                    record: current,
                    pngData: png,
                    ocrState: .notRequired
                )
            )) { XCTAssertEqual($0 as? InjectedFailure, InjectedFailure(point: point)) }
            XCTAssertNil(try fixture.repository.loadRecord(recordID: current.id))
            XCTAssertTrue(try fixture.repository.search("screenshot", limit: 20).allSatisfy { $0.id != current.id })
            XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 0)
            fixture.close()
        }
    }

    func testPostCommitPromotionFailureIsRecoveredOnRepositoryRestart() throws {
        let fixture = try makeFixture(injectedFailurePoint: .beforeSidecarPromote)
        let png = pngData(seed: 20)
        let current = makeImageRecord(id: "recover-current", png: png)

        XCTAssertThrowsError(try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: current,
                pngData: png,
                ocrState: .notRequired
            )
        )) { XCTAssertEqual($0 as? InjectedFailure, InjectedFailure(point: .beforeSidecarPromote)) }
        XCTAssertNotNil(try fixture.repository.loadRecord(recordID: current.id))
        XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 1)

        let recovered = ClipboardRepository(database: fixture.database, blobStore: fixture.blobStore)
        let recoveredPNG = try XCTUnwrap(
            recovered.readPayload(recordID: current.id)?.pngData
        )
        XCTAssertEqual(recoveredPNG, png)
        XCTAssertEqual(
            try payloadSignatures(database: fixture.database, recordID: current.id).payload,
            sha256(recoveredPNG)
        )
        XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 0)
        fixture.close()
    }

    func testCleanupWaitsForActiveScreenshotCommit() throws {
        let payloadStaged = expectation(description: "payload staged")
        let allowCommit = DispatchSemaphore(value: 0)
        let fixture = try makeFixture(screenshotHistoryFailureInjector: { point in
            guard point == .afterPayloadStaged else { return }
            payloadStaged.fulfill()
            guard allowCommit.wait(timeout: .now() + 5) == .success else {
                throw InjectedFailure(point: point)
            }
        })
        defer { fixture.close() }
        let png = pngData(seed: 22)
        let record = makeImageRecord(id: "serialized-commit", png: png)
        let commitFinished = expectation(description: "commit finished")
        let cleanupStarted = expectation(description: "cleanup started")
        let cleanupFinished = DispatchSemaphore(value: 0)
        let commitError = ThreadSafeErrorBox()
        let cleanupError = ThreadSafeErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { commitFinished.fulfill() }
            do {
                _ = try fixture.repository.commitScreenshotHistory(
                    request: ScreenshotHistoryCommitRequest(
                        record: record,
                        pngData: png,
                        ocrState: .notRequired
                    )
                )
            } catch {
                commitError.store(error)
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [payloadStaged], timeout: 2), .completed)

        DispatchQueue.global(qos: .userInitiated).async {
            cleanupStarted.fulfill()
            defer { cleanupFinished.signal() }
            do {
                try fixture.repository.cleanupUnreferencedSidecars()
            } catch {
                cleanupError.store(error)
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [cleanupStarted], timeout: 2), .completed)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 1)

        allowCommit.signal()
        XCTAssertEqual(XCTWaiter().wait(for: [commitFinished], timeout: 5), .completed)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(commitError.value)
        XCTAssertNil(cleanupError.value)
        let storedPNG = try XCTUnwrap(
            fixture.repository.readPayload(recordID: record.id)?.pngData
        )
        XCTAssertEqual(storedPNG, png)
        XCTAssertEqual(
            try payloadSignatures(database: fixture.database, recordID: record.id).payload,
            sha256(storedPNG)
        )
    }

    func testSecondRepositoryStartupMaintenanceWaitsForActiveScreenshotCommit() throws {
        let payloadStaged = expectation(description: "payload staged")
        let allowCommit = DispatchSemaphore(value: 0)
        let fixture = try makeFixture(screenshotHistoryFailureInjector: { point in
            guard point == .afterPayloadStaged else { return }
            payloadStaged.fulfill()
            guard allowCommit.wait(timeout: .now() + 5) == .success else {
                throw InjectedFailure(point: point)
            }
        })
        defer { fixture.close() }
        let png = pngData(seed: 23)
        let record = makeImageRecord(id: "cross-repository-commit", png: png)
        let commitFinished = expectation(description: "commit finished")
        let maintenanceStarted = expectation(description: "second repository maintenance started")
        let maintenanceFinished = DispatchSemaphore(value: 0)
        let commitError = ThreadSafeErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { commitFinished.fulfill() }
            do {
                _ = try fixture.repository.commitScreenshotHistory(
                    request: ScreenshotHistoryCommitRequest(
                        record: record,
                        pngData: png,
                        ocrState: .notRequired
                    )
                )
            } catch {
                commitError.store(error)
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [payloadStaged], timeout: 2), .completed)

        DispatchQueue.global(qos: .userInitiated).async {
            maintenanceStarted.fulfill()
            _ = ClipboardRepository(database: fixture.database, blobStore: fixture.blobStore)
            maintenanceFinished.signal()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [maintenanceStarted], timeout: 2), .completed)
        XCTAssertEqual(maintenanceFinished.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 1)

        allowCommit.signal()
        XCTAssertEqual(XCTWaiter().wait(for: [commitFinished], timeout: 5), .completed)
        XCTAssertEqual(maintenanceFinished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(commitError.value)
        let storedPNG = try XCTUnwrap(
            fixture.repository.readPayload(recordID: record.id)?.pngData
        )
        XCTAssertEqual(storedPNG, png)
        XCTAssertEqual(
            try payloadSignatures(database: fixture.database, recordID: record.id).payload,
            sha256(storedPNG)
        )
    }

    func testStartupRecoversStagedDrainsPendingAndRemovesUnrelatedOrphan() throws {
        let fixture = try makeFixture(
            screenshotHistoryFailureInjector: { point in
                if point == .beforeSidecarPromote { throw InjectedFailure(point: point) }
            },
            sidecarDeletionFailureInjector: { _ in throw SidecarDeleteFailure() }
        )
        let stagedPNG = pngData(seed: 109)
        let stagedRecord = makeImageRecord(id: "startup-staged", png: stagedPNG)
        XCTAssertThrowsError(try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: stagedRecord, pngData: stagedPNG, ocrState: .notRequired)
        ))
        XCTAssertEqual(try stagedURLs(in: fixture.blobStore).count, 1)

        let pending = makeImageRecord(id: "startup-pending", png: pngData(seed: 110))
        _ = try fixture.repository.insert(record: pending, payload: makePayload(recordID: pending.id, png: pngData(seed: 110)))
        _ = try fixture.repository.delete(recordID: pending.id)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
        let orphan = try fixture.blobStore.write(data: Data([1, 2, 3]), recordID: "startup-orphan", fileExtension: "png")

        fixture.database.close()
        let reopened = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: fixture.root))
        defer { reopened.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let recovered = ClipboardRepository(database: reopened)
        XCTAssertEqual(try recovered.pendingSidecarCleanupCount(), 0)
        XCTAssertEqual(try recovered.readPayload(recordID: stagedRecord.id)?.pngData, stagedPNG)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.environment.blobDirectory.appendingPathComponent(orphan).path))
    }

    func testOldSidecarDeletionIsBestEffortAndRecoveryRemovesOrphan() throws {
        let fixture = try makeFixture(
            sidecarDeletionFailureInjector: { _ in throw SidecarDeleteFailure() }
        )
        let png = pngData(seed: 21)
        let old = makeImageRecord(id: "old-sidecar", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: old,
                pngData: png,
                ocrState: .notRequired
            )
        )
        XCTAssertEqual(try payloadURLs(in: fixture.blobStore).count, 1)

        let current = makeImageRecord(id: "new-sidecar", png: png)
        let result = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: current,
                pngData: png,
                ocrState: .notRequired
            )
        )
        XCTAssertEqual(result.replacedRecordID, old.id)
        XCTAssertEqual(try payloadURLs(in: fixture.blobStore).count, 2)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)

        let recovered = ClipboardRepository(database: fixture.database, blobStore: fixture.blobStore)
        let recoveredPNG = try XCTUnwrap(
            recovered.readPayload(recordID: current.id)?.pngData
        )
        XCTAssertEqual(recoveredPNG, png)
        XCTAssertEqual(
            try payloadSignatures(database: fixture.database, recordID: current.id).payload,
            sha256(recoveredPNG)
        )
        XCTAssertEqual(try payloadURLs(in: fixture.blobStore).count, 1)
        fixture.close()
    }

    func testStartupRecoveryFailureSkipsCleanupAndPublishesLowSensitivityStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSidecarStartupFailureTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        defer { database.close() }
        let blobStore = BlobStore(directory: database.environment.blobDirectory, sidecarThresholdBytes: 1)
        _ = try blobStore.stage(data: pngData(seed: 29), recordID: "recoverable", fileExtension: "png")

        let repository = ClipboardRepository(
            database: database,
            blobStore: blobStore,
            screenshotHistoryFailureInjector: { _ in },
            screenshotHistoryMaintenanceFailureInjector: {
                throw StartupMaintenanceFailure()
            }
        )

        XCTAssertEqual(
            repository.screenshotHistoryMaintenanceStatus,
            .recoveryFailed(code: "sidecar_recovery_failed")
        )
        XCTAssertThrowsError(try repository.cleanupUnreferencedSidecars())
        XCTAssertEqual(try stagedURLs(in: blobStore).count, 1)
        XCTAssertEqual(try payloadURLs(in: blobStore).count, 0)
    }

    func testOCRRetryPreparationTransitionsOnlyRetryableStateWithoutIncrementingAttempts() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 35)
        let record = makeImageRecord(id: "retryable-ocr", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: png,
                ocrState: .pending
            )
        )
        let revision = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: record.id)?.revision)
        XCTAssertTrue(try fixture.repository.updateOCRResult(
            recordID: record.id,
            revision: revision,
            text: nil,
            state: .failed,
            errorCode: "fixture_failure"
        ))
        let failed = try XCTUnwrap(fixture.repository.loadSearchDocument(recordID: record.id))

        guard case let .ready(prepared) = try fixture.repository.prepareOCRRetry(recordID: record.id) else {
            return XCTFail("Failed OCR must be atomically prepared for retry")
        }
        XCTAssertEqual(prepared.ocrState, .pending)
        XCTAssertEqual(prepared.ocrAttemptCount, failed.ocrAttemptCount)
        XCTAssertNil(prepared.ocrErrorCode)

        guard case let .alreadyPending(unchanged) = try fixture.repository.prepareOCRRetry(recordID: record.id) else {
            return XCTFail("Pending OCR must not be rewritten as a fresh retry")
        }
        XCTAssertEqual(unchanged.ocrAttemptCount, prepared.ocrAttemptCount)
        XCTAssertEqual(unchanged.updatedAt, prepared.updatedAt)
    }

    func testBlobStoreStageAbortPromoteAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreStageTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let data = pngData(seed: 30)

        let aborted = try store.stage(data: data, recordID: "abort", fileExtension: "png")
        XCTAssertEqual(try stagedURLs(in: store).count, 1)
        try store.abort(aborted)
        XCTAssertEqual(try stagedURLs(in: store).count, 0)

        let recoverable = try store.stage(data: data, recordID: "recover", fileExtension: "png")
        let report = try store.recover(retaining: [recoverable.relativePath])
        XCTAssertEqual(report.promotedCount, 1)
        XCTAssertEqual(try store.read(relativePath: recoverable.relativePath), data)

        let orphan = try store.stage(data: data, recordID: "orphan", fileExtension: "png")
        let cleanup = try store.recover(retaining: [recoverable.relativePath])
        XCTAssertEqual(cleanup.removedStagingCount, 1)
        XCTAssertThrowsError(try store.promote(orphan))
    }

    func testBlobStoreHardensDirectoryAndSidecarPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePermissions.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let data = pngData(seed: 33)

        let writtenPath = try store.write(data: data, recordID: "private-write", fileExtension: "png")
        let writtenURL = root.appendingPathComponent(writtenPath)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: root), 0o700)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: writtenURL), 0o600)

        let staged = try store.stage(data: data, recordID: "private-stage", fileExtension: "png")
        let stagedURL = root.appendingPathComponent(staged.stagingRelativePath)
        let promotedURL = root.appendingPathComponent(staged.relativePath)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: stagedURL), 0o600)
        try Data("old".utf8).write(to: promotedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: stagedURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: promotedURL.path)

        try store.promote(staged)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: root), 0o700)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: promotedURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: promotedURL), data)

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: writtenURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: promotedURL.path)
        _ = try store.recover(retaining: [writtenPath, staged.relativePath])
        XCTAssertEqual(try blobStorePOSIXPermissions(at: root), 0o700)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: writtenURL), 0o600)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: promotedURL), 0o600)
    }

    func testBlobStoreRecoveryRejectsStagedSymlinkBeforeReadingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreSymlinkRecovery.\(UUID().uuidString)", isDirectory: true)
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreSymlinkTarget.\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalURL)
        }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let data = pngData(seed: 34)
        let staged = try store.stage(data: data, recordID: "symlink-stage", fileExtension: "png")
        let stagedURL = root.appendingPathComponent(staged.stagingRelativePath)
        try FileManager.default.removeItem(at: stagedURL)
        try data.write(to: externalURL)
        try FileManager.default.createSymbolicLink(at: stagedURL, withDestinationURL: externalURL)

        XCTAssertThrowsError(
            try store.recover(retaining: [staged.relativePath: sha256(data)])
        ) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidRelativePath(staged.stagingRelativePath))
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), data)
    }

    func testBlobStoreRecoveryPromotesOnlyStagingMatchingCommittedDigest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreDigestRecoveryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let committedData = pngData(seed: 31)
        let staleData = pngData(seed: 32)
        let committed = try store.stage(data: committedData, recordID: "same-final", fileExtension: "png")
        _ = try store.stage(data: staleData, recordID: "same-final", fileExtension: "png")

        let report = try store.recover(retaining: [committed.relativePath: sha256(committedData)])

        XCTAssertEqual(report.promotedCount, 1)
        XCTAssertEqual(report.removedStagingCount, 1)
        XCTAssertEqual(try store.read(relativePath: committed.relativePath), committedData)
        XCTAssertEqual(try stagedURLs(in: store).count, 0)
    }

    func testBlobStoreReadUsesOpenedDescriptorWhenNameIsReplacedAfterValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreDescriptorRead.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let original = Data("original-sidecar".utf8)
        let replacement = Data("replacement-sidecar".utf8)
        let relativePath = try store.write(data: original, recordID: "descriptor-read", fileExtension: "blob")
        let fileURL = root.appendingPathComponent(relativePath)
        let retainedURL = root.appendingPathComponent("retained-original")
        var checkpointReached = false
        var hookError: Error?
        store.testCheckpointHandler = { checkpoint in
            guard checkpoint == .readDescriptorOpened(relativePath), !checkpointReached else { return }
            checkpointReached = true
            do {
                try FileManager.default.moveItem(at: fileURL, to: retainedURL)
                try replacement.write(to: fileURL)
            } catch {
                hookError = error
            }
        }

        let loaded = try store.read(relativePath: relativePath)

        XCTAssertTrue(checkpointReached)
        XCTAssertNil(hookError)
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try Data(contentsOf: fileURL), replacement)
    }

    func testBlobStoreWriteRejectsRootReplacementWithoutWritingExternalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePinnedRoot.\(UUID().uuidString)", isDirectory: true)
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePinnedRootRetained.\(UUID().uuidString)", isDirectory: true)
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePinnedRootExternal.\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: retainedRoot)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let sentinelURL = externalRoot.appendingPathComponent("sentinel")
        let sentinel = Data("must-remain-untouched".utf8)
        try sentinel.write(to: sentinelURL)
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        var checkpointReached = false
        var hookError: Error?
        store.testCheckpointHandler = { checkpoint in
            guard checkpoint == .rootDescriptorOpened, !checkpointReached else { return }
            checkpointReached = true
            do {
                try FileManager.default.moveItem(at: root, to: retainedRoot)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: externalRoot)
            } catch {
                hookError = error
            }
        }

        XCTAssertThrowsError(
            try store.write(data: Data("private".utf8), recordID: "root-replacement")
        ) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidStorageDirectory(root.path))
        }
        XCTAssertTrue(checkpointReached)
        XCTAssertNil(hookError)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: externalRoot.path)),
            ["sentinel"]
        )
    }

    func testBlobStoreRejectsOrdinaryRootReplacementAcrossOperationsBeforeMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreBoundRoot.\(UUID().uuidString)", isDirectory: true)
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreBoundRootRetained.\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: retainedRoot)
        }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        _ = try store.write(
            data: Data("bind-original-root".utf8),
            recordID: "bind-original-root",
            fileExtension: "blob"
        )
        try FileManager.default.moveItem(at: root, to: retainedRoot)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let sentinelURL = root.appendingPathComponent("sentinel")
        let sentinel = Data("replacement-directory-must-remain-untouched".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sentinelURL.path)

        XCTAssertThrowsError(
            try store.write(data: Data("must-not-write".utf8), recordID: "replacement-write")
        ) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidStorageDirectory(root.path))
        }
        XCTAssertThrowsError(try store.delete(relativePath: "sentinel")) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidStorageDirectory(root.path))
        }
        XCTAssertThrowsError(try store.deleteAll()) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidStorageDirectory(root.path))
        }
        XCTAssertEqual(try blobStorePOSIXPermissions(at: root), 0o755)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: sentinelURL), 0o640)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: root.path)),
            ["sentinel"]
        )
    }

    func testBlobStoreRecoveryRejectsHardLinkedStagingBeforeDigestRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreHardLinkRecovery.\(UUID().uuidString)", isDirectory: true)
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreHardLinkTarget.\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalURL)
        }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let data = Data("external-private-data".utf8)
        try data.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: externalURL.path)
        let staged = try store.stage(data: data, recordID: "hard-link-stage", fileExtension: "blob")
        let stagedURL = root.appendingPathComponent(staged.stagingRelativePath)
        try FileManager.default.removeItem(at: stagedURL)
        try FileManager.default.linkItem(at: externalURL, to: stagedURL)

        XCTAssertThrowsError(
            try store.recover(retaining: [staged.relativePath: sha256(data)])
        ) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidRelativePath(staged.stagingRelativePath))
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), data)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: externalURL), 0o640)
    }

    func testBlobStorePromoteDoesNotChmodSymlinkReplacementAfterRename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePromoteReplacement.\(UUID().uuidString)", isDirectory: true)
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePromoteExternal.\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalURL)
        }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let staged = try store.stage(
            data: Data("promoted-data".utf8),
            recordID: "promote-replacement",
            fileExtension: "blob"
        )
        let finalURL = root.appendingPathComponent(staged.relativePath)
        let externalData = Data("external-data".utf8)
        try externalData.write(to: externalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: externalURL.path)
        var checkpointReached = false
        var hookError: Error?
        store.testCheckpointHandler = { checkpoint in
            guard checkpoint == .promoteRenamed(staged.relativePath), !checkpointReached else { return }
            checkpointReached = true
            do {
                try FileManager.default.removeItem(at: finalURL)
                try FileManager.default.createSymbolicLink(at: finalURL, withDestinationURL: externalURL)
            } catch {
                hookError = error
            }
        }

        XCTAssertThrowsError(try store.promote(staged)) { error in
            XCTAssertEqual(error as? BlobStoreError, .invalidRelativePath(staged.relativePath))
        }
        XCTAssertTrue(checkpointReached)
        XCTAssertNil(hookError)
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: externalURL), 0o640)
    }

    func testBlobStorePromoteValidatesOrdinaryReplacementBeforeChangingPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStorePromoteOrdinaryReplacement.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        let staged = try store.stage(
            data: Data("promoted-data".utf8),
            recordID: "promote-ordinary-replacement",
            fileExtension: "blob"
        )
        let finalURL = root.appendingPathComponent(staged.relativePath)
        let replacementURL = root.appendingPathComponent("ordinary-replacement")
        let replacementData = Data("ordinary-replacement-data".utf8)
        try replacementData.write(to: replacementURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: replacementURL.path
        )
        var checkpointReached = false
        var hookError: Error?
        store.testCheckpointHandler = { checkpoint in
            guard checkpoint == .promoteRenamed(staged.relativePath), !checkpointReached else { return }
            checkpointReached = true
            do {
                try FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: replacementURL, to: finalURL)
            } catch {
                hookError = error
            }
        }

        XCTAssertThrowsError(try store.promote(staged)) { error in
            XCTAssertEqual(error as? BlobStoreError, .integrityCheckFailed(staged.relativePath))
        }
        XCTAssertTrue(checkpointReached)
        XCTAssertNil(hookError)
        XCTAssertEqual(try Data(contentsOf: finalURL), replacementData)
        XCTAssertEqual(try blobStorePOSIXPermissions(at: finalURL), 0o640)
    }

    func testSidecarDirectorySyncFailureRetainsOutboxAfterPhysicalDeletion() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 48)
        let record = makeImageRecord(id: "outbox-directory-sync-failure", png: png)
        _ = try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: png)
        )
        let relativePath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ))
        let sidecarURL = fixture.blobStore.directory.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        fixture.blobStore.testDirectorySynchronizationHook = {
            throw BlobStoreError.fileSystemFailure(EIO)
        }

        XCTAssertEqual(try fixture.repository.delete(recordID: record.id), .deleted)

        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
        XCTAssertEqual(try fixture.database.connection.firstInt(
            "SELECT attempt_count FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
            bindings: [.string(relativePath)]
        ), 1)
        XCTAssertEqual(try fixture.database.connection.firstString(
            "SELECT last_error_code FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
            bindings: [.string(relativePath)]
        ), "delete_failed")

        var retryDirectorySynchronizationCount = 0
        fixture.blobStore.testDirectorySynchronizationHook = {
            retryDirectorySynchronizationCount += 1
        }
        XCTAssertEqual(try fixture.repository.drainSidecarCleanupOutbox(), 0)
        XCTAssertEqual(retryDirectorySynchronizationCount, 1)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
    }

    func testInsertRollbackDurablyQueuesCreatedSidecarWhenImmediateCleanupSyncFails() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let recordID = "rollback-sidecar-cleanup"
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_rollback_sidecar_search_document
            BEFORE INSERT ON clipboard_search_documents
            WHEN NEW.record_id = '\(recordID)'
            BEGIN
                SELECT RAISE(ABORT, 'injected search document failure');
            END;
            """
        )
        var directorySynchronizationCount = 0
        fixture.blobStore.testDirectorySynchronizationHook = {
            directorySynchronizationCount += 1
            if directorySynchronizationCount == 2 {
                throw BlobStoreError.fileSystemFailure(EIO)
            }
        }
        let png = pngData(seed: 49)
        let record = makeImageRecord(id: recordID, png: png)

        XCTAssertThrowsError(try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: png)
        ))

        XCTAssertEqual(directorySynchronizationCount, 2)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
        XCTAssertNil(try fixture.repository.readPayload(recordID: record.id))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 1)
        let queuedPath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT relative_path FROM clipboard_sidecar_cleanup"
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.blobStore.directory.appendingPathComponent(queuedPath).path
            )
        )
        XCTAssertEqual(try fixture.database.connection.firstInt(
            "SELECT attempt_count FROM clipboard_sidecar_cleanup WHERE relative_path = ?",
            bindings: [.string(queuedPath)]
        ), 1)

        var retryDirectorySynchronizationCount = 0
        fixture.blobStore.testDirectorySynchronizationHook = {
            retryDirectorySynchronizationCount += 1
        }
        XCTAssertEqual(try fixture.repository.drainSidecarCleanupOutbox(), 0)
        XCTAssertEqual(retryDirectorySynchronizationCount, 1)
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
    }

    func testInsertRollbackFallsBackToDurableDeleteWhenCleanupJournalInsertFails() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let recordID = "rollback-sidecar-journal-fallback"
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_rollback_sidecar_search_document_for_fallback
            BEFORE INSERT ON clipboard_search_documents
            WHEN NEW.record_id = '\(recordID)'
            BEGIN
                SELECT RAISE(ABORT, 'injected search document failure');
            END;
            """
        )
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_rollback_sidecar_cleanup_journal
            BEFORE INSERT ON clipboard_sidecar_cleanup
            BEGIN
                SELECT RAISE(ABORT, 'injected cleanup journal failure');
            END;
            """
        )
        var directorySynchronizationCount = 0
        fixture.blobStore.testDirectorySynchronizationHook = {
            directorySynchronizationCount += 1
        }
        let png = pngData(seed: 50)
        let record = makeImageRecord(id: recordID, png: png)

        XCTAssertThrowsError(try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: png)
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("injected search document failure"))
            if let repositoryError = error as? ClipboardRepositoryError,
               case .sidecarCleanupPersistenceFailed = repositoryError {
                XCTFail("The durable direct-delete fallback should preserve the original operation error")
            }
        }

        XCTAssertEqual(directorySynchronizationCount, 2)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
        XCTAssertNil(try fixture.repository.readPayload(recordID: record.id))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: fixture.blobStore.directory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testInsertRollbackFailsClosedWhenCleanupJournalAndDurableDeleteBothFail() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let recordID = "rollback-sidecar-cleanup-unavailable"
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_rollback_sidecar_search_document_for_cleanup_failure
            BEFORE INSERT ON clipboard_search_documents
            WHEN NEW.record_id = '\(recordID)'
            BEGIN
                SELECT RAISE(ABORT, 'injected search document failure');
            END;
            """
        )
        try fixture.database.connection.execute(
            """
            CREATE TRIGGER reject_rollback_sidecar_cleanup_journal_and_delete
            BEFORE INSERT ON clipboard_sidecar_cleanup
            BEGIN
                SELECT RAISE(ABORT, 'injected cleanup journal failure');
            END;
            """
        )
        var directorySynchronizationCount = 0
        fixture.blobStore.testDirectorySynchronizationHook = {
            directorySynchronizationCount += 1
            if directorySynchronizationCount == 2 {
                throw BlobStoreError.fileSystemFailure(EIO)
            }
        }
        let png = pngData(seed: 51)
        let record = makeImageRecord(id: recordID, png: png)

        XCTAssertThrowsError(try fixture.repository.insert(
            record: record,
            payload: makePayload(recordID: record.id, png: png)
        )) { error in
            guard let repositoryError = error as? ClipboardRepositoryError,
                  case .sidecarCleanupPersistenceFailed = repositoryError else {
                return XCTFail("Expected fail-closed cleanup persistence error, got \(error)")
            }
        }

        XCTAssertEqual(directorySynchronizationCount, 2)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: record.id))
        XCTAssertNil(try fixture.repository.readPayload(recordID: record.id))
        XCTAssertEqual(try fixture.repository.pendingSidecarCleanupCount(), 0)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: fixture.blobStore.directory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testBlobStoreDeleteAllSynchronizesSuccessfulUnlinkBeforeLaterFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreDeleteAllSync.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstFileURL = root.appendingPathComponent("a-file")
        let laterDirectoryURL = root.appendingPathComponent("z-directory", isDirectory: true)
        try Data("delete-first".utf8).write(to: firstFileURL)
        try FileManager.default.createDirectory(at: laterDirectoryURL, withIntermediateDirectories: false)
        let store = BlobStore(directory: root, sidecarThresholdBytes: 1)
        var directorySynchronizationCount = 0
        store.testDirectorySynchronizationHook = {
            directorySynchronizationCount += 1
        }

        XCTAssertThrowsError(try store.deleteAll()) { error in
            guard let blobError = error as? BlobStoreError,
                  case .fileSystemFailure = blobError else {
                return XCTFail("Expected directory unlink to fail, got \(error)")
            }
        }
        XCTAssertEqual(directorySynchronizationCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFileURL.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: laterDirectoryURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testClipboardRepositoryRejectsSidecarWhoseBytesDoNotMatchCommittedDigest() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let png = pngData(seed: 47)
        let record = makeImageRecord(id: "sidecar-integrity", png: png)
        _ = try fixture.repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(record: record, pngData: png, ocrState: .pending)
        )
        let relativePath = try XCTUnwrap(fixture.database.connection.firstString(
            "SELECT png_sidecar_path FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        ))
        let sidecarURL = fixture.blobStore.directory.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: sidecarURL)
        try Data("different-owned-file".utf8).write(to: sidecarURL)

        XCTAssertThrowsError(try fixture.repository.readImageData(recordID: record.id)) { error in
            XCTAssertEqual(error as? BlobStoreError, .integrityCheckFailed(relativePath))
        }
    }
}

private extension ClipboardScreenshotHistoryRepositoryTests {
    struct Fixture {
        let root: URL
        let database: AppDatabase
        let blobStore: BlobStore
        let repository: ClipboardRepository

        func close() {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func columnNames(table: String, database: AppDatabase) throws -> Set<String> {
        try database.connection.withStatement("PRAGMA table_info(\(table))") { statement in
            var names: Set<String> = []
            while try statement.step() {
                if let name = statement.columnString(1) {
                    names.insert(name)
                }
            }
            return names
        }
    }

    func blobStorePOSIXPermissions(at url: URL) throws -> Int {
        var metadata = stat()
        let result = url.path.withCString { path in
            lstat(path, &metadata)
        }
        guard result == 0,
              metadata.st_mode & S_IFMT == (url.hasDirectoryPath ? S_IFDIR : S_IFREG) else {
            throw BlobStoreError.invalidRelativePath(url.lastPathComponent)
        }
        return Int(metadata.st_mode & 0o777)
    }

    func makeFixture(
        injectedFailurePoint: ScreenshotHistoryCommitFailurePoint? = nil,
        screenshotHistoryFailureInjector: ((ScreenshotHistoryCommitFailurePoint) throws -> Void)? = nil,
        sidecarDeletionFailureInjector: (@Sendable (String) throws -> Void)? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardScreenshotHistoryRepositoryTests.\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        let blobStore = BlobStore(directory: database.environment.blobDirectory, sidecarThresholdBytes: 32)
        let repository: ClipboardRepository
        if let screenshotHistoryFailureInjector {
            repository = ClipboardRepository(
                database: database,
                blobStore: blobStore,
                screenshotHistoryFailureInjector: screenshotHistoryFailureInjector,
                sidecarDeletionFailureInjector: sidecarDeletionFailureInjector
            )
        } else if let injectedFailurePoint {
            repository = ClipboardRepository(
                database: database,
                blobStore: blobStore,
                screenshotHistoryFailureInjector: { point in
                    guard point == injectedFailurePoint else { return }
                    throw InjectedFailure(point: point)
                }
            )
        } else if let sidecarDeletionFailureInjector {
            repository = ClipboardRepository(
                database: database,
                blobStore: blobStore,
                sidecarDeletionFailureInjector: sidecarDeletionFailureInjector
            )
        } else {
            repository = ClipboardRepository(database: database, blobStore: blobStore)
        }
        return Fixture(root: root, database: database, blobStore: blobStore, repository: repository)
    }

    func makeTextRecord(id: String, text: String, signature: String? = nil) -> ClipboardRecorderRecord {
        ClipboardRecorderRecord(
            id: id,
            createdAt: Date(),
            changeCount: 1,
            kind: .text,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: text.count,
                byteCount: text.lengthOfBytes(using: .utf8)
            ),
            sourceApp: nil,
            signatureSHA256: signature ?? String(repeating: "0", count: 64),
            signatureSHA256_12: String((signature ?? String(repeating: "0", count: 64)).prefix(12)),
            fixtureOwned: false,
            restorable: true,
            summary: text
        )
    }

    struct InjectedFailure: Error, Equatable {
        let point: ScreenshotHistoryCommitFailurePoint
    }

    struct StartupMaintenanceFailure: Error {}
    struct SidecarDeleteFailure: Error {}

    func pngData(seed: UInt8, metadataLabel: String? = nil) -> Data {
        let pixels = Data((0..<4).flatMap { pixel -> [UInt8] in
            let offset = UInt8(pixel * 3)
            return [seed &+ offset, seed &+ offset &+ 1, seed &+ offset &+ 2, 255]
        })
        let provider = CGDataProvider(data: pixels as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big)
        let image = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let metadataLabel {
            properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: metadataLabel]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func makeImageRecord(
        id: String,
        png: Data,
        signatureOverride: String? = nil,
        createdAt: Date = Date(),
        changeCount: Int? = nil,
        lastCopiedAt: Date? = nil
    ) -> ClipboardRecorderRecord {
        let signature = signatureOverride ?? sha256(png)
        return ClipboardRecorderRecord(
            id: id,
            createdAt: createdAt,
            changeCount: changeCount ?? abs(id.hashValue % 100_000) + 1,
            kind: .image,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.png"],
                byteCount: png.count
            ),
            sourceApp: ClipboardRecorderSourceApp(
                bundleIdentifier: "app.blocks.tests",
                localizedName: "Blocks Tests",
                sourceAppIsCandidate: true
            ),
            signatureSHA256: signature,
            signatureSHA256_12: String(signature.prefix(12)),
            fixtureOwned: false,
            restorable: true,
            lastCopiedAt: lastCopiedAt,
            summary: "Screenshot"
        )
    }

    func payloadSignatures(
        database: AppDatabase,
        recordID: String
    ) throws -> (visual: String, payload: String) {
        let row = try database.connection.withStatement(
            """
            SELECT visual_signature_sha256, png_payload_sha256
            FROM clipboard_payloads
            WHERE record_id = ?
            """,
            bindings: [.string(recordID)]
        ) { statement -> (String?, String?)? in
            guard try statement.step() else { return nil }
            return (statement.columnString(0), statement.columnString(1))
        }
        let resolved = try XCTUnwrap(row)
        return (try XCTUnwrap(resolved.0), try XCTUnwrap(resolved.1))
    }

    func makePayload(recordID: String, png: Data) -> ClipboardRecorderPayload {
        ClipboardRecorderPayload(
            recordID: recordID,
            kind: .image,
            pngData: png
        )
    }

    func insertOrdinaryTag(
        database: AppDatabase,
        id: String,
        displayName: String,
        normalizedName: String,
        sortOrder: Int
    ) throws {
        try database.connection.withStatement(
            """
            INSERT INTO clipboard_tags
                (id, display_name, normalized_name, color_token, sort_order, built_in_kind, created_at, updated_at)
            VALUES (?, ?, ?, 'blue', ?, 'none', ?, ?)
            """,
            bindings: [
                .string(id), .string(displayName), .string(normalizedName), .int(sortOrder),
                .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970),
            ]
        ) { statement in _ = try statement.step() }
    }

    func createdTagID(_ result: ClipboardTagMutationResult) throws -> String {
        try XCTUnwrap(result.changedTagIDs.first)
    }

    func stagedURLs(in store: BlobStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".staged.") }
    }

    func payloadURLs(in store: BlobStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.contains(".staged.") }
    }

    func tagSortOrders(database: AppDatabase) throws -> [String: Int] {
        try database.connection.withStatement("SELECT id, sort_order FROM clipboard_tags ORDER BY id") { statement in
            var values: [String: Int] = [:]
            while try statement.step() {
                if let id = statement.columnString(0) {
                    values[id] = statement.columnInt(1)
                }
            }
            return values
        }
    }
}

private final class ThreadSafeCommittedDeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackCount = 0
    private var committedIDs: [String] = []

    func record(_ ids: [String]) {
        lock.lock()
        callbackCount += 1
        committedIDs = ids
        lock.unlock()
    }

    var snapshot: (count: Int, ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (callbackCount, committedIDs)
    }
}

private final class ThreadSafeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func store(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}

private final class ThreadSafeStringArrayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(contentsOf newValues: [String]) {
        lock.lock()
        values.append(contentsOf: newValues)
        lock.unlock()
    }
}

private extension ScreenshotHistoryCommitFailurePoint {
    var testOrdinal: Int {
        switch self {
        case .afterPayloadStaged: 1
        case .beforeDuplicateDelete: 2
        case .beforeFTSUpdate: 3
        case .beforeSQLiteCommit: 4
        case .afterSQLiteCommit: 5
        case .beforeSidecarPromote: 6
        case .beforeOldSidecarDelete: 7
        }
    }
}
