#!/usr/bin/env python3
"""P6-B shortcut customization and floating panel polish checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
TRANSLATION_LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Translation" / "Resources" / "TranslationLocalizable.xcstrings"
APP_MODEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "App" / "AppModel.swift"
SHORTCUT_SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "ShortcutSettingsPane.swift"
CLIPBOARD_PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardFloatingPanelView.swift"
CLIPBOARD_PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardHistoryPanelPresenter.swift"
CLIPBOARD_FOCUS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Clipboard" / "ClipboardPanelFocusCoordinator.swift"
TRANSLATION_PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "TranslationFloatingPanelView.swift"
TRANSLATION_COMPONENTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Translation" / "Panel" / "TranslationFloatingPanelComponents.swift"
TRANSLATION_PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "TranslationPanelPresenter.swift"
TRANSLATION_SESSION_MODEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Translation" / "TranslationPanelSessionModel.swift"
GLASS_PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Support" / "GlassPanel.swift"
SHORTCUT_CONTROLLER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ShortcutController.swift"
SHORTCUT_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Shortcuts" / "ShortcutStore.swift"
SCREENSHOT_APP_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "ScreenshotAppStateTests.swift"
TRANSLATION_ENTRY_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationEntryBridgeTests.swift"
STEP4C_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_2_DEVELOPMENT_RECORD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "开发记录-Step4C-2-ShortcutStore-v0.md"

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
        "stderr_tail": sanitize_text(completed.stderr[-2400:]),
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def function_body(source: str, signature: str) -> str:
    """Return one Swift function body without accepting a partial match."""
    start = source.find(signature)
    if start < 0:
        return ""
    opening = source.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    return ""


def has_disabled_or_conditional_gate(source: str) -> bool:
    """Reject the common source-only ways to make a checked branch inert."""
    return any(
        needle in source
        for needle in ["if false", "if (false)", "#if false", "#if 0"]
    )


def swap_contract_is_live(session_text: str) -> bool:
    body = function_body(session_text, "func swapLanguagesAndRun()")
    required_steps = [
        "guard let sourceLanguage else { return }",
        "let previousTarget = targetLanguage",
        "self.sourceLanguage = previousTarget",
        "targetLanguage = sourceLanguage",
        "usesAutomaticTarget = false",
        "runImmediately()",
    ]
    if not body or has_disabled_or_conditional_gate(body):
        return False
    positions = [body.find(step) for step in required_steps]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        return False
    rerun_position = positions[-1]
    rerun_line = next(
        (
            line.strip()
            for line in body[rerun_position:].splitlines()
            if "runImmediately()" in line
        ),
        "",
    )
    return (
        rerun_line == "runImmediately()"
        and "return" not in body[positions[3] : rerun_position]
    )


def nonactivating_panel_contract_is_live(presenter_text: str) -> bool:
    make_panel = function_body(presenter_text, "private func makePanel(")
    activation_policy = function_body(
        presenter_text,
        "static func shouldBecomeKeyOnPresentation("
    )
    return (
        "styleMask:" in make_panel
        and ".nonactivatingPanel" in make_panel
        and "TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation" in presenter_text
        and "makeKey:" in presenter_text
        and "inputSource == .manual" in activation_policy
        and "override func acceptsFirstMouse" in presenter_text
        and not has_disabled_or_conditional_gate(make_panel)
        and not has_disabled_or_conditional_gate(activation_policy)
    )


def shortcut_accessibility_contract_is_live(
    settings_text: str,
    glass_panel_text: str,
) -> bool:
    return (
        all(
            key in settings_text
            for key in [
                "settings.shortcutEnabledFor",
                "settings.shortcutRecordFor",
                "settings.shortcutRecordingFor",
                "settings.shortcutRestoreDefaultFor",
                "command.localizedTitle",
                "BlocksCompactIconButton(",
            ]
        )
        and "let label: String" in glass_panel_text
        and ".accessibilityLabel(label)" in glass_panel_text
        and not has_disabled_or_conditional_gate(glass_panel_text)
    )


def multi_result_contract_is_live(
    panel_text: str,
    components_text: str,
    session_text: str,
) -> bool:
    apply_snapshot = function_body(session_text, "private func applySnapshot(")
    required_session_steps = [
        "@Published private(set) var resultStates",
        "let nextStates = snapshot.results.map { result in",
        "resultStates = nextStates",
    ]
    required_panel_steps = [
        "let resultStates = model.resultStates",
        "Array(resultStates.enumerated())",
        "TranslationPanelResultStateReader(",
        "TranslationResultCard(",
    ]
    return (
        all(step in session_text for step in required_session_steps)
        and all(step in panel_text for step in required_panel_steps)
        and "struct TranslationResultCard: View" in components_text
        and "ForEach(snapshot.results)" not in panel_text
        and "ForEach(snapshot.results)" not in components_text
        and bool(apply_snapshot)
        and not has_disabled_or_conditional_gate(apply_snapshot)
    )


def run_structure_mutation_self_test() -> list[str]:
    """Prove the semantic gates reject representative drift mutations."""
    failures: list[str] = []
    swap = """func swapLanguagesAndRun() {
        guard let sourceLanguage else { return }
        let previousTarget = targetLanguage
        self.sourceLanguage = previousTarget
        targetLanguage = sourceLanguage
        usesAutomaticTarget = false
        runImmediately()
    }"""
    if swap_contract_is_live(swap.replace("runImmediately()", "return")):
        failures.append("swap_early_return_accepted")
    if swap_contract_is_live(swap.replace("runImmediately()", "if false { runImmediately() }")):
        failures.append("swap_hidden_rerun_accepted")
    if swap_contract_is_live(swap.replace("runImmediately()", "let rerun = { runImmediately() }")):
        failures.append("swap_deferred_closure_accepted")
    if swap_contract_is_live(swap.replace("runImmediately()", "#if false\nrunImmediately()\n#endif")):
        failures.append("swap_conditional_compilation_accepted")
    presenter = """private func makePanel() {
        styleMask: [.nonactivatingPanel]
    }
    static func shouldBecomeKeyOnPresentation(inputSource: Input) -> Bool {
        inputSource == .manual
    }
    let makeKey: Bool = TranslationPanelActivationPolicy.shouldBecomeKeyOnPresentation
    override func acceptsFirstMouse(for event: Event?) -> Bool { true }"""
    if nonactivating_panel_contract_is_live(
        presenter.replace(".nonactivatingPanel", ".titled")
    ):
        failures.append("nonactivating_panel_removal_accepted")
    session = """@Published private(set) var resultStates: [State] = []
    private func applySnapshot(_ snapshot: Snapshot) {
        let nextStates = snapshot.results.map { result in result }
        resultStates = nextStates
    }"""
    panel = """let resultStates = model.resultStates
    Array(resultStates.enumerated())
    TranslationPanelResultStateReader(
    TranslationResultCard("""
    components = "struct TranslationResultCard: View {}"
    if multi_result_contract_is_live(
        panel.replace("Array(resultStates.enumerated())", "Array(resultStates.reversed())"),
        components,
        session,
    ):
        failures.append("result_order_mutation_accepted")
    if multi_result_contract_is_live(panel, components, session.replace("resultStates = nextStates", "if false { resultStates = nextStates }")):
        failures.append("result_assignment_hidden_accepted")
    settings = """settings.shortcutEnabledFor
    settings.shortcutRecordFor
    settings.shortcutRecordingFor
    settings.shortcutRestoreDefaultFor
    command.localizedTitle
    BlocksCompactIconButton("""
    glass_panel = "let label: String\n.accessibilityLabel(label)"
    if shortcut_accessibility_contract_is_live(
        settings,
        glass_panel.replace(".accessibilityLabel(label)", ""),
    ):
        failures.append("shortcut_accessibility_disconnect_accepted")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Run source checks without invoking the app build verification.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Verify that representative structural mutations fail the semantic gates.",
    )
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    if args.skip_build:
        observations["app_build"] = {"skipped": True}
    else:
        build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    if args.self_test:
        mutation_failures = run_structure_mutation_self_test()
        require(
            not mutation_failures,
            "structure_mutation_gate_incomplete",
            ", ".join(mutation_failures),
            failures,
        )
        observations["structure_mutation_self_test"] = {
            "ok": not mutation_failures,
            "failures": mutation_failures,
        }

    for path in [
        APP_MODEL,
        SHORTCUT_CONTROLLER,
        SHORTCUT_STORE,
        SHORTCUT_SETTINGS,
        CLIPBOARD_PANEL,
        CLIPBOARD_PRESENTER,
        CLIPBOARD_FOCUS,
        TRANSLATION_PANEL,
        TRANSLATION_COMPONENTS,
        TRANSLATION_PRESENTER,
        TRANSLATION_SESSION_MODEL,
        GLASS_PANEL,
        SCREENSHOT_APP_TESTS,
        TRANSLATION_ENTRY_TESTS,
        STEP4C_PRD,
        STEP4C_2_DEVELOPMENT_RECORD,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    shortcut_text = text(SHORTCUT_CONTROLLER)
    shortcut_store_text = text(SHORTCUT_STORE)
    settings_text = text(SHORTCUT_SETTINGS)
    app_model_text = text(APP_MODEL)
    clipboard_panel_text = text(CLIPBOARD_PANEL)
    clipboard_presenter_text = text(CLIPBOARD_PRESENTER)
    clipboard_focus_text = text(CLIPBOARD_FOCUS)
    translation_panel_text = text(TRANSLATION_PANEL)
    translation_components_text = text(TRANSLATION_COMPONENTS)
    translation_presenter_text = text(TRANSLATION_PRESENTER)
    translation_session_text = text(TRANSLATION_SESSION_MODEL)
    glass_panel_text = text(GLASS_PANEL)
    screenshot_tests_text = text(SCREENSHOT_APP_TESTS)
    translation_entry_tests_text = text(TRANSLATION_ENTRY_TESTS)
    combined = "\n".join(
        [
            shortcut_text,
            shortcut_store_text,
            settings_text,
            app_model_text,
            clipboard_panel_text,
            clipboard_presenter_text,
            clipboard_focus_text,
            translation_panel_text,
            translation_components_text,
            translation_presenter_text,
            translation_session_text,
            glass_panel_text,
            screenshot_tests_text,
            translation_entry_tests_text,
        ]
    )

    required_symbols = [
        "ShortcutBinding",
        "ShortcutBindingStore",
        "ShortcutStore",
        "registerConfiguredShortcuts",
        "ShortcutRegistrationSummary",
        "refreshShortcutRegistrations",
        "restoreDefaultShortcuts",
        "ShortcutRecorderRow",
        "NSEvent.addLocalMonitorForEvents",
        "shortcut.enabled.",
        "shortcut.binding.",
        "ShortcutRecorderState",
        "settings.shortcutRecord",
        "settings.shortcutRestoreDefault",
        "settings.shortcutRestoreAllDefaults",
        "translationScreenshot",
        "Control + Option + S",
        "disabled.insert(.translationScreenshot)",
        "ClipboardPanelFocusCoordinator",
        "ClipboardPanelFocusTarget",
        "focusSearch",
        "TranslationSessionPanel",
        ".nonactivatingPanel",
        "TranslationPanelActivationPolicy",
        "TranslationFirstMouseHostingView",
        "onExitCommand",
        "TranslationSourceTextEditor",
        "focusRequest: model.sourceFocusRequest",
        "model.requestSourceFocus()",
        "TranslationLanguageTag",
        "supportedSourceLanguages",
        "supportedLanguages",
        "TranslationResultCard",
        "translation.panel.swapLanguages",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(not missing_symbols, "missing_p6b_symbols", ", ".join(missing_symbols), failures)

    require("registerDefaultShortcuts" in shortcut_text, "missing_p6a_compatibility", "registerDefaultShortcuts wrapper must remain", failures)
    require(
        "kEventHotKeyReleased" in shortcut_text
        and "pressedHotKeyIDs" in shortcut_text
        and "pressedHotKeyResetTasks" in shortcut_text
        and "stalePressedHotKeyResetDelay" in shortcut_text
        and "DispatchWorkItem" in shortcut_text
        and "asyncAfter" in shortcut_text
        and "invokePressed(hotKeyID:" in shortcut_text
        and "markReleased(hotKeyID:" in shortcut_text,
        "shortcut_press_release_gate_missing",
        "Global shortcuts should fire once per physical press, wait for release, and recover if Carbon drops the release event.",
        failures,
    )
    require(
        "func unregisterAll()" in shortcut_text
        and "pressedHotKeyResetTasks.values.forEach { $0.cancel() }" in shortcut_text
        and "pressedHotKeyResetTasks.removeAll()" in shortcut_text
        and "pressedHotKeyIDs.removeAll()" in shortcut_text,
        "shortcut_registration_teardown_incomplete",
        "Replacing Carbon registrations must cancel stale reset tasks and clear the physical-press state.",
        failures,
    )
    require(
        "focusCoordinator.beginSession(sessionID:" in clipboard_presenter_text
        and "focusCoordinator.registerParentWindow(panel)" in clipboard_presenter_text
        and "focusCoordinator.focusSearch(reason: .panelRefocused)" in clipboard_presenter_text
        and "FloatingPanelDismissMonitor" in clipboard_presenter_text
        and "enum ClipboardPanelFocusTarget" in clipboard_focus_text
        and "func accepts(generation:" in clipboard_focus_text,
        "clipboard_focus_contract_missing",
        "Clipboard panel presentation, refocus, and delayed endpoint callbacks must use the unified generation-gated focus coordinator.",
        failures,
    )
    require(
        nonactivating_panel_contract_is_live(translation_presenter_text),
        "translation_nonactivating_panel_contract_missing",
        "The multiline nonactivating style mask must remain present; only manual presentation may request key focus while selection and screenshot preserve the external app.",
        failures,
    )
    require(
        "model.swapLanguagesAndRun()" in translation_panel_text
        and "isEnabled: model.sourceLanguage != nil" in translation_panel_text
        and swap_contract_is_live(translation_session_text),
        "swap_language_direction_contract_missing",
        "Language swap must use the current button enabled state, exchange the current BCP-47 direction, and rerun the current session without a hidden conditional or early return.",
        failures,
    )
    require(
        multi_result_contract_is_live(
            translation_panel_text,
            translation_components_text,
            translation_session_text,
        )
        and "snapshot.results.contains" in translation_session_text,
        "ordered_multi_result_contract_missing",
        "Snapshot results must feed stable result states, and the panel must enumerate those states into independent cards without restoring the aggregate snapshot loop.",
        failures,
    )
    require(
        "testTranslationScreenshotShortcutDefaultBindingAndActionRouting" in screenshot_tests_text
        and "testTranslationScreenshotShortcutFollowsScreenshotRuntimeAvailability" in screenshot_tests_text
        and "testTranslationPanelOnlyTakesKeyOnManualPresentation" in translation_entry_tests_text
        and "testTranslationPanelAcceptsFirstMouseAndRoutesEscape" in translation_entry_tests_text,
        "missing_current_behavior_tests",
        "Screenshot translation registration/delivery/runtime disabling and nonactivating panel behavior require executable AppTests.",
        failures,
    )
    require(
        shortcut_accessibility_contract_is_live(settings_text, glass_panel_text),
        "shortcut_row_accessibility_context_missing",
        "Shortcut settings must pass each command name through the shared button label, and the shared button must own the resulting accessibility label.",
        failures,
    )

    forbidden = ["Authorization", "Bearer", "codex exec", "Process(", "getenv(", "SecItem", "URLSession"]
    protected_text = "\n".join(
        [
            shortcut_text,
            settings_text,
            clipboard_panel_text,
            clipboard_presenter_text,
            clipboard_focus_text,
            translation_panel_text,
            translation_presenter_text,
        ]
    )
    forbidden_hits = [needle for needle in forbidden if needle in protected_text]
    require(
        "NSPasteboard.general" not in protected_text,
        "pasteboard_access_in_panel_or_shortcut_ui",
        "Shortcut settings and panel presentation/focus code must not read or write the system pasteboard.",
        failures,
    )
    require(not forbidden_hits, "forbidden_shortcut_panel_runtime", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {"forbidden_hits": forbidden_hits}

    localized_strings: dict[str, Any] = {}
    for catalog in [LOCALIZABLE, TRANSLATION_LOCALIZABLE]:
        require(
            catalog.exists(),
            "missing_file",
            str(catalog.relative_to(ROOT)),
            failures,
        )
        if catalog.exists():
            localized_strings.update(
                json.loads(catalog.read_text(encoding="utf-8")).get("strings", {})
            )
    required_keys = [
        "settings.shortcutRecord",
        "settings.shortcutRecordFor",
        "settings.shortcutRecording",
        "settings.shortcutRecordingFor",
        "settings.shortcutRestoreDefault",
        "settings.shortcutRestoreDefaultFor",
        "settings.shortcutRestoreAllDefaults",
        "settings.shortcutEnabled",
        "settings.shortcutEnabledFor",
        "settings.shortcutDisabled",
        "settings.shortcutInvalid",
        "settings.shortcutPressNew",
        "settings.shortcutNotRegistered",
        "translation.panel.swapLanguages",
        "translation.panel.result",
        "translation.shortcut.screenshot",
    ]
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localized_strings.get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [lang for lang in LANGUAGES if lang not in entry.get("localizations", {})]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(not missing_l10n, "missing_localization", ", ".join(missing_l10n), failures)
    observations["localization"] = {"checked": len(required_keys), "missing": missing_l10n}

    prd_text = text(STEP4C_PRD)
    development_text = text(STEP4C_2_DEVELOPMENT_RECORD)
    required_current_terms = [
        "Step 4C-2",
        "ShortcutStore",
        "P6B",
        "快捷键配置",
        "旧事实源",
    ]
    missing_current_terms = [term for term in required_current_terms if term not in prd_text and term not in development_text]
    require(not missing_current_terms, "current_evidence_missing_terms", ", ".join(missing_current_terms), failures)
    observations["current_evidence"] = {
        "prd": str(STEP4C_PRD.relative_to(ROOT)),
        "development_record": str(STEP4C_2_DEVELOPMENT_RECORD.relative_to(ROOT)),
    }
    observations["baseline_reference"] = {
        "legacy_story_used_for_ok": False,
        "legacy_project_docs_used_for_ok": False,
        "note": "P6B Step 4C-2 checks use current PRD, current development record, and current code facts.",
    }

    report = {
        "ok": not failures,
        "suite": "p6b_shortcut_customization_panel_polish_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
