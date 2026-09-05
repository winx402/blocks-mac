#!/usr/bin/env python3
"""P11-C ShortcutStore boundary checks for Step 5."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
APP_MODEL = APP / "App" / "AppModel.swift"
SHORTCUT_STORE = APP / "Features" / "Shortcuts" / "ShortcutStore.swift"
SHORTCUT_CONTROLLER = APP / "Services" / "ShortcutController.swift"
SHORTCUT_PANE = APP / "Features" / "Settings" / "ShortcutSettingsPane.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
MIGRATION = APP / "App" / "Step5OneShotMigration.swift"
STEP5_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_5" / "PRD-Step5-门禁清理关闭-v0.md"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def fail(failures: list[dict], code: str, detail: str, path: Path) -> None:
    failures.append({"code": code, "detail": detail, "path": rel(path)})


def main() -> int:
    failures: list[dict] = []
    required = [APP_MODEL, SHORTCUT_STORE, SHORTCUT_CONTROLLER, SHORTCUT_PANE, PROJECT, MIGRATION, STEP5_PRD]
    for path in required:
        if not path.exists():
            fail(failures, "missing_file", "required current fact source missing", path)

    app_model = read(APP_MODEL)
    store = read(SHORTCUT_STORE)
    controller = read(SHORTCUT_CONTROLLER)
    pane = read(SHORTCUT_PANE)
    project = read(PROJECT)

    if "ShortcutStore.swift" not in project or "ShortcutStore.swift in Sources" not in project:
        fail(failures, "target_membership_missing", "ShortcutStore.swift", PROJECT)

    required_store_terms = [
        "final class ShortcutStore: ObservableObject",
        "@Published private(set) var shortcutRegistrationResults",
        "ShortcutActionHandlers",
        "clipboardQuickPaste: (Int) -> Void",
        "func configureActions",
        "func registerDefaultShortcuts",
        "func saveShortcutBinding",
        "func restoreDefaultShortcuts",
    ]
    missing = [term for term in required_store_terms if term not in store]
    if missing:
        fail(failures, "shortcut_store_contract_missing", ", ".join(missing), SHORTCUT_STORE)

    facade_hits = [
        term for term in [
            "var shortcutRegistrationResults",
            "func shortcutBinding(",
            "func shortcutRegistrationResult(",
            "func setGlobalShortcutModifierPreset(",
            "func saveShortcutBinding(",
            "func setShortcutEnabled(",
            "func restoreShortcutDefault(",
        ]
        if term in app_model
    ]
    if facade_hits:
        fail(failures, "app_model_shortcut_facade_remaining", ", ".join(facade_hits), APP_MODEL)

    if "@EnvironmentObject private var shortcutStore: ShortcutStore" not in pane:
        fail(failures, "shortcut_pane_not_direct_store", "ShortcutSettingsPane must read ShortcutStore directly", SHORTCUT_PANE)
    for token in ["shortcutStore.shortcutBinding", "shortcutStore.saveShortcutBinding", "shortcutStore.restoreShortcutDefault"]:
        if token not in pane:
            fail(failures, "shortcut_pane_store_action_missing", token, SHORTCUT_PANE)

    quick_paste_terms = [
        "case clipboardQuickPaste1",
        "case clipboardQuickPaste9",
        "var quickPasteIndex: Int?",
        "Command + 1",
        "Command + 9",
        "ShortcutCommand.settingsVisibleCases",
        "quickPasteIndex == nil",
        "actions.clipboardQuickPaste(index)",
        "pasteClipboardQuickRecord(index:",
    ]
    quick_missing = [term for term in quick_paste_terms if term not in controller + "\n" + store + "\n" + pane + "\n" + app_model]
    if quick_missing:
        fail(failures, "clipboard_quick_paste_shortcut_missing", ", ".join(quick_missing), SHORTCUT_CONTROLLER)

    old_runtime_tokens = [
        "migrateLegacyOptionOnlyDefaultIfNeeded",
        "migrateLegacyOptionOnlyCustomBindingsIfNeeded",
        "legacyOption",
        "shortcut.globalModifier.migratedControlOptionDefault.v2",
        "shortcut.customBinding.migratedControlOptionDefault.v2",
    ]
    controller_hits = [token for token in old_runtime_tokens if token in controller]
    if controller_hits:
        fail(failures, "shortcut_runtime_migration_remaining", ", ".join(controller_hits), SHORTCUT_CONTROLLER)

    migration = read(MIGRATION)
    if "migrateShortcutDefaults" not in migration or "Step5OneShotMigration" not in migration:
        fail(failures, "one_shot_shortcut_migration_missing", "migrateShortcutDefaults", MIGRATION)
    if re.search(r"AppState|SettingsView", store + pane + controller):
        fail(failures, "old_boundary_token", "AppState/SettingsView", SHORTCUT_STORE)

    payload = {
        "ok": not failures,
        "gate": "P11C",
        "checked_files": [rel(path) for path in required],
        "current_evidence": {"prd": rel(STEP5_PRD)},
        "baseline_reference": {"old_archives_used_for_ok": False},
        "failures": failures,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
