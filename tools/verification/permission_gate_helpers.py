#!/usr/bin/env python3
"""Shared fail-closed source checks for permission verification gates."""

from __future__ import annotations

import re
from collections.abc import Mapping


APP_MODEL_TYPE = "final class AppModel"
PERMISSION_COORDINATOR_TYPE = "final class PermissionFeatureCoordinator"
PERMISSION_STORE_TYPE = "final class PermissionStore"
PERMISSION_REQUESTER_TYPE = "struct DefaultPermissionAccessRequester"
SCREENSHOT_STORE_TYPE = "final class ScreenshotStore"

REQUEST_SCREEN_NO_ARGUMENTS = "func requestScreenRecordingPermissionAssist()"
REQUEST_ACCESSIBILITY_NO_ARGUMENTS = "func requestAccessibilityPermissionAssist()"
REQUEST_SCREEN_STORE = (
    "func requestScreenRecordingPermissionAssist(afterRefresh: (() -> Void)? = nil)"
)
REQUEST_ACCESSIBILITY_STORE = (
    "func requestAccessibilityPermissionAssist(afterRefresh: (() -> Void)? = nil)"
)
REQUEST_SCREEN_ACTION = "func requestScreenRecordingAccess() -> Bool"
REQUEST_ACCESSIBILITY_ACTION = "func requestAccessibilityAccess() -> Bool"
REFRESH_PERMISSION_STATE = "func refreshPermissionState()"
START_PERMISSION_REFRESH = "func startPermissionRefresh()"
START_SCREENSHOT = "func startSmartScreenshot() async -> ScreenshotStartResult"
START_SCREENSHOT_OVERLOAD = (
    "func startSmartScreenshot(startsInScrollingMode: Bool) async -> ScreenshotStartResult"
)


def _balanced_block_end(source: str, opening_brace: int) -> int | None:
    depth = 0
    for index in range(opening_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _exact_signature_start(source: str, signature: str) -> int | None:
    pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(signature)}(?![A-Za-z0-9_])")
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        return None
    return matches[0].start()


def _swift_declaration_span(source: str, signature: str) -> tuple[int, int] | None:
    start = _exact_signature_start(source, signature)
    if start is None:
        return None
    opening_brace = source.find("{", start + len(signature))
    if opening_brace < 0:
        return None
    end = _balanced_block_end(source, opening_brace)
    if end is None:
        return None
    return start, end


def swift_declaration_block(source: str, signature: str) -> str:
    span = _swift_declaration_span(source, signature)
    return source[span[0]:span[1]] if span is not None else ""


def swift_type_members(source: str, declaration_signature: str, type_name: str) -> str:
    """Return the primary declaration plus all extensions from a combined source snapshot."""
    blocks = [swift_declaration_block(source, declaration_signature)]
    extension_pattern = re.compile(rf"\bextension\s+{re.escape(type_name)}\b[^{{]*{{")
    for match in extension_pattern.finditer(source):
        opening_brace = source.find("{", match.start())
        end = _balanced_block_end(source, opening_brace)
        if end is not None:
            blocks.append(source[match.start():end])
    return "\n".join(block for block in blocks if block)


def _normalized_signature(signature: str) -> str:
    normalized = re.sub(r"\s+", " ", signature.strip())
    return re.sub(r"\(\s+|\s+\)", lambda match: "(" if "(" in match.group(0) else ")", normalized)


def _swift_code_only(source: str) -> str:
    """Mask Swift comments and string literals while preserving offsets and lines."""
    masked = list(source)
    length = len(source)
    index = 0

    def mask(start: int, end: int) -> None:
        for position in range(start, min(end, length)):
            if masked[position] not in "\r\n":
                masked[position] = " "

    while index < length:
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            end = length if end < 0 else end
            mask(index, end)
            index = end
            continue
        if source.startswith("/*", index):
            start = index
            index += 2
            depth = 1
            while index < length and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            mask(start, index)
            continue

        raw_hashes = 0
        quote_index = index
        while quote_index < length and source[quote_index] == "#":
            raw_hashes += 1
            quote_index += 1
        if quote_index < length and source[quote_index] == '"':
            start = index
            quote_count = 3 if source.startswith('"""', quote_index) else 1
            index = quote_index + quote_count
            closing = ('"' * quote_count) + ('#' * raw_hashes)
            if raw_hashes or quote_count == 3:
                closing_index = source.find(closing, index)
                index = length if closing_index < 0 else closing_index + len(closing)
            else:
                escaped = False
                while index < length:
                    char = source[index]
                    index += 1
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == '"':
                        break
            mask(start, index)
            continue
        index += 1

    return "".join(masked)


def _contains_exact_code_line(source: str, line: str) -> bool:
    return bool(re.search(
        rf"(?m)^[ \t]*{re.escape(line)}[ \t]*$",
        _swift_code_only(source),
    ))


def _exact_code_line_indices_at_brace_depth(
    source: str,
    line: str,
    brace_depth: int,
) -> list[int]:
    code = _swift_code_only(source)
    matches = re.finditer(rf"(?m)^[ \t]*{re.escape(line)}[ \t]*$", code)
    return [
        match.start()
        for match in matches
        if code[:match.start()].count("{") - code[:match.start()].count("}") == brace_depth
    ]


