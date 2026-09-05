#!/usr/bin/env python3
"""P5-C provider settings skeleton checks for Blocks."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build, run_controlled_subprocess

from current_architecture_gate_helpers import (
    exact_method_block,
    method_chain_checks,
    method_chain_mutations_fail_closed,
    method_chain_overload_adversaries_fail_closed,
)


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
SETTINGS = APP / "Features" / "Settings" / "ProviderSettingsPane.swift"
APP_MODEL = APP / "App" / "AppModel.swift"
APP_MODEL_DELEGATION = APP / "App" / "AppModel+FeatureDelegation.swift"
PROVIDER_COORDINATOR = APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift"
PROVIDER_STORE = APP / "Features" / "Provider" / "ProviderStore.swift"
SETTINGS_SECTION_LIST = APP / "Features" / "Settings" / "SettingsSectionList.swift"


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
        build = run_blocks_no_launch_build(ROOT, args.timeout, "p5c")
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5b = run(["python3", "tools/verification/p5b_translation_mock_result_checks.py", "--timeout", str(args.timeout), "--skip-build"], args.timeout)
    require(p5b["ok"], "p5b_regression_failed", p5b["stdout"] or p5b["stderr_tail"], failures)
    observations["p5b_regression"] = p5b["ok"]

    required_keys = [
        "settings.aiCapabilityGate",
        "settings.providerDefault",
        "settings.providerKeychainAccount",
        "settings.providerBaseURL",
        "settings.providerModel",
        "settings.providerConfiguration",
        "settings.providerCredential",
        "settings.providerNoSecretRead",
        "settings.providerConnection",
        "settings.openAITestConnectionRun",
    ]
    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in ["zh-Hans", "en", "ja"])
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    settings_text = SETTINGS.read_text(encoding="utf-8")
    app_model_text = APP_MODEL.read_text(encoding="utf-8")
    app_model_delegation_text = APP_MODEL_DELEGATION.read_text(encoding="utf-8")
    coordinator_text = PROVIDER_COORDINATOR.read_text(encoding="utf-8")
    store_text = PROVIDER_STORE.read_text(encoding="utf-8")
    section_list_text = SETTINGS_SECTION_LIST.read_text(encoding="utf-8")
    combined = "\n".join([
        settings_text,
        section_list_text,
        app_model_text,
        app_model_delegation_text,
        coordinator_text,
        store_text,
    ])
    required_symbols = [
        '@AppStorage("provider.api.keychainAccountAlias")',
        '@AppStorage("provider.api.baseURL")',
        '@AppStorage("provider.api.modelName")',
        '@AppStorage("provider.api.storedSecretAccountAlias")',
        "settings.aiCapabilityGate",
        "settings.providerNoSecretRead",
        "ProviderSettingsPersistence.saveProviderBaseURL(",
        "saveProviderModelName(",
        "ProviderSettingsPersistence.saveProviderAccountAlias(",
        "ProviderRuntimeGate.normalizedProviderBaseURL",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "provider_settings_symbols_missing", ", ".join(missing_symbols), failures)
    retired_placeholder_symbols = [
        '@AppStorage("provider.localCLI.name")',
        "settings.providerLocalCLI",
    ]
    retired_hits = [needle for needle in retired_placeholder_symbols if needle in settings_text]
    require(not retired_hits, "retired_local_cli_placeholder_restored", ", ".join(retired_hits), failures)

    persistence_text = (APP / "Models" / "ProviderRouting.swift").read_text(encoding="utf-8")
    persistence_requirements = [
        "static func saveProviderBaseURL(",
        "ProviderRuntimeGate.normalizedProviderBaseURL(candidate)",
        "static func saveProviderModelName(",
        "static func saveProviderAccountAlias(",
        "revokeExternalTransferGrant(defaults: defaults)",
    ]
    missing_persistence = [needle for needle in persistence_requirements if needle not in persistence_text]
    require(not missing_persistence, "provider_persistence_contract_missing", ", ".join(missing_persistence), failures)

    settings_save_sources = {"settings": settings_text}
    settings_save_specs = {
        "base_url_ui_uses_persistence_api": (
            "settings",
            "struct ProviderSettingsPane",
            "func saveProviderBaseURLDraft()",
            ["ProviderSettingsPersistence.saveProviderBaseURL(", "apiBaseURLDraft", "apiBaseURL = savedBaseURL"],
            ["apiBaseURL = apiBaseURLDraft"],
        ),
        "model_ui_uses_persistence_api": (
            "settings",
            "struct ProviderSettingsPane",
            "func saveProviderModelNameDraft()",
            ["ProviderSettingsPersistence", ".saveProviderModelName(apiModelNameDraft)", "apiModelName = savedModelName"],
            ["apiModelName = apiModelNameDraft"],
        ),
        "alias_ui_uses_persistence_api": (
            "settings",
            "struct ProviderSettingsPane",
            "func commitStoredProviderAccountAlias(_ alias: String, lifecycleRawValue: String)",
            ["ProviderSettingsPersistence.saveProviderAccountAlias(alias)", "apiKeychainAccountAlias = savedAlias"],
            ["apiKeychainAccountAlias = alias"],
        ),
    }
    settings_save_checks = method_chain_checks(settings_save_sources, settings_save_specs)
    settings_save_mutations = method_chain_mutations_fail_closed(
        settings_save_sources,
        settings_save_specs,
        [
            ("base_url_ui_uses_persistence_api", "settings", "ProviderSettingsPersistence.saveProviderBaseURL(", "_ = apiBaseURLDraft"),
            ("model_ui_uses_persistence_api", "settings", ".saveProviderModelName(apiModelNameDraft)", "_ = apiModelNameDraft"),
            ("alias_ui_uses_persistence_api", "settings", "ProviderSettingsPersistence.saveProviderAccountAlias(alias)", "_ = alias"),
        ],
    )
    require(all(settings_save_checks.values()), "provider_settings_ui_persistence_chain_disconnected", str(settings_save_checks), failures)
    require(all(settings_save_mutations.values()), "provider_settings_ui_persistence_mutation_not_fail_closed", str(settings_save_mutations), failures)

    forbidden_runtime_calls = ["SecItem", "URLSession", "Process(", "NSPasteboard.general", "getenv("]
    forbidden_hits = [needle for needle in forbidden_runtime_calls if needle in settings_text]
    require(not forbidden_hits, "provider_settings_runtime_call_found", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {
        "missing_symbols": missing_symbols,
        "retired_placeholder_hits": retired_hits,
        "missing_persistence": missing_persistence,
        "forbidden_runtime_calls": forbidden_hits,
        "settings_save_checks": settings_save_checks,
        "settings_save_mutations_fail_closed": settings_save_mutations,
        "stores_alias_only": '@AppStorage("provider.api.keychainAccountAlias")' in settings_text,
        "has_current_model_and_stored_alias": all(
            needle in settings_text
            for needle in [
                '@AppStorage("provider.api.modelName")',
                '@AppStorage("provider.api.storedSecretAccountAlias")',
            ]
        ),
    }

    output = {
        "ok": not failures,
        "suite": "p5c_provider_settings_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
