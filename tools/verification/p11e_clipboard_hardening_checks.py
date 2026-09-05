#!/usr/bin/env python3
"""P11-E clipboard output-boundary checks for 004 Step 1 + Step 2."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
APP_MODEL = APP / "App" / "AppModel.swift"
CLIPBOARD_STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
TAG_STORE = APP / "Features" / "Clipboard" / "ClipboardTagStore.swift"
PAYLOAD_ACCESS = APP / "Features" / "Clipboard" / "ClipboardPayloadAccess.swift"
READ_MODEL = APP / "Features" / "Clipboard" / "ClipboardReadModel.swift"
CONTROLLER = APP / "Stores" / "ClipboardController.swift"
PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
PANEL_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift",
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift",
]
FILTER_BAR = APP / "Views" / "ClipboardFilterBarView.swift"
FILTER_BAR_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Filters" / "ClipboardTagFilterChips.swift",
    APP / "Features" / "Clipboard" / "Filters" / "ClipboardFilterControls.swift",
]
RECORD_VIEWS = APP / "Views" / "ClipboardRecordViews.swift"
RECORD_VIEWS_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Records" / "ClipboardFloatingRecordRow.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordMenus.swift",
]
DETAIL_PRESENTATION = [
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationView.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationLayer.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPanel.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift",
]
LEGACY_HOVER = [
    APP / "Views" / "ClipboardHoverDetailLayer.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardHoverTracking.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardHoverDetailPanel.swift",
]
DETAIL_STORE = APP / "Features" / "Clipboard" / "ClipboardDetailStore.swift"
SETTINGS = APP / "Features" / "Settings" / "ClipboardSettingsPane.swift"
SETTINGS_EXTRACTED = [
    APP / "Features" / "Settings" / "ClipboardTagManagementSection.swift",
]
DATA_AUDIT = APP / "Features" / "Settings" / "DataAuditSettingsPane.swift"
VISION_RECOGNIZER = APP / "Features" / "Clipboard" / "ClipboardVisionTextRecognizer.swift"
OCR_QUEUE = APP / "Features" / "Clipboard" / "ClipboardVisionOCRQueue.swift"
LOCAL_OCR_SERVICE = APP / "Features" / "OCR" / "LocalVisionOCRService.swift"
LIVE_CAPTURE = APP / "Services" / "ClipboardLiveCaptureService.swift"
CLIPBOARD_BROKER = ROOT / "apps" / "Blocks" / "BlocksClipboardBroker"
HISTORY = APP / "Views" / "ClipboardHistoryView.swift"
RUNTIME_SERVICE = APP / "Services" / "ClipboardRecorderRuntimeService.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
STEP1_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "产品经理-PRD-v1.md"
STEP1_SUPPLEMENT = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1C-1D补充-v0.md"
STEP2_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "产品经理-PRD-v1.md"
STEP2_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "项目负责人-开发派发-Step2-v0.md"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def read_tree(path: Path) -> str:
    return "\n".join(
        child.read_text(encoding="utf-8")
        for child in sorted(path.rglob("*.swift"))
    ) if path.exists() else ""


def fail(failures: list[dict], code: str, detail: str, path: Path) -> None:
    failures.append({"code": code, "detail": detail, "path": rel(path)})


def method_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    open_index = source.find("{", start)
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


def has_explicit_detail_load(panel: str, detail_store: str) -> bool:
    present_block = method_block(panel, "private func presentFloatingDetail(recordID: String)")
    request_open_block = method_block(detail_store, "func requestOpen(recordID: String)")
    navigation_block = method_block(detail_store, "private func performNavigation(")
    load_block = method_block(detail_store, "private func loadRecord(recordID: String)")
    pipeline_load_block = method_block(
        detail_store,
        "func load(recordID: String) -> Result<ClipboardDetailReadModel, Error>",
    )
    return (
        "ClipboardPanelDetailPresentationLayer(" in panel
        and "clipboardStore.detailStore.requestOpen(recordID: recordID)" in present_block
        and "requestNavigation(.open(recordID: recordID))" in request_open_block
        and "case let .open(recordID):" in navigation_block
        and "loadRecord(recordID: recordID)" in navigation_block
        and "await pipeline.load(recordID: recordID)" in load_block
        and "repository.loadDetailReadModel(recordID: recordID)" in pipeline_load_block
    )


def has_reload_cache_invalidation_boundary(store: str) -> bool:
    load_block = method_block(store, "func loadRepositoryState(limit:")
    snapshot_block = method_block(store, "private func applyHistoryReadSnapshot(")
    prune_after_read_block = method_block(store, "private func pruneFilterAfterHistoryRead(")
    prune_payloads_block = method_block(store, "func prunePayloadsToCurrentRecords()")
    return (
        "refreshSearchResult(" in load_block
        and not any(token in load_block for token in ["readPayload", "loadPayloads", "payloadCache["])
        and "pruneFilterAfterHistoryRead(snapshot)" in snapshot_block
        and "prunePayloadsToCurrentRecords()" in prune_after_read_block
        and "let recordIDs = Set(records.map(\\.id))" in prune_payloads_block
        and "payloadCache = payloadCache.filter { recordIDs.contains($0.key.recordID) }" in prune_payloads_block
    )


def verify_fail_closed_mutations(panel: str, detail_store: str, store: str) -> list[str]:
    mutations = [
        (
            "detail_open_request",
            panel,
            "clipboardStore.detailStore.requestOpen(recordID: recordID)",
            lambda mutated: has_explicit_detail_load(mutated, detail_store),
        ),
        (
            "reload_cache_prune",
            store,
            "pruneFilterAfterHistoryRead(snapshot)",
            lambda mutated: has_reload_cache_invalidation_boundary(mutated),
        ),
    ]
    failures = []
    for name, source, required_call, still_passes in mutations:
        if required_call not in source:
            failures.append(f"{name}: key call absent before mutation")
        elif still_passes(source.replace(required_call, "", 1)):
            failures.append(f"{name}: deleting key call does not fail its contract")
    return failures


def main() -> int:
    failures: list[dict] = []
    required = [APP_MODEL, CLIPBOARD_STORE, TAG_STORE, PAYLOAD_ACCESS, READ_MODEL, CONTROLLER, PANEL, *PANEL_EXTRACTED, FILTER_BAR, *FILTER_BAR_EXTRACTED, RECORD_VIEWS, *RECORD_VIEWS_EXTRACTED, *DETAIL_PRESENTATION, DETAIL_STORE, SETTINGS, *SETTINGS_EXTRACTED, DATA_AUDIT, VISION_RECOGNIZER, OCR_QUEUE, LOCAL_OCR_SERVICE, LIVE_CAPTURE, CLIPBOARD_BROKER, PROJECT, STEP1_PRD, STEP1_SUPPLEMENT, STEP2_PRD, STEP2_DISPATCH]
    for path in required:
        if not path.exists():
            fail(failures, "missing_file", "required current fact source missing", path)

    if HISTORY.exists():
        fail(failures, "clipboard_history_view_remaining", "Unrouted legacy ClipboardHistoryView must be deleted", HISTORY)
    if RUNTIME_SERVICE.exists():
        fail(failures, "clipboard_runtime_service_remaining", "ClipboardRecorderRuntimeService must be deleted", RUNTIME_SERVICE)
    for path in LEGACY_HOVER:
        if path.exists():
            fail(failures, "legacy_hover_file_remaining", "superseded hover detail file must stay deleted", path)

    app_model = read(APP_MODEL)
    store = read(CLIPBOARD_STORE)
    tag_store = read(TAG_STORE)
    payload_access = read(PAYLOAD_ACCESS)
    read_model = read(READ_MODEL)
    controller = read(CONTROLLER)
    panel = "\n".join(read(path) for path in [PANEL, *PANEL_EXTRACTED])
    filter_bar = "\n".join(read(path) for path in [FILTER_BAR, *FILTER_BAR_EXTRACTED])
    record_views = "\n".join(read(path) for path in [RECORD_VIEWS, *RECORD_VIEWS_EXTRACTED])
    detail_presentation = "\n".join(read(path) for path in DETAIL_PRESENTATION)
    detail_store = read(DETAIL_STORE)
    settings = "\n".join(read(path) for path in [SETTINGS, *SETTINGS_EXTRACTED])
    data_audit = read(DATA_AUDIT)
    vision_recognizer = read(VISION_RECOGNIZER)
    ocr_queue = read(OCR_QUEUE)
    local_ocr_service = read(LOCAL_OCR_SERVICE)
    live_capture = read(LIVE_CAPTURE)
    clipboard_broker = read_tree(CLIPBOARD_BROKER)
    clipboard_app_sources = read_tree(APP)
    project = read(PROJECT)

    for token in ["ClipboardHistoryView.swift", "ClipboardRecorderRuntimeService.swift", "BlocksLoginItemHelper", "Embed LoginItems"]:
        if token in project:
            fail(failures, "project_clipboard_legacy_reference", token, PROJECT)

    required_store_terms = [
        "final class ClipboardStore: ObservableObject",
        "private var payloadCache: [ClipboardPayloadCacheKey: ClipboardRecorderPayload]",
        "func loadRepositoryState(limit:",
        "func readPayload(recordID: String, purpose: ClipboardPayloadReadPurpose)",
        "func preview(for record: ClipboardRecorderRecord) -> ClipboardRecordPreview",
        "func ocrState(for record: ClipboardRecorderRecord) -> ClipboardOCRState",
        "func retryOCR(recordID: String)",
        "func repositoryStateSummary()",
    ]
    missing_store = [term for term in required_store_terms if term not in store]
    if missing_store:
        fail(failures, "clipboard_store_contract_missing", ", ".join(missing_store), CLIPBOARD_STORE)

    repository_summary_block = method_block(store, "func repositoryStateSummary()")
    if ".normal(recordCount: records.count)" not in repository_summary_block:
        fail(
            failures,
            "repository_summary_normal_state_missing",
            "normal repository summary must use non-redacted storage/index/content-access semantics",
            CLIPBOARD_STORE
        )
    if ".redacted(recordCount:" in repository_summary_block or "clipboard.hardening.state.redacted" in repository_summary_block:
        fail(
            failures,
            "repository_summary_active_redacted_state",
            "Settings/DataAudit active repository summary must not resolve normal records through redacted state",
            CLIPBOARD_STORE
        )

    if not has_reload_cache_invalidation_boundary(store):
        fail(
            failures,
            "repository_reload_cache_invalidation_missing",
            "reload must stay payload-free and prune cached payloads against the published record set",
            CLIPBOARD_STORE,
        )

    read_block = method_block(store, "func readPayload(recordID: String, purpose: ClipboardPayloadReadPurpose)")
    if "ClipboardPayloadCacheKey(recordID: recordID, purpose: purpose)" not in read_block:
        fail(failures, "payload_cache_not_purpose_keyed", "readPayload must key cache by recordID and purpose", CLIPBOARD_STORE)

    allowed_purposes = ["case paste", "case copyPlainText", "case translationPreview", "case previewBuild", "case searchIndex", "case ocrInput", "case imagePreview", "case detailEditRead", "case detailFullValueRead", "case detailEditSave", "case detailCopyFullValue"]
    missing_purposes = [term for term in allowed_purposes if term not in payload_access]
    if missing_purposes:
        fail(failures, "payload_allowlist_missing", ", ".join(missing_purposes), PAYLOAD_ACCESS)

    filtered_block = method_block(controller, "static func filteredRecords")

    default_ui_combined = panel + "\n" + settings + "\n" + data_audit
    forbidden_default_tokens = [
        "payload: clipboardStore",
        "payload: appModel",
        "readPayload(",
        "readClipboardPayload(",
        "record.summary",
        "ClipboardRecorderRuntimeService",
        "settings.clipboardRecorder",
        "settings.clipboardHardening.storage",
        "settings.clipboardHardening.redactedPolicy",
        "settings.clipboardHardening.allowlist",
        "clipboard.hardening.state.redacted",
    ]
    default_hits = [token for token in forbidden_default_tokens if token in default_ui_combined]
    if default_hits:
        fail(failures, "default_ui_payload_or_debug_token", ", ".join(default_hits), PANEL)

    step2_tag_ui = panel + "\n" + filter_bar + "\n" + record_views + "\n" + settings + "\n" + tag_store
    for term in ["ClipboardTagStore", "selectedTagID", "ClipboardTagMenu", "ClipboardTagManagementSection"]:
        if term not in step2_tag_ui:
            fail(failures, "step2_tag_surface_missing", term, TAG_STORE)
    step2_forbidden_default_tokens = [
        "record.summary",
        "readPayload(",
        "NSPasteboard.general",
        "URLSession",
        "SecItem",
    ]
    step2_hits = [token for token in step2_forbidden_default_tokens if token in filter_bar + "\n" + record_views + "\n" + settings + "\n" + tag_store]
    if step2_hits:
        fail(failures, "step2_tag_surface_payload_or_system_token", ", ".join(step2_hits), RECORD_VIEWS)

    if not has_explicit_detail_load(panel, detail_store):
        fail(
            failures,
            "detail_not_explicit_lazy_read",
            "detail open must flow from the explicit panel action through ClipboardDetailStore to loadDetailReadModel",
            DETAIL_STORE,
        )
    detail_direct_payload_tokens = ["readPayload(", "readClipboardPayload(", "repository.readPayload("]
    detail_presentation_hits = [
        token for token in detail_direct_payload_tokens if token in detail_presentation
    ]
    if detail_presentation_hits:
        fail(
            failures,
            "detail_presentation_direct_payload_read",
            ", ".join(detail_presentation_hits),
            DETAIL_PRESENTATION[0],
        )
    legacy_hover_tokens = [
        "ClipboardHoverDetailLayer",
        "ClipboardHoverTracking",
        "ClipboardHoverDetailPanel",
        ".hoverDetail",
        "case hoverDetail",
    ]
    legacy_hover_hits = [
        token for token in legacy_hover_tokens if token in clipboard_app_sources or token in project
    ]
    if legacy_hover_hits:
        fail(
            failures,
            "legacy_hover_architecture_remaining",
            ", ".join(legacy_hover_hits),
            PAYLOAD_ACCESS,
        )
    for detail in verify_fail_closed_mutations(panel, detail_store, store):
        fail(failures, "clipboard_gate_mutation_self_check_failed", detail, CLIPBOARD_STORE)

    ocr_combined = vision_recognizer + "\n" + ocr_queue + "\n" + local_ocr_service
    for term in ["protocol ClipboardVisionTextRecognizer", "VNRecognizeTextRequest", "MockClipboardVisionTextRecognizer", ".ocrInput", "updateOCRResult"]:
        if term not in ocr_combined:
            fail(failures, "ocr_boundary_contract_missing", term, OCR_QUEUE)
    forbidden_ocr_tokens = ["URLSession", "NSWorkspace", "NSPasteboard.general", "SecItem", "CGEvent", "AXUIElement", "SCStream"]
    ocr_hits = [token for token in forbidden_ocr_tokens if token in ocr_combined]
    if ocr_hits:
        fail(failures, "ocr_forbidden_boundary_token", ", ".join(ocr_hits), OCR_QUEUE)

    if "lastAcceptedSignature" in live_capture:
        fail(
            failures,
            "live_capture_runtime_signature_dedupe",
            "ClipboardLiveCaptureService must not drop repeated payloads by last accepted signature; repository owns payload dedupe and recency updates",
            LIVE_CAPTURE
        )
    if "NSPasteboard.general" in live_capture or "DispatchQueue(" in live_capture:
        fail(
            failures,
            "live_capture_direct_or_uncancellable_clipboard_io",
            "ClipboardLiveCaptureService must delegate to the async broker and own no raw pasteboard queue.",
            LIVE_CAPTURE,
        )
    if "ClipboardBroker" not in live_capture or "observe(" not in live_capture:
        fail(
            failures,
            "live_capture_broker_boundary_missing",
            "ClipboardLiveCaptureService must observe through BlocksClipboardBroker.",
            LIVE_CAPTURE,
        )
    broker_capture_contracts = {
        "general_pasteboard": (
            "NSPasteboard.general" in clipboard_broker
            or "pasteboard: NSPasteboard = .general" in clipboard_broker
        ),
        "png_type": ".png" in clipboard_broker,
        "tiff_type": ".tiff" in clipboard_broker,
        "file_url_type": "fileURL" in clipboard_broker,
        "rtf_plain_text_derivation": "NSAttributedString" in clipboard_broker,
    }
    for term, present in broker_capture_contracts.items():
        if not present:
            fail(
                failures,
                "broker_clipboard_capture_path_missing",
                term,
                CLIPBOARD_BROKER,
            )

    app_model_forbidden = [
        "func clipboardPayload(for:",
        "func clipboardPreview(",
        "func filteredClipboardRecords(",
        "ClipboardRecorderRuntimeService",
        "RecorderRuntimeState",
        "var clipboardRecords",
        "var clipboardFilterState",
        "var clipboardPinboards",
        "var clipboardPinnedMetadata",
    ]
    app_hits = [token for token in app_model_forbidden if token in app_model]
    if app_hits:
        fail(failures, "app_model_clipboard_facade_or_debug_remaining", ", ".join(app_hits), APP_MODEL)

    payload = {
        "ok": not failures,
        "gate": "P11E",
        "checked_files": [rel(path) for path in required],
        "current_evidence": {
            "prd": rel(STEP1_PRD),
            "supplement": rel(STEP1_SUPPLEMENT),
            "step2_prd": rel(STEP2_PRD),
            "step2_dispatch": rel(STEP2_DISPATCH),
            "positioning": "Step 1 output-boundary and explicit-purpose guard plus Step 2 tag/favorite UI/store guard; old Step 4D redacted-first default is baseline only",
        },
        "denied_default_sites": {
            "panel_no_payload_reads": not any(token in panel for token in ["readPayload(", "readClipboardPayload(", "record.summary"]),
            "filtered_records_no_pinned_display_name": "displayName" not in filtered_block,
            "repository_summary_normal_state": ".normal(recordCount: records.count)" in repository_summary_block,
            "tag_filter_no_payload_reads": "readPayload(" not in filter_bar,
            "tag_menu_no_payload_reads": "readPayload(" not in record_views,
            "tag_settings_no_payload_reads": "readPayload(" not in settings,
            "history_view_deleted": not HISTORY.exists(),
            "runtime_service_deleted": not RUNTIME_SERVICE.exists(),
        },
        "baseline_reference": {"old_archives_used_for_ok": False, "step4d_redacted_first_used_for_ok": False, "old_pinboard_story_used_for_ok": False},
        "failures": failures,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
