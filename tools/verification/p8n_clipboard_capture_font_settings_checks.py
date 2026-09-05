#!/usr/bin/env python3
"""P8-N clipboard self-capture and item font setting checks."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from p8m_clipboard_modularization_checks import declaration_block, swift_without_comments


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"
CORE = ROOT / "apps/Blocks/BlocksCore"
BROKER = ROOT / "apps/Blocks/BlocksClipboardBroker"

FILES = {
    "feature_coordinator": APP / "Features/Clipboard/ClipboardFeatureCoordinator.swift",
    "store": APP / "Features/Clipboard/ClipboardStore.swift",
    "controller": APP / "Stores/ClipboardController.swift",
    "live_capture": APP / "Services/ClipboardLiveCaptureService.swift",
    "auto_paste": APP / "Services/ClipboardAutoPasteCoordinator.swift",
    "paste_orchestrator": APP / "Features/Clipboard/ClipboardPasteOrchestrator.swift",
    "settings": APP / "Support/ClipboardPanelSettings.swift",
    "panel": APP / "Views/ClipboardFloatingPanelView.swift",
    "records": APP / "Views/ClipboardRecordViews.swift",
    "detail_presentation_layer": APP / "Features/Clipboard/Detail/ClipboardDetailPresentationLayer.swift",
    "detail_presentation_view": APP / "Features/Clipboard/Detail/ClipboardDetailPresentationView.swift",
    "detail_panel": APP / "Features/Clipboard/Detail/ClipboardDetailPanel.swift",
    "floating_detail_card": APP / "Features/Clipboard/Detail/ClipboardFloatingDetailCard.swift",
    "settings_view": APP / "Features/Settings/ClipboardSettingsPane.swift",
    "strings": APP / "Resources/Localizable.xcstrings",
}
RECORD_SOURCES = [
    APP / "Features/Clipboard/Records/ClipboardRecordPreviewViews.swift",
    APP / "Features/Clipboard/Records/ClipboardRecordMenus.swift",
    APP / "Features/Clipboard/Records/ClipboardFloatingRecordRow.swift",
    FILES["records"],
]
PANEL_SOURCES = [
    FILES["panel"],
    APP / "Features/Clipboard/Panel/ClipboardPanelLayout.swift",
]
DETAIL_SOURCES = [
    FILES["detail_presentation_layer"],
    FILES["detail_presentation_view"],
    FILES["detail_panel"],
    FILES["floating_detail_card"],
]
LEGACY_DETAIL_PATHS = [
    APP / "Views/ClipboardHoverDetailLayer.swift",
    APP / "Features/Clipboard/Detail/ClipboardHoverTracking.swift",
    APP / "Features/Clipboard/Detail/ClipboardHoverDetailPanel.swift",
]
LEGACY_DETAIL_SYMBOLS = [
    "ClipboardHoverDetailLayer",
    "ClipboardHoverTracking",
    "ClipboardHoverDetailPanel",
]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def read_tree(path: Path) -> str:
    return "\n".join(
        child.read_text(encoding="utf-8")
        for child in sorted(path.rglob("*.swift"))
    ) if path.exists() else ""


def section(source: str, start: str, end: str | None = None) -> str:
    if start not in source:
        return ""
    tail = source.split(start, 1)[1]
    if end and end in tail:
        return tail.split(end, 1)[0]
    return tail


CAPTURE_PRUNE_CALL = re.compile(
    r"repository\.applyPolicy\(\s*effectivePrunePolicy\s*,\s*"
    r"onCommittedDeletion:\s*\{\s*deletedRecordIDs\s+in\s*"
    r"self\.recordActionValidity\.invalidate\(\s*recordIDs:\s*deletedRecordIDs\s*\)\s*\}\s*\)"
)


def capture_pruning_is_wired(source: str) -> bool:
    pipeline = declaration_block(swift_without_comments(source), "private final class ClipboardCapturePersistencePipeline")
    persist = declaration_block(pipeline, "func persist(")
    return len(list(CAPTURE_PRUNE_CALL.finditer(persist))) == 1


def capture_pruning_mutations_fail_closed(source: str) -> bool:
    clean = swift_without_comments(source)
    pipeline = declaration_block(clean, "private final class ClipboardCapturePersistencePipeline")
    persist = declaration_block(pipeline, "func persist(")
    match = CAPTURE_PRUNE_CALL.search(persist)
    if not match or not capture_pruning_is_wired(clean):
        return False
    call = match.group(0)
    mutations = [
        "repository.applyPolicy(effectivePrunePolicy)",
        call.replace("effectivePrunePolicy", "wrongPolicy"),
        call.replace("recordIDs: deletedRecordIDs", "recordIDs: []"),
        "/* " + call + " */",
    ]
    return all(not capture_pruning_is_wired(clean.replace(call, mutation, 1)) for mutation in mutations)


def main() -> int:
    sources = {name: read(path) for name, path in FILES.items()}
    sources["feature_coordinator"] += "\n" + read(APP / "Features/Clipboard/ClipboardFeatureCoordinator+CapturePersistence.swift")
    sources["records"] = "\n".join(read(path) for path in RECORD_SOURCES)
    sources["panel"] = "\n".join(read(path) for path in PANEL_SOURCES)
    sources["detail"] = "\n".join(read(path) for path in DETAIL_SOURCES)
    sources["clipboard_detail_tree"] = read_tree(APP / "Features/Clipboard/Detail")
    sources["broker_boundary"] = "\n".join(
        read(path)
        for path in sorted(APP.rglob("*.swift"))
        if "ClipboardBroker" in read(path)
    )
    sources["broker_protocol"] = read_tree(CORE)
    sources["broker_helper"] = read_tree(BROKER)
    module = "\n".join(sources.values())
    direct_preview_section = section(sources["records"], "struct ClipboardDirectContentPreview", "extension ClipboardRecorderItemKind")
    row_section = section(sources["records"], "struct ClipboardFloatingRecordRow", "struct ClipboardFloatingRecordCard")
    card_section = section(sources["records"], "struct ClipboardFloatingRecordCard")
    detail_card_source = sources["floating_detail_card"]
    detail_text_editor_section = section(detail_card_source, "private var detailTextEditor", "private func detailTextBlock")
    detail_text_block_section = section(detail_card_source, "private func detailTextBlock", "private var floatingDetailActionBar")
    detail_header_section = section(detail_card_source, "private var detailHeader", "private var fallbackMetadata")
    detail_metadata_section = section(detail_card_source, "private var fallbackMetadata", "private var detailPreviewDisplayText")
    checks = {
        "live_capture_uses_broker_owned_self_write_filter": (
            "ClipboardBroker" in sources["live_capture"]
            and "observe(" in sources["live_capture"]
            and "ignorePasteboardChange" not in sources["live_capture"]
            and "ignoredChangeCounts" not in sources["live_capture"]
            and "NSPasteboard.general" not in sources["live_capture"]
        ),
        "autopaste_reports_generation_scoped_write_lease": (
            "pasteboardChangeCountAfterWrite" in sources["auto_paste"]
            and "PasteResult" in sources["auto_paste"]
            and "ClipboardAutoPastePartialFailure" in sources["auto_paste"]
            and "ClipboardPasteboardWriteLease" in sources["auto_paste"] + sources["broker_boundary"] + sources["broker_protocol"]
            and "generation" in sources["auto_paste"] + sources["broker_boundary"] + sources["broker_protocol"]
        ),
        "broker_centralizes_self_write_suppression": (
            "ClipboardPasteboardWriteOrigin" in module
            and "origin" in sources["broker_protocol"] + sources["broker_helper"] + sources["broker_boundary"]
            and "changeCount" in sources["broker_protocol"] + sources["broker_helper"] + sources["broker_boundary"]
            and "ClipboardPasteboardChangeSuppressor.shared.suppress" not in sources["feature_coordinator"]
            and "ignorePasteboardChange" not in module
        ),
        "live_ingest_applies_existing_policy_and_prunes_payloads": all(
            needle in sources["feature_coordinator"]
            for needle in [
                "await self.clipboardStore.waitForCleanupMutationToSettle()",
                "clipboardStore.ingestLiveCaptureAsync(",
                "cleanupMode: self.policyCleanupMode",
                "retentionPolicy: self.policyRetentionPolicy",
                "maxItems: self.policyMaxItems",
                "preserveFavorite: self.policyPreserveFavorite",
            ]
        )
        and all(
            needle in sources["store"]
            for needle in [
                "func ingestLiveCaptureAsync(",
                "capturePersistencePipeline.persist(",
                "mutationQueue.effectivePolicy(",
                "refreshSearchResult(query: activeSearchQuery",
                "prunePayloadsToCurrentRecords()",
            ]
        )
        and "pruneFilterAfterHistoryRead(snapshot)" in sources["store"]
        and capture_pruning_is_wired(sources["store"]),
        "capture_pruning_mutations_fail_closed": capture_pruning_mutations_fail_closed(sources["store"]),
        "item_font_setting_is_typed_and_clamped": all(
            needle in sources["settings"]
            for needle in [
                "itemFontSize",
                "clipboard.panel.itemFontSize",
                "defaultItemFontSize",
                "minItemFontSize",
                "maxItemFontSize",
                "clampItemFontSize",
            ]
        ),
        "settings_view_exposes_item_font_slider": all(
            needle in sources["settings_view"]
            for needle in [
                "@AppStorage(ClipboardPanelSettings.Keys.itemFontSize)",
                "settings.clipboardPanelItemFontSize",
                "Slider(",
                "ClipboardPanelSettings.clampItemFontSize",
            ]
        ),
        "panel_passes_item_font_size_to_record_surfaces": all(
            needle in sources["panel"]
            for needle in [
                "@AppStorage(ClipboardPanelSettings.Keys.itemFontSize)",
                "clipboardItemFontSize",
                "itemFontSize: clipboardItemFontSize",
                "bottomRecordCardBodyLineLimit(for: cardHeight, itemFontSize:",
            ]
        ),
        "content_preview_uses_item_font_size": all(
            needle in direct_preview_section
            for needle in [
                "let itemFontSize: CGFloat",
                "fontSize: itemFontSize",
                "ClipboardPreviewText(",
            ]
        )
        and "NSFont.systemFont(ofSize: fontSize)" in sources["records"],
        "record_chrome_does_not_scale_with_item_font_size": all(
            forbidden not in row_section and forbidden not in card_section
            for forbidden in [
                "itemFontSize +",
                "itemFontSize -",
                "titleFontSize",
                "footerFontSize",
            ]
        )
        and "ClipboardDirectContentPreview(" in row_section
        and "itemFontSize: itemFontSize" in row_section
        and "ClipboardDirectContentPreview(" in card_section
        and "itemFontSize: itemFontSize" in card_section,
        "detail_presentation_uses_current_four_file_chain": all(
            sources[name]
            for name in [
                "detail_presentation_layer",
                "detail_presentation_view",
                "detail_panel",
                "floating_detail_card",
            ]
        )
        and all(
            needle in sources["panel"]
            for needle in [
                "ClipboardPanelDetailPresentationLayer(",
                "itemFontSize: clipboardItemFontSize",
            ]
        )
        and all(
            needle in sources["detail_presentation_layer"]
            for needle in [
                "struct ClipboardDetailPresentationItem",
                "let itemFontSize: CGFloat",
                "struct ClipboardDetailPresentationOverlay: NSViewRepresentable",
                "ClipboardDetailPresentationView()",
            ]
        )
        and all(
            needle in sources["detail_presentation_view"]
            for needle in [
                "final class ClipboardDetailPresentationView: NSView",
                "private let detailCoordinator = ClipboardDetailPanelCoordinator()",
                "detailCoordinator.show(",
                "item: item,",
                "struct ClipboardPanelDetailPresentationLayer: View",
                "itemFontSize: itemFontSize",
            ]
        )
        and all(
            needle in sources["detail_panel"]
            for needle in [
                "ClipboardFloatingDetailCard(",
                "itemFontSize: item.itemFontSize",
                "final class ClipboardDetailPanel: NSPanel",
            ]
        ),
        "detail_rejects_legacy_hover_implementation": (
            not any(path.exists() for path in LEGACY_DETAIL_PATHS)
            and all(
                symbol not in sources["clipboard_detail_tree"]
                for symbol in LEGACY_DETAIL_SYMBOLS
            )
        ),
        "detail_item_font_size_is_limited_to_preview_and_editor_body": (
            detail_card_source.count(".blocksFont(size: itemFontSize)") == 2
            and ".blocksFont(size: itemFontSize)" in detail_text_editor_section
            and ".blocksFont(size: itemFontSize)" in detail_text_block_section
        ),
        "detail_chrome_does_not_scale_with_item_font_size": all(
            forbidden not in detail_card_source
            for forbidden in [
                "itemFontSize +",
                "itemFontSize -",
                "max(10, itemFontSize",
                "max(9, itemFontSize",
            ]
        )
        and all(
            needle in detail_header_section
            for needle in [
                ".blocksFont(size: 13, weight: .semibold)",
                ".blocksFont(size: footerFontSize)",
                "BlocksCompactIconButton(",
            ]
        )
        and all(
            needle in detail_metadata_section
            for needle in [
                ".blocksFont(size: 9, weight: .medium)",
                ".blocksFont(size: detailFontSize)",
            ]
        )
        and "private var detailFontSize: CGFloat {\n        11\n    }" in detail_card_source
        and "private var footerFontSize: CGFloat {\n        10\n    }" in detail_card_source,
        "font_strings_are_localized": all(
            key in sources["strings"]
            for key in [
                "settings.clipboardPanelItemFontSize",
                "settings.clipboardPanelItemFontSizeDetail",
            ]
        ),
    }
    failures = [name for name, passed in checks.items() if not passed]
    print(json.dumps({
        "ok": not failures,
        "suite": "p8n_clipboard_capture_font_settings_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
