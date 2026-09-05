#!/usr/bin/env python3
"""P7-K stable signing, TCC identity, and permission assist gate checks."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

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
PERMISSION_STATE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStateService.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
APP_MODEL_DELEGATION = ROOT / "apps/Blocks/BlocksApp/App/AppModel+FeatureDelegation.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
PERMISSION_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run(command: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def redact(text: str) -> str:
    redacted = text.replace(str(ROOT), "<ROOT>").replace(str(Path.home()), "<HOME>")
    return re.sub(r"[\w.+-]+@[\w.-]+", "<EMAIL>", redacted)


def main() -> int:
    timeout = 180
    if "--timeout" in sys.argv:
        index = sys.argv.index("--timeout")
        timeout = int(sys.argv[index + 1])

    script = read(SCRIPT)
    presenter = read(PERMISSION_PRESENTER)
    assist_view = read(PERMISSION_VIEW)
    floating_panel_support = read(FLOATING_PANEL_SUPPORT)
    state_service = read(PERMISSION_STATE)
    app_model = read(APP_MODEL) + "\n" + read(APP_MODEL_DELEGATION)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    permission_store = read(PERMISSION_STORE)
    permission_actions = read(PERMISSION_ACTIONS)
    strings = json.loads(read(STRINGS)).get("strings", {})
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

    stable_verify = run(["./script/build_and_run.sh", "--verify-permissions"], timeout)
    stable_verify_ok = stable_verify.returncode == 0
    expected_identity_block = stable_verify.returncode in {66, 67, 68} and (
        "stable signing requested" in stable_verify.stderr
        or "no code signing identity" in stable_verify.stderr
        or "DEVELOPMENT_TEAM could not be resolved" in stable_verify.stderr
    )

    checks = {
        "permission_verify_mode_requires_stable_signing": "--verify-permissions" in script
        and "REQUIRE_STABLE_SIGNING=1" in script
        and "USE_STABLE_SIGNING=1" in script,
        "permission_verify_does_not_silently_use_adhoc": stable_verify_ok or expected_identity_block,
        "screen_recording_request_path": "CGRequestScreenCaptureAccess()" in state_service
        and all(value for name, value in request_chain.items() if name.startswith("screen_")),
        "accessibility_request_path": "AXIsProcessTrustedWithOptions" in state_service
        and all(value for name, value in request_chain.items() if name.startswith("accessibility_")),
        "request_chain_mutations_fail_closed": all(request_chain_mutations.values()),
        "request_chain_overload_adversary_fails_closed": all(
            request_chain_overload_adversary.values()
        ),
        "permission_assist_fallback": "settingsWindowFallbackSeconds" in presenter
        and "permission.assist.settingsWindowNotFound" in presenter
        and "orderFrontRegardless()" in presenter
        and all(owner_chain.values())
        and all(generation.values())
        and all(completion.values())
        and all(contract_mutations.values()),
        "permission_assist_state_machine": "enum PermissionAssistSessionState" in presenter
        and "waitingForSettingsWindow" in presenter
        and "checkingPermission" in presenter
        and "timedOut" in presenter,
        "no_destructive_tcc_reset": "tccutil reset" not in "\n".join([script, presenter, state_service, app_model]),
        "localization": all(
            key in strings
            for key in [
                "permission.assist.settingsWindowNotFound",
                "permission.assist.notGrantedAfterCheck",
                "settings.permissionActionSigningOrIdentityMismatch",
            ]
        ),
    }

    failures = [name for name, ok in checks.items() if not ok]
    report = {
        "ok": not failures,
        "suite": "p7k_permission_identity_gate_checks",
        "checks": checks,
        "stable_verify": {
            "ok": stable_verify_ok,
            "returncode": stable_verify.returncode,
            "identity_blocked": expected_identity_block,
            "stderr_tail": redact(stable_verify.stderr[-1200:]),
        },
        "permission_request_chain": request_chain,
        "permission_request_chain_mutations": request_chain_mutations,
        "permission_request_chain_overload_adversary": request_chain_overload_adversary,
        "failures": failures,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
