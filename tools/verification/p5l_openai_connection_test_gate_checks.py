#!/usr/bin/env python3
"""P5-L OpenAI-compatible test connection gate checks for Blocks."""

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
L10N = APP / "Support" / "L10n.swift"
AI_PROFILES = APP / "Models" / "AICapabilityProfiles.swift"
SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ProviderKeychainService.swift"
CONNECTION_SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "OpenAICompatibleConnectionService.swift"
PROVIDER_ROUTING = APP / "Models" / "ProviderRouting.swift"
SETTINGS = APP / "Features" / "Settings" / "ProviderSettingsPane.swift"
APP_MODEL = APP / "App" / "AppModel+FeatureDelegation.swift"
PROVIDER_COORDINATOR = APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift"
PROVIDER_STORE = APP / "Features" / "Provider" / "ProviderStore.swift"
TRANSLATION_MODELS = APP / "Models" / "ProviderAuditEvent.swift"
ENTITLEMENTS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Blocks.entitlements"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
DOC = ROOT / "docs" / "技术知识库" / "Provider-Secret-Handling-v0.md"
AI_DOC = ROOT / "docs" / "技术知识库" / "AI-Capability-Provider-Layer-v0.md"
STORY_CANDIDATES = [
    ROOT / "docs" / "项目管理库" / "实施记录" / "stories" / "p5-l-openai-compatible-test-connection-gate.md",
    ROOT / "docs" / "项目管理库" / "000_归档" / "2026-07-05_项目视图改造前" / "实施记录" / "stories" / "p5-l-openai-compatible-test-connection-gate.md",
]

LANGUAGES = ["zh-Hans", "en", "ja"]
RAW_DUMMY_SECRET = "blocks-p5l-low-sensitive-dummy-secret"


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


