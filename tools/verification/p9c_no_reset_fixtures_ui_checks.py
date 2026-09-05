#!/usr/bin/env python3
from __future__ import annotations

import sys
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
RECORD_VIEW_FILES = [
    APP / "Views" / "ClipboardRecordViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordMenus.swift",
]

CURRENT_FILES = [
    APP / "App" / "AppModel.swift",
    APP / "Stores" / "ClipboardController.swift",
    APP / "Features" / "Clipboard" / "ClipboardStore.swift",
    *RECORD_VIEW_FILES,
    APP / "Views" / "ClipboardHistoryView.swift",
    APP / "Views" / "ClipboardFloatingPanelView.swift",
    APP / "Support" / "ClipboardRecordPreview.swift",
    APP / "Resources" / "Localizable.xcstrings",
]

DELETED_FILES = [
    APP / "Stores" / "AppState.swift",
    APP / "Views" / "ClipboardHistoryView.swift",
]

FORBIDDEN = [
    "resetClipboardFixtures",
    "clipboard.resetFixtures",
    "status.clipboardReset",
    "ClipboardController.defaultRecords",
    "ClipboardController.defaultPayloads",
    "ClipboardController.defaultPinnedMetadata",
    "ClipboardRecorderFixture.payloads()[id]",
    "Reset low-sensitive fixtures",
    "fixtures reset",
    "Fixture 已重置",
]


def main() -> int:
    failures: list[str] = []
    checked: list[str] = []

    for path in DELETED_FILES:
        if path.exists():
            failures.append(f"{path.relative_to(ROOT)} should be deleted in Step 5")

    for path in CURRENT_FILES:
        if path in DELETED_FILES and not path.exists():
            continue
        if not path.exists():
            failures.append(f"{path.relative_to(ROOT)} missing")
            continue
        checked.append(str(path.relative_to(ROOT)))
        source = path.read_text(encoding="utf-8")
        for needle in FORBIDDEN:
            if needle in source:
                failures.append(f"{path.relative_to(ROOT)} contains {needle}")

    output = {
        "ok": not failures,
        "suite": "p9c_no_reset_fixtures_ui_checks",
        "checked": checked,
        "deleted_required": [str(path.relative_to(ROOT)) for path in DELETED_FILES],
        "baseline_reference": {"old_appstate_source_used_for_ok": False},
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
