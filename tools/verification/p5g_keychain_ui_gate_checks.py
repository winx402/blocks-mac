#!/usr/bin/env python3
"""P5-G Keychain UI gate checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build

from current_architecture_gate_helpers import (
    method_chain_checks,
    method_chain_mutations_fail_closed,
    method_chain_overload_adversaries_fail_closed,
)


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ProviderKeychainService.swift"
SETTINGS = APP / "Features" / "Settings" / "ProviderSettingsPane.swift"
APP_MODEL = APP / "App" / "AppModel+FeatureDelegation.swift"
PROVIDER_COORDINATOR = APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift"
PROVIDER_STORE = APP / "Features" / "Provider" / "ProviderStore.swift"
TRANSLATION_MODELS = APP / "Models" / "ProviderAuditEvent.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"

LANGUAGES = ["zh-Hans", "en", "ja"]
RAW_FIXTURE_VALUES = [
    "blocks-p5g-low-sensitive-test-secret-v1",
    "blocks-p5g-low-sensitive-test-secret-v2",
]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-1600:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def parse_json(text: str) -> dict[str, Any] | None:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def compile_and_run_keychain_roundtrip(timeout: int) -> dict[str, Any]:
    fixture_alias = f"blocks-p5g-{uuid.uuid4()}"
    with tempfile.TemporaryDirectory(prefix="blocks-p5g-") as tmp:
        tmp_path = Path(tmp)
        runner = tmp_path / "P5GKeychainRunner.swift"
        executable = tmp_path / "P5GKeychainRunner"
        runner_source = """
import Darwin
import Foundation

