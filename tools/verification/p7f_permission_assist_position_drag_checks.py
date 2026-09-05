#!/usr/bin/env python3
import json
import sys
from pathlib import Path

from permission_gate_helpers import (
    permission_assist_completion_checks,
    permission_assist_contract_mutations_fail_closed,
    permission_assist_generation_checks,
    permission_assist_owner_chain_checks,
)


ROOT = Path(__file__).resolve().parents[2]
PERMISSION_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift"
PERMISSION_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPanelView.swift"
FLOATING_PANEL_SUPPORT = ROOT / "apps/Blocks/BlocksApp/Services/FloatingPanelSupport.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"


def main() -> int:
    presenter = PERMISSION_PRESENTER.read_text(encoding="utf-8")
    assist_view = PERMISSION_VIEW.read_text(encoding="utf-8")
    floating_panel_support = FLOATING_PANEL_SUPPORT.read_text(encoding="utf-8")
    permission_store = PERMISSION_STORE.read_text(encoding="utf-8")
    owner_chain = permission_assist_owner_chain_checks(presenter, floating_panel_support, assist_view)
    generation = permission_assist_generation_checks(presenter)
    completion = permission_assist_completion_checks(presenter, permission_store)
    contract_mutations = permission_assist_contract_mutations_fail_closed(
        presenter,
        floating_panel_support,
        assist_view,
        permission_store,
    )
    checks = {
        "launch_grace": "settingsLaunchGraceSeconds" in presenter and "shouldKeepWaitingForSystemSettings" in presenter,
        "flow_timeout": "flowTimeoutSeconds" in presenter and "flowTimedOut" in presenter,
        "permission_assist_owner_chain": all(owner_chain.values()),
        "generation_contract": all(generation.values()),
        "callback_refresh": all(completion.values()),
        "permission_assist_contract_mutations_fail_closed": all(contract_mutations.values()),
        "arrow_direction_model": "PermissionAssistArrowDirection" in presenter and "arrowDirection" in presenter,
        "left_and_right_arrow_paths": "case .left" in assist_view and "case .right" in assist_view,
        "system_settings_relative_placement": "visibleWindowFrame()" in presenter and "canPlaceRight" in presenter,
    }
    ok = all(checks.values())
    print(json.dumps({
        "ok": ok,
        "check": "p7f_permission_assist_position_drag",
        "checks": checks,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
