#!/usr/bin/env python3
"""P8-I current settings navigation and clipboard-system contract checks."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

from current_architecture_gate_helpers import (
    exact_method_block,
    mutate_exact_method,
    swift_code_only,
)


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CONTENT_VIEW = APP / "Views" / "ContentView.swift"
SHELL = APP / "Features" / "Settings" / "SettingsShellView.swift"
CLIPBOARD_SETTINGS = APP / "Features" / "Settings" / "ClipboardSettingsPane.swift"
TAG_SECTION = APP / "Features" / "Settings" / "ClipboardTagManagementSection.swift"
STORE = APP / "Features" / "Clipboard" / "ClipboardStore.swift"
STORE_TYPE = "final class ClipboardStore"
PREVIEW_SIGNATURE = """func requestPolicyPreview(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) -> Bool"""
CANCEL_SIGNATURE = "func cancelPolicyPreview()"
CONFIRM_SIGNATURE = """func confirmPolicyApplication(
        token: ClipboardPolicyConfirmationToken,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    )"""
LEGACY_REQUEST_SIGNATURE = """func requestPolicyApplication(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (ClipboardPolicyApplyResult, Int?) -> Void
    ) -> Bool"""


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def require(checks: dict[str, bool], key: str, condition: bool) -> None:
    checks[key] = condition


def balanced_block_end(code: str, opening_brace: int) -> int | None:
    depth = 0
    for index in range(opening_brace, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def brace_depths(code: str) -> list[int]:
    depth = 0
    depths: list[int] = []
    for character in code:
        depths.append(depth)
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
    return depths


def executable_body(block: str, *, task: bool = False) -> str:
    """Return a concrete method or direct Task body, excluding its wrapper."""
    code = swift_code_only(block)
    opening = code.find("{")
    if opening < 0:
        return ""
    end = balanced_block_end(code, opening)
    if end is None:
        return ""
    if not task:
        return block[opening + 1:end - 1]
    header = code[opening + 1:end - 1]
    match = re.search(r"\bin\b", header)
    if match is None:
        return ""
    return block[opening + 1 + match.end():end - 1]


def direct_task_body(method: str, binding: str | None = None) -> str:
    """Extract exactly one direct Task assignment, never a closure-only decoy."""
    code = swift_code_only(method)
    assignment = (
        rf"\b{re.escape(binding)}\s*=\s*Task\s*\{{"
        if binding else r"\bTask\s*\{"
    )
    matches = list(re.finditer(assignment, code))
    if len(matches) != 1:
        return ""
    start = matches[0].start()
    if brace_depths(code)[start] != 1:
        return ""
    opening = code.find("{", start)
    end = balanced_block_end(code, opening)
    if end is None:
        return ""
    return executable_body(method[start:end], task=True)


def conditional_compilation_depths(source: str) -> list[int] | None:
    code = swift_code_only(source)
    depths = [0] * len(code)
    depth = 0
    offset = 0
    for line in code.splitlines(keepends=True):
        stripped = line.lstrip()
        directive = stripped.split(maxsplit=1)[0] if stripped.startswith("#") else ""
        if directive == "#if":
            line_depth = depth + 1
            depth += 1
        elif directive in {"#elseif", "#else"}:
            if depth == 0:
                return None
            line_depth = depth
        elif directive == "#endif":
            if depth == 0:
                return None
            line_depth = depth
            depth -= 1
        else:
            line_depth = depth
        depths[offset:offset + len(line)] = [line_depth] * len(line)
        offset += len(line)
    return depths if depth == 0 else None


def reachable_token_index(body: str, token: str, after: int = -1) -> int | None:
    """Find a live code token, rejecting comments, dead branches, and closures.

    The caller supplies an exact method or directly-bound Task body.  This
    deliberately accepts structured control flow but rejects a token hidden in
    a local closure, conditional-compilation branch, literal-false branch, or
    after an unconditional body-level terminator.
    """
    code = swift_code_only(body)
    conditional_depths = conditional_compilation_depths(body)
    if conditional_depths is None:
        return None
    token_pattern = re.compile(
        "".join(
            r"\s+" if part.isspace() else re.escape(part)
            for part in re.split(r"(\s+)", token.strip()) if part
        )
    )
    depths = brace_depths(code)
    unreachable_ranges: list[tuple[int, int]] = []
    for match in re.finditer(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*\{", code):
        opening = code.find("{", match.start())
        end = balanced_block_end(code, opening)
        if end is None:
            return None
        unreachable_ranges.append((opening, end))
    terminators = [
        match.start() for match in re.finditer(
            r"\b(?:return|throw|fatalError|preconditionFailure)\b", code
        )
        if depths[match.start()] == 0 and conditional_depths[match.start()] == 0
    ]

    def is_closure_scope(position: int) -> bool:
        stack: list[int] = []
        for index, character in enumerate(code[:position]):
            if character == "{":
                stack.append(index)
            elif character == "}" and stack:
                stack.pop()
        control = re.compile(r"\b(?:if|guard|else|switch|do|while|for|catch|repeat|defer)\b[^{}]*$")
        for opening in stack:
            boundary = max(code.rfind("{", 0, opening), code.rfind("}", 0, opening), code.rfind(";", 0, opening))
            if not control.search(code[boundary + 1:opening]):
                return True
        return False

    for match in token_pattern.finditer(code):
        start, end = match.span()
        if start <= after:
            continue
        if (
            all(conditional_depths[index] == 0 for index in range(start, end))
            and not is_closure_scope(start)
            and not any(range_start < start and end <= range_end for range_start, range_end in unreachable_ranges)
            and not any(terminator < start for terminator in terminators)
        ):
            return start
    return None


def ordered_reachable_tokens(body: str, tokens: list[str]) -> bool:
    position = -1
    for token in tokens:
        position = reachable_token_index(body, token, position)
        if position is None:
            return False
    return True


def clipboard_policy_contract(store: str) -> dict[str, bool]:
    preview = exact_method_block(store, STORE_TYPE, PREVIEW_SIGNATURE)
    cancel = exact_method_block(store, STORE_TYPE, CANCEL_SIGNATURE)
    confirm = exact_method_block(store, STORE_TYPE, CONFIRM_SIGNATURE)
    legacy = exact_method_block(store, STORE_TYPE, LEGACY_REQUEST_SIGNATURE)
    preview_body = executable_body(preview)
    confirm_body = executable_body(confirm)
    legacy_body = executable_body(legacy)
    preview_task = direct_task_body(preview)
    confirm_task = direct_task_body(confirm)
    legacy_task = direct_task_body(legacy, "cleanupPolicyRequestTask")

    return {
        "preview_enters_only_from_committed": ordered_reachable_tokens(preview_body, [
            "guard repository != nil, cleanupMutationState == .committed else",
            "cleanupMutationState = .previewing",
        ]),
        "preview_binds_plan_to_pending_token_and_confirmation": ordered_reachable_tokens(preview_task, [
            "switch await self.cleanupMutationPipeline.previewPolicy(policy)",
            "case let .success(plan):",
            "guard self.cleanupMutationState == .previewing else",
            "let token = ClipboardPolicyConfirmationToken(",
            "repositoryPlanToken: plan.token",
            "self.pendingPolicyConfirmation = token",
            "if plan.deleteCount == 0 {",
            "self.confirmPolicyApplication(token: token, completion: completion)",
            "self.cleanupMutationState = .awaitingConfirmation",
            "completion(.preview(deleteCount: plan.deleteCount, token: token))",
            "case .failure:",
            "self.pendingPolicyConfirmation = nil",
            "self.cleanupMutationState = .committed",
            "completion(.failed)",
        ]),
        "cancel_releases_only_preview_or_confirmation": ordered_reachable_tokens(executable_body(cancel), [
            "guard cleanupMutationState == .previewing || cleanupMutationState == .awaitingConfirmation else",
            "pendingPolicyConfirmation = nil",
            "cleanupMutationState = .committed",
        ]),
        "confirmation_validates_state_and_pending_identity": ordered_reachable_tokens(confirm_body, [
            "guard cleanupMutationState == .awaitingConfirmation || cleanupMutationState == .previewing",
            "let pending = pendingPolicyConfirmation",
            "pending == token else",
            "cleanupMutationState = .applying",
        ]),
        "confirmation_committed_stale_and_failure_transitions": ordered_reachable_tokens(confirm_task, [
            "let outcome = await self.cleanupMutationPipeline.applyConfirmedPolicy(",
            "token: pending.repositoryPlanToken",
            "case let .policy(result, visibleRecordCount, postMutationFailure):",
            "self.pendingPolicyConfirmation = nil",
            "self.cleanupMutationState = .committed",
            "completion(.committed(visibleRecordCount: visibleRecordCount))",
            "case let .stale(plan):",
            "let staleToken = pending.replacingRepositoryPlanToken(plan.token)",
            "self.pendingPolicyConfirmation = staleToken",
            "self.cleanupMutationState = .awaitingConfirmation",
            "completion(.stale(deleteCount: plan.deleteCount, token: staleToken))",
            "case .clear, .failure:",
            "self.pendingPolicyConfirmation = nil",
            "self.cleanupMutationState = .committed",
            "completion(.failed)",
        ]),
        "legacy_debounce_remains_generation_and_current_task_scoped": ordered_reachable_tokens(legacy_body, [
            "guard cleanupMutationState == .committed",
            "cleanupPolicyRequestTask != nil",
            "cleanupPolicyRequestTask?.cancel()",
            "cleanupMutationGeneration &+= 1",
            "let generation = cleanupMutationGeneration",
            "cleanupMutationState = .policyPending",
        ]) and ordered_reachable_tokens(legacy_task, [
            "try await Task.sleep(for: debounce)",
            "generation == self.cleanupMutationGeneration",
            "!Task.isCancelled else",
            "self.cleanupMutationState = .active",
            "if generation == self.cleanupMutationGeneration {",
            "self.cleanupMutationState = .idle",
            "self.cleanupPolicyRequestTask = nil",
            "let outcome = await pipeline.applyPolicy(policy, visibleLimit: visibleLimit)",
            "guard generation == self.cleanupMutationGeneration else",
        ]),
        "retired_busy_boolean_guard_not_restored": "guard !cleanupMutationInProgress else { return false }" not in swift_code_only(store),
    }


def policy_contract_mutations_fail_closed(store: str) -> dict[str, bool]:
    """Pure-Python adversaries prove this gate rejects common token decoys."""
    mutations = [
        ("removed_pending_identity", PREVIEW_SIGNATURE, "self.pendingPolicyConfirmation = token", "self.pendingPolicyConfirmation = nil"),
        ("awaiting_state_hidden_in_if_false", PREVIEW_SIGNATURE, "self.cleanupMutationState = .awaitingConfirmation", "if false { self.cleanupMutationState = .awaitingConfirmation }"),
        ("pending_identity_weakened", CONFIRM_SIGNATURE, "pending == token else", "true else"),
        ("confirmation_state_guard_weakened", CONFIRM_SIGNATURE, "cleanupMutationState == .awaitingConfirmation || cleanupMutationState == .previewing", "true"),
        ("generation_increment_removed", LEGACY_REQUEST_SIGNATURE, "cleanupMutationGeneration &+= 1", "// cleanupMutationGeneration &+= 1"),
        ("current_task_guard_removed", LEGACY_REQUEST_SIGNATURE, "cleanupPolicyRequestTask != nil", "true"),
        ("comment_decoy_does_not_restore_identity", CONFIRM_SIGNATURE, "pending == token else", "true /* pending == token else */ else"),
    ]
    results: dict[str, bool] = {}
    for name, signature, original, replacement in mutations:
        mutated = mutate_exact_method(store, STORE_TYPE, signature, original, replacement)
        results[name] = mutated is not None and not all(clipboard_policy_contract(mutated).values())
    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.parse_args(argv)

    files = [CONTENT_VIEW, SHELL, CLIPBOARD_SETTINGS, TAG_SECTION, STORE]
    failures = [{"code": "missing_file", "detail": str(path.relative_to(ROOT))}
                for path in files if not path.exists()]
    content_view, shell, settings, tags, store = (read(path) for path in files)
    checks: dict[str, bool] = {}

    require(checks, "current_settings_navigation_chain", all(token in content_view for token in [
        "struct ContentView: View", "SettingsNavigationShell(initialSection: initialSection)",
        "struct SettingsNavigationShell: View", "SettingsShellView(mode: appModel.selectedSection.settingsViewMode)",
    ]))
    require(checks, "cleanup_mode_uses_shared_segmented_row_and_draft", all(token in settings for token in [
        "SettingsSegmentedRow(", "cleanupModeDraft", "selection: cleanupModeSelection",
        "applyClipboardCleanupPolicy(cleanupMode: $0)",
    ]))
    policy_contract = clipboard_policy_contract(store)
    require(checks, "cleanup_policy_confirmation_state_machine_contract", all(policy_contract.values()))
    mutation_self_test = policy_contract_mutations_fail_closed(store)
    require(checks, "cleanup_policy_contract_mutations_fail_closed", all(mutation_self_test.values()))
    require(checks, "clipboard_tag_secondary_entry", all(token in settings for token in [
        "SettingsSecondaryRouteAnchor.clipboardTags", "ClipboardTagManagementSection(",
        "showsTagManagement",
    ]))
    require(checks, "tag_management_crud_and_reorder", all(token in tags for token in [
        "createNewTag", "tagStore.createTag", "beginSettingsTagEdit", "commitSettingsTagEdit",
        "cancelSettingsTagEdit", "requestDelete", "tagStore.deleteTag", "moveSettingsTagUp",
        "moveSettingsTagDown", "tagStore.moveFilterTag",
    ]))
    require(checks, "tag_management_accessibility_actions", all(token in tags for token in [
        ".accessibilityAction(named:", "settings.clipboardTagsMoveUp",
        "settings.clipboardTagsMoveDown",
    ]))
    require(checks, "tag_management_has_no_private_color_or_hover_contract", all(token not in tags for token in [
        "Color.red", "hoveredTagID", "onHover", "deleteButtonOpacity",
    ]))

    for key, ok in checks.items():
        if not ok:
            failures.append({"code": key, "detail": "Current P8-I settings/clipboard contract failed."})
    print(json.dumps({"ok": not failures, "suite": "p8i_settings_clipboard_system_checks",
                      "checks": checks, "policy_contract": policy_contract,
                      "mutation_self_test": mutation_self_test, "failures": failures,
                      "checked_files": [str(path.relative_to(ROOT)) for path in files]},
                     ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
