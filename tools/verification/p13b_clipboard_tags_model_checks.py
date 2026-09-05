#!/usr/bin/env python3
"""P13-B clipboard tag/favorite model checks for 004 Step 2."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verification_sanitizer import sanitize_payload, sanitizer_self_check


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"

STEP2_PRD = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "产品经理-PRD-v1.md"
STEP2_PLAN = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "App架构师-技术方案-v1.md"
STEP2_DISPATCH = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_2" / "项目负责人-开发派发-Step2-v0.md"

APP_DATABASE = CORE / "AppDatabase.swift"
TAG_MODEL = CORE / "ClipboardTag.swift"
TAG_REPOSITORY = CORE / "ClipboardTagRepository.swift"
SEARCH_DOCUMENT = CORE / "ClipboardSearchDocument.swift"
SEARCH_BUILDER = CORE / "ClipboardSearchDocumentBuilder.swift"
SEARCH_REPOSITORY = CORE / "ClipboardRepository+SearchDocuments.swift"

TAG_STORE = APP / "Features" / "Clipboard" / "ClipboardTagStore.swift"
CLIPBOARD_STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
CONTROLLER = APP / "Stores" / "ClipboardController.swift"
SEARCH_COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardSearchCoordinator.swift"
FILTERS = APP / "Support" / "ClipboardFilters.swift"
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
SETTINGS = APP / "Features" / "Settings" / "ClipboardSettingsPane.swift"
SETTINGS_EXTRACTED = [
    APP / "Features" / "Settings" / "ClipboardTagManagementSection.swift",
]
APP_MODEL = APP / "App" / "AppModel.swift"

P8 = ROOT / "tools" / "verification" / "p8_clipboard_product_polish_checks.py"
P8I = ROOT / "tools" / "verification" / "p8i_settings_clipboard_system_checks.py"
P9A = ROOT / "tools" / "verification" / "p9a_clipboard_repository_storage_smoke.py"
P9B = ROOT / "tools" / "verification" / "p9b_clipboard_appstate_repository_integration_checks.py"
P11E = ROOT / "tools" / "verification" / "p11e_clipboard_hardening_checks.py"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    open_index = source.find("{", start)
    if open_index < 0:
        return ""
    depth = 0
    for index in range(open_index, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:]


def require(failures: list[dict[str, str]], code: str, ok: bool, detail: str, path: Path) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail, "path": rel(path)})


def contains_all(source: str, terms: list[str]) -> bool:
    return all(term in source for term in terms)


def target_membership(project: str, paths: list[Path]) -> dict[str, bool]:
    return {rel(path): path.name in project for path in paths}


def main() -> int:
    failures: list[dict[str, str]] = []
    required = [
        STEP2_PRD,
        STEP2_PLAN,
        STEP2_DISPATCH,
        APP_DATABASE,
        TAG_MODEL,
        TAG_REPOSITORY,
        TAG_STORE,
        CLIPBOARD_STORE,
        FILTERS,
        CONTROLLER,
        SEARCH_COORDINATOR,
        PANEL,
        *PANEL_EXTRACTED,
        FILTER_BAR,
        *FILTER_BAR_EXTRACTED,
        RECORD_VIEWS,
        *RECORD_VIEWS_EXTRACTED,
        SETTINGS,
        *SETTINGS_EXTRACTED,
        APP_MODEL,
        SEARCH_DOCUMENT,
        SEARCH_BUILDER,
        SEARCH_REPOSITORY,
        PROJECT,
        P8,
        P8I,
        P9A,
        P9B,
        P11E,
    ]
    for path in required:
        require(failures, "missing_required_file", path.exists(), "required Step 2 fact source is missing", path)

    app_database = read(APP_DATABASE)
    tag_model = read(TAG_MODEL)
    tag_repository = read(TAG_REPOSITORY)
    tag_store = read(TAG_STORE)
    clipboard_store = read(CLIPBOARD_STORE)
    filters = read(FILTERS)
    controller = read(CONTROLLER)
    search_coordinator = read(SEARCH_COORDINATOR)
    panel = "\n".join(read(path) for path in [PANEL, *PANEL_EXTRACTED])
    filter_bar = "\n".join(read(path) for path in [FILTER_BAR, *FILTER_BAR_EXTRACTED])
    record_views = "\n".join(read(path) for path in [RECORD_VIEWS, *RECORD_VIEWS_EXTRACTED])
    settings = "\n".join(read(path) for path in [SETTINGS, *SETTINGS_EXTRACTED])
    tag_management = "\n".join(read(path) for path in SETTINGS_EXTRACTED)
    app_model = read(APP_MODEL)
    search_document = read(SEARCH_DOCUMENT)
    search_builder = read(SEARCH_BUILDER)
    search_repository = read(SEARCH_REPOSITORY)
    project = read(PROJECT)
    p8 = read(P8)
    p8i = read(P8I)
    p9a = read(P9A)
    p9b = read(P9B)
    p11e = read(P11E)

    sanitizer = sanitizer_self_check()
    require(failures, "sanitizer_self_check_failed", bool(sanitizer.get("ok")), "shared sanitizer must redact local sensitive material", Path(__file__))

    require(
        failures,
        "schema_tags_missing",
        contains_all(app_database, ["clipboard_tags", "clipboard_record_tags", "normalized_name", "built_in_kind", "UNIQUE", "record_id", "tag_id"]),
        "database migration must create Tag and RecordTag schema with uniqueness constraints",
        APP_DATABASE,
    )
    require(
        failures,
        "tag_model_missing",
        contains_all(tag_model, ["public struct ClipboardTag", "public struct ClipboardRecordTag", "enum ClipboardTagBuiltInKind", "case favorite"]),
        "core Tag, RecordTag, and favorite built-in model missing",
        TAG_MODEL,
    )
    require(
        failures,
        "normalizer_contract_missing",
        contains_all(tag_model, ["ClipboardTagNameNormalizer", "precomposedStringWithCompatibilityMapping", "foldedWhitespace", "containsControlCharacter", "reservedAliases"]),
        "normalizer must fix NFKC, whitespace fold, control rejection, case fold, and reserved aliases",
        TAG_MODEL,
    )
    require(
        failures,
        "mutation_result_missing",
        contains_all(tag_model + tag_repository, ["ClipboardTagMutationResult", "affectedRecordIDs", "removedTagIDs", "selectedTagTransition", "searchInvalidation"]),
        "mutation result must expose affected records, removed tags, selected transition, and search invalidation",
        TAG_MODEL,
    )
    require(
        failures,
        "tag_repository_contract_missing",
        contains_all(
            tag_repository,
            [
                "final class ClipboardTagRepository",
                "func ensureFavoriteTag",
                "func loadTags",
                "func loadRecordTags",
                "func createTag",
                "func createTagAndAttach",
                "func renameTag",
                "func updateTagColor",
                "func reorderTags",
                "func deleteTag",
                "func mergeTag",
                "func addTag",
                "func removeTag",
                "func toggleFavorite",
            ],
        ),
        "ClipboardTagRepository must provide all Step 2 tag mutations",
        TAG_REPOSITORY,
    )
    require(
        failures,
        "repository_transactions_missing",
        "transaction" in tag_repository and "ON CONFLICT(record_id, tag_id) DO NOTHING" in tag_repository and "DELETE FROM clipboard_record_tags" in tag_repository,
        "delete/merge/add must use transaction or equivalent unique RecordTag consistency",
        TAG_REPOSITORY,
    )
    require(
        failures,
        "favorite_immutability_missing",
        contains_all(tag_repository, ["ClipboardTagMutationError.favoriteImmutable", "rejectFavorite", "merge target", "merge source"]),
        "favorite delete/rename/recolor/reorder/merge source/target must be rejected",
        TAG_REPOSITORY,
    )

    require(
        failures,
        "tag_store_missing",
        contains_all(tag_store, ["final class ClipboardTagStore: ObservableObject", "@Published private(set) var tags", "@Published private(set) var recordTags", "@Published var selectedTagID"]),
        "ClipboardTagStore must be the feature-level tag facts source",
        TAG_STORE,
    )
    require(
        failures,
        "clipboard_store_bridge_missing",
        "let tagStore: ClipboardTagStore" in clipboard_store and "tagStore.objectWillChange" in clipboard_store,
        "ClipboardStore must bridge ClipboardTagStore without duplicating tag facts",
        CLIPBOARD_STORE,
    )
    require(
        failures,
        "app_model_tag_facade_missing",
        "clipboardTagStore" in app_model and "toggleClipboardFavorite" in app_model and "setClipboardTagFilter" in app_model,
        "AppModel must expose thin tag/favorite facades",
        APP_MODEL,
    )

    require(
        failures,
        "filter_state_still_pinboard_fact",
        "selectedTagID: String?" in filters and "pinboardID" not in block(filters, "struct ClipboardFilterState"),
        "ClipboardFilterState must use selectedTagID instead of pinboardID as current filter fact",
        FILTERS,
    )
    require(
        failures,
        "controller_filter_not_tag_based",
        "recordTags" in search_coordinator and "selectedTagID" in search_coordinator and "pinboardID" not in block(search_coordinator, "static func applyFilters"),
        "search coordinator/controller filter path must filter by selectedTagID + RecordTag, not pinboardID",
        SEARCH_COORDINATOR,
    )

    active_ui = "\n".join([panel, filter_bar, record_views, settings])
    active_store = "\n".join([clipboard_store, controller, filters, app_model])
    forbidden_ui_tokens = ["Move to Pinboard", "Pinned Groups", "clearUnpinned", "pinboardName(", "onMoveToPinboard", "clipboard.context.moveToPinboard", "clipboard.policy.clearUnpinned"]
    forbidden_ui_hits = [token for token in forbidden_ui_tokens if token in active_ui]
    require(
        failures,
        "legacy_active_ui_tokens_remaining",
        not forbidden_ui_hits,
        "active UI still contains legacy pinboard/pinned surface tokens",
        RECORD_VIEWS,
    )
    forbidden_store_tokens = ["togglePin", "setPinboardFilter", "renamePinnedRecord", "pinnedMetadata", "ClipboardFilterState.pinboardID", "clearUnpinned", "pinnedCount"]
    forbidden_store_hits = [token for token in forbidden_store_tokens if token in active_store]
    require(
        failures,
        "legacy_active_store_paths_remaining",
        not forbidden_store_hits,
        "active store/app model/filter paths still expose legacy pinned/pinboard facts",
        CLIPBOARD_STORE,
    )

    require(
        failures,
        "ui_tag_filter_missing",
        "ClipboardFlatTagFilterChips" in filter_bar
        and "favoriteTag" in filter_bar
        and "tags.filter { !$0.isFavorite }" in filter_bar
        and "Circle()" in filter_bar
        and "ForEach(ClipboardFilterGroup.nonTagCases)" in panel
        and "ClipboardFilterGroup.tag" not in panel,
        "filter bar must expose flat favorite-first tag chips outside ordinary collapsed filter groups",
        FILTER_BAR,
    )
    require(
        failures,
        "ui_filter_tag_inline_management_missing",
        contains_all(
            filter_bar,
            [
                "editingTagID",
                "draftTagName",
                "pendingDeleteTag",
                ".contextMenu",
                "clipboard.tags.rename",
                "clipboard.tags.delete",
                "clipboard.tags.new",
                "TextField(\"\", text:",
                ".confirmationDialog",
                "isPresented:",
                "draggableTagChip",
                "localTagDragGesture",
                "beginLocalTagDrag",
                "updateLocalTagDrag",
                "finishLocalTagDrag",
                "clearLocalTagDragState",
                "panelTagInsertionCursor",
            ],
        )
        and "item: $pendingDeleteTag" not in filter_bar
        and contains_all(tag_store, ["createFilterTag", "renameFilterTag", "deleteFilterTag", "moveFilterTag"])
        and "guard !tag.isBuiltIn" in filter_bar
        and "favoriteTag" in filter_bar,
        "top filter tag chips must support inline create/rename/delete and ordinary-tag drag sorting while favorite stays fixed",
        FILTER_BAR,
    )
    require(
        failures,
        "ui_filter_tag_drag_insertion_cursor_missing",
        contains_all(
            filter_bar,
            [
                "ClipboardTagFramePreferenceKey",
                "tagFrames",
                "draggedTagID",
                "dropInsertionTargetKey",
                "filterTagDropTargetKeyBeforeFirst",
                "ClipboardTagDropInsertionIndicator",
                "minimumDistance: ClipboardFilterBarLayout.tagDragActivationDistance",
                ".onChanged",
                ".onEnded",
                "defer { clearLocalTagDragState() }",
                "calculateInsertionTarget",
                "afterTagID:",
                "Color.accentColor",
                "tagDropIndicatorHitWidth: CGFloat = 14",
                "panelTagInsertionCursorX",
                "tagDropTargetFrame",
                "handleTagPointerEnded",
                "isLocalTagDragging",
            ],
        )
        and "favoriteTag" in filter_bar
        and ".simultaneousGesture(localTagDragGesture" in filter_bar
        and ".onTapGesture" not in block(filter_bar, "private func draggableTagChip")
        and ".onDrag" not in filter_bar
        and ".onDrop(" not in filter_bar
        and "DropDelegate" not in filter_bar
        and "NSItemProvider" not in filter_bar
        and ".dropDestination(for: String.self)" not in filter_bar
        and ".draggable(favoriteTag.id)" not in filter_bar,
        "filter tag drag sorting must use local pointer drag with a visible insertion cursor while keeping favorite fixed",
        FILTER_BAR,
    )
    require(
        failures,
        "panel_tag_keyboard_activation_and_reorder_missing",
        contains_all(
            filter_bar,
            [
                "private func tagChip(tag:",
                "private func draggableTagChip(tag:",
                "Button {",
                "moveFilterTagUp",
                "moveFilterTagDown",
                "settings.clipboardTagsMoveUp",
                "settings.clipboardTagsMoveDown",
                "accessibilityAction(named: Text(",
            ],
        )
        and ".onTapGesture" not in block(filter_bar, "private func tagChip")
        and ".onTapGesture" not in block(filter_bar, "private func draggableTagChip"),
        "panel favorite and ordinary tags must use keyboard-focusable Buttons and ordinary tags need context/VoiceOver reorder actions",
        FILTER_BAR,
    )
    require(
        failures,
        "panel_tag_drag_cleanup_missing",
        contains_all(
            filter_bar,
            [
                ".onDisappear",
                "NSWindow.didResignKeyNotification",
                ".onChange(of: tags)",
                "clearLocalTagDragState()",
            ],
        ),
        "panel tag drag state must clear when the view disappears, the window resigns key, or tag values change",
        FILTER_BAR,
    )
    require(
        failures,
        "tag_color_palette_missing",
        contains_all(
            tag_store + filter_bar,
            [
                "ClipboardTagColorPalette",
                "blue",
                "green",
                "purple",
                "orange",
                "pink",
                "gray",
                "cyan",
                "mint",
                "repairLoadedTagColorsIfNeeded",
                "isValidPaletteToken",
                "nextTagColorToken",
                "updateTagColor",
            ],
        )
        and "enumerated().compactMap" not in block(tag_store, "private func repairLoadedTagColorsIfNeeded")
        and "desiredToken = ClipboardTagColorPalette.token(at: index)" not in tag_store
        and "colorToken: String = \"blue\"" not in tag_store
        and "colorToken: String? = nil" in tag_store,
        "existing ordinary tags must keep stable persisted colors; only missing/invalid colors may be repaired",
        TAG_STORE,
    )
    require(
        failures,
        "ui_filter_tag_blank_context_area_too_small",
        "tagBlankCreateTargetMinWidth: CGFloat = 120" in filter_bar
        and "blankCreateTarget" in filter_bar
        and ".contextMenu" in block(filter_bar, "private var blankCreateTarget"),
        "filter tag blank area must be large enough to create a tag from the empty strip region",
        FILTER_BAR,
    )
    require(
        failures,
        "settings_tag_drag_reorder_missing",
        contains_all(
            tag_management,
            [
                "ClipboardSettingsTagFramePreferenceKey",
                "settingsTagDropInsertionIndicator",
                "editingSettingsTagID",
                "settingsDraftTagName",
                "beginSettingsTagEdit",
                "commitSettingsTagEdit",
                "cancelSettingsTagEdit",
                "dismissSettingsTagEditOnOutsideTap",
                "settingsTagFrames",
                "settingsDraggedTagID",
                "settingsDropInsertionTargetKey",
                "minimumDistance: ClipboardFilterBarLayout.tagDragActivationDistance",
                "handleSettingsTagPointerEnded",
                "isSettingsTagDragging",
                "tagStore.moveFilterTag(",
            ],
        )
        and "ClipboardSettingsTagReorderDropDelegate" not in tag_management
        and ".onDrag" not in tag_management
        and ".onDrop(" not in tag_management
        and "DropDelegate" not in tag_management
        and "NSItemProvider" not in tag_management
        and "UTType.plainText" not in tag_management
        and "Image(systemName: \"arrow.up\")" not in tag_management
        and "Image(systemName: \"arrow.down\")" not in tag_management,
        "settings tag management must use the same local pointer drag reorder model as the panel",
        SETTINGS_EXTRACTED[0],
    )
    require(
        failures,
        "settings_tag_keyboard_activation_and_reorder_missing",
        contains_all(
            tag_management,
            [
                "Button(action: beginSettingsTagEdit)",
                "settingsTagContextMenu",
                "moveSettingsTagUp",
                "moveSettingsTagDown",
                "accessibilityAction(named: Text(L10n.string(\"settings.clipboardTagsMoveUp\")))",
                "accessibilityAction(named: Text(L10n.string(\"settings.clipboardTagsMoveDown\")))",
            ],
        )
        and ".onTapGesture" not in block(tag_management, "private var tagIdentity"),
        "ordinary settings tags must use Button activation and expose keyboard/VoiceOver reorder actions plus a context menu",
        SETTINGS_EXTRACTED[0],
    )
    require(
        failures,
        "settings_tag_drag_cleanup_missing",
        contains_all(
            tag_management,
            [
                ".onDisappear",
                "NSWindow.didResignKeyNotification",
                ".onChange(of: ordinaryTagIDs)",
                "clearSettingsTagDragState()",
            ],
        ),
        "settings tag drag state must clear when the view disappears, the window resigns key, or ordinary tags change",
        SETTINGS_EXTRACTED[0],
    )
    require(
        failures,
        "settings_tag_color_token_exposed",
        "tag.colorToken" not in block(tag_management, "struct ClipboardTagIdentityLabel"),
        "settings tag labels must not expose internal color tokens in help or accessibility text",
        SETTINGS_EXTRACTED[0],
    )
    require(
        failures,
        "settings_tag_delete_action_contract_missing",
        "ClipboardTagManagementSection" in settings
        and contains_all(
            tag_management,
            [
                "BlocksCompactIconButton(",
                "systemImage: \"trash\"",
                "emphasis: .destructive",
                "_ = deleteTag()",
                ".contextMenu",
                "settingsTagContextMenu",
                "Button(role: .destructive)",
                "accessibilityAction(named: Text(",
                "moveSettingsTagUp",
                "moveSettingsTagDown",
                "clearSettingsTagDragState()",
            ],
        )
        and all(token not in tag_management for token in ["hoveredTagID", "deleteButtonOpacity", "deleteButtonFocused"]),
        "settings tag deletion must use the shared destructive icon button with keyboard, VoiceOver, context-menu, and drag-cleanup coverage; hover-only visibility is not a contract",
        SETTINGS_EXTRACTED[0],
    )
    require(
        failures,
        "settings_tag_inline_edit_without_default_textfield",
        "TextField(tag.displayName" not in tag_management
        and "editingSettingsTagID" in tag_management
        and "settingsTagEditorFocused" in tag_management
        and ".onSubmit" in block(tag_management, "private var tagIdentity")
        and "commitSettingsTagEdit()" in block(tag_management, "private var tagIdentity")
        and ".onChange(of: settingsTagEditorFocused)" in tag_management
        and "@State private var editingTagID" not in tag_management
        and "ClipboardTagActionIcon(systemName: \"paintpalette\")" not in tag_management
        and "arrow.triangle.merge" not in tag_management
        and "Image(systemName: \"checkmark\")" not in tag_management,
        "settings custom tags must show static labels by default and switch to inline input on click, without the trailing rename/color/merge button row",
        SETTINGS_EXTRACTED[0],
    )
    require(
        failures,
        "ui_record_tag_menu_missing",
        contains_all(record_views, ["Button(action: onToggleFavorite)", "ClipboardTagMenu", "defaultQuickTagName"])
        and record_views.find("Button(action: onToggleFavorite)") < record_views.find("ClipboardTagMenu"),
        "record context menu must expose favorite as a first-level action above tag operations",
        RECORD_VIEWS,
    )
    require(
        failures,
        "settings_tag_management_missing",
        contains_all(settings, ["ClipboardTagManagementSection", "favorite", "deleteTag", "moveFilterTag"])
        and "Image(systemName: \"arrow.up\")" not in settings
        and "Image(systemName: \"arrow.down\")" not in settings,
        "settings must provide tag management with immutable favorite row and drag reorder",
        SETTINGS,
    )

    require(
        failures,
        "search_contract_missing",
        "tagTokens" in search_document and "tags:" in search_builder and "markSearchDocumentTagsDirty" in search_repository,
        "tag search contract must expose tag projection and invalidation hook",
        SEARCH_REPOSITORY,
    )

    verifier_sources = "\n".join([p8, p8i, p9a, p9b, p11e])
    require(
        failures,
        "old_verifier_ok_evidence_remaining",
        "baseline_reference" in verifier_sources and "tag" in p8.lower() and "tag" in p8i.lower() and "tag" in p9a.lower() and "tag" in p9b.lower(),
        "old P8/P8I/P9A/P9B checks must use current tag facts; old pinned/pinboard only baseline",
        P9B,
    )

    membership_paths = [TAG_MODEL, TAG_REPOSITORY, TAG_STORE]
    membership = target_membership(project, membership_paths)
    require(
        failures,
        "target_membership_missing",
        all(membership.values()),
        "new Step 2 Swift files must be in the Xcode project",
        PROJECT,
    )

    output: dict[str, Any] = {
        "ok": not failures,
        "gate": "P13B",
        "checked_files": [rel(path) for path in required],
        "target_membership": {
            "source": rel(PROJECT),
            "files": membership,
        },
        "current_evidence": {
            "source_docs": [rel(STEP2_PRD), rel(STEP2_PLAN), rel(STEP2_DISPATCH)],
            "schema": {
                "tags_table": "clipboard_tags" in app_database,
                "record_tags_table": "clipboard_record_tags" in app_database,
                "favorite_unique": "built_in_kind = 'favorite'" in app_database,
            },
            "store": {
                "tag_store": "ClipboardTagStore" in tag_store,
                "clipboard_store_bridge": "let tagStore: ClipboardTagStore" in clipboard_store,
            },
            "ui": {
                "tag_filter": "selectedTagID" in filter_bar + panel,
                "right_click_tags": "ClipboardTagMenu" in record_views,
                "settings_tags": "ClipboardTagManagementSection" in settings,
            },
            "filter_path": {
                "record_tags_argument": "recordTags" in search_coordinator,
                "selected_tag_gate": "selectedTagID" in block(search_coordinator, "static func applyFilters"),
            },
        },
        "legacy_exit": {
            "active_ui_tokens_clear": not forbidden_ui_hits,
            "active_store_paths_clear": not forbidden_store_hits,
            "filter_state_no_pinboard_fact": "pinboardID" not in block(filters, "struct ClipboardFilterState"),
            "right_click_no_move_to_pinboard": "onMoveToPinboard" not in record_views and "clipboard.context.moveToPinboard" not in record_views,
            "settings_no_pinboard_section": "pinboards" not in settings and "clipboard.policy.clearUnpinned" not in settings,
            "verifier_ok_evidence_clear": "tag" in verifier_sources.lower(),
            "legacy_storage_baseline_only": "clipboard_pinboards" in app_database and "clipboard_pinned_metadata" in app_database,
        },
        "tag_search": {
            "contract_gate": "pass" if "markSearchDocumentTagsDirty" in search_repository and "tagTokens" in search_document else "fail",
            "e2e_gate": "pass" if "verified_tag_fixtures" in p9a and "tag_search_missing_document_repair" in p9a and "tag_search_rebuild_path" in p9a else "residual_risk",
            "e2e_source": rel(P9A),
            "affected_record_ids_emitted": "affectedRecordIDs" in tag_model + tag_repository,
            "projection_available": "tagTokens" in search_document,
            "fixtures_body_excludes_tag_name": "fixture_body_excludes_tag_name" in p9a or "body_excludes_tag_name" in p9a,
        },
        "baseline_reference": {
            "old_pinboard_storage_allowed": True,
            "old_archives_used_for_ok": False,
            "old_pinned_verifier_evidence_used_for_ok": False,
        },
        "sanitizer": sanitizer,
        "failure_summary": {
            "count": len(failures),
            "codes": sorted({failure["code"] for failure in failures}),
        },
        "failures": failures,
    }
    print(json.dumps(sanitize_payload(output), ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1

if __name__ == "__main__":
    raise SystemExit(main())
