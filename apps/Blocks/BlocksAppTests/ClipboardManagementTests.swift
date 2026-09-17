import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import BlocksCore

final class ClipboardManagementTests: XCTestCase {
    func testVersionedDocumentRejectsUnknownFieldsWrongTypesAndKindsBeforeWriting() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        for json in [
            #"{"schema_version":1,"records":[],"unknown":true}"#,
            #"{"schema_version":"1","records":[]}"#,
            #"{"schema_version":1,"records":null}"#,
            #"{"schema_version":1,"records":[{"kind":"text","text":"fixture","unknown":true}]}"#,
            #"{"schema_version":1,"records":[{"kind":"text","text":123}]}"#,
            #"{"schema_version":1,"records":[{"kind":"text","text":"fixture","tags":[123]}]}"#,
            #"{"schema_version":2,"records":[]}"#,
            #"{"schema_version":1,"records":[{"kind":"mixed","text":"fixture"}]}"#,
            #"{"schema_version":1,"records":[{"kind":"text","text":"fixture","png_base64":"AQ=="}]}"#
        ] {
            XCTAssertThrowsError(try {
                let document = try ClipboardImportDocument.decode(Data(json.utf8))
                _ = try fixture.repository.executeManagement(.init(operation: "import", document: document))
            }())
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ClipboardManagementActionInput.self,
            from: Data(#"{"operation":"list","unknown":true}"#.utf8)))
        XCTAssertTrue(try fixture.repository.loadRecent(limit: 10).isEmpty)
    }

    func testAllSupportedKindsRoundTripAndPreserveMetadata() throws {
        let source = try Fixture(); defer { source.close() }
        let target = try Fixture(); defer { target.close() }
        let png = try makePNG()
        let rtf = Data("{\\rtf1\\ansi rich sample}".utf8).base64EncodedString()
        let document = ClipboardImportDocument(pinboards: ["Imported", "Empty Board"], records: [
            ClipboardImportRecord(kind: "text", text: "plain", pinboard: "Imported", tags: ["project"], title: "Title", createdAt: "2025-01-01T01:00:00Z", lastCopiedAt: "2025-01-02T01:00:00Z", isFavorite: true),
            ClipboardImportRecord(kind: "rich_text", text: "rich sample", rtfBase64: rtf),
            ClipboardImportRecord(kind: "url", text: "Example", url: "https://example.com/path"),
            ClipboardImportRecord(kind: "file_url", fileURLs: ["file:///nonexistent/path.txt"]),
            ClipboardImportRecord(kind: "image", pngBase64: png.base64EncodedString())
        ])
        let inserted = try source.repository.executeManagement(.init(operation: "import", document: document))
        XCTAssertEqual(inserted.counts.inserted, 5)
        XCTAssertTrue(inserted.pinboards.contains { $0.name == "Empty Board" })
        let exported = try XCTUnwrap(source.repository.executeManagement(.init(operation: "export", all: true)).document)
        XCTAssertEqual(exported.records.count, 5)
        let imported = try target.repository.executeManagement(.init(operation: "import", document: exported))
        XCTAssertEqual(imported.counts.inserted, 5)
        XCTAssertTrue(imported.pinboards.contains { $0.name == "Empty Board" })
        let reexported = try XCTUnwrap(target.repository.executeManagement(.init(operation: "export", all: true)).document)
        for kind in ["text", "rich_text", "url", "file_url", "image"] {
            let a = try XCTUnwrap(exported.records.first { $0.kind == kind })
            let b = try XCTUnwrap(reexported.records.first { $0.kind == kind })
            XCTAssertEqual(a.text, b.text); XCTAssertEqual(a.url, b.url)
            XCTAssertEqual(a.rtfBase64, b.rtfBase64); XCTAssertEqual(a.pngBase64, b.pngBase64)
            XCTAssertEqual(a.fileURLs, b.fileURLs); XCTAssertEqual(a.title, b.title)
            XCTAssertEqual(a.createdAt, b.createdAt); XCTAssertEqual(a.lastCopiedAt, b.lastCopiedAt)
            XCTAssertEqual(a.isFavorite, b.isFavorite); XCTAssertEqual(a.tags, b.tags)
        }
    }

    func testDryRunDoesNotWriteDatabaseOrSidecars() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = try fixture.database.connection.firstInt("SELECT total_changes()")
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.database.environment.blobDirectory.path)
        let result = try fixture.repository.executeManagement(.init(operation: "import", document: .init(pinboards: ["New"], records: [
            .init(kind: "image", pngBase64: try makePNG().base64EncodedString(), pinboard: "New", tags: ["tag"])
        ]), dryRun: true))
        XCTAssertEqual(result.counts.inserted, 1)
        XCTAssertEqual(try fixture.database.connection.firstInt("SELECT total_changes()"), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.database.environment.blobDirectory.path), files)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).count, 0)
    }

    func testDuplicatesMergeTagsWithoutReplacingPayloadTitleOrIdentity() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let first = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
            .init(kind: "text", text: "duplicate", tags: ["old"], title: "Original")
        ])))
        let id = try XCTUnwrap(first.records.first?.id)
        let before = try fixture.repository.loadSearchDocument(recordID: id)
        let result = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
            .init(kind: "text", text: "duplicate", pinboard: "Workbox", tags: ["new"], title: "Do not replace"),
            .init(kind: "text", text: "duplicate", tags: ["another"])
        ])))
        XCTAssertEqual(result.counts.inserted, 0); XCTAssertEqual(result.counts.duplicates, 2)
        XCTAssertEqual(result.records.first?.id, id)
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: id)?.customTitle, "Original")
        XCTAssertEqual(try fixture.repository.readPayload(recordID: id)?.text, "duplicate")
        XCTAssertEqual(try fixture.repository.loadSearchDocument(recordID: id)?.ocrText, before?.ocrText)
        XCTAssertEqual(Set(result.records.first?.tags ?? []).subtracting(["Favorite", "收藏"]), Set(["old", "new", "another"]))
        XCTAssertEqual(try fixture.repository.search("another", limit: 10).map(\.id), [id])
    }

    func testConflictingBoardsAndMalformedBatchLeaveNoPartialRows() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [.init(kind: "text", text: "existing", pinboard: "A")])) )
        assertCode("pinboard_conflict") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "text", text: "new", pinboard: "New"), .init(kind: "text", text: "existing", pinboard: "B")
            ])))
        }
        assertCode("pinboard_conflict") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "text", text: "same", pinboard: "A"), .init(kind: "text", text: "same", pinboard: "B")
            ])))
        }
        assertCode("invalid_png") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "text", text: "new"), .init(kind: "image", pngBase64: Data("fake".utf8).base64EncodedString())
            ])))
        }
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 20).count, 1)
        XCTAssertFalse(try fixture.repository.loadPinboards().contains { $0.name == "New" })
    }

    func testDeletePreviewIsReadOnlyAndRejectsStaleToken() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let imported = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [.init(kind: "text", text: "delete me")])))
        let id = try XCTUnwrap(imported.records.first?.id)
        let preview = try fixture.repository.executeManagement(.init(operation: "delete", recordIDs: [id]))
        XCTAssertTrue(preview.dryRun)
        XCTAssertNotNil(try fixture.repository.loadRecord(recordID: id))
        _ = try fixture.repository.executeManagement(.init(operation: "tag_add", recordIDs: [id], tag: "changed"))
        assertCode("revision_conflict") {
            _ = try fixture.repository.executeManagement(.init(operation: "delete", recordIDs: [id], confirmationToken: preview.confirmationToken))
        }
        let newPreview = try fixture.repository.executeManagement(.init(operation: "delete", recordIDs: [id]))
        let deleted = try fixture.repository.executeManagement(.init(operation: "delete", recordIDs: [id], confirmationToken: newPreview.confirmationToken))
        XCTAssertEqual(deleted.mutatedRecordIDs, [id]); XCTAssertEqual(deleted.counts.deleted, 1)
        XCTAssertNil(try fixture.repository.loadRecord(recordID: id))
        XCTAssertTrue(try fixture.repository.search("changed", limit: 10).isEmpty)
    }

    func testDeleteConfirmationBindsResolvedDateSelectionAcrossMidnightAndTimeZoneChanges() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
            .init(kind: "text", text: "2025-01-01", createdAt: "2025-01-01T12:00:00Z"),
            .init(kind: "text", text: "2025-01-02", createdAt: "2025-01-02T12:00:00Z")
        ])))
        let formatter = ISO8601DateFormatter()
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let minusOneHour = try XCTUnwrap(TimeZone(secondsFromGMT: -3600))
        let scenarios: [(String, String, TimeZone, String, TimeZone)] = [
            ("today", "2025-01-01T23:59:59Z", utc, "2025-01-02T00:00:01Z", utc),
            ("yesterday", "2025-01-02T23:59:59Z", utc, "2025-01-03T00:00:01Z", utc),
            ("today", "2025-01-02T00:30:00Z", minusOneHour, "2025-01-02T00:30:00Z", utc)
        ]
        let changesBefore = try fixture.database.connection.firstInt("SELECT total_changes()")
        for (query, beforeValue, beforeZone, afterValue, afterZone) in scenarios {
            let before = try XCTUnwrap(formatter.date(from: beforeValue))
            let after = try XCTUnwrap(formatter.date(from: afterValue))
            let preview = try fixture.repository.executeManagement(.init(operation: "delete", query: query),
                selectionNow: before, selectionTimeZone: beforeZone)
            let changedSelection = try fixture.repository.executeManagement(.init(operation: "delete", query: query),
                selectionNow: after, selectionTimeZone: afterZone)
            XCTAssertEqual(preview.records.count, 1)
            XCTAssertEqual(changedSelection.records.count, 1)
            XCTAssertNotEqual(preview.records.map(\.id), changedSelection.records.map(\.id))
            XCTAssertNotEqual(preview.confirmationToken, changedSelection.confirmationToken)
            assertCode("revision_conflict") {
                _ = try fixture.repository.executeManagement(.init(operation: "delete", query: query,
                    confirmationToken: preview.confirmationToken), selectionNow: after, selectionTimeZone: afterZone)
            }
        }
        XCTAssertEqual(try fixture.database.connection.firstInt("SELECT total_changes()"), changesBefore)
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).count, 2)
    }

    func testExplicitExportSelectionPaginationAndFavoriteSync() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: (0..<4).map { .init(kind: "text", text: "item \($0)") })))
        assertCode("selection_required") { _ = try fixture.repository.executeManagement(.init(operation: "export")) }
        let page1 = try fixture.repository.executeManagement(.init(operation: "list", limit: 2))
        let page2 = try fixture.repository.executeManagement(.init(operation: "list", limit: 2, offset: 2))
        XCTAssertEqual(page1.records.count, 2); XCTAssertEqual(page2.records.count, 2)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: page1.records[0].createdAt))
        let metadataJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page1.records[0])) as? [String: Any])
        XCTAssertTrue(metadataJSON["created_at"] is String)
        XCTAssertTrue(Set(page1.records.map(\.id)).isDisjoint(with: page2.records.map(\.id)))
        let id = page1.records[0].id
        _ = try fixture.repository.executeManagement(.init(operation: "pin", recordIDs: [id], pinboardID: "pinboard.work"))
        _ = try fixture.repository.executeManagement(.init(operation: "pin", recordIDs: [id]))
        XCTAssertEqual(try fixture.repository.loadPinnedMetadata()[id]?.pinboardID, "pinboard.work")
        XCTAssertTrue(try fixture.repository.loadRecord(recordID: id)?.pinned == true)
        let doc = try XCTUnwrap(fixture.repository.executeManagement(.init(operation: "export", recordIDs: [id])).document)
        XCTAssertEqual(doc.records.first?.isFavorite, true)
        _ = try fixture.repository.executeManagement(.init(operation: "unpin", recordIDs: [id]))
        XCTAssertFalse(try fixture.repository.loadRecord(recordID: id)?.pinned == true)
        XCTAssertNil(try fixture.repository.loadPinnedMetadata()[id])
    }

    func testCancellationRollsBackAndUnsafeRTFAndMultipleFileURLsAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        XCTAssertThrowsError(try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [.init(kind: "text", text: "cancelled")])), isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        assertCode("invalid_rtf") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "rich_text", rtfBase64: Data("{\\rtf1{\\field malicious}}".utf8).base64EncodedString())
            ])))
        }
        // RTF control words terminate before numeric parameters; regex word
        // boundaries would incorrectly permit field1/bin3/pict0.
        for unsafe in [
            #"{\rtf1\ansi{\field1{\*\fldinst HYPERLINK "https://example.invalid/"}{\fldrslt link}}}"#,
            #"{\rtf1\ansi\bin3 abc}"#,
            #"{\rtf1\ansi{\pict0 00}}"#,
            #"{\rtf1\ansi{\object1 00}}"#,
            #"{\rtf1\ansi before\NeXTGraphic fixture.png after}"#,
            #"{\rtf1\ansi before\attachment1 fixture.png after}"#
        ] {
            assertCode("invalid_rtf") {
                _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                    .init(kind: "rich_text", rtfBase64: Data(unsafe.utf8).base64EncodedString())
                ])))
            }
        }
        assertCode("invalid_file_urls") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "file_url", fileURLs: ["file:///a", "file:///b"])
            ])))
        }
        XCTAssertTrue(try fixture.repository.loadRecent(limit: 10).isEmpty)
    }

    func testFailureAfterSidecarCreationRollsBackRowsFTSAndBlob() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try fixture.database.connection.execute("""
            CREATE TRIGGER fail_management_tag BEFORE INSERT ON clipboard_tags
            WHEN NEW.display_name = 'explode'
            BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;
            """)
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.database.environment.blobDirectory.path)
        assertCode("transaction_failed") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "image", pngBase64: try makePNG().base64EncodedString(), pinboard: "Rollback", tags: ["explode"])
            ])))
        }
        XCTAssertEqual(try fixture.database.connection.firstInt("SELECT COUNT(*) FROM clipboard_items"), 0)
        XCTAssertEqual(try fixture.database.connection.firstInt("SELECT COUNT(*) FROM clipboard_search_documents"), 0)
        XCTAssertFalse(try fixture.repository.loadPinboards().contains { $0.name == "Rollback" })
        let remainingFiles = try FileManager.default.subpathsOfDirectory(atPath: fixture.database.environment.blobDirectory.path)
            .filter { !$0.hasSuffix("/") && FileManager.default.fileExists(atPath: fixture.database.environment.blobDirectory.appendingPathComponent($0).path) }
        // BlobStore may leave an empty directory after removing a rolled-back blob.
        XCTAssertFalse(remainingFiles.contains { $0.hasSuffix(".png") })
        XCTAssertFalse(files.contains { $0.hasSuffix(".png") })
    }

    func testTagOnlyExportAndInvalidOperationFields() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
            .init(kind: "text", text: "included", tags: ["select-me"]), .init(kind: "text", text: "excluded")
        ])))
        let selected = try fixture.repository.executeManagement(.init(operation: "export", tag: "select-me"))
        XCTAssertEqual(selected.document?.records.map(\.text), ["included"])
        assertCode("invalid_operation_fields") { _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: []), all: true)) }
        assertCode("invalid_operation_fields") { _ = try fixture.repository.executeManagement(.init(operation: "tag_add", tag: "never-selects-all")) }
        for operation in ["export", "show", "delete", "pinboard_list"] {
            assertCode("invalid_operation_fields") {
                _ = try fixture.repository.executeManagement(.init(operation: operation, limit: 1))
            }
            assertCode("invalid_operation_fields") {
                _ = try fixture.repository.executeManagement(.init(operation: operation, offset: 1))
            }
        }
        for operation in ["list", "export", "delete"] {
            assertCode("invalid_operation_fields") {
                _ = try fixture.repository.executeManagement(.init(operation: operation, tag: "select-me", all: true))
            }
            assertCode("invalid_operation_fields") {
                _ = try fixture.repository.executeManagement(.init(operation: operation, query: "included", all: true))
            }
            assertCode("invalid_operation_fields") {
                _ = try fixture.repository.executeManagement(.init(operation: operation, recordIDs: ["any"], all: true))
            }
            assertCode("invalid_operation_fields") {
                _ = try fixture.repository.executeManagement(.init(operation: operation, pinboardID: "pinboard.work", all: true))
            }
        }
        XCTAssertThrowsError(try ClipboardImportDocument.decode(Data(#"{"schema_version":1,"records":[],"unrecognized":true}"#.utf8)))
    }

    func testScreenshotHistoryRoundTripKeepsOriginalIdentityOCRAndConflictCheck() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let png = try makePNG()
        let record = ClipboardRecorderRecord(id: "synthetic-screenshot", createdAt: Date(), changeCount: 0,
            kind: .image, formatSummary: .init(itemCount: 1, types: ["public.png"]), sourceApp: nil,
            signatureSHA256_12: "untrusted", fixtureOwned: true, restorable: true, customTitle: "Keep title", summary: "Synthetic")
        _ = try fixture.repository.commitScreenshotHistory(request: .init(record: record, pngData: png, ocrState: .notRequired))
        _ = try fixture.repository.executeManagement(.init(operation: "pin", recordIDs: [record.id], pinboardID: "pinboard.work"))
        let before = try fixture.repository.loadSearchDocument(recordID: record.id)
        let export = try XCTUnwrap(fixture.repository.executeManagement(.init(operation: "export", recordIDs: [record.id])).document)
        let imported = try fixture.repository.executeManagement(.init(operation: "import", document: export))
        XCTAssertEqual(imported.counts.inserted, 0); XCTAssertEqual(imported.counts.duplicates, 1)
        XCTAssertEqual(imported.records.map(\.id), [record.id])
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: record.id)?.origin, .screenshot)
        XCTAssertEqual(try fixture.repository.loadRecord(recordID: record.id)?.customTitle, "Keep title")
        XCTAssertEqual(try fixture.repository.loadSearchDocument(recordID: record.id)?.ocrState, before?.ocrState)
        assertCode("pinboard_conflict") {
            _ = try fixture.repository.executeManagement(.init(operation: "import", document: .init(records: [
                .init(kind: "image", pngBase64: png.base64EncodedString(), pinboard: "Conflict")
            ])))
        }
        XCTAssertEqual(try fixture.repository.loadRecent(limit: 10).count, 1)
    }

    func testExplicitNonFavoritePinboardRoundTripsWithoutRefavoriting() throws {
        let source = try Fixture(); defer { source.close() }
        let target = try Fixture(); defer { target.close() }
        let first = try source.repository.executeManagement(.init(operation: "import", document: .init(records: [
            .init(kind: "text", text: "grouped", pinboard: "A")
        ])))
        let id = try XCTUnwrap(first.records.first?.id)
        _ = try source.repository.executeManagement(.init(operation: "tag_remove", recordIDs: [id], tag: "favorite"))
        let exported = try XCTUnwrap(source.repository.executeManagement(.init(operation: "export", all: true)).document)
        XCTAssertEqual(exported.records.first?.pinboard, "A")
        XCTAssertEqual(exported.records.first?.isFavorite, false)
        let serialized = try exported.encoded()
        XCTAssertNotEqual(serialized.last, 10)
        _ = try target.repository.executeManagement(.init(operation: "import", document: try .decode(serialized)))
        let reexported = try XCTUnwrap(target.repository.executeManagement(.init(operation: "export", all: true)).document)
        XCTAssertEqual(reexported.records.first?.pinboard, "A")
        XCTAssertEqual(reexported.records.first?.isFavorite, false)
    }

    private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ClipboardManagementError)?.code, code, file: file, line: line)
        }
    }
    private func makePNG() throws -> Data {
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private struct Fixture {
        let root: URL
        let database: AppDatabase
        let repository: ClipboardRepository
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardManagementTests.\(UUID().uuidString)")
            database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
            repository = ClipboardRepository(database: database, blobStore: BlobStore(directory: database.environment.blobDirectory, sidecarThresholdBytes: 32))
        }
        func close() { database.connection.close(); try? FileManager.default.removeItem(at: root) }
    }
}
