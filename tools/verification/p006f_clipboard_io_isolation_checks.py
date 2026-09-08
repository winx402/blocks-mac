#!/usr/bin/env python3
"""P006-F clipboard I/O isolation and bounded-work static checks.

This gate deliberately avoids touching the system pasteboard.  Runtime timeout
and promised-data behavior belongs to the named-pasteboard integration tests;
this script fail-closes on production source and target wiring regressions.
"""

from __future__ import annotations

import json
import plistlib
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
BLOCKS = ROOT / "apps" / "Blocks"
APP = BLOCKS / "BlocksApp"
CORE = BLOCKS / "BlocksCore"
BROKER = BLOCKS / "BlocksClipboardBroker"
PROJECT = BLOCKS / "Blocks.xcodeproj" / "project.pbxproj"
BROKER_ENTITLEMENTS = BROKER / "BlocksClipboardBroker.entitlements"
BROKER_TESTS = BLOCKS / "BlocksAppTests" / "ClipboardIOBrokerTests.swift"
BROKER_BEHAVIOR_TESTS = (
    BLOCKS / "BlocksAppTests" / "ClipboardBrokerBehaviorTests.swift"
)
AUTOPASTE = APP / "Services" / "ClipboardAutoPasteCoordinator.swift"
SCREENSHOT_PASTEBOARD = (
    APP / "Features" / "Screenshot" / "Output" / "ScreenshotPasteboardWriter.swift"
)

PRODUCTION_SWIFT_ROOTS = (
    APP,
    CORE,
    BLOCKS / "BlocksCLI",
    BLOCKS / "BlocksActionBroker",
    BLOCKS / "BlocksPluginRunner",
    BLOCKS / "BlocksScreenshotCore",
    BROKER,
)

FORBIDDEN_BROKER_ENTITLEMENTS = {
    "com.apple.security.application-groups",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.automation.apple-events",
    "com.apple.security.temporary-exception.apple-events",
    "com.apple.security.temporary-exception.mach-lookup.global-name",
    "com.apple.security.temporary-exception.shared-preference.read-only",
    "com.apple.security.temporary-exception.shared-preference.read-write",
}

FORBIDDEN_PERSISTENCE_OR_PRIVILEGE_TOKENS = (
    "SMAppService",
    "ServiceManagement",
    "LaunchAgent",
    "LaunchAgents",
    "NSAccessibilityUsageDescription",
    "AXIsProcessTrusted",
    "AXUIElement",
    "URLSession",
    "NWConnection",
    "Network.framework",
    "NSXPCConnection",
    "NSMachPort",
)

FORBIDDEN_OLD_WRITE_TOKENS = (
    "snapshotItems()",
    "pasteboard.pasteboardItems",
    "replaceItems(originalItems)",
    "ClipboardPasteboardWriteFailure",
    "rollbackSucceeded",
)

