#!/usr/bin/env python3
"""P5-E provider audit summary skeleton checks for Blocks."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build, run_controlled_subprocess

from current_architecture_gate_helpers import (
    method_chain_checks,
    method_chain_mutations_fail_closed,
    method_chain_overload_adversaries_fail_closed,
)


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
P5E_FILES = [
    APP / "Models" / "ProviderAuditEvent.swift",
    APP / "App" / "AppModel.swift",
    APP / "App" / "AppModel+FeatureDelegation.swift",
    APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift",
    APP / "Features" / "Provider" / "ProviderStore.swift",
    APP / "Features" / "Translation" / "TranslationPanelSessionModel.swift",
    APP / "Features" / "Settings" / "DataAuditSettingsPane.swift",
    APP / "Views" / "TranslationFloatingPanelView.swift",
]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = run_controlled_subprocess(command, cwd=ROOT, timeout=timeout)
    if completed["timed_out"]:
        return {
            "ok": False,
            "returncode": completed["returncode"],
            "stdout": completed["stdout"],
            "stderr_tail": f"command timed out after {timeout}s",
            "timed_out": True,
        }
    return {
        "ok": completed["ok"],
        "returncode": completed["returncode"],
        "stdout": completed["stdout"],
        "stderr_tail": completed["stderr"][-1200:],
        "timed_out": False,
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--skip-build", "--no-build", action="store_true", dest="skip_build")
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    if args.skip_build:
        observations["app_build"] = {"ok": True, "skipped": True}
    else:
        build = run_blocks_no_launch_build(ROOT, args.timeout, "p5e")
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5d = run(["python3", "tools/verification/p5d_keychain_lifecycle_ui_checks.py", "--timeout", str(args.timeout), "--skip-build"], args.timeout)
    require(p5d["ok"], "p5d_regression_failed", p5d["stdout"] or p5d["stderr_tail"], failures)
    observations["p5d_regression"] = p5d["ok"]

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "providerAudit.kind.translationRuntime",
        "providerAudit.kind.providerSettingsPreview",
        "providerAudit.kind.keychainLifecyclePreview",
        "providerAudit.source.settings",
        "providerAudit.source.keychainLifecycle",
        "providerAudit.result.settingsPreview",
        "providerAudit.result.keychainLifecycle",
        "providerAudit.source.translationRuntime",
        "providerAudit.result.translationRuntime",
        "providerAudit.warning.externalTransferConfirmed",
        "providerAudit.warning.liveProviderTest",
        "providerAudit.warning.noProviderCall",
        "providerAudit.warning.noKeychainWrite",
        "settings.providerAuditSummary",
        "settings.providerAuditClear",
        "settings.providerAuditEmpty",
        "settings.providerAuditCount",
        "settings.providerAuditProvider",
        "settings.providerAuditConfirmation",
        "settings.providerAuditSource",
        "settings.providerAuditResult",
        "settings.providerAuditID",
        "status.providerAuditCleared.title",
        "status.providerAuditCleared.detail",
    ]
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in ["zh-Hans", "en", "ja"])
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    combined = "\n".join(path.read_text(encoding="utf-8") for path in P5E_FILES)
    required_symbols = [
        "ProviderAuditEvent",
        "ProviderAuditEventKind",
        "TranslationPanelSessionModel",
        "providerAuditEvents",
        "providerAuditCapacity = 20",
        "recordProviderAudit(",
        "clearProviderAuditEvents()",
        ".translationRuntime",
        ".providerSettingsPreview",
        ".keychainLifecyclePreview",
        "ProviderAuditRow",
        "settings.providerAuditSummary",
        "settings.providerAuditEmpty",
        "settings.providerAuditClear",
        "recordTranslationRuntime(",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "provider_audit_symbols_missing", ", ".join(missing_symbols), failures)

    chain_sources = {
        "app_model_delegation": (
            APP / "App" / "AppModel+FeatureDelegation.swift"
        ).read_text(encoding="utf-8"),
        "coordinator": (APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift").read_text(encoding="utf-8"),
    }
    chain_specs = {
        "app_model_clear_audit_to_coordinator": (
            "app_model_delegation",
            "extension AppModel",
            "func clearProviderAuditEvents()",
            ["providerCoordinator.clearProviderAuditEvents()"],
            ["providerStore.clearProviderAuditEvents"],
        ),
        "coordinator_clear_audit_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func clearProviderAuditEvents()",
            ["providerStore.clearProviderAuditEvents()"],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("app_model_clear_audit_to_coordinator", "app_model_delegation", "providerCoordinator.clearProviderAuditEvents()", "()"),
            ("coordinator_clear_audit_to_store", "coordinator", "providerStore.clearProviderAuditEvents()", "()"),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "clear_audit_target_noop_overload_forwards",
                "coordinator_clear_audit_to_store",
                "func clearProviderAuditEvents(overloadProbe: Bool)",
                """
func clearProviderAuditEvents(overloadProbe: Bool) {
    providerStore.clearProviderAuditEvents()
}
""",
                "providerStore.clearProviderAuditEvents()",
                "()",
            ),
        ],
    )
    require(all(chain_checks.values()), "provider_audit_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "provider_audit_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(chain_overload_adversaries.values()), "provider_audit_chain_overload_bypass", str(chain_overload_adversaries), failures)

    forbidden_runtime_calls = [
        "SecItem",
        "kSecClass",
        "URLSession",
        "Process(",
        "NSPasteboard.general",
        "getenv(",
        "secretValue",
        "rawProviderOutput",
        "providerRawOutput",
        "codex exec",
    ]
    forbidden_hits = [needle for needle in forbidden_runtime_calls if needle in combined]
    require(not forbidden_hits, "provider_audit_runtime_or_secret_found", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {
        "missing_symbols": missing_symbols,
        "forbidden_runtime_calls": forbidden_hits,
        "in_memory_only": "providerAuditEvents" in combined and "@AppStorage(\"provider.audit" not in combined,
        "capacity_limit": "providerAuditCapacity = 20" in combined,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
    }

    output = {
        "ok": not failures,
        "suite": "p5e_provider_audit_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
