#!/usr/bin/env python3
"""P5-D Keychain lifecycle UI skeleton checks for Blocks."""

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
PROVIDER_AUDIT_MODEL = APP / "Models" / "ProviderAuditEvent.swift"
KEYCHAIN_SERVICE = APP / "Services" / "ProviderKeychainService.swift"
PROVIDER_ROUTING = APP / "Models" / "ProviderRouting.swift"


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
        build = run_blocks_no_launch_build(ROOT, args.timeout, "p5d")
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5c = run(["python3", "tools/verification/p5c_provider_settings_checks.py", "--timeout", str(args.timeout), "--skip-build"], args.timeout)
    require(p5c["ok"], "p5c_regression_failed", p5c["stdout"] or p5c["stderr_tail"], failures)
    observations["p5c_regression"] = p5c["ok"]

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.providerSecretNoValue",
        "settings.providerSecretMissing",
        "settings.providerUserSecretSave",
        "settings.providerUserSecretDelete",
        "settings.providerUserSecretConfirmStore",
        "status.providerUserSecretGate.title",
        "status.providerUserSecretGate.detail",
    ]
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
    audit_model_text = PROVIDER_AUDIT_MODEL.read_text(encoding="utf-8")
    keychain_service_text = KEYCHAIN_SERVICE.read_text(encoding="utf-8")
    routing_text = PROVIDER_ROUTING.read_text(encoding="utf-8")
    combined = "\n".join(
        [
            settings_text,
            app_model_text,
            app_model_delegation_text,
            coordinator_text,
            store_text,
            audit_model_text,
            keychain_service_text,
            routing_text,
        ]
    )
    required_symbols = [
        '@AppStorage("provider.api.secretLifecycleState")',
        '@AppStorage("provider.api.storedSecretAccountAlias")',
        "ProviderSecretLifecycleState",
        "ProviderAuditEvent",
        "ProviderUserSecretAction",
        "runProviderUserSecretGate(action:",
        "performProviderUserSecretGate(",
        "providerKeychainWorker.performUserSecretGate(",
        "prepareCredentialMutation(",
        "ProviderStoredUserSecretEnvelope",
        "material.credentialRevision",
        "kind: .userSecretKeychainGate",
        "operationSucceeded: result.ok",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "keychain_ui_symbols_missing", ", ".join(missing_symbols), failures)

    retired_persistence = [
        '@AppStorage("provider.api.secretLifecycleAuditID")',
        "secretLifecycleAuditID",
    ]
    retired_hits = [needle for needle in retired_persistence if needle in settings_text]
    require(not retired_hits, "retired_audit_id_persistence_restored", ", ".join(retired_hits), failures)

    chain_sources = {
        "settings": settings_text,
        "app_model_delegation": app_model_delegation_text,
        "coordinator": coordinator_text,
        "store": store_text,
        "keychain_service": keychain_service_text,
    }
    chain_specs = {
        "settings_user_secret_to_app_model": (
            "settings",
            "struct ProviderSettingsPane",
            "func completeProviderUserSecretGate(action: ProviderUserSecretAction, targetAlias: String, secretCandidate: String?) async",
            [
                "appModel.performProviderUserSecretGate(",
                "action: action",
                "accountAlias: targetAlias",
                "secretCandidate: secretCandidate",
                "if outcome.operationSucceeded",
            ],
            ["performProviderKeychainGate("],
        ),
        "app_model_user_secret_to_coordinator": (
            "app_model_delegation",
            "extension AppModel",
            "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, replacingAccountAlias: String? = nil, authorizationIntent: ProviderExternalTransferAuthorizationIntent? = nil) async -> ProviderKeychainGateUIOutcome",
            [
                "providerCoordinator.performProviderUserSecretGate(",
                "action: action",
                "accountAlias: accountAlias",
                "secretCandidate: secretCandidate",
                "replacingAccountAlias: replacingAccountAlias",
                "authorizationIntent: authorizationIntent",
            ],
            ["performProviderKeychainGate("],
        ),
        "coordinator_user_secret_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, replacingAccountAlias: String? = nil, authorizationIntent: ProviderExternalTransferAuthorizationIntent? = nil) async -> ProviderKeychainGateUIOutcome",
            [
                "providerStore.performProviderUserSecretGate(",
                "action: action",
                "accountAlias: accountAlias",
                "secretCandidate: secretCandidate",
                "replacingAccountAlias: replacingAccountAlias",
                "authorizationIntent: authorizationIntent",
                "outcome.auditID",
            ],
            [],
        ),
        "store_user_secret_to_worker": (
            "store",
            "final class ProviderStore",
            "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, replacingAccountAlias: String? = nil, authorizationIntent: ProviderExternalTransferAuthorizationIntent? = nil) async -> ProviderKeychainGateUIOutcome",
            [
                "providerKeychainWorker.performUserSecretGate(",
                "action: action",
                "alias: accountAlias",
                "secret: secretCandidate",
                "authorizationIntent: authorizationIntent",
                "recordProviderAudit(",
                "operationSucceeded: result.ok",
            ],
            [],
        ),
        "worker_user_secret_to_keychain": (
            "store",
            "private final class ProviderKeychainWorker",
            "func performPreparedUserSecretMutation(action: ProviderUserSecretAction, alias: String, secret: String?, replacingAlias: String?, authorizationIntent: ProviderExternalTransferAuthorizationIntent?) throws -> (ProviderUserSecretOperationResult, UInt64?)",
            [
                "ProviderSettingsPersistence.prepareCredentialMutation(",
                "preserving: authorizationIntent",
                "service.performUserSecret(",
                "action: action",
                "alias: alias",
                "secret: secret",
                "replacingAlias: replacingAlias",
                "credentialRevision: revision",
            ],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    mutation_adversaries = [
        ("settings_action_forward_removed", "settings_user_secret_to_app_model", "settings", "appModel.performProviderUserSecretGate(", "_ = action"),
        ("app_model_action_forward_removed", "app_model_user_secret_to_coordinator", "app_model_delegation", "providerCoordinator.performProviderUserSecretGate(", "_ = action"),
        ("app_model_intent_forward_removed", "app_model_user_secret_to_coordinator", "app_model_delegation", "authorizationIntent: authorizationIntent", "authorizationIntent: nil"),
        ("coordinator_action_forward_removed", "coordinator_user_secret_to_store", "coordinator", "providerStore.performProviderUserSecretGate(", "_ = action"),
        ("coordinator_intent_forward_removed", "coordinator_user_secret_to_store", "coordinator", "authorizationIntent: authorizationIntent", "authorizationIntent: nil"),
        ("store_action_forward_removed", "store_user_secret_to_worker", "store", "providerKeychainWorker.performUserSecretGate(", "_ = action"),
        ("store_intent_forward_removed", "store_user_secret_to_worker", "store", "authorizationIntent: authorizationIntent", "authorizationIntent: nil"),
        ("worker_service_forward_removed", "worker_user_secret_to_keychain", "store", "service.performUserSecret(", "_ = action"),
        # Mutate every preserving edge in the one exact worker method.  A
        # first-occurrence substitution is insufficient now that preparation,
        # journaling, and settlement each preserve the same intent.
        ("worker_prepare_removed", "worker_user_secret_to_keychain", "store", "ProviderSettingsPersistence.prepareCredentialMutation(", "revision = 0"),
    ]
    chain_mutations = {
        result_name: method_chain_mutations_fail_closed(
            chain_sources,
            chain_specs,
            [(check_name, source_name, original, replacement)],
        ).get(check_name, False)
        for result_name, check_name, source_name, original, replacement in mutation_adversaries
    }
    worker_method = exact_method_block(
        store_text,
        "private final class ProviderKeychainWorker",
        "func performPreparedUserSecretMutation(action: ProviderUserSecretAction, alias: String, secret: String?, replacingAlias: String?, authorizationIntent: ProviderExternalTransferAuthorizationIntent?) throws -> (ProviderUserSecretOperationResult, UInt64?)",
    )
    worker_preserving_intent_removed = False
    if worker_method and store_text.count(worker_method) == 1:
        mutated_worker = worker_method.replace(
            "preserving: authorizationIntent", "preserving: nil"
        )
        worker_preserving_intent_removed = (
            mutated_worker != worker_method
            and not method_chain_checks(
                {**chain_sources, "store": store_text.replace(worker_method, mutated_worker, 1)},
                chain_specs,
            ).get("worker_user_secret_to_keychain", False)
        )
    chain_mutations["worker_preserving_intent_removed"] = worker_preserving_intent_removed
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "user_secret_target_noop_overload_forwards",
                "coordinator_user_secret_to_store",
                "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, replacingAccountAlias: String? = nil, authorizationIntent: ProviderExternalTransferAuthorizationIntent? = nil, overloadProbe: Bool) -> ProviderKeychainGateUIOutcome",
                """
func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, replacingAccountAlias: String? = nil, authorizationIntent: ProviderExternalTransferAuthorizationIntent? = nil, overloadProbe: Bool) -> ProviderKeychainGateUIOutcome {
    providerStore.performProviderUserSecretGate(
        action: action,
        accountAlias: accountAlias,
        secretCandidate: secretCandidate,
        replacingAccountAlias: replacingAccountAlias,
        authorizationIntent: authorizationIntent
    )
}
""",
                "providerStore.performProviderUserSecretGate(",
                "_ = action",
            ),
        ],
    )
    require(all(chain_checks.values()), "keychain_lifecycle_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "keychain_lifecycle_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(chain_overload_adversaries.values()), "keychain_lifecycle_chain_overload_bypass", str(chain_overload_adversaries), failures)

    ui_forbidden = ["SecItem", "kSecClass", "URLSession", "Process(", "getenv(", "secretValue"]
    forbidden_hits = [needle for needle in ui_forbidden if needle in settings_text]
    require(not forbidden_hits, "keychain_ui_runtime_or_secret_field_found", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {
        "missing_symbols": missing_symbols,
        "retired_audit_id_persistence": retired_hits,
        "forbidden_runtime_calls": forbidden_hits,
        "has_status_only_storage": '@AppStorage("provider.api.secretLifecycleState")' in settings_text,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
        "worker_exact_method_extractable_unique": bool(worker_method) and store_text.count(worker_method) == 1,
    }

    output = {
        "ok": not failures,
        "suite": "p5d_keychain_lifecycle_ui_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
