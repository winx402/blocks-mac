#!/usr/bin/env python3
"""P7-D floating-panel coordination, re-entry, and shortcut-focus checks."""

from __future__ import annotations

import json
import re
from pathlib import Path

from current_architecture_gate_helpers import (
    swift_code_only,
    swift_declaration_block,
)


ROOT = Path(__file__).resolve().parents[2]
APP_MODEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "App" / "AppModel.swift"
SHORTCUT_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Shortcuts" / "ShortcutStore.swift"
CLIPBOARD_COORDINATOR = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift"
TRANSLATION_COORDINATOR = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Translation" / "TranslationFeatureCoordinator.swift"
CLIPBOARD_PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardHistoryPanelPresenter.swift"
TRANSLATION_PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "TranslationPanelPresenter.swift"
SUPPORT = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "FloatingPanelSupport.swift"
STEP4C_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "PRD-Step4C-剩余Feature收口-v0.md"
STEP4C_2_DEVELOPMENT_RECORD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_4" / "开发记录-Step4C-2-ShortcutStore-v0.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def block(source: str, signature: str) -> str:
    return swift_code_only(swift_declaration_block(source, signature))


def ordered(source: str, *tokens: str) -> bool:
    position = -1
    for token in tokens:
        position = source.find(token, position + 1)
        if position < 0:
            return False
    return True


def current_method_block(
    source: str,
    type_signature: str,
    method_name: str,
    required_parameter_labels: tuple[str, ...],
) -> str:
    """Return one current overload, tolerating whitespace and new parameters.

    A generic ``func present`` lookup is unsafe: both coordinators acquire
    unrelated overloads over time.  Select the declaration only within its
    owning type and only when the required semantic parameter labels identify
    exactly one direct method declaration.
    """
    type_block = swift_declaration_block(source, type_signature)
    code = swift_code_only(type_block)
    depths = []
    depth = 0
    for character in code:
        depths.append(depth)
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1

    matches: list[tuple[int, int]] = []
    pattern = re.compile(rf"\bfunc\s+{re.escape(method_name)}\s*\(")
    for candidate in pattern.finditer(code):
        start = candidate.start()
        if start >= len(depths) or depths[start] != 1:
            continue
        parameters_start = code.find("(", start)
        parameters_end = _balanced_parentheses_end(code, parameters_start)
        if parameters_end is None:
            continue
        header = code[start:parameters_end]
        if not all(
            re.search(rf"\b{re.escape(label)}\s*:", header)
            for label in required_parameter_labels
        ):
            continue
        body_start = code.find("{", parameters_end)
        if body_start < 0:
            continue
        body_end = _balanced_braces_end(code, body_start)
        if body_end is not None:
            matches.append((start, body_end))
    return type_block[matches[0][0]:matches[0][1]] if len(matches) == 1 else ""


def _balanced_parentheses_end(source: str, opening: int) -> int | None:
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _balanced_braces_end(source: str, opening: int) -> int | None:
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _direct_statement_positions(
    code: str, start: int, end: int, depth: int, pattern: str
) -> list[int]:
    depths = []
    current = 0
    for character in code:
        depths.append(current)
        if character == "{":
            current += 1
        elif character == "}":
            current -= 1
    return [
        match.start()
        for match in re.finditer(pattern, code[start:end])
        if depths[start + match.start()] == depth
    ]


def visible_reentry_contract(method: str) -> bool:
    code = swift_code_only(method)
    match = re.search(
        r"if\s+let\s+panel\s*,\s*panel\.isVisible\s*,\s*!replacedPendingClose\s*\{",
        code,
    )
    if match is None:
        return False
    method_start = code.find("{")
    if method_start < 0 or _direct_statement_positions(
        code, method_start + 1, match.start(), 1, r"\breturn\s+\.shown\b"
    ):
        return False
    branch_start = code.find("{", match.start(), match.end())
    branch_end = _balanced_braces_end(code, branch_start)
    if branch_end is None or "#if" in code[branch_start:branch_end]:
        return False
    branch_depth = 2
    focus = _direct_statement_positions(
        code, branch_start + 1, branch_end - 1, branch_depth, r"\bfocus\s*\(\s*\)"
    )
    returned = _direct_statement_positions(
        code, branch_start + 1, branch_end - 1, branch_depth, r"\breturn\s+\.shown\b"
    )
    reset = _direct_statement_positions(
        code, branch_end, len(code), 1, r"\bpinState\s*\.\s*reset\s*\(\s*\)"
    )
    return len(focus) == 1 and len(returned) == 1 and len(reset) == 1 and focus[0] < returned[0]


