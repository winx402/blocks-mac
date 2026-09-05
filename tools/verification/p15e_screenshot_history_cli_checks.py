#!/usr/bin/env python3
"""P15-E screenshot history Action/CLI contract and file-safety checks."""

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
SERVICE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Screenshot" / "Integration" / "ScreenshotHistoryActionService.swift"
HISTORY_REPOSITORY = CORE / "ClipboardRepository+ScreenshotActions.swift"
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
        throw NSError(domain: "P15E", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

@main
struct ContractFixture {
    static func main() throws {
        let expectedScreenshotActions = [
            "blocks.screenshot.capture",
            "blocks.screenshot.history.query",
            "blocks.screenshot.history.search",
            "blocks.screenshot.ocr.status",
            "blocks.screenshot.ocr.retry",
            "blocks.screenshot.history.export",
            "blocks.screenshot.scrolling.status",
            "blocks.screenshot.scrolling.finish",
            "blocks.screenshot.scrolling.cancel",
        ]
        let screenshotActions = BlocksAction.allCases
            .map(\.rawValue)
            .filter { $0.hasPrefix("blocks.screenshot.") }
        let registeredScreenshotActions = ActionRegistry.actions
            .map(\.actionID.rawValue)
            .filter { $0.hasPrefix("blocks.screenshot.") }
        try require(screenshotActions == expectedScreenshotActions, "screenshot action IDs")
        try require(registeredScreenshotActions == expectedScreenshotActions, "screenshot registry order")

        let queryDefaults = try JSONDecoder().decode(
            ScreenshotHistoryQueryActionInput.self,
            from: Data("{}".utf8)
        )
        try require(queryDefaults.cursor == nil, "query cursor default")
        try require(queryDefaults.limit == 24, "query limit default")
        try require(!queryDefaults.includeOCR, "query include OCR default")
        _ = try ScreenshotHistoryQueryActionInput(limit: 1)
        _ = try ScreenshotHistoryQueryActionInput(limit: 100)
        for invalid in [0, 101] {
            do {
                _ = try ScreenshotHistoryQueryActionInput(limit: invalid)
                throw NSError(domain: "P15E", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid limit accepted"])
            } catch ScreenshotHistoryActionValidationError.invalidLimit {
            }
        }

        let search = try ScreenshotHistorySearchActionInput(
            query: "needle",
            cursor: "cursor-v1",
            limit: 100,
            includeOCR: true
        )
        let searchJSON = try encodedObject(search)
        try require(searchJSON["query"] as? String == "needle", "search query")
        try require(searchJSON["cursor"] as? String == "cursor-v1", "search cursor")
        try require(searchJSON["limit"] as? Int == 100, "search limit")
        try require(searchJSON["include_ocr"] as? Bool == true, "search include OCR key")
        do {
            _ = try ScreenshotHistorySearchActionInput(query: "   ")
            throw NSError(domain: "P15E", code: 3, userInfo: [NSLocalizedDescriptionKey: "blank query accepted"])
        } catch ScreenshotHistoryActionValidationError.invalidQuery {
        }

        let item = ScreenshotHistoryActionItem(
            recordID: "record-1",
            createdAt: Date(timeIntervalSince1970: 10),
            lastCopiedAt: Date(timeIntervalSince1970: 20),
            pixelSize: ScreenshotPixelDimensions(width: 1200, height: 800),
            isFavorite: true,
            tags: ["screenshot"],
            title: nil,
            ocrState: .succeeded,
            contentRevision: 4,
            ocrSummary: "bounded",
            ocr: nil
        )
        let itemJSON = try encodedObject(item)
        let expectedItemKeys: Set<String> = [
            "record_id", "created_at", "last_copied_at", "pixel_size", "is_favorite",
            "tags", "title", "ocr_state", "content_revision", "ocr_summary",
        ]
        try require(Set(itemJSON.keys) == expectedItemKeys, "history item fields")

        let status = ScreenshotOCRStatusActionResult(items: [
            ScreenshotOCRStatusActionItem(
                recordID: "record-1",
                ocrState: .running,
                captureIdentityRevision: "identity-2",
                contentRevision: 5
            )
        ])
        let statusJSON = try encodedObject(status)
        try require(statusJSON["items"] != nil, "status items")
        let notRequiredJSON = String(
            data: try JSONEncoder().encode(ScreenshotOCRActionState.notRequired),
            encoding: .utf8
        )
        try require(notRequiredJSON == "\"not_required\"", "not-required status encoding")

        let retry = ScreenshotOCRRetryActionResult(
            recordID: "record-1",
            captureIdentityRevision: "identity-2",
            contentRevision: 5
        )
        let retryJSON = try encodedObject(retry)
        try require(retryJSON["ocr_state"] as? String == "pending", "retry pending")
        try require(retryJSON["record_id"] as? String == "record-1", "retry record")
        try require(retryJSON["capture_identity_revision"] as? String == "identity-2", "retry identity")
        try require(retryJSON["content_revision"] as? Int == 5, "retry content revision")
        do {
            _ = try JSONDecoder().decode(
                ScreenshotOCRRetryActionResult.self,
                from: Data("""
                {
                  "ocr_state": "succeeded",
                  "record_id": "record-1",
                  "capture_identity_revision": "identity-2",
                  "content_revision": 5
                }
                """.utf8)
            )
            throw NSError(domain: "P15E", code: 4, userInfo: [NSLocalizedDescriptionKey: "non-pending retry decoded"])
        } catch is DecodingError {
        }

        let exported = ScreenshotHistoryExportActionResult(bytesWritten: 2048, format: .jpeg)
        let exportJSON = try encodedObject(exported)
        try require(Set(exportJSON.keys) == ["bytes_written", "format"], "export fields")
        try require(exportJSON["bytes_written"] as? Int == 2048, "export bytes")

        let capture = ScreenshotCaptureActionResult(
            captureID: "capture-1",
            kind: .region,
            displayScope: nil,
            pixelSize: ScreenshotPixelDimensions(width: 100, height: 80),
            pasteboard: .succeeded,
            history: .notRequested,
            output: .failed
        )
        let captureJSON = try encodedObject(capture)
        try require(captureJSON["pasteboard"] as? String == "succeeded", "pasteboard sink")
        try require(captureJSON["history"] as? String == "not_requested", "history sink")
        try require(captureJSON["output"] as? String == "failed", "output sink")
        try require(captureJSON["copied"] == nil, "legacy copied removed")
        try require(captureJSON["output_path"] == nil, "legacy output path removed")

        print("P15E_CONTRACT_OK")
    }
}
'''

FILE_SAFETY_FIXTURE = r'''
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

__PRODUCTION_FILE_SAFETY__

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "P15EFile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct FileSafetyFixture {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("blocks-p15e-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.png")
        try Data("preserve".utf8).write(to: existing)
        let symlink = root.appendingPathComponent("link.png")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: existing)

        do {
            _ = try prepareOutputDestination(path: symlink.path, allowOverwrite: true)
            throw NSError(domain: "P15EFile", code: 2, userInfo: [NSLocalizedDescriptionKey: "symlink accepted"])
        } catch let error as ScreenshotCLIParseError {
            try require(error.code == "output_symlink_rejected", "symlink error code")
        }

        do {
            _ = try prepareOutputDestination(path: existing.path, allowOverwrite: false)
            throw NSError(domain: "P15EFile", code: 3, userInfo: [NSLocalizedDescriptionKey: "implicit overwrite accepted"])
        } catch let error as ScreenshotCLIParseError {
            try require(error.code == "output_exists", "overwrite error code")
        }

        var existingDestination = try prepareOutputDestination(
            path: existing.path,
            allowOverwrite: true
        )
        try existingDestination.finish(success: false)
        let preservedData = try Data(contentsOf: existing)
        try require(preservedData == Data("preserve".utf8), "existing file preserved")

        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: existing.path)
        var replacement = try prepareOutputDestination(path: existing.path, allowOverwrite: true)
        try replacement.file.write(contentsOf: Data("replacement".utf8))
        try replacement.finish(success: true)
        let replacementData = try Data(contentsOf: existing)
        try require(replacementData == Data("replacement".utf8), "existing file atomically replaced")
        let replacementPermissions = try manager.attributesOfItem(atPath: existing.path)[.posixPermissions] as? NSNumber
        try require(replacementPermissions?.intValue == 0o600, "replacement permissions")

        let incomplete = root.appendingPathComponent("incomplete.png")
        var incompleteDestination = try prepareOutputDestination(
            path: incomplete.path,
            allowOverwrite: false
        )
        let permissions = try manager.attributesOfItem(
            atPath: incompleteDestination.temporaryURL.path
        )[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600, "created permissions")
        try incompleteDestination.finish(success: false)
        try require(!manager.fileExists(atPath: incomplete.path), "new incomplete file removed")
        try require(
            !manager.fileExists(atPath: incompleteDestination.temporaryURL.path),
            "incomplete temporary file removed"
        )

        let completed = root.appendingPathComponent("completed.png")
        var completedDestination = try prepareOutputDestination(
            path: completed.path,
            allowOverwrite: false
        )
        try completedDestination.finish(success: true)
        try require(manager.fileExists(atPath: completed.path), "completed file preserved")

        print("P15E_FILE_SAFETY_OK")
    }
}
'''


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def add_failure(
    failures: list[dict[str, str]], code: str, detail: str, path: Path | None = None
) -> None:
    failure = {"code": code, "detail": detail}
    if path is not None:
        failure["path"] = rel(path)
    failures.append(failure)


def run_contract_fixture(failures: list[dict[str, str]]) -> None:
    with tempfile.TemporaryDirectory(prefix="blocks_p15e_contract_") as temporary:
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
            tail = (compiled.stdout + "\n" + compiled.stderr).strip().splitlines()[-20:]
            add_failure(failures, "contract_fixture_compile_failed", "\n".join(tail))
            return
        executed = subprocess.run([str(executable)], cwd=ROOT, text=True, capture_output=True)
        if executed.returncode or "P15E_CONTRACT_OK" not in executed.stdout:
            add_failure(failures, "contract_fixture_execution_failed", executed.stderr.strip())


def run_file_safety_fixture(failures: list[dict[str, str]]) -> None:
    cli_source = CLI.read_text(encoding="utf-8")
    begin = "private enum OutputDestinationKind"
    end = "func emitActionFailure<Result: Codable>"
    if begin not in cli_source or end not in cli_source:
        add_failure(failures, "file_safety_fixture_markers_missing", "production extraction markers")
        return
    production = begin + cli_source.split(begin, 1)[1].split(end, 1)[0]
    source = textwrap.dedent(FILE_SAFETY_FIXTURE).replace(
        "__PRODUCTION_FILE_SAFETY__", production
    )
    with tempfile.TemporaryDirectory(prefix="blocks_p15e_file_") as temporary:
        fixture = Path(temporary) / "FileSafetyFixture.swift"
        executable = Path(temporary) / "file-safety-fixture"
        fixture.write_text(source, encoding="utf-8")
        compiled = subprocess.run(
            [
                "xcrun",
                "--sdk",
                "macosx",
                "swiftc",
                "-parse-as-library",
                "-warnings-as-errors",
                str(fixture),
                "-o",
                str(executable),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if compiled.returncode:
            tail = (compiled.stdout + "\n" + compiled.stderr).strip().splitlines()[-20:]
            add_failure(failures, "file_safety_fixture_compile_failed", "\n".join(tail))
            return
        executed = subprocess.run([str(executable)], cwd=ROOT, text=True, capture_output=True)
        if executed.returncode or "P15E_FILE_SAFETY_OK" not in executed.stdout:
            add_failure(failures, "file_safety_fixture_execution_failed", executed.stderr.strip())


def build_cli(failures: list[dict[str, str]], derived_data: Path) -> Path | None:
    completed = subprocess.run(
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
            "-quiet",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if completed.returncode:
        tail = (completed.stdout + "\n" + completed.stderr).strip().splitlines()[-30:]
        add_failure(failures, "cli_build_failed", "\n".join(tail))
        return None
    executable = derived_data / "Build" / "Products" / "Debug" / "blocks"
    if not executable.exists():
        add_failure(failures, "cli_executable_missing", "BlocksCLI executable was not produced")
        return None
    return executable


def run_cli(executable: Path, arguments: list[str]) -> tuple[int, dict[str, Any] | None]:
    completed = subprocess.run(
        [str(executable), *arguments], cwd=ROOT, text=True, capture_output=True
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        payload = None
    return completed.returncode, payload


def is_terminal(payload: dict[str, Any] | None, action_id: str, status: str) -> bool:
    return bool(
        isinstance(payload, dict)
        and payload.get("protocol_version") == 1
        and payload.get("action_id") == action_id
        and payload.get("status") == status
    )


def assert_dry_run(
    failures: list[dict[str, str]],
    executable: Path,
    action_id: str,
    arguments: list[str],
    expected_request: dict[str, Any],
) -> None:
    code, payload = run_cli(executable, ["run", action_id, "--dry-run", *arguments])
    result = payload.get("result", {}) if isinstance(payload, dict) else {}
    if (
        code != 0
        or not is_terminal(payload, action_id, "completed")
        or result.get("dry_run") is not True
        or result.get("request") != expected_request
    ):
        add_failure(failures, "dry_run_contract_wrong", action_id, CLI)


def run_parameter_checks(failures: list[dict[str, str]], executable: Path) -> None:
    cases = [
        (
            "blocks.screenshot.history.query",
            [],
            {"limit": 24, "include_ocr": False},
        ),
        (
            "blocks.screenshot.history.query",
            ["--cursor", "opaque", "--limit", "100", "--include-ocr"],
            {"cursor": "opaque", "limit": 100, "include_ocr": True},
        ),
        (
            "blocks.screenshot.history.search",
            ["--query", "needle", "--include-ocr"],
            {"query": "needle", "limit": 24, "include_ocr": True},
        ),
        (
            "blocks.screenshot.ocr.status",
            ["--record-id", "one", "--record-id", "two"],
            {"record_ids": ["one", "two"]},
        ),
        (
            "blocks.screenshot.ocr.retry",
            ["--record-id", "one"],
            {"record_id": "one"},
        ),
        (
            "blocks.screenshot.history.export",
            ["--record-id", "one", "--output", "/tmp/ignored.png"],
            {"record_id": "one", "format": "png"},
        ),
    ]
    for action_id, arguments, expected in cases:
        assert_dry_run(failures, executable, action_id, arguments, expected)

    invalid_cases = [
        ("blocks.screenshot.history.query", ["--limit", "0"]),
        ("blocks.screenshot.history.query", ["--limit", "101"]),
        ("blocks.screenshot.history.query", ["--limit", "x"]),
        ("blocks.screenshot.history.search", []),
        ("blocks.screenshot.history.search", ["--query", "   "]),
        ("blocks.screenshot.ocr.status", []),
        ("blocks.screenshot.ocr.retry", []),
        ("blocks.screenshot.history.export", ["--record-id", "one"]),
        (
            "blocks.screenshot.history.export",
            ["--record-id", "one", "--output", "/tmp/x", "--format", "gif"],
        ),
    ]
    for action_id, arguments in invalid_cases:
        code, payload = run_cli(executable, ["run", action_id, "--dry-run", *arguments])
        if code != 2 or not is_terminal(payload, action_id, "failed"):
            add_failure(failures, "invalid_arguments_accepted", action_id, CLI)


def run_source_checks(failures: list[dict[str, str]]) -> None:
    sources = {path: path.read_text(encoding="utf-8") for path in [*CORE_SOURCES, CLI]}
    combined = "\n".join(sources.values())
    required = [
        "blocks.screenshot.history.query",
        "blocks.screenshot.history.search",
        "blocks.screenshot.ocr.status",
        "blocks.screenshot.ocr.retry",
        "blocks.screenshot.history.export",
        "O_NOFOLLOW",
        "O_EXCL",
        "S_IRUSR | S_IWUSR",
        "fchmod",
        "replaceItemAt",
        "temporaryURL",
    ]
    for marker in required:
        if marker not in combined:
            add_failure(failures, "contract_marker_missing", marker)

    action_source = sources[CORE / "ScreenshotAction.swift"]
    for legacy in ["public let copied", "case copied"]:
        if legacy in action_source:
            add_failure(failures, "legacy_capture_result_remaining", legacy)

    cli_source = sources[CLI]
    if "base64EncodedString" in cli_source:
        add_failure(failures, "image_stdout_contract_unsafe", "base64 output API used", CLI)
    if "Output directory does not exist:" in cli_source or "Unable to create output file:" in cli_source:
        add_failure(failures, "full_output_path_in_error", "output path interpolation remains", CLI)

    repository_source = HISTORY_REPOSITORY.read_text(encoding="utf-8")
    for marker in ["requireScreenshotRecord", "record.origin == .screenshot", "origin_kind = 'screenshot'"]:
        if marker not in repository_source:
            add_failure(failures, "screenshot_record_scope_missing", marker, HISTORY_REPOSITORY)


def main() -> int:
    failures: list[dict[str, str]] = []
    missing = [path for path in [*CORE_SOURCES, CLI, PROJECT, SERVICE, HISTORY_REPOSITORY] if not path.exists()]
    for path in missing:
        add_failure(failures, "missing_file", "required source is missing", path)
    if missing:
        print(json.dumps({"gate": "P15-E", "status": "fail", "failures": failures}, indent=2))
        return 1

    run_source_checks(failures)
    run_contract_fixture(failures)
    run_file_safety_fixture(failures)
    with tempfile.TemporaryDirectory(prefix="blocks_p15e_derived_") as temporary:
        executable = build_cli(failures, Path(temporary))
        if executable is not None:
            run_parameter_checks(failures, executable)

    payload = {
        "gate": "P15-E",
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "observations": {
            "limit": {"default": 24, "maximum": 100},
            "export": "explicit_path_no_symlink_no_implicit_overwrite_0600",
            "binary_stdout": "forbidden",
        },
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
