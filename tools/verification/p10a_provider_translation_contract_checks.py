#!/usr/bin/env python3
"""P10-A provider routing and unified translation-adapter contract checks."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
L10N = ROOT / "apps/Blocks/BlocksApp/Support/L10n.swift"
AI_PROFILES = ROOT / "apps/Blocks/BlocksApp/Models/AICapabilityProfiles.swift"
PROVIDER_ROUTING = ROOT / "apps/Blocks/BlocksApp/Models/ProviderRouting.swift"
KEYCHAIN_SERVICE = ROOT / "apps/Blocks/BlocksApp/Services/ProviderKeychainService.swift"
CONNECTION_SERVICE = ROOT / "apps/Blocks/BlocksApp/Services/OpenAICompatibleConnectionService.swift"
TRANSLATION_ADAPTERS = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationBuiltInAdapters.swift"
TRANSLATION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift"


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
        "stderr_tail": completed.stderr[-2400:],
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def parse_json(value: str) -> dict[str, Any] | None:
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return None


def compile_and_run_runner(timeout: int) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="blocks-p10a-") as tmp:
        tmp_path = Path(tmp)
        runner = tmp_path / "P10AProviderContractRunner.swift"
        executable = tmp_path / "P10AProviderContractRunner"
        runner.write_text(
            """
import Darwin
import Foundation

@main
struct P10AProviderContractRunner {
    static func runtimeRequest(
        profile: AICapabilityProfile,
        configured: Bool,
        keychainAccountAlias: String = "p10a-alias",
        externalTransferConfirmed: Bool = true
    ) -> ProviderRouteRequest {
        ProviderRouteRequest(
            capability: profile.domain,
            profileID: profile.id,
            executionMode: profile.executionMode,
            providerSummary: profile.localizedSummary,
            configured: configured,
            implemented: true,
            localOnly: profile.localOnly,
            requiresKeychainSecret: profile.requiresKeychainSecret,
            requiresExternalTransfer: profile.requiresExternalTransfer,
            keychainAccountAlias: keychainAccountAlias,
            externalTransferConfirmed: externalTransferConfirmed
        )
    }

    static func routeJSON(_ route: ProviderRouteResolution) -> [String: Any] {
        [
            "ok": route.ok,
            "capability": route.capability.rawValue,
            "execution_mode": route.executionMode.rawValue,
            "confirmation_level": route.confirmationLevel,
            "error_code": route.errorCode?.rawValue ?? "none"
        ]
    }

