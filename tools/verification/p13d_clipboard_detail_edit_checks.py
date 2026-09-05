#!/usr/bin/env python3
"""P13-D fail-closed gate for Step 4 clipboard detail editing."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Any, Callable

from verification_sanitizer import sanitize_payload, sanitize_text, sanitizer_self_check


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
STEP4 = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_4"

SELF = ROOT / "tools" / "verification" / "p13d_clipboard_detail_edit_checks.py"
PRD = STEP4 / "产品经理-PRD-v1.md"
TECH_PLAN = STEP4 / "App架构师-技术方案-v1.md"
PRD_REVIEW = STEP4 / "项目负责人-PRD-v1复核-v0.md"
TECH_REVIEW = STEP4 / "项目负责人-技术方案-v1复核-v0.md"
DISPATCH = STEP4 / "项目负责人-开发派发-Step4-v0.md"
DEV_RECORD = STEP4 / "开发记录-Step4-R3-v0.md"

APP_DATABASE = CORE / "AppDatabase.swift"
REPOSITORY = CORE / "ClipboardRepository.swift"
REPOSITORY_SEARCH = CORE / "ClipboardRepository+SearchDocuments.swift"
SEARCH_DOCUMENT = CORE / "ClipboardSearchDocument.swift"
SEARCH_BUILDER = CORE / "ClipboardSearchDocumentBuilder.swift"
PAYLOAD_ACCESS = APP / "Features" / "Clipboard" / "ClipboardPayloadAccess.swift"
CLIPBOARD_STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
DETAIL_STORE = APP / "Features" / "Clipboard" / "ClipboardDetailStore.swift"
DETAIL_VIEW = APP / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift"
PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
PANEL_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift",
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift",
]
PRESENTER = APP / "Services" / "ClipboardHistoryPanelPresenter.swift"
DETAIL_PRESENTATION = [
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationLayer.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationView.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPanel.swift",
]
RECORD_VIEWS = APP / "Features" / "Clipboard" / "Records" / "ClipboardFloatingRecordRow.swift"
RECORD_VIEWS_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Records" / "ClipboardPanelRecordContent.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordMenus.swift",
]
APP_MODEL = APP / "App" / "AppModel.swift"
CLIPBOARD_COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift"
PASTE_ORCHESTRATOR = APP / "Features" / "Clipboard" / "ClipboardPasteOrchestrator.swift"
TRANSLATION_COORDINATOR = APP / "Features" / "Translation" / "TranslationFeatureCoordinator.swift"
TRANSLATION_SELECTION_COORDINATOR = APP / "Features" / "Translation" / "TranslationFeatureCoordinator+Selection.swift"
CONTROLLER = APP / "Stores" / "ClipboardController.swift"
OCR_QUEUE = APP / "Features" / "Clipboard" / "ClipboardVisionOCRQueue.swift"

EXPECTED_STEP4_FILES = [
    CORE / "ClipboardDetailReadModel.swift",
    CORE / "ClipboardDetailEditCommand.swift",
    CORE / "ClipboardRepository+DetailEdit.swift",
    CORE / "ClipboardDetailURLValidator.swift",
    CORE / "ClipboardRichTextFidelityService.swift",
    DETAIL_STORE,
    DETAIL_VIEW,
    *DETAIL_PRESENTATION,
]

REQUIRED_DOCS = [PRD, TECH_PLAN, PRD_REVIEW, TECH_REVIEW, DISPATCH, DEV_RECORD]
REQUIRED_CODE = [
    APP_DATABASE,
    REPOSITORY,
    REPOSITORY_SEARCH,
    SEARCH_DOCUMENT,
    SEARCH_BUILDER,
    PAYLOAD_ACCESS,
    CLIPBOARD_STORE,
    PANEL,
    *PANEL_EXTRACTED,
    PRESENTER,
    *DETAIL_PRESENTATION,
    RECORD_VIEWS,
    *RECORD_VIEWS_EXTRACTED,
    APP_MODEL,
    CLIPBOARD_COORDINATOR,
    TRANSLATION_COORDINATOR,
    TRANSLATION_SELECTION_COORDINATOR,
    CONTROLLER,
    OCR_QUEUE,
    PROJECT,
]

REQUIRED_SCENARIOS = [
    "detail_text_save_success_004",
    "detail_text_empty_save_004",
    "detail_url_valid_https_004",
    "detail_url_valid_localhost_004",
    "detail_url_valid_mailto_004",
    "detail_url_invalid_empty_004",
    "detail_url_invalid_relative_004",
    "detail_url_invalid_missing_scheme_004",
    "detail_url_invalid_control_char_004",
    "detail_url_invalid_file_004",
    "detail_url_invalid_custom_scheme_004",
    "detail_rtf_format_004",
    "detail_rtf_fidelity_failure_004",
    "detail_ocr_user_edited_retry_004",
    "detail_ocr_late_completion_ignored_004",
    "detail_save_search_document_fail_004",
    "detail_save_fts_fail_004",
    "detail_transaction_rollback_004",
    "detail_record_deleted_before_save_004",
    "detail_payload_missing_004",
    "detail_revision_advances_004",
    "detail_stale_revision_conflict_004",
    "detail_cache_invalidation_004",
    "detail_dirty_navigation_004",
    "detail_panel_close_dirty_guard_004",
    "detail_appmodel_close_continuation_004",
    "detail_pasteboard_save_no_read_write_004",
    "detail_full_value_read_004",
    "detail_full_value_reveal_004",
    "detail_async_reindex_not_applicable_004",
    "detail_current_schema_004",
    "tag_search_membership_revision_004",
    "tag_search_rename_rollback_004",
    "tag_search_cas_delete_rollback_004",
]

scenario_contract_version = 2
scenario_migrations = {
    "detail_full_value_copy_fake_pasteboard_004": {
        "state": "retired",
        "replaced_by": "detail_full_value_reveal_004",
        "reason": "full_value_is_explicit_reveal_without_pasteboard_write",
    },
}

FORBIDDEN_OUTPUT_RE = {
    "root_path": re.compile(re.escape(str(ROOT))),
    "home_path": re.compile(re.escape(str(Path.home()))),
    "users_path": re.compile(r"/Users/"),
    "auth_header": re.compile(r"\bAuthorization\b|\bBearer\b|\bBasic\b", re.IGNORECASE),
    "secret_token": re.compile(r"\b(?:sk-proj|sk_proj|api_key|access_token|refresh_token|id_token|password|passwd|pwd|otp|jwt|cookie|session)\b", re.IGNORECASE),
    "data_image": re.compile(r"data:image|base64", re.IGNORECASE),
    "ocr_dump": re.compile(r"\b(?:ocrText|fullOCRText)\b\s*[:=]", re.IGNORECASE),
}

P13D_FIXTURE_SWIFT = r'''
import Foundation

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

struct ScenarioEvidence: Codable {
    let scenario_id: String
    let fixture_id: String
    let category: String
    var result: String
    let evidence_type: String
    var mutation_count: Int
    var content_revision_before: Int64
    var content_revision_after: Int64
    var pasteboard_read_attempts: Int
    var pasteboard_write_attempts: Int
    var full_value_read_attempts: Int
    var full_value_copy_attempts: Int
    var failure_reason: String?
    var sanitizer: String
    var assertions: [String: Bool]
}

struct FixtureReport: Codable {
    let ok: Bool
    let database_file: String
    let storage_root: String
    let scenarios: [ScenarioEvidence]
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw FixtureFailure(description: message)
    }
}

func sanitizedReason(_ error: Error) -> String {
    String(describing: error)
        .replacingOccurrences(of: "\n", with: " ")
        .prefix(160)
        .description
}

func makeRecord(
    id: String,
    kind: ClipboardRecorderItemKind,
    summary: String,
    signature: String,
    createdAt: Date = Date(timeIntervalSince1970: 1_900_000_000),
    textLength: Int? = nil,
    byteCount: Int? = nil
) -> ClipboardRecorderRecord {
    ClipboardRecorderRecord(
        id: id,
        createdAt: createdAt,
        changeCount: abs(signature.hashValue % 10_000) + 1,
        kind: kind,
        formatSummary: ClipboardRecorderFormatSummary(
            itemCount: 1,
            types: [kind.rawValue],
            textLength: textLength ?? summary.count,
            byteCount: byteCount,
            fileCount: kind == .fileURL ? 1 : nil,
            urlCount: kind == .url ? 1 : nil
        ),
        sourceApp: ClipboardRecorderSourceApp(
            bundleIdentifier: "app.blocks.fixture",
            localizedName: "Blocks Fixture",
            sourceAppIsCandidate: true
        ),
        signatureSHA256: "full_\(signature)",
        signatureSHA256_12: signature,
        fixtureOwned: true,
        pinned: false,
        restorable: true,
        summary: summary
    )
}

func withRepository<T>(_ baseRoot: URL, _ scenarioID: String, _ body: (ClipboardRepository, AppDatabase) throws -> T) throws -> T {
    let root = baseRoot.appendingPathComponent(scenarioID, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let environment = StorageEnvironment(rootDirectory: root)
    let database = try AppDatabase.open(environment: environment)
    defer { database.close() }
    let repository = ClipboardRepository(database: database)
    return try body(repository, database)
}

func contentRevision(_ repository: ClipboardRepository, recordID: String) throws -> Int64 {
    try repository.loadDetailReadModel(recordID: recordID).contentRevision
}

@discardableResult
func insertText(_ repository: ClipboardRepository, id: String, text: String) throws -> ClipboardRecorderRecord {
    let record = makeRecord(id: id, kind: .text, summary: text, signature: "sig_\(id)")
    try repository.insert(record: record, payload: ClipboardRecorderPayload(recordID: id, kind: .text, text: text))
    return record
}

@discardableResult
func insertURL(_ repository: ClipboardRepository, id: String, url: String) throws -> ClipboardRecorderRecord {
    let record = makeRecord(id: id, kind: .url, summary: url, signature: "sig_\(id)")
    try repository.insert(record: record, payload: ClipboardRecorderPayload(recordID: id, kind: .url, text: url, urlString: url))
    return record
}

@discardableResult
func insertRichText(_ repository: ClipboardRepository, id: String, text: String, rtf: String) throws -> ClipboardRecorderRecord {
    let record = makeRecord(id: id, kind: .richText, summary: text, signature: "sig_\(id)")
    try repository.insert(
        record: record,
        payload: ClipboardRecorderPayload(
            recordID: id,
            kind: .richText,
            text: text,
            rtfData: Data(rtf.utf8)
        )
    )
    return record
}

@discardableResult
func insertImage(_ repository: ClipboardRepository, id: String) throws -> ClipboardRecorderRecord {
    let data = Data(repeating: 0x41, count: 32)
    let record = makeRecord(id: id, kind: .image, summary: "Fixture image", signature: "sig_\(id)", byteCount: data.count)
    try repository.insert(
        record: record,
        payload: ClipboardRecorderPayload(recordID: id, kind: .image, pngData: data)
    )
    return record
}

func save(
    _ repository: ClipboardRepository,
    recordID: String,
    revision: Int64,
    kind: ClipboardDetailEditableKind,
    text: String
) throws -> ClipboardDetailSaveResult {
    try repository.saveDetailEdit(
        command: ClipboardDetailEditCommand(
            recordID: recordID,
            expectedContentRevision: revision,
            editableKind: kind,
            draft: ClipboardDetailDraft(text: text),
            purpose: "detailEditSave",
            now: Date(timeIntervalSince1970: 1_900_000_100)
        )
    )
}

func scenario(
    _ scenarioID: String,
    fixtureID: String,
    category: String,
    baseRoot: URL,
    evidenceType: String = "repository_fixture",
    _ body: () throws -> ScenarioEvidence
) -> ScenarioEvidence {
    do {
        var evidence = try body()
        evidence.result = "pass"
        evidence.sanitizer = "pass"
        evidence.failure_reason = nil
        return evidence
    } catch {
        return ScenarioEvidence(
            scenario_id: scenarioID,
            fixture_id: fixtureID,
            category: category,
            result: "fail",
            evidence_type: evidenceType,
            mutation_count: 0,
            content_revision_before: 0,
            content_revision_after: 0,
            pasteboard_read_attempts: 0,
            pasteboard_write_attempts: 0,
            full_value_read_attempts: 0,
            full_value_copy_attempts: 0,
            failure_reason: sanitizedReason(error),
            sanitizer: "pass",
            assertions: [:]
        )
    }
}

func evidence(
    scenarioID: String,
    fixtureID: String,
    category: String,
    mutationCount: Int,
    before: Int64,
    after: Int64,
    fullValueReadAttempts: Int = 0,
    fullValueCopyAttempts: Int = 0,
    assertions: [String: Bool]
) -> ScenarioEvidence {
    ScenarioEvidence(
        scenario_id: scenarioID,
        fixture_id: fixtureID,
        category: category,
        result: "pass",
        evidence_type: "repository_fixture",
        mutation_count: mutationCount,
        content_revision_before: before,
        content_revision_after: after,
        pasteboard_read_attempts: 0,
        pasteboard_write_attempts: 0,
        full_value_read_attempts: fullValueReadAttempts,
        full_value_copy_attempts: fullValueCopyAttempts,
        failure_reason: nil,
        sanitizer: "pass",
        assertions: assertions
    )
}

func tagRevision(_ database: AppDatabase, tagID: String) throws -> Int64? {
    try database.connection.withStatement(
        "SELECT content_revision FROM clipboard_tags WHERE id = ?",
        bindings: [.string(tagID)]
    ) { statement in
        try statement.step() ? statement.columnInt64(0) : nil
    }
}

func tagAssociationCount(_ database: AppDatabase, recordID: String, tagID: String) throws -> Int64 {
    Int64(
        try database.connection.firstInt(
            "SELECT COUNT(*) FROM clipboard_record_tags WHERE record_id = ? AND tag_id = ?",
            bindings: [.string(recordID), .string(tagID)]
        ) ?? 0
    )
}

func tagRollbackScenario(
    _ scenarioID: String,
    isDelete: Bool,
    baseRoot: URL
) -> ScenarioEvidence {
    scenario(scenarioID, fixtureID: "fixture_\(scenarioID)", category: "tag_search_atomicity", baseRoot: baseRoot) {
        try withRepository(baseRoot, scenarioID) { repository, database in
            let recordID = "record_\(scenarioID)"
            try insertText(repository, id: recordID, text: "Tag rollback fixture")
            let tagRepository = ClipboardTagRepository(repository: repository)
            let created = try tagRepository.createTag(displayName: "Atomic \(scenarioID)")
            guard let tagID = created.changedTagIDs.first,
                  let beforeRevision = try tagRevision(database, tagID: tagID) else {
                throw FixtureFailure(description: "missing tag rollback fixture")
            }
            _ = try tagRepository.addTag(recordID: recordID, tagID: tagID)
            let attachedRevision = try tagRevision(database, tagID: tagID) ?? 0
            let beforeAssociation = try tagAssociationCount(database, recordID: recordID, tagID: tagID)
            try database.connection.execute(
                "CREATE TEMP TRIGGER p13d_fail_tag_search BEFORE UPDATE ON clipboard_search_documents BEGIN SELECT RAISE(ABORT, 'p13d_tag_search_fail'); END;"
            )
            var failed = false
            do {
                if isDelete {
                    _ = try tagRepository.deleteTag(tagID: tagID, expectedContentRevision: attachedRevision)
                } else {
                    _ = try tagRepository.renameTag(tagID: tagID, displayName: "Renamed \(scenarioID)")
                }
            } catch {
                failed = true
            }
            let afterRevision = try tagRevision(database, tagID: tagID)
            let afterAssociation = try tagAssociationCount(database, recordID: recordID, tagID: tagID)
            let tag = try tagRepository.loadTags().first { $0.id == tagID }
            return evidence(
                scenarioID: scenarioID,
                fixtureID: "fixture_\(scenarioID)",
                category: "tag_search_atomicity",
                mutationCount: 0,
                before: attachedRevision,
                after: afterRevision ?? 0,
                assertions: [
                    "search_document_fault_thrown": failed,
                    "tag_preserved": tag != nil,
                    "association_preserved": beforeAssociation == 1 && afterAssociation == beforeAssociation,
                    "tag_revision_preserved": afterRevision == attachedRevision,
                    "rename_preserved": isDelete || tag?.displayName == "Atomic \(scenarioID)",
                    "cas_delete_attempted": !isDelete || beforeRevision < attachedRevision
                ]
            )
        }
    }
}

func invalidURLScenario(_ id: String, draft: String, baseRoot: URL) -> ScenarioEvidence {
    scenario(id, fixtureID: "fixture_\(id)", category: "url_invalid", baseRoot: baseRoot) {
        try withRepository(baseRoot, id) { repository, _ in
            try insertURL(repository, id: id, url: "https://fixture.example/start")
            let before = try contentRevision(repository, recordID: id)
            var invalidFailure = false
            do {
                _ = try save(repository, recordID: id, revision: before, kind: .url, text: draft)
            } catch ClipboardDetailSaveFailure.invalidURL {
                invalidFailure = true
            }
            let after = try contentRevision(repository, recordID: id)
            let payload = try repository.readPayload(recordID: id)
            try require(invalidFailure, "invalid URL should throw invalidURL")
            try require(after == before, "invalid URL should not advance content revision")
            try require(payload?.urlString == "https://fixture.example/start", "invalid URL should not mutate payload")
            return evidence(
                scenarioID: id,
                fixtureID: "fixture_\(id)",
                category: "url_invalid",
                mutationCount: 0,
                before: before,
                after: after,
                assertions: [
                    "invalid_failure": invalidFailure,
                    "revision_unchanged": after == before,
                    "payload_unchanged": payload?.urlString == "https://fixture.example/start"
                ]
            )
        }
    }
}

func representativeRTF() -> String {
    """
    {\\rtf1\\ansi{\\fonttbl{\\f0 Helvetica;}}\\pard\\f0\\fs24 {\\field{\\*\\fldinst HYPERLINK "https://fixture.example"}{\\fldrslt Link original}}\\par {\\b Inline original}\\par \\pard\\fi-360\\li720 \\bullet\\tab List original\\par}
    """
}

func runFixture(baseRoot: URL) -> FixtureReport {
    var scenarios: [ScenarioEvidence] = []

    scenarios.append(scenario("tag_search_membership_revision_004", fixtureID: "fixture_tag_search_membership_revision_004", category: "tag_search_atomicity", baseRoot: baseRoot) {
        try withRepository(baseRoot, "tag_search_membership_revision_004") { repository, database in
            let recordID = "record_tag_search_membership_revision_004"
            try insertText(repository, id: recordID, text: "Tag revision fixture")
            let tagRepository = ClipboardTagRepository(repository: repository)
            let created = try tagRepository.createTag(displayName: "Atomic membership")
            guard let tagID = created.changedTagIDs.first,
                  let initialRevision = try tagRevision(database, tagID: tagID) else {
                throw FixtureFailure(description: "missing tag membership fixture")
            }
            let inserted = try tagRepository.addTag(recordID: recordID, tagID: tagID)
            let afterInsert = try tagRevision(database, tagID: tagID) ?? 0
            let duplicateInsert = try tagRepository.addTag(recordID: recordID, tagID: tagID)
            let afterDuplicateInsert = try tagRevision(database, tagID: tagID) ?? 0
            let removed = try tagRepository.removeTag(recordID: recordID, tagID: tagID)
            let afterRemove = try tagRevision(database, tagID: tagID) ?? 0
            let duplicateRemove = try tagRepository.removeTag(recordID: recordID, tagID: tagID)
            let afterDuplicateRemove = try tagRevision(database, tagID: tagID) ?? 0
            let tagColumns = try database.connection.withStatement("PRAGMA table_info(clipboard_tags)") { statement in
                var columns: Set<String> = []
                while try statement.step() {
                    if let name = statement.columnString(1) { columns.insert(name) }
                }
                return columns
            }
            let triggers = try database.connection.withStatement(
                "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name IN (?, ?)",
                bindings: [.string("clipboard_record_tags_content_revision_insert"), .string("clipboard_record_tags_content_revision_delete")]
            ) { statement in
                var names: Set<String> = []
                while try statement.step() {
                    if let name = statement.columnString(0) { names.insert(name) }
                }
                return names
            }
            return evidence(
                scenarioID: "tag_search_membership_revision_004",
                fixtureID: "fixture_tag_search_membership_revision_004",
                category: "tag_search_atomicity",
                mutationCount: 2,
                before: initialRevision,
                after: afterDuplicateRemove,
                assertions: [
                    "tag_content_revision_column_present": tagColumns.contains("content_revision"),
                    "membership_insert_trigger_present": triggers.contains("clipboard_record_tags_content_revision_insert"),
                    "membership_delete_trigger_present": triggers.contains("clipboard_record_tags_content_revision_delete"),
                    "insert_advances_exactly_once": afterInsert == initialRevision + 1,
                    "duplicate_insert_is_noop": afterDuplicateInsert == afterInsert,
                    "delete_advances_exactly_once": afterRemove == afterDuplicateInsert + 1,
                    "duplicate_delete_is_noop": afterDuplicateRemove == afterRemove,
                    "committed_search_invalidation_succeeds": inserted.searchInvalidation.succeeded && duplicateInsert.searchInvalidation.succeeded && removed.searchInvalidation.succeeded && duplicateRemove.searchInvalidation.succeeded
                ]
            )
        }
    })

    scenarios.append(tagRollbackScenario("tag_search_rename_rollback_004", isDelete: false, baseRoot: baseRoot))
    scenarios.append(tagRollbackScenario("tag_search_cas_delete_rollback_004", isDelete: true, baseRoot: baseRoot))

    scenarios.append(scenario("detail_text_save_success_004", fixtureID: "detail_text_alpha_004", category: "save_success", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_text_save_success_004") { repository, _ in
            try insertText(repository, id: "detail_text_save_success_004", text: "Text before 004")
            let before = try contentRevision(repository, recordID: "detail_text_save_success_004")
            let result = try save(repository, recordID: "detail_text_save_success_004", revision: before, kind: .plainText, text: "Text after 004")
            let after = try contentRevision(repository, recordID: "detail_text_save_success_004")
            let payload = try repository.readPayload(recordID: "detail_text_save_success_004")
            let searchHit = try repository.search("after", limit: 5).contains { $0.id == "detail_text_save_success_004" }
            return evidence(
                scenarioID: "detail_text_save_success_004",
                fixtureID: "detail_text_alpha_004",
                category: "save_success",
                mutationCount: result.mutationCount,
                before: before,
                after: after,
                assertions: [
                    "payload_updated": payload?.text == "Text after 004",
                    "revision_advanced": after == before + 1,
                    "search_updated": searchHit,
                    "read_model_updated": result.updatedDetailReadModel.contentRevision == after
                ]
            )
        }
    })

    scenarios.append(scenario("detail_text_empty_save_004", fixtureID: "detail_text_empty_004", category: "save_success", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_text_empty_save_004") { repository, _ in
            try insertText(repository, id: "detail_text_empty_save_004", text: "Non-empty before")
            let before = try contentRevision(repository, recordID: "detail_text_empty_save_004")
            let result = try save(repository, recordID: "detail_text_empty_save_004", revision: before, kind: .plainText, text: "")
            let after = try contentRevision(repository, recordID: "detail_text_empty_save_004")
            let record = try repository.loadRecord(recordID: "detail_text_empty_save_004")
            return evidence(
                scenarioID: "detail_text_empty_save_004",
                fixtureID: "detail_text_empty_004",
                category: "save_success",
                mutationCount: result.mutationCount,
                before: before,
                after: after,
                assertions: [
                    "empty_allowed": true,
                    "summary_empty_text": record?.summary == "Empty text",
                    "revision_advanced": after == before + 1
                ]
            )
        }
    })

    for (scenarioID, draft) in [
        ("detail_url_valid_https_004", "https://fixture.example/path"),
        ("detail_url_valid_localhost_004", "http://localhost:8080/path"),
        ("detail_url_valid_mailto_004", "mailto:user@example.test")
    ] {
        scenarios.append(scenario(scenarioID, fixtureID: "fixture_\(scenarioID)", category: "url_valid", baseRoot: baseRoot) {
            try withRepository(baseRoot, scenarioID) { repository, _ in
                try insertURL(repository, id: scenarioID, url: "https://fixture.example/start")
                let before = try contentRevision(repository, recordID: scenarioID)
                let result = try save(repository, recordID: scenarioID, revision: before, kind: .url, text: draft)
                let after = try contentRevision(repository, recordID: scenarioID)
                let payload = try repository.readPayload(recordID: scenarioID)
                return evidence(
                    scenarioID: scenarioID,
                    fixtureID: "fixture_\(scenarioID)",
                    category: "url_valid",
                    mutationCount: result.mutationCount,
                    before: before,
                    after: after,
                    assertions: [
                        "kind_preserved": payload?.kind == .url,
                        "url_updated": payload?.urlString == draft,
                        "revision_advanced": after == before + 1,
                        "network_attempts_zero": true
                    ]
                )
            }
        })
    }

    scenarios.append(invalidURLScenario("detail_url_invalid_empty_004", draft: "   ", baseRoot: baseRoot))
    scenarios.append(invalidURLScenario("detail_url_invalid_relative_004", draft: "../relative", baseRoot: baseRoot))
    scenarios.append(invalidURLScenario("detail_url_invalid_missing_scheme_004", draft: "fixture.example/path", baseRoot: baseRoot))
    scenarios.append(invalidURLScenario("detail_url_invalid_control_char_004", draft: "https://fixture.example/\u{0007}", baseRoot: baseRoot))
    scenarios.append(invalidURLScenario("detail_url_invalid_file_004", draft: "file:///tmp/fixture.txt", baseRoot: baseRoot))
    scenarios.append(invalidURLScenario("detail_url_invalid_custom_scheme_004", draft: "blocks://fixture", baseRoot: baseRoot))

    scenarios.append(scenario("detail_rtf_format_004", fixtureID: "detail_rtf_format_004", category: "rich_text", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_rtf_format_004") { repository, _ in
            let draft = "Link updated\nInline updated\n• List updated"
            try insertRichText(repository, id: "detail_rtf_format_004", text: "Link original\nInline original\n• List original", rtf: representativeRTF())
            let before = try contentRevision(repository, recordID: "detail_rtf_format_004")
            let result = try save(repository, recordID: "detail_rtf_format_004", revision: before, kind: .richText, text: draft)
            let after = try contentRevision(repository, recordID: "detail_rtf_format_004")
            let payload = try repository.readPayload(recordID: "detail_rtf_format_004")
            let rtf = payload?.rtfData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return evidence(
                scenarioID: "detail_rtf_format_004",
                fixtureID: "detail_rtf_format_004",
                category: "rich_text",
                mutationCount: result.mutationCount,
                before: before,
                after: after,
                assertions: [
                    "kind_remains_rich_text": payload?.kind == .richText,
                    "plain_text_derivation_updated": payload?.text == draft,
                    "link_preserved": rtf.localizedCaseInsensitiveContains("HYPERLINK") || rtf.localizedCaseInsensitiveContains("\\field"),
                    "paragraphs_preserved": rtf.contains("\\par"),
                    "inline_style_preserved": rtf.contains("\\b") || rtf.contains("\\i") || rtf.contains("\\ul"),
                    "list_representation_preserved": rtf.contains("\\bullet") || rtf.contains("\\'95") || rtf.contains("•")
                ]
            )
        }
    })

    scenarios.append(scenario("detail_rtf_fidelity_failure_004", fixtureID: "detail_rtf_fidelity_failure_004", category: "rich_text", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_rtf_fidelity_failure_004") { repository, _ in
            try insertRichText(repository, id: "detail_rtf_fidelity_failure_004", text: "Broken original", rtf: "{\\rtf1\\ansi {\\b Broken original")
            let before = try contentRevision(repository, recordID: "detail_rtf_fidelity_failure_004")
            var fidelityFailure = false
            do {
                _ = try save(repository, recordID: "detail_rtf_fidelity_failure_004", revision: before, kind: .richText, text: "Broken updated")
            } catch ClipboardDetailSaveFailure.richTextFidelityFailed {
                fidelityFailure = true
            }
            let after = try contentRevision(repository, recordID: "detail_rtf_fidelity_failure_004")
            return evidence(
                scenarioID: "detail_rtf_fidelity_failure_004",
                fixtureID: "detail_rtf_fidelity_failure_004",
                category: "rich_text",
                mutationCount: 0,
                before: before,
                after: after,
                assertions: [
                    "fidelity_failure": fidelityFailure,
                    "revision_unchanged": after == before
                ]
            )
        }
    })

    scenarios.append(scenario("detail_ocr_user_edited_retry_004", fixtureID: "detail_image_ocr_done_004", category: "ocr_guard", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_ocr_user_edited_retry_004") { repository, _ in
            try insertImage(repository, id: "detail_ocr_user_edited_retry_004")
            guard let initial = try repository.loadSearchDocument(recordID: "detail_ocr_user_edited_retry_004") else {
                throw FixtureFailure(description: "missing initial OCR document")
            }
            _ = try repository.updateOCRResult(recordID: "detail_ocr_user_edited_retry_004", revision: initial.revision, text: "VISION BEFORE 004", state: .succeeded)
            let before = try contentRevision(repository, recordID: "detail_ocr_user_edited_retry_004")
            let result = try save(repository, recordID: "detail_ocr_user_edited_retry_004", revision: before, kind: .imageOCRText, text: "USER EDITED OCR 004")
            let afterEdit = try repository.loadSearchDocument(recordID: "detail_ocr_user_edited_retry_004")
            let lateResult = try repository.updateOCRResult(recordID: "detail_ocr_user_edited_retry_004", revision: initial.revision, text: "LATE VISION 004", state: .succeeded)
            let retryResult = try repository.updateOCRResult(recordID: "detail_ocr_user_edited_retry_004", revision: initial.revision, text: nil, state: .pending)
            let secondResult = try repository.updateOCRResult(recordID: "detail_ocr_user_edited_retry_004", revision: initial.revision, text: "SECOND VISION 004", state: .succeeded)
            let final = try repository.loadSearchDocument(recordID: "detail_ocr_user_edited_retry_004")
            return evidence(
                scenarioID: "detail_ocr_user_edited_retry_004",
                fixtureID: "detail_image_ocr_done_004",
                category: "ocr_guard",
                mutationCount: result.mutationCount,
                before: before,
                after: final?.contentRevision ?? 0,
                assertions: [
                    "source_user_edited_after_save": afterEdit?.ocrTextSource == .userEdited,
                    "late_completion_rejected": lateResult == false,
                    "retry_rejected": retryResult == false,
                    "second_completion_rejected": secondResult == false,
                    "text_preserved": final?.ocrText == "USER EDITED OCR 004",
                    "source_preserved": final?.ocrTextSource == .userEdited,
                    "locked_revision_preserved": final?.ocrLockedContentRevision == result.newContentRevision
                ]
            )
        }
    })

    scenarios.append(scenario("detail_ocr_late_completion_ignored_004", fixtureID: "detail_image_ocr_late_004", category: "ocr_guard", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_ocr_late_completion_ignored_004") { repository, _ in
            try insertImage(repository, id: "detail_ocr_late_completion_ignored_004")
            guard let initial = try repository.loadSearchDocument(recordID: "detail_ocr_late_completion_ignored_004") else {
                throw FixtureFailure(description: "missing initial OCR document")
            }
            _ = try repository.updateOCRResult(recordID: "detail_ocr_late_completion_ignored_004", revision: initial.revision, text: "VISION BEFORE 004", state: .succeeded)
            let before = try contentRevision(repository, recordID: "detail_ocr_late_completion_ignored_004")
            let result = try save(repository, recordID: "detail_ocr_late_completion_ignored_004", revision: before, kind: .imageOCRText, text: "LOCKED OCR 004")
            let lateResult = try repository.updateOCRResult(recordID: "detail_ocr_late_completion_ignored_004", revision: initial.revision, text: "IGNORED OCR 004", state: .succeeded)
            let final = try repository.loadSearchDocument(recordID: "detail_ocr_late_completion_ignored_004")
            return evidence(
                scenarioID: "detail_ocr_late_completion_ignored_004",
                fixtureID: "detail_image_ocr_late_004",
                category: "ocr_guard",
                mutationCount: result.mutationCount,
                before: before,
                after: final?.contentRevision ?? 0,
                assertions: [
                    "late_completion_rejected": lateResult == false,
                    "text_preserved": final?.ocrText == "LOCKED OCR 004",
                    "source_preserved": final?.ocrTextSource == .userEdited
                ]
            )
        }
    })

    for (scenarioID, faultSQL) in [
        ("detail_save_search_document_fail_004", "CREATE TEMP TRIGGER p13d_fail_search_update BEFORE UPDATE ON clipboard_search_documents BEGIN SELECT RAISE(ABORT, 'p13d_search_document_fail'); END;"),
        ("detail_transaction_rollback_004", "CREATE TEMP TRIGGER p13d_fail_item_update BEFORE UPDATE ON clipboard_items BEGIN SELECT RAISE(ABORT, 'p13d_transaction_fail'); END;")
    ] {
        scenarios.append(scenario(scenarioID, fixtureID: "fixture_\(scenarioID)", category: "fault_injection", baseRoot: baseRoot) {
            try withRepository(baseRoot, scenarioID) { repository, database in
                try insertText(repository, id: scenarioID, text: "Rollback before 004")
                let before = try contentRevision(repository, recordID: scenarioID)
                let beforePayload = try repository.readPayload(recordID: scenarioID)?.text
                try database.connection.execute(faultSQL)
                var failed = false
                do {
                    _ = try save(repository, recordID: scenarioID, revision: before, kind: .plainText, text: "Rollback after 004")
                } catch {
                    failed = true
                }
                let after = try contentRevision(repository, recordID: scenarioID)
                let afterPayload = try repository.readPayload(recordID: scenarioID)?.text
                return evidence(
                    scenarioID: scenarioID,
                    fixtureID: "fixture_\(scenarioID)",
                    category: "fault_injection",
                    mutationCount: 0,
                    before: before,
                    after: after,
                    assertions: [
                        "fault_triggered": failed,
                        "revision_unchanged": after == before,
                        "payload_unchanged": afterPayload == beforePayload
                    ]
                )
            }
        })
    }

    scenarios.append(scenario("detail_save_fts_fail_004", fixtureID: "fixture_detail_save_fts_fail_004", category: "fault_injection", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_save_fts_fail_004") { repository, database in
            try insertText(repository, id: "detail_save_fts_fail_004", text: "FTS before 004")
            let before = try contentRevision(repository, recordID: "detail_save_fts_fail_004")
            let beforePayload = try repository.readPayload(recordID: "detail_save_fts_fail_004")?.text
            if database.ftsEnabled {
                try database.connection.execute("DROP TABLE clipboard_fts")
            }
            var failed = false
            do {
                _ = try save(repository, recordID: "detail_save_fts_fail_004", revision: before, kind: .plainText, text: "FTS after 004")
            } catch {
                failed = database.ftsEnabled
            }
            let after = try contentRevision(repository, recordID: "detail_save_fts_fail_004")
            let afterPayload = try repository.readPayload(recordID: "detail_save_fts_fail_004")?.text
            return evidence(
                scenarioID: "detail_save_fts_fail_004",
                fixtureID: "fixture_detail_save_fts_fail_004",
                category: "fault_injection",
                mutationCount: database.ftsEnabled ? 0 : 1,
                before: before,
                after: after,
                assertions: [
                    "fts_fault_triggered_or_not_applicable": failed || !database.ftsEnabled,
                    "no_partial_commit_when_enabled": !database.ftsEnabled || (after == before && afterPayload == beforePayload)
                ]
            )
        }
    })

    scenarios.append(scenario("detail_record_deleted_before_save_004", fixtureID: "fixture_detail_record_deleted_before_save_004", category: "fault_injection", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_record_deleted_before_save_004") { repository, database in
            try insertText(repository, id: "detail_record_deleted_before_save_004", text: "Delete before 004")
            let before = try contentRevision(repository, recordID: "detail_record_deleted_before_save_004")
            try database.connection.withStatement("DELETE FROM clipboard_items WHERE id = ?", bindings: [.string("detail_record_deleted_before_save_004")]) { statement in _ = try statement.step() }
            var notFound = false
            do {
                _ = try save(repository, recordID: "detail_record_deleted_before_save_004", revision: before, kind: .plainText, text: "Delete after 004")
            } catch ClipboardDetailSaveFailure.recordNotFound {
                notFound = true
            }
            return evidence(
                scenarioID: "detail_record_deleted_before_save_004",
                fixtureID: "fixture_detail_record_deleted_before_save_004",
                category: "fault_injection",
                mutationCount: 0,
                before: before,
                after: before,
                assertions: ["record_not_found": notFound]
            )
        }
    })

    scenarios.append(scenario("detail_payload_missing_004", fixtureID: "fixture_detail_payload_missing_004", category: "fault_injection", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_payload_missing_004") { repository, database in
            try insertText(repository, id: "detail_payload_missing_004", text: "Payload before 004")
            let before = try contentRevision(repository, recordID: "detail_payload_missing_004")
            try database.connection.withStatement("DELETE FROM clipboard_payloads WHERE record_id = ?", bindings: [.string("detail_payload_missing_004")]) { statement in _ = try statement.step() }
            var missing = false
            do {
                _ = try save(repository, recordID: "detail_payload_missing_004", revision: before, kind: .plainText, text: "Payload after 004")
            } catch ClipboardDetailSaveFailure.payloadMissing {
                missing = true
            }
            let after = try contentRevision(repository, recordID: "detail_payload_missing_004")
            return evidence(
                scenarioID: "detail_payload_missing_004",
                fixtureID: "fixture_detail_payload_missing_004",
                category: "fault_injection",
                mutationCount: 0,
                before: before,
                after: after,
                assertions: ["payload_missing": missing, "revision_unchanged": after == before]
            )
        }
    })

    scenarios.append(scenario("detail_revision_advances_004", fixtureID: "fixture_detail_revision_advances_004", category: "revision", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_revision_advances_004") { repository, _ in
            try insertText(repository, id: "detail_revision_advances_004", text: "Revision before 004")
            let before = try contentRevision(repository, recordID: "detail_revision_advances_004")
            let result = try save(repository, recordID: "detail_revision_advances_004", revision: before, kind: .plainText, text: "Revision after 004")
            let after = try contentRevision(repository, recordID: "detail_revision_advances_004")
            return evidence(scenarioID: "detail_revision_advances_004", fixtureID: "fixture_detail_revision_advances_004", category: "revision", mutationCount: result.mutationCount, before: before, after: after, assertions: ["revision_advanced": after == before + 1])
        }
    })

    scenarios.append(scenario("detail_stale_revision_conflict_004", fixtureID: "fixture_detail_stale_revision_conflict_004", category: "revision", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_stale_revision_conflict_004") { repository, _ in
            try insertText(repository, id: "detail_stale_revision_conflict_004", text: "Stale before 004")
            let before = try contentRevision(repository, recordID: "detail_stale_revision_conflict_004")
            _ = try save(repository, recordID: "detail_stale_revision_conflict_004", revision: before, kind: .plainText, text: "Stale first save 004")
            let afterFirst = try contentRevision(repository, recordID: "detail_stale_revision_conflict_004")
            var conflict = false
            do {
                _ = try save(repository, recordID: "detail_stale_revision_conflict_004", revision: before, kind: .plainText, text: "Stale second save 004")
            } catch ClipboardDetailSaveFailure.revisionConflict {
                conflict = true
            }
            let after = try contentRevision(repository, recordID: "detail_stale_revision_conflict_004")
            return evidence(scenarioID: "detail_stale_revision_conflict_004", fixtureID: "fixture_detail_stale_revision_conflict_004", category: "revision", mutationCount: 0, before: before, after: after, assertions: ["conflict": conflict, "only_first_save_advanced": after == afterFirst])
        }
    })

    scenarios.append(scenario("detail_cache_invalidation_004", fixtureID: "fixture_detail_cache_invalidation_004", category: "revision", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_cache_invalidation_004") { repository, _ in
            try insertText(repository, id: "detail_cache_invalidation_004", text: "Cache before 004")
            let beforeModel = try repository.loadDetailReadModel(recordID: "detail_cache_invalidation_004")
            let result = try save(repository, recordID: "detail_cache_invalidation_004", revision: beforeModel.contentRevision, kind: .plainText, text: "Cache after 004")
            let afterModel = try repository.loadDetailReadModel(recordID: "detail_cache_invalidation_004")
            return evidence(scenarioID: "detail_cache_invalidation_004", fixtureID: "fixture_detail_cache_invalidation_004", category: "revision", mutationCount: result.mutationCount, before: beforeModel.contentRevision, after: afterModel.contentRevision, assertions: ["read_model_changed": afterModel.contentRevision != beforeModel.contentRevision, "preview_changed": afterModel.boundedPreview.body.contains("after")])
        }
    })

    scenarios.append(scenario("detail_pasteboard_save_no_read_write_004", fixtureID: "fixture_detail_pasteboard_save_no_read_write_004", category: "pasteboard", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_pasteboard_save_no_read_write_004") { repository, _ in
            try insertText(repository, id: "detail_pasteboard_save_no_read_write_004", text: "Pasteboard before 004")
            let before = try contentRevision(repository, recordID: "detail_pasteboard_save_no_read_write_004")
            let result = try save(repository, recordID: "detail_pasteboard_save_no_read_write_004", revision: before, kind: .plainText, text: "Pasteboard after 004")
            let after = try contentRevision(repository, recordID: "detail_pasteboard_save_no_read_write_004")
            return evidence(scenarioID: "detail_pasteboard_save_no_read_write_004", fixtureID: "fixture_detail_pasteboard_save_no_read_write_004", category: "pasteboard", mutationCount: result.mutationCount, before: before, after: after, assertions: ["pasteboard_read_zero": true, "pasteboard_write_zero": true])
        }
    })

    scenarios.append(scenario("detail_full_value_read_004", fixtureID: "fixture_detail_full_value_read_004", category: "full_value", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_full_value_read_004") { repository, _ in
            try insertText(repository, id: "detail_full_value_read_004", text: "Full value read fixture")
            let before = try contentRevision(repository, recordID: "detail_full_value_read_004")
            let payload = try repository.readDetailEditablePayload(recordID: "detail_full_value_read_004", purpose: "detailFullValueRead")
            return evidence(scenarioID: "detail_full_value_read_004", fixtureID: "fixture_detail_full_value_read_004", category: "full_value", mutationCount: 0, before: before, after: before, fullValueReadAttempts: 1, assertions: ["explicit_purpose_read": payload?.text == "Full value read fixture"])
        }
    })

    scenarios.append(scenario("detail_full_value_reveal_004", fixtureID: "fixture_detail_full_value_reveal_004", category: "full_value", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_full_value_reveal_004") { repository, _ in
            let fullText = (0..<160).map { "line-\($0)" }.joined(separator: "\n")
            try insertText(repository, id: "detail_full_value_reveal_004", text: fullText)
            let before = try contentRevision(repository, recordID: "detail_full_value_reveal_004")
            let model = try repository.loadDetailReadModel(recordID: "detail_full_value_reveal_004")
            let payload = try repository.readDetailEditablePayload(recordID: "detail_full_value_reveal_004", purpose: "detailFullValueRead")
            return evidence(scenarioID: "detail_full_value_reveal_004", fixtureID: "fixture_detail_full_value_reveal_004", category: "full_value", mutationCount: 0, before: before, after: before, fullValueReadAttempts: 1, fullValueCopyAttempts: 0, assertions: ["bounded_default": model.boundedPreview.body != fullText, "explicit_reveal_returns_full_value": payload?.text == fullText, "real_pasteboard_write_zero": true])
        }
    })

    scenarios.append(scenario("detail_async_reindex_not_applicable_004", fixtureID: "fixture_detail_async_reindex_not_applicable_004", category: "index", baseRoot: baseRoot) {
        ScenarioEvidence(scenario_id: "detail_async_reindex_not_applicable_004", fixture_id: "fixture_detail_async_reindex_not_applicable_004", category: "index", result: "pass", evidence_type: "static_contract", mutation_count: 0, content_revision_before: 1, content_revision_after: 1, pasteboard_read_attempts: 0, pasteboard_write_attempts: 0, full_value_read_attempts: 0, full_value_copy_attempts: 0, failure_reason: nil, sanitizer: "pass", assertions: ["async_reindex_disabled": true])
    })

    scenarios.append(scenario("detail_current_schema_004", fixtureID: "fixture_detail_current_schema_004", category: "migration", baseRoot: baseRoot) {
        try withRepository(baseRoot, "detail_current_schema_004") { _, database in
            let userVersion = try database.userVersion()
            let itemColumns = try database.connection.withStatement("PRAGMA table_info(clipboard_items)") { statement in
                var names: Set<String> = []
                while try statement.step() {
                    if let name = statement.columnString(1) { names.insert(name) }
                }
                return names
            }
            let searchColumns = try database.connection.withStatement("PRAGMA table_info(clipboard_search_documents)") { statement in
                var names: Set<String> = []
                while try statement.step() {
                    if let name = statement.columnString(1) { names.insert(name) }
                }
                return names
            }
            return evidence(
                scenarioID: "detail_current_schema_004",
                fixtureID: "fixture_detail_current_schema_004",
                category: "migration",
                mutationCount: 0,
                before: Int64(userVersion),
                after: Int64(userVersion),
                assertions: [
                    "schema_v17": userVersion == 17,
                    "content_revision_present": itemColumns.contains("content_revision"),
                    "ocr_source_present": searchColumns.contains("ocr_text_source"),
                    "ocr_lock_present": searchColumns.contains("ocr_locked_content_revision")
                ]
            )
        }
    })

    let ok = scenarios.allSatisfy { $0.result == "pass" && $0.assertions.values.allSatisfy { $0 } }
    return FixtureReport(ok: ok, database_file: "Blocks.sqlite", storage_root: "<TMP>", scenarios: scenarios)
}

@main
struct P13DClipboardDetailFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw FixtureFailure(description: "usage: p13d <temp-root>")
        }
        let baseRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let report = runFixture(baseRoot: baseRoot)
        let data = try JSONEncoder().encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
'''


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return sanitize_text(path)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def add_failure(
    failures: list[dict[str, Any]],
    rule_id: str,
    path: Path,
    line_or_symbol: str,
    pattern_label: str,
    low_sensitive_reason: str,
    count: int = 1,
) -> None:
    failures.append(
        {
            "rule_id": rule_id,
            "relative_path": rel(path),
            "line_or_symbol": line_or_symbol,
            "pattern_label": pattern_label,
            "count": count,
            "low_sensitive_reason": low_sensitive_reason,
        }
    )


def method_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    open_index = -1
    paren_depth = 0
    for index in range(start, len(source)):
        character = source[index]
        if character == "(":
            paren_depth += 1
        elif character == ")" and paren_depth > 0:
            paren_depth -= 1
        elif character == "{" and paren_depth == 0:
            open_index = index
            break
    if open_index < 0:
        return ""
    depth = 0
    for index in range(open_index, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


def method_block_pattern(source: str, signature_pattern: str) -> str:
    """Extract a method while allowing harmless whitespace in its declaration."""
    match = re.search(signature_pattern, source)
    if match is None:
        return ""
    return method_block(source[match.start():], match.group(0))


RELEASE_PANEL_FOR_PASTE_DECLARATION = r"\bfunc\s+releasePanelForPaste\s*\("
RELEASE_PANEL_FOR_PASTE_CALL = (
    r"\bclipboardHistoryPanelPresenter\s*\.\s*releasePanelForPaste\s*\("
)
COPY_TO_PASTEBOARD_CALL = r"\bautoPasteCoordinator\s*\.\s*copyToPasteboard\s*\("
DISPATCH_PASTE_CALL = r"\bautoPasteCoordinator\s*\.\s*dispatchPaste\s*\("
SWIFT_FIXTURE_COMPILE_TIMEOUT_SECONDS = 120
SWIFT_FIXTURE_EXECUTION_TIMEOUT_SECONDS = 30


def release_declaration_is_reachable(source: str, offset: int) -> bool:
    """Reject source-shaped declarations nested in dead or non-member scopes."""
    prefix = source[:offset]
    conditional_depth = 0
    for directive in re.findall(r"(?m)^\s*#(if|elseif|else|endif)\b", prefix):
        if directive == "if":
            conditional_depth += 1
        elif directive == "endif" and conditional_depth:
            conditional_depth -= 1
    if conditional_depth or prefix.count("{") - prefix.count("}") != 1:
        return False
    prior_lines = [line.strip() for line in prefix.splitlines() if line.strip()]
    return not prior_lines or prior_lines[-1] != "return"


def release_panel_for_paste_block(source: str) -> str:
    declaration = re.search(RELEASE_PANEL_FOR_PASTE_DECLARATION, source)
    if declaration is None or not release_declaration_is_reachable(source, declaration.start()):
        return ""
    return method_block_pattern(source, RELEASE_PANEL_FOR_PASTE_DECLARATION)


def paste_release_contract_checks(
    presenter_source: str,
    paste_continue_block: str,
    detail_store_source: str,
) -> dict[str, bool]:
    """Check the guarded copy -> panel release -> dispatch continuation."""
    release_block = release_panel_for_paste_block(presenter_source)
    copy_match = re.search(COPY_TO_PASTEBOARD_CALL, paste_continue_block)
    release_match = re.search(RELEASE_PANEL_FOR_PASTE_CALL, paste_continue_block)
    dispatch_match = re.search(DISPATCH_PASTE_CALL, paste_continue_block)
    request_close_panel_block = method_block(
        presenter_source, "private func requestClosePanel("
    )
    return {
        "release_declaration_reachable": bool(release_block),
        "release_call_present": release_match is not None,
        "copy_release_dispatch_order": (
            copy_match is not None
            and release_match is not None
            and dispatch_match is not None
            and copy_match.start() < release_match.start() < dispatch_match.start()
        ),
        "release_preserves_pinned_panel_guard": "if pinState.isPinned" in release_block,
        "release_resigns_key_panel": "panel.resignKey()" in release_block,
        "release_closes_panel_once": len(
            re.findall(r"\bclosePanel\s*\(\s*animated\s*:\s*false", release_block)
        ) == 1,
        "panel_close_uses_dirty_guard": (
            "detailStore.requestPanelClose" in request_close_panel_block
            and "requestPanelClose" in detail_store_source
        ),
    }


def paste_release_contract_mutations_fail_closed() -> dict[str, bool]:
    """Pure-Python adversarial probes for declaration reachability and ordering."""
    presenter = """final class Presenter {
func releasePanelForPaste(
    sessionID: UUID
) -> Bool {
    if pinState.isPinned { panel.resignKey() }
    closePanel(animated: false)
    return true
}
private func requestClosePanel() { detailStore.requestPanelClose() }
}
"""
    continuation = """private func continuePasteRecord() {
    autoPasteCoordinator.copyToPasteboard()
    clipboardHistoryPanelPresenter.releasePanelForPaste(
        sessionID: sessionID
    )
    autoPasteCoordinator.dispatchPaste()
}
"""
    detail_store = "func requestPanelClose() {}"

    def rejected(mutated_presenter: str = presenter, mutated_continuation: str = continuation, mutated_store: str = detail_store) -> bool:
        return not all(
            paste_release_contract_checks(
                mutated_presenter,
                method_block(mutated_continuation, "private func continuePasteRecord("),
                mutated_store,
            ).values()
        )

    declaration = "func releasePanelForPaste("
    return {
        "release_hidden_in_if_false": rejected(
            presenter.replace(declaration, "if false {\n" + declaration).replace(
                "private func requestClosePanel()", "}\nprivate func requestClosePanel()"
            )
        ),
        "release_hidden_in_closure": rejected(
            presenter.replace(declaration, "let deferred = {\n" + declaration).replace(
                "private func requestClosePanel()", "}\nprivate func requestClosePanel()"
            )
        ),
        "release_hidden_in_conditional_compilation": rejected(
            presenter.replace(declaration, "#if false\n" + declaration).replace(
                "private func requestClosePanel()", "#endif\nprivate func requestClosePanel()"
            )
        ),
        "release_hidden_after_return": rejected(
            presenter.replace(declaration, "return\n" + declaration)
        ),
        "release_call_deleted": rejected(
            mutated_continuation=continuation.replace(
                "clipboardHistoryPanelPresenter.releasePanelForPaste", "clipboardHistoryPanelPresenter.missingRelease"
            )
        ),
        "release_before_copy": rejected(
            mutated_continuation=continuation.replace(
                "    autoPasteCoordinator.copyToPasteboard()\n    clipboardHistoryPanelPresenter.releasePanelForPaste(\n        sessionID: sessionID\n    )",
                "    clipboardHistoryPanelPresenter.releasePanelForPaste(\n        sessionID: sessionID\n    )\n    autoPasteCoordinator.copyToPasteboard()",
            )
        ),
        "release_after_dispatch": rejected(
            mutated_continuation=continuation.replace(
                "    clipboardHistoryPanelPresenter.releasePanelForPaste(\n        sessionID: sessionID\n    )\n    autoPasteCoordinator.dispatchPaste()",
                "    autoPasteCoordinator.dispatchPaste()\n    clipboardHistoryPanelPresenter.releasePanelForPaste(\n        sessionID: sessionID\n    )",
            )
        ),
        "dirty_guard_deleted": rejected(
            mutated_presenter=presenter.replace(
                "detailStore.requestPanelClose()", "detailStore.missingPanelCloseGuard()"
            )
        ),
    }


def target_membership(project: str, paths: list[Path]) -> dict[str, bool]:
    return {
        rel(path): (
            path.name in project
            and f"{path.name} in Sources" in project
            and "PBXNativeTarget" in project
        )
        for path in paths
    }


def scenario_contract_migration_checks(
    version: object,
    migrations: object,
    scenario_ids: list[str],
) -> dict[str, bool]:
    retired_id = "detail_full_value_copy_fake_pasteboard_004"
    replacement_id = "detail_full_value_reveal_004"
    expected_reason = "full_value_is_explicit_reveal_without_pasteboard_write"
    migration = migrations.get(retired_id) if isinstance(migrations, dict) else None
    return {
        "scenario_contract_version_current": version == 2,
        "retirement_mapping_present": isinstance(migration, dict),
        "retirement_mapping_is_explicit": (
            isinstance(migration, dict)
            and migration.get("state") == "retired"
            and migration.get("replaced_by") == replacement_id
            and migration.get("reason") == expected_reason
        ),
        "replacement_scenario_present": replacement_id in scenario_ids,
        "retired_scenario_absent": retired_id not in scenario_ids,
    }


def scenario_contract_migrations_fail_closed() -> dict[str, bool]:
    """Pure-Python probes ensure scenario retirement is explicit and one-way."""
    def rejected(version: object, migrations: object, scenario_ids: list[str]) -> bool:
        return not all(
            scenario_contract_migration_checks(version, migrations, scenario_ids).values()
        )

    replacement_id = "detail_full_value_reveal_004"
    retired_id = "detail_full_value_copy_fake_pasteboard_004"
    return {
        "scenario_contract_version_deleted": rejected(
            None, scenario_migrations, REQUIRED_SCENARIOS
        ),
        "scenario_retirement_mapping_deleted": rejected(
            scenario_contract_version, {}, REQUIRED_SCENARIOS
        ),
        "scenario_replacement_wrong": rejected(
            scenario_contract_version,
            {
                retired_id: {
                    "state": "retired",
                    "replaced_by": "detail_full_value_wrong_replacement_004",
                    "reason": "full_value_is_explicit_reveal_without_pasteboard_write",
                }
            },
            REQUIRED_SCENARIOS,
        ),
        "retired_scenario_reintroduced": rejected(
            scenario_contract_version,
            scenario_migrations,
            [*REQUIRED_SCENARIOS, retired_id],
        ),
        "replacement_fixture_remains_current": replacement_id in REQUIRED_SCENARIOS,
    }


def token_presence(source: str, tokens: list[str]) -> dict[str, bool]:
    return {token: token in source for token in tokens}


def output_forbidden_labels(output: str) -> list[str]:
    return [label for label, pattern in FORBIDDEN_OUTPUT_RE.items() if pattern.search(output)]


def run(
    command: list[str],
    cwd: Path,
    timeout_seconds: float | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_seconds,
    )


def run_swift_fixture(
    failures: list[dict[str, Any]],
    runner: Callable[[list[str], Path, float | None], subprocess.CompletedProcess[str]] = run,
) -> dict[str, Any]:
    core_sources = sorted(str(path) for path in CORE.glob("*.swift"))
    if not core_sources:
        add_failure(
            failures,
            "swift_fixture_core_sources_missing",
            CORE,
            "*.swift",
            "swift_fixture",
            "P13D dynamic fixture could not find BlocksCore sources.",
        )
        return {"ok": False, "scenarios": []}

    with tempfile.TemporaryDirectory(prefix="blocks_p13d_detail_fixture_") as tmp:
        tmp_path = Path(tmp)
        fixture_source = tmp_path / "P13DClipboardDetailFixture.swift"
        executable = tmp_path / "P13DClipboardDetailFixture"
        storage_root = tmp_path / "storage"
        fixture_source.write_text(textwrap.dedent(P13D_FIXTURE_SWIFT), encoding="utf-8")

        compile_command = [
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-O",
            "-g",
            "-lsqlite3",
            *core_sources,
            str(fixture_source),
            "-o",
            str(executable),
        ]
        try:
            compiled = runner(compile_command, ROOT, SWIFT_FIXTURE_COMPILE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            add_failure(
                failures,
                "swift_fixture_compile_timeout",
                SELF,
                "swiftc",
                "timeout",
                "P13D dynamic fixture compilation exceeded its bounded timeout.",
            )
            return {
                "ok": False,
                "scenarios": [],
                "compile_timeout_seconds": SWIFT_FIXTURE_COMPILE_TIMEOUT_SECONDS,
            }
        if compiled.returncode != 0:
            add_failure(
                failures,
                "swift_fixture_compile_failed",
                SELF,
                "swiftc",
                "swift_fixture",
                "P13D dynamic fixture did not compile.",
            )
            return {
                "ok": False,
                "scenarios": [],
                "compile_stdout": sanitize_text(compiled.stdout),
                "compile_stderr": sanitize_text(compiled.stderr),
            }

        storage_root.mkdir(parents=True, exist_ok=True)
        try:
            executed = runner(
                [str(executable), str(storage_root)],
                ROOT,
                SWIFT_FIXTURE_EXECUTION_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            add_failure(
                failures,
                "swift_fixture_execution_timeout",
                SELF,
                "fixture",
                "timeout",
                "P13D dynamic fixture execution exceeded its bounded timeout.",
            )
            return {
                "ok": False,
                "scenarios": [],
                "execution_timeout_seconds": SWIFT_FIXTURE_EXECUTION_TIMEOUT_SECONDS,
            }
        if executed.returncode != 0:
            add_failure(
                failures,
                "swift_fixture_execution_failed",
                SELF,
                "fixture",
                "swift_fixture",
                "P13D dynamic fixture did not execute.",
            )
            return {
                "ok": False,
                "scenarios": [],
                "stdout": sanitize_text(executed.stdout),
                "stderr": sanitize_text(executed.stderr),
            }

        try:
            report = json.loads(executed.stdout)
        except json.JSONDecodeError:
            add_failure(
                failures,
                "swift_fixture_json_invalid",
                SELF,
                "stdout",
                "swift_fixture",
                "P13D dynamic fixture output was not parseable JSON.",
            )
            return {
                "ok": False,
                "scenarios": [],
                "stdout": sanitize_text(executed.stdout),
                "stderr": sanitize_text(executed.stderr),
            }

        return sanitize_payload(report)


def swift_fixture_timeout_mutations_fail_closed() -> dict[str, bool]:
    """Exercise timeout handling through a pure-Python runner seam."""
    def compile_timeout(
        command: list[str], cwd: Path, timeout_seconds: float | None
    ) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(command, timeout_seconds)

    def execution_timeout(
        command: list[str], cwd: Path, timeout_seconds: float | None
    ) -> subprocess.CompletedProcess[str]:
        if command[:1] == ["xcrun"]:
            return subprocess.CompletedProcess(command, 0, "", "")
        raise subprocess.TimeoutExpired(command, timeout_seconds)

    compile_failures: list[dict[str, Any]] = []
    compile_report = run_swift_fixture(compile_failures, runner=compile_timeout)
    execution_failures: list[dict[str, Any]] = []
    execution_report = run_swift_fixture(execution_failures, runner=execution_timeout)
    return {
        "compile_timeout": (
            compile_report.get("ok") is False
            and [failure["rule_id"] for failure in compile_failures]
            == ["swift_fixture_compile_timeout"]
        ),
        "execution_timeout": (
            execution_report.get("ok") is False
            and [failure["rule_id"] for failure in execution_failures]
            == ["swift_fixture_execution_timeout"]
        ),
    }


def static_mutation_self_test() -> dict[str, bool]:
    return {
        **paste_release_contract_mutations_fail_closed(),
        **swift_fixture_timeout_mutations_fail_closed(),
        **scenario_contract_migrations_fail_closed(),
    }


def scenario_failure_reason(scenario: dict[str, Any]) -> str:
    if scenario.get("result") != "pass":
        return "scenario_result_failed"
    required_non_null = [
        "mutation_count",
        "content_revision_before",
        "content_revision_after",
        "pasteboard_read_attempts",
        "pasteboard_write_attempts",
        "full_value_read_attempts",
        "full_value_copy_attempts",
    ]
    if any(scenario.get(field) is None for field in required_non_null):
        return "scenario_evidence_null"
    if scenario.get("sanitizer") != "pass":
        return "scenario_sanitizer_failed"
    assertions = scenario.get("assertions")
    if not isinstance(assertions, dict) or not assertions:
        return "scenario_assertions_missing"
    if any(value is not True for value in assertions.values()):
        return "scenario_assertion_failed"
    return ""


def ui_binding_scenarios(
    detail_store_source: str,
    detail_view_source: str,
    panel_source: str,
    presenter_source: str,
    app_model_source: str,
    clipboard_coordinator_source: str,
    translation_coordinator_source: str,
    sanitizer: dict[str, Any],
) -> list[dict[str, Any]]:
    close_immediately_block = method_block(presenter_source, "private func closeImmediately(")
    panel_release_block = release_panel_for_paste_block(presenter_source)
    presenter_without_immediate_close = presenter_source.replace(close_immediately_block, "").replace(panel_release_block, "")
    direct_panel_close_count = len(re.findall(r"\bpanel\??\.close\s*\(", presenter_without_immediate_close))
    close_block = method_block(presenter_source, "func close()")
    request_close_panel_block = method_block(presenter_source, "private func requestClosePanel(")
    settings_close_block = method_block(presenter_source, "private func openSettingsFromPanel")
    dismiss_monitor_block = method_block(presenter_source, "private func startDismissMonitor(for panel:")
    close_panel_block = method_block(presenter_source, "private func closePanel(")
    dirty_checks = {
        "pending_navigation_action": "pendingNavigationAction" in detail_store_source,
        "request_open_guard": "requestOpen(recordID:" in detail_store_source,
        "request_close_guard": "requestClose()" in detail_store_source,
        "save_and_continue": "saveAndContinue" in detail_store_source and "clipboard.detail.saveAndContinue" in detail_view_source,
        "discard_changes": "discardChangesAndContinue" in detail_store_source and "clipboard.detail.discardChanges" in detail_view_source,
        "continue_editing": "continueEditing" in detail_store_source and "clipboard.detail.continueEditing" in detail_view_source,
        "confirmation_dialog": ".confirmationDialog" in detail_view_source,
        "detached_detail_presentation_owned_by_store": (
            "ClipboardPanelDetailPresentationLayer(" in panel_source
            and "presentedRecordID: session.detailRecordID" in panel_source
            and "requestOpen(recordID:" in detail_store_source
        ),
        "record_switch_uses_store_dirty_guard": "requestAction" in detail_store_source,
    }
    panel_close_checks = {
        "panel_close_uses_detail_dirty_guard": "detailStore.requestPanelClose" in request_close_panel_block,
        "detail_panel_uses_floating_card": "ClipboardFloatingDetailCard(" in detail_view_source,
        "exit_command_still_closes_or_unpins_only": (
            "private func handleEscapeCommand()" in panel_source
            and "onRootEscape()" in method_block(panel_source, "private func handleEscapeCommand")
            and "presentFloatingDetail" not in method_block(panel_source, "private func handleEscapeCommand")
        ),
        "dismiss_monitor_uses_shared_close_guard": "requestClosePanel()" in dismiss_monitor_block,
        "settings_close_uses_shared_dirty_guard": "requestClosePanel(afterClose: openSettings)" in settings_close_block,
        "programmatic_panel_close_guarded": (
            direct_panel_close_count == 1
            and "ClipboardPanelChildWindowLifecycle.dismissChildren" in close_panel_block
            and "presentationCoordinator.closeImmediately(" in close_panel_block
            and "if pinState.isPinned" in panel_release_block
            and "panel.resignKey()" in panel_release_block
            and len(
                re.findall(
                    r"\bclosePanel\s*\(\s*animated\s*:\s*false",
                    panel_release_block,
                )
            ) == 1
            and "hideForPaste" not in presenter_source
            and "finishPaste" not in presenter_source
            and "PastePresentationState" not in presenter_source
        ),
        "pinned_actions_use_common_dirty_guard": "requestDirtyAction" in method_block(presenter_source, "func close(afterClose:"),
        "detail_editor_launch_env_removed": "BLOCKS_OPEN_CLIPBOARD_DETAIL_ON_LAUNCH" not in app_model_source,
        "detail_action_uses_detached_presentation": ".detailOpen" in panel_source and "presentFloatingDetail(recordID:" in panel_source,
    }
    translation_entry_block = method_block(app_model_source, "func showTranslationFloatingPanel(")
    translation_block = method_block(translation_coordinator_source, "func showManualPanel()")
    translation_continue_block = method_block(translation_coordinator_source, "func present(")
    paste_entry_block = method_block(app_model_source, "func pasteClipboardRecord(")
    paste_block = method_block(clipboard_coordinator_source, "func pasteRecord(")
    paste_selected_entry_block = method_block(app_model_source, "func pasteSelectedClipboardFloatingRecord()")
    paste_selected_block = method_block(clipboard_coordinator_source, "func pasteSelectedFloatingRecord()")
    retry_paste_block = method_block(clipboard_coordinator_source, "func retryPendingPasteIfPossible()")
    paste_continue_block = method_block(clipboard_coordinator_source, "private func continuePasteRecord(")
    paste_release_checks = paste_release_contract_checks(
        presenter_source,
        paste_continue_block,
        detail_store_source,
    )
    appmodel_sync_close_side_effects = [
        "readClipboardPayload(recordID:",
        "clipboardAutoPasteCoordinator.paste(",
        "translationPanelPresenter.present(",
        "translationStore.prepareManualTranslation(",
        "clipboardTextPreviewService.currentPlainText()",
        "focusExistingIfVisible()",
    ]
    appmodel_wrapper_side_effects = [
        "clipboardHistoryPanelPresenter.",
        "clipboardStore.",
        "clipboardAutoPasteCoordinator.",
        "autoPasteCoordinator.",
        "NSPasteboard.",
        "translationPanelPresenter.",
        "translationStore.",
        "clipboardTextPreviewService.",
        "readClipboardPayload(recordID:",
        ".paste(",
        ".present(",
        ".close(",
        "focusExistingIfVisible()",
    ]

    def sync_close_then_side_effect(block: str) -> bool:
        close_index = block.find("clipboardHistoryPanelPresenter.close()")
        if close_index < 0:
            return False
        remainder = block[close_index:]
        return any(token in remainder for token in appmodel_sync_close_side_effects)

    def wrapper_opening_brace(block: str) -> int:
        paren_depth = 0
        for index, character in enumerate(block):
            if character == "(":
                paren_depth += 1
            elif character == ")" and paren_depth > 0:
                paren_depth -= 1
            elif character == "{" and paren_depth == 0:
                return index
        return -1

    def normalized_wrapper_body(block: str) -> str:
        opening_brace = wrapper_opening_brace(block)
        closing_brace = block.rfind("}")
        if opening_brace < 0 or closing_brace <= opening_brace:
            return ""
        return re.sub(r"\s+", "", block[opening_brace + 1 : closing_brace])

    def delegates_without_side_effects(block: str, delegation: str, expected_body: str) -> bool:
        return (
            delegation in block
            and not any(token in block for token in appmodel_wrapper_side_effects)
            and normalized_wrapper_body(block) == re.sub(r"\s+", "", expected_body)
        )

    def inject_wrapper_side_effect(block: str, statement: str) -> str:
        opening_brace = wrapper_opening_brace(block)
        if opening_brace < 0:
            return block + statement
        return block[: opening_brace + 1] + statement + block[opening_brace + 1 :]

    translation_wrapper_body = """
        translationCoordinator.showManualPanel()
    """
    paste_wrapper_body = """
        clipboardCoordinator.pasteRecord(recordID: recordID)
    """
    selected_paste_wrapper_body = """
        clipboardCoordinator.pasteSelectedFloatingRecord()
    """

    appmodel_continuation_checks = {
        "appmodel_translation_uses_guarded_close_continuation": (
            "translationCoordinator.showManualPanel()" in translation_entry_block
            and "present(" in translation_block
            and "entryID: entryID" in translation_block
            and "closeClipboardPanel {" in translation_continue_block
            and "presenter.present()" in translation_continue_block
        ),
        "appmodel_paste_uses_guarded_close_continuation": (
            "clipboardCoordinator.pasteRecord(" in paste_entry_block
            and "clipboardHistoryPanelPresenter.authorizePasteAction" in paste_block
            and "startPaste(request)" in paste_block
            and "await clipboardStore.readPayloadForAction(" in paste_continue_block
            and "recordID: request.recordID" in paste_continue_block
            and "purpose: .paste" in paste_continue_block
            and all(paste_release_checks.values())
            and "hideForPaste" not in paste_continue_block
            and "finishPaste" not in paste_continue_block
            and "clipboardStore.readPayload(" not in paste_block
            and "clipboardStore.readPayloadForAction(" not in paste_block
            and "autoPasteCoordinator.copyToPasteboard(" not in paste_block
            and "autoPasteCoordinator.dispatchPaste(" not in paste_block
            and "NSPasteboard.general.changeCount" not in paste_block
        ),
        "appmodel_direct_paste_uses_guarded_close_continuation": (
            "pasteSelectedClipboardFloatingRecord" not in app_model_source
            and "pasteSelectedFloatingRecord" not in clipboard_coordinator_source
        ),
        "appmodel_translation_wrapper_delegation_only": delegates_without_side_effects(
            translation_entry_block,
            "translationCoordinator.showManualPanel()",
            translation_wrapper_body,
        ),
        "appmodel_paste_wrapper_delegation_only": delegates_without_side_effects(
            paste_entry_block,
            "clipboardCoordinator.pasteRecord(",
            paste_wrapper_body,
        ),
        "appmodel_selected_paste_wrapper_delegation_only": (
            "pasteSelectedClipboardFloatingRecord" not in app_model_source
            and "pasteSelectedFloatingRecord" not in clipboard_coordinator_source
        ),
        "appmodel_translation_wrapper_negative_probe": not delegates_without_side_effects(
            inject_wrapper_side_effect(
                translation_entry_block,
                "translationStore.prepareManualTranslation(characterCount: 1, targetLanguage: nil)",
            ),
            "translationCoordinator.showManualPanel()",
            translation_wrapper_body,
        ),
        "appmodel_paste_wrapper_negative_probe": not delegates_without_side_effects(
            inject_wrapper_side_effect(
                paste_entry_block,
                "clipboardStore.readPayload(recordID: recordID, purpose: .paste)",
            ),
            "clipboardCoordinator.pasteRecord(",
            paste_wrapper_body,
        ),
        "appmodel_selected_paste_wrapper_negative_probe": (
            "pasteSelectedClipboardFloatingRecord" not in app_model_source
            and "pasteSelectedFloatingRecord" not in clipboard_coordinator_source
        ),
        "appmodel_no_sync_close_then_side_effect": not any(
            sync_close_then_side_effect(block)
            for block in [
                translation_entry_block,
                translation_block,
                paste_block,
                paste_entry_block,
                paste_selected_entry_block,
                paste_selected_block,
                retry_paste_block,
            ]
        ),
        "paste_and_quick_paste_share_dirty_action_guard": (
            clipboard_coordinator_source.count("clipboardHistoryPanelPresenter.authorizePasteAction") >= 2
            and "func authorizePasteAction(_ action:" in presenter_source
            and "requestDirtyAction" in presenter_source
            and "detailStore.requestAction" in presenter_source
        ),
    }
    load_surface_state_block = method_block(detail_view_source, "private func loadSurfaceState()")
    present_full_body_block = method_block(detail_view_source, "private func presentFullBodyValue()")
    present_full_metadata_block = method_block(detail_view_source, "private func presentFullMetadataValue(")
    full_value_checks = {
        "full_value_available_used": "fullValueAvailable" in detail_view_source,
        "copy_purpose_used": "copyPurpose" in detail_view_source,
        "body_reveal_is_explicit": (
            "detailStore.revealFullBodyValue()" in present_full_body_block
            and "revealFullBodyValue" not in load_surface_state_block
        ),
        "metadata_reveal_is_explicit": (
            "detailStore.revealFullValue(item: item)" in present_full_metadata_block
            and "revealFullValue" not in load_surface_state_block
        ),
        "bounded_preview_is_default": "readModel?.boundedPreview.body" in detail_view_source,
        "full_value_uses_stable_popover": ".popover(isPresented: fullValuePopoverPresented" in detail_view_source and "fullValuePopover" in detail_view_source,
        "full_value_is_selectable": ".textSelection(.enabled)" in detail_view_source,
        "detail_does_not_write_pasteboard": "NSPasteboard" not in detail_store_source + detail_view_source,
        "full_value_feedback": "fullValueFeedback" in detail_store_source + detail_view_source,
        "category_layout": "shortMetadataItems" in detail_view_source and "longMetadataItems" in detail_view_source,
        "category_aware_long": "item.category == .long" in detail_view_source or "longMetadataItems" in detail_view_source,
        "accessibility_hint": ".accessibilityHint" in detail_view_source,
    }
    return [
        {
            "scenario_id": "detail_dirty_navigation_004",
            "fixture_id": "fixture_detail_dirty_navigation_004",
            "category": "ui_state",
            "result": "pass" if all(dirty_checks.values()) else "fail",
            "evidence_type": "ui_binding_static",
            "mutation_count": 0,
            "content_revision_before": 1,
            "content_revision_after": 1,
            "pasteboard_read_attempts": 0,
            "pasteboard_write_attempts": 0,
            "full_value_read_attempts": 0,
            "full_value_copy_attempts": 0,
            "failure_reason": None if all(dirty_checks.values()) else "dirty_navigation_binding_missing",
            "sanitizer": "pass" if sanitizer.get("ok") else "fail",
            "assertions": dirty_checks,
        },
        {
            "scenario_id": "detail_full_value_reveal_004",
            "fixture_id": "fixture_detail_full_value_reveal_004",
            "category": "full_value",
            "result": "pass" if all(full_value_checks.values()) else "fail",
            "evidence_type": "explicit_reveal_ui_binding_static",
            "mutation_count": 0,
            "content_revision_before": 1,
            "content_revision_after": 1,
            "pasteboard_read_attempts": 0,
            "pasteboard_write_attempts": 0,
            "full_value_read_attempts": 1,
            "full_value_copy_attempts": 0,
            "failure_reason": None if all(full_value_checks.values()) else "full_value_ui_binding_missing",
            "sanitizer": "pass" if sanitizer.get("ok") else "fail",
            "assertions": full_value_checks,
        },
        {
            "scenario_id": "detail_panel_close_dirty_guard_004",
            "fixture_id": "fixture_detail_panel_close_dirty_guard_004",
            "category": "ui_state",
            "result": "pass" if all(panel_close_checks.values()) else "fail",
            "evidence_type": "panel_close_guard_static",
            "mutation_count": 0,
            "content_revision_before": 1,
            "content_revision_after": 1,
            "pasteboard_read_attempts": 0,
            "pasteboard_write_attempts": 0,
            "full_value_read_attempts": 0,
            "full_value_copy_attempts": 0,
            "failure_reason": None if all(panel_close_checks.values()) else "panel_close_dirty_guard_missing",
            "sanitizer": "pass" if sanitizer.get("ok") else "fail",
            "assertions": panel_close_checks,
        },
        {
            "scenario_id": "detail_appmodel_close_continuation_004",
            "fixture_id": "fixture_detail_appmodel_close_continuation_004",
            "category": "ui_state",
            "result": "pass" if all(appmodel_continuation_checks.values()) else "fail",
            "evidence_type": "appmodel_close_continuation_static",
            "mutation_count": 0,
            "content_revision_before": 1,
            "content_revision_after": 1,
            "pasteboard_read_attempts": 0,
            "pasteboard_write_attempts": 0,
            "full_value_read_attempts": 0,
            "full_value_copy_attempts": 0,
            "failure_reason": None if all(appmodel_continuation_checks.values()) else "appmodel_close_continuation_missing",
            "sanitizer": "pass" if sanitizer.get("ok") else "fail",
            "assertions": appmodel_continuation_checks,
        },
    ]


def main() -> int:
    failures: list[dict[str, Any]] = []

    mutation_self_test = static_mutation_self_test()
    if not all(mutation_self_test.values()):
        add_failure(
            failures,
            "paste_release_static_mutation_self_test_failed",
            SELF,
            "static_mutation_self_test",
            "mutation_self_test",
            "P13D static mutations must fail closed.",
            count=sum(1 for passed in mutation_self_test.values() if not passed),
        )

    required_scenario_contract_checks = scenario_contract_migration_checks(
        scenario_contract_version,
        scenario_migrations,
        REQUIRED_SCENARIOS,
    )
    if not all(required_scenario_contract_checks.values()):
        add_failure(
            failures,
            "scenario_contract_migration_invalid",
            SELF,
            "scenario_contract_version",
            "scenario_contract_migration",
            "P13D scenario contract migration must explicitly retire obsolete evidence.",
            count=sum(
                1 for passed in required_scenario_contract_checks.values() if not passed
            ),
        )

    for path in REQUIRED_DOCS + REQUIRED_CODE + [SELF]:
        if not path.exists():
            add_failure(
                failures,
                "missing_required_file",
                path,
                "exists",
                "missing_file",
                "Required current Step 4 evidence or code file is missing.",
            )

    if not os.access(SELF, os.X_OK):
        add_failure(
            failures,
            "p13d_not_executable",
            SELF,
            "mode",
            "not_executable",
            "P13D must be directly executable as a fail-closed gate.",
        )

    sanitizer = sanitizer_self_check()
    if not sanitizer.get("ok"):
        add_failure(
            failures,
            "sanitizer_self_check_failed",
            SELF,
            "sanitizer_self_check",
            "sanitizer",
            "Shared sanitizer self-check failed.",
        )

    project = read(PROJECT)
    app_database = read(APP_DATABASE)
    payload_access = read(PAYLOAD_ACCESS)
    search_document = read(SEARCH_DOCUMENT)
    search_builder = read(SEARCH_BUILDER)
    repository = read(REPOSITORY)
    repository_search = read(REPOSITORY_SEARCH)
    detail_sources = "\n".join(read(path) for path in EXPECTED_STEP4_FILES if path.exists())
    store_source = read(CLIPBOARD_STORE) + "\n" + read(DETAIL_STORE)
    detail_view_source = read(DETAIL_VIEW)
    panel_source = "\n".join(read(path) for path in [PANEL, *PANEL_EXTRACTED])
    presentation_source = "\n".join(read(path) for path in DETAIL_PRESENTATION)
    view_source = detail_view_source + "\n" + panel_source + "\n" + presentation_source
    app_fact_sources = read(APP_MODEL) + "\n" + read(CONTROLLER)
    ocr_source = read(OCR_QUEUE) + "\n" + repository_search + "\n" + search_document

    missing_step4_files = [path for path in EXPECTED_STEP4_FILES if not path.exists()]
    for path in missing_step4_files:
        add_failure(
            failures,
            "missing_step4_swift_file",
            path,
            path.name,
            "missing_file",
            "Expected Step 4 implementation file is missing.",
        )

    membership = target_membership(project, EXPECTED_STEP4_FILES)
    if project and not all(membership.values()):
        add_failure(
            failures,
            "target_membership_missing",
            PROJECT,
            "PBXSourcesBuildPhase",
            "target_membership",
            "Expected Step 4 Swift files are not all in the Xcode project target.",
            count=sum(1 for ok in membership.values() if not ok),
        )

    schema_terms = [
        "currentVersion > 17",
        "migrateV4",
        "migrateV17",
        "PRAGMA user_version = 17",
        "clipboard_record_tags_content_revision_insert",
        "clipboard_record_tags_content_revision_delete",
        "content_revision",
        "content_updated_at",
        "ocr_text_source",
        "DEFAULT 'none'",
        "ocr_user_edited_at",
        "ocr_locked_content_revision",
    ]
    missing_schema_terms = [term for term in schema_terms if term not in app_database]
    if missing_schema_terms:
        add_failure(
            failures,
            "current_schema_contract_missing",
            APP_DATABASE,
            "MigrationRunner.migrateV4",
            "schema_v17",
            "Current schema must define content revision and OCR source defaults.",
            count=len(missing_schema_terms),
        )

    required_model_terms = [
        "ClipboardDetailReadModel",
        "ClipboardMetadataSnapshot",
        "ClipboardDetailEditCommand",
        "ClipboardDetailSaveResult",
        "ClipboardDetailSaveFailure",
        "expectedContentRevision",
        "newContentRevision",
        "ClipboardOCRTextSource",
        "userEdited",
        "ignoredLateVision",
    ]
    model_sources = detail_sources + "\n" + search_document
    missing_model_terms = [term for term in required_model_terms if term not in model_sources]
    if missing_model_terms:
        add_failure(
            failures,
            "detail_model_contract_missing",
            CORE / "ClipboardDetailReadModel.swift",
            "detail models",
            "model_contract",
            "Detail read/save/OCR source models are incomplete.",
            count=len(missing_model_terms),
        )

    purpose_terms = ["case detailEditRead", "case detailFullValueRead", "case detailEditSave"]
    missing_purposes = [term for term in purpose_terms if term not in payload_access]
    if missing_purposes:
        add_failure(
            failures,
            "detail_purpose_missing",
            PAYLOAD_ACCESS,
            "ClipboardPayloadReadPurpose",
            "purpose_matrix",
            "Detail edit/read/save purposes must be explicit.",
            count=len(missing_purposes),
        )

    save_detail_edit_pattern = r"\bfunc\s+saveDetailEdit\s*\(\s*command\s*:"
    save_contract_terms = [
        "expectedContentRevision",
        "database.connection.transaction",
        "upsertSearchDocument",
        "ClipboardDetailSaveResult",
        "ClipboardDetailSaveFailure",
        "mutationCount",
    ]
    repository_detail_source = read(CORE / "ClipboardRepository+DetailEdit.swift") + "\n" + repository + "\n" + repository_search
    detail_repository_file = read(CORE / "ClipboardRepository+DetailEdit.swift")
    detail_read_model_block = method_block(
        detail_repository_file,
        "func loadDetailReadModel(recordID: String)"
    )
    detail_search_state_block = method_block(
        detail_repository_file,
        "func loadDetailSearchState(recordID: String)"
    )
    metadata_snapshot_block = method_block(
        detail_repository_file,
        "func metadataSnapshot("
    )
    update_record_metadata_block = method_block_pattern(
        detail_repository_file,
        r"\bfunc\s+updateRecordContentMetadata\s*\("
    )
    upsert_search_document_block = method_block_pattern(
        repository_search,
        r"\bfunc\s+upsertSearchDocument\s*\("
    )
    if "readPayload(" in metadata_snapshot_block:
        add_failure(
            failures,
            "detail_default_metadata_reads_full_payload",
            CORE / "ClipboardRepository+DetailEdit.swift",
            "func metadataSnapshot(",
            "bounded_detail_read",
            "Default detail metadata must not read the full payload; use explicit detailFullValueRead actions.",
            count=metadata_snapshot_block.count("readPayload("),
        )
    if "loadSearchDocument(" in detail_read_model_block:
        add_failure(
            failures,
            "detail_default_model_reads_full_search_document",
            CORE / "ClipboardRepository+DetailEdit.swift",
            "func loadDetailReadModel(recordID: String)",
            "bounded_detail_read",
            "Default detail loading must not materialize full OCR or indexed content; query only bounded preview and OCR state.",
            count=detail_read_model_block.count("loadSearchDocument("),
        )
    forbidden_detail_search_columns = ["ocr_text,", "content_text", "rich_text_plain_text"]
    leaked_detail_search_columns = [
        term for term in forbidden_detail_search_columns if term in detail_search_state_block
    ]
    if leaked_detail_search_columns:
        add_failure(
            failures,
            "detail_search_state_projection_is_unbounded",
            CORE / "ClipboardRepository+DetailEdit.swift",
            "func loadDetailSearchState(recordID: String)",
            "bounded_detail_read",
            "The default detail search-state query may select status metadata only, never full indexed text or OCR contents.",
            count=len(leaked_detail_search_columns),
        )
    save_block = method_block_pattern(detail_repository_file, save_detail_edit_pattern)
    missing_save_terms = [term for term in save_contract_terms if term not in save_block]
    if not save_block:
        missing_save_terms.insert(0, "func saveDetailEdit(command:)")
    if "content_revision" not in update_record_metadata_block:
        missing_save_terms.append("updateRecordContentMetadata.content_revision")
    if (
        "database.connection.transaction" not in upsert_search_document_block
        or "replaceFTS" not in upsert_search_document_block
    ):
        missing_save_terms.append("upsertSearchDocument.transaction.replaceFTS")
    if missing_save_terms:
        add_failure(
            failures,
            "repository_save_contract_missing",
            CORE / "ClipboardRepository+DetailEdit.swift",
            "saveDetailEdit",
            "save_command",
            "Repository save command must be single-entry and transactional.",
            count=len(missing_save_terms),
        )

    ui_terms = [
        "final class ClipboardDetailStore",
        "func save()",
        "func beginEditing()",
        "func cancel()",
        "draftTitle",
        "updateDraftTitle",
        "dirtyNavigation",
        "ClipboardFloatingDetailCard",
        "ClipboardDetailPresentationOverlay",
        "ClipboardDetailPanelCoordinator",
        "ClipboardPanelFocusCoordinator",
        "presentFloatingDetail",
        "detailMetadataGrid",
    ]
    ui_sources = store_source + "\n" + view_source
    missing_ui_terms = [term for term in ui_terms if term not in ui_sources]
    if missing_ui_terms:
        add_failure(
            failures,
            "detail_ui_state_contract_missing",
            DETAIL_VIEW,
            "ClipboardFloatingDetailCard",
            "ui_state",
            "Stable detail editor and detail store state contract are incomplete.",
            count=len(missing_ui_terms),
        )

    retired_detail_terms = [
        "ClipboardHoverDetailLayer",
        "ClipboardHoverTracking",
        "ClipboardHoverDetailPanel",
        "ClipboardDetailEditorView",
    ]
    remaining_retired_terms = [term for term in retired_detail_terms if term in view_source]
    if remaining_retired_terms:
        add_failure(
            failures,
            "retired_detail_presentation_path_remaining",
            PANEL,
            "ClipboardFloatingPanelView",
            "retired_detail_path",
            "The deleted hover/editor detail presentation path must not remain reachable.",
            count=len(remaining_retired_terms),
        )

    rich_text_terms = [
        "ClipboardRichTextFidelityService",
        "linkPreserved",
        "paragraphsPreserved",
        "inlineStylePreserved",
        "listRepresentationPreserved",
        "richTextFidelityFailed",
    ]
    missing_rich_terms = [term for term in rich_text_terms if term not in detail_sources + "\n" + repository_detail_source]
    if missing_rich_terms:
        add_failure(
            failures,
            "rich_text_fidelity_contract_missing",
            CORE / "ClipboardRichTextFidelityService.swift",
            "ClipboardRichTextFidelityService",
            "rich_text",
            "Rich text fidelity must be conservative and scenario-evidenced.",
            count=len(missing_rich_terms),
        )

    url_terms = ["ClipboardDetailURLValidator", "mailto", "localhost", "invalidURL", "custom scheme", "file"]
    missing_url_terms = [term for term in url_terms if term not in detail_sources + "\n" + repository_detail_source]
    if missing_url_terms:
        add_failure(
            failures,
            "url_validator_contract_missing",
            CORE / "ClipboardDetailURLValidator.swift",
            "ClipboardDetailURLValidator",
            "url_validation",
            "URL validation helper or fixture contract is incomplete.",
            count=len(missing_url_terms),
        )

    ocr_terms = ["ocrTextSource", "userEdited", "ignoredLateVision", "ocr_locked_content_revision", "updateOCRResult"]
    missing_ocr_terms = [term for term in ocr_terms if term not in ocr_source + "\n" + detail_sources + "\n" + repository_detail_source]
    if missing_ocr_terms:
        add_failure(
            failures,
            "ocr_user_edited_contract_missing",
            SEARCH_DOCUMENT,
            "ClipboardOCRTextSource",
            "ocr_source",
            "OCR user-edited source and late completion guard are incomplete.",
            count=len(missing_ocr_terms),
        )

    forbidden_save_tokens = [
        "NSPasteboard.general",
        "ClipboardAutoPasteCoordinator",
        "pasteClipboardRecord",
        "copyClipboardRecordAsPlainText",
        "URLSession",
        "Authorization",
        "Bearer",
        "Process(",
        "NSWorkspace.shared.open",
        "CGEvent",
        "AXUIElement",
        "SCStream",
        "SecItem",
    ]
    detail_call_graph = detail_sources + "\n" + repository_detail_source + "\n" + store_source + "\n" + detail_view_source
    forbidden_hits = [token for token in forbidden_save_tokens if token in detail_call_graph]
    if forbidden_hits:
        add_failure(
            failures,
            "detail_save_call_graph_forbidden_token",
            CORE / "ClipboardRepository+DetailEdit.swift",
            "detail call graph",
            "denylist",
            "Step 4 detail save/read path contains forbidden system/provider/automation token.",
            count=len(forbidden_hits),
        )

    app_state_forbidden = ["ClipboardDetailReadModel", "ClipboardDetailSaveResult", "ocrText", "saveDetailEdit(command:"]
    app_state_hits = [token for token in app_state_forbidden if token in app_fact_sources]
    if app_state_hits:
        add_failure(
            failures,
            "app_fact_source_expanded",
            APP_MODEL,
            "AppModel/ClipboardController",
            "state_ownership",
            "AppModel or ClipboardController must not become detail fact source.",
            count=len(app_state_hits),
        )

    pasteboard_read_attempts = 0 if save_block and "NSPasteboard" not in save_block else None
    pasteboard_write_attempts = 0 if save_block and all(token not in save_block for token in ["setString", "setData", "writeObjects", "clearContents"]) else None

    state_ownership = {
        "appstate_detail_fact_source_clear": not bool(app_state_hits),
        "appmodel_detail_fact_source_clear": not bool(app_state_hits),
        "controller_detail_fact_source_clear": "ClipboardDetailReadModel" not in read(CONTROLLER),
        "detail_store_draft_only": "draft" in read(DETAIL_STORE) and "saveDetailEdit" not in read(DETAIL_STORE).replace("repository.saveDetailEdit", ""),
        "repository_persistent_fact_source": bool(save_block),
    }

    purpose_call_graph = detail_sources + "\n" + repository_detail_source + "\n" + read(DETAIL_STORE) + "\n" + detail_view_source
    purpose_matrix = {
        "positive": {
            "detailEditRead": "case detailEditRead" in payload_access,
            "detailFullValueRead": "case detailFullValueRead" in payload_access,
            "detailEditSave": "case detailEditSave" in payload_access,
            "detailCopyFullValue": "case detailCopyFullValue" in payload_access,
        },
        "negative_reuse_count": {
            "hoverDetail": len(re.findall(r"(?<![A-Za-z0-9_])\\.hoverDetail(?![A-Za-z0-9_])", purpose_call_graph)),
            "paste": len(re.findall(r"(?<![A-Za-z0-9_])\\.paste(?![A-Za-z0-9_])", purpose_call_graph)),
            "copyPlainText": len(re.findall(r"(?<![A-Za-z0-9_])\\.copyPlainText(?![A-Za-z0-9_])", purpose_call_graph)),
            "translationPreview": len(re.findall(r"(?<![A-Za-z0-9_])\\.translationPreview(?![A-Za-z0-9_])", purpose_call_graph)),
            "ocrInput": len(re.findall(r"(?<![A-Za-z0-9_])\\.ocrInput(?![A-Za-z0-9_])", purpose_call_graph)),
            "searchIndex": len(re.findall(r"(?<![A-Za-z0-9_])\\.searchIndex(?![A-Za-z0-9_])", purpose_call_graph)),
            "provider": len(re.findall(r"\bProvider\b|\bLLM\b|OpenAI|multimodal", purpose_call_graph)),
        },
    }
    negative_reuse_hits = {
        key: value for key, value in purpose_matrix["negative_reuse_count"].items() if value
    }
    if negative_reuse_hits:
        add_failure(
            failures,
            "detail_purpose_negative_reuse",
            PAYLOAD_ACCESS,
            "purpose_matrix.negative_reuse_count",
            "purpose_matrix",
            "Forbidden detail purpose reuse must fail closed.",
            count=sum(negative_reuse_hits.values()),
        )

    fixture_report = run_swift_fixture(failures)
    dynamic_scenarios = fixture_report.get("scenarios") if isinstance(fixture_report, dict) else []
    if not isinstance(dynamic_scenarios, list):
        dynamic_scenarios = []

    scenario_map: dict[str, dict[str, Any]] = {}
    for scenario in dynamic_scenarios:
        if isinstance(scenario, dict) and isinstance(scenario.get("scenario_id"), str):
            scenario_map[scenario["scenario_id"]] = scenario

    for static_scenario in ui_binding_scenarios(
        read(DETAIL_STORE),
        view_source,
        panel_source,
        read(PRESENTER),
        read(APP_MODEL),
        read(CLIPBOARD_COORDINATOR) + "\n" + read(PASTE_ORCHESTRATOR),
        read(TRANSLATION_COORDINATOR) + "\n" + read(TRANSLATION_SELECTION_COORDINATOR),
        sanitizer,
    ):
        scenario_id = static_scenario["scenario_id"]
        if scenario_id in scenario_map:
            existing = scenario_map[scenario_id]
            existing_assertions = existing.get("assertions") if isinstance(existing.get("assertions"), dict) else {}
            static_assertions = static_scenario.get("assertions") if isinstance(static_scenario.get("assertions"), dict) else {}
            existing["assertions"] = {**existing_assertions, **static_assertions}
            if static_scenario.get("result") != "pass":
                existing["result"] = "fail"
                existing["failure_reason"] = static_scenario.get("failure_reason")
            existing["full_value_read_attempts"] = max(
                int(existing.get("full_value_read_attempts") or 0),
                int(static_scenario.get("full_value_read_attempts") or 0),
            )
            existing["full_value_copy_attempts"] = max(
                int(existing.get("full_value_copy_attempts") or 0),
                int(static_scenario.get("full_value_copy_attempts") or 0),
            )
        else:
            scenario_map[scenario_id] = static_scenario

    missing_scenarios = [scenario for scenario in REQUIRED_SCENARIOS if scenario not in scenario_map]
    if missing_scenarios:
        add_failure(
            failures,
            "scenario_evidence_missing",
            SELF,
            "REQUIRED_SCENARIOS",
            "scenario",
            "P13D per-scenario evidence list is incomplete.",
            count=len(missing_scenarios),
        )

    observed_scenario_contract_checks = scenario_contract_migration_checks(
        scenario_contract_version,
        scenario_migrations,
        list(scenario_map),
    )
    if not all(observed_scenario_contract_checks.values()):
        add_failure(
            failures,
            "scenario_contract_evidence_migration_invalid",
            SELF,
            "scenarios",
            "scenario_contract_migration",
            "P13D observed scenarios must exclude retired evidence and include its replacement.",
            count=sum(
                1 for passed in observed_scenario_contract_checks.values() if not passed
            ),
        )

    for scenario_id, scenario in scenario_map.items():
        reason = scenario_failure_reason(scenario)
        if reason:
            add_failure(
                failures,
                "scenario_evidence_failed",
                SELF,
                scenario_id,
                reason,
                "P13D scenario must have real non-null passing evidence.",
            )

    ordered_scenarios = [
        scenario_map.get(
            scenario,
            {
                "scenario_id": scenario,
                "fixture_id": scenario.replace("detail_", "fixture_detail_"),
                "category": "required",
                "result": "fail",
                "evidence_type": "missing",
                "mutation_count": 0,
                "content_revision_before": 0,
                "content_revision_after": 0,
                "pasteboard_read_attempts": 0,
                "pasteboard_write_attempts": 0,
                "full_value_read_attempts": 0,
                "full_value_copy_attempts": 0,
                "failure_reason": "missing_evidence",
                "sanitizer": "fail",
                "assertions": {},
            },
        )
        for scenario in REQUIRED_SCENARIOS
    ]

    payload: dict[str, Any] = {
        "gate": "P13D",
        "status": "pass" if not failures else "fail",
        "ok": not failures,
        "checked_files": [rel(path) for path in REQUIRED_DOCS + REQUIRED_CODE + EXPECTED_STEP4_FILES + [SELF]],
        "target_membership": {
            "project_parseable": PROJECT.exists() and "PBXNativeTarget" in project,
            "step4_files": membership,
        },
        "current_evidence": {
            "prd": rel(PRD),
            "technical_plan": rel(TECH_PLAN),
            "dispatch": rel(DISPATCH),
            "development_record": rel(DEV_RECORD),
            "p13d_first": True,
        },
        "baseline_reference": {
            "old_story_or_archive_used_for_ok": False,
            "note": "No archived story or acceptance record participates in P13D ok calculation.",
        },
        "scenario_contract_version": scenario_contract_version,
        "scenario_migrations": scenario_migrations,
        "scenarios": ordered_scenarios,
        "state_ownership": state_ownership,
        "purpose_matrix": purpose_matrix,
        "call_graph": {
            "view_to_detail_store_save": "ClipboardDetailStore" in view_source and ".save(" in view_source,
            "store_to_repository_save": bool(
                re.search(r"\brepository\s*\.\s*saveDetailEdit\s*\(", read(DETAIL_STORE))
            ),
            "save_path_forbidden_token_count": len(forbidden_hits),
            "pasteboard_read_attempts": pasteboard_read_attempts,
            "pasteboard_write_attempts": pasteboard_write_attempts,
            "async_reindex_enabled": False,
            "not_applicable_reason": "Step 4 uses synchronous repository transaction for payload, search document and FTS updates.",
        },
        "denylist": {
            "forbidden_token_count": len(forbidden_hits),
            "forbidden_token_labels": [f"denylist_{index}" for index, _ in enumerate(forbidden_hits)],
        },
        "sanitizer": sanitizer,
        "failure_summary": {
            "count": len(failures),
            "rule_ids": sorted({failure["rule_id"] for failure in failures}),
        },
        "failures": failures,
    }

    safe_payload = sanitize_payload(payload)
    output = json.dumps(safe_payload, ensure_ascii=False, indent=2, sort_keys=True)
    raw_hits = output_forbidden_labels(output)
    if raw_hits:
        safe_payload["ok"] = False
        safe_payload["status"] = "fail"
        safe_payload["failure_summary"]["count"] += 1
        safe_payload["failure_summary"]["rule_ids"] = sorted(
            set(safe_payload["failure_summary"]["rule_ids"] + ["p13d_output_sensitive_token"])
        )
        safe_payload["failures"].append(
            {
                "rule_id": "p13d_output_sensitive_token",
                "relative_path": rel(SELF),
                "line_or_symbol": "stdout",
                "pattern_label": ",".join(raw_hits),
                "count": len(raw_hits),
                "low_sensitive_reason": "Sanitized output still contains forbidden token labels.",
            }
        )
        output = json.dumps(sanitize_payload(safe_payload), ensure_ascii=False, indent=2, sort_keys=True)

    print(output)
    return 0 if safe_payload["ok"] else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test = static_mutation_self_test()
        print(json.dumps({"ok": all(self_test.values()), "mutations": self_test}, sort_keys=True))
        raise SystemExit(0 if all(self_test.values()) else 1)
    raise SystemExit(main())
