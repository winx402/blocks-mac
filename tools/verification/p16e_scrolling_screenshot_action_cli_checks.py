#!/usr/bin/env python3
"""P16-E scrolling Action and CLI control-only contract gate."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def main() -> int:
    failures: list[dict[str, object]] = []
    registry = read("apps/Blocks/BlocksCore/ActionRegistry.swift")
    contract = read("apps/Blocks/BlocksCore/ScreenshotAction.swift")
    cli = read("apps/Blocks/BlocksCLI/main.swift")
    host = read("apps/Blocks/BlocksApp/Features/Screenshot/Integration/ScreenshotActionHost.swift")
    tests = read("apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift")

    expected_ids = [
        "blocks.screenshot.scrolling.status",
        "blocks.screenshot.scrolling.finish",
        "blocks.screenshot.scrolling.cancel",
    ]
    for action_id in expected_ids:
        if action_id not in registry or action_id not in cli:
            failures.append({"check": "missing_action", "action_id": action_id})
    for forbidden in ["blocks.screenshot.scrolling.start", "blocks.screenshot.scrolling.resume"]:
        if forbidden in registry or forbidden in cli or forbidden in host:
            failures.append({"check": "forbidden_action", "action_id": forbidden})

    required = {
        "contract": (contract, ["ScreenshotScrollingStatusActionResult", "ScreenshotScrollingFinishActionInput", "cancellationConfirmationRequired", "case recovering"]),
        "host": (host, ["scrollingStatusAction", "finishScrollingAction", "cancelScrollingAction"]),
        "cli_confirmation": (cli, ["--session-id", "--confirm", "confirm: confirm"]),
        "behavior_tests": (tests, ["testScrollingActionRegistryExposesControlActionsWithoutStart", "testScrollingStatusActionResultRoundTripsOptionalContract", "testScrollingCancelActionRequiresExplicitConfirmation"]),
    }
    for name, (source, markers) in required.items():
        missing = [marker for marker in markers if marker not in source]
        if missing:
            failures.append({"check": name, "missing": missing})

    if not failures:
        selected = [
            "testScrollingActionRegistryExposesControlActionsWithoutStart",
            "testScrollingStatusActionResultRoundTripsOptionalContract",
            "testScrollingCancelActionRequiresExplicitConfirmation",
        ]
        args = []
        for test in selected:
            args.append(f"-only-testing:BlocksAppTests/ScreenshotAppStateTests/{test}")
        with tempfile.TemporaryDirectory(prefix="blocks-p16e-") as derived:
            result = subprocess.run(
                [
                    "xcodebuild", "-quiet", "-project", str(PROJECT),
                    "-scheme", "BlocksAppTests", "-derivedDataPath", derived,
                    "-destination", "platform=macOS", "CODE_SIGNING_ALLOWED=NO", "test",
                    *args,
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=300,
                check=False,
            )
        if result.returncode:
            failures.append({"check": "action_xctest", "tail": result.stdout.splitlines()[-40:]})

    print(json.dumps({
        "gate": "P16-E",
        "status": "fail" if failures else "pass",
        "failures": failures,
        "observations": {"actions": expected_ids, "start_supported": False, "resume_supported": False},
    }, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
