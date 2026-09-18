#!/usr/bin/env python3
"""Compile production CLI execution/output boundaries with -O and a fake broker.

All I/O is inside TemporaryDirectory. No XPC connection or app is launched.
This guards behavioral compatibility, not reproduction of Xcode 27's crash.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksCore"


def section(source: str, start: str, end: str) -> str:
    offset = source.index(start)
    return source[offset:source.index(end, offset)]


FIXTURE = r'''
enum FixtureError: Error { case failure }
struct FixturePayload: Codable { let value: String }
struct FixtureResult: Codable {
    let value: String
    func encode(to encoder: Encoder) throws {
        if value == "encoding-failure" { throw FixtureError.failure }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}
var submissions = 0
let scenario = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

@inline(never)
func submitToBroker<Payload: Codable, Result: Codable>(
    _ request: ActionBrokerRequest<Payload>, outputFile: FileHandle?,
    timeout: TimeInterval, resultType: Result.Type
) throws -> ActionBrokerTerminalResponse<Result> {
    submissions += 1
    // Exercise the same request-encoding failure classification as real XPC.
    _ = try JSONEncoder().encode(request)
    try outputFile?.write(contentsOf: Data("fixture-output".utf8))
    switch scenario {
    case "parse-failure": throw ScreenshotCLIParseError(code: "fixture_invalid", message: "Fixture")
    case "proxy-failure": throw BlocksCLITransportError.proxyUnavailable
    case "identity-failure": throw BlocksCLITransportError.localIdentityUnavailable
    case "untrusted-failure": throw BlocksCLITransportError.untrustedPeer
    case "unknown-failure": throw FixtureError.failure
    case "terminal-failure":
        return .failed(requestID: request.requestID, actionID: request.actionID,
            error: ActionBrokerError(category: .transport, code: "fixture_terminal", message: "Fixture", retryable: false))
    case "cancelled":
        return .cancelled(requestID: request.requestID, actionID: request.actionID, code: "fixture_cancelled", message: "Fixture")
    case "destination-changed":
        // Deliberately swap a fixture inode before finalization.
        try FileManager.default.removeItem(atPath: outputPath)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: outputPath))
    case "finalize-failure":
        try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: false)
    default: break
    }
    let value = scenario == "encoding-failure" ? "encoding-failure" : "ok"
    let result = try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(["value": value]))
    return .completed(requestID: request.requestID, actionID: request.actionID, result: result)
}
'''

HARNESS = r'''
let selectedAction = BlocksAction(rawValue: CommandLine.arguments[3])!
let execution = executeAction(
    action: selectedAction,
    requestID: ActionRequestID(rawValue: "req_fixture")!,
    arguments: ActionCLIArguments(request: FixturePayload(value: "fixture"),
        dryRun: scenario == "dry-run", outputPath: outputPath,
        allowOverwrite: scenario == "overwrite" || scenario == "destination-changed"),
    timeout: selectedAction == .screenshotScrollingCancel ? 30 : 90,
    resultType: FixtureResult.self
)
precondition(submissions == (scenario == "dry-run" || scenario == "existing" || scenario == "symlink" ? 0 : 1))
precondition((try! FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: outputPath).deletingLastPathComponent().path))
    .allSatisfy { !$0.hasPrefix(".blocks-export-") }, "Temporary output leaked before emission")
emit(execution)
'''


def main() -> None:
    source = (ROOT / "apps/Blocks/BlocksCLI/main.swift").read_text()
    execution = section(source, "// This non-generic owner", "// Clipboard management deliberately")
    assert ") -> CLIExecutionOutput {" in execution
    assert "exit(" not in execution and "emit(" not in execution
    assert "@_optimize" not in execution
    # Check the real action dispatch (not a fixture copy) terminates each branch.
    dispatch = source.split("switch action {", 1)[1].split("case .translationSourceManage:", 1)[0]
    assert dispatch.count("emit(executeAction(") == 9
    assert "case .screenshotScrollingCancel:" in dispatch
    assert "resultType: ScreenshotScrollingCancelActionResult.self\n            ))" in dispatch

    production = "\n".join([
        "import Darwin\nimport Foundation",
        (CORE / "ActionRegistry.swift").read_text().split("public struct ActionDescriptor:", 1)[0],
        (CORE / "ActionEnvelope.swift").read_text(),
        section(source, "struct CLIExecutionOutput {", "// List output is"),
        section(source, "struct ScreenshotCLIParseError:", "private func optionValue("),
        section(source, "private enum OutputDestinationKind {", "func emitActionFailure<Result:"),
        section(source, "enum BlocksCLITransportError:", "// This non-generic owner"),
        execution,
        FIXTURE,
        HARNESS,
    ])
    scenarios = {
        "success": (0, None), "overwrite": (0, None), "dry-run": (0, None),
        "parse-failure": (2, "fixture_invalid"), "proxy-failure": (5, "broker_unavailable"),
        "identity-failure": (4, "cli_identity_unavailable"), "untrusted-failure": (4, "broker_identity_untrusted"),
        "unknown-failure": (1, "broker_unavailable"), "terminal-failure": (1, "fixture_terminal"),
        "cancelled": (1, "fixture_cancelled"), "existing": (2, "output_exists"),
        "symlink": (2, "output_symlink_rejected"), "destination-changed": (2, "output_destination_changed"),
        "finalize-failure": (2, "output_finalize_failed"), "encoding-failure": (1, "json_encode_failed"),
    }
    with tempfile.TemporaryDirectory(prefix="blocks-cli-execution-") as raw:
        directory = pathlib.Path(raw)
        swift = directory / "main.swift"
        swift.write_text(production)
        binary = directory / "fixture"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", str(swift), "-o", str(binary)], check=True, cwd=ROOT)
        actions = [
            "capture", "history.query", "history.search", "ocr.status", "ocr.retry",
            "history.export", "scrolling.status", "scrolling.finish", "scrolling.cancel",
        ]
        cases = [(name, "scrolling.cancel") for name in scenarios]
        cases.extend(("success", action) for action in actions[:-1])
        for index, (scenario, action) in enumerate(cases):
            case_dir = directory / str(index)
            case_dir.mkdir()
            output = case_dir / "output"
            if scenario in {"existing", "overwrite", "destination-changed"}:
                output.write_bytes(b"original")
            if scenario == "symlink":
                target = case_dir / "target"
                target.write_bytes(b"original")
                output.symlink_to(target)
            action_id = "blocks.screenshot." + action
            result = subprocess.run([str(binary), scenario, str(output), action_id], capture_output=True)
            status, error = scenarios[scenario]
            assert result.returncode == status, (scenario, result.returncode, result.stderr)
            if scenario == "encoding-failure":
                assert result.stdout == b""
                assert result.stderr == b'{"ok":false,"error":{"code":"json_encode_failed","message":"Unable to encode output."}}\n'
            else:
                assert result.stderr == b"", (scenario, result.stderr)
                envelope = json.loads(result.stdout)
                assert envelope["request_id"] == "req_fixture" and envelope["action_id"] == action_id
                assert envelope["protocol_version"] == 1
                assert envelope.get("error", {}).get("code") == error, (scenario, envelope)
                assert result.stdout.endswith(b"\n")
                if scenario == "dry-run":
                    assert envelope["result"] == {"dry_run": True, "request": {"value": "fixture"}}
                elif scenario in {"success", "overwrite"}:
                    assert envelope["status"] == "completed" and envelope["result"] == {"value": "ok"}
                else:
                    assert envelope["status"] == ("cancelled" if scenario == "cancelled" else "failed")
            assert not list(case_dir.glob(".blocks-export-*")), scenario
            if scenario in {"success", "overwrite", "encoding-failure"}:
                assert output.read_bytes() == b"fixture-output"
                assert output.stat().st_mode & 0o777 == 0o600
            elif scenario in {"existing", "symlink"}:
                assert output.read_bytes() == b"original"
            elif scenario == "destination-changed":
                assert output.read_bytes() == b"replacement"
            elif scenario == "finalize-failure":
                assert output.is_dir()
            else:
                assert not output.exists(), scenario
        print(f"CLI execution/output checks passed ({len(cases)} isolated -O cases; no XPC; Xcode 27 unverified).")


if __name__ == "__main__":
    main()
