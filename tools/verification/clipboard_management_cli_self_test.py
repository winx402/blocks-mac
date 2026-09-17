#!/usr/bin/env python3
"""Exercise isolated clipboard CLI parsing and file-I/O boundaries.

This deliberately extracts the parser from BlocksCLI/main.swift and supplies
only harmless Core-shaped stubs. Its files exist only in a new temporary
directory; it never creates an XPC connection, reads user paths, or enables
the CLI broker service.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/Blocks/BlocksCLI/main.swift"
START = "private struct ClipboardCLIInvocation {"
END = "private struct ClipboardManagementTerminalOutput: Codable {"
OUTPUT_START = "private enum OutputDestinationKind {"
OUTPUT_END = "func emitActionFailure<Result: Codable>("
STABLE_START = "private func stableClipboardJSON(_ document: ClipboardImportDocument) throws -> Data {"
STABLE_END = "private func emitClipboardArgumentFailure("


def parser_source() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    try:
        start = source.index(START)
        end = source.index(END, start)
    except ValueError as error:
        raise AssertionError("Clipboard parser markers are missing from main.swift") from error
    return source[start:end]


def output_destination_source() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    try:
        start = source.index(OUTPUT_START)
        end = source.index(OUTPUT_END, start)
    except ValueError as error:
        raise AssertionError("Output destination markers are missing from main.swift") from error
    return source[start:end]


def stable_encoding_source() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    try:
        start = source.index(STABLE_START)
        end = source.index(STABLE_END, start)
    except ValueError as error:
        raise AssertionError("Stable clipboard encoding markers are missing from main.swift") from error
    return source[start:end]


PREAMBLE = r'''
import Darwin
import Foundation

struct ScreenshotCLIParseError: Error {
    let code: String
    let message: String
    init(code: String = "invalid_arguments", message: String) {
        self.code = code
        self.message = message
    }
}

func optionValue(after option: String, at index: Int, in args: [String]) throws -> String {
    guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
        throw ScreenshotCLIParseError(message: "Missing value for \(option).")
    }
    return args[index + 1]
}

func rejectDuplicate(_ option: String, seen: inout Set<String>) throws {
    guard seen.insert(option).inserted else {
        throw ScreenshotCLIParseError(message: "Duplicate option: \(option)")
    }
}

enum ClipboardManagementLimits {
    static let maxDocumentBytes = 32 * 1024 * 1024
    static let maxRecords = 1_000
}

struct ClipboardManagementError: Error {
    let code: String
}

struct ClipboardImportDocument {
    let data: Data
    static func decode(_ data: Data) throws -> ClipboardImportDocument {
        guard data == Data("{\"fixture\":true}".utf8) else {
            throw ClipboardManagementError(code: "invalid_document")
        }
        return ClipboardImportDocument(data: data)
    }
    func encoded() throws -> Data { data }
}

struct ClipboardManagementActionInput {
    let operation: String
    let document: ClipboardImportDocument?
    let dryRun: Bool
    let recordIDs: [String]
    let query: String?
    let pinboardID: String?
    let tag: String?
    let name: String?
    let limit: Int
    let offset: Int
    let all: Bool
    let confirmationToken: String?
    init(
        operation: String,
        document: ClipboardImportDocument? = nil,
        dryRun: Bool = false,
        recordIDs: [String] = [],
        query: String? = nil,
        pinboardID: String? = nil,
        tag: String? = nil,
        name: String? = nil,
        limit: Int = 100,
        offset: Int = 0,
        all: Bool = false,
        confirmationToken: String? = nil
    ) {
        self.operation = operation
        self.document = document
        self.dryRun = dryRun
        self.recordIDs = recordIDs
        self.query = query
        self.pinboardID = pinboardID
        self.tag = tag
        self.name = name
        self.limit = limit
        self.offset = offset
        self.all = all
        self.confirmationToken = confirmationToken
    }
}

let clipboardUsage = "clipboard management"
'''


TESTS = r'''
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func expectError(_ body: () throws -> Void, _ code: String) {
    do {
        try body()
        fatalError("Expected \(code)")
    } catch let error as ScreenshotCLIParseError {
        expect(error.code == code, "Expected \(code), got \(error.code)")
    } catch {
        fatalError("Unexpected error")
    }
}

func makeFixtureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blocks-clipboard-cli-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func fixtureFile(_ url: URL, _ data: Data) throws {
    try data.write(to: url, options: .atomic)
}

func fixtureSparseFile(_ url: URL, size: Int) throws {
    let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)) }
    guard descriptor >= 0 else { fatalError("Unable to create fixture sparse file") }
    defer { Darwin.close(descriptor) }
    guard ftruncate(descriptor, off_t(size)) == 0 else { fatalError("Unable to size fixture sparse file") }
}

do {
    let list = try parseClipboardInvocation(["list"])
    expect(list.input.operation == "list", "list operation")
    expect(list.input.limit == 100 && list.input.offset == 0, "list defaults")

    let export = try parseClipboardInvocation(["export", "--all", "--output", "/tmp/export.json", "--dry-run"])
    expect(export.input.operation == "export" && export.input.all, "export selector")
    expect(export.input.dryRun && export.outputPath == "/tmp/export.json", "export dry run")

    let preview = try parseClipboardInvocation(["delete", "--record-id", "one"])
    expect(preview.input.dryRun && preview.input.confirmationToken == nil, "delete defaults to broker preview")

    let confirmed = try parseClipboardInvocation(["delete", "--record-id", "one", "--confirm", "snapshot-token"])
    expect(!confirmed.input.dryRun && confirmed.input.confirmationToken == "snapshot-token", "delete confirmation")

    expectError({ _ = try parseClipboardInvocation(["export", "--output", "/tmp/export.json"]) }, "invalid_arguments")
    expectError({ _ = try parseClipboardInvocation(["show", "--record-id", "one", "--record-id", "one"]) }, "duplicate_record_id")
    expectError({ _ = try parseClipboardInvocation(["pinboard", "list", "--dry-run"]) }, "invalid_arguments")
    expectError({ _ = try parseClipboardInvocation(["list", "--all", "--tag", "work"]) }, "invalid_arguments")
    expectError({ _ = try parseClipboardInvocation(["export", "--all", "--output", "/tmp/export.json", "--limit", "1"]) }, "invalid_arguments")
    expectError({ _ = try parseClipboardInvocation(["export", "--all", "--tag", "work", "--output", "/tmp/export.json"]) }, "invalid_arguments")
    expectError({ _ = try parseClipboardInvocation(["import", "--file", "fixture.json", "--output", "/tmp/out"]) }, "invalid_arguments")

    let directory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let regularInput = directory.appendingPathComponent("valid.json")
    try fixtureFile(regularInput, Data("{\"fixture\":true}".utf8))
    let imported = try clipboardImportDocument(at: regularInput.path)
    expect(imported.data == Data("{\"fixture\":true}".utf8), "regular import read")
    let canonicalData = try stableClipboardJSON(imported)
    expect(canonicalData == Data("{\"fixture\":true}".utf8), "canonical export bytes")

    let inputLink = directory.appendingPathComponent("input-link.json")
    try FileManager.default.createSymbolicLink(at: inputLink, withDestinationURL: regularInput)
    expectError({ _ = try clipboardImportDocument(at: inputLink.path) }, "import_symlink_rejected")

    let fifo = directory.appendingPathComponent("input.fifo")
    guard mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else { fatalError("Unable to create FIFO fixture") }
    expectError({ _ = try clipboardImportDocument(at: fifo.path) }, "import_not_regular_file")

    let oversized = directory.appendingPathComponent("oversized.json")
    try fixtureSparseFile(oversized, size: ClipboardManagementLimits.maxDocumentBytes + 1)
    expectError({ _ = try clipboardImportDocument(at: oversized.path) }, "document_too_large")

    let output = directory.appendingPathComponent("export.json")
    var destination = try prepareOutputDestination(path: output.path, allowOverwrite: false)
    try destination.file.write(contentsOf: canonicalData)
    try destination.finish(success: true)
    let outputData = try Data(contentsOf: output)
    expect(outputData == canonicalData, "output contents")
    var metadata = stat()
    expect(lstat(output.path, &metadata) == 0, "output metadata")
    expect(metadata.st_mode & mode_t(0o777) == mode_t(0o600), "output mode")
    expectError({ _ = try prepareOutputDestination(path: output.path, allowOverwrite: false) }, "output_exists")

    let outputLink = directory.appendingPathComponent("output-link.json")
    try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: regularInput)
    expectError({ _ = try prepareOutputDestination(path: outputLink.path, allowOverwrite: false) }, "output_symlink_rejected")

    let abandonedOutput = directory.appendingPathComponent("abandoned.json")
    var abandoned = try prepareOutputDestination(path: abandonedOutput.path, allowOverwrite: false)
    try abandoned.finish(success: false)
    expect(!FileManager.default.fileExists(atPath: abandonedOutput.path), "failed output is not published")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    expect(!leftovers.contains(where: { $0.hasPrefix(".blocks-export-") }), "temporary output cleanup")
} catch {
    fatalError("Unexpected parser failure: \(error)")
}
print("clipboard management CLI parser self-test passed")
'''


def main() -> int:
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        print("swiftc is required for this self-test", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="blocks-clipboard-cli-") as directory:
        directory_path = pathlib.Path(directory)
        swift_file = directory_path / "ClipboardCLIParserSelfTest.swift"
        executable = directory_path / "ClipboardCLIParserSelfTest"
        swift_file.write_text(
            PREAMBLE + "\n" + output_destination_source() + "\n" + parser_source() + "\n" + stable_encoding_source() + "\n" + TESTS,
            encoding="utf-8",
        )
        subprocess.run([swiftc, str(swift_file), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
