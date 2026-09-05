#!/usr/bin/env python3
"""P9-B current Clipboard source contracts; Step 1/2 documents are historical scope references."""

from __future__ import annotations

import json
import re
from pathlib import Path

from current_architecture_gate_helpers import swift_code_only

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
APP_MODEL = APP / "App" / "AppModel.swift"
CLIPBOARD_STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
CLIPBOARD_COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift"
PASTE_ORCHESTRATOR = APP / "Features" / "Clipboard" / "ClipboardPasteOrchestrator.swift"
COPY_ACTIONS = CLIPBOARD_COORDINATOR.with_name("ClipboardFeatureCoordinator+CopyActions.swift")
PANEL_ACTIONS = CLIPBOARD_COORDINATOR.with_name("ClipboardFeatureCoordinator+PanelPresentation.swift")
MODEL_DELEGATION = APP_MODEL.with_name("AppModel+FeatureDelegation.swift")
MODEL_BINDINGS = APP_MODEL.with_name("AppModel+StoreBindings.swift")
HISTORY_PIPELINE = CLIPBOARD_COORDINATOR.with_name("ClipboardHistoryReadPipeline.swift")
OCR_SCHEDULER = CLIPBOARD_COORDINATOR.with_name("ClipboardOCRScheduler.swift")
TAG_STORE = APP / "Features" / "Clipboard" / "ClipboardTagStore.swift"
FILTERS = APP / "Support" / "ClipboardFilters.swift"
CONTROLLER = APP / "Stores" / "ClipboardController.swift"
PAYLOAD_ACCESS = APP / "Features" / "Clipboard" / "ClipboardPayloadAccess.swift"
READ_MODEL = APP / "Features" / "Clipboard" / "ClipboardReadModel.swift"
SEARCH_COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardSearchCoordinator.swift"
VISION_RECOGNIZER = APP / "Features" / "Clipboard" / "ClipboardVisionTextRecognizer.swift"
OCR_QUEUE = APP / "Features" / "Clipboard" / "ClipboardVisionOCRQueue.swift"
LOCAL_OCR_SERVICE = APP / "Features" / "OCR" / "LocalVisionOCRService.swift"
AUTO_PASTE = APP / "Services" / "ClipboardAutoPasteCoordinator.swift"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
SEARCH_DOCUMENT = CORE / "ClipboardSearchDocument.swift"
SEARCH_DOCUMENT_BUILDER = CORE / "ClipboardSearchDocumentBuilder.swift"
SEARCH_DOCUMENT_REPOSITORY = CORE / "ClipboardRepository+SearchDocuments.swift"
TAG_MODEL = CORE / "ClipboardTag.swift"
TAG_REPOSITORY = CORE / "ClipboardTagRepository.swift"
STEP1_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "产品经理-PRD-v1.md"
STEP1_SUPPLEMENT = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1C-1D补充-v0.md"
STEP2_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "产品经理-PRD-v1.md"
STEP2_PLAN = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "App架构师-技术方案-v1.md"
STEP2_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "项目负责人-开发派发-Step2-v0.md"

CORE_FORBIDDEN_IMPORTS = [
    "import AppKit",
    "import SwiftUI",
    "import Security",
    "import ApplicationServices",
    "import ScreenCaptureKit",
    "import ServiceManagement",
    "import Combine",
]


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def body_of(source: str, marker: str) -> str:
    if not marker:
        return ""
    code = swift_code_only(source)
    suffix = r"(?!\w)" if marker[-1].isalnum() or marker[-1] == "_" else ""
    matches = list(re.finditer(r"(?<!\w)" + re.escape(marker) + suffix, code))
    if len(matches) != 1:
        return ""

    def delimiter_end(start: int, left: str, right: str) -> int | None:
        if start < 0:
            return None
        depth = 0
        for index in range(start, len(code)):
            if code[index] == left:
                depth += 1
            elif code[index] == right:
                depth -= 1
                if depth == 0:
                    return index + 1
        return None

    # Parameter defaults can contain closures. Their braces are not the body.
    parameters_end = delimiter_end(code.find("(", matches[0].start()), "(", ")")
    if parameters_end is None:
        return ""
    opening = code.find("{", parameters_end)
    end = delimiter_end(opening, "{", "}")
    return code[opening + 1:end - 1] if end is not None else ""


