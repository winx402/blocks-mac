#!/usr/bin/env python3
"""P5-J API key input and OpenAI connection gate checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build

from current_architecture_gate_helpers import (
    exact_method_block,
    method_chain_checks,
    method_chain_mutations_fail_closed,
    method_chain_overload_adversaries_fail_closed,
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
DOC = ROOT / "docs" / "技术知识库" / "Provider-Secret-Handling-v0.md"
STORY_CANDIDATES = [
    ROOT / "docs" / "项目管理库" / "实施记录" / "stories" / "p5-j-api-key-connection-gate.md",
    ROOT / "docs" / "项目管理库" / "000_归档" / "2026-07-05_项目视图改造前" / "实施记录" / "stories" / "p5-j-api-key-connection-gate.md",
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

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p5j")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5i = run(["python3", "tools/verification/p5i_llm_adapter_boundary_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p5i["ok"], "p5i_regression_failed", p5i["stdout"] or p5i["stderr_tail"], failures)
    observations["p5i_regression"] = p5i["ok"]

    story = first_existing(STORY_CANDIDATES)
    require(story.exists(), "p5j_story_missing", str(story), failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.providerSecretInputGate",
        "settings.providerSecretInputGateNote",
        "settings.providerSecretCandidate",
        "settings.providerSecretCandidatePlaceholder",
        "settings.providerSecretPreviewSave",
        "settings.providerSecretDiscard",
        "settings.providerSecretStoredBlocked",
        "settings.openAIConnectionPreview",
        "settings.openAIConnectionPreviewNote",
        "settings.openAIConnectionPreviewRun",
        "providerAudit.kind.secretInputPreview",
        "providerAudit.kind.openAIConnectionPreview",
        "providerAudit.source.secretInputPreview",
        "providerAudit.result.secretInputPreview",
        "providerAudit.source.openAIConnectionPreview",
        "providerAudit.result.openAIConnectionPreview",
        "providerAudit.warning.noSecretStored",
        "providerAudit.warning.noNetworkCall",
        "status.providerSecretInputPreview.title",
        "status.providerSecretInputPreview.detail",
        "status.openAIConnectionPreview.title",
        "status.openAIConnectionPreview.detail",
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
    llm_text = LLM_ADAPTER.read_text(encoding="utf-8")
    doc_text = DOC.read_text(encoding="utf-8")
    story_text = story.read_text(encoding="utf-8") if story.exists() else ""
    combined = "\n".join([project_text, ai_text, settings_text, app_model_text, coordinator_text, store_text, translation_text, llm_text, doc_text, story_text])

    required_symbols = [
        "ProviderSecretInputPreview",
        "OpenAIConnectionPreviewDraft",
        "makeSecretInputPreview",
        "makeConnectionPreview",
        "previewProviderSecretInput",
        "previewOpenAIConnection",
        "secretInputPreview",
        "openAIConnectionPreview",
        "SecureField",
        "secretCandidate",
        "settings.providerSecretInputGate",
        "providerUserSecretStoreConfirmed",
        ".disabled(!canStoreProviderUserSecret)",
        "settings.openAIConnectionPreview",
        "providerAudit.result.openAIConnectionPreview",
        "external_transfer",
        "POST /v1/chat/completions",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "p5j_symbols_missing", ", ".join(missing_symbols), failures)

    chain_sources = {"app_model": app_model_text, "coordinator": coordinator_text}
    chain_specs = {
        "app_model_secret_preview_to_coordinator": (
            "app_model",
            "extension AppModel",
            "func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String)",
            [
                "providerCoordinator.previewProviderSecretInput(",
                "secretCharacterCount: secretCharacterCount",
                "keychainAccountAlias: keychainAccountAlias",
            ],
            ["providerStore.previewProviderSecretInput"],
        ),
        "coordinator_secret_preview_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String)",
            [
                "providerStore.previewProviderSecretInput(",
                "secretCharacterCount: secretCharacterCount",
                "keychainAccountAlias: keychainAccountAlias",
            ],
            [],
        ),
        "app_model_connection_preview_to_coordinator": (
            "app_model",
            "extension AppModel",
            "func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String) -> String",
            [
                "providerCoordinator.previewOpenAIConnection(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
            ],
            ["providerStore.previewOpenAIConnection"],
        ),
        "coordinator_connection_preview_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String) -> String",
            [
                "providerStore.previewOpenAIConnection(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
            ],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("app_model_secret_preview_to_coordinator", "app_model", "providerCoordinator.previewProviderSecretInput(", "_ = ("),
            ("coordinator_secret_preview_to_store", "coordinator", "providerStore.previewProviderSecretInput(", "_ = ("),
            ("app_model_connection_preview_to_coordinator", "app_model", "providerCoordinator.previewOpenAIConnection(", "_ = ("),
            ("coordinator_connection_preview_to_store", "coordinator", "providerStore.previewOpenAIConnection(", "_ = ("),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "secret_preview_target_noop_overload_forwards",
                "coordinator_secret_preview_to_store",
                "func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String, overloadProbe: Bool)",
                """
func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String, overloadProbe: Bool) {
    _ = providerStore.previewProviderSecretInput(
        secretCharacterCount: secretCharacterCount,
        keychainAccountAlias: keychainAccountAlias
    )
}
""",
                "providerStore.previewProviderSecretInput(",
                "_ = (",
            ),
            (
                "connection_preview_target_noop_overload_forwards",
                "coordinator_connection_preview_to_store",
                "func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String, overloadProbe: Bool)",
                """
func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String, overloadProbe: Bool) {
    _ = providerStore.previewOpenAIConnection(
        baseURL: baseURL,
        modelName: modelName,
        keychainAccountAlias: keychainAccountAlias
    )
}
""",
                "providerStore.previewOpenAIConnection(",
                "_ = (",
            ),
        ],
    )
    require(all(chain_checks.values()), "provider_preview_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "provider_preview_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(chain_overload_adversaries.values()), "provider_preview_chain_overload_bypass", str(chain_overload_adversaries), failures)

    preview_store_text = "\n".join([
        exact_method_block(
            store_text,
            "final class ProviderStore",
            "func previewProviderSecretInput(secretCharacterCount: Int, keychainAccountAlias: String) -> String",
        ),
        exact_method_block(
            store_text,
            "final class ProviderStore",
            "func previewOpenAIConnection(baseURL: String, modelName: String, keychainAccountAlias: String) -> String",
        ),
    ])
    scanned_runtime_text = "\n".join([settings_text, app_model_text, coordinator_text, preview_store_text, translation_text, llm_text, ai_text])
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
        if needle in scanned_runtime_text
    ]
    require(not forbidden_hits, "forbidden_runtime_or_secret_input_found", ", ".join(forbidden_hits), failures)

    redaction_failures = [
        needle
        for needle in [
            "rawSecret",
            "secretValue",
            "candidateValue",
            "fullPrompt",
            "messages",
            "apiKeyValue",
            "Authorization",
            "Bearer ",
        ]
        if needle in "\n".join([llm_text, app_model_text, coordinator_text, preview_store_text, settings_text])
    ]
    require(not redaction_failures, "unredacted_provider_surface_found", ", ".join(redaction_failures), failures)
    observations["static_boundary"] = {
        "missing_symbols": missing_symbols,
        "forbidden_hits": forbidden_hits,
        "redaction_failures": redaction_failures,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
    }

    output = {
        "ok": not failures,
        "suite": "p5j_api_key_connection_gate_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
