#!/usr/bin/env python3
"""P5-N unified translation service registry and routing checks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
RUNTIME = APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
STORE = APP / "Features" / "Translation" / "TranslationStore.swift"
BUILT_INS = APP / "Features" / "Translation" / "TranslationBuiltInAdapters.swift"
PLUGIN_ADAPTERS = APP / "Features" / "Translation" / "Plugins" / "TranslationPluginServiceAdapters.swift"
SETTINGS = APP / "Features" / "Settings" / "TranslationSettingsPane.swift"
AI_PROFILES = APP / "Models" / "AICapabilityProfiles.swift"
STORE_TESTS = ROOT / "apps" / "Blocks" / "BlocksAppTests" / "TranslationStoreTests.swift"


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
        "stdout": sanitize_text(completed.stdout),
        "stderr_tail": sanitize_text(completed.stderr[-1800:]),
    }


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    p5m = run(
        [
            "python3",
            "tools/verification/p5m_provider_routing_error_localization_checks.py",
            "--timeout",
            str(args.timeout),
        ],
        args.timeout,
    )
    require(
        p5m["ok"],
        "p5m_regression_failed",
        p5m["stdout"] or p5m["stderr_tail"],
        failures,
    )
    observations["p5m_regression"] = p5m["ok"]

    p5b = run(
        [
            "python3",
            "tools/verification/p5b_translation_mock_result_checks.py",
            "--timeout",
            str(args.timeout),
        ],
        args.timeout,
    )
    require(
        p5b["ok"],
        "p5b_regression_failed",
        p5b["stdout"] or p5b["stderr_tail"],
        failures,
    )
    observations["p5b_regression"] = p5b["ok"]

    for path in [
        RUNTIME,
        STORE,
        BUILT_INS,
        PLUGIN_ADAPTERS,
        SETTINGS,
        AI_PROFILES,
        STORE_TESTS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    runtime = text(RUNTIME)
    store = text(STORE)
    built_ins = text(BUILT_INS)
    plugins = text(PLUGIN_ADAPTERS)
    settings = text(SETTINGS)
    profiles = text(AI_PROFILES)
    tests = text(STORE_TESTS)
    combined = "\n".join([runtime, store, built_ins, plugins, settings, profiles])

    required_symbols = [
        "protocol TranslationServiceAdapter",
        "final class TranslationServiceRegistry",
        "func orderedAdapters(serviceIDs:",
        "maximumCount: Int = 4",
        "AppleLocalTranslationServiceAdapter",
        "OpenAICompatibleTranslationServiceAdapter",
        "TranslationPluginServiceAdapter",
        "private var builtInAdapters",
        "private var pluginAdapters",
        "replacePluginAdapters",
        "func refreshServiceRegistry()",
        "TranslationUnavailablePersistedPluginServiceAdapter",
        "removePluginService(pluginID:",
        "enabledServiceIDs",
        "moveEnabledService",
        "guard next.count < 4 else { return }",
        "LLMProviderProfile",
    ]
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(
        not missing_symbols,
        "translation_registry_contract_missing",
        ", ".join(missing_symbols),
        failures,
    )
    require(
        "TranslationProviderProfile" not in combined
        and "TranslationEngineProfile" not in combined
        and "translationEngines" not in combined,
        "legacy_translation_router_present",
        "Translation adapters must consume the unified registry and provider boundary without the retired provider/engine catalog.",
        failures,
    )
    require(
        "testEnabledComparisonGroupKeepsConfigurationOrderAndCapsAtFour" in tests
        and "testPersistedEmptyComparisonGroupRemainsEmptyAcrossRefreshAndRestart" in tests
        and "testPendingPluginServiceSurvivesStartupAndRegistryRefresh" in tests
        and "testEnabledPluginServiceSurvivesTemporaryRegistryFailureUntilExplicitRemoval" in tests
        and "testSupportedLanguagesFollowEnabledServiceCapabilities" in tests,
        "translation_registry_tests_missing",
        "Service order, four-service cap, empty-group persistence, plugin startup, and dynamic language capabilities require AppTests.",
        failures,
    )
    observations["routing"] = {
        "built_ins": ["apple-local", "openai-compatible"],
        "plugin_adapter": True,
        "maximum_enabled": 4,
        "legacy_profiles": False,
    }

    report = {
        "ok": not failures,
        "suite": "p5n_translation_engine_router_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