FORBIDDEN_LOG_FIELDS = (
    "text=",
    "content=",
    "payload=",
    "url=",
    "path=",
    "base64=",
    "ocr=",
    "secret=",
    "credential=",
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def swift_sources(root: Path) -> list[Path]:
    return sorted(root.rglob("*.swift")) if root.exists() else []


def production_swift_sources() -> list[Path]:
    paths: list[Path] = []
    for source_root in PRODUCTION_SWIFT_ROOTS:
        paths.extend(swift_sources(source_root))
    return sorted(set(paths))


def uses_general_pasteboard(source: str) -> bool:
    return (
        re.search(r"\bNSPasteboard\s*\.\s*general\b", source) is not None
        or re.search(
            r"\b(?:pasteboard|board)\s*:\s*NSPasteboard\s*=\s*\.general\b",
            source,
        ) is not None
    )


def method_like_block(source: str, marker: str, budget: int = 12_000) -> str:
    """Return one balanced Swift declaration body, with a bounded fallback."""
    start = source.find(marker)
    if start < 0:
        return ""
    open_brace = source.find("{", start)
    if open_brace < 0:
        return source[start:start + budget]
    depth = 0
    for index in range(open_brace, min(len(source), start + budget)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return source[start:start + budget]


def pbx_configuration_blocks(
    project: str,
    target_name: str,
) -> dict[str, str]:
    marker = f'/* Build configuration list for PBXNativeTarget "{target_name}" */ = {{'
    list_start = project.find(marker)
    if list_start < 0:
        return {}
    list_end = project.find("\n\t\t};", list_start)
    if list_end < 0:
        return {}
    list_block = project[list_start:list_end]
    entries = re.findall(
        r"([A-Z0-9]+)\s*/\*\s*([^*]+?)\s*\*/",
        list_block,
    )
    blocks: dict[str, str] = {}
    for object_id, name in entries:
        object_marker = f"{object_id} /* {name.strip()} */ = {{"
        object_start = project.find(object_marker)
        if object_start < 0:
            continue
        object_end = project.find("\n\t\t};", object_start)
        if object_end >= 0:
            blocks[name.strip()] = project[object_start:object_end]
    return blocks


def ordered(source: str, alternatives: list[tuple[str, ...]]) -> bool:
    cursor = -1
    for choices in alternatives:
        positions = [source.find(choice, cursor + 1) for choice in choices]
        positions = [position for position in positions if position >= 0]
        if not positions:
            return False
        cursor = min(positions)
    return True


def has_async_function(source: str, name: str) -> bool:
    pattern = rf"\bfunc\s+{re.escape(name)}\b[\s\S]{{0,500}}?\basync\b"
    return re.search(pattern, source) is not None


def numeric_contract(source: str, first: int, second: int | None = None) -> bool:
    first_present = re.search(rf"(?<!\d){first}(?:\.0)?(?!\d)", source) is not None
    if second is None:
        return first_present
    return first_present and re.search(rf"(?<!\d){second}(?:\.0)?(?!\d)", source) is not None


def representation_priority_contract(source: str) -> bool:
    """Require the one-family capture priority and its exact family/type map."""
    required_branches = [
        (
            "advertised.contains(.png)",
            "SelectedRepresentation(family: .imagePNG, pasteboardType: .png)",
        ),
        (
            "advertised.contains(.tiff)",
            "SelectedRepresentation(family: .imageTIFF, pasteboardType: .tiff)",
        ),
        (
            "advertised.contains(.fileURL)",
            "SelectedRepresentation(family: .fileURL, pasteboardType: .fileURL)",
        ),
        (
            "advertised.contains(.URL)",
            "SelectedRepresentation(family: .url, pasteboardType: .URL)",
        ),
        (
            "advertised.contains(.rtf)",
            "SelectedRepresentation(family: .richText, pasteboardType: .rtf)",
        ),
        (
            "advertised.contains(.string)",
            "SelectedRepresentation(family: .text, pasteboardType: .string)",
        ),
    ]
    return (
        ordered(source, [(condition, result) for condition, result in required_branches])
        and all(source.count(condition) == 1 for condition, _ in required_branches)
        and all(source.count(result) == 1 for _, result in required_branches)
        and source.count("return SelectedRepresentation(") == len(required_branches)
        and re.search(r"return nil\s*}\s*$", source) is not None
    )


def materialized_write_contract(
    write_source: str,
    prepare_source: str,
    perform_source: str,
) -> bool:
    """Check materialization, fences, and the single destructive publication."""
    direct_write = ordered(
        write_source,
        [
            ("materializeWrite(request)",),
            ("performMaterializedWrite(",),
            ("expectedChangeCount: request.expectedChangeCount",),
            ("operation: .write",),
        ],
    )
    preparation = ordered(
        prepare_source,
        [
            ("materializeWrite(request.write)",),
            ("capturedChangeCount = pasteboardChangeCount()",),
            ("PreparedWrite(",),
        ],
    )
    commit = ordered(
        prepare_source + "\n" + perform_source,
        [
            ("expectedChangeCount = request.write.expectedChangeCount",),
            ("expectedChangeCount: expectedChangeCount",),
        ],
    )
    final_publication = ordered(
        perform_source,
        [
            ("actualBefore = pasteboardChangeCount()",),
            ("expected != actualBefore",),
            ("actualBeforeClear = pasteboardChangeCount()",),
            ("guard actualBeforeClear == actualBefore else",),
            ("afterClear = clearPasteboard()",),
            ("guard pasteboardChangeCount() == afterClear else",),
            ("writeMaterializedPasteboard(",),
            ("purpose: .target",),
            ("lastClearedChangeCount: afterClear",),
        ],
    )
    return (
        direct_write
        and preparation
        and commit
        and final_publication
        and write_source.count("materializeWrite(request)") == 1
        and write_source.count("performMaterializedWrite(") == 1
        and prepare_source.count("materializeWrite(request.write)") == 1
        and perform_source.count("clearPasteboard()") == 1
        and perform_source.count("writeMaterializedPasteboard(") == 1
        and perform_source.count("guard pasteboardChangeCount() == afterClear else") == 1
    )


def test_contract(
    source: str,
    name: str,
    required_assertions: tuple[str, ...],
) -> bool:
    block = method_like_block(source, f"func {name}")
    return bool(block) and all(block.count(assertion) == 1 for assertion in required_assertions)


def p006f_mutations_fail_closed(
    representation_source: str,
    write_source: str,
    prepare_source: str,
    perform_source: str,
    behavior_tests_source: str,
) -> dict[str, bool]:
    """Pure source-shaped adversaries proving the P006-F checks are not vacuous."""
    tests = {
        "target_false": (
            "testTargetFalseWithoutExternalChangeFailsWithoutRestoring",
            (
                "XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)",
                "XCTAssertNil(fixture.pasteboard.string(forType: .string))",
                "XCTAssertEqual(trace.clearCount, 1)",
                "XCTAssertEqual(trace.writeCount, 1)",
                "XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)",
                "XCTAssertEqual(trace.rollbackWriteFailureCount, 0)",
            ),
        ),
        "default_observe": (
            "testFailedWriteDefaultObserveLeavesClearedClipboardWithoutFalseSelfSuppression",
            (
                "XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)",
                "XCTAssertNil(fixture.pasteboard.string(forType: .string))",
                "XCTAssertGreaterThan(failedChangeCount, originalChangeCount)",
                "XCTAssertEqual(observed.status, .skipped)",
                "XCTAssertEqual(observed.skipReason, .unsupported)",
                "XCTAssertEqual(observed.changeCount, failedChangeCount)",
                "XCTAssertEqual(trace.clearCount, 1)",
                "XCTAssertEqual(trace.writeCount, 1)",
                "XCTAssertEqual(trace.typesReadCount, 1)",
                "XCTAssertEqual(trace.stringReadCount, 0)",
                "XCTAssertEqual(trace.dataReadCount, 0)",
            ),
        ),
        "fault_no_rollback": (
            "testFailedWriteFaultDoesNotAttemptRollback",
            (
                "XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)",
                "XCTAssertNil(fixture.pasteboard.string(forType: .string))",
                "XCTAssertGreaterThan(failedChangeCount, originalChangeCount)",
                "XCTAssertEqual(observed.status, .skipped)",
                "XCTAssertEqual(observed.skipReason, .unsupported)",
                "XCTAssertEqual(observed.changeCount, failedChangeCount)",
                "XCTAssertEqual(trace.clearCount, 1)",
                "XCTAssertEqual(trace.writeCount, 1)",
                "XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)",
                "XCTAssertEqual(trace.rollbackWriteFailureCount, 0)",
                "XCTAssertEqual(trace.stringReadCount, 0)",
                "XCTAssertEqual(trace.dataReadCount, 0)",
            ),
        ),
    }
    png_branch = (
        "        if advertised.contains(.png) {\n"
        "            return SelectedRepresentation(family: .imagePNG, pasteboardType: .png)\n"
        "        }\n"
    )
    tiff_branch = (
        "        if advertised.contains(.tiff) {\n"
        "            return SelectedRepresentation(family: .imageTIFF, pasteboardType: .tiff)\n"
        "        }\n"
    )
    results = {
        "priority_swapped": not representation_priority_contract(
            representation_source.replace(
                png_branch + tiff_branch,
                tiff_branch + png_branch,
                1,
            )
        ),
        "priority_deleted": not representation_priority_contract(
            representation_source.replace("advertised.contains(.rtf)", "false", 1)
        ),
        "priority_mapping_wrong": not representation_priority_contract(
            representation_source.replace("family: .imagePNG", "family: .imageTIFF", 1)
        ),
        "prepare_perform_reordered": not materialized_write_contract(
            write_source.replace(
                "let materialized = try materializeWrite(request)\n        return try performMaterializedWrite(",
                "return try performMaterializedWrite(\n            try materializeWrite(request),",
                1,
            ),
            prepare_source,
            perform_source,
        ),
        "clear_moved_early": not materialized_write_contract(
            write_source,
            prepare_source,
            perform_source.replace(
                "let actualBefore = pasteboardChangeCount()",
                "let afterClear = clearPasteboard()\n        let actualBefore = pasteboardChangeCount()",
                1,
            ),
        ),
        "clear_duplicated": not materialized_write_contract(
            write_source,
            prepare_source,
            perform_source.replace(
                "let afterClear = clearPasteboard()",
                "_ = clearPasteboard()\n        let afterClear = clearPasteboard()",
                1,
            ),
        ),
        "post_clear_fence_deleted": not materialized_write_contract(
            write_source,
            prepare_source,
            perform_source.replace(
                "guard pasteboardChangeCount() == afterClear else",
                "guard true else",
                1,
            ),
        ),
        "target_purpose_wrong": not materialized_write_contract(
            write_source,
            prepare_source,
            perform_source.replace("purpose: .target", "purpose: .restore", 1),
        ),
    }
    for label, (name, assertions) in tests.items():
        block = method_like_block(behavior_tests_source, f"func {name}")
        assertion_deleted_source = behavior_tests_source.replace(
            block,
            block.replace(assertions[0], "", 1),
            1,
        )
        results[f"{label}_assertion_deleted"] = not test_contract(
            assertion_deleted_source, name, assertions
        )
        count_mutation = assertions[-1].replace(", 0)", ", 1)")
        assertion_count_source = behavior_tests_source.replace(
            block,
            block.replace(assertions[-1], count_mutation, 1),
            1,
        )
        results[f"{label}_assertion_count_changed"] = not test_contract(
            assertion_count_source,
            name,
            assertions,
        )
    return results


def logger_statements(source: str) -> list[str]:
    lines = source.splitlines()
    statements: list[str] = []
    for index, line in enumerate(lines):
        if re.search(r"\blogger\.(?:debug|info|notice|warning|error|fault)\s*\(", line):
            statements.append("\n".join(lines[index:min(len(lines), index + 12)]))
    return statements


def add_check(
    checks: dict[str, bool],
    failures: list[dict[str, Any]],
    name: str,
    condition: bool,
    detail: str,
    paths: list[Path] | None = None,
) -> None:
    checks[name] = condition
    if not condition:
        failure: dict[str, Any] = {"check": name, "detail": detail}
        if paths:
            failure["paths"] = [rel(path) for path in paths]
        failures.append(failure)


def main() -> int:
    checks: dict[str, bool] = {}
    failures: list[dict[str, Any]] = []

    project = read(PROJECT)
    broker_paths = swift_sources(BROKER)
    broker_source = "\n".join(read(path) for path in broker_paths)
    app_paths = swift_sources(APP)
    app_source = "\n".join(read(path) for path in app_paths)
    core_source = "\n".join(read(path) for path in swift_sources(CORE))
    production_paths = production_swift_sources()

    add_check(
        checks,
        failures,
        "broker_target_sources_exist",
        bool(broker_paths) and bool(broker_source),
        "BlocksClipboardBroker must have production Swift sources.",
        [BROKER],
    )

    general_pasteboard_hits = [
        path for path in production_paths
        if uses_general_pasteboard(read(path)) and not path.is_relative_to(BROKER)
    ]
    add_check(
        checks,
        failures,
        "general_pasteboard_is_broker_only",
        not general_pasteboard_hits and uses_general_pasteboard(broker_source),
        "Every NSPasteboard.general access must live in BlocksClipboardBroker.",
        general_pasteboard_hits or [BROKER],
    )

    broker_boundary_sources = [
        path for path in app_paths + swift_sources(CORE)
        if "ClipboardBroker" in read(path)
    ]
    broker_boundary = "\n".join(read(path) for path in broker_boundary_sources)
    broker_client_paths = [
        path for path in broker_boundary_sources
        if "ClipboardBroker" in path.name
    ]
    broker_client_source = "\n".join(read(path) for path in broker_client_paths)
    broker_runtime = "\n".join(
        read(path) for path in broker_client_paths + broker_paths
    )
    autopaste_source = read(AUTOPASTE)
    screenshot_pasteboard_source = read(SCREENSHOT_PASTEBOARD)
    add_check(
        checks,
        failures,
        "app_exposes_async_clipboard_boundary",
        bool(broker_boundary_sources)
        and has_async_function(broker_boundary, "observe")
        and has_async_function(broker_boundary, "write")
        and has_async_function(broker_boundary, "validate")
        and has_async_function(broker_boundary, "currentPlainText"),
        "The app-side broker boundary must expose async observe/write/validate/currentPlainText operations.",
        broker_boundary_sources or [APP],
    )

    protocol_source = broker_boundary + "\n" + broker_source + "\n" + core_source
    add_check(
        checks,
        failures,
        "broker_uses_process_pipes_and_binary_plist_frames",
        all(
            token in protocol_source
            for token in ("Process", "Pipe", "PropertyListEncoder", "PropertyListDecoder")
        )
        and ".binary" in protocol_source
        and any(token in protocol_source for token in ("UInt32", "bigEndian", "lengthPrefix")),
        "Broker IPC must use a child Process and length-prefixed binary-plist pipes.",
        broker_boundary_sources + broker_paths,
    )

    broker_build_configurations = pbx_configuration_blocks(
        project,
        "BlocksClipboardBroker",
    )
    required_configuration_names = {"Debug", "Release"}
    if "AppStoreRelease" in project:
        required_configuration_names.add("AppStoreRelease")
    broker_configurations_safe = all(
        "CODE_SIGN_ENTITLEMENTS = BlocksClipboardBroker/BlocksClipboardBroker.entitlements;" in block
        and "PRODUCT_NAME = BlocksClipboardBroker;" in block
        and "SKIP_INSTALL = YES;" in block
        for name, block in broker_build_configurations.items()
        if name in required_configuration_names
    )
    add_check(
        checks,
        failures,
        "broker_is_embedded_command_line_target",
        project.count("BlocksClipboardBroker") >= 5
        and "com.apple.product-type.tool" in project
        and "BlocksClipboardBroker in Embed Clipboard Broker" in project
        and "Normalize Clipboard Broker Entitlements" in project
        and r'--entitlements \"$entitlements\"' in project
        and "dstSubfolderSpec = 6;" in project
        and "remoteInfo = BlocksClipboardBroker;" in project
        and required_configuration_names <= set(broker_build_configurations)
        and broker_configurations_safe,
        "Sandboxed distribution configurations must embed the signed inherit-only ClipboardBroker.",
        [PROJECT],
    )

    entitlements: dict[str, Any] = {}
    entitlement_parse_ok = False
    if BROKER_ENTITLEMENTS.exists():
        try:
            with BROKER_ENTITLEMENTS.open("rb") as handle:
                parsed = plistlib.load(handle)
            if isinstance(parsed, dict):
                entitlements = parsed
                entitlement_parse_ok = True
        except (OSError, plistlib.InvalidFileException):
            pass
    add_check(
        checks,
        failures,
        "broker_entitlements_are_sandbox_inherit_only",
        entitlement_parse_ok
        and entitlements.get("com.apple.security.app-sandbox") is True
        and entitlements.get("com.apple.security.inherit") is True
        and not (set(entitlements) & FORBIDDEN_BROKER_ENTITLEMENTS)
        and set(entitlements) <= {
            "com.apple.security.app-sandbox",
            "com.apple.security.inherit",
        },
        "Sandboxed-host Broker entitlements must contain only app-sandbox + inherit.",
        [BROKER_ENTITLEMENTS],
    )
    local_entitlements = BLOCKS / "BlocksApp/Blocks-LocalDevelopment.entitlements"
    try:
        local_policy = plistlib.loads(local_entitlements.read_bytes())
    except (OSError, plistlib.InvalidFileException):
        local_policy = None
    add_check(
        checks,
        failures,
        "local_broker_matches_nonsandboxed_host",
        local_policy == {}
        and 'CODE_SIGN_ENTITLEMENTS = "BlocksApp/Blocks-LocalDevelopment.entitlements";'
            in broker_build_configurations.get("LocalDevelopment", "")
        and r'if [ \"${CONFIGURATION}\" = \"LocalDevelopment\" ]; then' in project
        and r'entitlements=\"${SRCROOT}/BlocksApp/Blocks-LocalDevelopment.entitlements\"' in project,
        "Only LocalDevelopment uses empty Broker entitlements, matching its nonsandboxed host; the final normalization must select that policy too.",
        [PROJECT, local_entitlements],
    )

    persistence_hits = [
        token for token in FORBIDDEN_PERSISTENCE_OR_PRIVILEGE_TOKENS
        if token in broker_runtime
    ]
    broker_non_entitlement_plists = [
        path for path in BROKER.rglob("*.plist")
        if path != BROKER_ENTITLEMENTS
    ] if BROKER.exists() else []
    add_check(
        checks,
        failures,
        "broker_has_no_persistent_or_privileged_registration",
        not persistence_hits and not broker_non_entitlement_plists,
        "Broker must not use LaunchAgent, Mach/XPC, Accessibility, network, App Group, or service registration.",
        broker_paths + broker_client_paths + broker_non_entitlement_plists,
    )

    scheduling_source = broker_boundary
    add_check(
        checks,
        failures,
        "passive_capture_has_bounded_latest_only_backpressure",
        re.search(r"in.?flight", scheduling_source, re.IGNORECASE) is not None
        and re.search(r"(latest|pending)", scheduling_source, re.IGNORECASE) is not None
        and re.search(r"(coalesc|replace|pending)", scheduling_source, re.IGNORECASE) is not None,
        "Passive observe scheduling must retain at most one in-flight request and one latest pending request.",
        broker_boundary_sources or [APP],
    )

    add_check(
        checks,
        failures,
        "timeout_kills_and_restarts_broker",
        numeric_contract(scheduling_source, 1)
        and re.search(r"(SIGKILL|kill\s*\(|\.terminate\s*\()", scheduling_source) is not None
        and re.search(r"restart", scheduling_source, re.IGNORECASE) is not None
        and re.search(r"generation", scheduling_source, re.IGNORECASE) is not None,
        "Raw clipboard requests must have a one-second deadline followed by deterministic kill/restart and generation rollover.",
        broker_boundary_sources or [APP],
    )

    add_check(
        checks,
        failures,
        "passive_restart_circuit_breaker_is_bounded",
        re.search(r"circuit", scheduling_source, re.IGNORECASE) is not None
        and re.search(r"(restart|failure)", scheduling_source, re.IGNORECASE) is not None
        and numeric_contract(scheduling_source, 3, 30),
        "Three passive broker restarts within 30 seconds must open a 30-second circuit breaker.",
        broker_boundary_sources or [APP],
    )

    add_check(
        checks,
        failures,
        "poisoned_change_count_is_not_reparsed",
        re.search(r"poison", scheduling_source, re.IGNORECASE) is not None
        and "changeCount" in scheduling_source,
        "A timed-out/poisoned changeCount needs an explicit no-retry guard.",
        broker_boundary_sources or [APP],
    )

    add_check(
        checks,
        failures,
        "remote_and_sensitive_markers_skip_representation_reads",
        all(
            token.lower() in protocol_source.lower()
            for token in ("Transient", "Concealed", "AutoGenerated", "remote")
        )
        and re.search(r"(skip|ignored|reject)", protocol_source, re.IGNORECASE) is not None,
        "Remote, transient, concealed, and auto-generated marker policy must be represented before content reads.",
        broker_paths + broker_boundary_sources,
    )

    observe_source = method_like_block(broker_source, "private func observe(")
    add_check(
        checks,
        failures,
        "observe_prefilters_before_single_content_read",
        ordered(
            observe_source,
            [
                ("prefilterDisposition",),
                ("pasteboardTypes()",),
                ("PasteboardMarkers.sensitive",),
                ("PasteboardMarkers.remote",),
                ("preferredRepresentation",),
                ("readSelectedRepresentation",),
                ("observedAfter",),
            ],
        )
        and observe_source.count("pasteboardTypes()") == 1
        and broker_source.count("return pasteboard.types") == 1,
        "Observe must prefilter, read types once, reject markers, select once, read once, then verify changeCount.",
        broker_paths or [BROKER],
    )

    representation_source = method_like_block(
        broker_source,
        "private func preferredRepresentation",
    )
    add_check(
        checks,
        failures,
        "single_representation_priority_is_explicit",
        representation_priority_contract(representation_source)
        and re.search(r"(selected|preferred).*representation", broker_source, re.IGNORECASE) is not None,
        "Representation choice must be exactly PNG, TIFF, file URL, URL, RTF, then text with one correctly mapped family.",
        broker_paths or [BROKER],
    )

    selected_read_source = method_like_block(
        broker_source,
        "private func readSelectedRepresentation",
    )
    materialize_source = method_like_block(
        broker_source,
        "private func materialize",
    )
    add_check(
        checks,
        failures,
        "rtf_and_file_url_hot_paths_do_not_add_reads",
        "NSAttributedString" in materialize_source
        and "Data(contentsOf:" not in selected_read_source + materialize_source
        and "NSImage(contentsOf:" not in selected_read_source + materialize_source
        and "String(contentsOf:" not in selected_read_source + materialize_source,
        "RTF text must derive locally and file URL capture must not open referenced files.",
        broker_paths or [BROKER],
    )
    add_check(
        checks,
        failures,
        "selected_family_performs_one_representation_call",
        selected_read_source.count("pasteboardString(forType:") == 1
        and selected_read_source.count("pasteboardData(forType:") == 1
        and broker_source.count("return pasteboard.string(forType:") == 1
        and broker_source.count("return pasteboard.data(forType:") == 1
        and "pngData == nil" not in selected_read_source
        and "tiffData = data" not in selected_read_source,
        "Each selected family must execute one string or data call with no PNG-to-TIFF retry.",
        broker_paths or [BROKER],
    )

    add_check(
        checks,
        failures,
        "clipboard_size_limits_are_bounded",
        all(
            re.search(pattern, protocol_source, re.IGNORECASE) is not None
            for pattern in (
                r"(4\s*\*\s*1024\s*\*\s*1024|4_194_304)",
                r"(16\s*\*\s*1024\s*\*\s*1024|16_777_216)",
                r"(32\s*\*\s*1024\s*\*\s*1024|33_554_432)",
                r"(25\s*\*\s*1024\s*\*\s*1024|26_214_400)",
                r"(40\s*\*\s*1024\s*\*\s*1024|41_943_040)",
            )
        ),
        "Text/RTF/raw-image/PNG/frame limits must remain 4/16/32/25/40 MiB.",
        broker_paths + broker_boundary_sources,
    )
    add_check(
        checks,
        failures,
        "large_payload_staging_is_token_scoped_and_private",
        "inlineImageBytes = 1024 * 1024" in protocol_source
        and "UUID(uuidString: token)" in protocol_source
        and "candidate.path.hasPrefix(rootPrefix)" in protocol_source
        and "0o600" in broker_client_source
        and "O_EXCL" in broker_client_source
        and "O_NOFOLLOW" in broker_client_source
        and "openat(" in broker_client_source
        and "fstatat(" in broker_client_source
        and "unlinkat(" in broker_client_source
        and "0o600" in broker_source
        and "O_EXCL" in broker_source
        and "O_NOFOLLOW" in broker_source
        and "openat(" in broker_source
        and "fstatat(" in broker_source
        and "unlinkat(" in broker_source
        and "fstat" in broker_client_source
        and "S_IFREG" in broker_client_source
        and "fstat" in broker_source
        and "S_IFREG" in broker_source
        and "BLOCKS_CLIPBOARD_STAGING_DEVICE" in broker_runtime
        and "BLOCKS_CLIPBOARD_STAGING_INODE" in broker_runtime
        and "pathStillReferencesPinnedRoot" in broker_client_source
        and "rootDescriptor" in broker_source,
        "Payloads above 1 MiB must use an inode-pinned root, device/inode launch validation, token-relative openat/unlinkat calls, and 0600 O_NOFOLLOW regular files.",
        broker_paths + broker_client_paths + [CORE / "ClipboardBrokerProtocol.swift"],
    )
    add_check(
        checks,
        failures,
        "image_write_preparation_is_off_main_actor",
        "stageLargeImagePayloads(in: request)" in broker_client_source
        and "ClipboardBrokerDataTransport.reference(" in broker_client_source
        and "ClipboardBrokerDataTransport.reference(" not in autopaste_source
        and "tiffData(fromPNGData:" not in app_source
        and ".tiffRepresentation" not in app_source
        and "NSBitmapImageRep(data: sourcePNGData)" in broker_source
        and "setData(derivedTIFF, forType: .tiff)" in broker_source
        and "actor ScreenshotPasteboardArtifactStore" in screenshot_pasteboard_source
        and "try await artifactStore.persist(pngData)" in screenshot_pasteboard_source,
        "App MainActor code must submit inline PNG only; staging, TIFF derivation, and screenshot artifact I/O belong to actor/Broker boundaries.",
        [AUTOPASTE, SCREENSHOT_PASTEBOARD, *broker_client_paths, *broker_paths],
    )
    cleanup_source = method_like_block(
        broker_source,
        "func cleanupPinnedRoot(",
    )
    add_check(
        checks,
        failures,
        "staging_cleanup_is_parent_bounded_and_validated",
        "beforeExit:" in broker_source
        and "cleanupPinnedRoot(" in broker_source
        and "AT_SYMLINK_NOFOLLOW" in broker_source
        and "unlinkat(" in broker_source
        and "currentMetadata.st_ino == rootMetadata.st_ino" in broker_source
        and "fdopendir(" in broker_source
        and "Darwin.alarm(1)" in broker_source
        and "FileManager" not in cleanup_source
        and "clipboardBrokerLogger" not in cleanup_source
        and "func finalizeRoot()" in broker_client_source
        and "applicationWillTerminate" in app_source
        and "ClipboardBrokerDataTransport.finalizeRoot()" in app_source
        and "FileManager.default.removeItem(at: rootDirectory)" not in broker_client_source,
        "Parent loss must use hard-deadline pinned-fd cleanup, while normal App termination finalizes its empty pinned root without recursive deletion.",
        broker_paths or [BROKER],
    )

    write_source = method_like_block(broker_source, "private func write(")
    prepare_write_source = method_like_block(broker_source, "private func prepareWrite(")
    perform_write_source = method_like_block(
        broker_source,
        "private func performMaterializedWrite(",
    )
    add_check(
        checks,
        failures,
        "write_path_prepares_then_checks_then_writes_once",
        materialized_write_contract(
            write_source,
            prepare_write_source,
            perform_write_source,
        )
        and broker_source.count("return pasteboard.clearContents()") == 1
        and broker_source.count("return pasteboard.writeObjects(items)") == 1,
        "write/prepareWrite must materialize before their handoff; performMaterializedWrite must retain expected-count and final pre-clear fences, clear once, post-clear fence once, and publish one target.",
        broker_paths or [BROKER],
    )

    clipboard_io_paths = [
        path for path in app_paths
        if "NSPasteboard" in read(path) or "ClipboardPasteboard" in read(path)
    ] + broker_paths
    old_write_hits: list[tuple[Path, str]] = []
    for path in clipboard_io_paths:
        source = read(path)
        for token in FORBIDDEN_OLD_WRITE_TOKENS:
            if path.parent == BROKER and token == "pasteboard.pasteboardItems":
                # The isolated Broker's explicit compatibility-selection
                # snapshot is bounded and never participates in write rollback.
                continue
            if token in source:
                old_write_hits.append((path, token))
    add_check(
        checks,
        failures,
        "old_snapshot_and_rollback_paths_are_absent",
        not old_write_hits,
        "Production clipboard code must not snapshot or restore the old pasteboard.",
        sorted({path for path, _ in old_write_hits}) or broker_paths,
    )

    lease_source = broker_boundary + "\n" + broker_source
    add_check(
        checks,
        failures,
        "write_lease_is_generation_scoped",
        "ClipboardPasteboardWriteLease" in lease_source
        and re.search(r"\bgeneration\b", lease_source) is not None
        and has_async_function(lease_source, "validate"),
        "A write lease must carry broker generation and be validated asynchronously.",
        broker_boundary_sources or [APP],
    )

    add_check(
        checks,
        failures,
        "broker_shutdown_is_parent_bounded",
        re.search(r"(parent|ppid|terminationHandler|shutdown)", protocol_source, re.IGNORECASE) is not None
        and "BLOCKS_CLIPBOARD_PARENT_PID" in protocol_source
        and "updatePassiveMonitoring" in broker_boundary
        and "passiveMonitoringIsActive" in broker_boundary
        and "SIGALRM" in broker_source
        and any(
            token in protocol_source
            for token in (
                "usleep(250_000)",
                "500_000_000",
                ".seconds(1)",
                ".seconds(2)",
                "2_000_000_000",
            )
        ),
        "Broker lifecycle must be tied to feature/App/parent shutdown with a two-second upper bound.",
        broker_paths + broker_boundary_sources,
    )

    telemetry_paths = [
        path for path in broker_paths + app_paths
        if 'category: "ClipboardBroker"' in read(path)
        or 'category: "ClipboardWrite"' in read(path)
    ]
    telemetry_source = "\n".join(read(path) for path in telemetry_paths)
    telemetry_statements = logger_statements(telemetry_source)
    unsafe_log_fields = sorted({
        field
        for field in FORBIDDEN_LOG_FIELDS
        if field in telemetry_source.lower()
    })
    unsafe_log_interpolations = [
        statement for statement in telemetry_statements
        if re.search(
            r"\\\([^)]*\b(?:text|content|payload|url|path|base64|ocr|secret|credential)\b",
            statement,
            re.IGNORECASE,
        )
    ]
    add_check(
        checks,
        failures,
        "telemetry_is_bounded_and_content_free",
        'category: "ClipboardBroker"' in telemetry_source
        and 'category: "ClipboardWrite"' in telemetry_source
        and "start" in telemetry_source.lower()
        and "finish" in telemetry_source.lower()
        and "timeout" in telemetry_source.lower()
        and "kill" in telemetry_source.lower()
        and re.search(
            r"(?:event\s*=\s*|event[=_-])(?:broker-)?restart(?:ed)?",
            telemetry_source,
            re.IGNORECASE,
        ) is not None
        and all(
            token in telemetry_source.lower()
            for token in (
                "request",
                "pid",
                "generation",
                "family",
                "item",
                "type",
                "byte",
                "change",
                "elapsed",
                "status",
            )
        )
        and not unsafe_log_fields
        and not unsafe_log_interpolations,
        "Clipboard telemetry must cover start/finish/timeout/kill/restart without content, URL, path, image, Base64, OCR, or credential values.",
        telemetry_paths or broker_paths + broker_boundary_sources,
    )

    payload_source = read(CORE / "ClipboardRecorderFoundation.swift")
    repository_source = read(CORE / "ClipboardRepository.swift")
    detail_signature_source = read(CORE / "ClipboardDetailEditCommand.swift")
    app_tests_source = "\n".join(
        read(path) for path in swift_sources(BLOCKS / "BlocksAppTests")
    )
    add_check(
        checks,
        failures,
        "payload_runtime_data_and_wire_keys_are_compatible",
        "let rtfData: Data?" in payload_source
        and "let pngData: Data?" in payload_source
        and "rtfDataBase64" not in payload_source
        and "pngDataBase64" not in payload_source
        and '"rtf_data_base64"' in payload_source
        and '"png_data_base64"' in payload_source
        and "testClipboardPayloadCodableKeepsLegacyJSONKeysAndBinaryPlistData" in app_tests_source,
        "ClipboardRecorderPayload must use Data in memory while retaining the legacy JSON keys.",
        [
            CORE / "ClipboardRecorderFoundation.swift",
            BLOCKS / "BlocksAppTests",
        ],
    )
    add_check(
        checks,
        failures,
        "payload_storage_and_digest_avoid_base64_copies",
        "decodeBase64" not in repository_source
        and "SHA256()" in detail_signature_source
        and ".update(data:" in detail_signature_source,
        "Repository storage must keep Data directly and logical digests must update incrementally.",
        [
            CORE / "ClipboardRepository.swift",
            CORE / "ClipboardDetailEditCommand.swift",
        ],
    )

    broker_tests = "\n".join(
        (read(BROKER_TESTS), read(BROKER_BEHAVIOR_TESTS))
    )
    broker_tests_lower = broker_tests.lower()
    failed_write_test_contracts = {
        "testTargetFalseWithoutExternalChangeFailsWithoutRestoring": (
            "XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)",
            "XCTAssertNil(fixture.pasteboard.string(forType: .string))",
            "XCTAssertEqual(trace.clearCount, 1)",
            "XCTAssertEqual(trace.writeCount, 1)",
            "XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)",
            "XCTAssertEqual(trace.rollbackWriteFailureCount, 0)",
        ),
        "testFailedWriteDefaultObserveLeavesClearedClipboardWithoutFalseSelfSuppression": (
            "XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)",
            "XCTAssertNil(fixture.pasteboard.string(forType: .string))",
            "XCTAssertGreaterThan(failedChangeCount, originalChangeCount)",
            "XCTAssertEqual(observed.status, .skipped)",
            "XCTAssertEqual(observed.skipReason, .unsupported)",
            "XCTAssertEqual(observed.changeCount, failedChangeCount)",
            "XCTAssertEqual(trace.clearCount, 1)",
            "XCTAssertEqual(trace.writeCount, 1)",
            "XCTAssertEqual(trace.typesReadCount, 1)",
            "XCTAssertEqual(trace.stringReadCount, 0)",
            "XCTAssertEqual(trace.dataReadCount, 0)",
        ),
        "testFailedWriteFaultDoesNotAttemptRollback": (
            "XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)",
            "XCTAssertNil(fixture.pasteboard.string(forType: .string))",
            "XCTAssertGreaterThan(failedChangeCount, originalChangeCount)",
            "XCTAssertEqual(observed.status, .skipped)",
            "XCTAssertEqual(observed.skipReason, .unsupported)",
            "XCTAssertEqual(observed.changeCount, failedChangeCount)",
            "XCTAssertEqual(trace.clearCount, 1)",
            "XCTAssertEqual(trace.writeCount, 1)",
            "XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)",
            "XCTAssertEqual(trace.rollbackWriteFailureCount, 0)",
            "XCTAssertEqual(trace.stringReadCount, 0)",
            "XCTAssertEqual(trace.dataReadCount, 0)",
        ),
    }
    add_check(
        checks,
        failures,
        "clipboard_broker_behavior_suites_cover_bounded_contracts",
        all(
            suite in broker_tests
            for suite in (
                "ClipboardBrokerProtocolTests",
                "ClipboardLiveCaptureBackpressureTests",
                "ClipboardPasteboardWriterBrokerTests",
                "ClipboardBrokerPolicyTests",
                "ClipboardBrokerBehaviorTests",
            )
        )
        and any(token in broker_tests for token in ("1_000", "1000"))
        and all(
            test_name in broker_tests
            for test_name in (
                "testEarlyRejectionsDoNotReadTypesOrRepresentations",
                "testSensitiveAndRemoteMarkersReadTypesOnceWithoutRepresentations",
                "testRepresentationPriorityRequestsExactlyOneProvider",
                "testPNGFailureDoesNotFallBackToTIFF",
                "testRTFDerivesPlainTextWithoutStringRequest",
                "testFileURLCaptureDoesNotOpenReferencedFIFO",
                "testExpectedChangeCountMismatchDoesNotClearOrWrite",
                "testTargetFalseWithoutExternalChangeFailsWithoutRestoring",
                "testFailedWriteDefaultObserveLeavesClearedClipboardWithoutFalseSelfSuppression",
                "testFailedWriteFaultDoesNotAttemptRollback",
                "testLargePNGWriteKeepsMainActorResponsiveDerivesTIFFAndCleansStaging",
                "testImagePayloadSendsOnlyInlinePNGWithoutAppTIFFOrStaging",
                "testPNGAboveLimitFailsPreflightBeforeLaunchStagingOrIPC",
                "testExplicitWriteBrokerReapsWithinTwoSecondsWhenPassiveMonitoringIsInactive",
                "testPassiveMonitoringKeepsBrokerAliveAndReapsWithinTwoSecondsAfterDeactivation",
                "testAppStagingReadStaysBoundToPinnedRootAfterPathReplacement",
                "testBrokerLaunchRejectsReplacementOfPinnedStagingRoot",
                "testParentWatchdogHardDeadlineExitsWhenCleanupDoesNotReturn",
            )
        )
        and all(
            token in broker_tests_lower
            for token in (
                "nochange",
                "prefilter",
                "representation",
                "richtext",
                "fileurl",
                "inflight",
                "latest",
                "generation",
                "expectedchangecount",
                "rollback",
                "brokergeneration",
                "clipboardbrokerframecodec",
                "rtf_data_base64",
                "png_data_base64",
            )
        )
        and not uses_general_pasteboard(broker_tests),
        "Focused tests must cover no-change/prefilter/one-representation/backpressure/generation/write/no-rollback/frame/Data-wire behavior without the general pasteboard.",
        [BROKER_TESTS, BROKER_BEHAVIOR_TESTS],
    )
    add_check(
        checks,
        failures,
        "failed_write_behavior_tests_assert_no_restore_contract",
        all(
            test_contract(read(BROKER_BEHAVIOR_TESTS), name, assertions)
            for name, assertions in failed_write_test_contracts.items()
        ),
        "The three failed-write behavior tests must each assert the exact cleared/no-rollback outcome and required observe counts.",
        [BROKER_BEHAVIOR_TESTS],
    )
    p006f_mutations = p006f_mutations_fail_closed(
        representation_source,
        write_source,
        prepare_write_source,
        perform_write_source,
        read(BROKER_BEHAVIOR_TESTS),
    )
    add_check(
        checks,
        failures,
        "p006f_contract_mutations_fail_closed",
        all(p006f_mutations.values()),
        "P006-F source-shaped priority, write-fence, target-purpose, and behavior-assertion mutations must fail this gate.",
        [BROKER, BROKER_BEHAVIOR_TESTS],
    )

    result = {
        "gate": "P006-F",
        "ok": not failures,
        "status": "pass" if not failures else "fail",
        "checks": checks,
        "observations": {
            "production_swift_file_count": len(production_paths),
            "broker_source_files": [rel(path) for path in broker_paths],
            "broker_boundary_files": [rel(path) for path in broker_boundary_sources],
            "broker_build_configurations": sorted(broker_build_configurations),
            "general_pasteboard_outside_broker": [
                rel(path) for path in general_pasteboard_hits
            ],
            "old_write_hits": [
                {"path": rel(path), "token": token}
                for path, token in old_write_hits
            ],
            "unsafe_log_fields": unsafe_log_fields,
            "p006f_contract_mutations": p006f_mutations,
        },
        "failures": failures,
        "note": (
            "Static source/target gate only. It never accesses NSPasteboard; "
            "promised-data timeout and UI heartbeat require named-pasteboard tests."
        ),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
