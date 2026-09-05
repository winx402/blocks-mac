#!/usr/bin/env python3
"""P8 Clipboard product polish checks for 004 Step 1 + Step 2."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
PANEL_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift",
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardPanelRecordContent.swift",
]
RECORD_VIEWS = APP / "Views" / "ClipboardRecordViews.swift"
RECORD_VIEWS_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Records" / "ClipboardFloatingRecordRow.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordMenus.swift",
]
FILTER_BAR = APP / "Views" / "ClipboardFilterBarView.swift"
FILTER_BAR_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Filters" / "ClipboardTagFilterChips.swift",
    APP / "Features" / "Clipboard" / "Filters" / "ClipboardFilterControls.swift",
]
PANEL_HEADER = APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift"
HOVER = APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationView.swift"
HOVER_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationLayer.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPanel.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift",
]
SETTINGS = APP / "Features" / "Settings" / "ClipboardSettingsPane.swift"
SETTINGS_EXTRACTED = [
    APP / "Features" / "Settings" / "ClipboardTagManagementSection.swift",
]
STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
HISTORY_READ_PIPELINE = APP / "Features" / "Clipboard" / "ClipboardHistoryReadPipeline.swift"
RECORD_ACTION_PIPELINE = APP / "Features" / "Clipboard" / "ClipboardRecordActionPipeline.swift"
TAG_STORE = APP / "Features" / "Clipboard" / "ClipboardTagStore.swift"
APP_MODEL = APP / "App" / "AppModel.swift"
STEP1_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "产品经理-PRD-v1.md"
STEP1_SUPPLEMENT = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_1" / "项目负责人-开发派发-Step1C-1D补充-v0.md"
STEP2_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "产品经理-PRD-v1.md"
STEP2_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "项目负责人-开发派发-Step2-v0.md"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def source_block(source: str, start: str, end: str) -> str:
    start_index = source.find(start)
    if start_index == -1:
        return ""
    end_index = source.find(end, start_index + len(start))
    if end_index == -1:
        return source[start_index:]
    return source[start_index:end_index]


def main() -> int:
    failures: list[dict[str, str]] = []
    files = [PANEL, *PANEL_EXTRACTED, RECORD_VIEWS, *RECORD_VIEWS_EXTRACTED, FILTER_BAR, *FILTER_BAR_EXTRACTED, HOVER, *HOVER_EXTRACTED, SETTINGS, *SETTINGS_EXTRACTED, STORE, HISTORY_READ_PIPELINE, RECORD_ACTION_PIPELINE, TAG_STORE, APP_MODEL, STEP1_PRD, STEP1_SUPPLEMENT, STEP2_PRD, STEP2_DISPATCH]
    for path in files:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})

    panel = "\n".join(read(path) for path in [PANEL, *PANEL_EXTRACTED])
    settings = "\n".join(read(path) for path in [SETTINGS, *SETTINGS_EXTRACTED])
    store = read(STORE)
    history_read_pipeline = read(HISTORY_READ_PIPELINE)
    record_action_pipeline = read(RECORD_ACTION_PIPELINE)
    tag_store = read(TAG_STORE)
    app_model = read(APP_MODEL)
    record_views = "\n".join(read(path) for path in [*RECORD_VIEWS_EXTRACTED, RECORD_VIEWS])
    filter_bar = "\n".join(read(path) for path in [FILTER_BAR, *FILTER_BAR_EXTRACTED])
    hover = "\n".join(read(path) for path in [HOVER, *HOVER_EXTRACTED])
    header = read(PANEL_HEADER)
    bottom_header_block = source_block(header, "private var bottomHeader", "private var sideHeader")
    side_header_block = source_block(header, "private var sideHeader", "private var bottomTrailingActionGroup")
    bottom_filter_block = source_block(header, "private var filterStrip", "private func sideFilterMenuGroup")
    side_filter_block = source_block(header, "private func sideFilterMenuGroup", "private var tagFilterStrip")
    clear_filter_block = source_block(panel, "private func clearAllFiltersFromToolbar", "private func toggleFormatFilter")
    store_clear_filters_block = source_block(store, "func clearFilters()", "func setFormatFilter")
    card_block = source_block(record_views, "struct ClipboardFloatingRecordCard", "private var rowBorderColor")
    direct_preview_block = source_block(record_views, "struct ClipboardDirectContentPreview", "extension ClipboardRecorderItemKind")

    checks = {
        "explicit_search_result_state": "clipboardStore.currentSearchResult" in panel and "refreshSearchResult()" in panel,
        "store_repository_search_path": (
            "ClipboardHistoryReadPipeline" in store
            and "let snapshot = await pipeline.read(request)" in store
            and "repository.searchDocuments(query:" in history_read_pipeline
            and 'label: "app.blocks.clipboard.history-read"' in history_read_pipeline
            and "queue.async" in history_read_pipeline
        ),
        "filter_menu_groups_present": (
            "struct ClipboardFilterMenuGroup" in filter_bar
            and "Menu {" in source_block(
                filter_bar,
                "struct ClipboardFilterMenuGroup",
                "private struct ClipboardFilterOptionMenuLabel",
            )
            and "ClipboardFilterMenuGroup(" in bottom_filter_block
            and "ClipboardFilterMenuGroup(" in side_filter_block
        ),
        "header_layout_matches_panel_position": (
            "if values.position == .bottom" in header
            and "HStack(" in bottom_header_block
            and "VStack(" not in bottom_header_block
            and "VStack(" in side_header_block
            and side_header_block.count("HStack(") >= 2
            and "ClipboardPanelToolbarLayout.headerRowHeight" in side_header_block
            and "ClipboardPanelToolbarLayout.tagRowHeight" in side_header_block
        ),
        "bounded_card_preview": "preview: clipboardStore.preview(for: record)" in panel and "ClipboardDirectContentPreview" in record_views,
        "bottom_card_footer_time_only": "ClipboardCardMetaLabel(" in card_block and "record.lastCopiedAt.formatted" in card_block and "Text(preview.badge)" not in card_block and "ClipboardTagChips" not in card_block,
        "bottom_card_content_unframed": "Color.primary.opacity(0.055)" not in direct_preview_block and "RoundedRectangle(cornerRadius: 10" not in direct_preview_block,
        "favorite_and_quick_number_separate": ".overlay(alignment: .topTrailing)" in card_block and ".overlay(alignment: .bottomTrailing)" in card_block and "ClipboardQuickPasteNumberBadge" in card_block,
        "ocr_status_retry_surface": "clipboardStore.ocrState(for: record)" in panel and "retryOCR(recordID:" in store,
        "hover_detail_lazy_read": (
            "clipboardStore.readDetailPreview(recordID: recordID)" in hover
            and "func readDetailPreview(" in record_action_pipeline
            and "queue.async" in record_action_pipeline
        ),
        "settings_clipboard_storage_section_removed": "settings.clipboardStorage" not in settings and "settings.clipboardSearchIndex" not in settings and "settings.clipboardContentAccess" not in settings,
        "settings_advanced_layout_uncollapsed": "settings.clipboardPanelAdvancedLayout" not in settings and "DisclosureGroup" not in source_block(settings, "SettingsTableSection(\n            title: L10n.string(\"settings.clipboardPanelDisplay\")", "SettingsTableSection(\n            title: L10n.string(\"settings.clipboardFilterBehavior\")"),
        "settings_tags_drag_reorder": all(term in settings for term in [
            "settingsTagDropInsertionIndicator",
            ".frame(height: 2)",
            ".simultaneousGesture(settingsTagPointerGesture(tag: tag))",
            "minimumDistance: ClipboardFilterBarLayout.tagDragActivationDistance",
            "handleSettingsTagPointerChanged",
            "handleSettingsTagPointerEnded",
            "isSettingsTagDragging",
            "defer { clearSettingsTagDragState() }",
            "tagStore.moveFilterTag(",
            ".onChange(of: ordinaryTagIDs)",
            "NSWindow.didResignKeyNotification",
            ".onDisappear",
            "settingsDraggedTagID = nil",
            "settingsDropInsertionTargetKey = nil",
            "settingsDragStartLocation = nil",
            "isSettingsTagDragging = false",
        ]) and ".onDrag" not in settings and ".onDrop(" not in settings and "DropDelegate" not in settings,
        "settings_tags_use_shared_row_actions": "struct ClipboardTagRow" in settings and "SettingsCustomLabelRow(" in settings and "BlocksCompactIconButton(" in settings and "systemImage: \"trash\"" in settings and "settingsTagContextMenu(for:" in settings,
        "step2_single_tag_filter": "ClipboardFlatTagFilterChips" in filter_bar and "favoriteTag" in filter_bar and "tags.filter { !$0.isFavorite }" in filter_bar and "ForEach(ClipboardFilterGroup.nonTagCases)" in panel,
        "step2_record_tag_menu": "Button(action: onToggleFavorite)" in record_views and "ClipboardTagMenu" in record_views and record_views.find("Button(action: onToggleFavorite)") < record_views.find("ClipboardTagMenu"),
        "step2_favorite_surface": "Button(action: onToggleFavorite)" in record_views and "clipboard.tags.favorite" in record_views and "clipboard.tags.unfavorite" in record_views and "isFavorite(recordID:" in record_views,
        "step2_tag_store_bridge": "let tagStore: ClipboardTagStore" in store and "final class ClipboardTagStore" in tag_store,
        "step2_clear_all_includes_tag_filter": (
            "values.hasActiveFilters" in header
            and "actions.onClearAllFilters" in header
            and "clipboardStore.clearFilters()" in clear_filter_block
            and "filterState.clear()" in store_clear_filters_block
            and "tagStore.setSelectedTagID(nil)" in store_clear_filters_block
        ),
        "step2_no_legacy_pinboard_ui": all(term not in panel + record_views + filter_bar + settings for term in ["onMoveToPinboard", "clipboard.context.moveToPinboard", "clipboard.policy.clearUnpinned", "Pinned Groups"]),
        "record_context_edit_detail_removed": all(term not in panel + record_views + app_model for term in ["clipboard.context.editDetails", ".editDetail", "onEditDetail", "detailEditorCard", "BLOCKS_OPEN_CLIPBOARD_DETAIL_ON_LAUNCH", "openDetailEditor(recordID:"]),
        "repository_state_feedback": "repositoryStateSummary" in store and "repositoryStateSummary" in settings,
        "no_appstate_fact_source": "AppState" not in "\n".join(read(path) for path in [PANEL, *PANEL_EXTRACTED, RECORD_VIEWS, *RECORD_VIEWS_EXTRACTED, FILTER_BAR, *FILTER_BAR_EXTRACTED, HOVER, *HOVER_EXTRACTED, SETTINGS, STORE, APP_MODEL]),
        "no_debug_recorder_ui": "settings.clipboardRecorder" not in settings and "ClipboardRecorderRuntimeService" not in panel + settings + app_model,
        "no_direct_payload_reads_in_panel": "readPayload(" not in panel + record_views,
    }

    for code, ok in checks.items():
        if not ok:
            failures.append({"code": code, "detail": "missing expected Step 1 clipboard polish surface"})

    output = {
        "ok": not failures,
        "suite": "p8_clipboard_product_polish_checks",
        "current_evidence": {
            "prd": rel(STEP1_PRD),
            "supplement": rel(STEP1_SUPPLEMENT),
            "step2_prd": rel(STEP2_PRD),
            "step2_dispatch": rel(STEP2_DISPATCH),
            "code_files": [rel(path) for path in files],
        },
        "baseline_reference": {"old_archives_used_for_ok": False, "step5_redacted_first_used_for_ok": False, "old_pinboard_story_used_for_ok": False},
        "checks": checks,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
