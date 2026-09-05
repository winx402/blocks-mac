#!/usr/bin/env python3
"""P7-S Alpha readiness final gate."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = ROOT / "docs/项目管理库/000_归档/2026-07-05_项目视图改造前"
P7P = ROOT / "tools/verification/p7p_alpha_readiness_closure_checks.py"
P7Q = ROOT / "tools/verification/p7q_screenshot_window_fullscreen_checks.py"
P7R = ROOT / "tools/verification/p7r_permission_assist_ux_checks.py"
P7S_RECORD = ARCHIVE / "实施记录/acceptance/p7-s-alpha-readiness-final-record.md"
P7S_STORY = ARCHIVE / "实施记录/stories/p7-s-alpha-readiness-final.md"
P7P_RECORD = ARCHIVE / "实施记录/acceptance/p7-p-alpha-readiness-closure-record.md"
README = ROOT / "README.md"
APP_README = ROOT / "apps/Blocks/README.md"
DOC_INDEX = ROOT / "docs/index.md"
PROJECT_INDEX = ROOT / "docs/项目管理库/index.md"
PROJECT_OVERVIEW = ARCHIVE / "项目总览.md"
BOARD = ARCHIVE / "项目进度看板.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    return {
        "command": command,
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": completed.stdout[-1800:],
        "stderr_tail": completed.stderr[-1800:],
    }


def main() -> int:
    timeout = 180
    if "--timeout" in sys.argv:
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1])

    subchecks = {
        "p7p": run(["python3", str(P7P), "--timeout", str(timeout)], timeout),
        "p7q": run(["python3", str(P7Q), "--timeout", str(timeout)], timeout),
        "p7r": run(["python3", str(P7R), "--timeout", str(timeout)], timeout),
    }

    p7s_record = read(P7S_RECORD)
    p7s_story = read(P7S_STORY)
    p7p_record = read(P7P_RECORD)
    public_docs = "\n".join([
        read(README),
        read(APP_README),
        read(DOC_INDEX),
        read(PROJECT_INDEX),
        read(PROJECT_OVERVIEW),
        read(BOARD),
    ])

    stale_phrases = [
        "Screenshot Window / Fullscreen UI 点击、多屏和权限撤销/重授权仍需单独验收",
        "Window / Fullscreen remain explicit P7-P manual UI checks until clicked",
        "Screenshot Window UI 点击验收 | `not_covered_this_pass`",
        "Screenshot Fullscreen UI 点击验收 | `not_covered_this_pass`",
        "Window / Fullscreen UI 点击验收和环境依赖项记录",
    ]
    stale_hits = [phrase for phrase in stale_phrases if phrase in public_docs or phrase in p7p_record]

    checks = {
        "subchecks_passed": all(item["ok"] for item in subchecks.values()),
        "p7s_record_core_closed": "Screenshot Region / Window / Fullscreen" in p7s_record
        and "Permission Assist granted close condition" in p7s_record
        and "Control + Option + A/V/D" in p7s_record,
        "p7s_record_keeps_deferred_items": "Permission Assist revoked-flow" in p7s_record
        and "Multi-display screenshot" in p7s_record
        and "Packaging/notarization" in p7s_record,
        "p7s_story_next_stage": "P8-A" in p7s_story
        and "Alpha Packaging / Tester Readiness" in p7s_story,
        "public_docs_link_p7qrs": "P7-Q" in public_docs
        and "P7-R" in public_docs
        and "P7-S" in public_docs,
        "public_docs_updated_to_window_fullscreen_passed": "Window / Fullscreen UI 点击验收仍需" not in public_docs
        and "Window / Fullscreen UI 点击、多屏和权限撤销/重授权仍需单独验收" not in public_docs,
        "p7p_record_not_stale": "P7-Q" in p7p_record
        and "closed_by_p7q" in p7p_record,
        "no_stale_hits": not stale_hits,
    }

    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7s_alpha_readiness_final_checks",
        "checks": checks,
        "subchecks": subchecks,
        "stale_hits": stale_hits,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
