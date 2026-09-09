#!/usr/bin/env python3
"""Compile production feedback/CLI sources and run fixture-only tests; never runs gh.

Uses a minimal BlocksCore module containing production feedback sources and the
actual shared envelope/ID definitions. This is not a replacement for app builds.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksCore"
TESTS = ROOT / "apps/Blocks/BlocksAppTests/FeedbackTests.swift"

HARNESS = r'''
import BlocksCore
import Foundation
import XCTest

final class CLIFakeGitHub: FeedbackGitHubServing, @unchecked Sendable {
    var posts = 0
    var probes = 0
    func doctor() -> FeedbackDoctor {
        probes += 1
        return FeedbackDoctor(ghAvailable: true, account: "fixture-user", code: "ready")
    }
    func create(title: String, body: String) throws -> String {
        posts += 1
        return "https://github.com/winx402/blocks-mac/issues/900"
    }
    func find(marker: String, account: String) throws -> String? { nil }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let store = FeedbackStore(directory: directory.appendingPathComponent("cli-store"), appVersion: "1.2.3")
let fake = CLIFakeGitHub()
let service = FeedbackService(store: store, client: fake)
func check(_ args: [String], code: String? = nil) {
    let (result, status) = FeedbackCLI.run(args: args, service: service)
    precondition(result.error?.code == code, "Unexpected CLI code for \(args.first ?? "none"): \(result.error?.code ?? "success")")
    precondition((status == 0) == (code == nil))
    precondition((try? JSONEncoder().encode(result)) != nil)
}
do {
    check(["submit", "--latest"], code: "confirmation_required")
    check(["create", "--title", "example", "--body-file", "/not/read"], code: "confirmation_required")
    check(["preview", "--latest", "--id", UUID().uuidString], code: "invalid_arguments")
    check(["preview", "--latest", "--latest"], code: "invalid_arguments")
    check(["list", "--confirm"], code: "invalid_arguments")
    check(["create", "--dry-run", "--confirm"], code: "invalid_arguments")
    check(["list"])
    try store.recordShutdownEvent(FeedbackShutdownEvent(attemptID: UUID(), phase: "failed", participant: "database", code: "timeout", elapsedMS: 40, forced: false, activeOperations: 1))
    check(["preview", "--latest"])
    check(["create", "--title", "Fixture", "--body-file", directory.appendingPathComponent("body.txt").path, "--dry-run"])
    check(["create", "--title", "Fixture", "--body-file", directory.appendingPathComponent("credential.txt").path, "--dry-run"], code: "credential_detected")
    precondition(fake.posts == 0 && fake.probes == 0, "Previews must make no external calls")
    check(["doctor"])
    check(["submit", "--latest", "--confirm"])
    precondition(fake.posts == 1)
    check(["submit", "--latest", "--confirm"])
    precondition(fake.posts == 1, "Confirmed duplicate must not POST twice")
    print("Feedback CLI fixture checks passed (14 cases; no network).")
} catch { fatalError("Fixture setup failed: \(error)") }
'''


def main() -> None:
    platform = pathlib.Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip())
    test_frameworks = platform / "Developer/Library/Frameworks"
    test_libraries = platform / "Developer/usr/lib"
    private_frameworks = platform / "Developer/Library/PrivateFrameworks"
    with tempfile.TemporaryDirectory(prefix="blocks-feedback-fixture-") as raw:
        directory = pathlib.Path(raw).resolve()
        # Reuse just the production IDs; other ActionRegistry entries pull in unrelated modules.
        registry = (CORE / "ActionRegistry.swift").read_text()
        (directory / "IDs.swift").write_text(registry.split("public enum BlocksAction:", 1)[0])
        module_sources = [*sorted(CORE.glob("Feedback*.swift")), CORE / "ActionEnvelope.swift", directory / "IDs.swift"]
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-emit-library", "-emit-module", "-enable-testing",
            "-module-name", "BlocksCore", "-emit-module-path", str(directory / "BlocksCore.swiftmodule"),
            *map(str, module_sources), "-o", str(directory / "libBlocksCore.dylib"),
        ], check=True, cwd=ROOT)
        (directory / "main.swift").write_text(HARNESS + "\nlet suite = FeedbackTests.defaultTestSuite\nsuite.run()\nexit(suite.testRun?.hasSucceeded == true ? 0 : 1)\n")
        (directory / "body.txt").write_text("A fixture-only issue body.")
        (directory / "credential.txt").write_text("api_key=fixture-credential-not-real")
        binary = directory / "feedback-fixture-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-I", str(directory), "-L", str(directory), "-lBlocksCore",
            "-F", str(test_frameworks), "-Xlinker", "-rpath", "-Xlinker", str(test_frameworks),
            "-I", str(test_libraries), "-L", str(test_libraries), "-Xlinker", "-rpath", "-Xlinker", str(test_libraries),
            "-Xlinker", "-rpath", "-Xlinker", str(private_frameworks),
            "-Xlinker", "-rpath", "-Xlinker", str(directory),
            str(ROOT / "apps/Blocks/BlocksCLI/FeedbackCLI.swift"), str(TESTS), str(directory / "main.swift"),
            "-o", str(binary),
        ], check=True, cwd=ROOT)
        subprocess.run([str(binary), str(directory)], check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
