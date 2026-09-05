#!/usr/bin/env python3
"""Shared retirement guard for pre-Step-5 clipboard/helper P4 verifiers."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks"
APP_CODE = APP / "BlocksApp"

DELETED_PATHS = [
    APP / "BlocksLoginItemHelper",
    APP_CODE / "Views" / "ClipboardHistoryView.swift",
    APP_CODE / "Services" / "ClipboardRecorderRuntimeService.swift",
]

PROJECT = APP / "Blocks.xcodeproj" / "project.pbxproj"
FORBIDDEN_PROJECT_TOKENS = [
    "BlocksLoginItemHelper",
    "Embed LoginItems",
    "ClipboardRecorderRuntimeService.swift",
    "ClipboardHistoryView.swift",
]


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def main(retired_suite: str) -> int:
    failures: list[dict[str, str]] = []
    for path in DELETED_PATHS:
        if path.exists():
            failures.append({"code": "retired_path_still_present", "detail": rel(path)})

    project = PROJECT.read_text(encoding="utf-8") if PROJECT.exists() else ""
    for token in FORBIDDEN_PROJECT_TOKENS:
        if token in project:
            failures.append({"code": "retired_project_token_still_present", "detail": token})

    output = {
        "ok": not failures,
        "suite": retired_suite,
        "retired_by": "Step 5 cleanup",
        "replacement_gates": [
            "p8_clipboard_product_polish_checks.py",
            "p8i_settings_clipboard_system_checks.py",
            "p9a_clipboard_repository_storage_smoke.py",
            "p9b_clipboard_appstate_repository_integration_checks.py",
            "p9c_no_reset_fixtures_ui_checks.py",
            "p11e_clipboard_hardening_checks.py",
            "p12_step5_cleanup_checks.py",
        ],
        "baseline_reference": {"old_helper_debug_targets_used_for_ok": False},
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1
