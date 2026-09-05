#!/usr/bin/env python3
"""P4-C clipboard interaction checks for Blocks."""

from __future__ import annotations

from retired_p4_step5_cleanup_guard import main as _step5_retired_main

if __name__ == "__main__":
    raise SystemExit(_step5_retired_main(__file__))


import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardRecorderFoundation.swift"
APP_STATE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Stores" / "AppState.swift"
PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardHistoryView.swift"


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-1200:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p4b = run(["python3", "tools/verification/p4b_clipboard_panel_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p4b["ok"], "p4b_regression_failed", p4b["stdout"] or p4b["stderr_tail"], failures)
    observations["p4b_regression"] = p4b["ok"]

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "clipboard.pinAction",
        "clipboard.unpinAction",
        "clipboard.deleteHistoryItem",
        "clipboard.statsPinned",
        "clipboard.statsRestorable",
        "clipboard.statsExcluded",
        "status.clipboardPinned.title",
        "status.clipboardUnpinned.title",
        "status.clipboardRemoved.title",
    ]
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in ["zh-Hans", "en", "ja"])
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    core_text = CORE.read_text(encoding="utf-8")
    app_state_text = APP_STATE.read_text(encoding="utf-8")
    panel_text = PANEL.read_text(encoding="utf-8")

    require("func replacing(" in core_text, "record_replace_missing", "Clipboard record needs immutable replacement helper", failures)
    required_state_methods = [
        "toggleClipboardPin(recordID:",
        "deleteClipboardHistoryItem(recordID:",
        "clipboardPinnedCount",
        "clipboardRestorableCount",
        "clipboardExcludedCount",
    ]
    missing_state_methods = [needle for needle in required_state_methods if needle not in app_state_text]
    require(not missing_state_methods, "state_methods_missing", ", ".join(missing_state_methods), failures)

    required_panel_hooks = [
        "appState.toggleClipboardPin(recordID: record.id)",
        "appState.deleteClipboardHistoryItem(recordID: record.id)",
        "statsRow",
    ]
    missing_panel_hooks = [needle for needle in required_panel_hooks if needle not in panel_text]
    require(not missing_panel_hooks, "panel_hooks_missing", ", ".join(missing_panel_hooks), failures)

    forbidden_runtime_reads = ["NSPasteboard", "URLSession", "Process("]
    forbidden_hits = [needle for needle in forbidden_runtime_reads if needle in panel_text]
    require(not forbidden_hits, "unexpected_runtime_access", ", ".join(forbidden_hits), failures)
    forbidden_reset = ["resetClipboardFixtures", "clipboard.resetFixtures", "status.clipboardReset"]
    reset_hits = [needle for needle in forbidden_reset if needle in f"{app_state_text}\n{panel_text}\n{json.dumps(localizable)}"]
    require(not reset_hits, "reset_fixtures_still_present", ", ".join(reset_hits), failures)
    observations["interaction_coverage"] = {
        "has_record_replace": "func replacing(" in core_text,
        "missing_state_methods": missing_state_methods,
        "missing_panel_hooks": missing_panel_hooks,
        "forbidden_runtime_hits": forbidden_hits,
    }

    output = {
        "ok": not failures,
        "suite": "p4c_clipboard_interactions_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
