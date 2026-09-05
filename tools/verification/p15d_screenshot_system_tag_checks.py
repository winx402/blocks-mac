#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


tag_model = read("apps/Blocks/BlocksCore/ClipboardTag.swift")
tag_repository = read("apps/Blocks/BlocksCore/ClipboardTagRepository.swift")
migration = read("apps/Blocks/BlocksCore/AppDatabase.swift")
tests = read("apps/Blocks/BlocksAppTests/ClipboardScreenshotHistoryRepositoryTests.swift")
filter_chips = read("apps/Blocks/BlocksApp/Features/Clipboard/Filters/ClipboardTagFilterChips.swift")
tag_settings = read("apps/Blocks/BlocksApp/Features/Settings/ClipboardTagManagementSection.swift")
record_menus = read("apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordMenus.swift")
localizations = read("apps/Blocks/BlocksApp/Resources/Localizable.xcstrings")

required = {
    "built_in_kind": (tag_model, ["case screenshot", "isScreenshot", "reservedScreenshotAliases"]),
    "capability_guards": (
        tag_repository,
        [
            "reorderableTag",
            "builtInImmutable",
            "systemMembershipImmutable",
            "attachScreenshotTag",
            "setScreenshotTagEnabled",
            "is_enabled",
        ],
    ),
    "stable_migration": (
        migration,
        ["tag.screenshot", "idx_clipboard_tags_builtin_screenshot", "Screenshot (Custom)", "截图（自定义）"],
    ),
    "behavior_tests": (
        tests,
        [
            "testScreenshotTagCanReorderButRejectsEditingAndPublicMembership",
            "testScreenshotAliasesAreReserved",
            "testScreenshotTagCanBeHiddenWithoutDeletingOriginsAndReenableDerivesAllHistory",
        ],
    ),
    "filter_system_tag_identity": (
        filter_chips,
        ["camera.fill", "tag.localizedDisplayName", "tag.builtInSystemImage"],
    ),
    "filter_system_tag_actions": (
        filter_chips,
        [
            "if !tag.isBuiltIn",
            "moveFilterTagUp(tag)",
            "moveFilterTagDown(tag)",
            ".contentShape(Rectangle())",
            ".simultaneousGesture(localTagDragGesture(tag: tag))",
        ],
    ),
    "settings_system_tag_identity": (
        tag_settings,
        ["tag.localizedDisplayName", "tag.builtInSystemImage", "settings.clipboardTagsScreenshotDetail"],
    ),
    "settings_system_tag_actions": (
        tag_settings,
        [
            "if !tag.isBuiltIn",
            "!tag.isBuiltIn, isEditing",
            "tag.isBuiltIn",
            "Button(action: openScreenshotSettings)",
            "clipboard.tags.screenshot.openSettings",
        ],
    ),
    "record_menu_excludes_system_tags": (
        record_menus,
        ["filter { !$0.isBuiltIn }", "tag.localizedDisplayName", "tag.builtInSystemImage", "tag.displayColor"],
    ),
    "system_tag_localization": (
        localizations,
        ["clipboard.tags.screenshot", "settings.clipboardTagsScreenshotDetail", '"en"', '"ja"', '"zh-Hans"'],
    ),
}

failures = []
for name, (source, markers) in required.items():
    missing = [marker for marker in markers if marker not in source]
    if missing:
        failures.append({"check": name, "missing": missing})

print(json.dumps({
    "gate": "P15-D",
    "status": "fail" if failures else "pass",
    "failures": failures,
    "observations": {"ui_checks": "static filter/settings/localization coverage"},
}, ensure_ascii=False, indent=2))
raise SystemExit(1 if failures else 0)
