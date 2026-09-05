#!/usr/bin/env python3
"""P14-E generic action broker and screenshot CLI contract checks."""

from __future__ import annotations

import json
import subprocess
import tempfile
import textwrap
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
CLI = ROOT / "apps" / "Blocks" / "BlocksCLI" / "main.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj"

CORE_SOURCES = [
    CORE / "ActionEnvelope.swift",
    CORE / "BlocksPluginPlatform.swift",
    CORE / "BlocksNativePluginXPC.swift",
    CORE / "BlocksNativePluginManifest.swift",
    CORE / "BlocksNativePluginPackageValidator.swift",
    CORE / "TranslationModels.swift",
    CORE / "TranslationSourceAction.swift",
    CORE / "ActionRegistry.swift",
    CORE / "ScreenshotAction.swift",
]

CONTRACT_FIXTURE = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "P14E", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func requireThrows(_ operation: () throws -> Void, _ message: String) throws {
    do {
        try operation()
        throw NSError(domain: "P14E", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    } catch let error as ScreenshotCaptureActionValidationError {
        _ = error
    }
}

@main
struct ContractFixture {
    static func main() throws {
        let actionID = ActionID(rawValue: "blocks.screenshot.capture")!
        let requestID = ActionRequestID(rawValue: "req_contract_fixture")!

        let interactive = try ScreenshotCaptureActionInput(
            kind: .smart,
            interaction: .interactive
        )
        try require(interactive.kind == .smart, "interactive defaults to smart")
        try require(interactive.displayScope == nil, "smart has no display scope")
        try require(interactive.copy, "copy defaults on without output")

        let region = try ScreenshotCaptureActionInput(
            kind: .region,
            interaction: .noEditor,
            outputPath: "/tmp/fixture.png"
        )
        try require(!region.copy, "output-only request does not also copy")

        let display = try ScreenshotCaptureActionInput(
            kind: .display,
            interaction: .noEditor
        )
        try require(display.displayScope == .current, "display scope defaults current")

        let allDisplays = try ScreenshotCaptureActionInput(
            kind: .display,
            interaction: .noEditor,
            displayScope: .all,
            copy: true,
            outputPath: "/tmp/fixture.jpg",
            format: .jpeg
        )
        try require(allDisplays.displayScope == .all, "all display scope preserved")
        try require(allDisplays.copy, "explicit copy preserved with output")
        try require(allDisplays.format == .jpeg, "jpeg format preserved")

        try requireThrows({
            _ = try ScreenshotCaptureActionInput(kind: .region, interaction: .interactive)
        }, "interactive region must fail")
        try requireThrows({
            _ = try ScreenshotCaptureActionInput(kind: .smart, interaction: .noEditor)
        }, "no-editor smart must fail")
        try requireThrows({
            _ = try ScreenshotCaptureActionInput(
                kind: .window,
                interaction: .noEditor,
                displayScope: .current
            )
        }, "display scope on window must fail")

        let request = ActionBrokerRequest(
            requestID: requestID,
            actionID: actionID,
            payload: allDisplays
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        let requestJSON = String(decoding: requestData, as: UTF8.self)
        try require(requestJSON.contains("\"protocol_version\":1"), "protocol version encoded")
        try require(requestJSON.contains("\"request_id\":\"req_contract_fixture\""), "request id encoded")
        try require(requestJSON.contains("\"action_id\":\"blocks.screenshot.capture\""), "action id encoded")
        let decodedRequest = try JSONDecoder().decode(
            ActionBrokerRequest<ScreenshotCaptureActionInput>.self,
            from: requestData
        )
        try require(decodedRequest.payload.displayScope == .all, "request payload round trips")

        let result = ScreenshotCaptureActionResult(
            captureID: "cap_fixture",
            kind: .display,
            displayScope: .all,
            pixelSize: ScreenshotPixelDimensions(width: 3200, height: 1800),
            pasteboard: .succeeded,
            history: .notRequested,
            output: .succeeded
        )
        let completed = ActionBrokerTerminalResponse.completed(
            requestID: requestID,
            actionID: actionID,
            result: result
        )
        let cancelled = ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.cancelled(
            requestID: requestID,
            actionID: actionID,
            code: "user_cancelled",
            message: "The screenshot session was cancelled."
        )
        let failed = ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.failed(
            requestID: requestID,
            actionID: actionID,
            error: ActionBrokerError(
                category: .availability,
                code: "broker_unavailable",
                message: "The action broker is unavailable.",
                retryable: false,
                details: ["explicit_enable_required": .bool(true)]
            )
        )
        try require(completed.status == .completed && completed.result != nil && completed.error == nil, "completed invariant")
        try require(cancelled.status == .cancelled && cancelled.result == nil && cancelled.error?.category == .cancelled, "cancelled invariant")
        try require(failed.status == .failed && failed.result == nil && failed.error?.category == .availability, "failed invariant")

        for response in [completed, cancelled, failed] {
            let data = try encoder.encode(response)
            _ = try JSONDecoder().decode(
                ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.self,
                from: data
            )
        }

        let malformed = Data("""
        {
          "protocol_version": 1,
          "request_id": "req_contract_fixture",
          "action_id": "blocks.screenshot.capture",
          "status": "completed",
          "error": {
            "category": "execution",
            "code": "impossible",
            "message": "Invalid completed response.",
            "retryable": false,
            "details": {}
          }
        }
        """.utf8)
        do {
            _ = try JSONDecoder().decode(
                ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.self,
                from: malformed
            )
            throw NSError(domain: "P14E", code: 3, userInfo: [NSLocalizedDescriptionKey: "malformed terminal decoded"])
        } catch is DecodingError {
        }

        print("P14E_CONTRACT_OK")
    }
}
'''


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def add_failure(failures: list[dict[str, str]], code: str, detail: str, path: Path | None = None) -> None:
    failure = {"code": code, "detail": detail}
    if path is not None:
        failure["path"] = rel(path)
    failures.append(failure)


def run_contract_fixture(failures: list[dict[str, str]]) -> None:
    with tempfile.TemporaryDirectory(prefix="blocks_p14e_contract_") as temporary:
        fixture = Path(temporary) / "ContractFixture.swift"
        executable = Path(temporary) / "contract-fixture"
        fixture.write_text(textwrap.dedent(CONTRACT_FIXTURE), encoding="utf-8")
        compiled = subprocess.run(
            [
                "xcrun",
                "--sdk",
                "macosx",
                "swiftc",
                "-strict-concurrency=complete",
                "-warnings-as-errors",
                *[str(path) for path in CORE_SOURCES],
                str(fixture),
                "-o",
                str(executable),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if compiled.returncode:
            diagnostic = (compiled.stderr or compiled.stdout).strip()
            add_failure(
                failures,
                "contract_fixture_compile_failed",
                "Swift action contract fixture did not compile"
                + (f": {diagnostic}" if diagnostic else ""),
            )
            return
        executed = subprocess.run([str(executable)], cwd=ROOT, text=True, capture_output=True)
        if executed.returncode or "P14E_CONTRACT_OK" not in executed.stdout:
            add_failure(failures, "contract_fixture_execution_failed", "Swift action contract fixture did not pass")


def build_cli(failures: list[dict[str, str]], derived_data: Path) -> Path | None:
    built = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(PROJECT),
            "-scheme",
            "BlocksCLI",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            str(derived_data),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if built.returncode:
        add_failure(failures, "cli_build_failed", "BlocksCLI did not build")
        return None
    executable = derived_data / "Build" / "Products" / "Debug" / "blocks"
    if not executable.exists():
        add_failure(failures, "cli_executable_missing", "BlocksCLI executable was not produced")
        return None
    return executable


def run_cli(executable: Path, arguments: list[str]) -> tuple[int, dict[str, Any] | None]:
    completed = subprocess.run([str(executable), *arguments], cwd=ROOT, text=True, capture_output=True)
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        payload = None
    return completed.returncode, payload


def terminal_shape(payload: dict[str, Any] | None) -> bool:
    return bool(
        isinstance(payload, dict)
        and payload.get("protocol_version") == 1
        and isinstance(payload.get("request_id"), str)
        and payload.get("action_id") == "blocks.screenshot.capture"
        and payload.get("status") in {"completed", "cancelled", "failed"}
    )


def run_cli_checks(failures: list[dict[str, str]], executable: Path) -> None:
    code, help_payload = run_cli(executable, ["--help"])
    usage = help_payload.get("usage", "") if isinstance(help_payload, dict) else ""
    if (
        code
        or "--dry-run" not in usage
        or "--interactive [--kind smart]" not in usage
        or "--no-editor --kind region|window|display" not in usage
        or "--no-editor --kind smart" in usage
        or "--mode" in usage
        or "fullscreen" in usage
    ):
        add_failure(failures, "cli_help_schema_wrong", "CLI help still exposes the old screenshot schema", CLI)

    code, list_payload = run_cli(executable, ["list"])
    actions = list_payload.get("actions", []) if isinstance(list_payload, dict) else []
    screenshot = actions[0] if actions and isinstance(actions[0], dict) else {}
    expected_descriptor = {
        "action_id": "blocks.screenshot.capture",
        "protocol_version": 1,
        "request_type": "ScreenshotCaptureActionInput",
        "result_type": "ScreenshotCaptureActionResult",
    }
    if code or any(screenshot.get(key) != value for key, value in expected_descriptor.items()):
        add_failure(failures, "action_descriptor_contract_wrong", "Action registry does not advertise the broker v1 DTO contract")
    if "inputSchema" in screenshot or "outputSchema" in screenshot or "input_schema" in screenshot or "output_schema" in screenshot:
        add_failure(failures, "legacy_schema_descriptor_remaining", "Action registry still advertises legacy screenshot schemas")

    with tempfile.TemporaryDirectory(prefix="blocks_p14e_dry_run_") as temporary:
        output_path = str(Path(temporary) / "missing" / "fixture.jpg")
        dry_run_cases = [
            (
                ["run", "blocks.screenshot.capture", "--dry-run", "--interactive"],
                {"kind": "smart", "interaction": "interactive", "copy": True, "format": "png", "watermark": "default"},
            ),
            (
                ["run", "blocks.screenshot.capture", "--interactive", "--kind", "smart", "--copy", "--dry-run"],
                {"kind": "smart", "interaction": "interactive", "copy": True, "format": "png", "watermark": "default"},
            ),
            (
                ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "region"],
                {"kind": "region", "interaction": "no_editor", "copy": True, "format": "png", "watermark": "default"},
            ),
            (
                [
                    "run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "region",
                    "--watermark", "none",
                ],
                {"kind": "region", "interaction": "no_editor", "copy": True, "format": "png", "watermark": "none"},
            ),
            (
                [
                    "run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "region",
                    "--watermark", "3C1A6400-3404-4DFE-9E97-BB8A90E4EB10",
                ],
                {
                    "kind": "region",
                    "interaction": "no_editor",
                    "copy": True,
                    "format": "png",
                    "watermark": "3c1a6400-3404-4dfe-9e97-bb8a90e4eb10",
                },
            ),
            (
                [
                    "run",
                    "blocks.screenshot.capture",
                    "--dry-run",
                    "--no-editor",
                    "--kind",
                    "window",
                    "--output",
                    output_path,
                    "--format",
                    "jpeg",
                ],
                {
                    "kind": "window",
                    "interaction": "no_editor",
                    "copy": False,
                    "output_path": output_path,
                    "format": "jpeg",
                    "watermark": "default",
                },
            ),
            (
                ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "display"],
                {
                    "kind": "display",
                    "interaction": "no_editor",
                    "display_scope": {"kind": "current"},
                    "copy": True,
                    "format": "png",
                    "watermark": "default",
                },
            ),
            (
                [
                    "run",
                    "blocks.screenshot.capture",
                    "--dry-run",
                    "--no-editor",
                    "--kind",
                    "display",
                    "--display-scope",
                    "all",
                    "--output",
                    output_path,
                    "--format",
                    "jpeg",
                ],
                {
                    "kind": "display",
                    "interaction": "no_editor",
                    "display_scope": {"kind": "all"},
                    "copy": False,
                    "output_path": output_path,
                    "format": "jpeg",
                    "watermark": "default",
                },
            ),
            (
                [
                    "run",
                    "blocks.screenshot.capture",
                    "--dry-run",
                    "--no-editor",
                    "--kind",
                    "display",
                    "--display-scope",
                    "42",
                    "--copy",
                    "--output",
                    output_path,
                ],
                {
                    "kind": "display",
                    "interaction": "no_editor",
                    "display_scope": {"kind": "display_id", "id": 42},
                    "copy": True,
                    "output_path": output_path,
                    "format": "png",
                    "watermark": "default",
                },
            ),
        ]
        for arguments, expected_request in dry_run_cases:
            code, payload = run_cli(executable, arguments)
            result = payload.get("result", {}) if isinstance(payload, dict) else {}
            if (
                code != 0
                or not terminal_shape(payload)
                or payload.get("status") != "completed"
                or result.get("dry_run") is not True
                or result.get("request") != expected_request
                or payload.get("error") is not None
            ):
                add_failure(
                    failures,
                    "dry_run_contract_wrong",
                    f"Dry-run request did not return the normalized completed result: {' '.join(arguments)}",
                    CLI,
                )
        if Path(output_path).exists() or Path(output_path).parent.exists():
            add_failure(failures, "dry_run_touched_output", "Dry-run created or opened the requested output path", CLI)

    broker_cases = [
        ["run", "blocks.screenshot.capture", "--interactive"],
        ["run", "blocks.screenshot.capture", "--no-editor", "--kind", "display", "--display-scope", "42"],
    ]
    for arguments in broker_cases:
        code, payload = run_cli(executable, arguments)
        if code != 1 or not terminal_shape(payload):
            add_failure(failures, "valid_cli_request_not_terminal", "Valid screenshot request did not return a structured terminal response", CLI)
            continue
        error = payload.get("error", {}) if isinstance(payload, dict) else {}
        if payload.get("status") != "failed" or error.get("code") != "broker_unavailable":
            add_failure(failures, "broker_unavailable_contract_wrong", "Pending broker platform must fail explicitly", CLI)

    invalid_cases = [
        ["run", "blocks.screenshot.capture", "--dry-run", "--interactive", "--no-editor"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--interactive", "--kind", "region"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "smart"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "region", "--display-scope", "current"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "display", "--display-scope", "invalid"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--interactive", "--mode", "region"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "fullscreen"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--no-editor", "--kind", "region", "--watermark", "invalid"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--dry-run", "--interactive"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--interactive", "--copy", "--copy"],
        ["run", "blocks.screenshot.capture", "--dry-run", "--interactive", "--output", "/tmp/a.png", "--output", "/tmp/b.png"],
    ]
    for arguments in invalid_cases:
        code, payload = run_cli(executable, arguments)
        error = payload.get("error", {}) if isinstance(payload, dict) else {}
        if code != 2 or not terminal_shape(payload) or payload.get("status") != "failed" or error.get("code") != "invalid_arguments":
            add_failure(failures, "invalid_cli_arguments_not_rejected", "Invalid or legacy screenshot arguments were accepted", CLI)


def main() -> int:
    failures: list[dict[str, str]] = []
    for path in [*CORE_SOURCES, CLI, PROJECT]:
        if not path.exists():
            add_failure(failures, "missing_file", "Required contract source is missing", path)

    cli_source = CLI.read_text(encoding="utf-8") if CLI.exists() else ""
    for token in ["condition.wait(until:", "broker_response_timeout", "proxy.cancel("]:
        if token not in cli_source:
            add_failure(failures, "broker_response_timeout_missing", token, CLI)
    legacy_tokens = [token for token in ["--mode", "fullscreen"] if token in cli_source]
    if legacy_tokens:
        add_failure(
            failures,
            "legacy_cli_schema_remaining",
            f"Legacy screenshot CLI tokens remain: {', '.join(legacy_tokens)}",
            CLI,
        )

    screenshot_contract_source = CORE_SOURCES[-1].read_text(encoding="utf-8") if CORE_SOURCES[-1].exists() else ""
    legacy_contract_tokens = [
        token
        for token in ["enum ScreenshotMode", "case fullscreen", "ScreenshotCaptureInput", "ScreenshotActionService"]
        if token in screenshot_contract_source
    ]
    if legacy_contract_tokens:
        add_failure(
            failures,
            "legacy_action_contract_remaining",
            f"Legacy screenshot action contracts remain: {', '.join(legacy_contract_tokens)}",
            CORE_SOURCES[-1],
        )

    run_contract_fixture(failures)
    with tempfile.TemporaryDirectory(prefix="blocks_p14e_derived_data_") as temporary:
        executable = build_cli(failures, Path(temporary))
        if executable is not None:
            run_cli_checks(failures, executable)

    payload = {
        "gate": "P14-E",
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "observations": {
            "broker_platform": "implemented_separate_gate_p14f",
            "legacy_screenshot_cli_aliases": "forbidden",
        },
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
