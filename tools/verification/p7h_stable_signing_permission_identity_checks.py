#!/usr/bin/env python3
"""P7-H signing/path and permission identity checks."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script/build_and_run.sh"
INSTALL_SCRIPT = ROOT / "script/stable_app_install.sh"
PERMISSION_DIAGNOSTICS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionDiagnostics.swift"
SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"
SELECTION_HELPER_CLIENT = ROOT / "apps/Blocks/BlocksApp/Features/Translation/Entry/SelectionHelperClient.swift"
SELECTION_HELPER_PROTOCOL = ROOT / "apps/Blocks/BlocksCore/SelectionAgentXPC.swift"
SELECTION_HELPER_INFO = ROOT / "apps/Blocks/BlocksSelectionHelper/Info.plist"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def has_signing_identity() -> bool:
    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return "0 valid identities found" not in result.stdout and ")" in result.stdout


def main() -> int:
    script = read(SCRIPT)
    install_script = read(INSTALL_SCRIPT)
    diagnostics = read(PERMISSION_DIAGNOSTICS)
    settings = read(SETTINGS)
    selection_helper_client = read(SELECTION_HELPER_CLIENT)
    selection_helper_protocol = read(SELECTION_HELPER_PROTOCOL)
    selection_helper_info = read(SELECTION_HELPER_INFO)
    strings = json.loads(read(STRINGS)).get("strings", {})
    identity_available = has_signing_identity()
    install_self_test = subprocess.run(
        [sys.executable, str(ROOT / "tools/verification/stable_app_install_self_test.py")],
        cwd=ROOT, text=True, capture_output=True, timeout=90, check=False,
    )
    try:
        install_report = json.loads(install_self_test.stdout)
    except ValueError:
        install_report = {}
    checks = {
        "stable_install_failure_recovery": (
            install_self_test.returncode == 0
            and install_report.get("ok") is True
            and len(install_report.get("cases", [])) == 18
            and all(case.get("ok") is True for case in install_report.get("cases", []))
        ),
        "stable_app_path": "BLOCKS_STABLE_APP_DIR" in script
        and "$HOME/Applications/BlocksDev/$CONFIGURATION" in script
        and 'source "$ROOT_DIR/script/stable_app_install.sh"' in script
        and "  install_stable_app\n" in script
        and 'ditto "$BUILT_APP_BUNDLE" "$staged_app"' in install_script
        and 'mv "$staged_app" "$APP_BUNDLE"' in install_script,
        "existing_app_permission_verify_mode": "--verify-permissions-existing" in script
        and "SKIP_BUILD=1" in script
        and "existing stable app not found" in script,
        "runtime_tcc_diagnostics_gate": "BLOCKS_REQUIRE_TCC" in script
        and "print_runtime_permission_diagnostics" in script
        and "TCC ScreenCapture row" in script
        and "TCC Accessibility row" in script
        and "exit 70" in script
        and "exit 71" in script,
        "optional_stable_signing_gate": "BLOCKS_REQUIRE_STABLE_SIGNING" in script
        and "BLOCKS_USE_STABLE_SIGNING" in script
        and "security find-identity -v -p codesigning" in script
        and "exit 66" in script,
        "selection_helper_independent_lifecycle": (
            "The separate\n  # Selection Helper is independently installed and versioned" in script
            and "must not stop or replace it" in script
            and "stop_selection_agent" not in script
            and "app.blocks.selection-agent" not in script
            and "BlocksSelectionHelperProtocol.bundleIdentifier" in selection_helper_client
            and '"app.blocks.selection-helper"' in selection_helper_protocol
            and "app.blocks.selection-helper" in selection_helper_info
        ),
        "permission_identity_issue_model": "enum PermissionDiagnosticIdentityIssue" in diagnostics
        and "signingOrIdentityMismatch" in diagnostics
        and "matchingRunningAppPaths" in diagnostics,
        "permission_identity_ui": "settings.permissionDiagnostic.identityIssue" in settings
        and "settings.permissionDiagnostic.runningPaths" in settings
        and "settings.permissionActionSigningOrIdentityMismatch" in settings,
        "localization": all(
            key in strings
            for key in [
                "settings.permissionActionSigningOrIdentityMismatch",
                "settings.permissionDiagnostic.identityIssue",
                "settings.permissionDiagnostic.runningPaths",
                "settings.permissionIdentityIssue.signingOrIdentityMismatch",
            ]
        ),
        "current_machine_identity_fact_recorded": True,
    }
    observations = {
        "code_signing_identity_available": identity_available,
        "expected_without_identity": "permission UI must diagnose unstable TCC identity; live TCC success is not guaranteed",
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7h_stable_signing_permission_identity_checks",
        "checks": checks,
        "observations": observations,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
