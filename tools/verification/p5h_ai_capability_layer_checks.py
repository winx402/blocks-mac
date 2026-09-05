#!/usr/bin/env python3
"""P5-H AI capability provider layer checks for Blocks."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
AI_MODELS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Models" / "AICapabilityProfiles.swift"
TRANSLATION_MODELS = (
    APP / "Features" / "Translation" / "TranslationServiceRuntime.swift"
)
SETTINGS = APP / "Features" / "Settings" / "ProviderSettingsPane.swift"
PROVIDER_STORE = APP / "Features" / "Provider" / "ProviderStore.swift"
TRANSLATION_STORE = APP / "Features" / "Translation" / "TranslationStore.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
DOC = ROOT / "docs" / "技术知识库" / "AI-Capability-Provider-Layer-v0.md"

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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    build = run_blocks_no_launch_build(ROOT, args.timeout, "p5h")
    require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
    observations["app_build"] = {"ok": build["ok"], "returncode": build["returncode"]}

    p5g = run(["python3", "tools/verification/p5g_keychain_ui_gate_checks.py", "--timeout", str(args.timeout)], args.timeout)
    require(p5g["ok"], "p5g_regression_failed", p5g["stdout"] or p5g["stderr_tail"], failures)
    observations["p5g_regression"] = p5g["ok"]

    require(AI_MODELS.exists(), "ai_capability_models_missing", str(AI_MODELS), failures)
    require(DOC.exists(), "ai_capability_doc_missing", str(DOC), failures)

    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    required_keys = [
        "settings.aiLLMProviders",
        "settings.ocrEngines",
        "settings.aiCapabilityGate",
        "settings.aiCapabilityArchitectureNote",
        "settings.aiCapabilityNotImplemented",
        "settings.aiCapabilityLocalOnly",
        "settings.aiCapabilityExternalTransfer",
        "aiCapability.llm.mock.name",
        "aiCapability.llm.openAICompatible.name",
        "aiCapability.llm.liteLLMGateway.name",
        "aiCapability.llm.localCLI.name",
        "aiCapability.ocr.mock.name",
        "aiCapability.ocr.appleVision.name",
        "aiCapability.ocr.multimodalLLM.name",
        "aiCapability.ocr.cloud.name",
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
    provider_store_text = PROVIDER_STORE.read_text(encoding="utf-8")
    translation_store_text = TRANSLATION_STORE.read_text(encoding="utf-8")
    translation_text = TRANSLATION_MODELS.read_text(encoding="utf-8")
    ai_text = AI_MODELS.read_text(encoding="utf-8") if AI_MODELS.exists() else ""
    doc_text = DOC.read_text(encoding="utf-8") if DOC.exists() else ""
    combined = "\n".join([project_text, settings_text, provider_store_text, translation_store_text, translation_text, ai_text, doc_text])

    required_symbols = [
        "AICapabilityProfiles.swift",
        "AICapabilityProfile",
        "AICapabilityDomain",
        "LLMProviderProfile",
        "OCREngineProfile",
        "AICapabilityCatalog",
        "llmProviderProfiles",
        "ocrEngineProfiles",
        "selectedLLMProviderID",
        "selectedOCREngineID",
        "TranslationServiceAdapter",
        "TranslationServiceRegistry",
        "TranslationServiceDescriptor",
        "maximumCount: Int = 4",
        "settings.aiLLMProviders",
        "settings.ocrEngines",
        "settings.aiCapabilityGate",
        "llm-openai-compatible-placeholder",
        "llm-litellm-gateway-placeholder",
        "llm-local-cli-placeholder",
        "ocr-apple-vision-placeholder",
        "ocr-multimodal-llm-placeholder",
        "ocr-cloud-placeholder",
        "OpenAI-compatible",
        "LiteLLM",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "ai_capability_symbols_missing", ", ".join(missing_symbols), failures)

    retired_translation_profile_symbols = [
        needle
        for needle in [
            "TranslationEngineProfile",
            "translationEngineProfiles",
            "selectedTranslationEngineID",
        ]
        if needle in "\n".join(
            [settings_text, provider_store_text, translation_store_text, ai_text]
        )
    ]
    require(
        not retired_translation_profile_symbols,
        "retired_translation_profile_symbols_found",
        ", ".join(retired_translation_profile_symbols),
        failures,
    )

    forbidden_hits = [
        needle
        for needle in [
            "URLSession",
            "Process(",
            "VNRecognizeTextRequest",
            "NSPasteboard.general",
            "getenv(",
            "rawProviderOutput",
            "providerRawOutput",
            "codex exec",
        ]
        if needle in "\n".join(
            [
                settings_text,
                provider_store_text,
                translation_text,
                ai_text,
            ]
        )
    ]
    require(not forbidden_hits, "forbidden_runtime_or_secret_input_found", ", ".join(forbidden_hits), failures)
    observations["static_boundary"] = {
        "missing_symbols": missing_symbols,
        "retired_translation_profile_symbols": retired_translation_profile_symbols,
        "forbidden_hits": forbidden_hits,
    }

    output = {
        "ok": not failures,
        "suite": "p5h_ai_capability_layer_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
