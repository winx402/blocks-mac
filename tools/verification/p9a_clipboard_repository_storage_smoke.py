#!/usr/bin/env python3
from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verification_sanitizer import sanitize_payload, sanitize_text

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"


SMOKE_SWIFT = r'''
import Darwin
import Foundation

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw SmokeFailure(description: message)
    }
}

func makeRecord(
    id: String,
    createdAt: Date,
    changeCount: Int,
    kind: ClipboardRecorderItemKind,
    signature: String,
    fullSignature: String? = nil,
    summary: String,
    sourceBundle: String? = "app.blocks.smoke",
    pinned: Bool = false,
    byteCount: Int? = nil,
    textLength: Int? = nil
) -> ClipboardRecorderRecord {
    ClipboardRecorderRecord(
        id: id,
        createdAt: createdAt,
        changeCount: changeCount,
        kind: kind,
        formatSummary: ClipboardRecorderFormatSummary(
            itemCount: 1,
            types: [kind.rawValue],
            textLength: textLength,
            byteCount: byteCount,
            fileCount: kind == .fileURL ? 1 : nil,
            urlCount: kind == .url ? 1 : nil
        ),
        sourceApp: ClipboardRecorderSourceApp(
            bundleIdentifier: sourceBundle,
            localizedName: sourceBundle.map { "Smoke \($0)" },
            sourceAppIsCandidate: true
        ),
        signatureSHA256: fullSignature ?? "full_\(signature)",
        signatureSHA256_12: signature,
        fixtureOwned: false,
        pinned: pinned,
        restorable: true,
        summary: summary
    )
}

func yyyyMMdd(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func deleteSearchDocumentFixture(recordID: String, database: AppDatabase) throws {
    try database.connection.withStatement(
        "DELETE FROM clipboard_search_documents WHERE record_id = ?",
        bindings: [.string(recordID)]
    ) { statement in
        _ = try statement.step()
    }
    try database.connection.withStatement(
        "UPDATE clipboard_items SET search_text = NULL WHERE id = ?",
        bindings: [.string(recordID)]
    ) { statement in
        _ = try statement.step()
    }
    if database.ftsEnabled {
        try database.connection.withStatement(
            "DELETE FROM clipboard_fts WHERE record_id = ?",
            bindings: [.string(recordID)]
        ) { statement in
            _ = try statement.step()
        }
    }
}

@main
struct ClipboardRepositorySmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure(description: "usage: smoke <temp-root>")
        }
        let tempRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let environment = StorageEnvironment(rootDirectory: tempRoot)
        try require(environment.databaseURL.lastPathComponent == "Blocks.sqlite", "database path should end with Blocks.sqlite")

        let overrideRoot = tempRoot.appendingPathComponent("env-override", isDirectory: true)
        setenv(StorageEnvironment.storageRootOverrideEnvironmentKey, overrideRoot.path, 1)
        let overrideDatabase = try AppDatabase.open()
        try require(overrideDatabase.environment.rootDirectory == overrideRoot.standardizedFileURL, "default database should honor BLOCKS_STORAGE_ROOT for isolated app verification")
        overrideDatabase.close()
        unsetenv(StorageEnvironment.storageRootOverrideEnvironmentKey)
        try require(FileManager.default.fileExists(atPath: overrideRoot.appendingPathComponent("Blocks.sqlite").path), "storage root override should create database under the override root")

        let legacySkippedRoot = tempRoot.appendingPathComponent("legacy-skipped-v7", isDirectory: true)
        let legacySkippedEnvironment = StorageEnvironment(rootDirectory: legacySkippedRoot)
        let legacySkippedDatabase = try AppDatabase.open(environment: legacySkippedEnvironment)
        let legacySkippedRepository = ClipboardRepository(database: legacySkippedDatabase)
        let legacyCases: [(String, String, ClipboardCaptureSkipReason, Bool)] = [
            ("legacy_paused", "Clipboard capture skipped: recorder paused.", .paused, false),
            ("legacy_excluded", "Clipboard capture skipped: excluded source.", .excludedSource, true),
            ("legacy_unsupported", "Clipboard capture skipped: unsupported content.", .unsupportedContent, false),
        ]
        for (index, legacyCase) in legacyCases.enumerated() {
            let record = makeRecord(
                id: legacyCase.0,
                createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                changeCount: 7_000 + index,
                kind: .text,
                signature: "legacy_\(index)",
                fullSignature: String(repeating: String(index + 1), count: 64),
                summary: "legacy payload \(index)",
                textLength: 16
            )
            _ = try legacySkippedRepository.insert(
                record: record,
                payload: ClipboardRecorderPayload(recordID: record.id, kind: .text, text: "legacy payload \(index)")
            )
            try legacySkippedDatabase.connection.withStatement(
                "UPDATE clipboard_items SET restorable = 0, excluded = ?, snapshot_skipped = 1, summary = ? WHERE id = ?",
                bindings: [.bool(legacyCase.3), .string(legacyCase.1), .string(legacyCase.0)]
            ) { statement in
                _ = try statement.step()
            }
        }
        try legacySkippedDatabase.connection.execute("PRAGMA user_version = 7")
        legacySkippedDatabase.close()

        let migratedSkippedDatabase = try AppDatabase.open(environment: legacySkippedEnvironment)
        try require(try migratedSkippedDatabase.userVersion() == 11, "legacy skipped database should migrate to schema v11")
        let migratedSkippedRepository = ClipboardRepository(database: migratedSkippedDatabase)
        for legacyCase in legacyCases {
            let migratedRecord = try migratedSkippedRepository.loadRecord(recordID: legacyCase.0)
            try require(migratedRecord?.summary == legacyCase.2.summaryCode, "legacy skipped summary should migrate to stable reason code")
            try require(migratedRecord?.kind == .unknown, "legacy skipped kind should be redacted")
            try require(migratedRecord?.formatSummary.types.isEmpty == true, "legacy skipped format types should be redacted")
            try require(try migratedSkippedRepository.readPayload(recordID: legacyCase.0) == nil, "legacy skipped payload should be deleted")
            let migratedSearch = try migratedSkippedRepository.loadSearchDocument(recordID: legacyCase.0)
            try require(migratedSearch?.payloadDerivationState == .redacted, "legacy skipped search document should be redacted")
            try require(migratedSearch?.preview.body == legacyCase.2.summaryCode, "legacy skipped detail reason should use stable code")
        }
        migratedSkippedDatabase.close()

        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }

        try require(try database.userVersion() == 11, "schema user_version should be 11")
        for table in [
            "clipboard_items",
            "clipboard_payloads",
            "clipboard_pinboards",
            "clipboard_pinned_metadata",
            "clipboard_search_documents",
            "clipboard_tags",
            "clipboard_record_tags"
        ] {
            try require(try database.tableExists(table), "missing table \(table)")
        }
        let signatureColumnCount = try database.connection.firstInt(
            "SELECT COUNT(*) FROM pragma_table_info('clipboard_items') WHERE name = 'signature_sha256'"
        ) ?? 0
        try require(signatureColumnCount == 1, "clipboard_items should include full signature_sha256")
        let contentRevisionColumnCount = try database.connection.firstInt(
            "SELECT COUNT(*) FROM pragma_table_info('clipboard_items') WHERE name = 'content_revision'"
        ) ?? 0
        try require(contentRevisionColumnCount == 1, "clipboard_items should include content_revision")
        let lastCopiedColumnCount = try database.connection.firstInt(
            "SELECT COUNT(*) FROM pragma_table_info('clipboard_items') WHERE name = 'last_copied_at'"
        ) ?? 0
        try require(lastCopiedColumnCount == 1, "clipboard_items should include last_copied_at")
        let customTitleColumnCount = try database.connection.firstInt(
            "SELECT COUNT(*) FROM pragma_table_info('clipboard_items') WHERE name = 'custom_title'"
        ) ?? 0
        try require(customTitleColumnCount == 1, "clipboard_items should include record-level custom_title")
        let ocrSourceColumnCount = try database.connection.firstInt(
            "SELECT COUNT(*) FROM pragma_table_info('clipboard_search_documents') WHERE name = 'ocr_text_source'"
        ) ?? 0
        try require(ocrSourceColumnCount == 1, "clipboard_search_documents should include ocr_text_source")
        try require(try database.pragmaValue("foreign_keys") == "1", "foreign_keys pragma should be ON")
        try require(try database.pragmaValue("busy_timeout") == "5000", "busy_timeout pragma should be 5000")
        try require(try database.pragmaValue("journal_mode").lowercased() == "wal", "journal_mode should be WAL")
        try require(try database.pragmaValue("synchronous") == "1", "synchronous should be NORMAL")

        let repository = ClipboardRepository(database: database)
        try database.connection.withStatement(
            """
            INSERT INTO privacy_policy_rules (
                subject_ref, subject_type, identifier, display_name, policy,
                path_hash, path_summary, source_directory, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .string("malformed:fixture"), .string("not-a-valid-type"), .string("fixture"),
                .null, .string(PrivacyPolicyStatus.restricted.rawValue), .null, .null, .null,
                .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970)
            ]
        ) { statement in
            _ = try statement.step()
        }
        do {
            _ = try PrivacyPolicyRepository(database: database).snapshot()
            throw SmokeFailure(description: "malformed privacy rule must fail closed")
        } catch PrivacyPolicyRepositoryError.malformedRule {
        }
        try database.connection.withStatement(
            "DELETE FROM privacy_policy_rules WHERE subject_ref = ?",
            bindings: [.string("malformed:fixture")]
        ) { statement in
            _ = try statement.step()
        }
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        let textRecord = makeRecord(
            id: "clip_text",
            createdAt: baseDate,
            changeCount: 1,
            kind: .text,
            signature: "sig_text_001",
            summary: "Alpha beta gamma",
            textLength: "Alpha beta gamma".count
        )
        let textPayload = ClipboardRecorderPayload(recordID: textRecord.id, kind: .text, text: "Alpha beta gamma")
        let insertedText = try repository.insert(record: textRecord, payload: textPayload)
        try require(insertedText.inserted && !insertedText.duplicate && !insertedText.skipped, "text insert should insert")
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            _ = try! repository.loadRecent(limit: 20)
            try! repository.markCopied(recordID: textRecord.id)
        }

        let duplicateRecord = makeRecord(
            id: "clip_text_duplicate",
            createdAt: baseDate.addingTimeInterval(5),
            changeCount: 2,
            kind: .text,
            signature: "different_short",
            fullSignature: textRecord.signatureSHA256,
            summary: "Alpha beta gamma",
            textLength: "Alpha beta gamma".count
        )
        let duplicateResult = try repository.insert(
            record: duplicateRecord,
            payload: ClipboardRecorderPayload(recordID: duplicateRecord.id, kind: .text, text: "Alpha beta gamma")
        )
        try require(duplicateResult.duplicate && !duplicateResult.inserted, "matching signature should dedupe")
        try require(try repository.loadRecent(limit: 10).count == 1, "dedupe should leave one item")
        let duplicateLastCopied = try database.connection.withStatement(
            "SELECT last_copied_at FROM clipboard_items WHERE id = ?",
            bindings: [.string(textRecord.id)]
        ) { statement in
            try statement.step() ? statement.columnDouble(0) : 0
        }
        try require(
            abs(duplicateLastCopied - duplicateRecord.createdAt.timeIntervalSince1970) < 0.001,
            "dedupe should update last_copied_at to the repeated copy time"
        )
        let signatureRows = try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_items WHERE signature_sha256 = ?",
            bindings: [.string(textRecord.signatureSHA256)]
        ) ?? 0
        try require(signatureRows == 1, "full signature should be stored uniquely")

        let loadedPayload = try repository.readPayload(recordID: textRecord.id)
        try require(loadedPayload?.text == "Alpha beta gamma", "text payload should round trip")
        try repository.updateCustomTitle(recordID: textRecord.id, title: "Pinned research note")
        try require(try repository.loadRecord(recordID: textRecord.id)?.customTitle == "Pinned research note", "record-level custom title should persist")
        try repository.updateCustomTitle(recordID: textRecord.id, title: "   ")
        try require(try repository.loadRecord(recordID: textRecord.id)?.customTitle == nil, "blank custom title should clear record-level title")
        try require(try repository.search("beta", limit: 10).map(\.id) == [textRecord.id], "search should find text")
        let textDocument = try repository.loadSearchDocument(recordID: textRecord.id)
        try require(textDocument?.preview.title == "Text", "text search document title should use content type")
        try require(textDocument?.preview.body.contains("beta") == true, "text preview snapshot should include bounded body")
        try require(textDocument?.ftsProjectionText.contains("gamma") == true, "text FTS projection should include payload text")
        let textCompatibilitySearch = try database.connection.firstString(
            "SELECT search_text FROM clipboard_items WHERE id = ?",
            bindings: [.string(textRecord.id)]
        )
        try require(textCompatibilitySearch == textDocument?.ftsProjectionText, "legacy search_text should mirror search document projection")
        try require(try repository.loadPreviewSnapshot(recordID: textRecord.id)?.body.contains("beta") == true, "preview snapshot should load without payload")

        let documentRowsAfterDedupe = try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_search_documents WHERE record_id = ?",
            bindings: [.string(textRecord.id)]
        ) ?? 0
        try require(documentRowsAfterDedupe == 1, "dedupe should leave one search document")

        let urlRecord = makeRecord(
            id: "clip_url",
            createdAt: baseDate.addingTimeInterval(6),
            changeCount: 7,
            kind: .url,
            signature: "sig_url_001",
            summary: "https://example.com/blocks/clipboard-step1",
            textLength: "https://example.com/blocks/clipboard-step1".count
        )
        try repository.insert(
            record: urlRecord,
            payload: ClipboardRecorderPayload(
                recordID: urlRecord.id,
                kind: .url,
                text: "https://example.com/blocks/clipboard-step1",
                urlString: "https://example.com/blocks/clipboard-step1?token=fixture"
            )
        )
        let urlDocument = try repository.loadSearchDocument(recordID: urlRecord.id)
        try require(urlDocument?.preview.title == "Link", "URL preview title should use content type")
        try require(urlDocument?.preview.body == "example.com/blocks/clipboard-step1", "URL preview body should include host and bounded path without query")
        try require(try repository.search("clipboard-step1", limit: 10).contains { $0.id == urlRecord.id }, "URL search should use search document tokens")

        let repeatTextAfterURL = makeRecord(
            id: "clip_text_duplicate_after_url",
            createdAt: baseDate.addingTimeInterval(20),
            changeCount: 21,
            kind: .text,
            signature: "different_short_after_url",
            fullSignature: textRecord.signatureSHA256,
            summary: "Alpha beta gamma",
            textLength: "Alpha beta gamma".count
        )
        let repeatTextAfterURLResult = try repository.insert(
            record: repeatTextAfterURL,
            payload: ClipboardRecorderPayload(recordID: repeatTextAfterURL.id, kind: .text, text: "Alpha beta gamma")
        )
        try require(repeatTextAfterURLResult.duplicate && !repeatTextAfterURLResult.inserted, "repeated payload after newer item should still dedupe")
        let recentAfterRepeat = try repository.loadRecent(limit: 3).map(\.id)
        try require(recentAfterRepeat.first == textRecord.id, "repeated payload should move original record to recent first")
        try require(!recentAfterRepeat.contains(repeatTextAfterURL.id), "repeated payload should not insert a second history row")

        try repository.markCopied(recordID: urlRecord.id, at: baseDate.addingTimeInterval(30))
        try require(try repository.loadRecent(limit: 3).map(\.id).first == urlRecord.id, "markCopied should move copied history record to recent first")
        try repository.markCopied(recordID: textRecord.id, at: baseDate.addingTimeInterval(40))
        try require(try repository.loadRecent(limit: 3).map(\.id).first == textRecord.id, "second markCopied should move older history record above newer created records")
        try require(
            abs((try repository.loadRecord(recordID: textRecord.id)?.lastCopiedAt.timeIntervalSince1970 ?? 0) - baseDate.addingTimeInterval(40).timeIntervalSince1970) < 0.001,
            "loadRecord should expose lastCopiedAt for UI display and in-memory policy"
        )
        try deleteSearchDocumentFixture(recordID: textRecord.id, database: database)
        try deleteSearchDocumentFixture(recordID: urlRecord.id, database: database)
        let pendingIndexByRecent = try repository.loadPendingIndexBatch(limit: 2)
        try require(pendingIndexByRecent.first == textRecord.id, "pending search indexing should prefer recently copied records over newer created records")
        try require(try repository.rebuildSearchDocuments(limit: 2) == 2, "rebuildSearchDocuments should restore missing recent search documents")
        try database.connection.withStatement(
            "UPDATE clipboard_search_documents SET revision = ? WHERE record_id = ?",
            bindings: [.string("v1:legacy-time-token"), .string(textRecord.id)]
        ) { statement in
            _ = try statement.step()
        }
        if database.ftsEnabled {
            try database.connection.withStatement(
                "DELETE FROM clipboard_fts WHERE record_id = ?",
                bindings: [.string(urlRecord.id)]
            ) { statement in
                _ = try statement.step()
            }
        }
        let inconsistentIndexBatch = try repository.loadPendingIndexBatch(limit: 10)
        try require(inconsistentIndexBatch.contains(textRecord.id), "legacy search revision should be scheduled for one-time rebuild")
        try require(inconsistentIndexBatch.contains(urlRecord.id), "missing FTS projection should be scheduled for repair")
        try require(try repository.rebuildPendingSearchDocuments(limit: 10) >= 2, "pending index repair should rebuild inconsistent projections")
        try require(try repository.loadSearchDocument(recordID: textRecord.id)?.revision.hasPrefix("v2:") == true, "rebuilt search revision should use current algorithm version")

        let fileRecord = makeRecord(
            id: "clip_file",
            createdAt: baseDate.addingTimeInterval(7),
            changeCount: 8,
            kind: .fileURL,
            signature: "sig_file_001",
            summary: "Report-004.pdf",
            textLength: "Report-004.pdf".count
        )
        try repository.insert(
            record: fileRecord,
            payload: ClipboardRecorderPayload(
                recordID: fileRecord.id,
                kind: .fileURL,
                text: "file:///Users/example/Documents/Report-004.pdf",
                urlString: "file:///Users/example/Documents/Report-004.pdf"
            )
        )
        let fileDocument = try repository.loadSearchDocument(recordID: fileRecord.id)
        try require(fileDocument?.preview.title == "File", "file URL preview title should use content type")
        try require(fileDocument?.preview.body == "Report-004.pdf", "file URL preview body should use filename without full path")
        try require(try repository.search("Report-004", limit: 10).contains { $0.id == fileRecord.id }, "file URL search should use filename tokens")

        let richTextRecord = makeRecord(
            id: "clip_rich_text",
            createdAt: baseDate.addingTimeInterval(8),
            changeCount: 9,
            kind: .richText,
            signature: "sig_rich_001",
            summary: "Rich Plain 004",
            textLength: "Rich Plain 004".count
        )
        try repository.insert(
            record: richTextRecord,
            payload: ClipboardRecorderPayload(recordID: richTextRecord.id, kind: .richText, text: "Rich Plain 004")
        )
        let richTextDocument = try repository.loadSearchDocument(recordID: richTextRecord.id)
        try require(richTextDocument?.preview.title == "Rich text", "rich text preview title should use content type")
        try require(richTextDocument?.richTextPlainText?.contains("Rich Plain 004") == true, "rich text plain text should feed search document")
        try require(try repository.search("Plain 004", limit: 10).contains { $0.id == richTextRecord.id }, "rich text plain text should be searchable")
        try require(try repository.search("smoke", limit: 10).contains { $0.id == textRecord.id }, "source app token should be searchable")

        let todayRecord = makeRecord(
            id: "clip_today",
            createdAt: Date(),
            changeCount: 11,
            kind: .text,
            signature: "sig_today_001",
            summary: "Today search token fixture",
            textLength: "Today search token fixture".count
        )
        try repository.insert(
            record: todayRecord,
            payload: ClipboardRecorderPayload(recordID: todayRecord.id, kind: .text, text: "Today search token fixture")
        )
        try require(try repository.search("today", limit: 20).contains { $0.id == todayRecord.id }, "today token should be searchable")
        try require(try repository.search("今天", limit: 20).contains { $0.id == todayRecord.id }, "Chinese today token should be searchable")
        try require(try repository.search(yyyyMMdd(todayRecord.createdAt), limit: 20).contains { $0.id == todayRecord.id }, "YYYY-MM-DD token should be searchable")

        let yesterdayRecord = makeRecord(
            id: "clip_yesterday",
            createdAt: Date().addingTimeInterval(-86_400),
            changeCount: 12,
            kind: .text,
            signature: "sig_yesterday_001",
            summary: "Yesterday search token fixture",
            textLength: "Yesterday search token fixture".count
        )
        try repository.insert(
            record: yesterdayRecord,
            payload: ClipboardRecorderPayload(recordID: yesterdayRecord.id, kind: .text, text: "Yesterday search token fixture")
        )
        try require(try repository.search("yesterday", limit: 20).contains { $0.id == yesterdayRecord.id }, "yesterday token should be searchable")
        try require(try repository.search("昨天", limit: 20).contains { $0.id == yesterdayRecord.id }, "Chinese yesterday token should be searchable")

        let recopiedRecord = makeRecord(
            id: "clip_recopied_today",
            createdAt: Date().addingTimeInterval(-864_000),
            changeCount: 13,
            kind: .text,
            signature: "sig_recopied_001",
            summary: "Stable date projection fixture",
            textLength: "Stable date projection fixture".count
        )
        try repository.insert(
            record: recopiedRecord,
            payload: ClipboardRecorderPayload(recordID: recopiedRecord.id, kind: .text, text: "Stable date projection fixture")
        )
        try repository.markCopied(recordID: recopiedRecord.id, at: Date())
        try require(try repository.search("today", limit: 30).contains { $0.id == recopiedRecord.id }, "relative date query should use lastCopiedAt")

        let idleSet = try repository.searchDocuments(query: "", limit: 10)
        try require(idleSet.state == .idle, "empty query should produce idle search state")
        let alphaSet = try repository.searchDocuments(query: "Alpha", limit: 10)
        try require(alphaSet.state == .results && alphaSet.records.contains { $0.id == textRecord.id }, "matching query should produce results state")
        let emptySet = try repository.searchDocuments(query: "not-present-step1b", limit: 10)
        try require(emptySet.state == .empty, "missing query should produce empty state when no index work is pending")

        let tagRepository = ClipboardTagRepository(repository: repository)
        let favoriteTag = try tagRepository.ensureFavoriteTag()
        try require(favoriteTag.id == "tag.favorite", "favorite built-in tag should be seeded")
        let favoriteMutation = try tagRepository.toggleFavorite(recordID: textRecord.id)
        try require(favoriteMutation.affectedRecordIDs.contains(textRecord.id), "favorite mutation should affect record")
        let researchMutation = try tagRepository.createTagAndAttach(
            displayName: "Research",
            colorToken: "blue",
            recordID: textRecord.id
        )
        try require(researchMutation.affectedRecordIDs.contains(textRecord.id), "createTagAndAttach should affect record")
        let recordTags = try tagRepository.loadRecordTags(recordIDs: [textRecord.id])
        try require(recordTags[textRecord.id]?.contains { $0.id == favoriteTag.id } == true, "favorite RecordTag should persist")
        try require(recordTags[textRecord.id]?.contains { $0.displayName == "Research" } == true, "custom RecordTag should persist")
        try require((textPayload.text ?? "").contains("Research") == false, "body_excludes_tag_name fixture should keep tag search independent from payload body")
        let taggedDocument = try repository.loadSearchDocument(recordID: textRecord.id)
        try require(taggedDocument?.tagTokens.contains("research") == true, "tag token should enter search document")
        try require(try repository.search("Research", limit: 10).contains { $0.id == textRecord.id }, "tag name should be searchable through FTS projection")
        try deleteSearchDocumentFixture(recordID: textRecord.id, database: database)
        try require(try repository.loadSearchDocument(recordID: textRecord.id) == nil, "tag rebuild fixture should remove search document")
        try require(try repository.search("Research", limit: 10).isEmpty, "tag rebuild fixture should remove stale tag search hit before repair")
        try repository.markSearchDocumentTagsDirty(recordIDs: [textRecord.id])
        let repairedTagDocument = try repository.loadSearchDocument(recordID: textRecord.id)
        try require(repairedTagDocument?.tagTokens.contains("research") == true, "markSearchDocumentTagsDirty should rebuild missing document with tags")
        try require(try repository.search("Research", limit: 10).contains { $0.id == textRecord.id }, "tag search should recover after missing document repair")
        try deleteSearchDocumentFixture(recordID: textRecord.id, database: database)
        let rebuiltTagCount = try repository.rebuildSearchDocuments(limit: 20)
        try require(rebuiltTagCount >= 1, "rebuildSearchDocuments should rebuild missing tagged document")
        let rebuiltTagDocument = try repository.loadSearchDocument(recordID: textRecord.id)
        try require(rebuiltTagDocument?.tagTokens.contains("research") == true, "rebuildSearchDocuments should include current tags")
        try require(try repository.search("Research", limit: 10).contains { $0.id == textRecord.id }, "tag search should recover after rebuildSearchDocuments")

        let largeImageBytes = Data(repeating: 0x42, count: BlobStore.defaultSidecarThresholdBytes + 1)
        let imageRecord = makeRecord(
            id: "clip_large_image",
            createdAt: baseDate.addingTimeInterval(10),
            changeCount: 3,
            kind: .image,
            signature: "sig_image_001",
            summary: "Large image",
            byteCount: largeImageBytes.count
        )
        try repository.insert(
            record: imageRecord,
            payload: ClipboardRecorderPayload(
                recordID: imageRecord.id,
                kind: .image,
                pngDataBase64: largeImageBytes.base64EncodedString()
            )
        )
        try require(try repository.search("photo", limit: 20).contains { $0.id == imageRecord.id }, "image type synonym should be searchable")
        try require(try repository.search("图片", limit: 20).contains { $0.id == imageRecord.id }, "Chinese image type synonym should be searchable")
        let blobFilesAfterInsert = try FileManager.default.contentsOfDirectory(
            at: environment.blobDirectory,
            includingPropertiesForKeys: nil
        )
        try require(blobFilesAfterInsert.count == 1, "large image should use one sidecar")
        let imagePayload = try repository.readPayload(recordID: imageRecord.id)
        try require(
            Data(base64Encoded: imagePayload?.pngDataBase64 ?? "")?.count == largeImageBytes.count,
            "sidecar image payload should round trip"
        )
        guard let initialImageDocument = try repository.loadSearchDocument(recordID: imageRecord.id) else {
            throw SmokeFailure(description: "image search document should exist")
        }
        try require(initialImageDocument.preview.title == "Image", "image preview title should use content type")
        try require(initialImageDocument.preview.body == "Image content", "image preview body should not expose byte count as primary content")
        try require(initialImageDocument.ocrState == .pending, "image OCR should start pending")
        let ocrPendingSearch = try repository.searchDocuments(query: "VISION-004", limit: 20)
        try require(ocrPendingSearch.state == .emptyIndexing, "pending OCR with no text hit should report emptyIndexing")
        try require(ocrPendingSearch.indexActivity.pendingOCRCount >= 1, "pending OCR count should be reported")
        try require(
            try repository.updateOCRResult(
                recordID: imageRecord.id,
                revision: initialImageDocument.revision,
                text: nil,
                state: .running,
                errorCode: nil
            ),
            "OCR running state should update"
        )
        let runningImageDocument = try repository.loadSearchDocument(recordID: imageRecord.id)
        try require(runningImageDocument?.ocrState == .running, "image OCR should transition to running")
        try require(
            try repository.updateOCRResult(
                recordID: imageRecord.id,
                revision: initialImageDocument.revision,
                text: nil,
                state: .failed,
                errorCode: "vision_unreadable"
            ),
            "OCR failed state should update"
        )
        let failedImageDocument = try repository.loadSearchDocument(recordID: imageRecord.id)
        try require(failedImageDocument?.ocrState == .failed, "image OCR should transition to failed")
        try require(failedImageDocument?.ocrErrorCode == "vision_unreadable", "OCR failure should store low-sensitive error code")
        try require(
            try repository.updateOCRResult(
                recordID: imageRecord.id,
                revision: initialImageDocument.revision,
                text: nil,
                state: .pending,
                errorCode: nil
            ),
            "OCR retry should return image to pending"
        )
        let retryImageDocument = try repository.loadSearchDocument(recordID: imageRecord.id)
        try require(retryImageDocument?.ocrState == .pending, "OCR retry should be visible as pending")
        try require(
            try repository.updateOCRResult(
                recordID: imageRecord.id,
                revision: initialImageDocument.revision,
                text: "VISION-004",
                state: .succeeded,
                errorCode: nil
            ),
            "OCR succeeded state should update"
        )
        let completedImageDocument = try repository.loadSearchDocument(recordID: imageRecord.id)
        try require(completedImageDocument?.ocrState == .succeeded, "image OCR should transition to succeeded")
        let ocrSearch = try repository.searchDocuments(query: "VISION-004", limit: 20)
        try require(ocrSearch.state == .results && ocrSearch.records.contains { $0.id == imageRecord.id }, "OCR text should be searchable")
        guard let completedImageDocument else {
            throw SmokeFailure(description: "completed image document should load before manual OCR edit")
        }
        let manualOCRText = "USER-EDITED-OCR-004"
        _ = try repository.saveDetailEdit(command: ClipboardDetailEditCommand(
            recordID: imageRecord.id,
            expectedContentRevision: completedImageDocument.contentRevision,
            editableKind: .imageOCRText,
            draft: ClipboardDetailDraft(text: manualOCRText),
            updatesPayload: true,
            purpose: "detailEditSave"
        ))
        let manuallyEditedDocument = try repository.loadSearchDocument(recordID: imageRecord.id)
        try require(manuallyEditedDocument?.ocrText == manualOCRText, "manual OCR edit should persist before repair")
        try require(manuallyEditedDocument?.ocrTextSource == .userEdited, "manual OCR edit should be marked userEdited")
        try require(manuallyEditedDocument?.ocrLockedContentRevision != nil, "manual OCR edit should lock the edited content revision")
        try database.connection.withStatement(
            "UPDATE clipboard_search_documents SET revision = ? WHERE record_id = ?",
            bindings: [.string("v1:stale-user-ocr"), .string(imageRecord.id)]
        ) { statement in
            _ = try statement.step()
        }
        try require(try repository.rebuildPendingSearchDocuments(limit: 20) >= 1, "stale manual OCR document should be rebuilt")
        let repairedManualOCRDocument = try repository.loadSearchDocument(recordID: imageRecord.id)
        try require(repairedManualOCRDocument?.ocrText == manualOCRText, "index repair must preserve manual OCR text")
        try require(repairedManualOCRDocument?.ocrTextSource == .userEdited, "index repair must preserve manual OCR source")
        try require(
            repairedManualOCRDocument?.ocrLockedContentRevision == manuallyEditedDocument?.ocrLockedContentRevision,
            "index repair must preserve manual OCR revision lock"
        )
        try require(
            try repository.search(manualOCRText, limit: 10).contains { $0.id == imageRecord.id },
            "repaired manual OCR text should remain searchable"
        )
        do {
            _ = try BlobStore(directory: environment.blobDirectory).read(relativePath: "../Blocks.sqlite")
            throw SmokeFailure(description: "sidecar read should reject path traversal")
        } catch BlobStoreError.invalidRelativePath {
        }
        try repository.delete(recordID: imageRecord.id)
        try require(try repository.loadSearchDocument(recordID: imageRecord.id) == nil, "delete should remove image search document")
        let blobFilesAfterDelete = try FileManager.default.contentsOfDirectory(
            at: environment.blobDirectory,
            includingPropertiesForKeys: nil
        )
        try require(blobFilesAfterDelete.isEmpty, "delete should remove sidecar")
        try FileManager.default.createDirectory(at: environment.blobDirectory, withIntermediateDirectories: true)
        let orphanURL = environment.blobDirectory.appendingPathComponent("orphan-fixture.png")
        try Data([0x01, 0x02]).write(to: orphanURL)
        try repository.cleanupUnreferencedSidecars()
        try require(!FileManager.default.fileExists(atPath: orphanURL.path), "orphan sidecar cleanup should remove unreferenced files")

        let blockedSecret = "DO-NOT-PERSIST-SECRET-CONTENT"
        let blockedRecord = makeRecord(
            id: "clip_blocked",
            createdAt: baseDate.addingTimeInterval(20),
            changeCount: 4,
            kind: .text,
            signature: "sig_blocked_001",
            summary: blockedSecret,
            sourceBundle: "app.blocks.secret",
            textLength: blockedSecret.count
        )
        let blockedSnapshot = PrivacyPolicySnapshot(restrictedBundleIDs: ["app.blocks.secret"])
        let blockedPolicy = ClipboardCapturePolicy(privacySnapshot: blockedSnapshot)
        let blockedResult = try repository.insert(
            record: blockedRecord,
            payload: ClipboardRecorderPayload(recordID: blockedRecord.id, kind: .text, text: blockedSecret),
            capturePolicy: blockedPolicy
        )
        try require(blockedResult.skipped && !blockedResult.inserted, "excluded source should write skipped row")
        let blockedStored = try repository.loadRecent(limit: 10).first { $0.id == blockedRecord.id }
        try require(blockedStored?.snapshotSkipped == true, "skipped row should be marked snapshotSkipped")
        try require(blockedStored?.restorable == false, "skipped row should not be restorable")
        try require(try repository.readPayload(recordID: blockedRecord.id) == nil, "skipped row should not persist payload")
        let blockedDocument = try repository.loadSearchDocument(recordID: blockedRecord.id)
        try require(blockedDocument?.payloadDerivationState == .redacted, "skipped row should have redacted search document")
        try require(blockedDocument?.ftsProjectionText.isEmpty == true, "skipped row search projection should be empty")
        try require(try repository.search(blockedSecret, limit: 10).isEmpty, "skipped full content should not be searchable")

        let pendingRecord = makeRecord(
            id: "clip_pending_index",
            createdAt: baseDate.addingTimeInterval(22),
            changeCount: 13,
            kind: .text,
            signature: "sig_pending_001",
            summary: "Pending index fixture",
            textLength: "Pending index fixture".count
        )
        try repository.insert(
            record: pendingRecord,
            payload: ClipboardRecorderPayload(recordID: pendingRecord.id, kind: .text, text: "Pending index fixture")
        )
        try database.connection.withStatement(
            "UPDATE clipboard_search_documents SET payload_derivation_state = ? WHERE record_id = ?",
            bindings: [.string(ClipboardPayloadDerivationState.pendingIndex.rawValue), .string(pendingRecord.id)]
        ) { statement in
            _ = try statement.step()
        }
        let emptyIndexingSet = try repository.searchDocuments(query: "still-not-present-step1b", limit: 10)
        try require(emptyIndexingSet.state == .emptyIndexing, "pending index with no hits should produce emptyIndexing")
        let partialIndexingSet = try repository.searchDocuments(query: "Alpha", limit: 10)
        try require(partialIndexingSet.state == .partialIndexing, "pending index with hits should produce partialIndexing")

        let unfavoritedRecord = makeRecord(
            id: "clip_unfavorited",
            createdAt: baseDate.addingTimeInterval(30),
            changeCount: 5,
            kind: .text,
            signature: "sig_unfavorited_001",
            summary: "Temporary unfavorited",
            textLength: "Temporary unfavorited".count
        )
        try repository.insert(
            record: unfavoritedRecord,
            payload: ClipboardRecorderPayload(recordID: unfavoritedRecord.id, kind: .text, text: "Temporary unfavorited")
        )
        let beforeClearCount = try repository.loadRecent(limit: 1_000).count
        let clearResult = try repository.clearUnfavorited()
        let afterClear = try repository.loadRecent(limit: 1_000)
        try require(clearResult.deletedCount == beforeClearCount - afterClear.count, "clearUnfavorited must report the database deletion count")
        try require(clearResult.remainingCount == afterClear.count, "clearUnfavorited must report the database remaining count")
        try require(afterClear.contains { $0.id == textRecord.id }, "clearUnfavorited should keep favorite-tagged item")
        try require(!afterClear.contains { $0.id == unfavoritedRecord.id }, "clearUnfavorited should remove ordinary untagged item")
        try require(try repository.loadSearchDocument(recordID: unfavoritedRecord.id) == nil, "clearUnfavorited should remove ordinary search document")

        let oldRecord = makeRecord(
            id: "clip_old",
            createdAt: baseDate.addingTimeInterval(-10_000),
            changeCount: 6,
            kind: .text,
            signature: "sig_old_001",
            summary: "Old record",
            textLength: "Old record".count
        )
        try repository.insert(
            record: oldRecord,
            payload: ClipboardRecorderPayload(recordID: oldRecord.id, kind: .text, text: "Old record")
        )
        let oldButRecentlyCopiedRecord = makeRecord(
            id: "clip_old_recently_copied",
            createdAt: baseDate.addingTimeInterval(-9_000),
            changeCount: 14,
            kind: .text,
            signature: "sig_old_recent_001",
            summary: "Old but recently copied record",
            textLength: "Old but recently copied record".count
        )
        try repository.insert(
            record: oldButRecentlyCopiedRecord,
            payload: ClipboardRecorderPayload(recordID: oldButRecentlyCopiedRecord.id, kind: .text, text: "Old but recently copied record")
        )
        try repository.markCopied(recordID: oldButRecentlyCopiedRecord.id, at: baseDate.addingTimeInterval(119))
        let countOnlyPolicy = try repository.applyPolicy(
            ClipboardRepositoryPrunePolicy(
                retentionSeconds: nil,
                maxItems: 100,
                preserveFavorite: true,
                now: baseDate.addingTimeInterval(120)
            )
        )
        try require(countOnlyPolicy.deletedCount == 0, "count-only policy must not apply the inactive retention value")
        try require((try repository.loadRecent(limit: 100)).contains { $0.id == oldRecord.id }, "count-only policy should retain an old row while under the count limit")
        let pruned = try repository.applyPolicy(
            ClipboardRepositoryPrunePolicy(
                retentionSeconds: 60,
                maxItems: nil,
                preserveFavorite: true,
                now: baseDate.addingTimeInterval(120)
            )
        )
        try require(pruned.deletedCount >= 1, "policy prune should delete expired ordinary rows")
        try require((try repository.loadRecent(limit: 100)).count > 1, "time-only policy must not apply an inactive item limit")
        try require(!(try repository.loadRecent(limit: 20)).contains { $0.id == oldRecord.id }, "expired row should be gone")
        try require((try repository.loadRecent(limit: 20)).contains { $0.id == oldButRecentlyCopiedRecord.id }, "policy prune should retain old created records that were recently copied")
        try require(try repository.loadSearchDocument(recordID: oldRecord.id) == nil, "policy prune should remove expired search document")

        let report: [String: Any] = [
            "ok": true,
            "database_file": environment.databaseURL.lastPathComponent,
            "fts_enabled": database.ftsEnabled,
            "recent_count": try repository.loadRecent(limit: 50).count,
            "schema_version": try database.userVersion(),
            "search_document_count": try database.connection.firstInt("SELECT COUNT(*) FROM clipboard_search_documents") ?? 0,
            "verified_search_document_fixtures": ["text", "url", "file_url", "rich_text"],
            "verified_search_field_fixtures": ["content", "source_app", "url_host_path", "file_name_extension", "rich_plain_text", "type_synonym", "time_token"],
            "verified_search_state_fixtures": ["idle", "results", "empty", "emptyIndexing", "partialIndexing"],
            "verified_ocr_state_fixtures": ["pending", "running", "failed", "retry", "succeeded"],
            "verified_ocr_search_fixtures": ["ocr_text_search"],
            "verified_tag_fixtures": ["favorite_builtin", "record_tag", "tag_search", "tag_search_missing_document_repair", "tag_search_rebuild_path", "clear_unfavorited", "preserve_favorite_policy", "body_excludes_tag_name"],
            "verified_lifecycle_cleanup": true
        ]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
'''


