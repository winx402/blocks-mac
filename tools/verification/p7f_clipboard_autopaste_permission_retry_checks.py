#!/usr/bin/env python3
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
CLIPBOARD_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
AUTO_PASTE = ROOT / "apps/Blocks/BlocksApp/Services/ClipboardAutoPasteCoordinator.swift"
STRINGS = ROOT / "apps/Blocks/BlocksApp/Resources/Localizable.xcstrings"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    app_model = read(APP_MODEL)
    clipboard_coordinator = read(CLIPBOARD_COORDINATOR)
    permission_coordinator = read(PERMISSION_COORDINATOR)
    auto_paste = read(AUTO_PASTE)
    strings = read(STRINGS)
    checks = {
        "pending_record_state": "private var pendingPasteRecordID" in clipboard_coordinator,
        "refresh_retries_pending": "func retryPendingPasteIfPossible()" in clipboard_coordinator
        and "guard accessibilityGranted(), let recordID = pendingPasteRecordID" in clipboard_coordinator,
        "missing_accessibility_opens_assist": "presentAccessibilityAssist { [weak self] in" in clipboard_coordinator
        and "permissionCoordinator?.presentAccessibilityAssist(onRefresh: onRefresh)" in app_model
        and "assistPanelPresenter.present(kind: .accessibility)" in permission_coordinator,
        "assist_callback_refresh": "self.store.refreshPermissionState()" in permission_coordinator
        and "onRefresh()" in permission_coordinator,
        "coordinator_prompt_gate": "promptForAccessibility: Bool = true" in auto_paste
        and "isAccessibilityTrusted(prompt: promptForAccessibility)" in auto_paste,
        "retry_failure_localized": "status.clipboardPasteRetry.detail" in strings,
    }
    ok = all(checks.values())
    print(json.dumps({
        "ok": ok,
        "check": "p7f_clipboard_autopaste_permission_retry",
        "checks": checks,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
