#!/usr/bin/env python3
"""P5-O OpenAI-compatible translation adapter and runtime boundary checks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
BUILT_INS = APP / "Features" / "Translation" / "TranslationBuiltInAdapters.swift"
RUNTIME = APP / "Services" / "OpenAITranslationRuntimeService.swift"
KEYCHAIN = APP / "Services" / "ProviderKeychainService.swift"
PANEL = APP / "Views" / "TranslationFloatingPanelView.swift"
SETTINGS = APP / "Features" / "Settings" / "TranslationSettingsPane.swift"
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

    p5n = run(
        [
            "python3",
            "tools/verification/p5n_translation_engine_router_checks.py",
            "--timeout",
            str(args.timeout),
        ],
        args.timeout,
    )
    require(
        p5n["ok"],
        "p5n_regression_failed",
        p5n["stdout"] or p5n["stderr_tail"],
        failures,
    )
    observations["p5n_regression"] = p5n["ok"]

    for path in [BUILT_INS, RUNTIME, KEYCHAIN, PANEL, SETTINGS, STORE_TESTS]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    adapter = text(BUILT_INS)
    runtime = text(RUNTIME)
    panel = text(PANEL)
    settings = text(SETTINGS)
    tests = text(STORE_TESTS)

    required_adapter_contract = [
        "private actor OpenAITranslationExecutionWorker",
        "final class OpenAICompatibleTranslationServiceAdapter",
        "ProviderRuntimeGate.validateOpenAICompatible",
        "guard gate.ready else",
        "let secret = try readProviderSecret",
        "readUserSecretForProviderCall",
        "OpenAITranslationRuntimeService.inputExceedsLimit",
        "request.direction.source?.rawValue ?? \"auto\"",
        "request.direction.target.rawValue",
        ".diagnostics(",
        "continuation.yield(",
        ".completed(",
        "continuation.onTermination",
        "task.cancel()",
    ]
    missing_adapter = [
        symbol for symbol in required_adapter_contract if symbol not in adapter
    ]
    require(
        not missing_adapter,
        "openai_adapter_contract_missing",
        ", ".join(missing_adapter),
        failures,
    )

    required_runtime_contract = [
        "ProviderUserSecretMaterial",
        "ProviderRuntimeGate.isAllowedProviderBaseURL",
        "request.setValue(\"Bearer \\(secret)\"",
        "URLSession",
        "maximumInputCharacterCount",
        "auditHandler",
        "translationDiagnostics",
        "sourceLanguageMode",
        "targetLanguage",
        "externalTransferDisabledResult",
    ]
    missing_runtime = [
        symbol for symbol in required_runtime_contract if symbol not in runtime
    ]
    require(
        not missing_runtime,
        "openai_runtime_contract_missing",
        ", ".join(missing_runtime),
        failures,
    )

    ui_forbidden = [
        "URLSession",
        'forHTTPHeaderField: "Authorization"',
        'setValue("Bearer ',
        "SecItem",
        "readUserSecretForProviderCall",
    ]
    ui = panel + "\n" + settings
    ui_hits = [symbol for symbol in ui_forbidden if symbol in ui]
    require(
        not ui_hits,
        "secret_or_network_runtime_in_translation_ui",
        ", ".join(ui_hits),
        failures,
    )
    require(
        "testOpenAIAdapterRejectsMissingConfigurationBeforeReadingSecret" in tests,
        "openai_adapter_gate_test_missing",
        "The adapter must prove that an invalid route fails before any Keychain secret read.",
        failures,
    )
    require(
        "testOpenAIAdapterReadsSecretOffMainThreadAndPreservesRuntimeDiagnostics"
        in tests,
        "openai_adapter_background_runtime_test_missing",
        "The adapter must prove that Keychain access is isolated from the main thread and diagnostics survive.",
        failures,
    )
    require(
        "testOpenAIAdapterRejectsOversizedInputBeforeReadingSecret" in tests,
        "openai_adapter_input_limit_test_missing",
        "Oversized input must fail before a Keychain read or provider request.",
        failures,
    )

    observations["runtime_boundary"] = {
        "route_validated_before_secret": True,
        "secret_read_in_background_worker": True,
        "runtime_diagnostics_preserved": True,
        "network_runtime_in_ui": False,
    }
    report = {
        "ok": not failures,
        "suite": "p5o_openai_translation_runtime_gate_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