def compile_and_run_connection_runner(timeout: int) -> dict[str, Any]:
    fixture_alias = f"blocks-p5l-{uuid.uuid4()}"
    with tempfile.TemporaryDirectory(prefix="blocks-p5l-") as tmp:
        tmp_path = Path(tmp)
        runner = tmp_path / "P5LOpenAIConnectionRunner.swift"
        executable = tmp_path / "P5LOpenAIConnectionRunner"
        runner_source = f"""
import Darwin
import Foundation

struct P5LRunnerReport: Codable {{
    let fixtureAlias: String
    let account: String
    let results: [String: OpenAIConnectionTestResult]
}}

struct P5LMockTransport: OpenAIConnectionTransport {{
    let statusCode: Int
    let body: String
    let headerRequestID: String?
    let error: URLError?

    func perform(_ request: URLRequest, timeoutSeconds: Int) async throws -> OpenAIConnectionTransportResponse {{
        if let error {{
            throw error
        }}
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerRequestID.map {{ ["x-request-id": $0] }} ?? [:]
        )!
        return OpenAIConnectionTransportResponse(
            httpResponse: response,
            data: Data(body.utf8)
        )
    }}
}}

@main
struct P5LOpenAIConnectionRunner {{
    static func main() async throws {{
        guard CommandLine.arguments.count == 2 else {{
            Darwin.exit(2)
        }}
        let keychain = ProviderKeychainService()
        let alias = CommandLine.arguments[1]
        defer {{
            _ = try? keychain.performUserSecret(action: .deleteStored, alias: alias)
        }}
        _ = try keychain.performUserSecret(
            action: .saveOrReplace,
            alias: alias,
            secret: "{RAW_DUMMY_SECRET}"
        )

        let material = try keychain.readUserSecretForProviderCall(alias: alias)
        let profile = OpenAIConnectionTestProfile(
            providerName: "OpenAI-compatible",
            baseURL: "https://example.invalid/v1",
            modelName: "p5l-model",
            keychainAccountAlias: alias,
            timeoutSeconds: 12
        )

        let success = await OpenAICompatibleConnectionService(
            transport: P5LMockTransport(
                statusCode: 200,
                body: #"{{"choices":[{{"message":{{"content":"pong"}}}}]}}"#,
                headerRequestID: "req_p5l_success",
                error: nil
            )
        ).testConnection(profile: profile, secretMaterial: material)

        let unauthorized = await OpenAICompatibleConnectionService(
            transport: P5LMockTransport(
                statusCode: 401,
                body: #"{{"error":{{"message":"unauthorized"}}}}"#,
                headerRequestID: "req_p5l_401",
                error: nil
            )
        ).testConnection(profile: profile, secretMaterial: material)

        let invalidResponse = await OpenAICompatibleConnectionService(
            transport: P5LMockTransport(
                statusCode: 200,
                body: #"{{"choices":[]}}"#,
                headerRequestID: nil,
                error: nil
            )
        ).testConnection(profile: profile, secretMaterial: material)

        let timeout = await OpenAICompatibleConnectionService(
            transport: P5LMockTransport(
                statusCode: 200,
                body: #"{{}}"#,
                headerRequestID: nil,
                error: URLError(.timedOut)
            )
        ).testConnection(profile: profile, secretMaterial: material)

        let invalidBaseURL = await OpenAICompatibleConnectionService(
            transport: P5LMockTransport(statusCode: 200, body: #"{{}}"#, headerRequestID: nil, error: nil)
        ).testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "OpenAI-compatible",
                baseURL: "not a url",
                modelName: "p5l-model",
                keychainAccountAlias: alias,
                timeoutSeconds: 12
            ),
            secretMaterial: material
        )

        let report = P5LRunnerReport(
            fixtureAlias: alias,
            account: material.redactedResult.account,
            results: [
                "success": success,
                "unauthorized": unauthorized,
                "invalid_response": invalidResponse,
                "timeout": timeout,
                "invalid_base_url": invalidBaseURL
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\\n".utf8))
        Darwin.exit(success.ok && !unauthorized.ok && !invalidResponse.ok && !timeout.ok && !invalidBaseURL.ok ? 0 : 1)
    }}
}}
"""
        runner.write_text(runner_source, encoding="utf-8")
        compile_result = run(
            [
                "xcrun",
                "swiftc",
                str(L10N),
                str(AI_PROFILES),
                str(SERVICE),
                str(PROVIDER_ROUTING),
                str(CONNECTION_SERVICE),
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

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p5l")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    story = first_existing(STORY_CANDIDATES)
    require(story.exists(), "p5l_story_missing", str(story), failures)
    require(CONNECTION_SERVICE.exists(), "openai_connection_service_missing", str(CONNECTION_SERVICE), failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.openAITestConnectionGate",
        "settings.openAITestConnectionGateNote",
        "settings.openAITestConnectionConfirmExternalTransfer",
        "settings.openAITestConnectionRun",
        "settings.openAITestConnectionUnavailable",
        "settings.openAITestConnectionLastResult",
        "providerAudit.kind.openAIConnectionTest",
        "providerAudit.source.openAIConnectionTest",
        "providerAudit.result.openAIConnectionTest",
        "providerAudit.warning.externalTransferConfirmed",
        "providerAudit.warning.liveProviderTest",
        "status.openAIConnectionTest.title",
        "status.openAIConnectionTest.detail",
    ]
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in LANGUAGES)
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    service_text = SERVICE.read_text(encoding="utf-8")
    connection_text = CONNECTION_SERVICE.read_text(encoding="utf-8") if CONNECTION_SERVICE.exists() else ""
    settings_text = SETTINGS.read_text(encoding="utf-8")
    app_model_text = APP_MODEL.read_text(encoding="utf-8")
    coordinator_text = PROVIDER_COORDINATOR.read_text(encoding="utf-8")
    store_text = PROVIDER_STORE.read_text(encoding="utf-8")
    translation_text = TRANSLATION_MODELS.read_text(encoding="utf-8")
    project_text = PROJECT.read_text(encoding="utf-8")
    entitlements_text = ENTITLEMENTS.read_text(encoding="utf-8")
    doc_text = DOC.read_text(encoding="utf-8")
    ai_doc_text = AI_DOC.read_text(encoding="utf-8")
    story_text = story.read_text(encoding="utf-8") if story.exists() else ""
    combined = "\n".join([
        service_text,
        connection_text,
        settings_text,
        app_model_text,
        coordinator_text,
        store_text,
        translation_text,
        project_text,
        entitlements_text,
        doc_text,
        ai_doc_text,
        story_text,
    ])

    required_symbols = [
        "ProviderUserSecretMaterial",
        "readUserSecretForProviderCall(alias:",
        "OpenAIConnectionTransport",
        "URLSessionOpenAIConnectionTransport",
        "OpenAIConnectionTestProfile",
        "OpenAIConnectionTestResult",
        "OpenAICompatibleConnectionService",
        "testConnection(profile:",
        "openAIConnectionTest",
        "runOpenAIConnectionTest(",
        "settings.openAITestConnectionGate",
        "settings.openAITestConnectionRun",
        "com.apple.security.network.client",
        "OpenAICompatibleConnectionService.swift",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "p5l_symbols_missing", ", ".join(missing_symbols), failures)

    chain_sources = {
        "app_model": app_model_text,
        "coordinator": coordinator_text,
        "store": store_text,
    }
    run_signature = (
        "func runOpenAIConnectionTest(baseURL: String, modelName: String, "
        "keychainAccountAlias: String, externalTransferConfirmed: Bool) async"
    )
    chain_specs = {
        "app_model_connection_test_to_coordinator": (
            "app_model",
            "extension AppModel",
            run_signature,
            [
                "await providerCoordinator.runOpenAIConnectionTest(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
                "externalTransferConfirmed: externalTransferConfirmed",
            ],
            ["providerStore.runOpenAIConnectionTest"],
        ),
        "coordinator_connection_test_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            run_signature,
            [
                "await providerStore.runOpenAIConnectionTest(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
                "externalTransferConfirmed: externalTransferConfirmed",
            ],
            [],
        ),
        "store_connection_test_runtime_boundary": (
            "store",
            "final class ProviderStore",
            run_signature + " -> OpenAIConnectionTestResult",
            [
                "ProviderRuntimeGate.validateOpenAICompatible(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
                "externalTransferConfirmed: externalTransferConfirmed",
                "providerKeychainService.readUserSecretForProviderCall(alias: keychainAccountAlias)",
                "openAIConnectionService.testConnection(profile: profile, secretMaterial: material)",
            ],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("app_model_connection_test_to_coordinator", "app_model", "await providerCoordinator.runOpenAIConnectionTest(", "_ = ("),
            ("coordinator_connection_test_to_store", "coordinator", "await providerStore.runOpenAIConnectionTest(", "_ = ("),
            ("store_connection_test_runtime_boundary", "store", "ProviderRuntimeGate.validateOpenAICompatible(", "ProviderRuntimeGate.noOp("),
        ],
    )
    argument_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "app_model_connection_test_to_coordinator",
                "app_model",
                "externalTransferConfirmed: externalTransferConfirmed",
                "externalTransferConfirmed: true",
            ),
            (
                "coordinator_connection_test_to_store",
                "coordinator",
                "externalTransferConfirmed: externalTransferConfirmed",
                "externalTransferConfirmed: false",
            ),
            (
                "store_connection_test_runtime_boundary",
                "store",
                "externalTransferConfirmed: externalTransferConfirmed",
                "externalTransferConfirmed: true",
            ),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "connection_test_target_noop_overload_forwards",
                "coordinator_connection_test_to_store",
                "func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, externalTransferConfirmed: Bool, overloadProbe: Bool) async",
                """
func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, externalTransferConfirmed: Bool, overloadProbe: Bool) async {
    _ = await providerStore.runOpenAIConnectionTest(
        baseURL: baseURL,
        modelName: modelName,
        keychainAccountAlias: keychainAccountAlias,
        externalTransferConfirmed: externalTransferConfirmed
    )
}
""",
                "await providerStore.runOpenAIConnectionTest(",
                "_ = (",
            ),
        ],
    )
    require(all(chain_checks.values()), "openai_connection_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "openai_connection_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(argument_mutations.values()), "openai_connection_argument_mutation_not_fail_closed", str(argument_mutations), failures)
    require(all(chain_overload_adversaries.values()), "openai_connection_chain_overload_bypass", str(chain_overload_adversaries), failures)

    forbidden_surface_hits = [
        needle
        for needle in [
            "URLSession",
            "SecItemCopyMatching",
            "rawProviderOutput",
            "providerRawOutput",
            "rawResponseBody",
            "fullProviderResponse",
            "apiKeyValue",
            "secretValue",
            "Authorization",
            "Bearer ",
            "getenv(",
            "Process(",
            "codex exec",
            "NSPasteboard.general",
            "VNRecognizeTextRequest",
        ]
        if needle in "\n".join([settings_text, app_model_text, coordinator_text, translation_text])
    ]
    require(not forbidden_surface_hits, "forbidden_ui_or_appstate_surface_found", ", ".join(forbidden_surface_hits), failures)

    runner = compile_and_run_connection_runner(args.timeout)
    report = runner.get("report") or {}
    result_report = report.get("results", {}) if isinstance(report, dict) else {}
    output_text = runner.get("stdout", "")
    fixture_alias = runner.get("fixture_alias", "")
    fixed_alias_marker = "p5l" + "-verification"
    raw_secret_hash = hashlib.sha256(RAW_DUMMY_SECRET.encode()).hexdigest()[:12]
    require(runner["ok"], "connection_runner_failed", runner.get("stdout") or runner.get("stderr_tail", ""), failures)
    require(fixed_alias_marker not in runner.get("runner_source", ""), "fixed_connection_alias_in_runner", fixed_alias_marker, failures)
    require(report.get("fixtureAlias") == fixture_alias, "dynamic_connection_alias_wrong", str(report.get("fixtureAlias")), failures)
    require(report.get("account") == f"openai-compatible:{fixture_alias}", "dynamic_connection_account_wrong", str(report.get("account")), failures)
    require(RAW_DUMMY_SECRET not in output_text, "raw_dummy_secret_in_output", "raw dummy secret appeared in output", failures)
    require(raw_secret_hash not in output_text, "dummy_secret_hash_in_output", "dummy secret hash appeared in output", failures)
    require("Authorization" not in output_text and "Bearer" not in output_text, "auth_header_in_output", "auth header appeared in output", failures)

    expected_status = {
        "success": ("success", True),
        "unauthorized": ("unauthorized", False),
        "invalid_response": ("invalid_response", False),
        "timeout": ("timeout", False),
        "invalid_base_url": ("invalid_base_url", False),
    }
    observed_status = {
        name: (value.get("status"), value.get("ok"))
        for name, value in result_report.items()
        if isinstance(value, dict)
    }
    require(observed_status == expected_status, "connection_statuses_wrong", str(observed_status), failures)
    success = result_report.get("success", {}) if isinstance(result_report.get("success"), dict) else {}
    require(success.get("http_status_code") == 200, "success_http_status_wrong", str(success), failures)
    require(success.get("response_text_character_count") == 4, "success_response_count_wrong", str(success), failures)
    require(success.get("request_id") == "req_p5l_success", "success_request_id_wrong", str(success), failures)
    require(success.get("secret_length") == len(RAW_DUMMY_SECRET), "secret_length_wrong", str(success), failures)

    observations["connection_runner"] = {
        "ok": runner["ok"],
        "stage": runner.get("stage"),
        "observed_status": observed_status,
        "raw_secret_output": RAW_DUMMY_SECRET in output_text,
        "secret_hash_output": raw_secret_hash in output_text,
        "dynamic_alias": fixture_alias,
        "account": report.get("account"),
        "fixed_alias_forbidden": fixed_alias_marker not in runner.get("runner_source", ""),
    }
    observations["static_boundary"] = {
        "missing_symbols": missing_symbols,
        "forbidden_surface_hits": forbidden_surface_hits,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "argument_mutations_fail_closed": argument_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
    }

    output = {
        "ok": not failures,
        "suite": "p5l_openai_connection_test_gate_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
