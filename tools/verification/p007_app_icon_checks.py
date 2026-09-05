#!/usr/bin/env python3
"""Verify the configured and compiled Blocks app icon."""

from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_ICON = ROOT / "apps/Blocks/BlocksApp/Resources/Assets.xcassets/AppIcon.appiconset"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
EXPECTED_FILES = {
    "icon_16x16.png",
    "icon_16x16@2x.png",
    "icon_32x32.png",
    "icon_32x32@2x.png",
    "icon_128x128.png",
    "icon_128x128@2x.png",
    "icon_256x256.png",
    "icon_256x256@2x.png",
    "icon_512x512.png",
    "icon_512x512@2x.png",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-bundle", type=Path)
    args = parser.parse_args()
    failures: list[dict[str, str]] = []

    contents = APP_ICON / "Contents.json"
    if not contents.exists():
        failures.append({"code": "app_icon_catalog_missing", "path": str(APP_ICON.relative_to(ROOT))})
    else:
        payload = json.loads(contents.read_text(encoding="utf-8"))
        referenced = {item.get("filename") for item in payload.get("images", []) if item.get("filename")}
        missing = sorted(EXPECTED_FILES - referenced)
        missing.extend(sorted(name for name in EXPECTED_FILES if not (APP_ICON / name).is_file()))
        if missing:
            failures.append({"code": "app_icon_sizes_missing", "detail": ", ".join(sorted(set(missing)))})

    project = PROJECT.read_text(encoding="utf-8")
    for token in [
        "Assets.xcassets in Resources",
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
    ]:
        if token not in project:
            failures.append({"code": "app_icon_project_configuration_missing", "detail": token})

    if args.app_bundle is not None:
        bundle = args.app_bundle
        resources = bundle / "Contents/Resources"
        plist_path = bundle / "Contents/Info.plist"
        for artifact in [resources / "Assets.car", resources / "AppIcon.icns", plist_path]:
            if not artifact.is_file():
                failures.append({"code": "compiled_app_icon_artifact_missing", "path": str(artifact)})
        if plist_path.is_file():
            with plist_path.open("rb") as handle:
                plist = plistlib.load(handle)
            if plist.get("CFBundleIconName") != "AppIcon" or plist.get("CFBundleIconFile") != "AppIcon":
                failures.append({"code": "compiled_app_icon_metadata_missing", "path": str(plist_path)})

    print(json.dumps({
        "gate": "P007-AppIcon",
        "status": "pass" if not failures else "fail",
        "failures": failures,
    }, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