@main
struct P5GKeychainRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            Darwin.exit(2)
        }
        let alias = CommandLine.arguments[1]
        let keychain = ProviderKeychainService()
        defer {
            _ = try? keychain.perform(action: .deleteTestSecret, alias: alias)
        }
        let steps = [
            try keychain.perform(action: .saveTestSecret, alias: alias),
            try keychain.perform(action: .rotateTestSecret, alias: alias),
            try keychain.perform(action: .deleteTestSecret, alias: alias),
            try keychain.perform(action: .verifyMissing, alias: alias),
        ]
        let report = ProviderKeychainRoundtripReport(
            ok: steps.allSatisfy { $0.ok },
            service: steps.first?.service ?? keychain.service,
            account: steps.first?.account ?? "",
            steps: steps,
            warnings: ["low_sensitive_fixture_only", "unique_alias"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\\n".utf8))
        Darwin.exit(report.ok ? 0 : 1)
    }
}
"""
        runner.write_text(runner_source, encoding="utf-8")
        compile_result = run(
            [
                "xcrun",
                "swiftc",
                str(SERVICE),
                str(runner),
                "-framework",
                "Security",
                "-o",
                str(executable),
            ],
            timeout,
        )
        if not compile_result["ok"]:
            return {
                "ok": False,
                "stage": "compile",
                "stdout": compile_result["stdout"],
                "stderr_tail": compile_result["stderr_tail"],
            }
        run_result = run([str(executable), fixture_alias], timeout)
        parsed = parse_json(run_result["stdout"])
        return {
            "ok": run_result["ok"] and parsed is not None,
            "stage": "run",
            "stdout": run_result["stdout"],
            "stderr_tail": run_result["stderr_tail"],
            "report": parsed,
            "fixture_alias": fixture_alias,
            "runner_source": runner_source,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p5g")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    require(SERVICE.exists(), "provider_keychain_service_missing", str(SERVICE), failures)

    p5f = run(["python3", "tools/verification/p5f_provider_connection_gate_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p5f["ok"], "p5f_regression_failed", p5f["stdout"] or p5f["stderr_tail"], failures)
    observations["p5f_regression"] = p5f["ok"]

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.providerSecretSaveTest",
        "settings.providerSecretRotateTest",
        "settings.providerSecretDeleteTest",
        "settings.providerSecretVerified",
        "settings.providerSecretService",
        "settings.providerSecretAccount",
        "settings.providerSecretHash",
        "settings.providerSecretGateNote",
        "settings.providerConnectionRequirement.apiKeychain.detailVerified",
        "providerAudit.result.keychainGate",
        "providerAudit.warning.lowSensitiveKeychainFixture",
        "status.providerKeychainGate.title",
        "status.providerKeychainGate.detail",
    ]
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in LANGUAGES)
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    project_text = PROJECT.read_text(encoding="utf-8")
    settings_text = SETTINGS.read_text(encoding="utf-8")
    app_model_text = APP_MODEL.read_text(encoding="utf-8")
    coordinator_text = PROVIDER_COORDINATOR.read_text(encoding="utf-8")
    store_text = PROVIDER_STORE.read_text(encoding="utf-8")
    translation_text = TRANSLATION_MODELS.read_text(encoding="utf-8")
    service_text = SERVICE.read_text(encoding="utf-8") if SERVICE.exists() else ""
    combined = "\n".join([project_text, settings_text, app_model_text, coordinator_text, store_text, translation_text, service_text])
    required_symbols = [
        "ProviderKeychainService.swift",
        "ProviderKeychainService",
        "ProviderKeychainGateAction",
        "ProviderKeychainOperationResult",
        "fixtureRoundtrip(alias:",
        "SecItemAdd",
        "SecItemCopyMatching",
        "SecItemUpdate",
        "SecItemDelete",
        "performProviderKeychainGate(action:",
        "runProviderKeychainGate(action:",
        "settings.providerSecretSaveTest",
        "settings.providerSecretRotateTest",
        "settings.providerSecretDeleteTest",
        "settings.providerSecretVerified",
        "providerAudit.result.keychainGate",
        "providerAudit.warning.lowSensitiveKeychainFixture",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "keychain_gate_symbols_missing", ", ".join(missing_symbols), failures)

    chain_sources = {
        "settings": settings_text,
        "app_model": app_model_text,
        "coordinator": coordinator_text,
        "store": store_text,
    }
    chain_specs = {
        "settings_keychain_action_to_app_model": (
            "settings",
            "struct ProviderSettingsPane",
            "func runProviderKeychainGate(action: ProviderKeychainGateAction)",
            [
                "appModel.performProviderKeychainGate(",
                "action: action",
                "accountAlias: apiKeychainAccountAlias",
            ],
            [],
        ),
        "app_model_keychain_action_to_coordinator": (
            "app_model",
            "extension AppModel",
            "func performProviderKeychainGate(action: ProviderKeychainGateAction, accountAlias: String) -> ProviderKeychainGateUIOutcome",
            ["providerCoordinator.performProviderKeychainGate(action: action, accountAlias: accountAlias)"],
            ["providerStore.performProviderKeychainGate"],
        ),
        "coordinator_keychain_action_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func performProviderKeychainGate(action: ProviderKeychainGateAction, accountAlias: String) -> ProviderKeychainGateUIOutcome",
            [
                "providerStore.performProviderKeychainGate(",
                "action: action",
                "accountAlias: accountAlias",
                "providerSummary: selectedProviderSummary()",
            ],
            [],
        ),
        "store_keychain_action_to_service": (
            "store",
            "final class ProviderStore",
            "func performProviderKeychainGate(action: ProviderKeychainGateAction, accountAlias: String, providerSummary: String) -> ProviderKeychainGateUIOutcome",
            ["providerKeychainService.perform(action: action, alias: accountAlias)"],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("settings_keychain_action_to_app_model", "settings", "appModel.performProviderKeychainGate(", "ProviderKeychainGateUIOutcome("),
            ("app_model_keychain_action_to_coordinator", "app_model", "providerCoordinator.performProviderKeychainGate(action: action, accountAlias: accountAlias)", "ProviderKeychainGateUIOutcome(lifecycleRawValue: \"missing\", auditID: \"none\")"),
            ("coordinator_keychain_action_to_store", "coordinator", "providerStore.performProviderKeychainGate(", "ProviderKeychainGateUIOutcome("),
            ("store_keychain_action_to_service", "store", "providerKeychainService.perform(action: action, alias: accountAlias)", "ProviderKeychainOperationResult.fixtureMissing"),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "keychain_action_target_noop_overload_forwards",
                "coordinator_keychain_action_to_store",
                "func performProviderKeychainGate(action: ProviderKeychainGateAction, accountAlias: String, overloadProbe: Bool) -> ProviderKeychainGateUIOutcome",
                """