def translation_presentation_contract(method: str, replacement: str) -> bool:
    code = swift_code_only(method)
    close = re.search(r"\bcloseClipboardPanel\s*\{", code)
    if close is None:
        return False
    closure_start = code.find("{", close.start(), close.end())
    closure_end = _balanced_braces_end(code, closure_start)
    if closure_end is None or "#if" in code[closure_start:closure_end]:
        return False
    operations = (
        r"\breplaceUnpinnedPresenterIfNeeded\s*\(\s*\)",
        r"\bpresenter\s*\.\s*present\s*\(\s*\)",
    )
    positions = [
        _direct_statement_positions(code, closure_start + 1, closure_end - 1, 2, operation)
        for operation in operations
    ]
    return (
        all(len(found) == 1 for found in positions)
        and positions[0][0] < positions[1][0]
        and "where !presenter.model.isPinned" in swift_code_only(replacement)
        and "presenter.close()" in swift_code_only(replacement)
        and "forceClose()" not in swift_code_only(replacement)
    )


def contract(sources: dict[str, str]) -> dict[str, bool]:
    app_configuration = block(sources["app_model"], "private func configureFeatureCoordinators()")
    open_main_window = block(sources["app_model"], "func openMainWindow(section: AppSection)")
    clipboard_show = block(sources["clipboard_coordinator"], "func showFloatingPanel(")
    clipboard_present = current_method_block(
        sources["clipboard_presenter"],
        "final class ClipboardHistoryPanelPresenter",
        "present",
        (
            "clipboardStore",
            "notificationState",
            "actions",
            "position",
            "invocationContext",
            "openMainWindow",
            "openSettings",
            "onClosed",
        ),
    )
    clipboard_close = block(sources["clipboard_presenter"], "private func closePanel(")
    clipboard_replace_close = block(
        sources["clipboard_presenter"],
        "private func replacePendingCloseForNewInvocation()",
    )
    translation_close = block(sources["translation_coordinator"], "func closeFloatingPanel()")
    translation_present = current_method_block(
        sources["translation_coordinator"],
        "final class TranslationFeatureCoordinator",
        "present",
        (
            "input",
            "sourceLanguage",
            "targetLanguage",
            "entryID",
            "shouldPresent",
            "onPresented",
        ),
    )
    translation_replace_unpinned = block(
        sources["translation_coordinator"],
        "private func replaceUnpinnedPresenterIfNeeded()",
    )
    presentation = block(sources["support"], "final class BlocksFloatingPanelPresentationCoordinator")
    regular_windows = block(sources["support"], "final class BlocksRegularWindowVisibilitySession")
    dismiss_monitor = block(sources["support"], "final class FloatingPanelDismissMonitor")
    recent_close = block(sources["support"], "struct FloatingPanelRecentCloseGuard")
    shortcut_code = swift_code_only(sources["shortcut_store"])
    clipboard_presenter_code = swift_code_only(sources["clipboard_presenter"])

    close_guard_precedes_close = ordered(
        clipboard_close,
        "self.lifecycleGeneration == closeGeneration",
        "self.isClosePending",
        "self.panel === panel",
        "panel.close()",
    )

    return {
        "files_present": all(sources.values()),
        "app_model_routes_current_coordinators": all(
            token in app_configuration
            for token in (
                "closeTranslationPanel:",
                "translationCoordinator?.closeFloatingPanel()",
                "closeClipboardPanel:",
                "clipboardCoordinator?.closeFloatingPanel(afterClose: completion)",
                "shortcutCoordinator.configure(",
                "self?.showClipboardFloatingPanel()",
                "translationCoordinator?.showSmartSelectionPanel()",
            )
        ),
        "main_window_route_is_single_and_explicit": all(
            token in open_main_window
            for token in (
                "selectedSection = section",
                "mainWindowNavigationGeneration &+= 1",
                "mainWindowOpener?()",
                "NSApp.activate(ignoringOtherApps: true)",
            )
        ),
        "clipboard_open_closes_translation_before_presenting": ordered(
            clipboard_show,
            "closeTranslationPanel()",
            "clipboardHistoryPanelPresenter.present(",
        ),
        "clipboard_visible_reentry_focuses_without_resetting_session": (
            visible_reentry_contract(clipboard_present)
            and "if pinState.isPinned" in clipboard_present
            and "dismissMonitor.stop()" in clipboard_present
            and "startDismissMonitor(for: panel)" in clipboard_present
        ),
        "clipboard_close_rejects_stale_completion": (
            close_guard_precedes_close
            and "lifecycleGeneration &+= 1" in clipboard_close
            and "let closeGeneration = lifecycleGeneration" in clipboard_close
            and all(
                token in clipboard_replace_close
                for token in (
                    "lifecycleGeneration &+= 1",
                    "guard isClosePending else { return false }",
                    "afterCloseActions.removeAll()",
                )
            )
        ),
        "translation_waits_for_clipboard_close_and_only_replaces_unpinned": (
            translation_presentation_contract(
                translation_present,
                translation_replace_unpinned,
            )
            and "active.forEach { $0.forceClose() }" in translation_close
        ),
        "presentation_animation_completions_are_generation_guarded": all(
            token in presentation
            for token in (
                "let presentationGeneration = generation",
                "self.generation == presentationGeneration",
                "let dismissalGeneration = generation",
                "self.generation == dismissalGeneration",
                "window.orderFrontRegardless()",
            )
        ),
        "dismiss_monitor_owns_and_cleans_all_observers": all(
            token in dismiss_monitor
            for token in (
                "NSEvent.addLocalMonitorForEvents",
                "NSEvent.addGlobalMonitorForEvents",
                "NSApplication.didResignActiveNotification",
                "NSEvent.removeMonitor(localMonitor)",
                "NSEvent.removeMonitor(globalMonitor)",
                "observer.center.removeObserver(observer.token)",
                "notificationObservers.removeAll()",
                "isEventInsideInteractionIsland",
                "FloatingPanelInteractionGeometry.windows(for: panel)",
                "isPanelRelatedTransientWindow",
            )
        ) and all(
            token not in dismiss_monitor
            for token in (
                "NSApplication.willHideNotification",
                "NSWorkspace.activeSpaceDidChangeNotification",
            )
        ),
        "regular_window_visibility_restores_only_captured_windows": all(
            token in regular_windows
            for token in (
                "window.isVisible",
                "!window.isMiniaturized",
                "window.parent == nil",
                "window.level == .normal",
                "window.styleMask.contains(.titled)",
                "entries.forEach { $0.window?.orderOut(nil) }",
                "entriesToRestore.forEach",
                "window.makeKeyAndOrderFront(nil)",
            )
        ),
        "recent_close_suppression_is_short_lived_and_geometry_scoped": (
            all(
                token in recent_close
                for token in (
                    "minimumReopenSuppressionInterval",
                    "timeIntervalSince(snapshot.closedAt)",
                    "snapshot.frame.contains(mouseLocation)",
                    "FloatingPanelInteractionGeometry.frame(for: panel)",
                )
            )
            and "recentCloseGuard.recordClose(panel: panel)" in clipboard_presenter_code
            and "recentCloseGuard.shouldSuppressOpen()" in clipboard_presenter_code
            and "lastClosedInteractionFrame" not in clipboard_presenter_code
        ),
        "shortcut_store_uses_typed_actions": (
            "struct ShortcutActionHandlers" in shortcut_code
            and "actions.clipboardHistory" in shortcut_code
            and "actions.translationPanel" in shortcut_code
            and "actions.translationScreenshot" in shortcut_code
        ),
        "retired_dismiss_generation_counter_absent": (
            "dismissMonitorStartGeneration" not in clipboard_presenter_code
        ),
    }


