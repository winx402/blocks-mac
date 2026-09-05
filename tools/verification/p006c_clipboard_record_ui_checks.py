#!/usr/bin/env python3
"""P006-C clipboard record UI checks."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"

RECORD_VIEWS = APP / "Views" / "ClipboardRecordViews.swift"
RECORD_ROW = APP / "Features" / "Clipboard" / "Records" / "ClipboardFloatingRecordRow.swift"
PREVIEW_VIEWS = APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift"
PANEL_LAYOUT = APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift"
PANEL_INTERACTION = APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelInteractionCoordinator.swift"
WIDTH_HANDLE = APP / "Views" / "ClipboardCardWidthResizeHandle.swift"


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


def main() -> int:
    failures: list[dict[str, str]] = []
    files = [RECORD_VIEWS, RECORD_ROW, PREVIEW_VIEWS, PANEL_LAYOUT, PANEL_INTERACTION, WIDTH_HANDLE]
    missing = [path for path in files if not path.exists()]
    for path in missing:
        failures.append({"code": "missing_file", "detail": rel(path)})

    record_views = read(RECORD_VIEWS) + "\n" + read(RECORD_ROW)
    preview_views = read(PREVIEW_VIEWS)
    panel_layout = read(PANEL_LAYOUT)
    panel_interaction = read(PANEL_INTERACTION)
    width_handle = read(WIDTH_HANDLE)

    row_block = block(record_views, "struct ClipboardFloatingRecordRow")
    card_block = block(record_views, "struct ClipboardFloatingRecordCard")
    preview_text_block = block(preview_views, "private struct ClipboardPreviewText")
    record_list_block = block(panel_layout, "private var recordList")
    side_line_limit_block = block(panel_layout, "private func sideRecordBodyLineLimit")
    side_resize_handle_block = block(panel_layout, "private struct ClipboardSideRowHeightResizeHandle")
    width_handle_block = block(width_handle, "struct ClipboardCardWidthResizeHandle")

    checks = {
        "side_list_width_locked": (
            "GeometryReader" in record_list_block
            and re.search(r"let\s+availableWidth\s*=", record_list_block) is not None
            and ".frame(width: availableWidth, alignment: .topLeading)" in record_list_block
            and ".frame(width: availableWidth, height: proxy.size.height, alignment: .topLeading)" in record_list_block
        ),
        "single_global_side_resize_entry": (
            "if record.id != lastRecordID" not in record_list_block
            and "private func sideRowResizeHandle(" in panel_layout
            and "sideRowResizeHandle(" in record_list_block
        ),
        "default_side_row_uses_two_lines": (
            "itemFontSize * 2.6" in side_line_limit_block
            and "rowHeight - reservedHeight" in side_line_limit_block
            and "return max(1, min(10, computedLimit))" in side_line_limit_block
        ),
        "preview_wraps_words_with_char_fallback": (
            "preferredLineBreakMode(for: text)" in preview_text_block
            and ".byWordWrapping" in preview_text_block
            and ".byCharWrapping" in preview_text_block
        ),
        "preview_footer_protected": (
            ".layoutPriority(1)" in row_block
            and ".frame(maxHeight: contentHeight, alignment: .topLeading)" in row_block
            and ".clipped()" in row_block
        ),
        "native_click_count_has_no_timing_patch": (
            record_views.count(".pointerAction(clickCount: NSApp.currentEvent?.clickCount)") >= 2
            and "TapGesture(count: 2)" not in record_views
            and "Task.sleep" not in panel_interaction
            and "pendingPrimaryActivationTask" not in panel_interaction
            and "InteractionTiming" not in panel_interaction
        ),
        "single_click_selection_is_immediate": (
            "enum ClipboardPanelActivationDecision" in panel_interaction
            and "case .selection, .singleClick:" in panel_interaction
            and "return .selectAndOpenDetail" in panel_interaction
            and "guard onSelect() else" in panel_interaction
            and "onPerform(.singleClick, .detailOpen)" in panel_interaction
        ),
        "selected_state_is_visible": (
            "interactionState" in row_block
            and "interactionState" in card_block
            and "ClipboardRecordInteractionState.resolve(" in row_block + card_block
            and "if isDetailPresented || isSelected" in record_views
            and "return .selected" in record_views
        ),
        "record_accessibility_actions_present": (
            record_views.count("accessibilityAddTraits(isSelected ? .isSelected : [])") >= 2
            and record_views.count("accessibilityAction(.default)") >= 2
            and "accessibilityAction(named: Text(L10n.string(\"clipboard.panel.detailTitle\")))" in record_views
            and "accessibilityAction(named: Text(L10n.string(\"clipboard.context.paste\")))" in record_views
            and "accessibilityAction(named: Text(" in record_views
        ),
        "card_favorite_action_reserves_title_space": (
            "cardFavoriteActionReservedTrailingSpace" in card_block
            and "Color.clear" in card_block
            and ".frame(width: cardFavoriteActionReservedTrailingSpace" in card_block
            and card_block.count(".frame(width: cardFavoriteActionReservedTrailingSpace") >= 2
        ),
        "resize_accessibility_actions_present": (
            "accessibilityAdjustableAction" in side_resize_handle_block
            and "accessibilityAdjustableAction" in width_handle_block
            and "accessibilityValue" in side_resize_handle_block
            and "accessibilityValue" in width_handle_block
        ),
        "resize_labels_are_localized": (
            'L10n.string("clipboard.panel.cardWidthResize.label")' in width_handle_block
            and 'L10n.string("clipboard.panel.cardWidthResize.help")' in width_handle_block
            and "调整条目宽度" not in width_handle_block
            and "拖动调整条目宽度" not in width_handle_block
        ),
    }

    for code, ok in checks.items():
        if not ok:
            failures.append({"code": code, "detail": "clipboard record UI expectation not met"})

    output = {
        "ok": not failures,
        "suite": "p006c_clipboard_record_ui_checks",
        "files": [rel(path) for path in files],
        "checks": checks,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
