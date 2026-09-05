#!/usr/bin/env python3
"""P2-K provider settings confirmation smoke for 积木工具.

This script validates redacted provider profile handling only. It does not read
environment variables, Keychain values, local CLI tokens, or call any network
API.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from typing import Any


def audit_id(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]
    return f"provider_settings_{int(time.time())}_{digest}"


def confirmation(level: str, reason: str, preview: dict[str, Any]) -> dict[str, Any]:
    return {
        "level": level,
        "reason": reason,
        "preview": preview,
    }


def redacted_base_url(raw: str) -> dict[str, Any]:
    try:
        from urllib.parse import urlparse

        parsed = urlparse(raw)
        return {
            "scheme": parsed.scheme,
            "host_characters": len(parsed.hostname or ""),
            "host_sha256_12": hashlib.sha256((parsed.hostname or "").encode("utf-8")).hexdigest()[:12],
            "path_characters": len(parsed.path or ""),
        }
    except Exception:
        return {"parse_error": True, "characters": len(raw)}


def mock_api_profile() -> dict[str, Any]:
    profile = {
        "provider": "mock-api",
        "model": "mock-safe-model",
        "base_url": "https://api.example.invalid/v1",
        "keychain_account": "mock-api:p2k-placeholder",
        "timeout_seconds": 30,
    }
    preview = {
        "provider": profile["provider"],
        "model": profile["model"],
        "base_url": redacted_base_url(profile["base_url"]),
        "keychain_account": profile["keychain_account"],
        "timeout_seconds": profile["timeout_seconds"],
        "sample_payload": {
            "source": "fixed-low-sensitive-fixture",
            "characters": 4,
            "sha256_12": hashlib.sha256(b"pong").hexdigest()[:12],
        },
    }
    return {
        "provider": profile["provider"],
        "model": profile["model"],
        "base_url": preview["base_url"],
        "keychain_account": profile["keychain_account"],
        "timeout_seconds": profile["timeout_seconds"],
        "api_key_present": False,
        "network_called": False,
        "requires_confirmation": confirmation(
            "external_transfer",
            "API provider calls may transfer user content outside the device.",
            preview,
        ),
    }


def cli_profile() -> dict[str, Any]:
    codex = shutil.which("codex")
    return {
        "provider": "codex-cli",
        "command_shape": [
            "codex",
            "exec",
            "--ephemeral",
            "--sandbox",
            "read-only",
            "--cd",
            "/tmp",
            "--output-schema",
            "<schema>",
            "--json",
            "<low-sensitive prompt>",
        ],
        "available": codex is not None,
        "path_present": codex is not None,
        "token_read": False,
        "network_called_by_this_smoke": False,
        "requires_confirmation": confirmation(
            "external_transfer",
            "CLI providers may receive user content through their own runtime and login state.",
            {
                "provider": "codex-cli",
                "transport": "local-cli",
                "content_preview_policy": "summary-only",
            },
        ),
    }


def smoke_payload() -> dict[str, Any]:
    observations = {
        "mock_api_profile": mock_api_profile(),
        "cli_profile": cli_profile(),
        "audit_policy": {
            "records_raw_provider_output": False,
            "records_raw_user_content": False,
            "records_secrets": False,
            "records_preview_only": True,
        },
    }
    payload = {
        "ok": True,
        "probe": "blocks.provider_settings",
        "status": "settings_confirmation_smoke_passed",
        "prompt_requested": False,
        "observations": observations,
        "warnings": [
            "API provider is not called in this smoke.",
            "No environment variables, Keychain secrets, CLI tokens or raw provider output are read.",
        ],
    }
    payload["audit_id"] = audit_id(payload)
    return payload


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="P2-K provider settings confirmation smoke")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("smoke")
    args = parser.parse_args(argv)

    if args.command == "smoke":
        emit(smoke_payload())
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
