#!/usr/bin/env python3
"""Compatibility gate for the P14 screenshot breaking replacement."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
VERIFICATION = ROOT / "tools" / "verification"
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
SCREENSHOT_CORE = ROOT / "apps" / "Blocks" / "BlocksScreenshotCore"
ACTION_BROKER = ROOT / "apps" / "Blocks" / "BlocksActionBroker"
CLI = ROOT / "apps" / "Blocks" / "BlocksCLI" / "main.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"

P14_GATES = {
    "P14-A": VERIFICATION / "p14a_screenshot_core_architecture_checks.py",
    "P14-B": VERIFICATION / "p14b_screenshot_unified_capture_checks.py",
    "P14-C": VERIFICATION / "p14c_screenshot_editor_checks.py",
    "P14-D": VERIFICATION / "p14d_screenshot_settings_output_checks.py",
    "P14-E": VERIFICATION / "p14e_screenshot_action_cli_contract_checks.py",
    "P14-F": VERIFICATION / "p14f_action_broker_platform_checks.py",
    "P14-G": VERIFICATION / "p14g_screenshot_app_tests.py",
}

LEGACY_FILES = [
    APP / "Services" / "RegionSelectionController.swift",
    APP / "Services" / "WindowSelectionController.swift",
    APP / "Services" / "ScreenshotCaptureService.swift",
    APP / "Services" / "ScreenshotResultPresenter.swift",
    APP / "Views" / "ScreenshotResultView.swift",
    APP / "Models" / "ScreenshotAIAction.swift",
    APP / "Models" / "ScreenshotHistoryEntry.swift",
]

LEGACY_SOURCE_TOKENS = [
    "ScreenshotMode",
    "ScreenshotResultView",
    "ScreenshotResultPresenter",
    "ScreenshotAIAction",
    "ScreenshotHistoryEntry",
    "recentCaptures",
    "routeSummaryForScreenshotAIAction",
    "ScreenshotAIActionRoutePreview",
    "startScreenshot(mode:",
    "screenshotRegion",
]

LEGACY_LOCALIZATION_KEYS = {
    "menu.screenshotRegion",
    "menu.screenshotWindow",
    "menu.screenshotFullscreen",
}
LEGACY_LOCALIZATION_PREFIXES = (
    "main.recentCapture",
    "screenshot.ai.",
)
LEGACY_CLI_TOKENS = ["--mode", "fullscreen"]
P14E_REQUIRED_CLI_TOKENS = [
    "func parseScreenshotArguments(",
    'case "--dry-run"',
    'case "--interactive"',
    'case "--no-editor"',
    'case "--kind"',
    'case "--display-scope"',
    'case "--copy"',
    'case "--output"',
    'case "--format"',
    "ScreenshotCaptureActionInput",
    "ActionBrokerRequest(",
    "submitToBroker(",
]


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def add_failure(
    failures: list[dict[str, str]],
    code: str,
    detail: str,
    path: Path | None = None,
) -> None:
    failure = {"code": code, "detail": sanitize_text(detail)}
    if path is not None:
        failure["path"] = rel(path)
    failures.append(failure)


def active_source_files() -> list[Path]:
    files = [
        *APP.rglob("*.swift"),
        *CORE.rglob("*.swift"),
        *SCREENSHOT_CORE.rglob("*.swift"),
        *ACTION_BROKER.rglob("*.swift"),
        CLI,
        PROJECT,
    ]
    return sorted({path for path in files if path.exists()})


def check_legacy_absence(failures: list[dict[str, str]]) -> dict[str, Any]:
    remaining_paths = [rel(path) for path in LEGACY_FILES if path.exists()]
    for path in LEGACY_FILES:
        if path.exists():
            add_failure(failures, "legacy_screenshot_file_remaining", "breaking replacement requires file deletion", path)

    source_hits: list[dict[str, str]] = []
    for path in active_source_files():
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            add_failure(failures, "active_source_read_failed", str(error), path)
            continue
        for token in LEGACY_SOURCE_TOKENS:
            is_identifier = re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token) is not None
            pattern = rf"(?<![A-Za-z0-9_]){re.escape(token)}(?![A-Za-z0-9_])"
            matched = re.search(pattern, source) is not None if is_identifier else token in source
            if matched:
                source_hits.append({"path": rel(path), "token": token})
                add_failure(failures, "legacy_screenshot_symbol_remaining", token, path)

    localization_hits: list[dict[str, str]] = []
    localization_catalogs = sorted(APP.rglob("*.xcstrings"))
    if not localization_catalogs:
        add_failure(failures, "localization_catalog_missing", "no active localization catalog found", APP)
    for path in localization_catalogs:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            keys = payload.get("strings")
            if not isinstance(keys, dict):
                raise ValueError("top-level strings must be an object")
        except (OSError, json.JSONDecodeError, ValueError) as error:
            add_failure(failures, "localization_catalog_invalid", str(error), path)
            continue
        for key in sorted(keys):
            if (
                key in LEGACY_LOCALIZATION_KEYS
                or "screenshotRegion" in key
                or key.startswith(LEGACY_LOCALIZATION_PREFIXES)
            ):
                localization_hits.append({"path": rel(path), "key": key})
                add_failure(failures, "legacy_screenshot_localization_key_remaining", key, path)

    cli_hits: list[str] = []
    if not CLI.exists():
        add_failure(failures, "screenshot_cli_source_missing", "P14 CLI source is required", CLI)
    else:
        try:
            cli_source = CLI.read_text(encoding="utf-8")
        except OSError as error:
            add_failure(failures, "screenshot_cli_source_read_failed", str(error), CLI)
        else:
            cli_hits = [token for token in LEGACY_CLI_TOKENS if token in cli_source]
            for token in cli_hits:
                add_failure(failures, "legacy_screenshot_cli_token_remaining", token, CLI)

    return {
        "legacy_files_absent": not remaining_paths,
        "remaining_files": remaining_paths,
        "source_hits": source_hits,
        "localization_hits": localization_hits,
        "cli_hits": cli_hits,
    }


def run_safe_p14e_gate(timeout: int, failures: list[dict[str, str]]) -> dict[str, Any]:
    gate = "P14-E"
    path = P14_GATES[gate]
    if not path.exists():
        add_failure(failures, "replacement_gate_missing", gate, path)
        return {"gate": gate, "ok": False, "returncode": None, "status": "missing"}

    try:
        cli_source = CLI.read_text(encoding="utf-8")
    except OSError as error:
        add_failure(failures, "p14e_cli_source_read_failed", str(error), CLI)
        cli_source = ""
    missing_cli_tokens = [token for token in P14E_REQUIRED_CLI_TOKENS if token not in cli_source]
    if missing_cli_tokens:
        add_failure(failures, "p14e_cli_contract_missing", ", ".join(missing_cli_tokens), CLI)
    legacy_cli_tokens = [token for token in LEGACY_CLI_TOKENS if token in cli_source]
    if legacy_cli_tokens:
        add_failure(failures, "p14e_legacy_cli_schema_remaining", ", ".join(legacy_cli_tokens), CLI)

    safe_runner = """