func performProviderKeychainGate(action: ProviderKeychainGateAction, accountAlias: String, overloadProbe: Bool) -> ProviderKeychainGateUIOutcome {
    providerStore.performProviderKeychainGate(
        action: action,
        accountAlias: accountAlias,
        providerSummary: selectedProviderSummary()
    )
}
""",
                "providerStore.performProviderKeychainGate(",
                "ProviderKeychainGateUIOutcome(",
            ),
        ],
    )
    require(all(chain_checks.values()), "keychain_action_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "keychain_action_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(chain_overload_adversaries.values()), "keychain_action_chain_overload_bypass", str(chain_overload_adversaries), failures)

    forbidden_hits = [
        needle
        for needle in [
            "URLSession",
            "Process(",
            "NSPasteboard.general",
            "getenv(",
            "rawProviderOutput",
            "providerRawOutput",
            "codex exec",
        ]
        if needle in combined
    ]
    require(not forbidden_hits, "forbidden_runtime_or_secret_input_found", ", ".join(forbidden_hits), failures)
    observations["static_boundary"] = {
        "missing_symbols": missing_symbols,
        "forbidden_hits": forbidden_hits,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
    }

    if SERVICE.exists():
        roundtrip = compile_and_run_keychain_roundtrip(args.timeout)
        report = roundtrip.get("report") or {}
        output_text = roundtrip.get("stdout", "")
        fixture_alias = roundtrip.get("fixture_alias", "")
        fixed_alias_marker = "p5g" + "-verification"
        require(roundtrip["ok"], "fixture_roundtrip_failed", roundtrip.get("stdout") or roundtrip.get("stderr_tail", ""), failures)
        require(fixed_alias_marker not in roundtrip.get("runner_source", ""), "fixed_fixture_alias_in_runner", fixed_alias_marker, failures)
        require(bool(fixture_alias) and fixture_alias in output_text, "dynamic_fixture_alias_missing", fixture_alias, failures)
        require(report.get("account") == f"mock-api:{fixture_alias}", "dynamic_fixture_account_wrong", str(report.get("account")), failures)
        require(not any(raw in output_text for raw in RAW_FIXTURE_VALUES), "raw_fixture_secret_in_output", "raw low-sensitive fixture secret appeared in output", failures)
        steps = report.get("steps", [])
        step_names = [step.get("step") for step in steps]
        expected_steps = [
            "save_test_secret",
            "rotate_test_secret",
            "delete_test_secret",
            "verify_missing",
        ]
        require(step_names == expected_steps, "fixture_steps_wrong", str(step_names), failures)
        missing_step = next((step for step in steps if step.get("step") == "verify_missing"), {})
        require(missing_step.get("found") is False, "fixture_final_missing_read_wrong", str(missing_step), failures)
        observations["fixture_roundtrip"] = {
            "ok": report.get("ok"),
            "step_names": step_names,
            "service": report.get("service"),
            "account": report.get("account"),
            "dynamic_alias": fixture_alias,
            "fixed_alias_forbidden": fixed_alias_marker not in roundtrip.get("runner_source", ""),
            "raw_secret_output": any(raw in output_text for raw in RAW_FIXTURE_VALUES),
        }

    output = {
        "ok": not failures,
        "suite": "p5g_keychain_ui_gate_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
