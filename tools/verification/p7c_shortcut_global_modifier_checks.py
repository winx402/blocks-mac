#!/usr/bin/env python3
"""P7-C shortcut global modifier checks for Blocks."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
SHORTCUTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ShortcutController.swift"
SHORTCUT_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Shortcuts" / "ShortcutStore.swift"
SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "ShortcutSettingsPane.swift"
SETTINGS_SHELL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "SettingsShellView.swift"
LEGACY_SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "SettingsView.swift"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
STEP4C_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_2_DEVELOPMENT_RECORD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "开发记录-Step4C-2-ShortcutStore-v0.md"

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": sanitize_text(completed.stdout[-2400:]),
        "stderr_tail": sanitize_text(completed.stderr[-2400:]),
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def global_modifier_setter_is_reachable(shortcut_store: str) -> bool:
    setter = re.search(
        r"^    func setGlobalShortcutModifierPreset\(_ preset: ShortcutModifierPreset\) \{\n(?P<body>(?:        .*\n)*)    \}",
        shortcut_store,
        re.MULTILINE,
    )
    if setter is None:
        return False
    statements = [line.strip() for line in setter.group("body").splitlines() if line.strip()]
    return statements == [
        "ShortcutBindingStore.setGlobalModifierPreset(preset)",
        "registerDefaultShortcuts(force: true)",
    ]


def has_global_modifier_contract(
    shortcuts: str,
    shortcut_store: str,
    settings: str,
    settings_shell: str,
    localizable: dict[str, Any],
) -> dict[str, bool]:
    source_label_block = re.search(
        r"enum ShortcutBindingSource: String \{.*?\n\}",
        shortcuts,
        re.DOTALL,
    )
    picker_block = re.search(
        r"Picker\(L10n\.string\(\"settings\.shortcutGlobalModifier\"\),\s*selection:\s*globalShortcutModifier\)\s*\{.*?\n\s*\}",
        settings,
        re.DOTALL,
    )
    custom_priority = re.search(
        r"static func effectiveBinding\(for command:.*?\{\s*if let custom = customBinding\(for: command, userDefaults: userDefaults\) \{\s*return custom\s*\}\s*return defaultBindingWithEnabledOverride",
        shortcuts,
        re.DOTALL,
    )
    required_l10n_keys = {
        "settings.shortcutGlobalModifier",
        "settings.shortcutGlobalModifierNote",
        "settings.shortcutSource",
        "settings.shortcutSource.global",
        "settings.shortcutSource.custom",
    }
    return {
        "settings_pane_exists": bool(settings),
        "legacy_settings_view_absent": not LEGACY_SETTINGS.exists(),
        "shortcuts_route_to_pane": bool(
            re.search(r"case \.shortcuts:\s*ShortcutSettingsPane\(\)", settings_shell)
        ),
        "global_picker_has_binding": bool(picker_block)
        and "ForEach(ShortcutModifierPreset.allCases)" in picker_block.group(0),
        "global_picker_updates_store": bool(
            re.search(
                r"private var globalShortcutModifier: Binding<ShortcutModifierPreset> \{.*?shortcutStore\.setGlobalShortcutModifierPreset\(preset\)",
                settings,
                re.DOTALL,
            )
        ),
        "store_setter_persists_and_reregisters": global_modifier_setter_is_reachable(shortcut_store),
        "global_modifier_persistence_key": 'globalModifierKey = "shortcut.globalModifier"' in shortcuts,
        "custom_binding_precedes_global_default": bool(custom_priority),
        "source_label_connected": bool(source_label_block)
        and 'L10n.string("settings.shortcutSource.global")' in source_label_block.group(0)
        and 'L10n.string("settings.shortcutSource.custom")' in source_label_block.group(0)
        and "bindingSource.localizedTitle" in settings,
        "global_modifier_localization_present": all(
            key in localizable.get("strings", {})
            and all(
                language in localizable["strings"][key].get("localizations", {})
                for language in LANGUAGES
            )
            for key in required_l10n_keys
        ),
    }


def mutations_fail_closed(
    shortcuts: str,
    shortcut_store: str,
    settings: str,
    settings_shell: str,
    localizable: dict[str, Any],
) -> dict[str, bool]:
    sources = {
        "shortcuts": shortcuts,
        "shortcut_store": shortcut_store,
        "settings": settings,
        "settings_shell": settings_shell,
    }
    mutations = {
        "route_removed": ("settings_shell", "ShortcutSettingsPane()", "EmptyView()"),
        "picker_binding_removed": ("settings", "selection: globalShortcutModifier", "selection: .constant(.controlOption)"),
        "custom_priority_removed": ("shortcuts", "return custom", "return defaultBindingWithEnabledOverride(command: command, userDefaults: userDefaults)"),
        "source_label_removed": ("settings", "bindingSource.localizedTitle", 'L10n.string("settings.shortcutSource.global")'),
        "setter_persistence_removed": (
            "shortcut_store",
            "ShortcutBindingStore.setGlobalModifierPreset(preset)\n        registerDefaultShortcuts(force: true)",
            "// persistence removed\n        registerDefaultShortcuts(force: true)",
        ),
        "setter_reregistration_removed": (
            "shortcut_store",
            "ShortcutBindingStore.setGlobalModifierPreset(preset)\n        registerDefaultShortcuts(force: true)",
            "ShortcutBindingStore.setGlobalModifierPreset(preset)\n        // re-registration removed",
        ),
        "setter_persistence_unreachable": (
            "shortcut_store",
            "ShortcutBindingStore.setGlobalModifierPreset(preset)\n        registerDefaultShortcuts(force: true)",
            "if false { ShortcutBindingStore.setGlobalModifierPreset(preset) }\n        registerDefaultShortcuts(force: true)",
        ),
        "setter_reregistration_unreachable": (
            "shortcut_store",
            "ShortcutBindingStore.setGlobalModifierPreset(preset)\n        registerDefaultShortcuts(force: true)",
            "ShortcutBindingStore.setGlobalModifierPreset(preset)\n        DispatchQueue.main.async { registerDefaultShortcuts(force: true) }",
        ),
    }
    results: dict[str, bool] = {}
    for name, (source_name, original, replacement) in mutations.items():
        if original not in sources[source_name]:
            results[name] = False
            continue
        mutated = dict(sources)
        mutated[source_name] = mutated[source_name].replace(original, replacement, 1)
        results[name] = not all(
            has_global_modifier_contract(
                mutated["shortcuts"],
                mutated["shortcut_store"],
                mutated["settings"],
                mutated["settings_shell"],
                localizable,
            ).values()
        )
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--skip-build", action="store_true", help="Run source checks without invoking the app build.")
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    shortcuts = text(SHORTCUTS)
    shortcut_store = text(SHORTCUT_STORE)
    settings = text(SETTINGS)
    settings_shell = text(SETTINGS_SHELL)

    required_shortcut_symbols = [
        "enum ShortcutModifierPreset",
        "shortcut.globalModifier",
        "effectiveBinding(for command",
        "hasCustomBinding(for command",
        "bindingSource(for command",
        "setGlobalModifierPreset",
        "ShortcutBindingSource",
        "case global",
        "case custom",
    ]
    missing_shortcuts = [symbol for symbol in required_shortcut_symbols if symbol not in shortcuts]
    require(not missing_shortcuts, "missing_shortcut_global_symbols", ", ".join(missing_shortcuts), failures)

    required_store_symbols = [
        "final class ShortcutStore",
        "func globalShortcutModifierPreset()",
        "func setGlobalShortcutModifierPreset(_ preset:",
        "ShortcutBindingStore.globalModifierPreset()",
        "ShortcutBindingStore.setGlobalModifierPreset(preset)",
    ]
    missing_store = [symbol for symbol in required_store_symbols if symbol not in shortcut_store]
    require(not missing_store, "missing_shortcut_store_global_facade", ", ".join(missing_store), failures)

    required_settings_symbols = [
        "globalShortcutModifier",
        "settings.shortcutGlobalModifier",
        "settings.shortcutSource",
        "bindingSource.localizedTitle",
    ]
    missing_settings = [symbol for symbol in required_settings_symbols if symbol not in settings]
    require(not missing_settings, "missing_settings_shortcut_global_ui", ", ".join(missing_settings), failures)

    require(settings != "", "shortcut_settings_pane_missing", str(SETTINGS.relative_to(ROOT)), failures)
    require(not LEGACY_SETTINGS.exists(), "legacy_settings_view_remaining", str(LEGACY_SETTINGS.relative_to(ROOT)), failures)
    require(
        bool(re.search(r"case \.shortcuts:\s*ShortcutSettingsPane\(\)", settings_shell)),
        "shortcut_settings_route_disconnected",
        "SettingsShellView .shortcuts must route to ShortcutSettingsPane()",
        failures,
    )

    localizable = json.loads(text(LOCALIZABLE))
    required_keys = [
        "settings.shortcutGlobalModifier",
        "settings.shortcutGlobalModifierNote",
        "settings.shortcutSource",
        "settings.shortcutSource.global",
        "settings.shortcutSource.custom",
    ]
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localizable.get("strings", {}).get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [lang for lang in LANGUAGES if lang not in entry.get("localizations", {})]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(not missing_l10n, "missing_localization", ", ".join(missing_l10n), failures)

    contract = has_global_modifier_contract(shortcuts, shortcut_store, settings, settings_shell, localizable)
    require(all(contract.values()), "shortcut_global_modifier_contract_disconnected", str(contract), failures)
    mutation_results = mutations_fail_closed(shortcuts, shortcut_store, settings, settings_shell, localizable)
    require(all(mutation_results.values()), "shortcut_global_modifier_mutation_bypass", str(mutation_results), failures)
    observations["contract"] = contract
    observations["mutation_adversaries_fail_closed"] = mutation_results

    if args.skip_build:
        observations["app_build"] = {"skipped": True}
    else:
        build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
        require(build["ok"], "app_build_failed", build["stderr_tail"] or build["stdout_tail"], failures)
        observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}
    observations["current_evidence"] = {
        "prd": str(STEP4C_PRD.relative_to(ROOT)),
        "development_record": str(STEP4C_2_DEVELOPMENT_RECORD.relative_to(ROOT)),
    }
    observations["baseline_reference"] = {
        "legacy_story_used_for_ok": False,
        "note": "P7C Step 4C-2 checks use current PRD, current development record, and current code facts.",
    }

    report = {
        "ok": not failures,
        "suite": "p7c_shortcut_global_modifier_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