def _method_span(type_block: str, exact_signature: str) -> tuple[int, int] | None:
    expected = _normalized_signature(exact_signature)
    matches: list[tuple[int, int]] = []
    for candidate in re.finditer(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*", type_block):
        start = candidate.start()
        parenthesis_depth = 0
        opening_brace = -1
        for index in range(start, len(type_block)):
            char = type_block[index]
            if char == "(":
                parenthesis_depth += 1
            elif char == ")":
                parenthesis_depth -= 1
            elif char == "{" and parenthesis_depth == 0:
                opening_brace = index
                break
        if opening_brace < 0:
            continue
        header = _normalized_signature(type_block[start:opening_brace])
        if header != expected:
            continue
        end = _balanced_block_end(type_block, opening_brace)
        if end is not None:
            matches.append((start, end))
    return matches[0] if len(matches) == 1 else None


def _method_block(type_block: str, exact_signature: str) -> str:
    span = _method_span(type_block, exact_signature)
    return type_block[span[0]:span[1]] if span is not None else ""


def _replace_in_exact_method(
    source: str,
    type_signature: str,
    method_signature: str,
    original: str,
    replacement: str,
) -> str | None:
    type_span = _swift_declaration_span(source, type_signature)
    if type_span is None:
        return None
    type_block = source[type_span[0]:type_span[1]]
    method_span = _method_span(type_block, method_signature)
    if method_span is None:
        return None
    method_block = type_block[method_span[0]:method_span[1]]
    if method_block.count(original) != 1:
        return None
    mutated_method = method_block.replace(original, replacement, 1)
    mutated_type = (
        type_block[:method_span[0]]
        + mutated_method
        + type_block[method_span[1]:]
    )
    return source[:type_span[0]] + mutated_type + source[type_span[1]:]


def _replace_all_in_exact_method(
    source: str,
    type_signature: str,
    method_signature: str,
    original: str,
    replacement: str,
) -> str | None:
    type_span = _swift_declaration_span(source, type_signature)
    if type_span is None:
        return None
    type_block = source[type_span[0]:type_span[1]]
    method_span = _method_span(type_block, method_signature)
    if method_span is None:
        return None
    method_block = type_block[method_span[0]:method_span[1]]
    if original not in method_block:
        return None
    mutated_method = method_block.replace(original, replacement)
    mutated_type = (
        type_block[:method_span[0]]
        + mutated_method
        + type_block[method_span[1]:]
    )
    return source[:type_span[0]] + mutated_type + source[type_span[1]:]


def _insert_before_exact_method(
    source: str,
    type_signature: str,
    method_signature: str,
    injected_method: str,
) -> str | None:
    type_span = _swift_declaration_span(source, type_signature)
    if type_span is None:
        return None
    type_block = source[type_span[0]:type_span[1]]
    method_span = _method_span(type_block, method_signature)
    if method_span is None:
        return None
    absolute_method_start = type_span[0] + method_span[0]
    line_start = source.rfind("\n", 0, absolute_method_start) + 1
    indentation = source[line_start:absolute_method_start]
    injected_lines = injected_method.strip().splitlines()
    insertion = "\n".join(
        indentation + line if line else ""
        for line in injected_lines
    ) + "\n\n"
    return source[:line_start] + insertion + source[line_start:]


def permission_request_chain_checks(
    app_model: str,
    permission_coordinator: str,
    permission_store: str,
    permission_actions: str,
) -> dict[str, bool]:
    app_model_type = swift_type_members(app_model, APP_MODEL_TYPE, "AppModel")
    coordinator_type = swift_declaration_block(
        permission_coordinator,
        PERMISSION_COORDINATOR_TYPE,
    )
    store_type = swift_declaration_block(permission_store, PERMISSION_STORE_TYPE)
    requester_type = swift_declaration_block(
        permission_actions,
        PERMISSION_REQUESTER_TYPE,
    )

    app_screen = _method_block(app_model_type, REQUEST_SCREEN_NO_ARGUMENTS)
    app_accessibility = _method_block(app_model_type, REQUEST_ACCESSIBILITY_NO_ARGUMENTS)
    coordinator_screen = _method_block(
        coordinator_type,
        REQUEST_SCREEN_NO_ARGUMENTS,
    )
    coordinator_accessibility = _method_block(
        coordinator_type,
        REQUEST_ACCESSIBILITY_NO_ARGUMENTS,
    )
    store_screen = _method_block(store_type, REQUEST_SCREEN_STORE)
    store_accessibility = _method_block(
        store_type,
        REQUEST_ACCESSIBILITY_STORE,
    )
    actions_screen = _method_block(requester_type, REQUEST_SCREEN_ACTION)
    actions_accessibility = _method_block(requester_type, REQUEST_ACCESSIBILITY_ACTION)

    requester_wiring = (
        "private let accessRequester: PermissionAccessRequesting" in store_type
        and "self.accessRequester = accessRequester ?? DefaultPermissionAccessRequester()" in store_type
    )
    return {
        "screen_appmodel_to_coordinator": (
            "permissionCoordinator.requestScreenRecordingPermissionAssist()" in app_screen
        ),
        "screen_coordinator_to_store": (
            "store.requestScreenRecordingPermissionAssist" in coordinator_screen
        ),
        "screen_store_to_system_actions": (
            requester_wiring
            and "accessRequester.requestScreenRecordingAccess()" in store_screen
        ),
        "screen_system_actions_to_state_service": (
            "PermissionStateService.requestScreenRecordingAccess()" in actions_screen
        ),
        "accessibility_appmodel_to_coordinator": (
            "permissionCoordinator.requestAccessibilityPermissionAssist()" in app_accessibility
        ),
        "accessibility_coordinator_to_store": (
            "store.requestAccessibilityPermissionAssist" in coordinator_accessibility
        ),
        "accessibility_store_to_system_actions": (
            requester_wiring
            and "accessRequester.requestAccessibilityAccess()" in store_accessibility
        ),
        "accessibility_system_actions_to_state_service": (
            "PermissionStateService.requestAccessibilityAccess()" in actions_accessibility
        ),
    }


def permission_request_chain_mutations_fail_closed(
    app_model: str,
    permission_coordinator: str,
    permission_store: str,
    permission_actions: str,
) -> dict[str, bool]:
    mutations = {
        "screen_coordinator_noop": (
            REQUEST_SCREEN_NO_ARGUMENTS,
            "store.requestScreenRecordingPermissionAssist",
            "noOpScreenRecordingPermissionAssist",
            "screen_coordinator_to_store",
        ),
        "accessibility_coordinator_noop": (
            REQUEST_ACCESSIBILITY_NO_ARGUMENTS,
            "store.requestAccessibilityPermissionAssist",
            "noOpAccessibilityPermissionAssist",
            "accessibility_coordinator_to_store",
        ),
    }
    results: dict[str, bool] = {}
    for name, (method_signature, original, replacement, expected_check) in mutations.items():
        mutated_coordinator = _replace_in_exact_method(
            permission_coordinator,
            PERMISSION_COORDINATOR_TYPE,
            method_signature,
            original,
            replacement,
        )
        if mutated_coordinator is None:
            results[name] = False
            continue
        mutated_checks = permission_request_chain_checks(
            app_model,
            mutated_coordinator,
            permission_store,
            permission_actions,
        )
        results[name] = not mutated_checks[expected_check]
    return results


def permission_request_overload_adversary_fails_closed(
    app_model: str,
    permission_coordinator: str,
    permission_store: str,
    permission_actions: str,
) -> dict[str, bool]:
    adversaries = {
        "screen_target_noop_overload_forwards": (
            REQUEST_SCREEN_NO_ARGUMENTS,
            "func requestScreenRecordingPermissionAssist(overloadProbe: Bool)",
            "store.requestScreenRecordingPermissionAssist",
            "noOpScreenRecordingPermissionAssist",
            """
func requestScreenRecordingPermissionAssist(overloadProbe: Bool) {
    store.requestScreenRecordingPermissionAssist { }
}
""",
            "screen_coordinator_to_store",
        ),
        "accessibility_target_noop_overload_forwards": (
            REQUEST_ACCESSIBILITY_NO_ARGUMENTS,
            "func requestAccessibilityPermissionAssist(overloadProbe: Bool)",
            "store.requestAccessibilityPermissionAssist",
            "noOpAccessibilityPermissionAssist",
            """
func requestAccessibilityPermissionAssist(overloadProbe: Bool) {
    store.requestAccessibilityPermissionAssist { }
}
""",
            "accessibility_coordinator_to_store",
        ),
    }
    results: dict[str, bool] = {}
    for name, values in adversaries.items():
        (
            method_signature,
            overload_signature,
            original,
            replacement,
            overload,
            expected_check,
        ) = values
        target_noop = _replace_in_exact_method(
            permission_coordinator,
            PERMISSION_COORDINATOR_TYPE,
            method_signature,
            original,
            replacement,
        )
        if target_noop is None:
            results[name] = False
            continue
        adversarial_source = _insert_before_exact_method(
            target_noop,
            PERMISSION_COORDINATOR_TYPE,
            method_signature,
            overload,
        )
        if adversarial_source is None:
            results[name] = False
            continue
        adversarial_checks = permission_request_chain_checks(
            app_model,
            adversarial_source,
            permission_store,
            permission_actions,
        )
        coordinator_type = swift_declaration_block(
            adversarial_source,
            PERMISSION_COORDINATOR_TYPE,
        )
        overload_block = _method_block(coordinator_type, overload_signature)
        target_block = _method_block(coordinator_type, method_signature)
        results[name] = (
            original in overload_block
            and replacement in target_block
            and original not in target_block
            and not adversarial_checks[expected_check]
        )
    return results


def _direct_code_positions(source: str, pattern: str, depth: int) -> list[int]:
    code = _swift_code_only(source)
    return [
        match.start()
        for match in re.finditer(pattern, code, re.MULTILINE | re.DOTALL)
        if code[:match.start()].count("{") - code[:match.start()].count("}") == depth
    ]


def _task_block(refresh_method: str) -> str:
    code = _swift_code_only(refresh_method)
    match = re.search(
        r"\brefreshTask\s*=\s*Task\s*\{\s*\[\s*weak\s+self\s*\]\s*in",
        code,
    )
    if match is None:
        return ""
    opening_brace = code.find("{", match.start(), match.end())
    end = _balanced_block_end(code, opening_brace)
    return code[match.start():end] if end is not None else ""


def _guard_positions(task: str) -> list[tuple[int, int, str]]:
    code = _swift_code_only(task)
    guards: list[tuple[int, int, str]] = []
    for match in re.finditer(r"\bguard\b", code):
        if code[:match.start()].count("{") - code[:match.start()].count("}") != 1:
            continue
        opening_brace = code.find("{", match.end())
        if opening_brace < 0:
            continue
        guards.append((match.start(), opening_brace, code[match.start():opening_brace]))
    return guards


def _permission_refresh_contract_checks(permission_store: str) -> dict[str, bool]:
    store_type = swift_declaration_block(permission_store, PERMISSION_STORE_TYPE)
    refresh_method = _swift_code_only(_method_block(
        store_type,
        START_PERMISSION_REFRESH,
    ))
    regular_refresh = _swift_code_only(_method_block(store_type, REFRESH_PERMISSION_STATE))
    completion_refresh = _swift_code_only(_method_block(
        store_type,
        "func refreshPermissionState(afterSnapshotPublished: @escaping () -> Void)",
    ))
    task = _task_block(refresh_method)
    guards = _guard_positions(task)

    def direct_one(pattern: str, source: str = refresh_method, depth: int = 1) -> int:
        positions = _direct_code_positions(source, pattern, depth)
        return positions[0] if len(positions) == 1 else -1

    generation_increment = direct_one(r"\brefreshGeneration\s*(?:&\+=|\+=)\s*1\b")
    generation_capture = direct_one(r"\blet\s+generation\s*=\s*refreshGeneration\b")
    cancellation = direct_one(r"\brefreshTask\s*\?\.\s*cancel\s*\(\s*\)")
    task_start = direct_one(r"\brefreshTask\s*=\s*Task\s*\{")
    await_snapshot = direct_one(
        r"\blet\s+snapshot\s*=\s*await\s+snapshotProvider\.snapshot\s*\(\s*\)",
        task,
    )
    publish = direct_one(r"\bself\.permissionSnapshot\s*=\s*snapshot\b", task)
    clear_task = direct_one(r"\bself\.refreshTask\s*=\s*nil\b", task)
    take_waiter = direct_one(
        r"\blet\s+afterSnapshotPublished\s*=\s*self\.afterSnapshotPublished\b",
        task,
    )
    clear_waiter = direct_one(r"\bself\.afterSnapshotPublished\s*=\s*nil\b", task)
    callback = direct_one(r"\bafterSnapshotPublished\s*\?\s*\(\s*\)", task)
    first_guard = guards[0] if len(guards) == 2 else None
    second_guard = guards[1] if len(guards) == 2 else None

    def is_current_guard(guard: tuple[int, int, str] | None, *, owns_self: bool) -> bool:
        if guard is None:
            return False
        clause = guard[2]
        return (
            "!Task.isCancelled" in clause
            and "self.refreshGeneration == generation" in clause
            and (("let self" in clause) if owns_self else ("let self" not in clause))
        )

    unreachable_or_conditional = (
        "#if" in refresh_method
        or bool(re.search(r"\bif\s+false\b", task))
        or any(
            task[:position].count("{") - task[:position].count("}") == 1
            for position in _direct_code_positions(task, r"\breturn\b", 1)
        )
    )
    return {
        "refresh_store_generation_cancel_task_order": (
            -1 < generation_increment < generation_capture < cancellation < task_start
        ),
        "refresh_store_first_current_cancel_guard_before_publish": (
            is_current_guard(first_guard, owns_self=True)
            and -1 < await_snapshot < first_guard[0] < publish
        ),
        "refresh_store_publishes_snapshot": publish >= 0,
        "refresh_store_second_current_cancel_guard_after_publish": (
            is_current_guard(second_guard, owns_self=False)
            and -1 < publish < second_guard[0]
        ),
        "refresh_store_cleanup_waiter_callback_after_second_guard": (
            second_guard is not None
            and -1 < second_guard[0] < clear_task < take_waiter < clear_waiter < callback
        ),
        "refresh_store_waiter_contract": (
            "afterSnapshotPublished" not in regular_refresh
            and "startPermissionRefresh()" in regular_refresh
            and "self.afterSnapshotPublished = afterSnapshotPublished" in completion_refresh
            and completion_refresh.find("self.afterSnapshotPublished = afterSnapshotPublished")
            < completion_refresh.find("startPermissionRefresh()")
        ),
        "refresh_store_task_is_reachable": bool(task) and not unreachable_or_conditional,
    }


def permission_refresh_chain_checks(
    app_model: str,
    permission_coordinator: str,
    permission_store: str,
    screenshot_store: str,
) -> dict[str, bool]:
    app_model_type = swift_type_members(app_model, APP_MODEL_TYPE, "AppModel")
    coordinator_type = swift_declaration_block(
        permission_coordinator,
        PERMISSION_COORDINATOR_TYPE,
    )
    store_type = swift_declaration_block(permission_store, PERMISSION_STORE_TYPE)
    screenshot_type = swift_declaration_block(screenshot_store, SCREENSHOT_STORE_TYPE)

    app_refresh = _method_block(app_model_type, REFRESH_PERMISSION_STATE)
    coordinator_refresh = _method_block(coordinator_type, REFRESH_PERMISSION_STATE)
    screenshot_start = _swift_code_only(_method_block(screenshot_type, START_SCREENSHOT))
    screenshot_start_overload = _swift_code_only(_method_block(
        screenshot_type,
        START_SCREENSHOT_OVERLOAD,
    ))

    no_argument_forward = bool(re.fullmatch(
        r"func startSmartScreenshot\(\) async -> ScreenshotStartResult \{"
        r"\s*await startSmartScreenshot\(startsInScrollingMode: false\)\s*\}",
        screenshot_start,
    ))
    refresh_indices = _exact_code_line_indices_at_brace_depth(
        screenshot_start_overload,
        "permissionRefresher()",
        1,
    )
    snapshot_indices = _exact_code_line_indices_at_brace_depth(
        screenshot_start_overload,
        "let snapshot = permissionSnapshotProvider()",
        1,
    )
    guard_indices = _exact_code_line_indices_at_brace_depth(
        screenshot_start_overload,
        "guard snapshot.screenRecordingGranted else {",
        1,
    )
    refresh_index = refresh_indices[0] if len(refresh_indices) == 1 else -1
    snapshot_index = snapshot_indices[0] if len(snapshot_indices) == 1 else -1
    guard_index = guard_indices[0] if len(guard_indices) == 1 else -1
    refresh_contract = _permission_refresh_contract_checks(permission_store)
    return {
        "refresh_appmodel_to_coordinator": (
            "permissionCoordinator.refreshPermissionState()" in app_refresh
        ),
        "refresh_appmodel_retries_pending_paste": (
            "clipboardCoordinator.retryPendingPasteIfPossible()" in app_refresh
        ),
        "refresh_coordinator_to_store": "store.refreshPermissionState()" in coordinator_refresh,
        "refresh_store_replaces_snapshot": all(refresh_contract.values()),
        **refresh_contract,
        "screenshot_refreshes_before_permission_guard": (
            no_argument_forward
            and "#if" not in screenshot_start_overload
            and -1 < refresh_index < snapshot_index < guard_index
            and "return" not in screenshot_start_overload[refresh_index:guard_index]
        ),
    }


def permission_refresh_chain_mutations_fail_closed(
    app_model: str,
    permission_coordinator: str,
    permission_store: str,
    screenshot_store: str,
) -> dict[str, bool]:
    original = "store.refreshPermissionState()"
    mutated_coordinator = _replace_in_exact_method(
        permission_coordinator,
        PERMISSION_COORDINATOR_TYPE,
        REFRESH_PERMISSION_STATE,
        original,
        "noOpPermissionStateRefresh()",
    )
    def mutate_refresh(original: str, replacement: str) -> str | None:
        type_span = _swift_declaration_span(permission_store, PERMISSION_STORE_TYPE)
        if type_span is None:
            return None
        type_block = permission_store[type_span[0]:type_span[1]]
        method_span = _method_span(type_block, START_PERMISSION_REFRESH)
        if method_span is None:
            return None
        method = type_block[method_span[0]:method_span[1]]
        if original not in method:
            return None
        mutated_type = (
            type_block[:method_span[0]]
            + method.replace(original, replacement, 1)
            + type_block[method_span[1]:]
        )
        return permission_store[:type_span[0]] + mutated_type + permission_store[type_span[1]:]

    mutated_store = mutate_refresh(
        "self.permissionSnapshot = snapshot",
        "noOpPermissionSnapshotPublish(snapshot)",
    )
    screenshot_forward_removed = _replace_in_exact_method(
        screenshot_store,
        SCREENSHOT_STORE_TYPE,
        START_SCREENSHOT,
        "await startSmartScreenshot(startsInScrollingMode: false)",
        "await startSmartScreenshot(startsInScrollingMode: true)",
    )
    refresh_after_guard = _replace_in_exact_method(
        screenshot_store,
        SCREENSHOT_STORE_TYPE,
        START_SCREENSHOT_OVERLOAD,
        """permissionRefresher()
        let snapshot = permissionSnapshotProvider()
        guard snapshot.screenRecordingGranted else {
            statusRecorder(screenRecordingMissingStatus(snapshot))
            return .screenRecordingPermissionMissing
        }
        let applicationContext""",
        """let snapshot = permissionSnapshotProvider()
        guard snapshot.screenRecordingGranted else {
            statusRecorder(screenRecordingMissingStatus(snapshot))
            return .screenRecordingPermissionMissing
        }
        permissionRefresher()
        let applicationContext""",
    )
    if (
        mutated_coordinator is None
        or mutated_store is None
        or screenshot_forward_removed is None
        or refresh_after_guard is None
    ):
        return {
            "refresh_coordinator_noop": False,
            "refresh_store_publish_noop": False,
            "screenshot_no_argument_forward_removed": False,
            "screenshot_refresh_after_guard": False,
        }
    coordinator_checks = permission_refresh_chain_checks(
        app_model,
        mutated_coordinator,
        permission_store,
        screenshot_store,
    )
    store_checks = permission_refresh_chain_checks(
        app_model,
        permission_coordinator,
        mutated_store,
        screenshot_store,
    )
    forward_checks = permission_refresh_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        screenshot_forward_removed,
    )
    ordering_checks = permission_refresh_chain_checks(
        app_model,
        permission_coordinator,
        permission_store,
        refresh_after_guard,
    )
    mutations = {
        "refresh_coordinator_noop": not coordinator_checks["refresh_coordinator_to_store"],
        "refresh_store_publish_noop": not store_checks["refresh_store_replaces_snapshot"],
        "screenshot_no_argument_forward_removed": not forward_checks[
            "screenshot_refreshes_before_permission_guard"
        ],
        "screenshot_refresh_after_guard": not ordering_checks[
            "screenshot_refreshes_before_permission_guard"
        ],
    }
    adversaries = {
        "refresh_store_first_generation_guard_removed": mutate_refresh(
            "self.refreshGeneration == generation",
            "true",
        ),
        "refresh_store_second_generation_guard_removed": mutate_refresh(
            "self.refreshGeneration == generation\n            else",
            "true\n            else",
        ),
        "refresh_store_cleanup_before_publish": mutate_refresh(
            "self.permissionSnapshot = snapshot\n            guard",
            "self.refreshTask = nil\n            self.permissionSnapshot = snapshot\n            guard",
        ),
        "refresh_store_waiter_before_second_guard": mutate_refresh(
            "self.permissionSnapshot = snapshot\n            guard",
            "let afterSnapshotPublished = self.afterSnapshotPublished\n            self.afterSnapshotPublished = nil\n            self.permissionSnapshot = snapshot\n            guard",
        ),
        "refresh_store_publish_in_if_false": mutate_refresh(
            "self.permissionSnapshot = snapshot",
            "if false { self.permissionSnapshot = snapshot }",
        ),
        "refresh_store_publish_in_closure": mutate_refresh(
            "self.permissionSnapshot = snapshot",
            "let deferredPublish = { self.permissionSnapshot = snapshot }\n            deferredPublish()",
        ),
        "refresh_store_publish_in_if_false_compilation": mutate_refresh(
            "self.permissionSnapshot = snapshot",
            "#if false\n            self.permissionSnapshot = snapshot\n            #endif",
        ),
        "refresh_store_top_level_return_before_publish": mutate_refresh(
            "self.permissionSnapshot = snapshot",
            "return\n            self.permissionSnapshot = snapshot",
        ),
    }
    for name, mutated in adversaries.items():
        mutations[name] = (
            mutated is not None
            and not permission_refresh_chain_checks(
                app_model, permission_coordinator, mutated, screenshot_store
            )["refresh_store_replaces_snapshot"]
        )
    return mutations


