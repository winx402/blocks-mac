#!/usr/bin/env python3
import json
import sys
from pathlib import Path

from permission_gate_helpers import (
    permission_refresh_chain_checks,
    permission_refresh_chain_mutations_fail_closed,
    permission_refresh_overload_adversary_fails_closed,
    permission_settings_diagnostics_checks,
    permission_settings_diagnostics_mutations_fail_closed,
)


ROOT = Path(__file__).resolve().parents[2]
PERMISSION_DIAGNOSTICS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionDiagnostics.swift"
PERMISSION_STATE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStateService.swift"
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
APP_MODEL_DELEGATION = ROOT / "apps/Blocks/BlocksApp/App/AppModel+FeatureDelegation.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
SCREENSHOT_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift"
SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    diagnostics = read(PERMISSION_DIAGNOSTICS)
    state_service = read(PERMISSION_STATE)
    app_model = read(APP_MODEL) + "\n" + read(APP_MODEL_DELEGATION)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    permission_store = read(PERMISSION_STORE)
    screenshot_store = read(SCREENSHOT_STORE)
    settings = read(SETTINGS)
    strings = read(STRINGS)
    refresh_chain = permission_refresh_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_store,
    )
    refresh_chain_mutations = permission_refresh_chain_mutations_fail_closed(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_store,
    )
    refresh_chain_overload_adversary = permission_refresh_overload_adversary_fails_closed(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_store,
    )
    settings_diagnostics = permission_settings_diagnostics_checks(settings)
    settings_diagnostics_mutations = (
        permission_settings_diagnostics_mutations_fail_closed(settings)
    )
    checks = {
        "permission_snapshot_model": "struct PermissionStateSnapshot" in diagnostics
        and "struct PermissionDiagnosticSnapshot" in diagnostics
        and "enum PermissionStateService" in state_service,
        "reads_screen_and_accessibility": "ScreenRecordingPermission.isAuthorized" in state_service and "AXIsProcessTrusted()" in state_service,
        "requests_screen_and_accessibility": "CGRequestScreenCaptureAccess()" in state_service and "AXIsProcessTrustedWithOptions" in state_service,
        "reads_signing_team": "SecCodeCopySigningInformation" in state_service and "kSecCodeInfoTeamIdentifier" in state_service,
        "permission_refreshes_before_screenshot": all(refresh_chain.values()),
        "permission_refresh_mutations_fail_closed": all(refresh_chain_mutations.values()),
        "permission_refresh_overload_adversary_fails_closed": all(
            refresh_chain_overload_adversary.values()
        ),
        "did_become_active_refresh": "NSApplication.didBecomeActiveNotification" in read(ROOT / "apps/Blocks/BlocksApp/Views/ContentView.swift"),
        "settings_shows_diagnostics": all(settings_diagnostics.values()),
        "settings_diagnostic_mutations_fail_closed": all(
            settings_diagnostics_mutations.values()
        ),
        "restart_guidance_localized": "status.screenRecordingRestartRequired.detail" in strings and "settings.permissionDebugAdHoc" in strings,
    }
    ok = all(checks.values())
    print(json.dumps({
        "ok": ok,
        "check": "p7f_permission_state_refresh",
        "checks": checks,
        "permission_refresh_chain": refresh_chain,
        "permission_refresh_chain_mutations": refresh_chain_mutations,
        "permission_refresh_chain_overload_adversary": refresh_chain_overload_adversary,
        "settings_diagnostics": settings_diagnostics,
        "settings_diagnostics_mutations": settings_diagnostics_mutations,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
