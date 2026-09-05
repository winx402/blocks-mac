#!/usr/bin/env python3
"""P5-I LLM adapter boundary checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build

from current_architecture_gate_helpers import (
    method_chain_checks,
    method_chain_mutations_fail_closed,
    method_chain_overload_adversaries_fail_closed,
    swift_code_only,
    swift_declaration_block,
)


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
LLM_ADAPTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Models" / "LLMProviderAdapter.swift"
AI_MODELS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Models" / "AICapabilityProfiles.swift"
SETTINGS = APP / "Features" / "Settings" / "ProviderSettingsPane.swift"
APP_MODEL = APP / "App" / "AppModel+FeatureDelegation.swift"
PROVIDER_COORDINATOR = APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift"
PROVIDER_STORE = APP / "Features" / "Provider" / "ProviderStore.swift"
TRANSLATION_MODELS = APP / "Models" / "ProviderAuditEvent.swift"
DOC = ROOT / "docs" / "技术知识库" / "AI-Capability-Provider-Layer-v0.md"
STORY_CANDIDATES = [
    ROOT / "docs" / "项目管理库" / "实施记录" / "stories" / "p5-i-llm-adapter-boundary.md",
    ROOT / "docs" / "项目管理库" / "000_归档" / "2026-07-05_项目视图改造前" / "实施记录" / "stories" / "p5-i-llm-adapter-boundary.md",
]

LANGUAGES = ["zh-Hans", "en", "ja"]


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p5i")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5h = run(["python3", "tools/verification/p5h_ai_capability_layer_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p5h["ok"], "p5h_regression_failed", p5h["stdout"] or p5h["stderr_tail"], failures)
    observations["p5h_regression"] = p5h["ok"]

    p10a = run(["python3", "tools/verification/p10a_provider_translation_contract_checks.py"], args.timeout)
    require(p10a["ok"], "p10a_capability_contract_failed", p10a["stdout"] or p10a["stderr_tail"], failures)
    observations["p10a_capability_contract"] = p10a["ok"]

    require(LLM_ADAPTER.exists(), "llm_adapter_model_missing", str(LLM_ADAPTER), failures)
    story = first_existing(STORY_CANDIDATES)
    require(story.exists(), "p5i_story_missing", str(story), failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.llmAdapterBoundary",
        "settings.llmAdapterBoundaryNote",
        "settings.llmAdapterMockPreview",
        "settings.llmAdapterMockRun",
        "settings.llmAdapterOpenAIBlocked",
        "settings.llmAdapterPreviewCharacters",
        "llmAdapter.task.translationPreview",
        "llmAdapter.task.summaryPreview",
        "llmAdapter.output.mockSummary",
        "llmAdapter.warning.mockOnly",
        "providerAudit.kind.llmAdapterPreview",
        "providerAudit.kind.llmMockRun",
        "providerAudit.source.llmAdapterPreview",
        "providerAudit.result.llmAdapterPreview",
        "providerAudit.result.llmMockRun",
        "status.llmAdapterPreview.title",
        "status.llmAdapterPreview.detail",
        "status.llmMockRun.title",
        "status.llmMockRun.detail",
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
    ai_text = AI_MODELS.read_text(encoding="utf-8")
    settings_text = SETTINGS.read_text(encoding="utf-8")
    app_model_text = APP_MODEL.read_text(encoding="utf-8")
    coordinator_text = PROVIDER_COORDINATOR.read_text(encoding="utf-8")
    store_text = PROVIDER_STORE.read_text(encoding="utf-8")
    translation_text = TRANSLATION_MODELS.read_text(encoding="utf-8")
    llm_text = LLM_ADAPTER.read_text(encoding="utf-8") if LLM_ADAPTER.exists() else ""
    doc_text = DOC.read_text(encoding="utf-8")
    story_text = story.read_text(encoding="utf-8") if story.exists() else ""
    combined = "\n".join([project_text, ai_text, settings_text, app_model_text, coordinator_text, store_text, translation_text, llm_text, doc_text, story_text])

    required_symbols = [
        "LLMProviderAdapter.swift",
        "LLMProviderAdapter",
        "LLMProviderRequest",
        "LLMProviderResponse",
        "LLMProviderError",
        "LLMProviderTask",
        "LLMProviderOutputFormat",
        "OpenAICompatibleProfileBoundary",
        "LLMProviderMockAdapter",
        "makePreview",
        "runMock",
        "llmAdapterPreview",
        "llmMockRun",
        "previewLLMAdapterBoundary",
        "runLLMMockAdapter",
        "status.llmAdapterPreview.title",
        "status.llmMockRun.title",
        "external_transfer",
        "OpenAI-compatible",
        "llm-openai-compatible-placeholder",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "llm_adapter_symbols_missing", ", ".join(missing_symbols), failures)

    chain_sources = {"app_model": app_model_text, "coordinator": coordinator_text}
    chain_specs = {
        "app_model_llm_preview_to_coordinator": (
            "app_model",
            "extension AppModel",
            "func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String)",
            [
                "providerCoordinator.previewLLMAdapterBoundary(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
            ],
            ["providerStore.previewLLMAdapterBoundary"],
        ),
        "coordinator_llm_preview_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String)",
            [
                "providerStore.previewLLMAdapterBoundary(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
            ],
            [],
        ),
        "app_model_llm_mock_to_coordinator": (
            "app_model",
            "extension AppModel",
            "func runLLMMockAdapter()",
            ["providerCoordinator.runLLMMockAdapter()"],
            ["providerStore.runLLMMockAdapter"],
        ),
        "coordinator_llm_mock_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func runLLMMockAdapter()",
            ["providerStore.runLLMMockAdapter()"],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("app_model_llm_preview_to_coordinator", "app_model", "providerCoordinator.previewLLMAdapterBoundary(", "_ = ("),
            ("coordinator_llm_preview_to_store", "coordinator", "providerStore.previewLLMAdapterBoundary(", "_ = ("),
            ("app_model_llm_mock_to_coordinator", "app_model", "providerCoordinator.runLLMMockAdapter()", "()"),
            ("coordinator_llm_mock_to_store", "coordinator", "providerStore.runLLMMockAdapter()", "\"none\""),
        ],
    )
    argument_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "app_model_llm_preview_to_coordinator",
                "app_model",
                "keychainAccountAlias: keychainAccountAlias",
                'keychainAccountAlias: ""',
            ),
            (
                "coordinator_llm_preview_to_store",
                "coordinator",
                "keychainAccountAlias: keychainAccountAlias",
                'keychainAccountAlias: ""',
            ),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "llm_preview_target_noop_overload_forwards",
                "coordinator_llm_preview_to_store",
                "func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String, overloadProbe: Bool)",
                """
