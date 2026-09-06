#!/usr/bin/env python3
"""P7-H clipboard nonactivating target and paste failure classification checks."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift"
PASTE_ORCHESTRATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPasteOrchestrator.swift"
PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift"
AUTOPASTE = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def has_partial_failure_after_clipboard_write(source: str) -> bool:
    """Keep the copied-to-pasteboard truth before every automatic-paste failure."""
    required = (
        "ClipboardAutoPastePartialFailure",
        "func copyToPasteboard(",
        "try await pasteboardWriter.write(",
        "func dispatchPaste(",
        "eventPostingAccess(promptForAccessibility)",
        "waitForStableTargetFrontmost",
        "pasteboardLease.changeCount",
    )
    return (
        all(token in source for token in required)
        and source.index("func copyToPasteboard(") < source.index("try await pasteboardWriter.write(")
        and source.index("try await pasteboardWriter.write(") < source.index("func dispatchPaste(")
        and source.index("func dispatchPaste(") < source.index("eventPostingAccess(promptForAccessibility)")
    )


def partial_failure_negative_fixture() -> bool:
    """Prove that deleting the awaited broker write invalidates this critical gate."""
    fixture = "\n".join(
        (
            "struct ClipboardAutoPastePartialFailure {}",
            "func copyToPasteboard() { try await pasteboardWriter.write() }",
            "func dispatchPaste() { eventPostingAccess(promptForAccessibility); waitForStableTargetFrontmost(); _ = pasteboardLease.changeCount }",
        )
    )
    return has_partial_failure_after_clipboard_write(fixture) and not has_partial_failure_after_clipboard_write(
        fixture.replace("try await pasteboardWriter.write()", "")
    )


def main() -> int:
    state = read(COORDINATOR) + "\n" + read(PASTE_ORCHESTRATOR)
    presenter = read(PRESENTER)
    autopaste = read(AUTOPASTE)
    strings = json.loads(read(STRINGS)).get("strings", {})
    checks = {
        "invocation_target_is_explicit_and_cleared": "ClipboardPanelInvocationContext" in presenter
        and "invocationContext = nil" in presenter
        and "com.apple.SystemSettings" in autopaste
        and "com.apple.systempreferences" in autopaste
        and "invocation-target-reused" not in presenter,
        "nonactivating_target_model": ".nonactivatingPanel" in presenter
        and "ClipboardExternalTargetTracker" in presenter
        and "contextForInvocation" in presenter
        and "func updatePinnedTargetContext" in presenter,
        "explicit_activation_and_pid_dispatch_removed": all(
            token not in autopaste
            for token in ["activateIgnoringOtherApps", ".activate(options:", "postToPid", "waitForTargetActivation"]
        ),
        "session_event_dispatch": ".post(tap: .cgSessionEventTap)" in autopaste
        and "waitForStableTargetFrontmost" in autopaste
        and "targetApplicationNotFrontmost" in autopaste,
        "partial_failure_after_clipboard_write": has_partial_failure_after_clipboard_write(autopaste),
        "partial_failure_after_clipboard_write_negative_fixture": partial_failure_negative_fixture(),
        "paste_states": "case pasteboardWritten" in autopaste
        and "case pasteCommandSent" in autopaste
        and "PasteResult" in autopaste,
        "appstate_failure_mapping": "case .targetApplicationNotFrontmost:" in state
        and "recordCopiedFallback(.targetApplicationNotFrontmost)" in state
        and "status.clipboardPasteCopiedFallback.detail" in state,
        "appstate_success_mapping": ".pasteCommandSent" in state
        and "status.clipboardPasteReady.detail" in state,
        "localization": all(
            key in strings
            for key in [
                "status.clipboardPasteCopiedFallback.title",
                "status.clipboardPasteCopiedFallback.detail",
            ]
        ),
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "ok": not failures,
        "suite": "p7h_clipboard_autopaste_activation_checks",
        "checks": checks,
        "failures": failures,
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