    static func main() throws {
        let catalog = AICapabilityCatalog.defaults()
        let router = ProviderRouter()
        let localMock = catalog.llmProviders.first {
            $0.base.executionMode == .localMock
        }!.base
        let openAI = catalog.llmProviders.first {
            $0.base.executionMode == .openAICompatible
        }!.base
        let localCLI = catalog.llmProviders.first {
            $0.base.executionMode == .localCLI
        }!.base

        let routes: [String: ProviderRouteResolution] = [
            "local_mock": router.resolve(ProviderRouteRequest(profile: localMock)),
            "openai_missing_configuration": router.resolve(
                runtimeRequest(profile: openAI, configured: false)
            ),
            "openai_missing_secret": router.resolve(
                runtimeRequest(
                    profile: openAI,
                    configured: true,
                    keychainAccountAlias: ""
                )
            ),
            "openai_confirmation_required": router.resolve(
                runtimeRequest(
                    profile: openAI,
                    configured: true,
                    externalTransferConfirmed: false
                )
            ),
            "openai_ready": router.resolve(
                runtimeRequest(profile: openAI, configured: true)
            ),
            "local_cli_unsupported": router.resolve(
                runtimeRequest(profile: localCLI, configured: true)
            )
        ]

        let gates: [String: ProviderRuntimeGateResult] = [
            "confirmation_required": ProviderRuntimeGate.validateOpenAICompatible(
                baseURL: "https://example.test",
                modelName: "model",
                keychainAccountAlias: "alias",
                externalTransferConfirmed: false
            ),
            "missing_secret": ProviderRuntimeGate.validateOpenAICompatible(
                baseURL: "https://example.test",
                modelName: "model",
                keychainAccountAlias: "",
                externalTransferConfirmed: true
            ),
            "invalid_url": ProviderRuntimeGate.validateOpenAICompatible(
                baseURL: "http://example.test",
                modelName: "model",
                keychainAccountAlias: "alias",
                externalTransferConfirmed: true
            ),
            "loopback_ready": ProviderRuntimeGate.validateOpenAICompatible(
                baseURL: "http://127.0.0.1:11434/v1",
                modelName: "model",
                keychainAccountAlias: "alias",
                externalTransferConfirmed: true
            ),
            "https_ready": ProviderRuntimeGate.validateOpenAICompatible(
                baseURL: "https://example.test/v1",
                modelName: "model",
                keychainAccountAlias: "alias",
                externalTransferConfirmed: true
            )
        ]

        let payload: [String: Any] = [
            "routes": routes.mapValues(routeJSON),
            "runtime_gate": gates.mapValues {
                [
                    "ready": $0.ready,
                    "error_code": $0.errorCode?.rawValue ?? "none"
                ] as [String: Any]
            }
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\\n".utf8))

        let ok = routes["local_mock"]?.ok == true
            && routes["openai_missing_configuration"]?.errorCode == .missingConfiguration
            && routes["openai_missing_secret"]?.errorCode == .missingSecret
            && routes["openai_confirmation_required"]?.errorCode == .confirmationRequired
            && routes["openai_ready"]?.ok == true
            && routes["openai_ready"]?.confirmationLevel == "external_transfer"
            && routes["local_cli_unsupported"]?.errorCode == .unsupportedCapability
            && gates["confirmation_required"]?.errorCode == .confirmationRequired
            && gates["missing_secret"]?.errorCode == .missingSecret
            && gates["invalid_url"]?.errorCode == .invalidBaseURL
            && gates["loopback_ready"]?.ready == true
            && gates["https_ready"]?.ready == true
        Darwin.exit(ok ? 0 : 1)
    }
}
""",
            encoding="utf-8",
        )
        compile_result = run(
            [
                "xcrun",
                "swiftc",
                str(L10N),
                str(AI_PROFILES),
                str(KEYCHAIN_SERVICE),
                str(CONNECTION_SERVICE),
                str(PROVIDER_ROUTING),
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
        run_result = run([str(executable)], timeout)
        parsed = parse_json(run_result["stdout"])
        return {
            "ok": run_result["ok"] and parsed is not None,
            "stage": "run",
            "stdout": run_result["stdout"],
            "stderr_tail": run_result["stderr_tail"],
            "report": parsed,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}
    required_files = [
        L10N,
        AI_PROFILES,
        PROVIDER_ROUTING,
        KEYCHAIN_SERVICE,
        CONNECTION_SERVICE,
        TRANSLATION_ADAPTERS,
        TRANSLATION_STORE,
    ]
    for path in required_files:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    routing = PROVIDER_ROUTING.read_text(encoding="utf-8") if PROVIDER_ROUTING.exists() else ""
    adapter = TRANSLATION_ADAPTERS.read_text(encoding="utf-8") if TRANSLATION_ADAPTERS.exists() else ""
    store = TRANSLATION_STORE.read_text(encoding="utf-8") if TRANSLATION_STORE.exists() else ""
    profiles = AI_PROFILES.read_text(encoding="utf-8") if AI_PROFILES.exists() else ""

    forbidden_router_hits = [
        needle
        for needle in [
            "URLSession",
            "SecItem",
            "Process(",
            "getenv(",
            "Authorization",
            "Bearer ",
            "rawProviderOutput",
            "providerRawOutput",
        ]
        if needle in routing
    ]
    require(
        not forbidden_router_hits,
        "provider_router_side_effect_token",
        ", ".join(forbidden_router_hits),
        failures,
    )

    unified_symbols = [
        "final class OpenAICompatibleTranslationServiceAdapter",
        "ProviderRuntimeGate.validateOpenAICompatible",
        "OpenAITranslationRuntimeService",
    ]
    missing_adapter_symbols = [
        symbol for symbol in unified_symbols if symbol not in adapter
    ]
    require(
        not missing_adapter_symbols,
        "unified_translation_adapter_missing",
        ", ".join(missing_adapter_symbols),
        failures,
    )
    require(
        "OpenAICompatibleTranslationServiceAdapter(" in store
        and "AppleLocalTranslationServiceAdapter(" in store,
        "translation_store_registry_missing_builtins",
        "TranslationStore must register Apple local and OpenAI-compatible adapters.",
        failures,
    )
    require(
        "TranslationEngineProfile" not in profiles
        and "translationEngines" not in profiles,
        "legacy_translation_engine_catalog_restored",
        "Provider profiles must not recreate a second translation runtime catalog.",
        failures,
    )

    runner = compile_and_run_runner(args.timeout) if not failures else {
        "ok": False,
        "stage": "skipped",
    }
    require(
        runner["ok"],
        "contract_runner_failed",
        runner.get("stdout") or runner.get("stderr_tail", ""),
        failures,
    )
    observations["runner"] = {
        "ok": runner["ok"],
        "stage": runner.get("stage"),
        "report": runner.get("report"),
    }

    output = {
        "ok": not failures,
        "suite": "p10a_provider_translation_contract_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
