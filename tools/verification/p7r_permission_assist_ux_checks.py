#!/usr/bin/env python3
"""P7-R Permission Assist UX validation gate."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from permission_gate_helpers import (
    permission_assist_completion_checks,
    permission_assist_contract_mutations_fail_closed,
    permission_assist_generation_checks,
    permission_assist_owner_chain_checks,
    permission_request_chain_checks,
    permission_request_chain_mutations_fail_closed,
    permission_request_overload_adversary_fails_closed,
)


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script/build_and_run.sh"
PERMISSION_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift"
PERMISSION_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPanelView.swift"
FLOATING_PANEL_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
APP_MODEL_DELEGATION = ROOT / "apps/Blocks/BlocksApp/App/AppModel+FeatureDelegation.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
PERMISSION_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift"
SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"
STEP4_DIR = ROOT / "docs/项目管理库/003_架构升级/step_4"
STEP4B_PRD = STEP4_DIR / "PRD-Step4B-PermissionStore-v0.md"
STEP4B_DEVELOPMENT_RECORD = STEP4_DIR / "开发记录-Step4B-PermissionStore-v0.md"
STEP4B_ACCEPTANCE_RECORD = STEP4_DIR / "验收记录-Step4B-PermissionStore-v0.md"
LANGUAGES = ["zh-Hans", "en", "ja"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def redact(text: str) -> str:
    redacted = text.replace(str(ROOT), "<ROOT>").replace(str(Path.home()), "<HOME>")
    redacted = re.sub(r"[\w.+-]+@[\w.-]+", "<EMAIL>", redacted)
    sanitized_lines: list[str] = []
    for line in redacted.splitlines():
        if line.startswith("TCC ScreenCapture row:") or line.startswith("TCC Accessibility row:"):
            prefix, payload = line.split(": ", 1)
            fields = payload.split(" | ")
            sanitized_lines.append(" | ".join([prefix + ":", *fields[:5], "<REDACTED_TCC_REQUIREMENT>"]))
        else:
            sanitized_lines.append(line)
    return "\n".join(sanitized_lines)


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
        "stdout_tail": redact(completed.stdout[-2000:]),
        "stderr_tail": redact(completed.stderr[-2000:]),
    }


def main() -> int:
    timeout = 180
    if "--timeout" in sys.argv:
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1])

    presenter = read(PERMISSION_PRESENTER)
    assist_view = read(PERMISSION_VIEW)
    floating_panel_support = read(FLOATING_PANEL_SUPPORT)
    app_model = read(APP_MODEL) + "\n" + read(APP_MODEL_DELEGATION)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    permission_store = read(PERMISSION_STORE)
    permission_actions = read(PERMISSION_ACTIONS)
    settings = read(SETTINGS)
    strings = json.loads(read(STRINGS))
    step4b_prd = read(STEP4B_PRD)
    step4b_development_record = read(STEP4B_DEVELOPMENT_RECORD)
    step4b_acceptance_record = read(STEP4B_ACCEPTANCE_RECORD) if STEP4B_ACCEPTANCE_RECORD.exists() else ""
    request_chain = permission_request_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    request_chain_mutations = permission_request_chain_mutations_fail_closed(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    request_chain_overload_adversary = permission_request_overload_adversary_fails_closed(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    owner_chain = permission_assist_owner_chain_checks(presenter, floating_panel_support, assist_view)
    generation = permission_assist_generation_checks(presenter)
    completion = permission_assist_completion_checks(presenter, permission_store)
    contract_mutations = permission_assist_contract_mutations_fail_closed(
        presenter,
        floating_panel_support,
        assist_view,
        permission_store,
    )
    existing_tcc = run(["./script/build_and_run.sh", "--verify-permissions-existing"], timeout)

    localization_keys = [
        "permission.assist.accessibility.title",
        "permission.assist.screenRecording.title",
        "permission.assist.completed",
        "permission.assist.settingsWindowNotFound",
        "permission.assist.notGrantedAfterCheck",
        "permission.assist.state.opening",
        "permission.assist.state.waiting",
        "permission.assist.state.guiding",
        "permission.assist.state.checking",
        "permission.assist.state.granted",
        "permission.assist.state.failed",
        "permission.assist.state.cancelled",
        "permission.assist.state.timedOut",
    ]
    missing_localizations: dict[str, list[str]] = {}
    string_map = strings.get("strings", {})
    for key in localization_keys:
        entry = string_map.get(key)
        missing = [lang for lang in LANGUAGES if lang not in (entry or {}).get("localizations", {})]
        if entry is None or missing:
            missing_localizations[key] = missing or LANGUAGES

    checks = {
        "existing_tcc_gate_passed": existing_tcc["ok"]
        and "kTCCServiceScreenCapture | app.blocks.app | 2" in existing_tcc["stdout_tail"]
        and "kTCCServiceAccessibility | app.blocks.app | 2" in existing_tcc["stdout_tail"],
        "state_machine_declared": "enum PermissionAssistSessionState" in presenter
        and all(state in presenter for state in [
            "openingSystemSettings",
            "waitingForSettingsWindow",
            "guiding",
            "checkingPermission",
            "granted",
            "failed",
            "cancelled",
            "timedOut",
        ]),
        "waits_for_system_settings_window": "hasObservedSystemSettingsWindow" in presenter
        and "settingsLaunchGraceSeconds" in presenter
        and "settingsWindowFallbackSeconds" in presenter
        and "showPanelIfNeeded(forceWaitingPanel: false, generation: generation)" in presenter
        and "permission.assist.settingsWindowNotFound" in presenter
        and all(generation.values()),
        "placement_arrow_direction": "systemSettingsWindowFrame()" in presenter
        and "PermissionAssistPlacementGeometry.visibleFrame" in presenter
        and "canPlaceRight" in presenter
        and "arrowDirection = canPlaceRight ? .left : .right" in presenter
        and "AnimatedPermissionArrow" in assist_view,
        "drag_isolation": all(owner_chain.values()),
        "permission_assist_contract_mutations_fail_closed": all(contract_mutations.values()),
        "close_conditions": "flowTimedOut" in presenter
        and "hasObservedSystemSettingsWindow && !isSystemSettingsRunning()" in presenter
        and "cancel()" in presenter
        and "close()" in presenter
        and all(completion.values()),
        "request_paths_present": all(request_chain.values()),
        "request_chain_mutations_fail_closed": all(request_chain_mutations.values()),
        "request_chain_overload_adversary_fails_closed": all(
            request_chain_overload_adversary.values()
        ),
        "settings_exposes_permission_actions": "settings.permissionRequestScreenRecording" in settings
        and "settings.permissionRequestAccessibility" in settings
        and "permission.assist.completed" in assist_view
        and "settings.permissionShowInFinder" in settings,
        "localization_coverage": not missing_localizations,
        "step4b_prd_records_ux_evidence_contract": "Permission Assist 实际触碰的 opening" in step4b_prd
        and "未触碰状态明确标为未覆盖" in step4b_prd
        and "作为 Step 4B 阻断门禁的旧 P7 / P10 脚本必须先确认事实源仍然有效" in step4b_prd
        and "baseline 辅助证据" in step4b_prd
        and "当前代码事实" in step4b_prd,
        "step4b_development_record_records_ux_limits": "P7R existing TCC mode 通过" in step4b_development_record
        and "受限 / 未覆盖" in step4b_development_record
        and "未自动点击 Request Screen Recording" in step4b_development_record
        and "未重置 TCC" in step4b_development_record
        and "Permission Assist" in step4b_development_record,
        "script_has_existing_tcc_mode": "--verify-permissions-existing" in read(SCRIPT),
    }

    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7r_permission_assist_ux_checks",
        "checks": checks,
        "existing_tcc": existing_tcc,
        "missing_localizations": missing_localizations,
        "permission_request_chain": request_chain,
        "permission_request_chain_mutations": request_chain_mutations,
        "permission_request_chain_overload_adversary": request_chain_overload_adversary,
        "current_evidence": {
            "prd": str(STEP4B_PRD.relative_to(ROOT)),
            "development_record": str(STEP4B_DEVELOPMENT_RECORD.relative_to(ROOT)),
            "acceptance_record_available": STEP4B_ACCEPTANCE_RECORD.exists(),
            "acceptance_record_status": "changes-requested" if "changes-requested" in step4b_acceptance_record else "not_changes_requested",
        },
        "baseline_reference": {
            "legacy_archive_used_for_ok": False,
            "note": "Step 4B P7R blocking checks use current step_4 evidence; old archive is not read or used for ok.",
        },
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
