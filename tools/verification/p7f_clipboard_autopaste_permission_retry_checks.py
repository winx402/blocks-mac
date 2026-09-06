#!/usr/bin/env python3
"""Current permission-refresh and explicit paste-retry source contracts."""
import json
import re
import sys
from pathlib import Path
from p9b_clipboard_appstate_repository_integration_checks import body_of

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def refresh_never_replays(source: str) -> bool:
    body = body_of(source, "func pastePermissionStateDidRefresh(")
    return (
        "autoPasteCoordinator.hasEventPostingAccess" in body
        and "pendingPasteRequest = nil" in body
        and "startPaste(" not in body
        and "retryPendingPasteIfPossible(" not in body
    )


def main() -> int:
    coordinator = read("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift")
    paste = read("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPasteOrchestrator.swift")
    app = read("apps/Blocks/BlocksApp/App/AppModel.swift")
    delegation = read("apps/Blocks/BlocksApp/App/AppModel+FeatureDelegation.swift")
    auto = read("apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift")
    strings = read("apps/Blocks/BlocksApp/Resources/Localizable.xcstrings")
    retry = body_of(paste, "private func retryPendingPasteIfPossible(")
    refresh = body_of(delegation, "func refreshPermissionState()")
    callbacks = re.sub(r"\s+", "", paste)
    fixture = "func pastePermissionStateDidRefresh() { guard autoPasteCoordinator.hasEventPostingAccess else { return }; pendingPasteRequest = nil }"
    checks = {
        "pending_request_retains_committed_lease": "var pendingPasteRequest: PendingPasteRequest?" in coordinator
        and "preparedWriteLease: preparedWriteLease" in coordinator,
        "permission_refresh_is_not_a_paste_gesture": refresh_never_replays(paste),
        "app_permission_observers_do_not_replay": "clipboardCoordinator?.pastePermissionStateDidRefresh()" in app
        and "clipboardCoordinator.pastePermissionStateDidRefresh()" in refresh
        and "retryPendingPasteIfPossible" not in refresh,
        "assist_callbacks_only_refresh": callbacks.count("self?.pastePermissionStateDidRefresh(requestToken:requestToken)") == 2
        and "self?.retryPendingPasteIfPossible(requestToken:" not in callbacks,
        "explicit_retry_reuses_write": "request.retryingAfterAccessibilityGrant()" in retry
        and "startPaste(retryRequest)" in retry,
        "event_permission_is_independent_of_AX": "CGPreflightPostEventAccess()" in auto
        and "CGRequestPostEventAccess()" in auto
        and "eventPostingAccess(promptForAccessibility)" in auto
        and "AXIsProcessTrusted" not in auto,
        "new_gesture_guidance_localized": "status.clipboardPastePermissionReady.detail" in strings,
        "replay_regression_is_rejected": refresh_never_replays(fixture)
        and not refresh_never_replays(fixture.replace("pendingPasteRequest = nil", "pendingPasteRequest = nil; startPaste(oldRequest)")),
    }
    print(json.dumps({"ok": all(checks.values()), "check": "p7f_clipboard_autopaste_permission_retry",
                      "verification_scope": "source_contracts_only", "checks": checks}, ensure_ascii=False, indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