def mutations_fail_closed(sources: dict[str, str]) -> dict[str, bool]:
    cases = (
        (
            "clipboard_open_requires_translation_close",
            "clipboard_coordinator",
            "        closeTranslationPanel()\n",
            "        _ = closeTranslationPanel\n",
            "clipboard_open_closes_translation_before_presenting",
        ),
        (
            "visible_reentry_requires_focus",
            "clipboard_presenter",
            "            focus()\n",
            "            _ = panel\n",
            "clipboard_visible_reentry_focuses_without_resetting_session",
        ),
        (
            "stale_close_requires_lifecycle_generation",
            "clipboard_presenter",
            "self.lifecycleGeneration == closeGeneration",
            "true",
            "clipboard_close_rejects_stale_completion",
        ),
        (
            "dismiss_completion_requires_generation",
            "support",
            "self.generation == dismissalGeneration",
            "true",
            "presentation_animation_completions_are_generation_guarded",
        ),
        (
            "dismiss_monitor_requires_global_cleanup",
            "support",
            "            NSEvent.removeMonitor(globalMonitor)\n",
            "            _ = globalMonitor\n",
            "dismiss_monitor_owns_and_cleans_all_observers",
        ),
        (
            "regular_window_capture_requires_normal_level",
            "support",
            "                  window.level == .normal,\n",
            "                  true,\n",
            "regular_window_visibility_restores_only_captured_windows",
        ),
        (
            "shortcut_requires_clipboard_action",
            "app_model",
            "                    self?.showClipboardFloatingPanel()\n",
            "                    self?.showClipboardHistory()\n",
            "app_model_routes_current_coordinators",
        ),
    )
    baseline = contract(sources)
    results: dict[str, bool] = {}
    for name, source_name, original, replacement, check_name in cases:
        source = sources[source_name]
        if source.count(original) != 1 or not baseline.get(check_name, False):
            results[name] = False
            continue
        mutated = dict(sources)
        mutated[source_name] = source.replace(original, replacement, 1)
        results[name] = not contract(mutated).get(check_name, False)

    structural_cases = (
        (
            "visible_reentry_rejects_false_branch",
            "clipboard_presenter",
            "if let panel, panel.isVisible, !replacedPendingClose {",
            "if false {",
            "clipboard_visible_reentry_focuses_without_resetting_session",
        ),
        (
            "visible_reentry_rejects_focus_in_closure",
            "clipboard_presenter",
            "            focus()\n",
            "            Task { focus() }\n",
            "clipboard_visible_reentry_focuses_without_resetting_session",
        ),
        (
            "visible_reentry_rejects_inactive_conditional",
            "clipboard_presenter",
            "            focus()\n",
            "#if false\n            focus()\n#endif\n",
            "clipboard_visible_reentry_focuses_without_resetting_session",
        ),
        (
            "visible_reentry_rejects_early_top_level_return",
            "clipboard_presenter",
            "        let replacedPendingClose = replacePendingCloseForNewInvocation()\n",
            "        return .shown\n        let replacedPendingClose = replacePendingCloseForNewInvocation()\n",
            "clipboard_visible_reentry_focuses_without_resetting_session",
        ),
        (
            "translation_preserves_pinned_presenters",
            "translation_coordinator",
            "for presenter in Array(presenters.values) where !presenter.model.isPinned {",
            "for presenter in Array(presenters.values) {",
            "translation_waits_for_clipboard_close_and_only_replaces_unpinned",
        ),
    )
    for name, source_name, original, replacement, check_name in structural_cases:
        source = sources[source_name]
        if source.count(original) != 1 or not baseline.get(check_name, False):
            results[name] = False
            continue
        mutated = dict(sources)
        mutated[source_name] = source.replace(original, replacement, 1)
        results[name] = not contract(mutated).get(check_name, False)

    present = current_method_block(
        sources["translation_coordinator"],
        "final class TranslationFeatureCoordinator",
        "present",
        ("input", "sourceLanguage", "targetLanguage", "entryID", "shouldPresent", "onPresented"),
    )
    close_call = "        closeClipboardPanel { [weak self] in\n"
    if (
        present.count(close_call) != 1
        or sources["translation_coordinator"].count(present) != 1
        or not baseline.get("translation_waits_for_clipboard_close_and_only_replaces_unpinned", False)
    ):
        results["translation_requires_clipboard_close_callback"] = False
    else:
        mutated = dict(sources)
        mutated_present = present.replace(
            close_call, "        ({ completion in completion() }) { [weak self] in\n", 1
        )
        mutated["translation_coordinator"] = sources["translation_coordinator"].replace(
            present, mutated_present, 1
        )
        results["translation_requires_clipboard_close_callback"] = not contract(mutated).get(
            "translation_waits_for_clipboard_close_and_only_replaces_unpinned", False
        )

    overload_marker = "    private func makePresenter(\n"
    overload = """    func present(
        input: TranslationInput,
        sourceLanguage: TranslationLanguageTag? = nil,
        targetLanguage: TranslationLanguageTag? = nil,
        entryID: UUID,
        pluginRunAuthorization: BlocksPluginAuthorizationContext = .init(userInitiated: true),
        shouldPresent: @escaping @MainActor () -> Bool = { true },
        onPresented: @escaping @MainActor (TranslationPanelSessionModel) -> Void = { _ in }
    ) {}

"""
    if (
        sources["translation_coordinator"].count(overload_marker) != 1
        or not baseline.get("translation_waits_for_clipboard_close_and_only_replaces_unpinned", False)
    ):
        results["translation_rejects_ambiguous_present_overload"] = False
    else:
        mutated = dict(sources)
        mutated["translation_coordinator"] = sources["translation_coordinator"].replace(
            overload_marker, overload + overload_marker, 1
        )
        results["translation_rejects_ambiguous_present_overload"] = not contract(mutated).get(
            "translation_waits_for_clipboard_close_and_only_replaces_unpinned", False
        )
    return results


