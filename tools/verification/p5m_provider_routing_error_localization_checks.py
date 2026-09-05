#!/usr/bin/env python3
"""P5-M provider routing and localized error contract checks."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_text


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
PROVIDER_ROUTING = APP / "Models" / "ProviderRouting.swift"
PROVIDER_STORE = APP / "Features" / "Provider" / "ProviderStore.swift"
PROVIDER_COORDINATOR = APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift"
TRANSLATION_ADAPTERS = APP / "Features" / "Translation" / "TranslationBuiltInAdapters.swift"

LANGUAGES = ["zh-Hans", "en", "ja"]
ERROR_CODES = [
    "missing_configuration",
    "missing_secret",
    "invalid_base_url",
    "unauthorized",
    "forbidden",
    "rate_limited",
    "timeout",
    "network_error",
    "invalid_response",
    "provider_unavailable",
    "unsupported_capability",
    "confirmation_required",
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

    p10a = run(
        [
            "python3",
            "tools/verification/p10a_provider_translation_contract_checks.py",
            "--timeout",
            str(args.timeout),
        ],
        args.timeout,
    )
    require(
        p10a["ok"],
        "p10a_provider_contract_failed",
        p10a["stdout"] or p10a["stderr_tail"],
        failures,
    )
    observations["p10a_provider_contract"] = p10a["ok"]

    for path in [
        LOCALIZABLE,
        PROVIDER_ROUTING,
        PROVIDER_STORE,
        PROVIDER_COORDINATOR,
        TRANSLATION_ADAPTERS,
    ]:
        require(path.exists(), "missing_file", str(path.relative_to(ROOT)), failures)

    router = text(PROVIDER_ROUTING)
    store = text(PROVIDER_STORE)
    coordinator = text(PROVIDER_COORDINATOR)
    adapter = text(TRANSLATION_ADAPTERS)
    required_symbols = [
        "enum ProviderErrorCode",
        "struct ProviderRouteRequest",
        "struct ProviderRouteResolution",
        "struct ProviderRouteSummary",
        "struct ProviderRouter",
        "var providerErrorCode: ProviderErrorCode?",
        "providerRouteResolution",
        "ProviderRuntimeGate.validateOpenAICompatible",
    ]
    combined = "\n".join([router, store, coordinator, adapter])
    missing_symbols = [symbol for symbol in required_symbols if symbol not in combined]
    require(
        not missing_symbols,
        "provider_routing_contract_missing",
        ", ".join(missing_symbols),
        failures,
    )
    forbidden_router = [
        "URLSession",
        "Process(",
        "getenv(",
        "NSPasteboard.general",
        "SecItem",
        "rawProviderOutput",
        "providerRawOutput",
        "Authorization",
        "Bearer ",
    ]
    router_hits = [symbol for symbol in forbidden_router if symbol in router]
    require(
        not router_hits,
        "router_forbidden_side_effect_found",
        ", ".join(router_hits),
        failures,
    )

    localized = (
        json.loads(LOCALIZABLE.read_text(encoding="utf-8")).get("strings", {})
        if LOCALIZABLE.exists()
        else {}
    )
    required_keys = [
        "providerAudit.kind.providerRouteResolution",
        "providerAudit.source.providerRouteResolution",
        "providerAudit.result.providerRouteResolution",
        "status.providerRouteResolution.title",
        "status.providerRouteResolution.detail",
    ]
    for code in ERROR_CODES:
        required_keys.extend(
            [f"provider.error.{code}.title", f"provider.error.{code}.detail"]
        )
    missing_l10n: list[str] = []
    for key in required_keys:
        entry = localized.get(key)
        if entry is None:
            missing_l10n.append(key)
            continue
        missing_langs = [
            language
            for language in LANGUAGES
            if language not in entry.get("localizations", {})
        ]
        if missing_langs:
            missing_l10n.append(f"{key}:{','.join(missing_langs)}")
    require(
        not missing_l10n,
        "localization_missing",
        ", ".join(missing_l10n),
        failures,
    )
    observations["localization"] = {
        "checked": len(required_keys),
        "missing": missing_l10n,
    }
    observations["retired_contract"] = (
        "Translation routing no longer comes from AICapabilityCatalog.translationEngines."
    )

    report = {
        "ok": not failures,
        "suite": "p5m_provider_routing_error_localization_checks",
        "failures": failures,
        "observations": observations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
