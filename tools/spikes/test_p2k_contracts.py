#!/usr/bin/env python3
"""Lightweight contract tests for P2-K spike entrypoints."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPIKES = ROOT / "tools" / "spikes"


class P2KContracts(unittest.TestCase):
    def run_json(self, *args: str) -> dict[str, object]:
        result = subprocess.run(
            [sys.executable, *args],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        return json.loads(result.stdout)

    def test_provider_settings_smoke_returns_redacted_confirmation_preview(self) -> None:
        payload = self.run_json("tools/spikes/blocks_provider_settings_smoke.py", "smoke")

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["probe"], "blocks.provider_settings")
        self.assertIn("mock_api_profile", payload["observations"])
        self.assertIn("cli_profile", payload["observations"])
        self.assertEqual(payload["observations"]["mock_api_profile"]["api_key_present"], False)
        confirmation = payload["observations"]["mock_api_profile"]["requires_confirmation"]
        self.assertEqual(confirmation["level"], "external_transfer")
        serialized = json.dumps(payload).lower()
        self.assertNotIn("sk-", serialized)
        self.assertNotIn("api_key_value", serialized)
        self.assertNotIn("token_value", serialized)

    def test_p2k_suite_has_redacted_plan_only_mode(self) -> None:
        payload = self.run_json("tools/spikes/p2k_validation_suite.py", "--plan-only")

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["probe"], "blocks.p2k_validation_suite")
        self.assertIn("checks", payload["observations"])
        self.assertGreaterEqual(len(payload["observations"]["checks"]), 5)

    def test_swift_sources_declare_p2k_commands(self) -> None:
        macos_source = (
            SPIKES / "blocks_macos_probe" / "Sources" / "BlocksMacOSProbe" / "main.swift"
        ).read_text(encoding="utf-8")
        login_source = (
            SPIKES
            / "blocks_login_item_probe"
            / "Sources"
            / "BlocksLoginItemProbe"
            / "main.swift"
        ).read_text(encoding="utf-8")

        for command in [
            "--boundary-suite",
            "--complex-fixture-roundtrip",
            "--detection-patterns-fixture",
            "--manual-complex-watch",
        ]:
            self.assertIn(command, macos_source, msg=f"missing macOS probe command {command}")

        for command in [
            "--recorder-roundtrip",
            "--restart-policy-check",
            "--approval-status",
        ]:
            self.assertIn(command, login_source, msg=f"missing login item probe command {command}")


if __name__ == "__main__":
    unittest.main()
