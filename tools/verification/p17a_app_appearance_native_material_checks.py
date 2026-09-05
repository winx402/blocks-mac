#!/usr/bin/env python3
"""P17-A global appearance and native material static checks for Blocks."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "apps" / "Blocks" / "BlocksApp"
APPEARANCE = APP_ROOT / "Support" / "AppAppearance.swift"
DESIGN_FOUNDATION = APP_ROOT / "Support" / "DesignSystemFoundation.swift"
GLASS = APP_ROOT / "Support" / "GlassPanel.swift"
APP = APP_ROOT / "App" / "BlocksApp.swift"
GENERAL = APP_ROOT / "Features" / "Settings" / "GeneralSettingsPane.swift"
SETTINGS_SECTIONS = APP_ROOT / "Features" / "Settings" / "SettingsSectionList.swift"
CONTENT = APP_ROOT / "Views" / "ContentView.swift"
LOCALIZATION = APP_ROOT / "Resources" / "Localizable.xcstrings"
SELECTION = APP_ROOT / "Features" / "Screenshot" / "Capture" / "ScreenshotSelectionController.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    failures: list[dict[str, str]] = []
    appearance = read(APPEARANCE)
    design_foundation = read(DESIGN_FOUNDATION)
    glass = read(GLASS)
    app = read(APP)
    general = read(GENERAL)
    settings_sections = read(SETTINGS_SECTIONS)
    content = read(CONTENT)
    localization = read(LOCALIZATION)
    selection = read(SELECTION)
    production = "\n".join(read(path) for path in APP_ROOT.rglob("*.swift"))

    for symbol in [
        "enum AppAppearancePreference",
        "case system",
        "case light",
        "case dark",
        'static let defaultsKey = "app.appearance"',
        "final class AppAppearanceStore",
        "NSApplication.shared.appearance = appearance",
        "NSAppearance.init(named:)",
    ]:
        require(symbol in appearance, "missing_appearance_contract", symbol, failures)

    require("@StateObject private var appearanceStore" in app, "appearance_store_not_owned_by_app", str(APP), failures)
    require(".environmentObject(appearanceStore)" in app, "appearance_store_not_injected", str(APP), failures)
    require("AppAppearancePreference.allCases" in general, "appearance_picker_missing", str(GENERAL), failures)
    require(".pickerStyle(.segmented)" in general, "segmented_picker_missing", str(GENERAL), failures)

    for symbol in [
        "enum BlocksVisualTokens",
        "minimumHitTarget: CGFloat = 36",
        "static let control: CGFloat = 8",
        "static let section: CGFloat = 12",
    ]:
        require(symbol in design_foundation, "missing_design_foundation_contract", symbol, failures)

    for symbol in [
        "enum BlocksSurfaceRole",
        "enum BlocksSurfaceRenderingMode",
        "func renderingMode(",
        "func blocksSurface(",
        "func blocksBackground(",
        "GlassEffectContainer",
        "NSVisualEffectView",
        "accessibilityReduceTransparency",
    ]:
        require(symbol in glass, "missing_visual_system_contract", symbol, failures)

    surface_role_match = re.search(
        r"enum\s+BlocksSurfaceRole\s*:\s*CaseIterable\s*\{(?P<body>.*?)\n\s*var\s+layer",
        glass,
        re.DOTALL,
    )
    actual_surface_roles = (
        re.findall(r"\bcase\s+([A-Za-z][A-Za-z0-9_]*)", surface_role_match.group("body"))
        if surface_role_match
        else []
    )
    expected_surface_roles = [
        "window",
        "sidebar",
        "content",
        "section",
        "panel",
        "popover",
        "interactive",
        "hud",
    ]
    require(
        actual_surface_roles == expected_surface_roles,
        "surface_role_set_out_of_date",
        f"expected {expected_surface_roles}, found {actual_surface_roles}",
        failures,
    )
    legacy_surface_role_aliases = [
        alias
        for alias in ["settingsSection", "floatingPanel"]
        if re.search(rf"\bcase\s+{alias}\b", glass)
    ]
    require(
        not legacy_surface_role_aliases,
        "legacy_surface_role_alias_restored",
        ", ".join(legacy_surface_role_aliases),
        failures,
    )

    require(".blocksSurface(" in settings_sections, "settings_surface_not_centralized", str(SETTINGS_SECTIONS), failures)
    require(".quaternary.opacity(0.36)" not in settings_sections, "legacy_settings_fill_remaining", str(SETTINGS_SECTIONS), failures)
    require(".blocksBackground(.sidebar)" in content, "semantic_sidebar_material_missing", str(CONTENT), failures)

    forbidden_runtime_tokens = [
        "-AppleInterfaceStyle",
        "NSRequiresAquaSystemAppearance",
        'setValue("Dark", forKey: "AppleInterfaceStyle")',
        'set("Dark", forKey: "AppleInterfaceStyle")',
    ]
    forbidden_hits = [token for token in forbidden_runtime_tokens if token in production]
    require(not forbidden_hits, "forbidden_global_appearance_override", ", ".join(forbidden_hits), failures)

    scattered_materials = [
        token
        for token in [
            ".background(.regularMaterial",
            ".background(.thinMaterial",
            ".background(.ultraThinMaterial",
            ".background(Color(nsColor: .controlBackgroundColor)",
        ]
        if token in production
    ]
    require(not scattered_materials, "scattered_structural_material", ", ".join(scattered_materials), failures)

    direct_appkit_materials = [
        str(path.relative_to(ROOT))
        for path in APP_ROOT.rglob("*.swift")
        if path != GLASS and (".material =" in read(path) or ".blendingMode =" in read(path))
    ]
    require(
        not direct_appkit_materials,
        "appkit_material_bypasses_surface_role",
        ", ".join(direct_appkit_materials),
        failures,
    )

    require("glassEffect" not in selection, "selection_overlay_must_remain_clear", str(SELECTION), failures)

    localization_keys = [
        "settings.appearance.title",
        "settings.appearance.picker",
        "settings.appearance.detail",
        "settings.appearance.system",
        "settings.appearance.light",
        "settings.appearance.dark",
    ]
    missing_localization = [key for key in localization_keys if f'"{key}"' not in localization]
    require(not missing_localization, "appearance_localization_missing", ", ".join(missing_localization), failures)
    for language in ['"en"', '"ja"', '"zh-Hans"']:
        require(localization.count(language) >= len(localization_keys), "language_catalog_missing", language, failures)

    report = {
        "ok": not failures,
        "suite": "p17a_app_appearance_native_material_checks",
        "failures": failures,
        "observations": {
            "preference_key": "app.appearance",
            "default": "system",
            "surface_roles": [
                "window",
                "sidebar",
                "content",
                "section",
                "panel",
                "popover",
                "interactive",
                "hud",
            ],
            "global_system_preferences_written": False,
        },
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
