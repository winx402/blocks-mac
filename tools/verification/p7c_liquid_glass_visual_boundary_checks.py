#!/usr/bin/env python3
"""P7-C Liquid Glass visual boundary checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
GLASS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Support" / "GlassPanel.swift"
CONTENT = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ContentView.swift"
SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "SettingsView.swift"
SETTINGS_SHELL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "SettingsShellView.swift"
SETTINGS_SECTIONS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Settings" / "SettingsSectionList.swift"
CLIPBOARD = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift"
TRANSLATION = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "TranslationFloatingPanelView.swift"
APP_ROOT = ROOT / "apps" / "Blocks" / "BlocksApp"


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": completed.stdout[-2400:],
        "stderr_tail": completed.stderr[-2400:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    glass = text(GLASS)
    combined_ui = "\n".join(
        text(path)
        for path in [CONTENT, SETTINGS, SETTINGS_SHELL, SETTINGS_SECTIONS, CLIPBOARD, TRANSLATION]
    )
    all_app_ui = "\n".join(text(path) for path in APP_ROOT.rglob("*.swift"))

    required_symbols = [
        "BlocksVisualTokens",
        "BlocksSurfaceRole",
        "BlocksAppKitGlassSurfaceView",
        "BlocksWindowGlassConfigurator",
        "accessibilityReduceTransparency",
        "GlassEffectContainer",
        "NSGlassEffectView",
        "NSGlassEffectContainerView",
        "Glass.regular.tint",
        "glassTintColor",
        ".interactive()",
        "appKitMaterial",
        "blocksSurface",
        "blocksBackground",
        "BlocksMotionRole",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in glass]
    require(not missing_symbols, "missing_glass_symbols", ", ".join(missing_symbols), failures)
    scattered_materials = [
        token
        for token in [
            ".background(.regularMaterial",
            ".background(.thinMaterial",
            ".background(.ultraThinMaterial",
        ]
        if token in all_app_ui
    ]
    require(not scattered_materials, "material_still_scattered", ", ".join(scattered_materials), failures)
    retired_symbols = [
        "struct GlassPanel",
        "GlassPanelStyle",
        "func glassPanel(",
        "func glassSurface(",
        "func glassContainerBackground(",
        "BlocksVisualEffectSurfaceView",
    ]
    remaining_retired = [symbol for symbol in retired_symbols if symbol in all_app_ui]
    require(not remaining_retired, "retired_glass_compatibility_remaining", ", ".join(remaining_retired), failures)
    require(".background(Color.white" not in combined_ui and ".background(.white" not in combined_ui, "opaque_background_found", "P7-C UI must not add opaque white backgrounds.", failures)

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"] or build["stdout_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    report = {
        "ok": not failures,
        "suite": "p7c_liquid_glass_visual_boundary_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
