#!/usr/bin/env python3
"""P13-A baseline gate for clipboard plaintext preview, search, and OCR."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import textwrap
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_payload, sanitize_text, sanitizer_self_check


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"

SELF = ROOT / "tools" / "verification" / "p13a_clipboard_plaintext_search_ocr_checks.py"
PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "产品经理-PRD-v1.md"
PRD_REVIEW = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-PRD-v1复核-v0.md"
TECH_PLAN = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "App架构师-技术方案-v1.md"
TECH_REVIEW = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-技术方案-v1复核-v0.md"
BASELINE_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1A-0-v0.md"
STEP1A_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1A-v0.md"
STEP1A_ACCEPTANCE = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-Step1A验收-v0.md"
STEP1A_DEV_RECORD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "开发记录-Step1A-v0.md"
STEP1B_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1B-v0.md"
STEP1B_ACCEPTANCE = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-Step1B验收-v0.md"
STEP1B_DEV_RECORD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "开发记录-Step1B-v0.md"
STEP1C_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1C-v0.md"
STEP1C1D_SUPPLEMENT = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1C-1D补充-v0.md"
STEP4D_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4D-ClipboardHardening-v0.md"

APP_DATABASE = CORE / "AppDatabase.swift"
REPOSITORY = CORE / "ClipboardRepository.swift"
STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
HISTORY_READ_PIPELINE = APP / "Features" / "Clipboard" / "ClipboardHistoryReadPipeline.swift"
RECORD_ACTION_PIPELINE = APP / "Features" / "Clipboard" / "ClipboardRecordActionPipeline.swift"
PAYLOAD_ACCESS = APP / "Features" / "Clipboard" / "ClipboardPayloadAccess.swift"
READ_MODEL = APP / "Features" / "Clipboard" / "ClipboardReadModel.swift"
CONTROLLER = APP / "Stores" / "ClipboardController.swift"
PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
DETAIL_PRESENTATION_SWIFT_FILES = [
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationLayer.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationView.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPanel.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift",
]
SETTINGS = APP / "Features" / "Settings" / "ClipboardSettingsPane.swift"
DATA_AUDIT = APP / "Features" / "Settings" / "DataAuditSettingsPane.swift"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"

STEP1A_SWIFT_FILES = [
    CORE / "ClipboardSearchDocument.swift",
    CORE / "ClipboardSearchDocumentBuilder.swift",
    CORE / "ClipboardRepository+SearchDocuments.swift",
    PAYLOAD_ACCESS,
]

STEP1B_SWIFT_FILES = [
    APP / "Features" / "Clipboard" / "ClipboardSearchCoordinator.swift",
]

FUTURE_STEP_SWIFT_FILES = [
    APP / "Features" / "Clipboard" / "ClipboardVisionTextRecognizer.swift",
    APP / "Features" / "Clipboard" / "ClipboardVisionOCRQueue.swift",
    APP / "Features" / "OCR" / "LocalVisionOCRService.swift",
]

EXPECTED_SWIFT_FILES = (
    STEP1A_SWIFT_FILES
    + STEP1B_SWIFT_FILES
    + FUTURE_STEP_SWIFT_FILES
    + DETAIL_PRESENTATION_SWIFT_FILES
)

CURRENT_PAYLOAD_READ_PURPOSES = [
    "previewBuild",
    "searchIndex",
    "ocrInput",
    "imagePreview",
    "paste",
    "copyPlainText",
    "translationPreview",
    "detailEditRead",
    "detailFullValueRead",
    "detailEditSave",
    "detailCopyFullValue",
]

REQUIRED_DOCS = [
    PRD,
    PRD_REVIEW,
    TECH_PLAN,
    TECH_REVIEW,
    BASELINE_DISPATCH,
    STEP1A_DISPATCH,
    STEP1A_ACCEPTANCE,
    STEP1A_DEV_RECORD,
    STEP1B_DISPATCH,
    STEP1B_ACCEPTANCE,
    STEP1B_DEV_RECORD,
    STEP1C_DISPATCH,
    STEP1C1D_SUPPLEMENT,
]
REQUIRED_CODE = [
    APP_DATABASE,
    REPOSITORY,
    STORE,
    HISTORY_READ_PIPELINE,
    RECORD_ACTION_PIPELINE,
    PAYLOAD_ACCESS,
    READ_MODEL,
    CONTROLLER,
    PANEL,
    *DETAIL_PRESENTATION_SWIFT_FILES,
    SETTINGS,
    DATA_AUDIT,
    PROJECT,
]

URL_QUERY_RE = re.compile(r"https?://[^\s\"'<>]+\\?[^\s\"'<>]+")
DATA_IMAGE_RE = re.compile(r"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+")
BASE64_BLOB_RE = re.compile(r"\b[A-Za-z0-9+/]{80,}={0,2}\b")
AUTH_HEADER_RE = re.compile(
    r"\bAuthorization\b\s*[:=]\s*(?:Bearer|Basic)?\s*[^\s,;}]+|\b(?:Bearer|Basic)\s+[^\s,;}]+",
    re.IGNORECASE,
)
SECRET_RE = re.compile(
    r"\b(?:sk-proj|sk_proj|sk|api_key|access_token|refresh_token|id_token|password|passwd|pwd|otp|jwt|cookie|session)[-_A-Za-z0-9]*\b",
    re.IGNORECASE,
)
FULL_OCR_RE = re.compile(r"\b(?:ocrText|fullOCRText)\b\s*[:=]\s*[^\n,;}]+")


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return sanitize_text(path)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def method_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    open_index = source.find("{", start)
    if open_index < 0:
        return ""
    depth = 0
    for index in range(open_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


OCR_LAYOUT_FIXTURE = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "P13AOCRLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct P13AOCRLayoutFixture {
    static func main() throws {
        let horizontalColumns = [
            LocalVisionOCRLayoutBox(index: 0, boundingBox: CGRect(x: 0.58, y: 0.72, width: 0.30, height: 0.08), text: "R1"),
            LocalVisionOCRLayoutBox(index: 1, boundingBox: CGRect(x: 0.08, y: 0.72, width: 0.30, height: 0.08), text: "L1"),
            LocalVisionOCRLayoutBox(index: 2, boundingBox: CGRect(x: 0.58, y: 0.52, width: 0.30, height: 0.08), text: "R2"),
            LocalVisionOCRLayoutBox(index: 3, boundingBox: CGRect(x: 0.08, y: 0.52, width: 0.30, height: 0.08), text: "L2"),
        ]
        try require(
            LocalVisionOCRReadingOrder.orderedIndices(horizontalColumns) == [1, 3, 0, 2],
            "horizontal columns must read the left column before the right column"
        )

        let verticalJapanese = [
            LocalVisionOCRLayoutBox(index: 0, boundingBox: CGRect(x: 0.62, y: 0.45, width: 0.08, height: 0.18), text: "本"),
            LocalVisionOCRLayoutBox(index: 1, boundingBox: CGRect(x: 0.82, y: 0.70, width: 0.08, height: 0.18), text: "日"),
            LocalVisionOCRLayoutBox(index: 2, boundingBox: CGRect(x: 0.62, y: 0.70, width: 0.08, height: 0.18), text: "語"),
            LocalVisionOCRLayoutBox(index: 3, boundingBox: CGRect(x: 0.82, y: 0.45, width: 0.08, height: 0.18), text: "縦"),
        ]
        try require(
            LocalVisionOCRReadingOrder.orderedIndices(verticalJapanese) == [1, 3, 2, 0],
            "vertical Japanese must read top-to-bottom and columns right-to-left"
        )

        print("P13A_OCR_LAYOUT_OK")
    }
}
'''


def run_ocr_layout_fixture() -> tuple[bool, str]:
    recognizer = APP / "Features" / "OCR" / "LocalVisionOCRService.swift"
    with tempfile.TemporaryDirectory(prefix="blocks_p13a_ocr_layout_") as temporary:
        temp = Path(temporary)
        fixture = temp / "P13AOCRLayoutFixture.swift"
        fixture.write_text(textwrap.dedent(OCR_LAYOUT_FIXTURE), encoding="utf-8")
        executable = temp / "P13AOCRLayoutFixture"
        compiled = subprocess.run(
            [
                "xcrun", "--sdk", "macosx", "swiftc",
                str(recognizer), str(fixture),
                "-framework", "Vision",
                "-framework", "ImageIO",
                "-framework", "CoreGraphics",
                "-o", str(executable),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if compiled.returncode:
            return False, "fixture_compile"
        executed = subprocess.run(
            [str(executable)],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if executed.returncode or "P13A_OCR_LAYOUT_OK" not in executed.stdout:
            return False, "fixture_execution"
        return True, "ok"


def p13a_sanitize_text(value: object) -> str:
    text = "" if value is None else str(value)
    text = URL_QUERY_RE.sub("<URL_WITH_QUERY>", text)
    text = DATA_IMAGE_RE.sub("<DATA_IMAGE>", text)
    text = AUTH_HEADER_RE.sub("<AUTH_HEADER>", text)
    text = FULL_OCR_RE.sub("<OCR_TEXT_FIELD>", text)
    text = SECRET_RE.sub("<SECRET>", text)
    text = BASE64_BLOB_RE.sub(redact_base64_blob, text)
    return sanitize_text(text)


def redact_base64_blob(match: re.Match[str]) -> str:
    candidate = match.group(0)
    if candidate.startswith(("apps/", "docs/", "tools/")):
        return candidate
    return "<BASE64>"


def p13a_sanitize_payload(value: Any) -> Any:
    return sanitize_payload(_map_strings(value, p13a_sanitize_text))


def _map_strings(value: Any, transform) -> Any:
    if isinstance(value, dict):
        return {transform(key): _map_strings(item, transform) for key, item in value.items()}
    if isinstance(value, list):
        return [_map_strings(item, transform) for item in value]
    if isinstance(value, tuple):
        return [_map_strings(item, transform) for item in value]
    if isinstance(value, str):
        return transform(value)
    return value


def add_failure(failures: list[dict[str, Any]], code: str, detail: str, path: Path | None = None) -> None:
    item: dict[str, Any] = {
        "code": code,
        "detail": detail,
    }
    if path is not None:
        item["path"] = rel(path)
    failures.append(item)


def token_presence(source: str, tokens: list[str]) -> dict[str, bool]:
    return {token: token in source for token in tokens}


def payload_read_purpose_cases(source: str) -> list[str]:
    purpose_block = method_block(source, "enum ClipboardPayloadReadPurpose")
    return re.findall(r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*$", purpose_block, re.MULTILINE)


def target_membership(project: str, paths: list[Path]) -> dict[str, bool]:
    membership: dict[str, bool] = {}
    for path in paths:
        membership[rel(path)] = (
            path.name in project
            and f"{path.name} in Sources" in project
            and ("PBXNativeTarget" in project)
        )
    return membership


def sanitizer_contract_check() -> dict[str, Any]:
    shared = sanitizer_self_check()
    sample = "\n".join(
        [
            "https://example.com/blocks/clipboard-step1?token=fixture-secret",
            "file:///Users/example/Documents/Report-004.pdf",
            "Authorization: Bearer sample-secret",
            "ocrText: VISION-004 plus a longer sensitive OCR sentence",
            "data:image/png;base64," + "A" * 96,
            "sk-proj-sample-secret",
        ]
    )
    redacted = p13a_sanitize_text(sample)
    forbidden = [
        "fixture-secret",
        "Authorization: Bearer",
        "VISION-004 plus a longer sensitive OCR sentence",
        "data:image/png;base64",
        "sk-proj-sample-secret",
        "/Users/example",
    ]
    required = ["<URL_WITH_QUERY>", "<AUTH_HEADER>", "<OCR_TEXT_FIELD>", "<DATA_IMAGE>", "<SECRET>", "<PATH>"]
    failures = [f"forbidden_sample:{index}" for index, item in enumerate(forbidden) if item in redacted]
    failures.extend(f"missing_marker:{item}" for item in required if item not in redacted)
    return {
        "ok": bool(shared.get("ok")) and not failures,
        "shared_ok": bool(shared.get("ok")),
        "failures": list(shared.get("failures", [])) + failures,
    }


def output_forbidden_hits(output: str) -> list[str]:
    checks = {
        "root_path": str(ROOT),
        "home_path": str(Path.home()),
        "users_path": "/Users/",
        "file_users_url": "file:///Users/",
        "auth_header": "Authorization: Bearer",
        "data_image": "data:image",
        "sample_secret": "sk-proj-sample-secret",
        "url_query_secret": "fixture-secret",
    }
    return [label for label, token in checks.items() if token and token in output]


def main() -> int:
    failures: list[dict[str, Any]] = []

    for path in REQUIRED_DOCS + REQUIRED_CODE + [SELF]:
        if not path.exists():
            add_failure(failures, "missing_required_file", "required current evidence file missing", path)

    if not SELF.exists() or not os.access(SELF, os.X_OK):
        add_failure(failures, "p13a_not_executable", "script must be directly executable", SELF)

    sanitizer_check = sanitizer_contract_check()
    if not sanitizer_check["ok"]:
        add_failure(failures, "sanitizer_contract_failed", "P13A sanitizer self-check failed", SELF)

    app_database = read(APP_DATABASE)
    repository = read(REPOSITORY)
    store = read(STORE)
    payload_access = read(PAYLOAD_ACCESS)
    controller = read(CONTROLLER)
    settings = read(SETTINGS)
    data_audit = read(DATA_AUDIT)
    localizable = read(LOCALIZABLE)
    project = read(PROJECT)
    ocr_layout_ok, ocr_layout_failure = run_ocr_layout_fixture()

    search_doc_sources = "\n".join(read(path) for path in EXPECTED_SWIFT_FILES if path.exists())
    expected_type_tokens = [
        "ClipboardSearchDocument",
        "ClipboardContentPreviewSnapshot",
        "ClipboardOCRState",
        "ClipboardSearchResultState",
    ]
    type_presence = token_presence(search_doc_sources, expected_type_tokens)
    missing_types = [token for token, present in type_presence.items() if not present]
    if missing_types:
        add_failure(failures, "search_document_types_missing", "search document, preview snapshot, or OCR state type missing")

    missing_swift_files = [rel(path) for path in STEP1A_SWIFT_FILES if not path.exists()]
    if missing_swift_files:
        add_failure(failures, "expected_step1a_swift_files_missing", f"{len(missing_swift_files)} expected Step 1A files missing")

    missing_step1b_files = [rel(path) for path in STEP1B_SWIFT_FILES if not path.exists()]
    if missing_step1b_files:
        add_failure(failures, "expected_step1b_swift_files_missing", f"{len(missing_step1b_files)} expected Step 1B files missing")

    missing_step1c_files = [rel(path) for path in FUTURE_STEP_SWIFT_FILES if not path.exists()]
    if missing_step1c_files:
        add_failure(failures, "expected_step1c_swift_files_missing", f"{len(missing_step1c_files)} expected Step 1C files missing")

    membership = target_membership(project, EXPECTED_SWIFT_FILES)
    if project and not all(membership.values()):
        add_failure(
            failures,
            "target_membership_missing",
            "expected Step 1A/1B/1C and current detail presentation Swift files are not all in the Xcode project",
            PROJECT,
        )

    if "ClipboardSearchDocumentBuilder" not in search_doc_sources:
        add_failure(failures, "search_document_builder_missing", "builder single-entry point missing")

    if "clipboard_search_documents" not in app_database + repository:
        add_failure(failures, "search_documents_schema_missing", "search document storage schema missing", APP_DATABASE)

    if "currentVersion > 1" in app_database and "PRAGMA user_version = 2" not in app_database:
        add_failure(failures, "schema_v2_migration_missing", "database migration still rejects versions above v1", APP_DATABASE)

    if "private func searchText(for record:" in repository and "ClipboardSearchDocumentBuilder" not in repository:
        add_failure(failures, "legacy_search_text_builder_active", "repository still has independent legacy search text builder", REPOSITORY)

    if "try insertRecord(resolvedRecord, searchText:" in repository:
        add_failure(failures, "insert_writes_legacy_search_text", "insert path still writes legacy search text directly", REPOSITORY)

    if "INSERT INTO clipboard_fts" in repository and "ClipboardSearchDocument" not in repository:
        add_failure(failures, "fts_not_projected_from_search_document", "FTS write path is not tied to search document projection", REPOSITORY)

    preview_block = method_block(store, "func preview(for record:")
    if "redactedPreview" in preview_block:
        add_failure(failures, "store_preview_uses_redacted_preview", "ClipboardStore preview still uses redacted preview", STORE)

    filtered_block = method_block(controller, "static func filteredRecords")
    filtered_tokens = ["redactedSearchableText", "preview.searchableText", "pinnedMetadata", "pinboardName", "filterState"]
    if filtered_block and "query" in filtered_block and any(token in filtered_block for token in filtered_tokens):
        add_failure(failures, "visible_filter_search_path_active", "non-empty search still uses visible/redacted/filter metadata path", CONTROLLER)

    panel = read(PANEL)
    if "clipboardStore.filteredRecords(query: query" in panel:
        add_failure(failures, "panel_uses_store_filtered_records_for_query", "panel query path still uses store visible filtering", PANEL)
    if "clipboardStore.searchResult(query:" in panel:
        add_failure(failures, "panel_body_calls_store_search_result", "panel body/computed path calls store searchResult directly", PANEL)

    step1b_source = "\n".join(read(path) for path in STEP1B_SWIFT_FILES if path.exists())
    if "ClipboardSearchCoordinator" not in step1b_source:
        add_failure(failures, "search_coordinator_missing", "Step 1B search coordinator missing")
    if "ClipboardSearchResultSet" not in search_doc_sources or "ClipboardSearchIndexActivity" not in search_doc_sources:
        add_failure(failures, "search_result_set_missing", "search result set or index activity model missing")
    history_read_pipeline = read(HISTORY_READ_PIPELINE)
    if not (
        "ClipboardHistoryReadPipeline" in store
        and "let snapshot = await pipeline.read(request)" in store
        and "repository.searchDocuments(query:" in history_read_pipeline
        and 'label: "app.blocks.clipboard.history-read"' in history_read_pipeline
    ):
        add_failure(failures, "store_repository_search_path_missing", "ClipboardStore non-empty search does not use the background repository read pipeline", STORE)
    record_action_pipeline = read(RECORD_ACTION_PIPELINE)
    if not (
        "ClipboardRecordActionPipeline" in store
        and "await recordActionPipeline.read(recordID:" in store
        and 'label: "app.blocks.clipboard.record-action"' in record_action_pipeline
        and "readPayloadForAction(" in store
        and "ClipboardRecordActionPipeline.swift" in project
    ):
        add_failure(
            failures,
            "record_action_payload_read_not_background",
            "paste payload reads must use the single background record action pipeline",
            RECORD_ACTION_PIPELINE,
        )
    if "currentSearchResult" not in store or "refreshSearchResult(query:" not in store:
        add_failure(failures, "store_search_state_refresh_missing", "ClipboardStore search state is not exposed through explicit refresh/current result", STORE)
    if "@Published private var previewSnapshots" in store or "@Published private(set) var previewSnapshots" in store:
        add_failure(failures, "search_preview_cache_published", "search preview snapshot cache is still @Published", STORE)
    if "ClipboardSearchCoordinator.presentation" not in panel:
        add_failure(failures, "search_state_ui_missing", "panel search state presentation missing", PANEL)
    if "searchStatusBanner" in panel or "inlineSearchStatus" in panel:
        add_failure(failures, "search_partial_results_banner_present", "panel must not insert partial search result banner above non-empty results", PANEL)
    state_keys = [
        "clipboard.search.state.empty.title",
        "clipboard.search.state.emptyIndexing.title",
        "clipboard.search.state.partialIndexing.title",
        "clipboard.search.state.failed.title",
    ]
    missing_state_keys = [token for token in state_keys if token not in localizable + read(PANEL) + step1b_source]
    if missing_state_keys:
        add_failure(failures, "search_state_localization_missing", "search state localization keys missing", LOCALIZABLE)
    builder = read(CORE / "ClipboardSearchDocumentBuilder.swift")
    repository_search = read(CORE / "ClipboardRepository.swift")
    required_builder_tokens = ["image", "img", "ima", "pic", "picture", "photo", "图片", "图", "照片"]
    required_query_time_tokens = ["today", "yesterday", "今天", "昨天"]
    missing_search_tokens = [token for token in required_builder_tokens if token not in builder]
    missing_search_tokens += [token for token in required_query_time_tokens if token not in repository_search]
    if "record.lastCopiedAt" not in builder or "expandedRelativeDateQuery" not in repository_search:
        missing_search_tokens.append("lastCopiedAt_relative_query_contract")
    if missing_search_tokens:
        add_failure(failures, "search_field_tokens_missing", f"{len(missing_search_tokens)} required Step 1B search tokens missing")

    payload_purpose_cases = payload_read_purpose_cases(payload_access)
    if payload_purpose_cases != CURRENT_PAYLOAD_READ_PURPOSES:
        add_failure(
            failures,
            "content_access_purpose_matrix_mismatch",
            "payload read purposes must exactly match the current preview/search/OCR/action/detail matrix",
            PAYLOAD_ACCESS,
        )
    if "hoverDetail" in payload_purpose_cases:
        add_failure(
            failures,
            "retired_hover_detail_purpose_active",
            "payload access must not restore the retired hover-detail classification",
            PAYLOAD_ACCESS,
        )

    detail_presentation = "\n".join(read(path) for path in DETAIL_PRESENTATION_SWIFT_FILES)
    required_detail_tokens = [
        "ClipboardDetailPresentationOverlay",
        "ClipboardDetailPresentationView",
        "ClipboardDetailPanelCoordinator",
        "ClipboardDetailPanel",
        "ClipboardFloatingDetailCard",
    ]
    missing_detail_tokens = [token for token in required_detail_tokens if token not in detail_presentation]
    if missing_detail_tokens:
        add_failure(
            failures,
            "detail_presentation_single_track_missing",
            "current detached detail presentation layer/view/panel/card path is incomplete",
            DETAIL_PRESENTATION_SWIFT_FILES[0],
        )

    ocr_source = "\n".join(read(path) for path in EXPECTED_SWIFT_FILES if "Vision" in path.name or "OCR" in path.name)
    if "protocol ClipboardVisionTextRecognizer" not in ocr_source:
        add_failure(failures, "ocr_recognizer_protocol_missing", "Vision OCR recognizer protocol missing")
    if "VNRecognizeTextRequest" not in ocr_source:
        add_failure(failures, "apple_vision_implementation_missing", "Apple Vision implementation missing")
    if "MockVision" not in ocr_source and "MockClipboardVision" not in ocr_source:
        add_failure(failures, "ocr_mock_missing", "deterministic OCR mock missing")
    if "ClipboardVisionOCRQueue" not in ocr_source or "updateOCRResult" not in ocr_source:
        add_failure(failures, "ocr_queue_missing", "OCR queue or repository OCR update integration missing")
    if "readPayload(recordID:" not in ocr_source or ".ocrInput" not in ocr_source:
        add_failure(failures, "ocr_input_purpose_missing", "OCR queue must read existing image payload through explicit ocrInput purpose")
    if "retryOCR" not in store + panel + ocr_source or "clipboard.ocr.retry" not in localizable + panel + ocr_source:
        add_failure(failures, "ocr_retry_ui_missing", "row-level OCR retry action contract missing", PANEL)
    if not all(token in ocr_source for token in ["pending", "running", "succeeded", "failed"]):
        add_failure(failures, "ocr_state_transitions_missing", "OCR pending/running/succeeded/failed transitions are not all represented")
    if "runningHold" not in ocr_source and "holdRunning" not in ocr_source:
        add_failure(failures, "ocr_mock_running_hold_missing", "deterministic mock lacks running hold control")
    required_quality_tokens = [
        "automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage",
        "supportedRecognitionLanguages",
        '"zh-Hans"',
        '"zh-Hant"',
        '"en-US"',
        '"ja-JP"',
        "CGImagePropertyOrientation",
        "orientation: Self.imageOrientation(from: source)",
        "LocalVisionOCRReadingOrder.orderedIndices",
    ]
    missing_quality_tokens = [token for token in required_quality_tokens if token not in ocr_source]
    if missing_quality_tokens:
        add_failure(failures, "ocr_multilingual_orientation_ordering_missing", ", ".join(missing_quality_tokens))
    if not ocr_layout_ok:
        add_failure(failures, "ocr_layout_fixture_failed", ocr_layout_failure)
    if "refreshPresentedOCRIfNeeded" not in store:
        add_failure(failures, "ocr_open_detail_refresh_missing", "completed OCR must refresh a visible clean detail")
    forbidden_ocr_tokens = [
        "URLSession",
        "Authorization",
        "Bearer",
        "NSWorkspace",
        "NSPasteboard.general",
        "Process(",
        "getenv(",
        "SecItem",
        "CGEvent",
        "AXUIElement",
        "SCStream",
        "contentsOfDirectory",
    ]
    forbidden_ocr_hits = [token for token in forbidden_ocr_tokens if token in ocr_source]
    if forbidden_ocr_hits:
        add_failure(failures, "ocr_forbidden_boundary_token", f"{len(forbidden_ocr_hits)} forbidden OCR boundary tokens present")

    if "import Vision" in read(CORE / "ClipboardSearchDocument.swift") + read(CORE / "ClipboardSearchDocumentBuilder.swift"):
        add_failure(failures, "vision_import_in_core", "BlocksCore search document files must not import Vision")

    settings_tokens = [
        "settings.clipboardHardening.storage",
        "settings.clipboardHardening.redactedPolicy",
        "settings.clipboardHardening.redactedPolicyDetail",
        "settings.clipboardHardening.allowlist",
        "settings.clipboardHardening.allowlistDetail",
        "clipboard.hardening.state.redacted.title",
        "clipboard.hardening.state.redacted.detail",
    ]
    active_sources = settings + data_audit + panel
    active_settings_hits = [token for token in settings_tokens if token in active_sources]
    negative_ui_phrases = [
        "redacted preview",
        "payload 不可见",
        "只显示字符数",
        "只显示长度",
        "隐藏摘要",
        "metadata-first",
    ]
    active_phrase_hits = [phrase for phrase in negative_ui_phrases if phrase in active_sources]
    active_settings_hits.extend(active_phrase_hits)
    if active_settings_hits:
        add_failure(failures, "settings_hardening_negative_tokens_active", f"{len(active_settings_hits)} active hardening/redacted setting tokens remain", SETTINGS)

    repository_summary_block = method_block(store, "func repositoryStateSummary()")
    if ".redacted(recordCount:" in repository_summary_block or "clipboard.hardening.state.redacted" in repository_summary_block:
        add_failure(
            failures,
            "repository_summary_active_redacted_state",
            "Settings/DataAudit repository summary must not resolve normal records through redacted state",
            STORE
        )
    if repository_summary_block and ".normal(recordCount: records.count)" not in repository_summary_block:
        add_failure(
            failures,
            "repository_summary_normal_state_missing",
            "normal repository summary path must use normal storage/index/content-access semantics",
            STORE
        )

    localization_only_hits = [token for token in settings_tokens if token in localizable]

    step1_candidate_sources = "\n".join(read(path) for path in EXPECTED_SWIFT_FILES if path.exists())
    forbidden_action_patterns = {
        "url_session": r"\bURLSession\b",
        "auth_header": r"setValue\([^)]*forHTTPHeaderField:\s*\"Authorization\"",
        "image_upload": r"multipart|imageUpload|uploadImage|data:image",
        "provider_call": r"Provider|LLM|OpenAI|multimodal",
        "system_settings": r"NSWorkspace\.shared\.open|CGRequestScreenCaptureAccess|AXIsProcessTrusted|NSAppleScript|CGEvent",
        "pasteboard": r"NSPasteboard\.general",
    }
    forbidden_action_hits = [
        label for label, pattern in forbidden_action_patterns.items()
        if re.search(pattern, step1_candidate_sources)
    ]
    if forbidden_action_hits:
        add_failure(failures, "step1_forbidden_action_tokens", f"{len(forbidden_action_hits)} forbidden Step 1 action token groups found")

    has_search_states = all(token in search_doc_sources for token in ["idle", "results", "emptyIndexing", "partialIndexing", "failed"])
    if not has_search_states:
        add_failure(failures, "search_result_states_missing", "search result states not present")

    repository_consistency_terms = [
        "upsertSearchDocument",
        "deleteSearchDocuments",
        "markSearchDocumentRedacted",
        "updateOCRResult",
        "rebuildSearchDocuments",
    ]
    consistency_presence = token_presence(repository + search_doc_sources, repository_consistency_terms)
    if not all(consistency_presence.values()):
        add_failure(failures, "repository_search_document_lifecycle_missing", "repository lifecycle APIs for search/OCR consistency missing", REPOSITORY)

    output_rules = {
        "json_schema": ["ok", "failures", "current_evidence", "baseline_reference", "checked_files", "rules"],
        "sensitive_output": ["relative_path_only", "no_real_payload", "no_full_url_query", "no_full_file_path", "no_full_ocr_text", "no_base64", "no_secret"],
        "scope": ["step1_current_implementation", "step1c_ocr_runtime", "step1d_settings_cleanup", "no_real_clipboard", "no_real_ocr", "no_provider", "no_tcc", "implementation_green_expected"],
    }

    checked_files = [rel(path) for path in REQUIRED_DOCS + REQUIRED_CODE + [SELF] + EXPECTED_SWIFT_FILES]
    current_evidence = {
        "source_docs": [rel(path) for path in REQUIRED_DOCS],
        "code_fact_sources": [rel(path) for path in [APP_DATABASE, REPOSITORY, STORE, HISTORY_READ_PIPELINE, RECORD_ACTION_PIPELINE, PAYLOAD_ACCESS, CONTROLLER, SETTINGS, DATA_AUDIT, PROJECT]],
        "step1a_expected_files_present_count": len([path for path in STEP1A_SWIFT_FILES if path.exists()]),
        "step1b_expected_files_present_count": len([path for path in STEP1B_SWIFT_FILES if path.exists()]),
        "step1c_expected_files_present_count": len([path for path in FUTURE_STEP_SWIFT_FILES if path.exists()]),
        "ocr_expected_files_present_count": len([path for path in FUTURE_STEP_SWIFT_FILES if path.exists()]),
        "detail_presentation_expected_files_present_count": len([path for path in DETAIL_PRESENTATION_SWIFT_FILES if path.exists()]),
        "payload_read_purpose_matrix": payload_purpose_cases,
        "retired_hover_detail_purpose_present": "hoverDetail" in payload_purpose_cases,
        "active_settings_hardening_token_count": len(active_settings_hits),
        "repository_summary_uses_normal_state": ".normal(recordCount: records.count)" in repository_summary_block,
        "localization_legacy_token_count": len(localization_only_hits),
    }
    baseline_reference = {
        "old_003_step4d_reference": rel(STEP4D_PRD) if STEP4D_PRD.exists() else None,
        "used_for_ok": False,
    }

    payload: dict[str, Any] = {
        "ok": not failures,
        "gate": "P13A",
        "phase": "Step1 implementation closure",
        "expected_baseline": "ok=true after Step 1C/1D merged implementation",
        "checked_files": checked_files,
        "target_membership": {
            "project_parseable": PROJECT.exists() and "PBXNativeTarget" in project,
            "expected_step1a_step1b_step1c_detail_presentation_files": membership,
        },
        "current_evidence": current_evidence,
        "baseline_reference": baseline_reference,
        "rules": output_rules,
        "sanitizer": sanitizer_check,
        "failure_summary": {
            "count": len(failures),
            "codes": sorted({failure["code"] for failure in failures}),
        },
        "failures": failures,
    }

    safe_payload = p13a_sanitize_payload(payload)
    output = json.dumps(safe_payload, ensure_ascii=False, indent=2, sort_keys=True)
    raw_hits = output_forbidden_hits(output)
    if raw_hits:
        safe_payload["ok"] = False
        safe_payload["failure_summary"]["count"] += 1
        safe_payload["failure_summary"]["codes"] = sorted(set(safe_payload["failure_summary"]["codes"] + ["p13a_output_sensitive_token"]))
        safe_payload["failures"].append(
            {
                "code": "p13a_output_sensitive_token",
                "detail": "sanitized output still contains forbidden token labels",
                "labels": raw_hits,
                "path": rel(SELF),
            }
        )
        output = json.dumps(p13a_sanitize_payload(safe_payload), ensure_ascii=False, indent=2, sort_keys=True)

    print(output)
    return 0 if safe_payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
