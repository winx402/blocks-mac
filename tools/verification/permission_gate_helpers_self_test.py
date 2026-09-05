#!/usr/bin/env python3
"""Adversarial self-test for permission source-gate parsing."""

from __future__ import annotations

import json
from pathlib import Path

from permission_gate_helpers import (
    destructive_permission_reset_absent,
    destructive_permission_reset_mutation_fails_closed,
    permission_assist_completion_checks,
    permission_assist_contract_mutations_fail_closed,
    permission_assist_generation_checks,
    permission_assist_owner_chain_checks,
    permission_refresh_chain_checks,
    permission_refresh_chain_mutations_fail_closed,
    permission_refresh_overload_adversary_fails_closed,
    permission_settings_diagnostics_checks,
    permission_settings_diagnostics_mutations_fail_closed,
    permission_request_chain_checks,
    permission_request_chain_mutations_fail_closed,
    permission_request_overload_adversary_fails_closed,
)


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    app_model = (
        read(APP / "App/AppModel.swift")
        + "\n"
        + read(APP / "App/AppModel+FeatureDelegation.swift")
    )
    permission_coordinator = read(
        APP / "Features/Permissions/PermissionFeatureCoordinator.swift"
    )
    permission_store = read(APP / "Features/Permissions/PermissionStore.swift")
    permission_actions = read(
        APP / "Features/Permissions/PermissionSystemActions.swift"
    )
    screenshot_store = read(APP / "Features/Screenshot/ScreenshotStore.swift")
    diagnostics = read(APP / "Features/Permissions/PermissionDiagnostics.swift")
    state_service = read(APP / "Features/Permissions/PermissionStateService.swift")
    assist_view = read(APP / "Features/Permissions/PermissionAssistPanelView.swift")
    presenter = read(APP / "Services/PermissionAssistPanelPresenter.swift")
    floating_panel_support = read(APP / "Services/FloatingPanelSupport.swift")
    permission_settings = read(APP / "Features/Settings/PermissionSettingsPane.swift")
    script = read(ROOT / "script/build_and_run.sh")

    request_chain = permission_request_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    request_mutations = permission_request_chain_mutations_fail_closed(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    request_overload_adversary = permission_request_overload_adversary_fails_closed(
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
    )
    refresh_chain = permission_refresh_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_store,
    )
    refresh_mutations = permission_refresh_chain_mutations_fail_closed(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_store,
    )
    refresh_overload_adversary = permission_refresh_overload_adversary_fails_closed(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_store,
    )
    settings_diagnostics = permission_settings_diagnostics_checks(permission_settings)
    settings_diagnostics_mutations = (
        permission_settings_diagnostics_mutations_fail_closed(permission_settings)
    )
    refresh_screenshot_mutations = {
        name: refresh_mutations.get(name, False)
        for name in (
            "screenshot_no_argument_forward_removed",
            "screenshot_refresh_after_guard",
        )
    }
    assist_owner = permission_assist_owner_chain_checks(
        presenter,
        floating_panel_support,
        assist_view,
    )
    assist_generation = permission_assist_generation_checks(presenter)
    assist_completion = permission_assist_completion_checks(
        presenter,
        permission_store,
    )
    assist_mutations = permission_assist_contract_mutations_fail_closed(
        presenter,
        floating_panel_support,
        assist_view,
        permission_store,
    )
    completion_mutations = {
        name: assist_mutations.get(name, False)
        for name in (
            "close_to_finish_pending_close_removed",
            "finish_pending_close_to_notification_removed",
        )
    }
    reset_sources = {
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

    checks = {
        "request_chain_baseline": all(request_chain.values()),
        "request_targeted_mutations_fail_closed": all(request_mutations.values()),
        "request_overload_adversary_fails_closed": all(
            request_overload_adversary.values()
        ),
        "refresh_chain_baseline": all(refresh_chain.values()),
        "refresh_targeted_mutation_fails_closed": all(refresh_mutations.values()),
        "refresh_screenshot_targeted_mutations_fail_closed": all(
            refresh_screenshot_mutations.values()
        ),
        "refresh_overload_adversary_fails_closed": all(
            refresh_overload_adversary.values()
        ),
        "settings_diagnostics_baseline": all(settings_diagnostics.values()),
        "settings_diagnostics_mutations_fail_closed": all(
            settings_diagnostics_mutations.values()
        ),
        "permission_assist_owner_baseline": all(assist_owner.values()),
        "permission_assist_generation_baseline": all(assist_generation.values()),
        "permission_assist_completion_baseline": all(assist_completion.values()),
        "permission_assist_completion_lifecycle_baseline": assist_completion.get(
            "completion_lifecycle_reaches_notification_and_store_refreshes",
            False,
        ),
        "permission_assist_completion_lifecycle_mutations_fail_closed": all(
            completion_mutations.values()
        ),
        "permission_assist_adversarial_mutations_fail_closed": all(
            assist_mutations.values()
        ),
        "destructive_reset_baseline": destructive_permission_reset_absent(reset_sources),
        "destructive_reset_state_service_mutation_fails_closed": (
            destructive_permission_reset_mutation_fails_closed(
                reset_sources,
                mutation_target="state_service",
            )
        ),
    }
    failures = [name for name, passed in checks.items() if not passed]
    print(json.dumps({
        "ok": not failures,
        "suite": "permission_gate_helpers_self_test",
        "checks": checks,
        "request_chain": request_chain,
        "request_mutations": request_mutations,
        "request_overload_adversary": request_overload_adversary,
        "refresh_chain": refresh_chain,
        "refresh_mutations": refresh_mutations,
        "refresh_screenshot_mutations": refresh_screenshot_mutations,
        "refresh_overload_adversary": refresh_overload_adversary,
        "settings_diagnostics": settings_diagnostics,
        "settings_diagnostics_mutations": settings_diagnostics_mutations,
        "permission_assist_owner": assist_owner,
        "permission_assist_generation": assist_generation,
        "permission_assist_completion": assist_completion,
        "permission_assist_completion_mutations": completion_mutations,
        "permission_assist_mutations": assist_mutations,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
