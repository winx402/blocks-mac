#!/usr/bin/env python3
"""P13-C clipboard panel interaction/layout checks for 004 Step 3."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verification_sanitizer import sanitize_payload, sanitizer_self_check


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"

STEP3 = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_3"
STEP3_PRD = STEP3 / "产品经理-PRD-v1.md"
STEP3_PLAN = STEP3 / "App架构师-技术方案-v1.md"
STEP3_DISPATCH = STEP3 / "项目负责人-开发派发-Step3-v0.md"
STEP3_DEV_RECORD = STEP3 / "开发记录-Step3-R1-v0.md"
MANIFEST = STEP3 / "evidence" / "p13c" / "manifest-v0.json"

PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
PANEL_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift",
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift",
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelInteractionCoordinator.swift",
]
PANEL_SESSION = APP / "Features" / "Clipboard" / "ClipboardPanelSessionModel.swift"
PANEL_FOCUS = APP / "Features" / "Clipboard" / "ClipboardPanelFocusCoordinator.swift"
PANEL_RECORD_CONTENT = APP / "Features" / "Clipboard" / "Records" / "ClipboardPanelRecordContent.swift"
POINTER_SURFACE = APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPointerSurface.swift"
PRESENTER = APP / "Services" / "ClipboardHistoryPanelPresenter.swift"
FILTER_BAR = APP / "Views" / "ClipboardFilterBarView.swift"
FILTER_TAG_CHIPS = APP / "Features" / "Clipboard" / "Filters" / "ClipboardTagFilterChips.swift"
FILTER_CONTROLS = APP / "Features" / "Clipboard" / "Filters" / "ClipboardFilterControls.swift"
FILTER_BAR_EXTRACTED = [
    FILTER_TAG_CHIPS,
    FILTER_CONTROLS,
]
RECORD_VIEWS = APP / "Views" / "ClipboardRecordViews.swift"
RECORD_VIEWS_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Records" / "ClipboardFloatingRecordRow.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordMenus.swift",
    PANEL_RECORD_CONTENT,
]
HOVER_DETAIL = APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationView.swift"
HOVER_TRACKING = APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationLayer.swift"
HOVER_DETAIL_EXTRACTED = [
    HOVER_TRACKING,
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPanel.swift",
    APP / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift",
]
PANEL_SETTINGS = APP / "Support" / "ClipboardPanelSettings.swift"
GLASS_PANEL = APP / "Support" / "GlassPanel.swift"
NOTIFICATION = APP / "Support" / "BlocksNotification.swift"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
APP_MODEL = APP / "App" / "AppModel.swift"
CLIPBOARD_COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift"
CLIPBOARD_COORDINATOR_EXTRACTED = [
    APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator+PanelPresentation.swift",
    APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator+CopyActions.swift",
]
PASTE_ORCHESTRATOR = APP / "Features" / "Clipboard" / "ClipboardPasteOrchestrator.swift"
CLIPBOARD_STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
PAYLOAD_ACCESS = APP / "Features" / "Clipboard" / "ClipboardPayloadAccess.swift"
RECORD_ACTION_PIPELINE = APP / "Features" / "Clipboard" / "ClipboardRecordActionPipeline.swift"
LIVE_CAPTURE = APP / "Services" / "ClipboardLiveCaptureService.swift"
P13A = ROOT / "tools" / "verification" / "p13a_clipboard_plaintext_search_ocr_checks.py"
P13B = ROOT / "tools" / "verification" / "p13b_clipboard_tags_model_checks.py"
P8 = ROOT / "tools" / "verification" / "p8_clipboard_product_polish_checks.py"
P8I = ROOT / "tools" / "verification" / "p8i_settings_clipboard_system_checks.py"
P9A = ROOT / "tools" / "verification" / "p9a_clipboard_repository_storage_smoke.py"
P9B = ROOT / "tools" / "verification" / "p9b_clipboard_appstate_repository_integration_checks.py"
P11E = ROOT / "tools" / "verification" / "p11e_clipboard_hardening_checks.py"

INTERACTION_FIXTURE = r'''
import AppKit
import Foundation

enum ClipboardPanelActivationTrigger: String {
    case singleClick
    case doubleClick
    case keyboard
    case contextMenu
    case button
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "P13CInteraction", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
@MainActor
struct P13CInteractionFixture {
    static func main() throws {
        let coordinator = ClipboardPanelInteractionCoordinator()
        var selectedRecordID: String?
        var actions: [ClipboardPanelActionKind] = []
        let select: @MainActor () -> Bool = {
            selectedRecordID = "record-a"
            return true
        }
        let perform: @MainActor (ClipboardPanelActivationTrigger, ClipboardPanelActionKind) -> Void = { _, action in
            actions.append(action)
        }

        coordinator.routeActivation(
            recordID: "record-a",
            source: .bottomCard,
            trigger: .singleClick,
            onSelect: select,
            onPerform: perform
        )
        try require(actions == [.detailOpen], "a single click must select and open detail synchronously")

        coordinator.resetTransientState()
        selectedRecordID = nil
        actions.removeAll()
        coordinator.routeActivation(
            recordID: "record-a",
            source: .bottomCard,
            trigger: .doubleClick,
            onSelect: select,
            onPerform: perform
        )
        try require(actions == [.paste], "an exclusive double click must paste exactly once")
        print("P13C_INTERACTION_OK")
    }
}
'''


def run_interaction_fixture() -> tuple[bool, str]:
    source_path = APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelInteractionCoordinator.swift"
    source = read(source_path).split("extension View", maxsplit=1)[0]
    with tempfile.TemporaryDirectory(prefix="blocks_p13c_interaction_") as temporary:
        temp = Path(temporary)
        coordinator = temp / source_path.name
        coordinator.write_text(source, encoding="utf-8")
        fixture = temp / "P13CInteractionFixture.swift"
        fixture.write_text(textwrap.dedent(INTERACTION_FIXTURE), encoding="utf-8")
        executable = temp / "P13CInteractionFixture"
        compiled = subprocess.run(
            [
                "xcrun", "--sdk", "macosx", "swiftc",
                str(coordinator), str(fixture), "-o", str(executable),
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
        if executed.returncode or "P13C_INTERACTION_OK" not in executed.stdout:
            return False, "fixture_execution"
        return True, "ok"

SENSITIVE_PATTERNS = [
    re.compile(r"/Users/[^\\s\"']+"),
    re.compile(r"/private/[^\\s\"']+"),
    re.compile(r"/tmp/[^\\s\"']+"),
    re.compile(r"(?<![\\w.+-])[\\w.+-]+@[\\w.-]+\\.[A-Za-z]{2,}(?![\\w.+-])"),
    re.compile(r"Authorization", re.IGNORECASE),
    re.compile(r"Bearer", re.IGNORECASE),
    re.compile(r"secret", re.IGNORECASE),
    re.compile(r"api[_-]?key", re.IGNORECASE),
    re.compile(r"base64", re.IGNORECASE),
    re.compile(r"payloadBody", re.IGNORECASE),
    re.compile(r"ocrRawText", re.IGNORECASE),
    re.compile(r"qrCode", re.IGNORECASE),
    re.compile(r"verificationCode", re.IGNORECASE),
]

REQUEST_EVENTS = {
    "single_click_paste": "pasteRequested",
    "double_click_paste": "pasteRequested",
    "detail_open": "detailRequested",
    "ocr_retry": "ocrRetryRequested",
}

REQUIRED_SCENARIOS = set(REQUEST_EVENTS) | {"rapid_click_stale_completion"}
KEYBOARD_REQUIRED = {
    "keyboard-search-focus",
    "keyboard-filter-expand-collapse",
    "keyboard-all-favorite-ordinary-tag",
    "keyboard-clear-filter",
    "keyboard-record-list-focus-selected",
    "keyboard-cmd-digit-quick-paste",
    "keyboard-settings-close",
    "keyboard-ocr-retry",
    "keyboard-detail-open",
    "keyboard-no-focus-trap",
}
VOICEOVER_REQUIRED = {
    "voiceover-search-label",
    "voiceover-active-filter-all",
    "voiceover-expanded-collapsed",
    "voiceover-selected-focused",
    "voiceover-favorite",
    "voiceover-ocr-status",
    "voiceover-cmd-digit-hint",
    "voiceover-long-tag",
    "voiceover-settings-close-clear",
}

def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def block(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        return ""
    open_index = source.find("{", start)
    if open_index < 0:
        return source[start:]
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


def clipboard_panel_wiring_checks(
    panel_root: str,
    panel_header: str,
    panel_layout: str,
    panel_record_content: str,
) -> dict[str, bool]:
    header_actions = block(panel_root, "private var headerActions")
    layout_actions = block(panel_root, "private var layoutActions")
    bottom_builder = block(panel_record_content, "func bottomRecordCard(")
    side_builder = block(panel_record_content, "func sideRecordRow(")
    pagination = block(panel_root, "private func onRecordAppearedForPagination(")
    resize_update = block(panel_root, "private func updateSideRowHeightResize(")
    resize_finish = block(panel_root, "private func finishSideRowHeightResize(")
    resize_reset = block(panel_root, "private func resetSideRowHeightResize(")
    normalize_selection = block(panel_root, "private func normalizeSelection(")
    filter_strip = block(panel_header, "private var filterStrip")
    trailing_action = block(panel_header, "private var trailingActionGroup")
    tray = block(panel_layout, "private var pasteStyleTray")
    list_view = block(panel_layout, "private var recordList")
    resize_handle = block(panel_layout, "private struct ClipboardSideRowHeightResizeHandle")

    return {
        "hover_enter": (
            "onExpandedHoverEnter: actions.onExpandedHoverEnter" in filter_strip
            and "onExpandedHoverEnter: cancelPendingFilterCollapse" in header_actions
        ),
        "hover_exit": (
            "onExpandedHoverExit: { actions.onExpandedHoverExit(group) }" in filter_strip
            and "onExpandedHoverExit: scheduleExpandedFilterCollapse" in header_actions
        ),
        "pagination": (
            "bottomRecordBuilder(record, offset, cardHeight, bodyLineLimit)" in tray
            and "sideRecordBuilder(record, offset, rowHeight, bodyLineLimit)" in list_view
            and ".onAppear" in bottom_builder
            and "onRecordAppeared(offset)" in bottom_builder
            and ".onAppear" in side_builder
            and "onRecordAppeared(offset)" in side_builder
            and "loadNextPageIfNeeded(offset: offset)" in pagination
            and ".onAppear" not in panel_layout
            and "Pagination" not in panel_layout
        ),
        "pin": (
            "actions.onTogglePin()" in trailing_action
            and "onTogglePin: {" in header_actions
            and "dismissFloatingDetail()" in header_actions
            and "onTogglePin()" in header_actions
        ),
        "resize": (
            "onHeightChanged(handleID, currentHeight, value.translation.height)" in resize_handle
            and "onHeightChangeEnded(handleID, currentHeight, value.translation.height)" in resize_handle
            and "onHeightChanged: actions.onSideRowHeightResizeChanged" in list_view
            and "onHeightChangeEnded: actions.onSideRowHeightResizeEnded" in list_view
            and "onSideRowHeightResizeChanged: updateSideRowHeightResize" in layout_actions
            and "onSideRowHeightResizeEnded: finishSideRowHeightResize" in layout_actions
            and "activeSideRowHeightResizeHandleID = handleID" in resize_update
            and "previewSideRowHeight(startHeight + translationHeight)" in resize_update
            and "activeSideRowHeightResizeHandleID == handleID" in resize_finish
            and "commitSideRowHeight(startHeight + translationHeight)" in resize_finish
            and "resetSideRowHeightResize()" in resize_finish
            and "sideRowHeightResizeDragStartHeight = nil" in resize_reset
            and "activeSideRowHeightResizeHandleID = nil" in resize_reset
            and "sideRowHeightDragValue = nil" in resize_reset
            and "resetSideRowHeightResizeIfIdentityMissing()" in normalize_selection
        ),
    }


def clipboard_panel_wiring_mutations_fail_closed(
    panel_root: str,
    panel_header: str,
    panel_layout: str,
    panel_record_content: str,
) -> bool:
    sources = {
        "root": panel_root,
        "header": panel_header,
        "layout": panel_layout,
        "record_content": panel_record_content,
    }
    mutations = [
        ("hover_enter", "root", "onExpandedHoverEnter: cancelPendingFilterCollapse", "onExpandedHoverEnter: {}"),
        ("hover_exit", "root", "onExpandedHoverExit: scheduleExpandedFilterCollapse", "onExpandedHoverExit: { _ in }"),
        ("pagination", "root", "loadNextPageIfNeeded(offset: offset)", "_ = offset"),
        ("pin", "header", "actions.onTogglePin()", "()"),
        ("resize", "root", "onSideRowHeightResizeChanged: updateSideRowHeightResize", "onSideRowHeightResizeChanged: { _, _, _ in }"),
        ("resize", "root", "resetSideRowHeightResizeIfIdentityMissing()\n        guard", "_ = filteredRecords\n        guard"),
    ]
    for check_name, source_name, original, replacement in mutations:
        if original not in sources[source_name]:
            return False
        mutated = dict(sources)
        mutated[source_name] = mutated[source_name].replace(original, replacement, 1)
        checks = clipboard_panel_wiring_checks(
            mutated["root"],
            mutated["header"],
            mutated["layout"],
            mutated["record_content"],
        )
        if checks[check_name]:
            return False
    return True


def add_failure(failures: list[dict[str, str]], code: str, detail: str, path: Path | None = None) -> None:
    item = {"code": code, "detail": detail}
    if path is not None:
        item["path"] = rel(path)
    failures.append(item)


def contains_sensitive_text(value: Any) -> bool:
    text = json.dumps(value, ensure_ascii=False, sort_keys=True) if not isinstance(value, str) else value
    return any(pattern.search(text) for pattern in SENSITIVE_PATTERNS)


def localizations_for_key(catalog: dict[str, Any], key: str) -> dict[str, Any]:
    value = catalog.get("strings", {}).get(key, {})
    return value.get("localizations", {}) if isinstance(value, dict) else {}


def localized_key_has_all_languages(catalog: dict[str, Any], key: str) -> bool:
    localizations = localizations_for_key(catalog, key)
    for language in ["zh-Hans", "en", "ja"]:
        unit = localizations.get(language, {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value"):
            return False
    return True


def localized_value(catalog: dict[str, Any], key: str, language: str) -> str:
    return str(
        localizations_for_key(catalog, key)
        .get(language, {})
        .get("stringUnit", {})
        .get("value", "")
    )


def load_manifest(failures: list[dict[str, str]]) -> dict[str, Any]:
    if not MANIFEST.exists():
        add_failure(failures, "manifest_missing", "P13C evidence manifest is required", MANIFEST)
        return {}
    try:
        manifest = json.loads(read(MANIFEST))
    except json.JSONDecodeError as error:
        add_failure(failures, "manifest_invalid_json", f"manifest JSON parse failed: {error.msg}", MANIFEST)
        return {}
    if contains_sensitive_text(manifest):
        add_failure(failures, "manifest_sensitive_content", "manifest contains sensitive or forbidden token", MANIFEST)
    return manifest if isinstance(manifest, dict) else {}


def validate_relative_artifact(path_value: str, failures: list[dict[str, str]], owner: str) -> Path | None:
    if not path_value:
        add_failure(failures, "artifact_path_missing", f"{owner} missing artifact path", MANIFEST)
        return None
    path = Path(path_value)
    if path.is_absolute():
        add_failure(failures, "artifact_absolute_path", f"{owner} artifact path must be repository-relative", MANIFEST)
        return None
    resolved = ROOT / path
    try:
        resolved.relative_to(STEP3)
    except ValueError:
        add_failure(failures, "artifact_outside_step3", f"{owner} artifact must live under current Step 3 evidence", MANIFEST)
        return None
    if not resolved.exists():
        add_failure(failures, "artifact_missing", f"{owner} artifact file is missing", resolved)
        return None
    content = read(resolved)
    if contains_sensitive_text(content):
        add_failure(failures, "artifact_sensitive_content", f"{owner} artifact contains sensitive or forbidden token", resolved)
    return resolved


def validate_viewports(manifest: dict[str, Any], failures: list[dict[str, str]]) -> int:
    entries = manifest.get("viewportEvidence", [])
    if not isinstance(entries, list) or not entries:
        add_failure(failures, "viewport_evidence_missing", "viewportEvidence must be a non-empty list", MANIFEST)
        return 0

    positions = set()
    width_categories = set()
    states = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            add_failure(failures, "viewport_entry_invalid", f"viewport entry {index} must be object", MANIFEST)
            continue
        owner = f"viewport[{index}]"
        required = ["evidenceID", "position", "widthCategory", "heightCategory", "actualWidth", "actualHeight", "fixtureID", "state", "artifactPath"]
        missing = [field for field in required if field not in entry or entry.get(field) in ("", None)]
        if missing:
            add_failure(failures, "viewport_field_missing", f"{owner} missing {', '.join(missing)}", MANIFEST)
        if entry.get("position") not in {"bottom", "side"}:
            add_failure(failures, "viewport_position_invalid", f"{owner} position must be bottom or side", MANIFEST)
        if not isinstance(entry.get("actualWidth"), int) or not isinstance(entry.get("actualHeight"), int):
            add_failure(failures, "viewport_size_invalid", f"{owner} actual sizes must be integers", MANIFEST)
        positions.add(entry.get("position"))
        width_categories.add(entry.get("widthCategory"))
        states.add(entry.get("state"))
        validate_relative_artifact(str(entry.get("artifactPath", "")), failures, owner)

    required_widths = {"bottom_min_width", "bottom_regular_width", "bottom_wide_width", "side_min_width", "side_default_width", "side_wide_width"}
    required_states = {"all", "favorite_filter_active", "ordinary_tag_active", "long_tag_label", "expanded_filter_group", "single_click_mode", "double_click_mode", "clear_filter_visible", "settings_close_visible"}
    if positions != {"bottom", "side"}:
        add_failure(failures, "viewport_positions_incomplete", "viewport evidence must cover bottom and side", MANIFEST)
    missing_widths = sorted(required_widths - width_categories)
    if missing_widths:
        add_failure(failures, "viewport_width_categories_missing", ", ".join(missing_widths), MANIFEST)
    missing_states = sorted(required_states - states)
    if missing_states:
        add_failure(failures, "viewport_states_missing", ", ".join(missing_states), MANIFEST)
    return len(entries)


def events_by_scenario(events: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for event in events:
        grouped.setdefault(str(event.get("scenario", "")), []).append(event)
    return grouped


def validate_interaction_events(manifest: dict[str, Any], failures: list[dict[str, str]]) -> int:
    events = manifest.get("interactionEvents", [])
    if not isinstance(events, list) or not events:
        add_failure(failures, "interaction_events_missing", "interactionEvents must be a non-empty list", MANIFEST)
        return 0
    if contains_sensitive_text(events):
        add_failure(failures, "interaction_events_sensitive_content", "interaction event log contains forbidden token", MANIFEST)
    for index, event in enumerate(events):
        if not isinstance(event, dict):
            add_failure(failures, "interaction_event_invalid", f"event {index} must be object", MANIFEST)
            continue
        missing = [field for field in ["scenario", "recordFixtureID", "recordSyntheticID", "seq", "t", "event", "source"] if field not in event]
        if missing:
            add_failure(failures, "interaction_event_field_missing", f"event {index} missing {', '.join(missing)}", MANIFEST)
        if not isinstance(event.get("seq"), int) or not isinstance(event.get("t"), int):
            add_failure(failures, "interaction_event_time_invalid", f"event {index} seq/t must be integer", MANIFEST)

    grouped = events_by_scenario([event for event in events if isinstance(event, dict)])
    missing_scenarios = sorted(REQUIRED_SCENARIOS - set(grouped))
    if missing_scenarios:
        add_failure(failures, "interaction_scenarios_missing", ", ".join(missing_scenarios), MANIFEST)
    for scenario, scenario_events in grouped.items():
        seqs = [event.get("seq") for event in scenario_events]
        if seqs != sorted(seqs):
            add_failure(failures, "interaction_sequence_not_monotonic", scenario, MANIFEST)
        if scenario in REQUEST_EVENTS:
            selected_at = min((event["seq"] for event in scenario_events if event.get("event") == "selected"), default=None)
            focused_at = min((event["seq"] for event in scenario_events if event.get("event") == "focused"), default=None)
            request_at = min((event["seq"] for event in scenario_events if event.get("event") == REQUEST_EVENTS[scenario]), default=None)
            if selected_at is None or focused_at is None or request_at is None:
                add_failure(failures, "interaction_required_event_missing", scenario, MANIFEST)
            elif not (selected_at < request_at and focused_at < request_at):
                add_failure(failures, "interaction_order_invalid", scenario, MANIFEST)
        if scenario == "double_click_paste":
            first_click_events = [event.get("event") for event in scenario_events if event.get("phase") == "first_click"]
            if "pasteRequested" in first_click_events:
                add_failure(failures, "double_click_first_click_pastes", "first click must only select/focus", MANIFEST)
        if scenario == "rapid_click_stale_completion":
            final_events = [event for event in scenario_events if event.get("event") == "finalSelected"]
            stale_events = [event for event in scenario_events if event.get("event") == "staleCompletionIgnored"]
            if not final_events or final_events[-1].get("recordSyntheticID") != "fixture-record-b":
                add_failure(failures, "rapid_click_final_selection_invalid", "rapid click final selection must be record B", MANIFEST)
            if not stale_events:
                add_failure(failures, "rapid_click_stale_completion_missing", "stale completion ignored event required", MANIFEST)
    return len(grouped)


def validate_checklists(manifest: dict[str, Any], key: str, required_ids: set[str], failures: list[dict[str, str]]) -> int:
    entries = manifest.get(key, [])
    if not isinstance(entries, list) or not entries:
        add_failure(failures, f"{key}_missing", f"{key} must be a non-empty list", MANIFEST)
        return 0
    seen_ids: set[str] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            add_failure(failures, f"{key}_entry_invalid", f"{key}[{index}] must be object", MANIFEST)
            continue
        owner = f"{key}[{index}]"
        required_fields = ["evidence_id", "date", "tester", "build_or_commit", "locale", "viewport_category", "actual_width", "actual_height", "panel_position", "fixture_ids", "artifact_paths", "checks"]
        missing = [field for field in required_fields if field not in entry or entry.get(field) in ("", None, [])]
        if missing:
            add_failure(failures, f"{key}_field_missing", f"{owner} missing {', '.join(missing)}", MANIFEST)
        if entry.get("panel_position") not in {"bottom", "side"}:
            add_failure(failures, f"{key}_position_invalid", f"{owner} invalid panel position", MANIFEST)
        for artifact in entry.get("artifact_paths", []):
            validate_relative_artifact(str(artifact), failures, owner)
        checks = entry.get("checks", [])
        if not isinstance(checks, list):
            add_failure(failures, f"{key}_checks_invalid", f"{owner} checks must be list", MANIFEST)
            continue
        for check in checks:
            if not isinstance(check, dict):
                add_failure(failures, f"{key}_check_invalid", f"{owner} check must be object", MANIFEST)
                continue
            check_id = str(check.get("id", ""))
            seen_ids.add(check_id)
            if "pass" not in check or not isinstance(check.get("pass"), bool):
                add_failure(failures, f"{key}_check_pass_missing", f"{owner}:{check_id}", MANIFEST)
            if check.get("pass") is False:
                add_failure(failures, f"{key}_check_failed", f"{owner}:{check_id}", MANIFEST)
            if contains_sensitive_text(check):
                add_failure(failures, f"{key}_check_sensitive_content", f"{owner}:{check_id}", MANIFEST)
    missing_ids = sorted(required_ids - seen_ids)
    if missing_ids:
        add_failure(failures, f"{key}_required_checks_missing", ", ".join(missing_ids), MANIFEST)
    return len(entries)


def validate_static_sources(failures: list[dict[str, str]]) -> dict[str, bool]:
    panel_root = read(PANEL)
    panel_header = read(PANEL_EXTRACTED[0])
    panel_layout = read(PANEL_EXTRACTED[1])
    panel_interaction = read(PANEL_EXTRACTED[2])
    panel_session = read(PANEL_SESSION)
    panel_focus = read(PANEL_FOCUS)
    panel_record_content = read(PANEL_RECORD_CONTENT)
    pointer_surface = read(POINTER_SURFACE)
    panel = "\n".join([panel_root, panel_header, panel_layout, panel_interaction, panel_session, panel_record_content])
    bottom_builder = block(panel_record_content, "func bottomRecordCard(")
    side_builder = block(panel_record_content, "func sideRecordRow(")
    record_values = block(panel_record_content, "private func recordValues(")
    presenter = read(PRESENTER)
    filter_bar_primary = read(FILTER_BAR)
    filter_controls = read(FILTER_CONTROLS)
    filter_bar = "\n".join(read(path) for path in [FILTER_BAR, *FILTER_BAR_EXTRACTED])
    record_views = "\n".join(read(path) for path in [RECORD_VIEWS, *RECORD_VIEWS_EXTRACTED])
    hover_detail_primary = read(HOVER_DETAIL)
    hover_tracking = read(HOVER_TRACKING)
    hover_detail = "\n".join(read(path) for path in [HOVER_DETAIL, *HOVER_DETAIL_EXTRACTED])
    panel_settings = read(PANEL_SETTINGS)
    glass_panel = read(GLASS_PANEL)
    notification = read(NOTIFICATION)
    app_model = read(APP_MODEL)
    clipboard_coordinator = "\n".join(
        [read(CLIPBOARD_COORDINATOR)]
        + [read(path) for path in CLIPBOARD_COORDINATOR_EXTRACTED]
        + [read(PASTE_ORCHESTRATOR)]
    )
    store = read(CLIPBOARD_STORE)
    payload_access = read(PAYLOAD_ACCESS)
    record_action_pipeline = read(RECORD_ACTION_PIPELINE)
    live_capture = read(LIVE_CAPTURE)
    core_sources = "\n".join(read(path) for path in CORE.glob("*.swift"))
    row_body = block(record_views, "struct ClipboardFloatingRecordRow").split(".contextMenu", 1)[0]
    card_full = block(record_views, "struct ClipboardFloatingRecordCard")
    card_body = card_full.split(".contextMenu", 1)[0]
    direct_preview = block(record_views, "struct ClipboardDirectContentPreview")
    bottom_line_limit = block(panel, "private func bottomRecordCardBodyLineLimit")
    store_preview = block(store, "func preview(for record:")
    image_preview = block(store, "private func previewImage")
    short_preview = block(live_capture, "private static func shortPreview")
    primary_record_bodies = row_body + "\n" + card_body
    bottom_header = block(panel, "private var bottomHeader")
    side_header = block(panel, "private var sideHeader")
    side_filter_strip = block(panel, "private var sideFilterStrip")
    side_tag_filter_strip = block(panel, "private var sideTagFilterStrip")
    tag_filter_chips = block(panel, "private var tagFilterChips")
    trailing_action = block(panel, "private var trailingActionGroup")
    search_bar = block(panel, "private var searchBar")
    escape_command = block(panel_root, "private func handleEscapeCommand")
    handle_action = block(panel, "private func handleRecordAction")
    confirm_removal = block(panel, "private func confirmPendingRecordRemoval")
    search_change = block(panel, ".onChange(of: session.query)")
    primary_activation = block(panel, "private func onPrimaryActivation")
    activation_decision = block(panel_interaction, "static func resolve(")
    activation_route = block(panel_interaction, "func routeActivation(")
    present_detail = block(panel_root, "private func presentFloatingDetail")
    set_hover = block(panel, "private func setHoveredRecordID")
    local_mouse_move = block(hover_detail, "private func handleLocalMouseMoved")
    screen_mouse_move = block(hover_detail, "private func handleScreenMouseMoved")
    show_detail = block(hover_detail, "private func showDetail")
    detail_panel_frame = block(hover_detail, "private func detailPanelFrame")
    detail_card = block(hover_detail, "struct ClipboardFloatingDetailCard")
    content_container = block(presenter, "private final class ClipboardPanelContentContainer")
    make_panel = block(presenter, "private func makePanel")
    open_settings_from_panel = block(presenter, "private func openSettingsFromPanel")
    request_close_panel = block(presenter, "private func requestClosePanel")
    toggle_panel_pinned = block(presenter, "private func togglePanelPinned")
    start_dismiss_monitor = block(presenter, "private func startDismissMonitorAfterOpen")
    quick_paste_entry = block(clipboard_coordinator, "func pasteQuickRecord(index: Int)")
    quick_paste_request_builder = block(clipboard_coordinator, "private func makeQuickPasteRequest(index: Int)")
    quick_paste_panel_route = block(panel_root, "private func handleKeyboardCommand")
    global_state_sources = "\n".join([app_model, store, core_sources])
    try:
        localizable_catalog = json.loads(read(LOCALIZABLE))
    except json.JSONDecodeError:
        localizable_catalog = {}

    direct_paste_terms = ["onPaste()", "pasteClipboardRecord(", "action: .paste", "performPaste"]
    direct_paste_bypass = any(term in primary_record_bodies for term in direct_paste_terms)
    paste_activation_sources = "\n".join([panel, record_views, hover_detail, panel_settings])
    quick_paste_terms = [
        "ClipboardPanelKeyboardCommandRouter",
        "case let .quickPaste(index)",
        "override func sendEvent",
        "kVK_ANSI_1",
        "kVK_ANSI_Keypad1",
        "pasteClipboardQuickRecord(index:",
        "clipboardHistoryPanelPresenter.isVisible",
        "currentSearchResult.records",
    ]
    quick_paste_sources = "\n".join([panel, panel_focus, presenter, app_model, clipboard_coordinator])
    quick_paste_routing_present = all(term in quick_paste_sources for term in quick_paste_terms)
    quick_paste_single_request_builder = (
        "let pasteQuickRecord: (Int) -> Void" in presenter
        and "actions.pasteQuickRecord(index)" in quick_paste_panel_route
        and "pasteQuickRecord: { [weak self] in self?.pasteQuickRecord(index: $0) }" in clipboard_coordinator
        and "makeQuickPasteRequest(index: index)" in quick_paste_entry
        and "snapshotRecordID ?? fallbackRecordID" in quick_paste_entry
        and all(term in quick_paste_request_builder for term in [
            "clipboardHistoryPanelPresenter.isVisible",
            "clipboardHistoryPanelPresenter.quickPasteSnapshotRecordID(index: index)",
            "clipboardStore.currentSearchResult.records",
            "clipboardStore.records",
            "fallbackRecordIDs: sourceRecords.map(\\.id)",
        ])
        and "currentSearchResult.records" not in quick_paste_panel_route
        and "clipboardStore.records" not in quick_paste_panel_route
        and "quickPasteSnapshotRecordID" not in quick_paste_panel_route
        and "ClipboardPanelQuickPasteRequest" not in presenter + clipboard_coordinator
        and clipboard_coordinator.count("makeQuickPasteRequest(index:") == 2
    )
    quick_paste_hint_terms = [
        "ClipboardQuickPasteHintState",
        "onCommandModifierChanged",
        "quickPasteHintState.isCommandKeyPressed",
        "snapshotRecordIDs",
        "snapshotCaptured",
        "captureSnapshotIfNeeded",
        "quickPasteIndex(record.id)",
        "quickPasteIndex:",
        "ClipboardQuickPasteNumberBadge",
        ".overlay(alignment: .bottomTrailing)",
    ]
    quick_paste_hints_present = all(term in panel + "\n" + presenter + "\n" + record_views for term in quick_paste_hint_terms)
    quick_paste_state = block(presenter, "final class ClipboardQuickPasteHintState")
    panel_send_event = block(presenter, "override func sendEvent")
    short_preview_limit_match = re.search(r"singleLine\.count\s*>\s*(\d+)", short_preview)
    short_preview_limit = int(short_preview_limit_match.group(1)) if short_preview_limit_match else 0
    panel_wiring = clipboard_panel_wiring_checks(panel_root, panel_header, panel_layout, panel_record_content)
    panel_wiring_mutations_fail_closed = clipboard_panel_wiring_mutations_fail_closed(
        panel_root,
        panel_header,
        panel_layout,
        panel_record_content,
    )

    checks = {
        "current_docs_present": STEP3_PRD.exists() and STEP3_PLAN.exists() and STEP3_DISPATCH.exists(),
        "dev_record_present": STEP3_DEV_RECORD.exists(),
        "hover_delayed_collapse": all(
            term in filter_bar + panel_root + panel_session
            for term in [
                "collapseDelay",
                "safeBridgePadding",
                "safeRegionInflation",
                "pendingFilterCollapseTask",
                "cancelPendingFilterCollapse",
                "1_500_000_000",
            ]
        ),
        "hover_safe_bridge_hit_transparent": "allowsHitTesting(false)" in filter_bar and "safeBridgePadding: 22" in filter_bar and "safeRegionInflation: 34" in filter_bar,
        "hover_no_global_event_monitor": "NSEvent.addGlobalMonitorForEvents" not in filter_bar + panel,
        "paste_activation_control_removed": "private var pasteActivationModeControl" not in panel and "normalizePasteActivationMode" not in panel,
        "paste_activation_storage_removed": "clipboard.panel.pasteActivationMode" not in paste_activation_sources and "ClipboardPanelSettings.Keys.pasteActivationMode" not in paste_activation_sources,
        "paste_activation_type_removed": "ClipboardPasteActivationMode" not in paste_activation_sources,
        "fixed_single_double_activation": "routeActivation(" in primary_activation and "case .selectImmediately" in activation_route and "onSelect()" in activation_route and "switch trigger" in activation_decision and "case .selection" in activation_decision and "case .singleClick" in activation_decision and "return .perform(.detailOpen)" in activation_decision and "case .doubleClick" in activation_decision and "return .perform(.paste)" in activation_decision,
        "paste_panel_uses_frozen_nonactivating_target_context": (
            "ClipboardPanelInvocationContext" in presenter
            and "ClipboardExternalTargetTracker" in presenter
            and "ClipboardHistoryPanelStyle.mask" in make_panel
            and ".nonactivatingPanel" in presenter
            and "NSApp.activate" not in presenter
            and "func releasePanelForPaste(sessionID:" in presenter
            and "if pinState.isPinned" in presenter
            and "panel.resignKey()" in presenter
            and "panel.close()" in presenter
            and "func targetContextForPaste()" in presenter
            and "invocationContext?.targetContext" in presenter
            and "func updatePinnedTargetContext" in presenter
            and "hideForPaste" not in presenter + clipboard_coordinator
            and "finishPaste" not in presenter + clipboard_coordinator
            and "PastePresentationState" not in presenter
            and "clipboardHistoryPanelPresenter.releasePanelForPaste(sessionID:" in clipboard_coordinator
        ),
        "single_click_disambiguation_survives_record_rerender": (
            "pendingPrimaryActivationTask" not in record_views
            and record_views.count(".exclusively(before: TapGesture(count: 1))") >= 2
            and record_views.count("case .first: activateDoubleClick()") >= 2
            and record_views.count("case .second: activateSingleClick()") >= 2
            and record_views.count(".simultaneousGesture(") >= 2
            and record_views.count("onPrimaryActivation(.selection)") >= 2
        ),
        "single_click_detail_feedback_is_prompt": (
            "ClipboardRecordInteractionTiming" not in record_views
            and "singleClickActivationTask" not in panel_interaction
            and "case .singleClick" in activation_decision
        ),
        "double_click_suppression_is_record_scoped": (
            record_views.count("TapGesture(count: 2)") >= 2
            and record_views.count(".exclusively(before: TapGesture(count: 1))") >= 2
            and "suppressSingleClickUntil" not in panel_interaction
        ),
        "direct_paste_gesture_removed": (
            "ClipboardRecordPointerSurface" in primary_record_bodies
            and "onDoubleClick" in pointer_surface
            and "onPaste" not in pointer_surface
            and not direct_paste_bypass
        ),
        "activation_handler_present": "onPrimaryActivation" in record_views + panel and "ClipboardPanelActivationTrigger" in record_views + panel,
        "single_click_detail_does_not_open_inline_editor": "case .selectOnly" in handle_action and "case .selectOnly:\n            clipboardStore.openDetailEditor" not in handle_action,
        "single_click_detail_uses_ns_panel": "detailRecordID" in panel and "presentedRecordID:" in panel and "presentPresentedDetailIfNeeded" in hover_detail and "ClipboardHoverDetailPanel" in hover_detail and "NSPanel" in hover_detail,
        "search_partial_results_banner_removed": "searchStatusBanner" not in panel and "inlineSearchStatus" not in panel and "case .partialIndexing:\n            return nil" in read(APP / "Features" / "Clipboard" / "ClipboardSearchCoordinator.swift"),
        "single_click_same_record_toggles_detail": "case .selectOnly:\n            presentFloatingDetail(recordID: recordID)" in handle_action and "toggleFloatingDetail(recordID:" not in panel,
        "outside_click_dismisses_floating_detail": "dismissFloatingDetail()" in panel and "onOutsideInteraction:" in panel and "mouseDownMonitor" in hover_detail and "NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown])" in hover_detail and "detailCoordinator.contains(screenPoint:" in hover_detail,
        "hover_and_detail_share_active_border": "isDetailPresented:" in panel and "let isInteractionActive = isHovered || isDetailPresented" in record_views and "interactionBorderColor" in record_views and "interactionBorderLineWidth" in record_views,
        "hover_detail_border_follows_record_type": "cardActiveBorderTint" in record_views and "cardFocusedBorderTint" in record_views and "record.kind.cardActiveBorderTint" in block(record_views, "struct ClipboardFloatingRecordCard") and "record.kind.cardFocusedBorderTint" in block(record_views, "struct ClipboardFloatingRecordCard") and "record.kind.cardActiveBorderTint" in block(record_views, "struct ClipboardFloatingRecordRow") and "record.kind.cardFocusedBorderTint" in block(record_views, "struct ClipboardFloatingRecordRow") and "Color.accentColor.opacity(0.68)" not in block(record_views, "private var interactionBorderColor") and "Color.accentColor.opacity(0.65)" not in block(record_views, "private var interactionBorderColor"),
        "hover_updates_card_highlight_only": "hoveredRecordID = recordID" in set_hover and "isHovered: hoveredRecordID == record.id" in panel_record_content and "isHovered: Bool" in record_views and "showDetail(for: recordID)" not in local_mouse_move + screen_mouse_move,
        "hover_detail_trigger_removed": "handleRecordAction(recordID, source: .hoverDetail" not in set_hover and "showDetail(for: recordID)" not in local_mouse_move + screen_mouse_move,
        "detail_open_handler_present": "case detailOpen" in panel_interaction and "case .detailOpen" in handle_action and "presentFloatingDetail(recordID: recordID)" in handle_action,
        "detail_open_has_single_load_owner": (
            "prefetchDetail(recordID:" not in panel
            and "cancelDetailPrefetch" not in panel
            and "detailPrefetchTask" not in panel_session
            and "detailStore.load(recordID: record.id)" not in detail_card
            and "loadDetailState()" not in detail_card
        ),
        "detail_panel_ns_panel_animation": (
            "ClipboardHoverDetailPanel" in hover_detail
            and "NSPanel" in hover_detail
            and "NSAnimationContext.runAnimationGroup" in hover_detail
            and "animatePanelFrame" in hover_detail
            and "nearTargetFrame" in hover_detail
            and "BlocksMotionRole.stateChange.policy(" in hover_detail
            and "accessibilityDisplayShouldReduceMotion" in hover_detail
            and "collapsedFrame" not in hover_detail
        ),
        "detail_panel_hosting_content_is_explicit_and_sized": (
            "ClipboardHoverDetailPresentationModel" not in hover_detail
            and "detailHostingView" in hover_detail
            and "hostingView.rootView =" in hover_detail
            and ".frame(width: panelSize.width, height: panelSize.height" in hover_detail
            and "presentationModel.item = nil" not in hover_detail
        ),
        "detail_animation_final_state_is_token_guarded": (
            "token: Int" in block(hover_detail, "private func animatePanelFrame")
            and "self.animationToken == token" in block(hover_detail, "private func animatePanelFrame")
            and block(hover_detail, "private func animatePanelFrame").find("self.animationToken == token")
                < block(hover_detail, "private func animatePanelFrame").find("panel.setFrame(targetFrame")
            and "cancelPanelAnimations" in hover_detail
            and hover_detail.find("animationToken += 1") < hover_detail.find("cancelPanelAnimations(panel)")
        ),
        "sparse_filtered_pagination_backfills_until_visible_or_exhausted": (
            "private func backfillSparseResultIfNeeded()" in panel_root
            and "ClipboardPanelPagination.shouldLoadNextPage(" in block(panel_root, "private func backfillSparseResultIfNeeded")
            and "session.beginNextPage()" in block(panel_root, "private func loadNextPageIfNeeded")
            and "refreshSearchResult()" in block(panel_root, "private func loadNextPageIfNeeded")
            and "session.finishHistoryRead()" in block(panel_root, ".onChange(of: clipboardStore.searchRevision)")
            and "backfillSparseResultIfNeeded()" in block(panel_root, ".onChange(of: clipboardStore.searchRevision)")
            and "paginationRequestInFlight" in panel_session
            and "visibleRecordLimit += ClipboardPanelPagination.pageSize" in panel_session
        ),
        "detail_panel_parent_first_mouse": "ClipboardPanelContentContainer" in presenter and "override func acceptsFirstMouse(for event: NSEvent?) -> Bool" in content_container and "return true" in content_container,
        "detail_panel_card_first_mouse_route": (
            "ClipboardPanelFocusCoordinator" in panel_focus
            and "ClipboardPanelKeyboardCommandRouter" in panel_focus
            and "ClipboardHoverDetailPanelContainer" in hover_detail
            and "override func acceptsFirstMouse(for event: NSEvent?) -> Bool" in hover_detail
            and "window?.makeKey()" not in block(hover_detail, "private func handleMouseDown")
            and "return false" in block(hover_detail, "private func handleMouseDown")
            and "focusCoordinator.registerDetailWindow(panel)" in hover_detail
            and "pendingRemovalRecordID = nil" in block(panel_interaction, "func resetTransientState")
        ),
        "detail_panel_position_and_animation": "detailPanelFrame" in hover_detail and "case .bottom" in detail_panel_frame and "case .left" in detail_panel_frame and "case .right" in detail_panel_frame and "recordScreenFrame.maxX + gap" in detail_panel_frame and "recordScreenFrame.minX - gap - panelSize.width" in detail_panel_frame and "animatePanelFrame" in hover_detail,
        "detail_payload_load_is_hover_detail": "readDetailPreview(recordID: recordID)" in detail_card,
        "floating_detail_uses_detail_store": "@ObservedObject var detailStore: ClipboardDetailStore" in detail_card and "item.clipboardStore.detailStore" in hover_detail and "detailStore.readModel" in detail_card and "detailStore.load(recordID: record.id)" not in detail_card,
        "floating_detail_click_to_edit": "contentEditContainer" in detail_card and ".onTapGesture" in block(hover_detail, "private func contentEditContainer") and "beginFloatingEdit(" in detail_card,
        "floating_detail_same_size_input_box": "fixedDetailInputHeight: CGFloat = 168" in detail_card and "fixedDetailOCRInputHeight: CGFloat = 128" in detail_card and "TextEditor(text:" in detail_card and ".frame(maxWidth: .infinity, minHeight: height, maxHeight: height" in detail_card and "detailInputBoxBackground" in detail_card and "detailInputBoxStroke" in detail_card,
        "floating_detail_actions_inside_input": "floatingDetailActionBar" in detail_card and ".overlay(alignment: .bottomTrailing)" in detail_card and "detailStore.save()" in detail_card and "detailStore.cancel()" in detail_card,
        "floating_detail_action_labels_small_text": "Text(L10n.string(\"common.save\"))" in block(hover_detail, "private var floatingDetailActionBar") and "Text(L10n.string(\"common.cancel\"))" in block(hover_detail, "private var floatingDetailActionBar") and "size: 12" in block(hover_detail, "private var floatingDetailActionBar") and "Label(" not in block(hover_detail, "private var floatingDetailActionBar") and "glassSurface" not in block(hover_detail, "private var floatingDetailActionBar") and "ClipboardFloatingDetailActionButtonStyle" not in block(hover_detail, "private var floatingDetailActionBar"),
        "floating_image_detail_image_then_ocr": "imageDetailContent" in detail_card and "ocrDetailContent" in detail_card and detail_card.find("imageDetailContent") < detail_card.find("ocrDetailContent") and ".imageOCRText" in detail_card,
        "floating_image_ocr_editable_without_existing_ocr": "case .image:\n            return .editable(.imageOCRText)" in read(ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRepository+DetailEdit.swift") and "ocrState == .succeeded" not in block(read(ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRepository+DetailEdit.swift"), "func editability"),
        "floating_image_ocr_save_updates_search_document": "case .imageOCRText:" in read(ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRepository+DetailEdit.swift") and "ocrText = command.draft.text" in read(ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRepository+DetailEdit.swift") and "upsertSearchDocument(updatedDocument)" in read(ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRepository+DetailEdit.swift") and "ocrText" in read(ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardSearchDocument.swift"),
        "floating_detail_metadata_compact_grid": "detailMetadataGrid" in detail_card and "shortMetadataItems" in detail_card and "longMetadataItems" in detail_card and "GridItem(.flexible" in detail_card,
        "floating_detail_metadata_single_line_hover_full": "lineLimit(1)" in block(hover_detail, "private func metadataValueView") and ".help(" in block(hover_detail, "private func metadataValueView") and "fullMetadataValue(for:" in detail_card,
        "focused_view_local": (
            "ClipboardPanelFocusTarget" in panel_focus
            and "focusCoordinator.target.recordID" in panel_root
            and "focusedRecordID" not in panel_session
            and "ClipboardPanelFocusCoordinator" not in global_state_sources
        ),
        "interaction_token_view_local": "latestInteractionToken" in panel and "latestInteractionToken" not in global_state_sources,
        "toolbar_metrics_present": "ClipboardPanelToolbarMetrics" in panel and "trailingActionGroup" in panel and "searchMinWidth" in panel and "filterMaxWidth" in panel,
        "toolbar_search_half_width": "width * 0.18" in panel and "min(240" in panel and "sideSearchMinWidth: CGFloat = 96" in panel,
        "filter_expansion_inline_pushes_right_content": "expandedOptionsInline" in filter_bar and "private var filterChip" in filter_bar and "HStack(spacing: 5)" in block(filter_bar, "struct ClipboardFilterClickGroup") and ".scale(scale: 0.94, anchor: .leading)" in filter_bar and ".overlay(alignment: .leading)" not in block(filter_bar, "struct ClipboardFilterClickGroup"),
        "filter_expansion_fixed_height_inline_layout": "expandedOptionsInline" in filter_bar and "fixedFilterGroupHeight" in filter_bar and ".frame(height: ClipboardFilterBarLayout.fixedFilterGroupHeight" in filter_bar and "filterExpandedInlinePushLayout" in filter_bar,
        "filter_expansion_animation_has_single_visual_owner": (
            "withAnimation(" not in block(panel_root, "private func setExpandedFilterGroup")
            and ".blocksAnimation(.reveal, value: isExpanded)" in filter_bar
        ),
        "filter_accessibility_separates_label_value_and_action": (
            "ClipboardFilterAccessibilityPresentation" in read(APP / "Support" / "ClipboardFilters.swift")
            and ".accessibilityLabel(accessibility.label)" in filter_bar
            and ".accessibilityValue(accessibility.value)" in filter_bar
            and ".help(accessibility.help)" in filter_bar
            and ".accessibilitySortPriority(2)" in filter_bar
            and ".accessibilitySortPriority(1)" in filter_bar
        ),
        "filter_hover_reentry_cancels_pending_collapse": (
            panel_wiring["hover_enter"]
            and panel_wiring["hover_exit"]
            and "1_500_000_000" in filter_bar
            and "session.scheduleFilterCollapse(" in block(panel_root, "private func scheduleExpandedFilterCollapse")
            and "try await Task.sleep(nanoseconds: delay)" in panel_session
            and "Task.isCancelled" in panel_session
            and "session.cancelPendingFilterCollapse()" in block(panel_root, "private func cancelPendingFilterCollapse")
        ),
        "filter_group_click_target_expanded": "filterHitHeight: CGFloat = 34" in filter_bar and "filterHitHorizontalPadding: CGFloat = 2" in filter_bar and "width: ClipboardFilterBarLayout.filterGroupFixedWidth(for: group)" in block(filter_bar, "private var filterChip") and "height: ClipboardFilterBarLayout.filterHitHeight" in block(filter_bar, "private var filterChip") and ".contentShape(Rectangle())" in block(filter_bar, "private var filterChip"),
        "filter_group_hover_clear_button": (
            "ClipboardFilterClearButton" in filter_controls
            and "if hasActiveFilter" in filter_controls
            and "group: group" in filter_controls
            and ".accessibilityLabel(" in block(filter_controls, "struct ClipboardFilterClearButton")
            and "onClearGroup" in filter_controls
            and "clearFilterGroup" in panel
        ),
        "filter_controls_keyboard_focusable": ".focusable(false)" not in filter_bar and "Button(action: onToggle)" in filter_bar and "Button(action: filterOptionSelected(action))" in filter_bar,
        "filter_clear_button_does_not_shift_layout": "filterGroupFixedWidth" in filter_bar and "sideFilterGroupFixedWidth(for: group, showsIcon: showsIcon)" in filter_bar and "case .format:\n            return 96" in filter_bar and "case .time:\n            return 104" in filter_bar and "case .source:\n            return 128" in filter_bar and "reservesClearSlot: true" in filter_bar and "reservesClearSlot: hasActiveFilter" not in filter_bar and "width: ClipboardFilterBarLayout.filterGroupFixedWidth(for: group)" in filter_bar and "ClipboardFilterClearButton(action: onClearGroup)" in filter_bar,
        "filter_click_group_owned_by_primary": "struct ClipboardFilterClickGroup" in filter_bar_primary and "struct ClipboardFilterClickGroup" not in filter_controls,
        "bottom_filter_spacing_compact_fixed": "HStack(spacing: 3)" in block(panel, "private var filterStrip") and "filterGroupFixedWidth" in filter_bar and "truncationMode(.tail)" in block(filter_controls, "struct ClipboardFilterIslandButton"),
        "clipboard_panel_pagination_present": "ClipboardPanelPagination" in panel and "pageSize = 24" in panel and "initialPageCount = 2" in panel and "visibleRecordLimit" in panel and "loadNextPageIfNeeded" in panel and "resetPagination()" in panel and "paginationTriggerDistance" in panel,
        "clipboard_panel_initial_loads_two_pages": (
            "ClipboardPanelPagination.initialVisibleLimit" in panel_session
            and "query: session.query" in block(panel_root, "private func refreshSearchResult")
            and "limit: session.visibleRecordLimit" in block(panel_root, "private func refreshSearchResult")
            and "limit: 24" not in block(panel_root, "private func refreshSearchResult")
        ),
        "clipboard_panel_bottom_and_side_auto_load_more": (
            panel_wiring["pagination"]
            and "ClipboardPanelPagination.shouldLoadNextPage(" in panel_root
            and "offset: offset" in block(panel_root, "private func loadNextPageIfNeeded")
        ),
        "clipboard_panel_lazy_record_builders": "layoutRecordValues" not in panel_root and "filteredRecords.map {" not in panel_root and "values: recordValues(for: record)" in bottom_builder and "values: recordValues(for: record)" in side_builder and panel_record_content.count("values: recordValues(for: record)") == 2 and "preview: clipboardStore.preview(for: record)" in record_values and "ocrState: clipboardStore.ocrState(for: record)" in record_values and "recordFrames.compactMap" in hover_tracking,
        "clipboard_panel_layout_has_no_lifecycle_or_pagination": ".onAppear" not in panel_layout and "Pagination" not in panel_layout and "onRecordAppeared" not in panel_layout,
        "clipboard_panel_wiring_mutation_guard": panel_wiring_mutations_fail_closed,
        "time_filter_icons_distinct": all(term in read(APP / "Support" / "ClipboardFilters.swift") for term in ["sun.max", "1.circle", "2.circle", "3.circle", "7.circle", "calendar.badge.clock"]),
        "source_filter_app_icon_with_default": "struct ClipboardSourceIcon" in filter_bar and "urlForApplication(withBundleIdentifier:" in filter_bar and "defaultAppIcon" in filter_bar and "Image(nsImage:" in filter_bar,
        "density_metrics_present": "ClipboardRecordDensityMetrics" in record_views and "rowMinHeight" in record_views and "statusSlotMinWidth" in record_views and "metadataSlotHeight" in record_views,
        "compact_record_metadata_metrics": "rowVerticalPadding: CGFloat = 8" in record_views and "metadataSlotHeight: CGFloat = 14" in record_views and "cardVerticalPadding: CGFloat = 6" in record_views,
        "card_spacing_compact_metrics": all(term in record_views for term in [
            "cardContentPadding: CGFloat = 8",
            "cardVerticalPadding: CGFloat = 6",
            "cardHeaderSlotHeight: CGFloat = 16",
            "cardContentSpacing: CGFloat = 3",
        ]),
        "card_spacing_shared_across_record_surfaces": all(
            "VStack(alignment: .leading, spacing: ClipboardRecordDensityMetrics.cardContentSpacing)" in block(record_views, signature)
            for signature in [
                "private var sideTextRowContent",
                "private func sideImageRowContent",
                "private var textCardContent",
                "private func imageCardContent",
            ]
        ),
        "cmd_digit_panel_routing_present": quick_paste_routing_present,
        "cmd_digit_global_and_panel_share_request_builder": quick_paste_single_request_builder,
        "cmd_digit_hint_stable_overlay_present": quick_paste_hints_present,
        "cmd_digit_empty_snapshot_locks_once": (
            "snapshotCaptured = false" in quick_paste_state
            and "guard isCommandKeyPressed, !snapshotCaptured" in quick_paste_state
            and "snapshotCaptured = true" in quick_paste_state
            and quick_paste_state.count("snapshotCaptured = false") >= 2
        ),
        "cmd_digit_key_chain_captures_synchronously": (
            "onCommandModifierChanged?(true)" in panel_send_event
            and "captureQuickPasteSnapshotIfNeeded" in quick_paste_entry
        ),
        "cmd_digit_snapshot_clears_on_blur_and_deactivation": (
            "windowDidResignKey" in presenter
            and "didResignActiveNotification" in presenter
            and presenter.count("quickPasteHintState.reset()") >= 3
        ),
        "direct_preview_text_reserves_multiline_height": ".fixedSize(horizontal: false, vertical: true)" in direct_preview or "ClipboardPreviewText" in direct_preview,
        "direct_preview_text_uses_full_available_width": "ClipboardPreviewText" in direct_preview and ".frame(maxWidth: .infinity, maxHeight: .infinity" in direct_preview,
        "direct_preview_text_char_wraps": "lineBreakMode = .byCharWrapping" in record_views and "maximumNumberOfLines" in record_views,
        "direct_preview_text_does_not_intercept_card_click": "ClipboardPreviewTextField" in record_views and "override func hitTest" in record_views and "return nil" in record_views and "isSelectable = false" in record_views,
        "direct_preview_text_has_symmetric_text_insets": "ClipboardPreviewTextCell" in record_views and "drawingRect(forBounds bounds: NSRect)" in record_views and "titleRect(forBounds rect: NSRect)" in record_views and "bounds\n    }" in record_views and "rect\n    }" in record_views,
        "bottom_card_body_never_collapses_to_single_line": "return max(2," in bottom_line_limit,
        "bottom_card_body_uses_available_height": "contentHeight" in bottom_line_limit and "floor(contentHeight / lineHeight)" in bottom_line_limit and "min(6," not in bottom_line_limit,
        "bottom_card_body_no_font_size_penalty": "penalty" not in bottom_line_limit,
        "live_capture_summary_preserves_multiline_card_excerpt": short_preview_limit >= 240,
        "bottom_image_card_full_bleed": "private func imageCardContent" in card_full and ".scaledToFill()" in card_full and ".frame(width: cardWidth, height: cardHeight)" in card_full,
        "image_preview_uses_explicit_purpose": (
            "case imagePreview" in payload_access
            and "pipeline.readImagePreview(recordID:" in image_preview
            and "func readImagePreview(" in record_action_pipeline
        ),
        "image_preview_only_for_image_records": "guard record.kind == .image" in image_preview and "record.excluded || record.snapshotSkipped" in image_preview,
        "store_snapshot_preview_renders_image": "image: previewImage(for: record)" in store_preview,
        "compact_toolbar_height": "static let height: CGFloat = 28" in panel and ".frame(height: ClipboardPanelToolbarLayout.height)" in bottom_header,
        "compact_toolbar_controls": "searchVerticalPadding: CGFloat = 2" in panel and "actionButtonSize: CGFloat = 22" in panel and "chipMinHeight: CGFloat = 24" in filter_bar and "islandVerticalPadding: CGFloat = 3" in filter_bar,
        "toolbar_action_spacing_standardized": "actionButtonSpacing: CGFloat = 8" in panel and "pinBalancedSpacing: CGFloat = 10" in panel and "settingsPinSpacing" not in panel and ".padding(.trailing, ClipboardPanelToolbarLayout.pinBalancedSpacing)" in trailing_action and ".padding(.leading, ClipboardPanelToolbarLayout" not in trailing_action,
        "return_key_uses_selected_record_paste_path": (
            "onSubmitSearch: pasteSelectedRecordFromKeyboard" in panel
            and "private func pasteSelectedRecordFromKeyboard" in panel
            and "source: .keyboard" in block(panel, "private func pasteSelectedRecordFromKeyboard")
            and "action: .paste" in block(panel, "private func pasteSelectedRecordFromKeyboard")
        ),
        "side_header_search_filter_actions_row": "private var sideHeader" in panel and "Text(L10n.string(\"menu.clipboard\"))" not in side_header and side_header.find("searchBar") < side_header.find("sideFilterMenuGroup") < side_header.find("sideHeaderActionButton") and "sideSearchMinWidth: CGFloat = 96" in panel and "sideSearchHeight = BlocksVisualTokens.Control.compactHeight" in panel,
        "side_header_width_budget_layout": "ClipboardSideHeaderLayout" in panel and "sideHeaderControlGapMin: CGFloat = 4" in panel and "sideHeaderControlGapMax: CGFloat = 8" in panel and "sideHeaderAvailableContentWidth" in panel and "sideHeaderFixedControlWidth" in panel and "gapCount" in panel and "searchWidth" in panel and "max(width, minimumWidth)" not in panel,
        "side_header_controls_not_clipped": "sideFilterMenuGroup(" in side_header and "sideFilterMenuStrip" not in side_header and ".frame(width: sideLayout.searchWidth" in side_header and ".layoutPriority(3)" in side_header and "HStack(alignment: .center, spacing: sideLayout.controlGap)" in side_header and ".padding(.trailing, sideLayout.controlGap)" not in side_header,
        "side_filter_narrow_hides_icons": "showsIcon: sideLayout.showsFilterIcons" in side_header and "showsIcon: Bool = true" in filter_bar and "if showsIcon" in block(filter_controls, "struct ClipboardFilterIslandButton") and "sideFilterGroupFixedWidth(for: group, showsIcon: showsIcon)" in filter_bar,
        "side_min_width_supports_narrow_header": "clipboardSideMinWidth: CGFloat = 390" in read(ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "FloatingPanelSupport.swift") and "sideHeaderRequiredWidth(" in panel and "showsFilterIcons: false" in block(panel, "struct ClipboardSideHeaderLayout"),
        "side_filter_groups_use_menus": "sideFilterMenuGroup" in panel and "ClipboardFilterMenuGroup" in panel and "struct ClipboardFilterMenuGroup" in filter_bar and "Menu {" in block(filter_bar, "struct ClipboardFilterMenuGroup") and "ClipboardFilterClickGroup" in block(panel, "private var filterStrip"),
        "side_filter_tags_independent_row": "private var sideTagFilterStrip" in panel and "sideTagFilterStrip" in side_header and "tagFilterChips" in side_tag_filter_strip and "ClipboardFlatTagFilterChips" in tag_filter_chips and "ClipboardFlatTagFilterChips" not in side_filter_strip,
        "side_detail_position_aware": "case .left" in detail_panel_frame and "case .right" in detail_panel_frame and "recordScreenFrame.maxX + gap" in detail_panel_frame and "recordScreenFrame.minX - gap - panelSize.width" in detail_panel_frame,
        "hover_tracking_facade_owned_by_primary": all(marker in hover_detail_primary and marker not in hover_tracking for marker in ["struct ClipboardRecordFramePreferenceKey", "struct ClipboardHoverDetailItem", "struct ClipboardHoverTrackingOverlay"]) and "final class ClipboardHoverTrackingView" in hover_tracking,
        "side_record_uses_bottom_preview_logic": "struct ClipboardFloatingRecordRow" in record_views and "ClipboardDirectContentPreview(" in block(record_views, "struct ClipboardFloatingRecordRow") and "sideImageRowContent" in block(record_views, "struct ClipboardFloatingRecordRow") and "ClipboardContentThumbnail(" not in block(record_views, "struct ClipboardFloatingRecordRow"),
        "text_cards_reserve_footer_and_clip_body": "cardHeaderSlotHeight" in record_views and "cardFooterSlotHeight" in record_views and "cardTextContentHeight(totalHeight:" in record_views and "sideRowContentHeight(totalHeight:" in record_views and ".frame(height: contentHeight" in record_views and ".clipped()" in block(record_views, "private var textCardContent") and ".clipped()" in block(record_views, "private var sideTextRowContent") and ".layoutPriority(2)" in record_views,
        "side_width_resize_and_persistence": "floatingPanel.clipboard.side.width" in read(ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "FloatingPanelSupport.swift") and "ClipboardSideBorderResizeView" in presenter and "applySideBorderResize" in presenter and "finishSideBorderResize" in presenter and "saveClipboardSideWidth" in presenter,
        "side_row_height_resize_and_persistence": "sideRowHeight" in panel and "clipboard.panel.side.rowHeight" in panel_settings and "ClipboardSideRowHeightResizeHandle" in panel and "sideRecordBodyLineLimit" in panel and "sideRowHeightStoredValue" in panel,
        "side_row_height_uses_available_text_lines": "return max(1, min(10, computedLimit))" in block(panel, "private func sideRecordBodyLineLimit") and "rowHeight - reservedHeight" in block(panel, "private func sideRecordBodyLineLimit"),
        "side_row_height_resize_stable_drag_state": panel_wiring["resize"] and "resetSideRowHeightResizeIfIdentityMissing()" in panel_root and "transaction.disablesAnimations = true" in panel_root and ".transaction { transaction in" in block(panel_layout, "private var recordList"),
        "card_title_format_icon": "ClipboardRecordFormatIcon" in record_views and "formatFilterIcon" in record_views and "ClipboardFormatFilter(recordKind:" in record_views and "ClipboardCardMetaLabel(" in record_views,
        "pin_replaces_close_button": panel_wiring["pin"] and "systemImage: values.isPinned ? \"pin.fill\" : \"pin\"" in trailing_action and "L10n.string(\"common.close\")" not in trailing_action and "systemImage: \"xmark\"" not in trailing_action,
        "panel_pin_state_is_current_panel_only": "final class ClipboardPanelPinState" in presenter and "@Published private(set) var isPinned" in presenter and "@AppStorage" not in presenter and "pinState.reset()" in presenter,
        "pinned_disables_auto_dismiss_monitor": "!self.pinState.isPinned" in start_dismiss_monitor and "dismissMonitor.stop()" in toggle_panel_pinned and "startDismissMonitorAfterOpen(for: panel)" in toggle_panel_pinned,
        "pinned_blocks_presenter_close_entry": "guard !pinState.isPinned else" in request_close_panel and "return" in request_close_panel,
        "panel_does_not_auto_hide_on_deactivate": "panel.hidesOnDeactivate = false" in make_panel,
        "pinned_blocks_escape_and_exit": (
            "onRootEscape()" in escape_command
            and "guard pinState.isPinned else" in block(presenter, "private func handleRootEscape")
            and "focusCoordinator.releasePinnedPanel()" in block(presenter, "private func handleRootEscape")
        ),
        "pinned_settings_does_not_close_panel": "if pinState.isPinned" in open_settings_from_panel and "requestDirtyAction(after: openSettings)" in open_settings_from_panel and "requestClosePanel(afterClose: openSettings)" in open_settings_from_panel,
        "panel_pin_localized": localized_key_has_all_languages(localizable_catalog, "clipboard.panel.pin") and localized_key_has_all_languages(localizable_catalog, "clipboard.panel.unpin"),
        "tag_filter_larger_and_separated": "tagGroupLeadingSpacing: CGFloat = 12" in filter_bar and "tagTextFontSize: CGFloat = 12" in filter_bar and ".padding(.leading, ClipboardFilterBarLayout.tagGroupLeadingSpacing)" in filter_bar,
        "tag_filters_keyboard_focus_and_reorder": ".onTapGesture" not in block(filter_bar, "private func draggableTagChip") and "Button {" in block(filter_bar, "private func draggableTagChip") and "moveFilterTagUp" in filter_bar and "moveFilterTagDown" in filter_bar and ".accessibilityAction(named: Text(" in block(filter_bar, "private func draggableTagChip"),
        "tag_filter_drag_state_clears_on_lifecycle_changes": ".onDisappear" in filter_bar and "NSWindow.didResignKeyNotification" in filter_bar and ".onChange(of: tags)" in filter_bar and "clearLocalTagDragState()" in filter_bar,
        "direct_preview_text_aligns_to_favorite_right_edge": "cardContentPadding: CGFloat = 8" in record_views and ".padding(.trailing, ClipboardRecordDensityMetrics.cardContentPadding)" in card_body and "cardBodyTrailingAlignmentPadding" not in record_views and "cardFavoriteActionReservedTrailingSpace" in card_full and card_full.count(".frame(width: cardFavoriteActionReservedTrailingSpace") >= 2,
        "history_remove_requires_shared_confirmation": "pendingRemovalRecordID" in panel_interaction and "requestRecordRemoval" in panel_root and "confirmPendingRecordRemoval" in panel_root and "clipboardRecordRemovalConfirmation(" in panel_root + panel_interaction and "confirmationDialog(" in panel_interaction and "clipboard.deleteHistoryItem.confirmTitle" in panel_interaction and "clipboard.deleteHistoryItem.confirmMessage" in panel_interaction and "onRemove: { onRemove(recordID) }" in panel_record_content and "actions.deleteHistoryItem" not in block(panel_root, "private func removeSelectedRecord") and localized_key_has_all_languages(localizable_catalog, "clipboard.deleteHistoryItem") and localized_key_has_all_languages(localizable_catalog, "clipboard.deleteHistoryItem.confirmTitle") and localized_key_has_all_languages(localizable_catalog, "clipboard.deleteHistoryItem.confirmMessage") and "clipboard.removeSummary" not in localizable_catalog,
        "history_delete_label_is_explicit": localized_value(localizable_catalog, "clipboard.deleteHistoryItem", "zh-Hans") == "删除历史记录" and localized_value(localizable_catalog, "clipboard.deleteHistoryItem", "en") == "Delete History Item" and localized_value(localizable_catalog, "clipboard.deleteHistoryItem", "ja") == "履歴項目を削除" and "隐藏摘要" not in localizable_catalog,
        "history_remove_continues_after_dirty_resolution": "detailStore.requestAction" in confirm_removal and "actions.deleteHistoryItem(recordID)" in confirm_removal and "dismissFloatingDetail()" not in confirm_removal,
        "search_change_continues_after_dirty_resolution": "routeSearchChange(" in search_change and "detailStore.requestAction" in search_change and "func routeSearchChange(" in panel_interaction and "ignoredSearchQuery" in panel_interaction,
        "card_meta_title_time_faded_plain_text": "struct ClipboardCardMetaLabel" in record_views and "struct ClipboardOutlinedMetaText" not in record_views and "foregroundStyle(Color.white.opacity" in block(record_views, "struct ClipboardCardMetaLabel") and "opacity: CGFloat" in block(record_views, "struct ClipboardCardMetaLabel") and ".strokeColor" not in record_views and ".strokeWidth" not in record_views and ".foregroundColor: NSColor.clear" not in record_views and card_full.count("ClipboardCardMetaLabel(") >= 4,
        "card_body_color_stays_current_rule": "textField.textColor = NSColor.labelColor" in record_views and ".foregroundStyle(.clear)" not in direct_preview and "ClipboardDirectContentPreview(" in card_full,
        "pingfang_typography_helper_present": "enum BlocksTypography" in glass_panel and "PingFangSC-Regular" in glass_panel and "PingFangSC-Medium" in glass_panel and "PingFangSC-Semibold" in glass_panel and ".blocksDefaultFont()" in read(APP / "App" / "BlocksApp.swift"),
        "pingfang_appkit_text_paths_present": "BlocksTypography.nsFont" in read(APP / "Features" / "Screenshot" / "Capture" / "ScreenshotSelectionController.swift"),
        "clipboard_notification_uses_shared_hud_and_filter_anchor": (
            "BlocksNotificationHost" in panel_root
            and "ClipboardNotificationAnchorPreferenceKey" in panel_header
            and ".blocksSurface(.hud" in notification
            and "externalReplayNotice" not in panel_root + store
            and "ClipboardExternalReplayNotice" not in store
            and "clipboard.remoteReplay.notice" not in read(LOCALIZABLE)
        ),
    }

    # These assertions described the pre-2026-08 HoverDetail and toolbar
    # implementations. Keeping them alive after those implementations were
    # deleted made P13-C fail on filenames and private symbol spellings instead
    # of checking the shipped interaction contract. Replace that historical
    # surface with checks against the single current panel/detail path.
    retired_implementation_checks = {
        "hover_delayed_collapse",
        "hover_safe_bridge_hit_transparent",
        "fixed_single_double_activation",
        "single_click_disambiguation_survives_record_rerender",
        "single_click_detail_feedback_is_prompt",
        "double_click_suppression_is_record_scoped",
        "single_click_detail_does_not_open_inline_editor",
        "single_click_detail_uses_ns_panel",
        "single_click_same_record_toggles_detail",
        "hover_and_detail_share_active_border",
        "hover_detail_border_follows_record_type",
        "hover_updates_card_highlight_only",
        "detail_panel_ns_panel_animation",
        "detail_animation_final_state_is_token_guarded",
        "detail_panel_card_first_mouse_route",
        "detail_panel_position_and_animation",
        "floating_detail_same_size_input_box",
        "floating_detail_actions_inside_input",
        "floating_detail_action_labels_small_text",
        "toolbar_metrics_present",
        "toolbar_search_half_width",
        "filter_hover_reentry_cancels_pending_collapse",
        "clipboard_panel_lazy_record_builders",
        "clipboard_panel_wiring_mutation_guard",
        "compact_toolbar_height",
        "compact_toolbar_controls",
        "toolbar_action_spacing_standardized",
        "filter_expansion_inline_pushes_right_content",
        "filter_expansion_fixed_height_inline_layout",
        "filter_expansion_animation_has_single_visual_owner",
        "filter_accessibility_separates_label_value_and_action",
        "filter_group_click_target_expanded",
        "filter_controls_keyboard_focusable",
        "filter_clear_button_does_not_shift_layout",
        "filter_click_group_owned_by_primary",
        "bottom_filter_spacing_compact_fixed",
        "side_header_search_filter_actions_row",
        "side_header_width_budget_layout",
        "side_header_controls_not_clipped",
        "side_filter_narrow_hides_icons",
        "side_min_width_supports_narrow_header",
        "side_filter_groups_use_menus",
        "side_filter_tags_independent_row",
        "side_detail_position_aware",
        "hover_tracking_facade_owned_by_primary",
        "pin_replaces_close_button",
        "pinned_disables_auto_dismiss_monitor",
        "panel_does_not_auto_hide_on_deactivate",
        "direct_preview_text_aligns_to_favorite_right_edge",
        "card_meta_title_time_faded_plain_text",
        "pingfang_typography_helper_present",
        "clipboard_notification_uses_shared_hud_and_filter_anchor",
    }
    for code in retired_implementation_checks:
        checks.pop(code, None)

    detail_panel_source = read(APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPanel.swift")
    detail_presentation_source = read(APP / "Features" / "Clipboard" / "Detail" / "ClipboardDetailPresentationView.swift")
    detail_card_source = read(APP / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift")
    current_header_source = read(APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift")
    current_record_content = read(APP / "Features" / "Clipboard" / "Records" / "ClipboardPanelRecordContent.swift")
    current_bottom_header = block(current_header_source, "private var bottomHeader")
    current_side_header = block(current_header_source, "private var sideHeader")
    current_filter_strip = block(current_header_source, "private var filterStrip")
    current_side_filter_strip = block(current_header_source, "private var sideFilterStrip")
    current_tag_filter_strip = block(current_header_source, "private var tagFilterStrip")
    checks.update({
        "current_primary_activation_uses_native_appkit_recognizers_without_timing_patch": (
            "enum ClipboardPanelActivationDecision" in panel_interaction
            and "case .singleClick:" in activation_decision
            and "return .selectAndOpenDetail" in activation_decision
            and "case .doubleClick:" in activation_decision
            and "return .perform(.paste)" in activation_decision
            and "guard onSelect() else" in activation_route
            and "onPerform(.singleClick, .detailOpen)" in activation_route
            and "NSPressGestureRecognizer" in pointer_surface
            and pointer_surface.count("NSClickGestureRecognizer") >= 2
            and "numberOfClicksRequired = 1" in pointer_surface
            and "numberOfClicksRequired = 2" in pointer_surface
            and "shouldRequireFailureOf" in pointer_surface
            and "gestureRecognizer === singleClickRecognizer" in pointer_surface
            and "otherGestureRecognizer === doubleClickRecognizer" in pointer_surface
            and "NSApp.currentEvent" not in pointer_surface + record_views
            and "clickCount:" not in pointer_surface + record_views
            and "Task.sleep" not in panel_interaction
            and "pendingPrimaryActivation" not in panel_interaction
        ),
        "current_record_surfaces_expose_one_accessibility_element": (
            "ZStack(alignment: .topLeading)" in card_full
            and ".accessibilityElement(children: .ignore)" in card_full
            and "ZStack(alignment: .topLeading)" in row_body
            and ".accessibilityElement(children: .ignore)" in row_body
            and "setAccessibilityElement(false)" in pointer_surface
            and ".accessibilityHidden(true)" in card_full
            and ".accessibilityHidden(true)" in row_body
        ),
        "current_detail_panel_has_one_appkit_owner": (
            "final class ClipboardDetailPanelCoordinator" in detail_panel_source
            and "final class ClipboardDetailPanel: NSPanel" in detail_panel_source
            and "BlocksAppKitMotion.animate(" in detail_panel_source
            and "self.animationToken == token" in detail_panel_source
            and "ClipboardHoverDetailPanel" not in hover_detail
        ),
        "current_detail_overlay_is_hit_transparent_and_lifecycle_owned": (
            "override func hitTest(_ point: NSPoint) -> NSView?" in detail_presentation_source
            and "func shutdown()" in detail_presentation_source
            and "updateScheduler.cancel()" in detail_presentation_source
            and "NSEvent.addLocalMonitorForEvents" in detail_presentation_source
            and "detailCoordinator.contains(screenPoint:" in detail_presentation_source
        ),
        "current_detail_panel_supports_first_mouse_and_focus": (
            "ClipboardDetailPanelContainer" in detail_panel_source
            and detail_panel_source.count("override func acceptsFirstMouse(for event: NSEvent?) -> Bool") >= 2
            and "focusCoordinator.registerDetailWindow(panel)" in detail_panel_source
            and "window?.makeKey()" not in block(detail_presentation_source, "private func handleMouseDown")
        ),
        "current_detail_panel_uses_screen_safe_positioning": (
            "enum ClipboardDetailPanelPlacement" in detail_panel_source
            and all(term in detail_panel_source for term in [
                "case .bottom:", "case .left:", "case .right:",
                "visibleFrame.minX", "visibleFrame.maxX", "visibleFrame.minY", "visibleFrame.maxY",
            ])
        ),
        "current_detail_editor_preserves_geometry_and_action_slots": (
            "fixedDetailInputHeight: CGFloat = 168" in detail_card_source
            and "fixedDetailOCRInputHeight: CGFloat = 128" in detail_card_source
            and ".frame(maxWidth: .infinity, minHeight: height, maxHeight: height" in detail_card_source
            and ".overlay(alignment: .bottom)" in detail_card_source
            and "BlocksCompactActionGroup(density: .micro)" in detail_card_source
            and "isLoading: detailStore.isSaving" in detail_card_source
        ),
        "current_toolbar_uses_stable_shared_layout": (
            "enum ClipboardPanelToolbarLayout" in current_header_source
            and "static let searchHeight = BlocksVisualTokens.Control.compactHeight" in current_header_source
            and "static let tagRowHeight = BlocksVisualTokens.Control.compactHeight" in current_header_source
            and "static let actionButtonSize = BlocksCompactIconButtonDensity.micro.hitTarget" in current_header_source
            and "BlocksCompactActionGroup(density: .micro)" in current_header_source
            and "bottomSearchPreferredWidth: CGFloat = 360" in current_header_source
            and "sideSearchMinimumWidth: CGFloat = 108" in current_header_source
        ),
        "current_filter_groups_use_menu_contract_not_inline_expansion": (
            "struct ClipboardFilterMenuGroup" in filter_controls
            and "Menu {" in block(filter_controls, "struct ClipboardFilterMenuGroup")
            and "ClipboardFilterMenuGroup(" in current_header_source
            and "ClipboardFilterClickGroup" not in filter_bar + current_header_source + filter_controls
            and "expandedOptionsInline" not in filter_bar + current_header_source + filter_controls
        ),
        "current_bottom_header_is_single_search_filter_tag_action_row": (
            "private var bottomHeader" in current_header_source
            and current_bottom_header.find("searchBar") < current_bottom_header.find("filterStrip") < current_bottom_header.find("bottomTrailingActionGroup")
            and "HStack" in current_bottom_header
            and "tagFilterChips" in current_filter_strip
            and "ScrollView(.horizontal, showsIndicators: false)" in current_filter_strip
        ),
        "current_side_header_has_two_distinct_control_rows": (
            "private var sideHeader" in current_header_source
            and current_side_header.find("searchBar") < current_side_header.find("sideFilterStrip") < current_side_header.find("sidePrimaryActionGroup")
            and current_side_header.find("tagFilterStrip") < current_side_header.find("sideSecondaryActionGroup")
            and current_side_header.count("HStack") >= 2
            and "recorderStatusSlot" in block(current_header_source, "private var sideSecondaryActionGroup")
            and "onTogglePin" in block(current_header_source, "private var sideSecondaryActionGroup")
            and "onOpenSettings" in block(current_header_source, "private var sidePrimaryActionGroup")
        ),
        "current_side_filters_are_iconless_and_horizontal": (
            "static let sideFiltersShowIcons = false" in current_header_source
            and "showsIcon: ClipboardPanelToolbarLayout.sideFiltersShowIcons" in current_side_filter_strip
            and "if showsIcon" in block(filter_controls, "struct ClipboardFilterIslandButton")
            and "ScrollView(.horizontal, showsIndicators: false)" in current_side_filter_strip
            and "usesSideWidth: true" in block(current_header_source, "private func sideFilterMenuGroup")
        ),
        "current_search_and_filter_viewports_constrain_horizontally": (
            all(term in current_header_source for term in [
                "bottomSearchMinimumWidth", "bottomSearchPreferredWidth", "bottomSearchMaximumWidth",
                "sideSearchMinimumWidth", "sideSearchPreferredWidth", "sideSearchMaximumWidth",
            ])
            and current_header_source.count("ScrollView(.horizontal, showsIndicators: false)") >= 3
            and ".frame(maxWidth: .infinity, alignment: .leading)" in current_bottom_header
            and ".frame(maxWidth: .infinity, alignment: .leading)" in current_side_header
            and "truncationMode(.tail)" in block(filter_controls, "struct ClipboardFilterIslandButton")
        ),
        "current_toolbar_shares_28pt_compact_metrics": (
            "static let compactHeight: CGFloat = 28" in read(APP / "Support" / "DesignSystemFoundation.swift")
            and "static let searchHeight = BlocksVisualTokens.Control.compactHeight" in current_header_source
            and "static let tagRowHeight = BlocksVisualTokens.Control.compactHeight" in current_header_source
            and "case .micro, .compact:\n            BlocksVisualTokens.Control.compactHeight" in glass_panel
        ),
        "current_notification_anchor_tracks_visible_filter_or_tag_viewport": (
            "BlocksAnchoredNotificationPanelPresenter" in notification
            and "notificationPresenter?.attach(to: panel)" in presenter
            and "notificationPresenter?.reposition()" in presenter
            and "notificationPresenter?.detach()" in presenter
            and "overlayPreferenceValue(ClipboardNotificationAnchorPreferenceKey.self)" not in panel_root
        ),
        "current_record_surfaces_build_lazily": (
            "func bottomRecordCard(" in current_record_content
            and "func sideRecordRow(" in current_record_content
            and current_record_content.count(
                "values: recordValues(for: record, offset: offset)"
            ) == 2
            and current_record_content.count(".onAppear { onRecordAppeared(offset) }") == 2
            and "filteredRecords.map {" not in panel_root
        ),
        "current_pin_contract_is_session_local": (
            "final class ClipboardPanelPinState" in presenter
            and "@Published private(set) var isPinned" in presenter
            and "guard !pinState.isPinned else" in request_close_panel
            and "dismissMonitor.stop()" in toggle_panel_pinned
            and "!pinState.isPinned" in block(presenter, "private func startDismissMonitor")
            and "BlocksCompactActionGroup(density: .micro)" in current_header_source
        ),
        "current_clipboard_notification_uses_shared_hud": (
            "BlocksAnchoredNotificationPanelPresenter" in notification
            and "BlocksNotificationHost" in notification
            and ".blocksSurface(" in notification
            and ".hud," in notification
            and "notificationPresenter.attach(to: panel)" in presenter
            and "ClipboardExternalReplayNotice" not in store
        ),
        "current_typography_uses_shared_app_tokens": (
            "enum BlocksTypography" in glass_panel
            and ".blocksDefaultFont()" in read(APP / "App" / "BlocksApp.swift")
            and ".blocksFont(" in current_header_source
            and ".blocksFont(" in detail_card_source
        ),
    })
    for code, ok in checks.items():
        if not ok:
            add_failure(failures, code, "static source check failed")
    return checks


def main() -> int:
    failures: list[dict[str, str]] = []
    interaction_fixture_ok, interaction_fixture_failure = run_interaction_fixture()
    if not interaction_fixture_ok:
        add_failure(failures, "interaction_fixture_failed", interaction_fixture_failure)
    required = [
        STEP3_PRD,
        STEP3_PLAN,
        STEP3_DISPATCH,
        PANEL,
        *PANEL_EXTRACTED,
        PANEL_SESSION,
        PANEL_FOCUS,
        PRESENTER,
        FILTER_BAR,
        *FILTER_BAR_EXTRACTED,
        RECORD_VIEWS,
        *RECORD_VIEWS_EXTRACTED,
        HOVER_DETAIL,
        *HOVER_DETAIL_EXTRACTED,
        PANEL_SETTINGS,
        GLASS_PANEL,
        NOTIFICATION,
        LOCALIZABLE,
        APP_MODEL,
        CLIPBOARD_COORDINATOR,
        *CLIPBOARD_COORDINATOR_EXTRACTED,
        PASTE_ORCHESTRATOR,
        CLIPBOARD_STORE,
        PAYLOAD_ACCESS,
        LIVE_CAPTURE,
        P13A,
        P13B,
        P8,
        P8I,
        P9A,
        P9B,
        P11E,
    ]
    for path in required:
        if not path.exists():
            add_failure(failures, "missing_required_file", "required current fact source is missing", path)

    sanitizer = sanitizer_self_check()
    if not sanitizer.get("ok"):
        add_failure(failures, "sanitizer_self_check_failed", "shared sanitizer self-check failed", Path(__file__))

    static_checks = validate_static_sources(failures)
    manifest = load_manifest(failures)
    viewport_count = validate_viewports(manifest, failures) if manifest else 0
    scenario_count = validate_interaction_events(manifest, failures) if manifest else 0
    keyboard_count = validate_checklists(manifest, "keyboardChecklists", KEYBOARD_REQUIRED, failures) if manifest else 0
    voiceover_count = validate_checklists(manifest, "voiceOverChecklists", VOICEOVER_REQUIRED, failures) if manifest else 0

    output = {
        "ok": not failures,
        "gate": "P13C",
        "status": "pass" if not failures else "fail",
        "checked": {
            "staticGestureChecks": static_checks.get("direct_paste_gesture_removed", False)
            and static_checks.get("current_primary_activation_uses_native_appkit_recognizers_without_timing_patch", False),
            "stateOwnershipNegativeChecks": static_checks.get("focused_view_local", False) and static_checks.get("interaction_token_view_local", False),
            "detailCodePathChecks": static_checks.get("current_detail_panel_has_one_appkit_owner", False)
            and static_checks.get("current_detail_panel_supports_first_mouse_and_focus", False),
            "pasteActivationContractChecks": static_checks.get("paste_activation_control_removed", False)
            and static_checks.get("paste_activation_storage_removed", False)
            and static_checks.get("paste_activation_type_removed", False)
            and static_checks.get("current_primary_activation_uses_native_appkit_recognizers_without_timing_patch", False),
            "filterMenuLayoutChecks": static_checks.get("current_filter_groups_use_menu_contract_not_inline_expansion", False)
            and static_checks.get("current_bottom_header_is_single_search_filter_tag_action_row", False)
            and static_checks.get("current_side_header_has_two_distinct_control_rows", False)
            and static_checks.get("current_side_filters_are_iconless_and_horizontal", False)
            and static_checks.get("current_search_and_filter_viewports_constrain_horizontally", False)
            and static_checks.get("current_toolbar_shares_28pt_compact_metrics", False)
            and static_checks.get("current_notification_anchor_tracks_visible_filter_or_tag_viewport", False),
            "viewportEvidence": viewport_count,
            "interactionScenarios": scenario_count,
            "interactionSequenceFixture": interaction_fixture_ok,
            "keyboardChecklists": keyboard_count,
            "voiceOverChecklists": voiceover_count,
            "sanitizerChecks": bool(sanitizer.get("ok")),
        },
        "checked_files": [rel(path) for path in required if path.exists()],
        "current_evidence": {
            "prd": rel(STEP3_PRD),
            "technical_plan": rel(STEP3_PLAN),
            "dispatch": rel(STEP3_DISPATCH),
            "dev_record": rel(STEP3_DEV_RECORD) if STEP3_DEV_RECORD.exists() else None,
            "manifest": rel(MANIFEST) if MANIFEST.exists() else None,
        },
        "baseline_reference": {
            "old_archives_used_for_ok": False,
            "old_step_docs_used_for_ok": False,
            "real_app_or_clipboard_used_for_ok": False,
        },
        "static_checks": static_checks,
        "sanitizer": sanitizer,
        "failures": failures,
    }
    print(json.dumps(sanitize_payload(output), ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