def main() -> int:
    paths = {
        "app_model": APP_MODEL,
        "shortcut_store": SHORTCUT_STORE,
        "clipboard_coordinator": CLIPBOARD_COORDINATOR,
        "translation_coordinator": TRANSLATION_COORDINATOR,
        "clipboard_presenter": CLIPBOARD_PRESENTER,
        "translation_presenter": TRANSLATION_PRESENTER,
        "support": SUPPORT,
    }
    sources = {name: read(path) for name, path in paths.items()}
    checks = contract(sources)
    mutations = mutations_fail_closed(sources)
    failures = [
        {"code": "contract_missing", "detail": name}
        for name, ok in checks.items()
        if not ok
    ]
    if not all(mutations.values()):
        failures.append({
            "code": "mutation_bypass",
            "detail": ", ".join(name for name, ok in mutations.items() if not ok),
        })

    print(json.dumps({
        "ok": not failures,
        "suite": "p7d_panel_exclusivity_shortcut_focus_checks",
        "checked_files": [str(path.relative_to(ROOT)) for path in paths.values()],
        "contract": checks,
        "mutation_adversaries_fail_closed": mutations,
        "current_evidence": {
            "prd": str(STEP4C_PRD.relative_to(ROOT)),
            "development_record": str(STEP4C_2_DEVELOPMENT_RECORD.relative_to(ROOT)),
            "panel_policy": "Unpinned sessions coordinate before replacement; a pinned clipboard panel may coexist with translation by current product contract.",
        },
        "baseline_reference": {
            "legacy_story_used_for_ok": False,
            "note": "P7-D validates the current coordinator-presenter architecture and rejects stale completion/focus regressions.",
        },
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