import json
import tempfile
from pathlib import Path
import sys

sys.path.insert(0, str(Path('tools/verification').resolve()))
from p14e_screenshot_action_cli_contract_checks import build_cli, run_contract_fixture

failures = []
run_contract_fixture(failures)
with tempfile.TemporaryDirectory(prefix='blocks_p14e_safe_build_') as temporary:
    executable = build_cli(failures, Path(temporary))
    if executable is not None and not executable.exists():
        failures.append({'code': 'cli_executable_missing', 'detail': 'safe build produced no executable'})
print(json.dumps({'gate': 'P14-E', 'status': 'pass' if not failures else 'fail', 'failures': failures}))
raise SystemExit(0 if not failures else 1)
"""
    try:
        completed = subprocess.run(
            ["python3", "-c", safe_runner],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        add_failure(failures, "replacement_gate_timeout", f"{gate} safe equivalent exceeded {timeout}s", path)
        return {"gate": gate, "ok": False, "returncode": None, "status": "timeout", "execution": "no_broker_requests"}
    except OSError as error:
        add_failure(failures, "replacement_gate_execution_failed", f"{gate}: {error}", path)
        return {
            "gate": gate,
            "ok": False,
            "returncode": None,
            "status": "execution_failed",
            "execution": "no_broker_requests",
        }

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        add_failure(failures, "replacement_gate_json_invalid", f"{gate}: {error}", path)
        payload = {}
    delegated_failures = payload.get("failures") if isinstance(payload, dict) else None
    ok = bool(
        not missing_cli_tokens
        and not legacy_cli_tokens
        and completed.returncode == 0
        and isinstance(payload, dict)
        and payload.get("gate") == gate
        and payload.get("status") == "pass"
        and delegated_failures == []
    )
    if not ok and not any(item["code"].startswith("p14e_") for item in failures):
        detail = json.dumps(delegated_failures, ensure_ascii=False) if isinstance(delegated_failures, list) else "malformed payload"
        add_failure(failures, "replacement_gate_failed", f"{gate} safe equivalent: {detail}", path)
    return {
        "gate": gate,
        "ok": ok,
        "returncode": completed.returncode,
        "status": payload.get("status") if isinstance(payload, dict) else None,
        "failures": delegated_failures if isinstance(delegated_failures, list) else None,
        "execution": "contract_fixture_and_cli_build_only_no_broker_requests",
    }


def run_p14_gate(gate: str, timeout: int, failures: list[dict[str, str]]) -> dict[str, Any]:
    if gate == "P14-E":
        return run_safe_p14e_gate(timeout, failures)

    path = P14_GATES[gate]
    if not path.exists():
        add_failure(failures, "replacement_gate_missing", gate, path)
        return {"gate": gate, "ok": False, "returncode": None, "status": "missing"}

    try:
        completed = subprocess.run(
            ["python3", str(path)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        add_failure(failures, "replacement_gate_timeout", f"{gate} exceeded {timeout}s", path)
        return {"gate": gate, "ok": False, "returncode": None, "status": "timeout"}
    except OSError as error:
        add_failure(failures, "replacement_gate_execution_failed", f"{gate}: {error}", path)
        return {"gate": gate, "ok": False, "returncode": None, "status": "execution_failed"}

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        add_failure(failures, "replacement_gate_json_invalid", f"{gate}: {error}", path)
        return {
            "gate": gate,
            "ok": False,
            "returncode": completed.returncode,
            "status": "invalid_json",
            "stderr_tail": sanitize_text(completed.stderr[-1200:]),
        }

    delegated_failures = payload.get("failures") if isinstance(payload, dict) else None
    ok = bool(
        completed.returncode == 0
        and isinstance(payload, dict)
        and payload.get("gate") == gate
        and payload.get("status") == "pass"
        and delegated_failures == []
    )
    if not ok:
        detail = json.dumps(delegated_failures, ensure_ascii=False) if isinstance(delegated_failures, list) else "malformed payload"
        add_failure(failures, "replacement_gate_failed", f"{gate}: {detail}", path)
    return {
        "gate": gate,
        "ok": ok,
        "returncode": completed.returncode,
        "status": payload.get("status") if isinstance(payload, dict) else None,
        "failures": delegated_failures if isinstance(delegated_failures, list) else None,
    }


def run_compatibility_gate(
    suite: str,
    replacement_gates: list[str],
    timeout: int,
    legacy_gate: str | None = None,
) -> int:
    failures: list[dict[str, str]] = []
    unknown = [gate for gate in replacement_gates if gate not in P14_GATES]
    for gate in unknown:
        add_failure(failures, "unknown_replacement_gate", gate)

    delegated = [run_p14_gate(gate, timeout, failures) for gate in replacement_gates if gate in P14_GATES]
    legacy_absence = check_legacy_absence(failures)
    payload: dict[str, Any] = {
        "ok": not failures,
        "suite": suite,
        "replacement": "P14 screenshot breaking replacement",
        "delegated_gates": delegated,
        "legacy_absence": legacy_absence,
        "failures": failures,
    }
    if legacy_gate is not None:
        payload["gate"] = legacy_gate
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    return run_compatibility_gate(
        "p3c_screenshot_checks",
        ["P14-A", "P14-B", "P14-C", "P14-D", "P14-E", "P14-F", "P14-G"],
        args.timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