def permission_settings_diagnostics_checks(settings: str) -> dict[str, bool]:
    code = _swift_code_only(settings)
    cards = {
        kind: bool(re.search(
            rf"\bPermissionDiagnosticCard\s*\(\s*diagnostic\s*:\s*"
            rf"permissionStore\s*\.\s*permissionSnapshot\s*\.\s*{kind}\s*\)",
            code,
            re.DOTALL,
        ))
        for kind in ("screenRecording", "accessibility", "inputMonitoring")
    }
    return {
        "settings_diagnostics_disclosure": bool(re.search(
            r"\bDisclosureGroup\s*\(\s*isExpanded\s*:\s*\$diagnosticsExpanded\s*\)",
            code,
        )),
        "settings_diagnostics_cards_cover_all_snapshots": all(cards.values()),
    }


def permission_settings_diagnostics_mutations_fail_closed(settings: str) -> dict[str, bool]:
    def remove_card(kind: str) -> str:
        return re.sub(
            r"(\bPermissionDiagnosticCard\s*\(\s*diagnostic\s*:\s*"
            rf"permissionStore\s*\.\s*permissionSnapshot\s*\.\s*){kind}\b",
            r"\1removed" + kind.capitalize(),
            settings,
            count=1,
        )

    mutations = {
        "diagnostics_disclosure_removed": settings.replace(
            "DisclosureGroup(isExpanded: $diagnosticsExpanded)", "VStack", 1
        ),
        "screen_recording_card_removed": remove_card("screenRecording"),
        "accessibility_card_removed": remove_card("accessibility"),
        "input_monitoring_card_removed": remove_card("inputMonitoring"),
    }
    return {
        name: not all(permission_settings_diagnostics_checks(mutated).values())
        for name, mutated in mutations.items()
    }