func previewLLMAdapterBoundary(baseURL: String, modelName: String, keychainAccountAlias: String, overloadProbe: Bool) {
    _ = providerStore.previewLLMAdapterBoundary(
        baseURL: baseURL,
        modelName: modelName,
        keychainAccountAlias: keychainAccountAlias
    )
}
""",
                "providerStore.previewLLMAdapterBoundary(",
                "_ = (",
            ),
            (
                "llm_mock_target_noop_overload_forwards",
                "coordinator_llm_mock_to_store",
                "func runLLMMockAdapter(overloadProbe: Bool)",
                """
func runLLMMockAdapter(overloadProbe: Bool) {
    _ = providerStore.runLLMMockAdapter()
}
""",
                "providerStore.runLLMMockAdapter()",
                "_ = ()",
            ),
        ],
    )
    require(all(chain_checks.values()), "llm_adapter_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "llm_adapter_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(argument_mutations.values()), "llm_adapter_argument_mutation_not_fail_closed", str(argument_mutations), failures)
    require(all(chain_overload_adversaries.values()), "llm_adapter_chain_overload_bypass", str(chain_overload_adversaries), failures)

    forbidden_hits = [
        needle
        for needle in [
            "URLSession",
            "Process(",
            "getenv(",
            "SecItemCopyMatching",
            "rawProviderOutput",
            "providerRawOutput",
            "NSPasteboard.general",
            "VNRecognizeTextRequest",
            "codex exec",
        ]
        if needle in "\n".join([settings_text, app_model_text, coordinator_text, store_text, translation_text, llm_text, ai_text])
    ]
    require(not forbidden_hits, "forbidden_runtime_or_secret_input_found", ", ".join(forbidden_hits), failures)

    redaction_failures = [
        needle
        for needle in [
            "rawText",
            "sourceText",
            "fullPrompt",
            "messages",
            "apiKeyValue",
            "Authorization",
            "Bearer ",
        ]
        if needle in "\n".join([llm_text, app_model_text, coordinator_text, store_text, settings_text])
    ]
    require(not redaction_failures, "unredacted_provider_surface_found", ", ".join(redaction_failures), failures)
    settings_content = swift_declaration_block(settings_text, "private var content: some View")
    settings_code = swift_code_only(settings_content)
    current_settings_entry = {
        "provider_profiles": "ForEach(providerStore.llmProviderProfiles)" in settings_code,
        "provider_readiness": "providerConnectionReadiness" in settings_code,
        "connection_gate_action": "appModel.validateProviderConnectionGate(" in settings_code,
        "secret_confirmation_gate": ".disabled(!canStoreProviderUserSecret)" in settings_code,
    }
    require(all(current_settings_entry.values()), "current_provider_settings_entry_missing", str(current_settings_entry), failures)
    superseded_legacy_ui_keys = [
        "settings.llmAdapterBoundary",
        "settings.llmAdapterBoundaryNote",
        "settings.llmAdapterOpenAIBlocked",
    ]
    observations["static_boundary"] = {
        "missing_symbols": missing_symbols,
        "forbidden_hits": forbidden_hits,
        "redaction_failures": redaction_failures,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "argument_mutations_fail_closed": argument_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
        "current_provider_settings_entry": current_settings_entry,
        "legacy_ui_contract": {
            "status": "superseded",
            "keys": superseded_legacy_ui_keys,
            "replacement": "ProviderSettingsPane + ProviderFeatureCoordinator + P10A capability contract",
            "localization_retained": all(key not in missing for key in superseded_legacy_ui_keys),
        },
    }

    output = {
        "ok": not failures,
        "suite": "p5i_llm_adapter_boundary_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
