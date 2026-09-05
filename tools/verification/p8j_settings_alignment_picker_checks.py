#!/usr/bin/env python3
"""P8-J current settings layout-token and adaptive-value-column checks."""

from __future__ import annotations

import argparse
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
SECTION_LIST = APP / "Features" / "Settings" / "SettingsSectionList.swift"
SHELL = APP / "Features" / "Settings" / "SettingsShellView.swift"
TOKENS = APP / "Support" / "DesignSystemFoundation.swift"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.parse_args(argv)
    section_list, shell, tokens = (read(path) for path in [SECTION_LIST, SHELL, TOKENS])
    failures: list[str] = []

    for token in [
        "settingsFormContentMaxWidth: CGFloat = 820",
        "settingsCollectionContentMaxWidth: CGFloat = 1120",
        "settingsSheetContentMaxWidth: CGFloat = 640",
        "settingsTrailingColumnMinimumWidth: CGFloat = 220",
        "settingsTrailingColumnWidth: CGFloat = 280",
        "settingsTrailingColumnMaximumWidth: CGFloat = 360",
    ]:
        require(token in tokens, f"Missing current settings layout token: {token}", failures)
    require(all(token in section_list for token in ["case form", "case content", "case sheet"]),
            "SettingsContentLayoutProfile must retain form/content/sheet profiles.", failures)
    require("mode.layoutProfile.maximumWidth" in shell,
            "Settings shell must select width through mode.layoutProfile.", failures)
    require("case .translationFavorites, .hooks:" in shell and ".content" in shell,
            "Content routes must opt into the content profile.", failures)
    require(all(token in section_list for token in [
        "minWidth: SettingsLayout.trailingColumnMinimumWidth",
        "idealWidth: SettingsLayout.trailingColumnWidth",
        "maxWidth: SettingsLayout.trailingColumnMaximumWidth",
    ]), "SettingsValueColumn must retain its 220/280/360 adaptive contract.", failures)
    require("contentMaxWidth: CGFloat = 760" not in section_list,
            "Legacy 760pt settings width must not return.", failures)
    require("ProviderReadinessRow" not in section_list + shell,
            "P8-J must not depend on ProviderReadinessRow.", failures)

    if failures:
        print("P8-J checks failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("P8-J checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
