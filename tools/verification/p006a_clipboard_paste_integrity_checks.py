#!/usr/bin/env python3
"""P006-A clipboard paste integrity checks.

The pasteboard transaction now belongs to BlocksClipboardBroker.  This gate
keeps the App-side focus/one-Cmd-V contract and checks the async broker
boundary without compiling the removed in-process pasteboard writer.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from p9b_clipboard_appstate_repository_integration_checks import body_of


ROOT = Path(__file__).resolve().parents[2]
BLOCKS = ROOT / "apps" / "Blocks"
APP = BLOCKS / "BlocksApp"
CORE = BLOCKS / "BlocksCore"
BROKER = BLOCKS / "BlocksClipboardBroker"
COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift"
PASTE_ORCHESTRATOR = APP / "Features" / "Clipboard" / "ClipboardPasteOrchestrator.swift"
PRESENTER = APP / "Services" / "ClipboardHistoryPanelPresenter.swift"
AUTOPASTE = APP / "Services" / "ClipboardAutoPasteCoordinator.swift"
PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
TEXT_PREVIEW = APP / "Services" / "ClipboardTextPreviewService.swift"
TRANSLATION_COORDINATOR = APP / "Features" / "Translation" / "TranslationFeatureCoordinator.swift"
APP_TESTS = BLOCKS / "BlocksAppTests"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def read_tree(path: Path) -> str:
    return "\n".join(
        child.read_text(encoding="utf-8")
        for child in sorted(path.rglob("*.swift"))
    ) if path.exists() else ""


def section(source: str, marker: str, next_marker: str | None = None) -> str:
    start = source.find(marker)
    if start < 0:
        return ""
    tail = source[start:]
    if next_marker is None:
        return tail
    end = tail.find(next_marker, len(marker))
    return tail if end < 0 else tail[:end]


def contains_async_call(source: str, method: str) -> bool:
    return re.search(
        rf"\bawait\b[\s\S]{{0,240}}?\.{re.escape(method)}\s*\(",
        source,
    ) is not None


def main() -> int:
    coordinator = read(COORDINATOR) + "\n" + read(PASTE_ORCHESTRATOR)
    presenter = read(PRESENTER)
    autopaste = read(AUTOPASTE)
    panel = read(PANEL)
    text_preview = read(TEXT_PREVIEW)
    translation_coordinator = read(TRANSLATION_COORDINATOR)
    app_source = read_tree(APP)
    broker = read_tree(BROKER)
    core = read_tree(CORE)
    tests = read_tree(APP_TESTS)
    target_capture = body_of(autopaste, "static func capturePasteTargetContext(")
    target_validation = body_of(autopaste, "private func focusStillMatchesCapturedTarget(")
    broker_write = body_of(broker, "private func performMaterializedWrite(")
    before_clear = broker_write.split("let afterClear = clearPasteboard()", 1)[0]
    broker_boundary = "\n".join(
        read(path)
        for path in sorted(APP.rglob("*.swift"))
        if "ClipboardBroker" in read(path)
    )

    close_after = section(presenter, "func close(afterClose:", "private func requestClosePanel")
    explicit_close = section(presenter, "func close()", "func close(afterClose:")
    will_close = section(presenter, "func windowWillClose", "func windowDidBecomeKey")
    target_accessor = section(presenter, "func targetContextForPaste", "func quickPasteSnapshotRecordID")
    retry = section(coordinator, "func retryPendingPasteIfPossible", "private func continuePasteRecord")
    start_paste = section(coordinator, "func startPaste(", "private func continuePasteRecord")
    copy = section(autopaste, "func copyToPasteboard(", "func dispatchPaste(")
    paste = section(autopaste, "func dispatchPaste(", "private func partialFailure")
    lease_validation = section(
        autopaste,
        "private func ensurePasteboardOwnership(",
        "private static func focusIdentity",
    )

    output_callers = "\n".join(
        source
        for source in (
            coordinator,
            text_preview,
            translation_coordinator,
            read(APP / "Features" / "Screenshot" / "Editor" / "ScreenshotEditorStore.swift"),
            read(APP / "Features" / "Screenshot" / "Output" / "ScreenshotPasteboardWriter.swift"),
        )
        if source
    )

    checks = {
        "closed_panel_drops_cached_target": (
            "invocationContext = nil" in will_close
            and "guard isVisible" in target_accessor
            and "isEligiblePasteTarget(targetContext.target.runningApplication)" in target_accessor
        ),
        "pinned_paste_uses_common_dirty_action_guard": (
            "requestDirtyAction" in close_after
            and "afterClose()" not in close_after
            and "detailStore.requestAction" in presenter
        ),
        "explicit_close_uses_dirty_guard": (
            "requestClosePanel()" in explicit_close
            and "closeImmediately()" not in explicit_close
        ),
        "pending_request_preserves_full_context": all(
            needle in coordinator
            for needle in [
                "struct PendingPasteRequest",
                "let recordID: String",
                "let targetContext: ClipboardPasteTargetContext?",
                "let promptForAccessibility: Bool",
                "let token: UUID",
                "var pendingPasteRequest: PendingPasteRequest?",
            ]
        )
        and "pendingPasteRecordID" not in coordinator
        and "requestToken" in retry,
        "paste_target_is_captured_before_nonactivating_panel": all(
            needle in presenter + "\n" + coordinator + "\n" + autopaste
            for needle in [
                "ClipboardPasteTargetContext",
                "windowID",
                "launchDate",
                "capturePasteTargetContext",
                "ClipboardExternalTargetTracker",
                ".nonactivatingPanel",
                "frontmostVisibleWindowID",
            ]
        )
        and "restoreTargetFocus" not in autopaste
        and "postToPid" not in autopaste
        and "targetContext:" in coordinator
        and "targetApplication:" not in section(
            coordinator,
            "struct PendingPasteRequest",
            "let clipboardStore",
        ),
        "input_evidence_is_separate_from_window_routing": all(
            needle in autopaste
            for needle in [
                "struct ClipboardPasteFocusSnapshot",
                "struct ClipboardPasteFocusIdentity",
                "chromeAXNodeID",
                "windowID",
                "launchDate",
                "hasTextContentModel",
                "hasTextSelectionModel",
                "hasWebAreaAncestor",
                "hasStableWebNodeIdentity",
            ]
        )
        and "resolveFocusedElement" not in autopaste
        and "focusMatchesSnapshot" not in autopaste
        and "AXUIElementSetAttributeValue" not in autopaste,
        "paste_requests_are_serialized_end_to_end": (
            "var pasteTask: Task<Void, Never>?" in coordinator
            and "pasteTask?.cancel()" in start_paste
            and "pasteTransactionState.begin(token: request.token)" in start_paste
            and "pasteTransactionIsCurrent(generation, request: request)" in coordinator
            and "pasteTask = task" in start_paste
        ),
        "pasteboard_write_failures_are_checked": (
            "pasteboardWriteFailed" in autopaste + "\n" + coordinator + "\n" + broker_boundary
            and "ClipboardAutoPasteError" in autopaste
            and ("ClipboardBroker" in autopaste + "\n" + broker_boundary)
        ),
        "all_explicit_writes_delegate_async_broker": (
            "ClipboardBroker" in output_callers
            and "await" in output_callers
            and "NSPasteboard.general" not in app_source
            and "init(pasteboard: NSPasteboard = .general)" not in app_source
            and "init(broker: any ClipboardBrokerServing = ClipboardBrokerClient.shared)" in autopaste
            and "init(pasteboard: NSPasteboard)" in autopaste
        ),
        "plain_text_self_writes_are_centralized": (
            (
                "writePlainText" in broker_boundary
                or "ClipboardBrokerWriteRequest" in broker_boundary
                or "ClipboardWriteRequest" in broker_boundary
            )
            and "ClipboardPasteboardChangeSuppressor.shared.suppress" not in translation_coordinator
            and "ignorePasteboardChange" not in app_source
        ),
        "copy_and_dispatch_are_explicit_async_stages": (
            "async throws -> ClipboardAutoPasteCopyResult" in copy
            and "pasteboardLease: pasteboardLease" in copy
            and "mayContinueAutomaticPaste:" in copy
            and contains_async_call(copy, "write")
            and "guard let targetContext" not in copy
            and "guard let targetContext" in paste
            and "try await ensurePasteboardOwnership" in paste
            and "await pasteboardWriter.validate" in lease_validation
        ),
        "frontmost_verification_is_async_single_flight": (
            "async throws -> PasteResult" in paste
            and "await waitForStableTargetFrontmost" in paste
            and "frontmostApplicationProvider" in autopaste
            and "Task.sleep" in autopaste
            and "RunLoop.current.run" not in autopaste
            and "targetIdentityMatches" in autopaste
            and ".activate(options:" not in autopaste
        ),
        "missing_ax_focus_uses_session_event_for_frozen_target": all(
            needle in autopaste
            for needle in [
                "ClipboardTargetFrontmostStability",
                "waitForStableTargetFrontmost",
                "paste route=window-preserving",
                ".post(tap: .cgSessionEventTap)",
            ]
        )
        and "private static let pasteFallbackMaxWait: TimeInterval = 0.35" in autopaste
        and "requiredConsecutiveMatches: 2" in autopaste
        and "postToPid" not in autopaste,
        "main_routing_works_without_AX_input_access": (
            "frontmostVisibleWindowID(" in target_capture
            and "windowID: windowID" in target_capture
            and "current.windowID == capturedWindow" in target_validation
            and "current.target == target" in target_validation
            and "AXUIElementCopyAttributeValue" not in autopaste
            and "AXIsProcessTrusted" not in autopaste
            and "captured.focusedElement" not in target_validation
        ),
        "broker_write_is_single_attempt_without_old_item_reads": (
            "NSPasteboardItem" in broker
            and broker_write.count("clearPasteboard()") == 1
            and broker_write.count("writeMaterializedPasteboard(") == 1
            and "purpose: .target" in broker_write
            and "purpose: .rollback" not in broker_write
            and "snapshot(" not in before_clear
            and "pasteboard.pasteboardItems" not in before_clear
            and "snapshotItems()" not in broker + "\n" + app_source
            and "ClipboardPasteboardWriteFailure" not in broker + "\n" + app_source
            and "rollbackSucceeded" not in broker
        ),
        "pasteboard_write_has_bounded_content_free_telemetry": (
            'category: "ClipboardWrite"' in broker + "\n" + broker_boundary
            and "write-start" in broker + "\n" + broker_boundary
            and any(
                token in (broker + "\n" + broker_boundary)
                for token in ("write-finished", "write-finish")
            )
            and any(
                token in (broker + "\n" + broker_boundary)
                for token in ("write-failed", "write-timeout", "timeout")
            )
            and not re.search(
                r"(?:text|content|payload|url|path|base64|ocr)=",
                broker + "\n" + broker_boundary,
                re.IGNORECASE,
            )
        ),
        "write_lease_is_generation_scoped_and_tested": (
            "ClipboardPasteboardWriteLease" in autopaste + "\n" + broker_boundary + "\n" + core
            and "generation" in autopaste + "\n" + broker_boundary + "\n" + core
            and re.search(r"validate[\s\S]{0,240}async", broker_boundary) is not None
            and "ClipboardPasteboardWriterBrokerTests" in tests
        ),
        "tracks_latest_non_blocks_target_while_panel_visible": all(
            needle in presenter
            for needle in [
                "ClipboardExternalTargetTracker",
                "didActivateApplicationNotification",
                "activationObserver",
                "recordExplicitActivation",
                "updatePinnedTargetContext",
                "isEligiblePasteTarget",
            ]
        )
        and "Timer.scheduledTimer" not in presenter
        and "setContinuousTracking" not in presenter,
        "system_overlay_fallback_never_treats_blocks_as_frontmost_target": all(
            needle in presenter + "\n" + autopaste
            for needle in [
                "frontmostOverlayBundleIdentifiers",
                "shouldUseVisibleWindowFallback",
                "frontmostVisibleEligibleApplication",
            ]
        ),
        "return_uses_unified_selected_record_action": (
            "onSubmitSearch: pasteSelectedRecordFromKeyboard" in panel
            and "private func pasteSelectedRecordFromKeyboard" in panel
            and "source: .keyboard" in panel
            and "action: .paste" in panel
        ),
    }

    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({
        "gate": "P006A",
        "ok": not failures,
        "checks": checks,
        "failures": failures,
        "note": (
            "Static boundary/focus gate. Broker transaction behavior is covered "
            "by ClipboardIOBrokerTests and P006-F; no system pasteboard is touched."
        ),
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