def permission_refresh_overload_adversary_fails_closed(
    app_model: str,
    permission_coordinator: str,
    permission_store: str,
    screenshot_store: str,
) -> dict[str, bool]:
    target_noop = _replace_in_exact_method(
        permission_coordinator,
        PERMISSION_COORDINATOR_TYPE,
        REFRESH_PERMISSION_STATE,
        "store.refreshPermissionState()",
        "noOpPermissionStateRefresh()",
    )
    if target_noop is None:
        return {"refresh_target_noop_overload_forwards": False}
    adversarial_source = _insert_before_exact_method(
        target_noop,
        PERMISSION_COORDINATOR_TYPE,
        REFRESH_PERMISSION_STATE,
        """
func refreshPermissionState(overloadProbe: Bool) {
    store.refreshPermissionState()
}
""",
    )
    if adversarial_source is None:
        return {"refresh_target_noop_overload_forwards": False}
    adversarial_checks = permission_refresh_chain_checks(
        app_model,
        adversarial_source,
        permission_store,
        screenshot_store,
    )
    coordinator_type = swift_declaration_block(
        adversarial_source,
        PERMISSION_COORDINATOR_TYPE,
    )
    overload_block = _method_block(
        coordinator_type,
        "func refreshPermissionState(overloadProbe: Bool)",
    )
    target_block = _method_block(coordinator_type, REFRESH_PERMISSION_STATE)
    return {
        "refresh_target_noop_overload_forwards": (
            "store.refreshPermissionState()" in overload_block
            and "noOpPermissionStateRefresh()" in target_block
            and "store.refreshPermissionState()" not in target_block
            and not adversarial_checks["refresh_coordinator_to_store"]
        ),
    }


