#!/usr/bin/env python3
"""P7-E canonical language and stable multi-result card checks."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORE_MODELS = ROOT / "apps/Blocks/BlocksCore/TranslationModels.swift"
PANEL = ROOT / "apps/Blocks/BlocksApp/Views/TranslationFloatingPanelView.swift"
PANEL_COMPONENTS = (
    ROOT
    / "apps/Blocks/BlocksApp/Features/Translation/Panel"
    / "TranslationFloatingPanelComponents.swift"
)
RUNTIME = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationServiceRuntime.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    models = read(CORE_MODELS)
    panel = read(PANEL)
    panel_components = read(PANEL_COMPONENTS)
    panel_ui = panel + "\n" + panel_components
    result_card = panel_components.partition("struct TranslationResultCard: View")[2]
    action_type = panel_components.partition("enum TranslationResultHeaderAction: Hashable")[2].partition(
        "enum TranslationResultHeaderActionLayout"
    )[0]
    compact_card = re.sub(r"\s+", "", result_card)
    runtime = read(RUNTIME)
    checks = {
        "canonical_bcp47_language_type": (
            "public struct TranslationLanguageTag" in models
            and 'replacingOccurrences(of: "_", with: "-")' in models
            and 'language.caseInsensitiveCompare("auto") != .orderedSame' in models
            and "isASCIIAlphanumeric" in models
        ),
        "session_owns_ordered_result_snapshots": (
            "public struct TranslationSessionSnapshot" in models
            and "public let results: [TranslationResultSnapshot]" in models
            and "public var successfulResults" in models
        ),
        "registry_preserves_configured_adapter_order": (
            "func orderedAdapters(" in runtime
            and "serviceIDs.compactMap" in runtime
            and ".prefix(max(0, maximumCount))" in runtime
        ),
        "multi_result_cards": (
            "Array(resultStates.enumerated())" in panel
            and "TranslationPanelResultStateReader(" in panel
            and "TranslationResultCard(" in panel_ui
            and "struct TranslationResultCard: View" in panel_ui
        ),
        "result_actions_and_selection": all(
            symbol in panel_ui
            for symbol in [
                "onCopy:",
                "onSpeak:",
                "onRetry:",
                "Text(result.translatedText)",
                ".textSelection(.enabled)",
            ]
        ),
        "result_text_always_expanded": (
            bool(result_card)
            and "resultBody\n" in result_card
            and "if result.isSuccessful || result.state == .streaming" in result_card
            and all(
                symbol not in panel_ui
                for symbol in [
                    "onToggleCollapsed", "isCollapsed", "collapsedServiceIDs",
                    '"translation.result.collapse"', '"translation.result.expand"',
                ]
            )
        ),
        "three_fixed_result_action_slots": (
            "maximumSlotCount = 3" in panel_components
            and "maximumSlotCount = 4" not in panel_components
            and "reservedSlotCount:TranslationResultHeaderActionLayout.maximumSlotCount" in compact_card
            and "ForEach(headerActionIDs, id: \\.self)" in result_card
            and re.findall(r"\bcase\s+(\w+)", action_type) == ["copy", "speak", "diagnostics"]
            and all(symbol not in action_type for symbol in ["case collapse", "case cancel", "case retry"])
            and "actions.append(contentsOf: [.copy, .speak])" in panel_components
            and "actions.append(.diagnostics)" in panel_components
        ),
        "no_translate_cancel_or_collapse_controls": all(
            symbol not in panel_ui
            for symbol in [
                '"translation.runButton"', '"translation.cancel"', "onCancel:",
                "actions.cancelTranslation()", "model.cancel()", "onToggleCollapsed",
            ]
        ),
        "diagnostics_are_collapsed": (
            "@State private var diagnosticsExpanded = false" in panel_ui
            and "if hasDiagnostics && diagnosticsExpanded" in panel_ui
            and "diagnosticsExpanded.toggle()" in panel_ui
            and '"translation.panel.diagnostics"' in panel_ui
        ),
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7e_translation_language_result_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
