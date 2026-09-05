#!/usr/bin/env python3
"""P5-K user API key Keychain gate checks for Blocks."""

from __future__ import annotations

import argparse
import hashlib
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
LLM_ADAPTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Models" / "LLMProviderAdapter.swift"
DOC = ROOT / "docs" / "技术知识库" / "Provider-Secret-Handling-v0.md"
STORY_CANDIDATES = [
    ROOT / "docs" / "项目管理库" / "实施记录" / "stories" / "p5-k-user-secret-keychain-gate.md",
    ROOT / "docs" / "项目管理库" / "000_归档" / "2026-07-05_项目视图改造前" / "实施记录" / "stories" / "p5-k-user-secret-keychain-gate.md",
]

LANGUAGES = ["zh-Hans", "en", "ja"]
RAW_DUMMY_SECRET_V1 = "blocks-p5k-low-sensitive-dummy-secret-v1"
RAW_DUMMY_SECRET_V2 = "blocks-p5k-low-sensitive-dummy-secret-v2"


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
        "stderr_tail": completed.stderr[-1800:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def first_existing(paths: list[Path]) -> Path:
    return next((path for path in paths if path.exists()), paths[0])


def parse_json(text: str) -> dict[str, Any] | None:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def compile_and_run_user_secret_roundtrip(timeout: int) -> dict[str, Any]:
    fixture_alias = f"blocks-p5k-{uuid.uuid4()}"
    with tempfile.TemporaryDirectory(prefix="blocks-p5k-") as tmp:
        tmp_path = Path(tmp)
        runner = tmp_path / "P5KUserSecretRunner.swift"
        executable = tmp_path / "P5KUserSecretRunner"
        runner_source = f"""
import Darwin
import Foundation

@main
struct P5KUserSecretRunner {{
    static func main() throws {{
        guard CommandLine.arguments.count == 2 else {{
            Darwin.exit(2)
        }}
        let alias = CommandLine.arguments[1]
        let keychain = ProviderKeychainService()
        defer {{
            _ = try? keychain.performUserSecret(action: .deleteStored, alias: alias)
        }}
        let steps = [
            try keychain.performUserSecret(action: .saveOrReplace, alias: alias, secret: "{RAW_DUMMY_SECRET_V1}"),
            try keychain.performUserSecret(action: .verifyStored, alias: alias),
            try keychain.performUserSecret(action: .saveOrReplace, alias: alias, secret: "{RAW_DUMMY_SECRET_V2}"),
            try keychain.performUserSecret(action: .verifyStored, alias: alias),
            try keychain.performUserSecret(action: .deleteStored, alias: alias),
            try keychain.performUserSecret(action: .verifyMissing, alias: alias),
        ]
        let report = ProviderUserSecretRoundtripReport(
            ok: steps.allSatisfy {{ $0.ok }},
            service: steps.first?.service ?? keychain.service,
            account: steps.first?.account ?? "",
            steps: steps,
            warnings: ["low_sensitive_dummy_secret_only", "unique_alias", "no_secret_value_or_hash_in_output"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\\n".utf8))
        Darwin.exit(report.ok ? 0 : 1)
    }}
}}
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

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p5k")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5j = run(["python3", "tools/verification/p5j_api_key_connection_gate_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p5j["ok"], "p5j_regression_failed", p5j["stdout"] or p5j["stderr_tail"], failures)
    observations["p5j_regression"] = p5j["ok"]

    p5g = run(["python3", "tools/verification/p5g_keychain_ui_gate_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p5g["ok"], "p5g_regression_failed", p5g["stdout"] or p5g["stderr_tail"], failures)
    observations["p5g_regression"] = p5g["ok"]

    story = first_existing(STORY_CANDIDATES)
    require(story.exists(), "p5k_story_missing", str(story), failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.providerUserSecretConfirmStore",
        "settings.providerUserSecretSave",
        "settings.providerUserSecretVerifyStored",
        "settings.providerUserSecretDelete",
        "settings.providerUserSecretVerifyMissing",
        "settings.providerUserSecretGateNote",
        "settings.providerUserSecretStored",
        "settings.providerUserSecretFound",
        "settings.providerUserSecretLength",
        "settings.providerConnectionReadyDryRun",
        "settings.providerConnectionRequirement.apiModel.title",
        "settings.providerConnectionRequirement.apiModel.detail",
        "settings.providerConnectionRequirement.apiKeychain.detailUserStored",
        "settings.providerConnectionRequirement.apiDryRun.title",
        "settings.providerConnectionRequirement.apiDryRun.detail",
        "providerAudit.kind.userSecretKeychainGate",
        "providerAudit.source.userSecretKeychainGate",
        "providerAudit.result.userSecretKeychainGate",
        "providerAudit.warning.userSecretStored",
        "status.providerUserSecretGate.title",
        "status.providerUserSecretGate.detail",
    ]
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in LANGUAGES)
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    settings_text = SETTINGS.read_text(encoding="utf-8")
    app_model_text = APP_MODEL.read_text(encoding="utf-8")
    coordinator_text = PROVIDER_COORDINATOR.read_text(encoding="utf-8")
    store_text = PROVIDER_STORE.read_text(encoding="utf-8")
    translation_text = TRANSLATION_MODELS.read_text(encoding="utf-8")
    llm_text = LLM_ADAPTER.read_text(encoding="utf-8")
    service_text = SERVICE.read_text(encoding="utf-8")
    doc_text = DOC.read_text(encoding="utf-8")
    story_text = story.read_text(encoding="utf-8") if story.exists() else ""
    combined = "\n".join([settings_text, app_model_text, coordinator_text, store_text, translation_text, llm_text, service_text, doc_text, story_text])

    required_symbols = [
        "ProviderUserSecretAction",
        "ProviderUserSecretOperationResult",
        "ProviderUserSecretRoundtripReport",
        "performUserSecret(action:",
        "userSecretRoundtrip(alias:",
        "openai-compatible:",
        "performProviderUserSecretGate(",
        "runProviderUserSecretGate(action:",
        "providerUserSecretLastResult",
        "providerUserSecretStoreConfirmed",
        "userSecretKeychainGate",
        "settings.providerUserSecretConfirmStore",
        "settings.providerUserSecretSave",
        "settings.providerUserSecretVerifyStored",
        "settings.providerUserSecretDelete",
        "settings.providerUserSecretVerifyMissing",
        "settings.providerConnectionReadyDryRun",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "p5k_symbols_missing", ", ".join(missing_symbols), failures)

    chain_sources = {
        "settings": settings_text,
        "app_model": app_model_text,
        "coordinator": coordinator_text,
        "store": store_text,
        "service": service_text,
    }
    chain_specs = {
        "settings_user_secret_action_to_app_model": (
            "settings",
            "struct ProviderSettingsPane",
            "func runProviderUserSecretGate(action: ProviderUserSecretAction, secretCandidate: String? = nil)",
            [
                "appModel.performProviderUserSecretGate(",
                "action: action",
                "accountAlias: apiKeychainAccountAlias",
                "secretCandidate: secretCandidate",
            ],
            [],
        ),
        "app_model_user_secret_action_to_coordinator": (
            "app_model",
            "extension AppModel",
            "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil) -> ProviderKeychainGateUIOutcome",
            [
                "providerCoordinator.performProviderUserSecretGate(",
                "action: action",
                "accountAlias: accountAlias",
                "secretCandidate: secretCandidate",
            ],
            ["providerStore.performProviderUserSecretGate"],
        ),
        "coordinator_user_secret_action_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil) -> ProviderKeychainGateUIOutcome",
            [
                "providerStore.performProviderUserSecretGate(",
                "action: action",
                "accountAlias: accountAlias",
                "secretCandidate: secretCandidate",
            ],
            [],
        ),
        "store_user_secret_action_to_service": (
            "store",
            "final class ProviderStore",
            "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil) -> ProviderKeychainGateUIOutcome",
            ["providerKeychainService.performUserSecret("],
            [],
        ),
        "service_user_secret_action_contract": (
            "service",
            "struct ProviderKeychainService",
            "func performUserSecret(action: ProviderUserSecretAction, alias: String, secret: String? = nil) throws -> ProviderUserSecretOperationResult",
            ["addRaw(account:", "existsRaw(account:", "deleteRaw(account:"],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("settings_user_secret_action_to_app_model", "settings", "appModel.performProviderUserSecretGate(", "ProviderKeychainGateUIOutcome("),
            ("app_model_user_secret_action_to_coordinator", "app_model", "providerCoordinator.performProviderUserSecretGate(", "ProviderKeychainGateUIOutcome("),
            ("coordinator_user_secret_action_to_store", "coordinator", "providerStore.performProviderUserSecretGate(", "ProviderKeychainGateUIOutcome("),
            ("store_user_secret_action_to_service", "store", "providerKeychainService.performUserSecret(", "ProviderUserSecretOperationResult("),
            ("service_user_secret_action_contract", "service", "addRaw(account:", "noOpAddRaw(account:"),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "user_secret_target_noop_overload_forwards",
                "coordinator_user_secret_action_to_store",
                "func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, overloadProbe: Bool) -> ProviderKeychainGateUIOutcome",
                """
func performProviderUserSecretGate(action: ProviderUserSecretAction, accountAlias: String, secretCandidate: String? = nil, overloadProbe: Bool) -> ProviderKeychainGateUIOutcome {
    providerStore.performProviderUserSecretGate(
        action: action,
        accountAlias: accountAlias,
        secretCandidate: secretCandidate
    )
}
""",
                "providerStore.performProviderUserSecretGate(",
                "ProviderKeychainGateUIOutcome(",
            ),
        ],
    )
    require(all(chain_checks.values()), "user_secret_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "user_secret_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(chain_overload_adversaries.values()), "user_secret_chain_overload_bypass", str(chain_overload_adversaries), failures)

    scanned_runtime_text = "\n".join([settings_text, app_model_text, coordinator_text, store_text, translation_text, llm_text, service_text])
    forbidden_hits = [
        needle
        for needle in [
            "URLSession",
            "Process(",
            "getenv(",
            "codex exec",
            "NSPasteboard.general",
            "VNRecognizeTextRequest",
            "rawProviderOutput",
            "providerRawOutput",
            "Authorization",
            "Bearer ",
        ]
        if needle in scanned_runtime_text
    ]
    require(not forbidden_hits, "forbidden_runtime_or_secret_output_found", ", ".join(forbidden_hits), failures)

    roundtrip = compile_and_run_user_secret_roundtrip(args.timeout)
    report = roundtrip.get("report") or {}
    output_text = roundtrip.get("stdout", "")
    fixture_alias = roundtrip.get("fixture_alias", "")
    fixed_alias_marker = "p5k" + "-verification"
    raw_secret_hashes = [
        hashlib.sha256(RAW_DUMMY_SECRET_V1.encode()).hexdigest()[:12],
        hashlib.sha256(RAW_DUMMY_SECRET_V2.encode()).hexdigest()[:12],
    ]
    require(roundtrip["ok"], "user_secret_roundtrip_failed", roundtrip.get("stdout") or roundtrip.get("stderr_tail", ""), failures)
    require(fixed_alias_marker not in roundtrip.get("runner_source", ""), "fixed_user_secret_alias_in_runner", fixed_alias_marker, failures)
    require(bool(fixture_alias) and fixture_alias in output_text, "dynamic_user_secret_alias_missing", fixture_alias, failures)
    require(
        RAW_DUMMY_SECRET_V1 not in output_text and RAW_DUMMY_SECRET_V2 not in output_text,
        "raw_user_secret_in_output",
        "raw low-sensitive dummy secret appeared in output",
        failures,
    )
    require(
        not any(value in output_text for value in raw_secret_hashes),
        "user_secret_hash_in_output",
        "short secret hash appeared in output",
        failures,
    )
    steps = report.get("steps", [])
    step_names = [step.get("step") for step in steps]
    expected_steps = [
        "save_or_replace",
        "verify_stored",
        "save_or_replace",
        "verify_stored",
        "delete_stored",
        "verify_missing",
    ]
    require(step_names == expected_steps, "user_secret_steps_wrong", str(step_names), failures)
    require(report.get("account") == f"openai-compatible:{fixture_alias}", "user_secret_account_wrong", str(report.get("account")), failures)
    missing_step = steps[-1] if steps else {}
    require(missing_step.get("found") is False, "user_secret_final_missing_read_wrong", str(missing_step), failures)
    observations["user_secret_roundtrip"] = {
        "ok": report.get("ok"),
        "step_names": step_names,
        "service": report.get("service"),
        "account": report.get("account"),
        "dynamic_alias": fixture_alias,
        "fixed_alias_forbidden": fixed_alias_marker not in roundtrip.get("runner_source", ""),
        "raw_secret_output": RAW_DUMMY_SECRET_V1 in output_text or RAW_DUMMY_SECRET_V2 in output_text,
        "secret_hash_output": any(value in output_text for value in raw_secret_hashes),
    }

    observations["static_boundary"] = {
        "missing_symbols": missing_symbols,
        "forbidden_hits": forbidden_hits,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
    }

    output = {
        "ok": not failures,
        "suite": "p5k_user_secret_keychain_gate_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
