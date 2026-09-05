#!/usr/bin/env python3
"""P14-A screenshot core target and platform-boundary checks."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksScreenshotCore"
TESTS = ROOT / "apps/Blocks/BlocksScreenshotCoreTests"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
SCHEME = ROOT / "apps/Blocks/Blocks.xcodeproj/xcshareddata/xcschemes/BlocksScreenshotCoreTests.xcscheme"
APP_TEST = ROOT / "apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift"
APP_TEST_SCHEME = ROOT / "apps/Blocks/Blocks.xcodeproj/xcshareddata/xcschemes/BlocksAppTests.xcscheme"

REQUIRED_CORE_FILES = [
    CORE / "ScreenshotCaptureContracts.swift",
    CORE / "ScreenshotSelectionReducer.swift",
    CORE / "ScreenshotCapturePlan.swift",
    CORE / "ScreenshotDocument.swift",
    CORE / "ScreenshotGeometry.swift",
    CORE / "ScreenshotRenderer.swift",
    CORE / "ScreenshotPreferences.swift",
]
REQUIRED_TEST_FILES = [
    TESTS / "ScreenshotSelectionReducerTests.swift",
    TESTS / "ScreenshotCapturePlanTests.swift",
    TESTS / "ScreenshotDocumentTests.swift",
    TESTS / "ScreenshotGeometryTests.swift",
    TESTS / "ScreenshotRendererTests.swift",
    TESTS / "ScreenshotPreferencesTests.swift",
]
FORBIDDEN_IMPORTS = {
    "AppKit",
    "SwiftUI",
    "ScreenCaptureKit",
}
FORBIDDEN_SYMBOLS = {
    "UserDefaults",
    "NSPasteboard",
    "NSWindow",
    "NSView",
    "SCWindow",
    "SCDisplay",
}


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    failures: list[dict[str, str]] = []
    observations: dict[str, object] = {}

    for path in [*REQUIRED_CORE_FILES, *REQUIRED_TEST_FILES, PROJECT, SCHEME, APP_TEST, APP_TEST_SCHEME]:
        if not path.exists():
            failures.append({"code": "missing_file", "path": rel(path)})

    core_sources = {path: source(path) for path in CORE.glob("*.swift")}
    for path, content in core_sources.items():
        imports = set(re.findall(r"^import\s+(\w+)", content, flags=re.MULTILINE))
        forbidden_imports = sorted(imports & FORBIDDEN_IMPORTS)
        if forbidden_imports:
            failures.append({
                "code": "platform_ui_import_in_core",
                "path": rel(path),
                "detail": ", ".join(forbidden_imports),
            })
        forbidden_symbols = sorted(symbol for symbol in FORBIDDEN_SYMBOLS if symbol in content)
        if forbidden_symbols:
            failures.append({
                "code": "platform_symbol_in_core",
                "path": rel(path),
                "detail": ", ".join(forbidden_symbols),
            })

    project = source(PROJECT)
    required_project_tokens = [
        "BlocksScreenshotCore.framework",
        "BlocksScreenshotCoreTests.xctest",
        "BlocksAppTests.xctest",
        "ScreenshotAppStateTests.swift in Sources",
        "ScreenshotCaptureContracts.swift in Sources",
        "ScreenshotSelectionReducer.swift in Sources",
        "ScreenshotCapturePlan.swift in Sources",
        "ScreenshotDocument.swift in Sources",
        "ScreenshotGeometry.swift in Sources",
        "ScreenshotRenderer.swift in Sources",
        "ScreenshotPreferences.swift in Sources",
        "ScreenshotSelectionReducerTests.swift in Sources",
        "ScreenshotCapturePlanTests.swift in Sources",
        "ScreenshotDocumentTests.swift in Sources",
        "ScreenshotGeometryTests.swift in Sources",
        "ScreenshotRendererTests.swift in Sources",
        "ScreenshotPreferencesTests.swift in Sources",
        'productType = "com.apple.product-type.framework";',
        'productType = "com.apple.product-type.bundle.unit-test";',
    ]
    missing_project_tokens = [token for token in required_project_tokens if token not in project]
    if missing_project_tokens:
        failures.append({
            "code": "xcode_target_membership_missing",
            "path": rel(PROJECT),
            "detail": ", ".join(missing_project_tokens),
        })

    combined_core = "\n".join(core_sources.values())
    required_contracts = [
        "enum ScreenshotCaptureIntentKind",
        "enum ScreenshotDisplayScope",
        "struct ScreenshotSelectionReducer",
        "struct ScreenshotCapturePlanner",
        "final class ScreenshotSceneDocument",
        "struct ScreenshotSourceContext",
        "enum ScreenshotElementGeometry",
        "enum ScreenshotGeometry",
        "struct ScreenshotRenderer",
        "struct ScreenshotPreferences",
        "maximumDimension = 32_768",
        "maximumPixelCount = 120_000_000",
    ]
    missing_contracts = [token for token in required_contracts if token not in combined_core]
    if missing_contracts:
        failures.append({
            "code": "screenshot_core_contract_missing",
            "path": rel(CORE),
            "detail": ", ".join(missing_contracts),
        })

    legacy_contracts = [
        "enum ScreenshotEditCommand",
        "final class ScreenshotDocument",
        "enum ScreenshotEditorLayout",
    ]
    present_legacy_contracts = [token for token in legacy_contracts if token in combined_core]
    if present_legacy_contracts:
        failures.append({
            "code": "legacy_screenshot_core_contract_present",
            "path": rel(CORE),
            "detail": ", ".join(present_legacy_contracts),
        })

    observations["core_file_count"] = len(core_sources)
    observations["test_file_count"] = len(list(TESTS.glob("*.swift")))
    observations["app_test_target"] = APP_TEST.exists() and APP_TEST_SCHEME.exists()
    observations["forbidden_imports"] = sorted(FORBIDDEN_IMPORTS)

    payload = {
        "gate": "P14-A",
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