PERMISSION_ASSIST_PRESENTER_TYPE = "final class PermissionAssistPanelPresenter: NSObject, NSWindowDelegate"
FLOATING_PANEL_ROLE_TYPE = "enum BlocksFloatingPanelWindowRole"
PERMISSION_ASSIST_VIEW_TYPE = "struct PermissionAssistPanelView: View"
PRESENTER_PRESENT = "func present(kind: PermissionAssistKind, appURL: URL = Bundle.main.bundleURL, onFlowEnded: (() -> Void)? = nil)"
PRESENTER_MAKE_PANEL = "func makePanel() -> NSPanel"
PRESENTER_START_MONITORING = "func startMonitoring(for generation: UInt64)"
PRESENTER_MONITOR_FLOW = "func monitorPermissionFlow(generation: UInt64)"
PRESENTER_SHOW_PANEL = "func showPanelIfNeeded(forceWaitingPanel: Bool = false, generation: UInt64? = nil)"
PRESENTER_COMPLETE = "func completeFromUserAction()"
PRESENTER_CLOSE = "func close()"
PRESENTER_FINISH_PENDING_CLOSE = "func finishPendingClose(for generation: UInt64)"
FLOATING_PANEL_ROLE_APPLY = "func apply(to panel: NSPanel)"


def swift_member_slice(source: str, marker: str) -> str:
    """Return one four-space-indented Swift member, or an empty string."""
    start = source.find(marker)
    if start < 0:
        return ""
    following = re.search(
        r"(?m)^    (?:private )?(?:func|var)\b",
        source[start + len(marker):],
    )
    end = start + len(marker) + following.start() if following else len(source)
    return source[start:end]