def current_contracts(sources: dict[str, str]) -> dict[str, bool]:
    sources = {name: swift_code_only(source) for name, source in sources.items()}
    model = sources["app_model"]
    copy = body_of(sources["auto_paste"], "func copyToPasteboard(")
    dispatch = body_of(sources["auto_paste"], "func dispatchPaste(")
    paste = body_of(sources["paste"], "private func continuePasteRecord(")
    plain = body_of(sources["copy_actions"], "private func copyRecordAsPlainTextAsync(")
    fresh_write = paste.find("let copyResult = try await autoPasteCoordinator.copyToPasteboard(")
    receipt = paste.find("pasteboardLease = copyResult.pasteboardLease", max(0, fresh_write))
    recency = paste.find("await clipboardStore.commitCopyEvent(", max(0, receipt))
    late_effect_guard = paste.find("guard copyResult.mayContinueAutomaticPaste", max(0, recency))
    plain_write = plain.find("try await autoPasteCoordinator.writePlainText(")
    plain_validate = plain.find("guard await autoPasteCoordinator.validate(lease)", max(0, plain_write))
    plain_recency = plain.find("await clipboardStore.commitCopyEvent(", max(0, plain_validate))
    plain_effects = plain.find("guard recency.recordFound", max(0, plain_recency))
    history = body_of(sources["store"], "func refreshSearchResult(query:")
    prune = body_of(sources["store"], "func prunePayloadsToCurrentRecords()")
    return {
        "cleanup_preview_and_confirmation_delegate": (
            "clipboardCoordinator.previewCleanupPolicy(" in body_of(model, "func previewClipboardCleanupPolicy(")
            and "clipboardCoordinator.confirmCleanupPolicy(" in body_of(model, "func confirmClipboardCleanupPolicy(")
        ),
        "panel_delete_delegates_to_store": (
            "await self.deleteHistoryItem(recordID: recordID)" in body_of(sources["panel_actions"], "func makeClipboardPanelActions()")
            and "await clipboardStore.delete(recordID: recordID)" in body_of(sources["coordinator"], "func deleteHistoryItem(")
        ),
        "copy_has_no_target_dependency": (
            "try await pasteboardWriter.write(" in copy
            and "targetContext" not in copy
            and "mayContinueAutomaticPaste: !Task.isCancelled && operationAllowed()" in copy
        ),
        "dispatch_requires_owned_lease_and_target": (
            0 <= dispatch.find("try await ensurePasteboardOwnership(pasteboardLease)") < dispatch.find("guard let targetContext")
            and "pasteboardWriter.write(" not in dispatch
        ),
        "paste_records_physical_write_before_late_effects": (
            0 <= fresh_write < receipt < recency < late_effect_guard
            and "Task.isCancelled" not in paste[receipt:recency]
            and not re.search(r"\b(?:guard|return|throw)\b", paste[receipt:recency])
            and "shouldPublishPluginEvent:" in paste[recency:late_effect_guard]
        ),
        "plain_copy_records_validated_write_before_late_effects": (
            0 <= plain_write < plain_validate < plain_recency < plain_effects
            and "shouldPublishPluginEvent:" in plain[plain_recency:plain_effects]
        ),
        "history_read_is_generation_scoped": (
            "let pipeline = historyReadPipeline" in history and "await pipeline.read(request)" in history
            and "snapshot.generation == self.historyReadGeneration" in history
            and "repository.searchDocuments(query:" in re.sub(r"\s+", "", swift_code_only(sources["history_pipeline"]))
        ),
        "payload_cache_prunes_only_removed_records": (
            "let recordIDs = Set(records.map(\\.id))" in prune
            and "payloadCache = payloadCache.filter { recordIDs.contains($0.key.recordID) }" in prune
        ),
        "ocr_scheduler_owns_queue": (
            "ClipboardOCRScheduler(queue: resolvedOCRQueue)" in sources["store"]
            and "ocrScheduler?.retry(recordID: recordID)" in body_of(sources["store"], "func retryOCR(recordID:")
            and "queue.retryOCR(recordID:" in sources["ocr_scheduler"]
        ),
    }


