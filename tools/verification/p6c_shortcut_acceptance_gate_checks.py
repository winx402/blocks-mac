#!/usr/bin/env python3
"""P6-C shortcut acceptance gate checks for Blocks."""

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
SHORTCUTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ShortcutController.swift"
SHORTCUT_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Shortcuts" / "ShortcutStore.swift"
STEP4C_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_2_DEVELOPMENT_RECORD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "开发记录-Step4C-2-ShortcutStore-v0.md"

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
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
    """Return one Swift computed-property or function body without partial matches."""
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


def shortcut_diagnostics_contract_is_live(settings_text: str) -> bool:
    """Require the current SettingsFormRow diagnostics instead of a retired badge view."""
    summary = function_body(settings_text, "private var registrationSummary: String")
    diagnostics_title = settings_text.find('L10n.string("settings.shortcutDiagnosticsTitle")')
    diagnostics_start = settings_text.rfind("SettingsFormRow(", 0, diagnostics_title)
    next_section = settings_text.find("SettingsSection(", diagnostics_title + 1)
    diagnostics_row = settings_text[diagnostics_start:next_section] if diagnostics_start >= 0 else ""
    required_summary_metrics = [
        "settings.shortcutPrimaryRegisteredCount",
        "shortcutStore.registeredPrimaryShortcutCount",
        "settings.shortcutQuickPasteRegisteredCount",
        "shortcutStore.registeredQuickPasteShortcutCount",
        "settings.shortcutFailedCount",
        "shortcutStore.failedShortcutCount",
    ]
    return (
        "SettingsFormRow(" in diagnostics_row
        and 'L10n.string("settings.shortcutDiagnosticsDetail")' in diagnostics_row
        and "Label(" in diagnostics_row
        and "registrationSummary," in diagnostics_row
        and all(metric in summary for metric in required_summary_metrics)
        and 'L10n.string("settings.shortcutReregister")' in settings_text
        and "shortcutStore.refreshShortcutRegistrations()" in settings_text
    )


def run_structure_mutation_self_test() -> list[str]:
    """Prove removal of a displayed metric, label, or refresh action fails closed."""
    failures: list[str] = []
    settings = '''
    SettingsFormRow(
        title: L10n.string("settings.shortcutDiagnosticsTitle"),
        detail: L10n.string("settings.shortcutDiagnosticsDetail")
    ) {
        Label(
            registrationSummary,
            systemImage: "checkmark.circle.fill"
        )
    }
    SettingsSection(
        title: L10n.string("settings.shortcutStatus"),
        headerActions: {
            Button {
                let summary = shortcutStore.refreshShortcutRegistrations()
            } label: {
                Label(L10n.string("settings.shortcutReregister"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
    ) {}
    private var registrationSummary: String {
        [
            L10n.format("settings.shortcutPrimaryRegisteredCount", shortcutStore.registeredPrimaryShortcutCount),
            L10n.format("settings.shortcutQuickPasteRegisteredCount", shortcutStore.registeredQuickPasteShortcutCount),
            L10n.format("settings.shortcutFailedCount", shortcutStore.failedShortcutCount),
        ].joined(separator: " · ")
    }
    '''
    metric_tokens = [
        "settings.shortcutPrimaryRegisteredCount",
        "settings.shortcutQuickPasteRegisteredCount",
        "settings.shortcutFailedCount",
    ]
    for metric in metric_tokens:
        if shortcut_diagnostics_contract_is_live(settings.replace(metric, "removedMetric")):
            failures.append(f"diagnostic_metric_removal_accepted:{metric}")
    if shortcut_diagnostics_contract_is_live(settings.replace("Label(", "Text(")):
        failures.append("diagnostic_label_removal_accepted")
    if shortcut_diagnostics_contract_is_live(
        settings.replace("shortcutStore.refreshShortcutRegistrations()", "shortcutStore.restoreDefaultShortcuts()")
    ):
        failures.append("diagnostic_refresh_removal_accepted")
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
        help="Verify that representative structural mutations fail the diagnostics gate.",
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

    p6b_command = ["python3", "tools/verification/p6b_shortcut_customization_panel_polish_checks.py", "--timeout", str(args.timeout)]
    if args.skip_build:
        p6b_command.append("--skip-build")
    p6b = run(p6b_command, args.timeout)
    require(p6b["ok"], "p6b_regression_failed", p6b["stdout"] or p6b["stderr_tail"], failures)
    observations["p6b_regression"] = p6b["ok"]

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

    for path in [APP_MODEL, SHORTCUT_SETTINGS, SHORTCUTS, SHORTCUT_STORE, STEP4C_PRD, STEP4C_2_DEVELOPMENT_RECORD]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    combined = "\n".join(text(path) for path in [APP_MODEL, SHORTCUT_SETTINGS, SHORTCUTS, SHORTCUT_STORE])
    required_symbols = [
        "ShortcutStore",
        "registeredShortcutCount",
        "registeredPrimaryShortcutCount",
        "registeredQuickPasteShortcutCount",
        "disabledShortcutCount",
        "failedShortcutCount",
        "refreshShortcutRegistrations",
        "settings.shortcutReregister",
        "Control + Option + A",
        "Control + Option + V",
        "Control + Option + D",
        "Control + Option + S",
        "translationScreenshot",
        "showScreenshotTranslation",
        "disabled.insert(.translationScreenshot)",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(not missing_symbols, "missing_symbols", ", ".join(missing_symbols), failures)
    require(
        shortcut_diagnostics_contract_is_live(text(SHORTCUT_SETTINGS)),
        "shortcut_diagnostics_contract_missing",
        "Diagnostics must use the current SettingsFormRow Label(registrationSummary), display primary/quick-paste/failed metrics, and keep the refresh action.",
        failures,
    )

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
        "settings.shortcutDiagnosticsTitle",
        "settings.shortcutDiagnosticsDetail",
        "settings.shortcutRegisteredCount",
        "settings.shortcutPrimaryRegisteredCount",
        "settings.shortcutQuickPasteRegisteredCount",
        "settings.shortcutDisabledCount",
        "settings.shortcutFailedCount",
        "settings.shortcutReregister",
        "settings.shortcutManualChecklist",
        "status.shortcutsRefreshed.title",
        "status.shortcutsRefreshed.detail",
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

    forbidden = ["Authorization", "Bearer", "codex exec", "Process(", "getenv(", "SecItem", "URLSession"]
    forbidden_hits = [needle for needle in forbidden if needle in combined]
    require(not forbidden_hits, "forbidden_shortcut_runtime", ", ".join(forbidden_hits), failures)

    prd_text = text(STEP4C_PRD)
    development_text = text(STEP4C_2_DEVELOPMENT_RECORD)
    required_current_terms = ["Step 4C-2", "ShortcutStore", "P6C", "低敏", "不触发真实系统快捷键"]
    missing_current_terms = [term for term in required_current_terms if term not in prd_text and term not in development_text]
    require(not missing_current_terms, "current_evidence_missing_terms", ", ".join(missing_current_terms), failures)
    observations["current_evidence"] = {
        "prd": str(STEP4C_PRD.relative_to(ROOT)),
        "development_record": str(STEP4C_2_DEVELOPMENT_RECORD.relative_to(ROOT)),
    }
    observations["baseline_reference"] = {
        "legacy_story_used_for_ok": False,
        "note": "P6C Step 4C-2 checks use current PRD, current development record, and current code facts.",
    }

    report = {
        "ok": not failures,
        "suite": "p6c_shortcut_acceptance_gate_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
