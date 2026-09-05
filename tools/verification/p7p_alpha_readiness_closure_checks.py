#!/usr/bin/env python3
"""P7-P alpha readiness closure checks.

This gate verifies the facts that P7-P depends on: stable signed app path,
existing TCC grant visibility, no stale P7-N/L/M shortcut or permission status,
Permission Assist state-machine markers, and a P7-P acceptance record that keeps
uncovered UI checks explicit.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from permission_gate_helpers import (
    destructive_permission_reset_absent,
    destructive_permission_reset_mutation_fails_closed,
    permission_assist_completion_checks,
    permission_assist_contract_mutations_fail_closed,
    permission_assist_generation_checks,
    permission_assist_owner_chain_checks,
)


ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = ROOT / "docs/项目管理库/000_归档/2026-07-05_项目视图改造前"
SCRIPT = ROOT / "script/build_and_run.sh"
PERMISSION_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift"
PERMISSION_DIAGNOSTICS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionDiagnostics.swift"
PERMISSION_STATE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStateService.swift"
PERMISSION_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPanelView.swift"
FLOATING_PANEL_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
PERMISSION_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
WINDOW_SELECTION = ROOT / "apps/Blocks/BlocksApp/Services/WindowSelectionController.swift"
SCREENSHOT_SERVICE = ROOT / "apps/Blocks/BlocksApp/Services/ScreenshotCaptureService.swift"
P7O_RECORD = ARCHIVE / "实施记录/acceptance/p7-o-real-permission-interaction-acceptance-record.md"
P7P_RECORD = ARCHIVE / "实施记录/acceptance/p7-p-alpha-readiness-closure-record.md"
P7P_STORY = ARCHIVE / "实施记录/stories/p7-p-alpha-readiness-closure.md"
P7N_STORY = ARCHIVE / "实施记录/stories/p7-n-alpha-readiness-gate.md"
P7L_STORY = ARCHIVE / "实施记录/stories/p7-l-clipboard-experience-closure.md"
P7M_STORY = ARCHIVE / "实施记录/stories/p7-m-translation-settings-productization.md"
README = ROOT / "README.md"
APP_README = ROOT / "apps/Blocks/README.md"
PROJECT_INDEX = ROOT / "docs/项目管理库/index.md"
BOARD = ARCHIVE / "项目进度看板.md"
DOC_INDEX = ROOT / "docs/index.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run(command: list[str], timeout: int, env: dict[str, str] | None = None) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
        env=env,
    )
    return {
        "command": command,
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout_tail": completed.stdout[-2400:],
        "stderr_tail": completed.stderr[-2400:],
    }


def main() -> int:
    timeout = 180
    if "--timeout" in sys.argv:
        index = sys.argv.index("--timeout")
        timeout = int(sys.argv[index + 1])

    script = read(SCRIPT)
    presenter = read(PERMISSION_PRESENTER)
    diagnostics = read(PERMISSION_DIAGNOSTICS)
    state_service = read(PERMISSION_STATE)
    assist_view = read(PERMISSION_VIEW)
    floating_panel_support = read(FLOATING_PANEL_SUPPORT)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    permission_store = read(PERMISSION_STORE)
    permission_actions = read(PERMISSION_ACTIONS)
    app_model = read(APP_MODEL)
    window_selection = read(WINDOW_SELECTION)
    screenshot_service = read(SCREENSHOT_SERVICE)
    p7o_record = read(P7O_RECORD)
    p7p_record = read(P7P_RECORD)
    p7p_story = read(P7P_STORY)
    p7n_story = read(P7N_STORY)
    p7l_story = read(P7L_STORY)
    p7m_story = read(P7M_STORY)
    public_status_docs = "\n".join([
        read(README),
        read(APP_README),
        read(PROJECT_INDEX),
        read(BOARD),
        read(DOC_INDEX),
    ])
    p7_story_docs = "\n".join([p7n_story, p7l_story, p7m_story])
    permission_reset_sources = {
        "script": script,
        "app_model": app_model,
        "coordinator": permission_coordinator,
        "store": permission_store,
        "actions": permission_actions,
        "diagnostics": diagnostics,
        "state_service": state_service,
        "view": assist_view,
        "presenter": presenter,
    }
    owner_chain = permission_assist_owner_chain_checks(presenter, floating_panel_support, assist_view)
    generation = permission_assist_generation_checks(presenter)
    completion = permission_assist_completion_checks(presenter, permission_store)
    contract_mutations = permission_assist_contract_mutations_fail_closed(
        presenter,
        floating_panel_support,
        assist_view,
        permission_store,
    )

    env = os.environ.copy()
    env["BLOCKS_REQUIRE_TCC"] = "1"
    existing_tcc = run(["./script/build_and_run.sh", "--verify-permissions-existing"], timeout, env=env)

    stale_story_phrases = [
        "partial until live TCC pass",
        "Screen Recording 仍被 App preflight 阻断",
        "默认 Option-only 快捷键也未触发浮层",
        "Option+V",
        "Option+D",
    ]
    stale_public_phrases = [
        "partial / blockers found",
        "Screen Recording preflight 和默认 Option-only 快捷键真实触发仍阻断",
        "快捷键真实触发未通过",
    ]
    stale_hits = [
        phrase for phrase in stale_story_phrases if phrase in p7_story_docs
    ] + [
        phrase for phrase in stale_public_phrases if phrase in public_status_docs
    ]

    checks = {
        "stable_app_path_script": "BLOCKS_STABLE_APP_DIR" in script
        and "$HOME/Applications/BlocksDev/$CONFIGURATION" in script
        and "--verify-permissions-existing" in script,
        "existing_tcc_gate_passed": existing_tcc["ok"],
        "p7o_core_facts_recorded": "Control + Option + A/V/D" in p7o_record
        and "Screen Recording 和 Accessibility 均能被当前稳定 App 识别" in p7o_record
        and "Clipboard 低敏 fixture 可通过 `Return` 和双击卡片" in p7o_record,
        "p7n_l_m_stale_status_removed": not stale_hits,
        "permission_assist_waits_for_settings_window": "hasObservedSystemSettingsWindow" in presenter
        and "showPanelIfNeeded(forceWaitingPanel: false, generation: generation)" in presenter
        and "settingsWindowFallbackSeconds" in presenter
        and "permission.assist.settingsWindowNotFound" in presenter
        and all(generation.values()),
        "permission_assist_close_conditions": "flowTimedOut" in presenter
        and "hasObservedSystemSettingsWindow && !SystemSettingsWindowLocator.isSystemSettingsRunning" in presenter
        and "cancel()" in presenter
        and "completeFromUserAction()" in presenter
        and all(completion.values()),
        "permission_assist_arrow_and_drag_isolated": "arrowDirection = canPlaceRight ? .left : .right" in presenter
        and all(owner_chain.values())
        and "AnimatedPermissionArrow" in assist_view,
        "permission_assist_contract_mutations_fail_closed": all(contract_mutations.values()),
        "no_code_or_script_tcc_reset": destructive_permission_reset_absent(permission_reset_sources),
        "destructive_reset_mutation_fails_closed": destructive_permission_reset_mutation_fails_closed(
            permission_reset_sources,
            mutation_target="state_service",
        ),
        "screenshot_window_fullscreen_paths": "case .window:" in screenshot_service
        and "captureInteractiveWindow()" in screenshot_service
        and "noCandidateWindow" in screenshot_service
        and "case .fullscreen:" in screenshot_service
        and "captureFullscreenOnCurrentDisplay()" in screenshot_service
        and "preferredDisplay(from:" in screenshot_service
        and "drawHighlight(for:" in window_selection
        and "keyCode == 53" in window_selection,
        "p7p_story_and_record": "P7-P" in p7p_story
        and "Permission Assist" in p7p_story
        and "Window / Fullscreen" in p7p_story
        and "P7-P" in p7p_record
        and "passed" in p7p_record
        and "not_covered" in p7p_record,
        "public_status_mentions_p7p": "P7-P" in public_status_docs
        and "Control + Option + A/V/D" in public_status_docs,
    }

    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7p_alpha_readiness_closure_checks",
        "checks": checks,
        "existing_tcc": existing_tcc,
        "stale_hits": stale_hits,
        "permission_reset_scan_sources": sorted(permission_reset_sources),
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