def main() -> int:
    failures: list[dict[str, str]] = []
    required = [
        APP_MODEL,
        CLIPBOARD_STORE,
        CLIPBOARD_COORDINATOR,
        CLIPBOARD_COORDINATOR.with_name("ClipboardFeatureCoordinator+CapturePersistence.swift"),
        PASTE_ORCHESTRATOR,
        COPY_ACTIONS, PANEL_ACTIONS, MODEL_DELEGATION, MODEL_BINDINGS,
        HISTORY_PIPELINE, OCR_SCHEDULER,
        TAG_STORE,
        FILTERS,
        CONTROLLER,
        PAYLOAD_ACCESS,
        READ_MODEL,
        SEARCH_COORDINATOR,
        VISION_RECOGNIZER,
        OCR_QUEUE,
        LOCAL_OCR_SERVICE,
        AUTO_PASTE,
        SEARCH_DOCUMENT,
        SEARCH_DOCUMENT_BUILDER,
        SEARCH_DOCUMENT_REPOSITORY,
        TAG_MODEL,
        TAG_REPOSITORY,
        STEP1_PRD,
        STEP1_SUPPLEMENT,
        STEP2_PRD,
        STEP2_PLAN,
        STEP2_DISPATCH,
    ]
    for path in required:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})

    app_model = "\n".join(read(path) for path in [APP_MODEL, MODEL_DELEGATION, MODEL_BINDINGS])
    store = read(CLIPBOARD_STORE)
    clipboard_coordinator = "\n".join(read(path) for path in [CLIPBOARD_COORDINATOR, CLIPBOARD_COORDINATOR.with_name("ClipboardFeatureCoordinator+CapturePersistence.swift"), PASTE_ORCHESTRATOR])
    tag_store = read(TAG_STORE)
    filters = read(FILTERS)
    controller = read(CONTROLLER)
    payload_access = read(PAYLOAD_ACCESS)
    read_model = read(READ_MODEL)
    search_coordinator = read(SEARCH_COORDINATOR)
    vision_recognizer = read(VISION_RECOGNIZER)
    ocr_queue = read(OCR_QUEUE)
    local_ocr_service = read(LOCAL_OCR_SERVICE)
    auto_paste = read(AUTO_PASTE)
    integration_sources = {
        "app_model": app_model, "store": store, "coordinator": clipboard_coordinator,
        "paste": read(PASTE_ORCHESTRATOR), "copy_actions": read(COPY_ACTIONS),
        "panel_actions": read(PANEL_ACTIONS), "auto_paste": auto_paste,
        "history_pipeline": read(HISTORY_PIPELINE), "ocr_scheduler": read(OCR_SCHEDULER),
    }
    contracts = current_contracts(integration_sources)
    for name, valid in contracts.items():
        if not valid:
            failures.append({"code": "current_integration_contract_missing", "detail": name})
    search_documents = "\n".join(read(path) for path in [SEARCH_DOCUMENT, SEARCH_DOCUMENT_BUILDER, SEARCH_DOCUMENT_REPOSITORY])
    tag_sources = read(TAG_MODEL) + "\n" + read(TAG_REPOSITORY) + "\n" + tag_store

    app_model_required = [
        "let clipboardStore: ClipboardStore",
        "let sharedClipboardRepository = clipboardStore == nil ? AppModel.makeClipboardRepository() : nil",
        "ocrQueue: sharedClipboardOCRQueue",
        "ClipboardFeatureCoordinator(",
        "clipboardCoordinator.loadRepositoryState",
        "clipboardCoordinator.ingestLiveCapture",
        "clipboardCoordinator.previewCleanupPolicy",
        "clipboardCoordinator.confirmCleanupPolicy",
        "clipboardCoordinator.clearUnfavoritedSummaries",
        "clipboardCoordinator.toggleFavorite",
        "clipboardTagStore",
        "toggleClipboardFavorite",
        "setClipboardTagFilter",
        "clearUnfavoritedClipboardSummaries",
    ]
    missing_app_model = [snippet for snippet in app_model_required if snippet not in app_model]
    if missing_app_model:
        failures.append({"code": "app_model_missing", "detail": ", ".join(missing_app_model)})

    app_model_forbidden = [
        "Stores/AppState.swift",
        "@Published var clipboardRecords",
        "@Published var clipboardPayloads",
        "func clipboardPayload(for:",
        "func clipboardPreview(",
        "func filteredClipboardRecords(",
    ]
    app_model_hits = [snippet for snippet in app_model_forbidden if snippet in app_model]
    if app_model_hits:
        failures.append({"code": "app_model_forbidden", "detail": ", ".join(app_model_hits)})

    store_required = [
        "final class ClipboardStore: ObservableObject",
        "private let repository: ClipboardRepository?",
        "private var payloadCache: [ClipboardPayloadCacheKey: ClipboardRecorderPayload] = [:]",
        "@Published var records: [ClipboardRecorderRecord] = []",
        "@Published var filterState = ClipboardFilterState()",
        "let tagStore: ClipboardTagStore",
        "tagStore.objectWillChange",
        "@Published var recorderPaused = false",
        "@Published var pasteAttempt: ClipboardPasteAttempt?",
        "@Published var floatingSelectedRecordID: String?",
        "@Published private(set) var repositoryUnavailable = false",
        "@Published private(set) var currentSearchResult",
        "private var previewSnapshots: [String: ClipboardContentPreviewSnapshot]",
        "private var ocrScheduler: ClipboardOCRScheduler?",
        "func repositoryStateSummary() -> ClipboardRepositoryStateSummary",
        "func readPayload(recordID: String, purpose: ClipboardPayloadReadPurpose)",
        "func resolveRecord(recordID: String)",
        "func preview(for record: ClipboardRecorderRecord) -> ClipboardRecordPreview",
        "func ocrState(for record: ClipboardRecorderRecord) -> ClipboardOCRState",
        "func retryOCR(recordID: String)",
        "ClipboardPayloadCacheKey(recordID: recordID, purpose: purpose)",
        "repository.readPayload(recordID:",
        "func prunePayloadsToCurrentRecords()",
        "repository.insert(",
        "repository.applyPolicy(",
        "repository.clearUnfavorited(",
        "recordMutationPipeline.delete(recordID:",
        "repository.markCopied(recordID:",
        "func markCopied(",
        "tagStore.toggleFavorite(recordID:",
        "func setTagFilter",
        "selectedTagID",
    ]
    missing_store = [snippet for snippet in store_required if snippet not in store]
    if missing_store:
        failures.append({"code": "store_missing", "detail": ", ".join(missing_store)})

    store_forbidden = [
        "@Published var payloads: [String: ClipboardRecorderPayload]",
        "private func loadPayloads",
        "RecorderRuntimeState",
    ]
    store_hits = [snippet for snippet in store_forbidden if snippet in store]
    if store_hits:
        failures.append({"code": "store_forbidden", "detail": ", ".join(store_hits)})

    legacy_active_tokens = [
        "@Published var pinboards",
        "@Published var pinnedMetadata",
        "clipboardStore.clearUnpinned",
        "clipboardStore.togglePin",
        "clipboardStore.move",
        "clipboardStore.renamePinnedRecord",
        "repository.clearUnpinned()",
        "repository.pin(recordID:",
        "repository.move(recordID:",
        "repository.renamePinnedRecord(recordID:",
        "ClipboardFilterState.pinboardID",
        "pinnedCount",
    ]
    legacy_hits = [snippet for snippet in legacy_active_tokens if snippet in app_model + store + filters]
    if legacy_hits:
        failures.append({"code": "step2_legacy_active_fact_remaining", "detail": ", ".join(legacy_hits)})

    tag_required = [
        "final class ClipboardTagStore: ObservableObject",
        "@Published private(set) var tags",
        "@Published private(set) var recordTags",
        "@Published var selectedTagID",
        "ClipboardTagRepository",
        "toggleFavorite(recordID:",
        "createTagAndAttach",
        "deleteTag",
        "mergeTag",
        "selectedTagTransition",
        "affectedRecordIDs",
    ]
    tag_missing = [snippet for snippet in tag_required if snippet not in tag_sources]
    if tag_missing:
        failures.append({"code": "step2_tag_store_integration_missing", "detail": ", ".join(tag_missing)})

    load_body = body_of(store, "func loadRepositoryState")
    if "repository.readPayload(recordID:" in load_body or "loadPayloads(" in load_body:
        failures.append({"code": "load_reads_payload", "detail": "loadRepositoryState must stay metadata-first"})

    ingest_body = body_of(store, "func ingestLiveCapture(")
    if "result.duplicate" not in ingest_body or "loadRepositoryState(limit: lastLoadLimit)" not in ingest_body:
        failures.append({
            "code": "duplicate_ingest_does_not_reload_recent",
            "detail": "repository duplicate ingest must reload after repository updates last_copied_at"
        })

    controller_ingest = body_of(controller, "static func ingestLiveCapture")
    if "$0.signatureSHA256 == snapshot.record.signatureSHA256" in controller_ingest and "records.remove(at:" not in controller_ingest:
        failures.append({
            "code": "in_memory_duplicate_does_not_move_recent",
            "detail": "in-memory duplicate ingest must move the existing record to the top instead of rejecting it"
        })

    payload_required = [
        "enum ClipboardPayloadReadPurpose: String, CaseIterable",
        "case paste",
        "case copyPlainText",
        "case detailEditRead",
        "case detailFullValueRead",
        "case detailEditSave",
        "case detailCopyFullValue",
        "case translationPreview",
        "case previewBuild",
        "case searchIndex",
        "case ocrInput",
        "struct ClipboardPayloadReadResult",
    ]
    payload_missing = [snippet for snippet in payload_required if snippet not in payload_access]
    if payload_missing:
        failures.append({"code": "payload_access_missing", "detail": ", ".join(payload_missing)})
    if "case hoverDetail" in swift_code_only(payload_access):
        failures.append({"code": "retired_payload_access_purpose", "detail": "hoverDetail must not replace explicit detail purposes"})

    read_model_required = [
        "enum ClipboardRepositoryStorageState: String",
        "struct ClipboardRepositoryStateSummary",
    ]
    read_model_missing = [snippet for snippet in read_model_required if snippet not in read_model]
    if read_model_missing:
        failures.append({"code": "read_model_missing", "detail": ", ".join(read_model_missing)})

    search_required = [
        "ClipboardSearchResultSet",
        "ClipboardSearchIndexActivity",
        "ClipboardSearchCoordinator",
        "recordTags",
        "selectedTagID",
        "upsertSearchDocument",
        "searchDocuments(query:",
        "tagTokens",
        "markSearchDocumentTagsDirty",
        "updateOCRResult",
        "loadPendingOCRDocuments",
    ]
    missing_search = [
        snippet for snippet in search_required
        if snippet not in re.sub(r"\s+", "", swift_code_only(search_documents + search_coordinator))
    ]
    if missing_search:
        failures.append({"code": "search_integration_missing", "detail": ", ".join(missing_search)})

    ocr_required = [
        "protocol ClipboardVisionTextRecognizer",
        "VNRecognizeTextRequest",
        "MockClipboardVisionTextRecognizer",
        "runningHold",
        "actor ClipboardVisionOCRQueue",
        ".ocrInput",
        "retryOCR(recordID:",
        "updateOCRResult",
    ]
    missing_ocr = [
        snippet for snippet in ocr_required
        if snippet not in vision_recognizer + ocr_queue + local_ocr_service + store
    ]
    if missing_ocr:
        failures.append({"code": "ocr_integration_missing", "detail": ", ".join(missing_ocr)})

    core_failures: list[str] = []
    for path in CORE.glob("*.swift"):
        source = read(path)
        for forbidden_import in CORE_FORBIDDEN_IMPORTS:
            if forbidden_import in source:
                core_failures.append(f"{rel(path)} contains {forbidden_import}")
    if core_failures:
        failures.append({"code": "blocks_core_forbidden_import", "detail": "; ".join(core_failures)})

    output = {
        "ok": not failures,
        "suite": "p9b_clipboard_appmodel_repository_integration_checks",
        "verification_scope": "source_contracts_only",
        "current_contracts": contracts,
        "failures": failures,
        "current_evidence": {
            "app_model": rel(APP_MODEL),
            "clipboard_store": rel(CLIPBOARD_STORE),
            "clipboard_coordinator": rel(CLIPBOARD_COORDINATOR),
            "clipboard_paste_orchestrator": rel(PASTE_ORCHESTRATOR),
            "clipboard_copy_actions": rel(COPY_ACTIONS),
            "clipboard_panel_actions": rel(PANEL_ACTIONS),
            "app_model_delegation": rel(MODEL_DELEGATION),
            "history_read_pipeline": rel(HISTORY_PIPELINE),
            "ocr_scheduler": rel(OCR_SCHEDULER),
            "payload_access": rel(PAYLOAD_ACCESS),
            "read_model": rel(READ_MODEL),
            "search_coordinator": rel(SEARCH_COORDINATOR),
            "ocr_queue": rel(OCR_QUEUE),
            "vision_recognizer": rel(VISION_RECOGNIZER),
            "prd": rel(STEP1_PRD),
            "supplement": rel(STEP1_SUPPLEMENT),
            "step2_prd": rel(STEP2_PRD),
            "step2_plan": rel(STEP2_PLAN),
            "step2_dispatch": rel(STEP2_DISPATCH),
            "tag_store": rel(TAG_STORE),
            "tag_repository": rel(TAG_REPOSITORY),
            "tag_filter": rel(FILTERS),
        },
        "baseline_reference": {
            "old_appstate_sources_used_for_ok": False,
            "old_archives_used_for_ok": False,
            "step5_redacted_first_used_for_ok": False,
            "old_pinboard_storage_used_for_ok": False,
        },
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
