#!/usr/bin/env python3
"""P7-E canonical language and stable multi-result card checks."""

from __future__ import annotations

import json
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
                "onToggleCollapsed:",
                "Text(result.translatedText)",
                ".textSelection(.enabled)",
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