def fail(message: str) -> int:
    print(sanitize_text(message), file=sys.stderr)
    return 1


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def main() -> int:
    core_sources = sorted(str(path) for path in CORE.glob("*.swift"))
    if not core_sources:
        return fail(f"no BlocksCore Swift files found under {CORE}")

    with tempfile.TemporaryDirectory(prefix="blocks_clipboard_repo_smoke_") as tmp:
        tmp_path = Path(tmp)
        smoke_source = tmp_path / "ClipboardRepositorySmoke.swift"
        executable = tmp_path / "ClipboardRepositorySmoke"
        storage_root = tmp_path / "storage"
        smoke_source.write_text(textwrap.dedent(SMOKE_SWIFT), encoding="utf-8")

        compile_command = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-O",
            "-g",
            "-lsqlite3",
            *core_sources,
            str(smoke_source),
            "-o",
            str(executable),
        ]
        compiled = run(compile_command, ROOT)
        if compiled.returncode != 0:
            print(sanitize_text(compiled.stdout))
            print(sanitize_text(compiled.stderr), file=sys.stderr)
            return compiled.returncode

        storage_root.mkdir(parents=True, exist_ok=True)
        executed = run([str(executable), str(storage_root)], ROOT)
        if executed.returncode != 0:
            print(sanitize_text(executed.stdout))
            print(sanitize_text(executed.stderr), file=sys.stderr)
            return executed.returncode

        try:
            report = json.loads(executed.stdout)
        except json.JSONDecodeError as exc:
            return fail(f"smoke output was not JSON: {exc}\n{executed.stdout}")

        database = storage_root / report["database_file"]
        if not database.exists():
            return fail("database not created under smoke storage root")

        connection = sqlite3.connect(database)
        try:
            tables = {
                row[0]
                for row in connection.execute(
                    "select name from sqlite_master where type in ('table', 'virtual table')"
                )
            }
            required_tables = {
                "clipboard_items",
                "clipboard_payloads",
                "clipboard_pinboards",
                "clipboard_pinned_metadata",
                "clipboard_search_documents",
                "clipboard_tags",
                "clipboard_record_tags",
            }
            missing = required_tables - tables
            if missing:
                return fail(f"missing sqlite tables after smoke: {sorted(missing)}")

            forbidden = "DO-NOT-PERSIST-SECRET-CONTENT"
            for table, columns in {
                "clipboard_items": "summary, coalesce(search_text, '')",
                "clipboard_payloads": "coalesce(text, ''), coalesce(url_string, '')",
                "clipboard_search_documents": "preview_title, preview_body, coalesce(content_text, ''), coalesce(ocr_text, ''), url_tokens_json, file_tokens_json",
            }.items():
                for row in connection.execute(f"select {columns} from {table}"):
                    if any(forbidden in str(value) for value in row):
                        return fail(f"redacted skipped content leaked into {table}")
        finally:
            connection.close()

        report["storage_root"] = "<TMP>"
        print(json.dumps(sanitize_payload(report), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
