#!/usr/bin/env python3
"""P4-K clipboard recorder policy foundation checks for Blocks."""

from __future__ import annotations

from retired_p4_step5_cleanup_guard import main as _step5_retired_main

if __name__ == "__main__":
    raise SystemExit(_step5_retired_main(__file__))


import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
SETTINGS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "SettingsView.swift"
CLIPBOARD_VIEW = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardHistoryView.swift"
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardFloatingPanelView.swift"
STORY = ROOT / "docs" / "项目管理库" / "实施记录" / "stories" / "p4-k-clipboard-recorder-policy-foundation.md"

LANGUAGES = ["zh-Hans", "en", "ja"]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=False)
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
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

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p4j = run(["python3", "tools/verification/p4j_clipboard_panel_deepening_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p4j["ok"], "p4j_regression_failed", p4j["stdout"] or p4j["stderr_tail"], failures)
    observations["p4j_regression"] = p4j["ok"]

    for path in [APP_STATE, SETTINGS, CLIPBOARD_VIEW, PANEL, STORY]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    combined = "\n".join(text(path) for path in [APP_STATE, SETTINGS, CLIPBOARD_VIEW, PANEL])
    required_symbols = [
        "clipboard.policy.retentionDays",
        "clipboard.policy.maxItems",
        "clipboard.policy.preservePinned",
        "clipboard.policy.excludedBundleIDs",
        "applyClipboardPolicy",
        "clearUnpinnedClipboardSummaries",
        "clipboardPolicySummary",
        "clipboard.policy.apply",
        "clipboard.policy.clearUnpinned",
        "settings.clipboardPolicy",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(not missing_symbols, "missing_symbols", ", ".join(missing_symbols), failures)

    forbidden = ["URLSession", "Process(", "getenv(", "SecItem", "Authorization", "Bearer", "NSPasteboard.general"]
    policy_sources = "\n".join(text(path) for path in [SETTINGS, CLIPBOARD_VIEW, PANEL])
    forbidden_hits = [needle for needle in forbidden if needle in policy_sources]
    require(not forbidden_hits, "forbidden_clipboard_policy_runtime", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {"forbidden_hits": forbidden_hits}

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.clipboardPolicy",
        "settings.clipboardPolicyNote",
        "settings.clipboardPolicyRetentionDays",
        "settings.clipboardPolicyMaxItems",
        "settings.clipboardPolicyPreservePinned",
        "settings.clipboardPolicyExcludedBundleIDs",
        "clipboard.policy.title",
        "clipboard.policy.apply",
        "clipboard.policy.clearUnpinned",
        "clipboard.policy.summary",
        "status.clipboardPolicyApplied.title",
        "status.clipboardUnpinnedCleared.title",
    ]
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localizable.get("strings", {}).get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [lang for lang in LANGUAGES if lang not in entry.get("localizations", {})]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(not missing_l10n, "missing_localization", ", ".join(missing_l10n), failures)

    story_text = text(STORY)
    required_story_terms = ["P4-K", "retention", "max items", "pinned", "excluded bundle", "不读取真实剪贴板原文"]
    missing_story_terms = [term for term in required_story_terms if term not in story_text]
    require(not missing_story_terms, "story_missing_terms", ", ".join(missing_story_terms), failures)

    report = {
        "ok": not failures,
        "suite": "p4k_clipboard_recorder_policy_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