def _permission_assist_role_block(floating_panel_support: str) -> tuple[str, str]:
    role_type = swift_declaration_block(
        floating_panel_support,
        FLOATING_PANEL_ROLE_TYPE,
    )
    apply = _method_block(role_type, FLOATING_PANEL_ROLE_APPLY)
    executable_apply = _swift_code_only(apply)
    switch_index = executable_apply.find("switch self")
    shared_prefix = executable_apply[:switch_index] if switch_index >= 0 else ""
    assist_start = executable_apply.find("case .assist:", switch_index)
    next_case = executable_apply.find("\n        case ", assist_start + 1)
    assist_role = (
        executable_apply[assist_start:next_case if next_case >= 0 else len(executable_apply)]
        if assist_start >= 0
        else ""
    )
    return shared_prefix, assist_role


def permission_assist_owner_chain_checks(
    presenter: str,
    floating_panel_support: str,
    assist_view: str,
) -> dict[str, bool]:
    presenter_type = swift_declaration_block(
        presenter,
        PERMISSION_ASSIST_PRESENTER_TYPE,
    )
    make_panel = _method_block(presenter_type, PRESENTER_MAKE_PANEL)
    shared_prefix, assist_role = _permission_assist_role_block(floating_panel_support)
    view_type = swift_declaration_block(assist_view, PERMISSION_ASSIST_VIEW_TYPE)
    app_icon = swift_member_slice(view_type, "private var draggableAppIcon")
    executable_view = _swift_code_only(assist_view)
    executable_app_icon = _swift_code_only(app_icon)
    return {
        "presenter_make_panel_applies_assist_role": (
            _contains_exact_code_line(
                make_panel,
                "BlocksFloatingPanelWindowRole.assist.apply(to: panel)",
            )
        ),
        "shared_apply_prefix_keeps_panel_visible_on_deactivate": (
            _contains_exact_code_line(shared_prefix, "panel.hidesOnDeactivate = false")
        ),
        "assist_role_disables_background_drag": (
            _contains_exact_code_line(
                assist_role,
                "panel.isMovableByWindowBackground = false",
            )
        ),
        "only_app_icon_is_drag_source": (
            executable_view.count(".onDrag") == 1
            and ".onDrag" in executable_app_icon
            and "NSItemProvider(object: sessionModel.appURL as NSURL)" in executable_app_icon
        ),
    }


