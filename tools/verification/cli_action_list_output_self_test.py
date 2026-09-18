#!/usr/bin/env python3
"""Exercise the production list output boundary under -O, without XPC.

Core contracts are compiled as a separate module, matching the actual CLI's
cross-module optional error layout. The fixture replaces only the live provider.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksCore"


def section(source: str, start: str, end: str) -> str:
    offset = source.index(start)
    return source[offset:source.index(end, offset)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=pathlib.Path,
                        help="Also verify a freshly built CLI's real list command (may contact its authenticated Broker).")
    parser.add_argument("--expected-error", help="Require this error code from --cli instead of accepting success.")
    options = parser.parse_args()
    if options.expected_error and not options.cli:
        parser.error("--expected-error requires --cli")
    source = (ROOT / "apps/Blocks/BlocksCLI/main.swift").read_text()
    dispatch = section(source, 'case "list":\n    let actionList', '\ncase "clipboard":')
    dispatch = dispatch.split("\n", 1)[1]
    helpers = section(source, "struct CLIExecutionOutput {", "struct ActionListOutput:")
    contracts = "\n".join([
        (CORE / "ActionRegistry.swift").read_text().split("public enum ActionRegistry {", 1)[0],
        (CORE / "ActionEnvelope.swift").read_text(),
        "import Foundation\npublic struct CLIActionListResponse:" +
            (CORE / "CLIModuleAccess.swift").read_text().split("public struct CLIActionListResponse:", 1)[1],
    ])
    fixture = r'''
let scenario = CommandLine.arguments[1]
@inline(never)
func liveActionList() -> CLIActionListResponse {
    if scenario == "empty" { return .init() }
    if scenario == "success" {
        return .init(actions: [ActionDescriptor(actionID: BlocksAction.clipboardManage.actionID,
            protocolVersion: 1, requestType: "FixtureInput", resultType: "FixtureResult", risk: "synthetic")])
    }
    return .init(error: ActionBrokerError(category: .availability, code: scenario,
        message: "Synthetic denied access", retryable: false, details: ["explicit_enable_required": .bool(true)]))
}
'''
    cases = ["empty", "success", "local_identity_unavailable", "broker_unavailable", "upgrade_required", "invalid_broker_response", "broker_response_timeout"]
    with tempfile.TemporaryDirectory(prefix="blocks-cli-list-output-") as raw:
        root = pathlib.Path(raw)
        core = root / "Contracts.swift"
        core.write_text(contracts)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-emit-library", "-emit-module",
                        "-module-name", "ListFixtureCore", str(core), "-o", str(root / "libListFixtureCore.dylib"),
                        "-emit-module-path", str(root / "ListFixtureCore.swiftmodule")], check=True)
        swift = root / "main.swift"
        swift.write_text("import Foundation\nimport Darwin\nimport ListFixtureCore\n" + helpers + fixture + dispatch)
        binary = root / "fixture"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-I", raw, "-L", raw,
                        "-lListFixtureCore", "-Xlinker", "-rpath", "-Xlinker", raw,
                        str(swift), "-o", str(binary)], check=True)
        for case in cases:
            result = subprocess.run([str(binary), case], capture_output=True, timeout=5)
            success = case in {"empty", "success"}
            assert result.returncode == (0 if success else 1), (case, result.returncode, result.stderr)
            assert not result.stderr, (case, result.stderr)
            value = json.loads(result.stdout)
            if success:
                assert "error" not in value, value
                assert len(value["actions"]) == (1 if case == "success" else 0), value
            else:
                assert value["actions"] == [], value
                assert value["error"]["code"] == case, value
                assert value["error"]["details"] == {"explicit_enable_required": True}, value
            assert result.stdout.endswith(b"\n")
        print(f"CLI list output checks passed ({len(cases)} separate-module -O cases; no XPC).")
    if options.cli:
        result = subprocess.run([str(options.cli.resolve()), "list"], capture_output=True, timeout=20)
        assert result.returncode in (0, 1), ("real CLI", result.returncode, result.stderr)
        assert not result.stderr, result.stderr
        value = json.loads(result.stdout)
        assert isinstance(value["actions"], list), value
        if result.returncode == 0:
            assert "error" not in value, value
        else:
            assert value["actions"] == [] and isinstance(value["error"]["code"], str), value
        if options.expected_error:
            assert result.returncode == 1 and value["error"]["code"] == options.expected_error, value
        print(f"Real CLI list verified (exit {result.returncode}; error={value.get('error', {}).get('code')}).")


if __name__ == "__main__":
    main()
