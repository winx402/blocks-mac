#!/usr/bin/env python3
"""P14-G executes the hosted screenshot app-state XCTest target."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"


def resolve_signing_identity() -> tuple[str, str] | None:
    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    identity_match = re.search(
        r"\)\s+([A-F0-9]{40})\s+"
        r'"Apple Development:[^"]+"',
        result.stdout,
    )
    if not identity_match:
        return None
    certificate = subprocess.run(
        [
            "security",
            "find-certificate",
            "-a",
            "-p",
            "-c",
            "Apple Development",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    subject = subprocess.run(
        ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
        input=certificate.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout.decode("utf-8", errors="replace")
    team_match = re.search(r"(?:^|,)OU=([^,]+)", subject)
    if not team_match:
        return None
    return identity_match.group(1), team_match.group(1)


def main() -> int:
    signing_identity = resolve_signing_identity()
    with (
        tempfile.TemporaryDirectory(
            prefix="blocks-p14g-hosted-derived-data-"
        ) as hosted_directory,
        tempfile.TemporaryDirectory(
            prefix="blocks-p14g-broker-derived-data-"
        ) as broker_directory,
    ):
        hosted_command = [
            "xcodebuild",
            "-project",
            str(PROJECT),
            "-derivedDataPath",
            hosted_directory,
            "-scheme",
            "BlocksAppTests",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS",
            "-skip-testing:BlocksAppTests/ClipboardBrokerBehaviorTests",
            "-skip-testing:BlocksAppTests/ClipboardBrokerProcessIntegrationTests",
            "test",
        ]
        if signing_identity:
            identity_hash, development_team = signing_identity
            hosted_command.extend([
                f"DEVELOPMENT_TEAM={development_team}",
                f"CODE_SIGN_IDENTITY={identity_hash}",
                "CODE_SIGN_STYLE=Manual",
            ])
        hosted_result = subprocess.run(
            hosted_command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        # Named pasteboards and their promised-data fixtures intentionally run
        # outside the hosted App Sandbox. The production App/Broker pair is
        # still covered by the signed hosted pass; this second pass owns only
        # the isolated Broker protocol and timeout fixtures.
        broker_result = subprocess.run(
            [
                "xcodebuild",
                "-project",
                str(PROJECT),
                "-derivedDataPath",
                broker_directory,
                "-scheme",
                "BlocksAppTests",
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS",
                "-only-testing:BlocksAppTests/ClipboardBrokerBehaviorTests",
                "-only-testing:BlocksAppTests/ClipboardBrokerProcessIntegrationTests",
                "CODE_SIGNING_ALLOWED=NO",
                "test",
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    failures: list[dict[str, str]] = []
    if not signing_identity:
        failures.append({
            "code": "development_team_unavailable",
            "detail": (
                "BlocksSelectionAgent hosted tests require a valid local "
                "Apple Development identity."
            ),
        })
    if hosted_result.returncode != 0:
        tail = "\n".join(hosted_result.stdout.splitlines()[-80:])
        failures.append({"code": "hosted_app_tests_failed", "detail": tail})
    if broker_result.returncode != 0:
        tail = "\n".join(broker_result.stdout.splitlines()[-80:])
        failures.append({
            "code": "isolated_broker_tests_failed",
            "detail": tail,
        })
    payload = {
        "gate": "P14-G",
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "test_layout": {
            "hosted": (
                "signed BlocksAppTests excluding named-pasteboard Broker "
                "fixtures"
            ),
            "broker": (
                "unsigned named-pasteboard Broker behavior/process fixtures"
            ),
        },
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
