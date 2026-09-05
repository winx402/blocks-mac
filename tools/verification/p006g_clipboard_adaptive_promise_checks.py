#!/usr/bin/env python3
"""P006-G clipboard adaptive promised-data static gate.

This gate never opens the system pasteboard. Runtime provider behavior is
covered by named-pasteboard tests.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BLOCKS = ROOT / "apps" / "Blocks"
PROTOCOL = BLOCKS / "BlocksCore" / "ClipboardBrokerProtocol.swift"
BROKER = BLOCKS / "BlocksClipboardBroker" / "main.swift"
CLIENT = BLOCKS / "BlocksApp" / "Services" / "ClipboardBrokerClient.swift"
CAPTURE = BLOCKS / "BlocksApp" / "Services" / "ClipboardLiveCaptureService.swift"
COORDINATOR = (
    BLOCKS
    / "BlocksApp"
    / "Features"
    / "Clipboard"
    / "ClipboardFeatureCoordinator.swift"
)
TESTS = BLOCKS / "BlocksAppTests" / "ClipboardIOBrokerTests.swift"
BEHAVIOR = BLOCKS / "BlocksAppTests" / "ClipboardBrokerBehaviorTests.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(
    condition: bool,
    code: str,
    detail: str,
    failures: list[dict[str, str]],
) -> None:
    if not condition:
        failures.append({"code": code, "detail": detail})


def ordered(source: str, tokens: list[str]) -> bool:
    cursor = -1
    for token in tokens:
        cursor = source.find(token, cursor + 1)
        if cursor < 0:
            return False
    return True


def main() -> int:
    failures: list[dict[str, str]] = []
    protocol = read(PROTOCOL)
    broker = read(BROKER)
    client = read(CLIENT)
    capture = read(CAPTURE)
    coordinator = read(COORDINATOR)
    tests = read(TESTS) + read(BEHAVIOR)

    for token in [
        "case deferred",
        "struct ClipboardBrokerResolutionTicket",
        "case resolve(ClipboardBrokerResolveRequest)",
    ]:
        require(token in protocol, "missing_protocol_contract", token, failures)
    require(
        "func resolve(" in client,
        "missing_client_contract",
        "ClipboardBrokerServing.resolve",
        failures,
    )

    require(
        ordered(
            broker,
            [
                "PasteboardMarkers.sensitive",
                "PasteboardMarkers.remote",
                "preferredRepresentation",
                "if request.screenSharingActive",
                "status: .deferred",
                "readSelectedRepresentation(selected)",
            ],
        ),
        "broker_order_regressed",
        "marker checks and defer must precede representation reads",
        failures,
    )
    resolve_block = broker[
        broker.find("private func resolve("):
        broker.find("private struct SelectedRepresentation")
    ]
    require(
        "pasteboardTypes()" not in resolve_block
        and resolve_block.count("readSelectedRepresentation(selected)") == 1,
        "resolve_not_single_representation",
        "resolve must not reread types and must request one representation",
        failures,
    )
    require(
        capture.count("self.broker.resolve(") == 2
        and ".milliseconds(500)" in capture
        and ".milliseconds(1_500)" in capture
        and ".milliseconds(250)" in capture,
        "adaptive_attempt_budget_missing",
        "500ms defer, one 1s attempt and one 250ms retry are required",
        failures,
    )
    require(
        "case .observe:" in client
        and "case .baseline:" in client
        and "case .resolve:" not in client[
            client.find("private func requestTimedOut("):
            client.find("private func recordPassiveRestart(")
        ],
        "resolve_timeout_poisoning_not_isolated",
        (
            "observe may poison and count, baseline may only count, and "
            "resolve must not affect the passive circuit"
        ),
        failures,
    )
    require(
        "if taggedObservation.skipReason != .stale" in client
        and "if result.skipReason != .stale" in capture,
        "stale_resolution_consumes_following_change",
        "a stale ticket must not advance either observation baseline",
        failures,
    )
    require(
        coordinator.count("runningApplications") == 0
        and capture.count("workspace.runningApplications") == 1
        and "didLaunchApplicationNotification" in capture
        and "didTerminateApplicationNotification" in capture
        and "didActivateApplicationNotification" in capture,
        "workspace_hot_path_not_cached",
        "workspace state must be scanned once and maintained by notifications",
        failures,
    )
    for test_name in [
        "testScreenSharingUnknownItemDefersWithoutReadingRepresentation",
        "testStaleResolutionTicketDoesNotReadRepresentation",
        "testStaleResolutionDoesNotConsumeTheFollowingChange",
        "testDeferredObservationPublishesAfterOneSuccessfulResolution",
        "testDeferredObservationRetriesOnceAfterTimeout",
        "testDeferredObservationStopsAfterTwoTimeoutsWithoutPlaceholder",
        "testStaleDeferredResolutionLeavesFollowingVersionObservable",
        "testScreenSharingDeferredPromiseUsesOneSecondThenQuarterSecondAttempts",
    ]:
        require(test_name in tests, "missing_adaptive_test", test_name, failures)

    report = {
        "gate": "P006-G",
        "ok": not failures,
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "note": (
            "Static gate only; named-pasteboard process tests own runtime "
            "promised-data and heartbeat evidence."
        ),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
