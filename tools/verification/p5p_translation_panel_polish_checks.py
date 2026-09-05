#!/usr/bin/env python3
"""P5-P unified translation panel interaction and surface checks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
TRANSLATION_LOCALIZABLE = APP / "Features" / "Translation" / "Resources" / "TranslationLocalizable.xcstrings"
COORDINATOR = APP / "Features" / "Translation" / "TranslationFeatureCoordinator.swift"
SESSION_MODEL = APP / "Features" / "Translation" / "TranslationPanelSessionModel.swift"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
PANEL_COMPONENTS = (
    APP
    / "Features"
    / "Translation"
    / "Panel"
    / "TranslationFloatingPanelComponents.swift"
)
PRESENTER = APP / "Services" / "TranslationPanelPresenter.swift"
ENTRY_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationEntryBridgeTests.swift"

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": sanitize_text(completed.stdout),
        "stderr_tail": sanitize_text(completed.stderr[-1800:]),
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    p5o = run(
        [
            "python3",
            "tools/verification/p5o_openai_translation_runtime_gate_checks.py",
            "--timeout",
            str(args.timeout),
        ],
        args.timeout,
    )
    require(
        p5o["ok"],
        "p5o_regression_failed",
        p5o["stdout"] or p5o["stderr_tail"],
        failures,
    )
    observations["p5o_regression"] = p5o["ok"]

    for path in [
        LOCALIZABLE,
        TRANSLATION_LOCALIZABLE,
        COORDINATOR,
        SESSION_MODEL,
        PANEL,
        PANEL_COMPONENTS,
        PRESENTER,
        ENTRY_TESTS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    coordinator = text(COORDINATOR)
    session = text(SESSION_MODEL)
    panel = text(PANEL)
    panel_components = text(PANEL_COMPONENTS)
    presenter = text(PRESENTER)
    tests = text(ENTRY_TESTS)
    combined = "\n".join(
        [coordinator, session, panel, panel_components, presenter]
    )

    required_symbols = [
        "TranslationPanelActions",
        "TranslationFloatingPanelView",
        "TranslationPanelSessionModel",
        "TranslationSessionPanel",
        ".nonactivatingPanel",
        "TranslationPanelActivationPolicy",
        "TranslationFirstMouseHostingView",
        "BlocksNotificationPresentationState",
        "BlocksAnchoredNotificationPanelPresenter",
        ".blocksSurface(",
        ".panel,",
        "TextEditor(",
        "languageBar",
        "Array(resultStates.enumerated())",
        "TranslationPanelResultStateReader(",
        "TranslationResultCard(",
        "BlocksCompactIconButton(",
        "TranslationServiceOrderDragSource(",
        "BlocksPanelWindowDragArea(",
        ".accessibilityLabel(",
        "beginDraggingSession(",
        "performDragOperation(",
        "maximumSlotCount = 4",
        "onCopy:",
        "onSpeak:",
        "onRetry:",
        "collapsedServiceIDs",
        "model.isPinned",
        "actions.openFavorites()",
        "actions.openTranslationSettings()",
        "onExitCommand",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(
        not missing_symbols,
        "translation_panel_contract_missing",
        ", ".join(missing_symbols),
        failures,
    )
    require(
        "inputSource == .manual" in presenter
        and "makeKey: TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation" in presenter
        and "presentationCoordinator.present(" in presenter
        and "override func acceptsFirstMouse" in presenter,
        "translation_panel_focus_contract_missing",
        "The nonactivating panel may take Key focus for manual input only and must accept the first explicit edit click.",
        failures,
    )
    require(
        "func reposition(to:" not in presenter
        and "TranslationPanelPlacementStore" not in presenter
        and ".utilityWindow" not in presenter
        and "BlocksFloatingPanelWindowRole.nonactivatingSession.apply(to: panel)" in presenter,
        "legacy_translation_panel_repositioning_present",
        "The visible panel must be centered before presentation and must not restore or animate a second position.",
        failures,
    )
    require(
        "sourceExpanded" not in panel
        and "sourceExpanded" not in session
        and "translation.panel.selectionActions" not in panel
        and ".overlay(alignment: .topTrailing)" not in panel
        and "notificationPresenter.attach(to: panel)" in presenter,
        "translation_panel_stable_source_contract_missing",
        "The source editor must remain expanded, selection recovery actions must stay out of the panel, and notifications must use the external anchored HUD.",
        failures,
    )
    forbidden = [
        "URLSession",
        "Process(",
        "getenv(",
        "SecItem",
        "Authorization",
        "Bearer",
        "NSPasteboard.general",
    ]
    panel_hits = [symbol for symbol in forbidden if symbol in panel + "\n" + presenter]
    require(
        not panel_hits,
        "forbidden_translation_panel_runtime",
        ", ".join(panel_hits),
        failures,
    )
    require(
        "highPriorityGesture(" not in panel_components
        and "DragGesture(" not in panel_components
        and ".onDrop(" not in panel
        and "mouseDragged(with event:" in panel_components
        and "beginDraggingSession(" in panel_components
        and "draggingUpdated(" in panel_components
        and "performDragOperation(" in panel_components
        and "TranslationServiceOrderDragPayload" in panel_components
        and "TranslationServiceOrderDragPayload.decode(" in panel_components
        and "sender.draggingPasteboard" in panel_components
        and "dragCoordinator?.commit(" in panel_components,
        "translation_result_drag_contract_invalid",
        "Result ordering must keep pointer tracking, target resolution, and the single commit in one AppKit lifecycle.",
        failures,
    )
    require(
        "testTranslationPanelAcceptsFirstMouseAndRoutesEscape" in tests
        and "testTranslationPanelGeometryShrinksToNarrowVisibleFrame" in tests
        and "testSelectionPanelIsCenteredOnResolvedScreen" in tests
        and "testTranslationEntryScreenContextPreservesFrozenDisplayAcrossAsyncWork" in tests
        and "testTranslationPanelOnlyTakesKeyOnManualPresentation" in tests,
        "translation_panel_behavior_tests_missing",
        "First mouse, Escape, target-screen centering, trigger-screen freezing, narrow-screen geometry, and nonactivating presentation require AppTests.",
        failures,
    )
    require(
        "testTranslationNotificationUsesSeparateNonKeyChildPanel" in tests,
        "translation_notification_window_test_missing",
        "The anchored notification panel requires an AppKit window contract test.",
        failures,
    )

    localized_strings: dict[str, Any] = {}
    for catalog in [LOCALIZABLE, TRANSLATION_LOCALIZABLE]:
        if catalog.exists():
            localized_strings.update(
                json.loads(catalog.read_text(encoding="utf-8")).get("strings", {})
            )
    required_keys = [
        "translation.panel.title",
        "translation.panel.pin",
        "translation.panel.source",
        "translation.panel.target",
        "translation.panel.swapLanguages",
        "translation.panel.diagnostics",
        "translation.result.speak",
        "translation.favorite.action",
        "translation.notification.copied",
        "translation.notification.copyFailed",
    ]
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localized_strings.get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [
            language
            for language in LANGUAGES
            if language not in entry.get("localizations", {})
        ]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(
        not missing_l10n,
        "missing_localization",
        ", ".join(missing_l10n),
        failures,
    )
    observations["localization"] = {
        "checked": len(required_keys),
        "missing": missing_l10n,
    }

    report = {
        "ok": not failures,
        "suite": "p5p_translation_panel_polish_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