def permission_assist_generation_checks(presenter: str) -> dict[str, bool]:
    presenter_type = swift_declaration_block(
        presenter,
        PERMISSION_ASSIST_PRESENTER_TYPE,
    )
    present = _swift_code_only(_method_block(presenter_type, PRESENTER_PRESENT))
    monitoring = _swift_code_only(_method_block(presenter_type, PRESENTER_START_MONITORING))
    monitor = _swift_code_only(_method_block(presenter_type, PRESENTER_MONITOR_FLOW))
    show_panel = _swift_code_only(_method_block(presenter_type, PRESENTER_SHOW_PANEL))
    return {
        "generation_is_created_and_passed_to_delayed_show": (
            "let generation = mainWindowRestoreSession.begin()" in present
            and "startMonitoring(for: generation)" in present
            and "showPanelIfNeeded(forceWaitingPanel: false, generation: generation)" in present
        ),
        "monitor_receives_generation": (
            "monitorPermissionFlow(generation: generation)" in monitoring
            and bool(monitor)
        ),
        "generation_is_guarded_at_monitor_and_show_boundaries": (
            "guard isCurrent(generation) else" in monitor
            and "guard isCurrent(generation) else" in show_panel
        ),
    }


def permission_assist_completion_checks(
    presenter: str,
    permission_store: str,
) -> dict[str, bool]:
    presenter_type = swift_declaration_block(
        presenter,
        PERMISSION_ASSIST_PRESENTER_TYPE,
    )
    monitor = _swift_code_only(_method_block(presenter_type, PRESENTER_MONITOR_FLOW))
    complete = _swift_code_only(_method_block(presenter_type, PRESENTER_COMPLETE))
    close = _swift_code_only(_method_block(presenter_type, PRESENTER_CLOSE))
    finish_pending_close = _swift_code_only(_method_block(
        presenter_type,
        PRESENTER_FINISH_PENDING_CLOSE,
    ))
    store_type = swift_declaration_block(permission_store, PERMISSION_STORE_TYPE)
    screen_request = _swift_code_only(_method_block(store_type, REQUEST_SCREEN_STORE))
    accessibility_request = _swift_code_only(_method_block(store_type, REQUEST_ACCESSIBILITY_STORE))

    def granted_path_closes(method: str) -> bool:
        return bool(re.search(
            r"if permissionGranted\(session\.kind\) \{"
            r"(?:(?!\breturn\b).)*?"
            r"\bclose\(\)\s*\n\s*return",
            method,
            re.DOTALL,
        ))

    close_completion_order = (
        close.count("finishPendingClose(for: generation)") == 3
        and close.find("pendingCloseGeneration = generation")
        < close.find("finishPendingClose(for: generation)")
        and close.find("finishPendingClose(for: generation)")
        < close.rfind("return")
    )
    finish_notification_order = all(
        finish_pending_close.find(before) >= 0
        and finish_pending_close.find(before)
        < finish_pending_close.find("notifyFlowEndedOnce()")
        for before in (
            "pendingCloseGeneration = nil",
            "session = nil",
            "mainWindowRestoreSession.restore(for: generation)",
        )
    )
    return {
        "permission_granted_is_checked_in_monitor_and_complete_paths": (
            granted_path_closes(monitor)
            and granted_path_closes(complete)
        ),
        "completion_lifecycle_reaches_notification_and_store_refreshes": (
            close_completion_order
            and finish_notification_order
            and "assistPresenter.present(kind: .screenRecording)" in screen_request
            and "self.refreshPermissionState()" in screen_request
            and "assistPresenter.present(kind: .accessibility)" in accessibility_request
            and "self.refreshPermissionState()" in accessibility_request
        ),
    }


