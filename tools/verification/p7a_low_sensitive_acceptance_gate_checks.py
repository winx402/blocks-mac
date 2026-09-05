#!/usr/bin/env python3
"""P7-A aggregate acceptance readiness gate for the current Blocks baseline.

The original P7-A story/board files were retired with the historical project
layout.  The executable entry point remains in aggregate verification, so it
now fails closed against the current translation project acceptance contract
instead of treating deleted historical documents as live facts.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PRD = ROOT / "docs" / "项目管理库" / "015_翻译工具完善" / "PRD与架构边界.md"
ACCEPTANCE = ROOT / "docs" / "项目管理库" / "015_翻译工具完善" / "实施与验收记录.md"
PROJECT_ENTRY = ROOT / "docs" / "项目管理库" / "015_翻译工具完善" / "index.md"
PROJECT_INDEX = ROOT / "docs" / "项目管理库" / "index.md"
APP_README = ROOT / "apps" / "Blocks" / "README.md"

REGRESSION_SCRIPTS = [
    "tools/verification/p6c_shortcut_acceptance_gate_checks.py",
    "tools/verification/p4k_clipboard_recorder_policy_checks.py",
    "tools/verification/p5q_translation_language_error_ux_checks.py",
    "tools/verification/p3f_screenshot_ai_route_ready_checks.py",
]


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


def forbidden_hits(content: str) -> list[str]:
    patterns = [
        r"sk-[A-Za-z0-9_-]{12,}",
        r"Authorization\s*:",
        r"Bearer\s+[A-Za-z0-9._~+/=-]{8,}",
        r"providerRawOutput",
        r"rawProviderOutput",
        r"BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY",
    ]
    hits: list[str] = []
    for pattern in patterns:
        if re.search(pattern, content):
            hits.append(pattern)
    return hits


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run(["./script/build_and_run.sh", "--verify"], args.timeout)
    require(build["ok"], "app_build_failed", build["stderr_tail"] or build["stdout_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    regression_results: dict[str, Any] = {}
    for script in REGRESSION_SCRIPTS:
        result = run(["python3", script, "--timeout", str(args.timeout)], args.timeout)
        regression_results[Path(script).name] = {"ok": result["ok"], "returncode": result["returncode"]}
        require(result["ok"], "regression_failed", f"{script}: {result['stdout_tail'] or result['stderr_tail']}", failures)
    observations["regressions"] = regression_results

    for path in [PRD, ACCEPTANCE, PROJECT_ENTRY, PROJECT_INDEX, APP_README]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    prd_text = text(PRD)
    acceptance_text = text(ACCEPTANCE)
    project_entry_text = text(PROJECT_ENTRY)
    combined_docs = "\n".join([prd_text, acceptance_text, project_entry_text])

    required_prd_terms = [
        "只通过 Accessibility",
        "截图翻译",
        "不写剪贴板",
        "不写截图历史",
        "0–4 个服务",
        "完成顺序不得改变卡片位置",
        ".blocksplugin",
        "独立 XPC",
        "不保留生产 Mock",
    ]
    missing_prd_terms = [term for term in required_prd_terms if term not in prd_text]
    require(not missing_prd_terms, "current_prd_missing_terms", ", ".join(missing_prd_terms), failures)

    required_acceptance_sections = [
        "## 当前事实",
        "## 已实现范围",
        "## 已确认并修复的实施偏差",
        "## 自动化证据",
        "## 尚未完成与阻断项",
        "## 验收原则",
    ]
    missing_sections = [section for section in required_acceptance_sections if section not in acceptance_text]
    require(not missing_sections, "acceptance_missing_sections", ", ".join(missing_sections), failures)

    required_acceptance_terms = [
        "状态：实施中",
        "自动化通过不替代",
        "待验证",
        "不能判定翻译工具完成",
        "不推进项目阶段",
    ]
    missing_acceptance_terms = [term for term in required_acceptance_terms if term not in acceptance_text]
    require(not missing_acceptance_terms, "acceptance_missing_terms", ", ".join(missing_acceptance_terms), failures)

    safety_hits = forbidden_hits(combined_docs)
    require(not safety_hits, "forbidden_sensitive_content", ", ".join(safety_hits), failures)

    project_index_text = text(PROJECT_INDEX)
    app_readme_text = text(APP_README)
    require(
        "015_翻译工具完善" in project_index_text
        and "实施与阻断项验证阶段" in project_index_text,
        "project_index_not_updated",
        "Current translation project status is missing from the project index",
        failures,
    )
    require(
        "状态：implementation-in-progress" in project_entry_text
        and "当前不标记完成、不推进项目阶段" in project_entry_text,
        "project_entry_overstates_completion",
        "Current project entry must retain its implementation and pending-acceptance state",
        failures,
    )
    require("p7a_low_sensitive_acceptance_gate_checks.py" in app_readme_text, "app_readme_not_updated", "P7-A verification command missing", failures)

    status_counts = {
        "implemented_items": acceptance_text.count("- "),
        "pending_acceptance": acceptance_text.count("待"),
        "blocking_items": acceptance_text.count("阻断"),
    }
    observations["acceptance_status_counts"] = status_counts
    observations["safety_scan"] = {"forbidden_hits": safety_hits}
    observations["superseded_by"] = "015_翻译工具完善 current acceptance contract"

    report = {
        "ok": not failures,
        "suite": "p7a_low_sensitive_acceptance_gate_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
