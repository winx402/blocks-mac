#!/usr/bin/env python3
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
P7E = ROOT / "docs/项目管理库/实施记录/stories/p7-e-settings-clipboard-translation-permission-deep-polish.md"
P7F = ROOT / "docs/项目管理库/实施记录/stories/p7-f-settings-permission-regression-fix.md"
P7G = ROOT / "docs/项目管理库/实施记录/stories/p7-g-permission-settings-interaction-rework.md"


def main() -> int:
    p7e = P7E.read_text(encoding="utf-8")
    p7f = P7F.read_text(encoding="utf-8")
    p7g = P7G.read_text(encoding="utf-8")
    required_p7f = [
        "P7-F-01",
        "P7-F-02",
        "P7-F-03",
        "research / plan / dev / test / close",
        "P7-G",
        "p7f_settings_menu_dedup_checks.py",
        "p7f_permission_state_refresh_checks.py",
        "p7f_permission_assist_position_drag_checks.py",
        "p7f_clipboard_autopaste_permission_retry_checks.py",
    ]
    required_p7g = [
        "pending low-sensitive manual acceptance",
        "P7-G-01",
        "P7-G-02",
        "P7-G-03",
        "P7-G-04",
        "P7-G-05",
        "p7g_permission_settings_interaction_checks.py",
    ]
    required_p7e = [
        "partially superseded by P7-F",
        "reopened_by_p7f",
        "p7-f-settings-permission-regression-fix.md",
    ]
    missing = [item for item in required_p7f if item not in p7f]
    missing += [f"P7E:{item}" for item in required_p7e if item not in p7e]
    missing += [f"P7G:{item}" for item in required_p7g if item not in p7g]
    ok = not missing
    print(json.dumps({
        "ok": ok,
        "check": "p7f_issue_ledger_reopen",
        "missing": missing,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