def permission_assist_contract_mutations_fail_closed(
    presenter: str,
    floating_panel_support: str,
    assist_view: str,
    permission_store: str,
) -> dict[str, bool]:
    assist_drag_removed = re.sub(
        r"(case \.assist:.*?)[ \t]*panel\.isMovableByWindowBackground = false\n",
        r"\1",
        floating_panel_support,
        count=1,
        flags=re.DOTALL,
    )
    mutations = {
        "shared_hides_on_deactivate_removed": (
            floating_panel_support.replace("panel.hidesOnDeactivate = false", "", 1),
            "shared_apply_prefix_keeps_panel_visible_on_deactivate",
        ),
        "assist_background_drag_protection_removed": (
            assist_drag_removed,
            "assist_role_disables_background_drag",
        ),
    }
    results = {
        name: not permission_assist_owner_chain_checks(
            presenter,
            mutated_support,
            assist_view,
        )[expected_check]
        for name, (mutated_support, expected_check) in mutations.items()
    }
    mutated_presenter = presenter.replace("guard isCurrent(generation) else", "guard false else")
    results["generation_guard_removed"] = not all(
        permission_assist_generation_checks(mutated_presenter).values()
    )
    mutated_view = assist_view + "\n.onDrag { NSItemProvider() }\n"
    results["additional_drag_source_added"] = not permission_assist_owner_chain_checks(
        presenter,
        floating_panel_support,
        mutated_view,
    )["only_app_icon_is_drag_source"]

    commented_role = _replace_in_exact_method(
        presenter,
        PERMISSION_ASSIST_PRESENTER_TYPE,
        PRESENTER_MAKE_PANEL,
        "BlocksFloatingPanelWindowRole.assist.apply(to: panel)",
        "// BlocksFloatingPanelWindowRole.assist.apply(to: panel)",
    )
    results["assist_role_application_commented_out"] = (
        commented_role is not None
        and not permission_assist_owner_chain_checks(
            commented_role,
            floating_panel_support,
            assist_view,
        )["presenter_make_panel_applies_assist_role"]
    )

    for name, method_signature in (
        ("monitor_permission_condition_made_unconditional", PRESENTER_MONITOR_FLOW),
        ("completion_permission_condition_made_unconditional", PRESENTER_COMPLETE),
    ):
        unconditional = _replace_in_exact_method(
            presenter,
            PERMISSION_ASSIST_PRESENTER_TYPE,
            method_signature,
            "if permissionGranted(session.kind) {",
            "if permissionGranted(session.kind) || true {",
        )
        results[name] = (
            unconditional is not None
            and not permission_assist_completion_checks(
                unconditional,
                permission_store,
            )["permission_granted_is_checked_in_monitor_and_complete_paths"]
        )
    close_without_finish = _replace_all_in_exact_method(
        presenter,
        PERMISSION_ASSIST_PRESENTER_TYPE,
        PRESENTER_CLOSE,
        "finishPendingClose(for: generation)",
        "finishPendingCloseRemoved(for: generation)",
    )
    results["close_to_finish_pending_close_removed"] = (
        close_without_finish is not None
        and not permission_assist_completion_checks(
            close_without_finish,
            permission_store,
        )["completion_lifecycle_reaches_notification_and_store_refreshes"]
    )
    finish_without_notification = _replace_in_exact_method(
        presenter,
        PERMISSION_ASSIST_PRESENTER_TYPE,
        PRESENTER_FINISH_PENDING_CLOSE,
        "notifyFlowEndedOnce()",
        "notifyFlowEndedOnceRemoved()",
    )
    results["finish_pending_close_to_notification_removed"] = (
        finish_without_notification is not None
        and not permission_assist_completion_checks(
            finish_without_notification,
            permission_store,
        )["completion_lifecycle_reaches_notification_and_store_refreshes"]
    )
    return results


DESTRUCTIVE_PERMISSION_RESET_TOKENS = (
    "tccutil reset",
    "tccaccessreset",
)


def destructive_permission_reset_absent(sources: Mapping[str, str]) -> bool:
    combined = "\n".join(sources.values()).casefold()
    return all(token not in combined for token in DESTRUCTIVE_PERMISSION_RESET_TOKENS)


def destructive_permission_reset_mutation_fails_closed(
    sources: Mapping[str, str],
    mutation_target: str,
) -> bool:
    if mutation_target not in sources or not destructive_permission_reset_absent(sources):
        return False
    mutated_sources = dict(sources)
    mutated_sources[mutation_target] += "\ntccutil reset ScreenCapture"
    return not destructive_permission_reset_absent(mutated_sources)
