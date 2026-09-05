#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_SECTION = ROOT / "apps/Blocks/BlocksApp/Models/AppSection.swift"
CONTENT = ROOT / "apps/Blocks/BlocksApp/Views/ContentView.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
BLOCKS_APP = ROOT / "apps/Blocks/BlocksApp/App/BlocksApp.swift"
TRANSLATION_COORDINATOR = (
    ROOT
    / "apps/Blocks/BlocksApp/Features/Translation/TranslationFeatureCoordinator.swift"
)
STEP4C_PRD = ROOT / "docs/项目管理库/003_架构升级/step_4/PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_RECORD = ROOT / "docs/项目管理库/003_架构升级/step_4/开发记录-Step4C-3-SettingsShell-v0.md"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    app_section = read(APP_SECTION)
    content = read(CONTENT)
    app_model = read(APP_MODEL)
    blocks_app = read(BLOCKS_APP)
    translation_coordinator = read(TRANSLATION_COORDINATOR)
    failures = []
    for path in [
        APP_SECTION,
        CONTENT,
        APP_MODEL,
        BLOCKS_APP,
        TRANSLATION_COORDINATOR,
        STEP4C_PRD,
        STEP4C_RECORD,
    ]:
        if not path.exists():
            failures.append({"code": "missing_file", "detail": rel(path)})
    forbidden_cases = [
        r"case clipboard\s*(?:\n|$)",
        r"case translation\s*(?:\n|$)",
        r"selectedSection = \.clipboard\b",
        r"selectedSection = \.translation\b",
        r"section: \.clipboard\b",
        r"section: \.translation\b",
    ]
    combined = "\n".join(
        [
            app_section,
            content,
            app_model,
            blocks_app,
            translation_coordinator,
        ]
    )
    for pattern in forbidden_cases:
        if re.search(pattern, combined):
            failures.append({"code": "old_tool_route_still_present", "pattern": pattern})
    required = [
        "case clipboardSettings",
        "case translationSettings",
        "SettingsShellView(mode: appModel.selectedSection.settingsViewMode)",
        "openMainWindow(section: .clipboardSettings)",
        "openTranslationSettings(from:",
        "openMainWindow(.translationSettings, from:",
        "await Task.yield()",
        'Window(L10n.string("app.name"), id: "main")',
        "CommandGroup(replacing: .appSettings)",
    ]
    missing = [item for item in required if item not in combined]
    if missing:
        failures.append({"code": "missing_new_settings_routes", "detail": ", ".join(missing)})
    if "Settings {" in blocks_app or "WindowGroup" in blocks_app:
        failures.append({
            "code": "duplicate_settings_scene_present",
            "detail": "Blocks must expose one singleton main settings Window and no duplicate Settings or WindowGroup scene.",
        })
    print(json.dumps({
        "ok": not failures,
        "suite": "p7f_settings_menu_dedup",
        "failures": failures,
        "observations": {
            "checked_files": [
                rel(path)
                for path in [
                    APP_SECTION,
                    CONTENT,
                    APP_MODEL,
                    BLOCKS_APP,
                    TRANSLATION_COORDINATOR,
                    STEP4C_PRD,
                    STEP4C_RECORD,
                ]
            ],
            "current_evidence": {
                "prd": rel(STEP4C_PRD),
                "development_record": rel(STEP4C_RECORD),
            },
            "baseline_reference": {
                "legacy_sources_used_for_ok": False,
            },
        },
    }, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
