#!/usr/bin/env python3
"""Hermetic contract checks for plugin CLI error and fixture handling."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/Blocks/BlocksCLI/TranslationSourceCLI.swift"
MAIN = ROOT / "apps/Blocks/BlocksCLI/main.swift"


def package_relative_path(path: str, files: dict[str, bytes]) -> bytes:
    """Mirror the safe relative-package fixture contract, without filesystem I/O."""
    parts = path.split("/")
    if not path or any(part in {"", ".", ".."} for part in parts):
        raise ValueError("invalid_path")
    try:
        return files[path]
    except KeyError as error:
        raise FileNotFoundError("read_failed") from error


def classified_error(kind: str) -> tuple[str, str]:
    """Only an explicit unavailable broker gets integration-toggle guidance."""
    if kind == "proxy_unavailable":
        return ("broker_unavailable", "Enable CLI integration in Blocks settings.")
    if kind == "untrusted_peer":
        return ("broker_identity_untrusted", "identity could not be verified")
    return ("plugin_command_failed", "The plugin command failed unexpectedly.")


def _rejects_path(path: str, files: dict[str, bytes]) -> bool:
    try:
        package_relative_path(path, files)
    except ValueError:
        return True
    return False


def _missing_path_is_rejected(path: str, files: dict[str, bytes]) -> bool:
    try:
        package_relative_path(path, files)
    except FileNotFoundError:
        return True
    return False


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    main_source = MAIN.read_text(encoding="utf-8")
    fixtures = {"Tests/app-launched.event.json": b'{"kind":"hook"}'}
    checks = {
        "typed_translation_source_error_is_preserved": (
            "catch let error as TranslationSourceCLIError" in source
            and "code: error.code" in source
            and "message: error.message" in source
        ),
        "typed_transport_has_distinct_identity_failures": (
            "catch let error as BlocksCLITransportError" in source
            and "case .localIdentityUnavailable" in main_source
            and "case .untrustedPeer" in main_source
            and "broker_identity_untrusted" in main_source
            and "cli_identity_unavailable" in main_source
        ),
        "missing_probe_reply_is_unavailable_not_affirmatively_untrusted": (
            "func wait() -> Bool?" in main_source
            and "== .success else { return nil }" in main_source
            and "guard let trustedPeer = verifyBroker" in main_source
            and "guard trustedPeer else" in main_source
        ),
        "failure_command_is_canonical_and_not_raw_args": (
            "let canonicalCommand = canonicalPluginCommand(args)" in source
            and "command: canonicalCommand" in source
            and "command: args.joined(separator: \" \")" not in source
        ),
        "pack_usage_requires_output": (
            "blocks plugin pack PATH.blocksplugin --output OUTPUT.blocksplugin"
            in source
            and "blocks plugin pack PATH.blocksplugin [--output" not in source
        ),
        "package_relative_fixture_reads_validated_snapshot": (
            "private func readPluginFixture(" in source
            and "package.files[relativePath]" in source
            and "path.hasPrefix(\"/\")" in source
            and "O_NOFOLLOW" in source
        ),
        "package_relative_fixture_accepts_scaffold_path": (
            package_relative_path("Tests/app-launched.event.json", fixtures)
            == fixtures["Tests/app-launched.event.json"]
        ),
        "package_relative_fixture_rejects_escape": all(
            _rejects_path(path, fixtures)
            for path in ("../outside.json", "Tests/../outside.json", "Tests//fixture.json", "")
        ),
        "package_relative_fixture_missing_file_is_not_cwd_fallback": (
            _missing_path_is_rejected("Tests/missing.event.json", fixtures)
        ),
        "untrusted_peer_is_not_relabeled_as_integration_toggle": (
            classified_error("untrusted_peer")[0] == "broker_identity_untrusted"
            and classified_error("proxy_unavailable")[0] == "broker_unavailable"
            and classified_error("arbitrary_error")[0] == "plugin_command_failed"
        ),
    }
    failures = [name for name, passed in checks.items() if not passed]
    print(json.dumps({
        "ok": not failures,
        "suite": "plugin_cli_error_self_test",
        "checks": checks,
        "failures": failures,
    }, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
