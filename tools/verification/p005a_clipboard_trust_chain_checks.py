#!/usr/bin/env python3
"""005-A clipboard trust-chain gate.

This is a current-source static gate for the 005 trust-chain requirements.
It proves the implementation shape for the denied Accessibility path, but it
does not replace a real denied-TCC runtime acceptance run.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
BROKER = ROOT / "apps" / "Blocks" / "BlocksClipboardBroker"
BROKER_PROTOCOL = ROOT / "apps" / "Blocks" / "BlocksCore" / "ClipboardBrokerProtocol.swift"

AUTOPASTE = APP / "Services" / "ClipboardAutoPasteCoordinator.swift"
CAPTURE = APP / "Services" / "ClipboardLiveCaptureService.swift"
CLIPBOARD_COORDINATOR = APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift"
PASTE_ORCHESTRATOR = APP / "Features" / "Clipboard" / "ClipboardPasteOrchestrator.swift"
PRESENTER = APP / "Services" / "ClipboardHistoryPanelPresenter.swift"
PANEL = APP / "Views" / "ClipboardFloatingPanelView.swift"
PANEL_EXTRACTED = [
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelHeader.swift",
    APP / "Features" / "Clipboard" / "Panel" / "ClipboardPanelLayout.swift",
]
STRINGS = APP / "Resources" / "Localizable.xcstrings"

LANGUAGES = ["zh-Hans", "en", "ja"]
REQUIRED_LOCALIZATION_KEYS = [
    "status.clipboardPastePermission.title",
    "status.clipboardPastePermission.detail",
    "status.clipboardPasteCopiedFallback.title",
    "status.clipboardPasteCopiedFallback.detail",
    "status.clipboardPasteFailed.title",
    "status.clipboardPasteFailed.notFound",
]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_tree(path: Path) -> str:
    return "\n".join(
        child.read_text(encoding="utf-8")
        for child in sorted(path.rglob("*.swift"))
    ) if path.exists() else ""


def ordered(source: str, needles: list[str]) -> bool:
    cursor = -1
    for needle in needles:
        index = source.find(needle)
        if index <= cursor:
            return False
        cursor = index
    return True


def section(source: str, start: str, end: str | None = None) -> str:
    if start not in source:
        return ""
    tail = source.split(start, 1)[1]
    if end and end in tail:
        return tail.split(end, 1)[0]
    return tail


def has_localization_keys() -> tuple[bool, list[str]]:
    strings = json.loads(read(STRINGS)).get("strings", {})
    missing: list[str] = []
    for key in REQUIRED_LOCALIZATION_KEYS:
        if key not in strings:
            missing.append(key)
            continue
        localizations = strings[key].get("localizations", {})
        for language in LANGUAGES:
            value = (
                localizations
                .get(language, {})
                .get("stringUnit", {})
                .get("value", "")
                .strip()
            )
            if not value:
                missing.append(f"{key}:{language}")
    return not missing, missing


def main() -> int:
    autopaste = read(AUTOPASTE)
    capture = read(CAPTURE)
    broker = read_tree(BROKER)
    broker_protocol = read(BROKER_PROTOCOL)
    clipboard_coordinator = read(CLIPBOARD_COORDINATOR) + "\n" + read(PASTE_ORCHESTRATOR)
    presenter = read(PRESENTER)
    panel = "\n".join(read(path) for path in [PANEL, *PANEL_EXTRACTED])
    partial_failure_section = section(
        clipboard_coordinator,
        "private func handlePartialPasteFailure(",
        "private func handlePasteError(",
    )
    accessibility_branch = section(
        partial_failure_section,
        "case .accessibilityPermissionRequired:",
        "case .targetApplicationNotFrontmost:",
    )
    quick_paste_section = section(
        clipboard_coordinator,
        "func pasteQuickRecord(index: Int)",
        "func toggleRecorderPaused",
    )
    copy_section = section(
        autopaste,
        "func copyToPasteboard(",
        "func dispatchPaste(",
    )
    broker_capture_section = section(
        broker,
        "private func preferredRepresentation",
        "private func write(",
    )
    localization_ok, missing_localizations = has_localization_keys()

    checks = {
        "pasteboard_written_before_accessibility_check": (
            "func copyToPasteboard(" in autopaste
            and "await" in copy_section
            and ".write(" in copy_section
            and ordered(autopaste, [
                "func copyToPasteboard(",
                "func dispatchPaste(",
                "accessibilityTrusted(promptForAccessibility)",
            ])
        ),
        "accessibility_denial_is_partial_after_write": all(
            needle in autopaste
            for needle in [
                "ClipboardAutoPastePartialFailure(",
                "throw partialFailure(.accessibilityPermissionRequired, lease: pasteboardLease)",
                "pasteboardChangeCountAfterWrite: pasteboardLease.changeCount",
            ]
        ),
        "autopaste_requires_preserved_target_before_shortcut": all(
            needle in autopaste
            for needle in [
                "waitForStableTargetFrontmost",
                "pasteFallbackRetryInterval",
                "pasteFallbackMaxWait",
                "frontmostApplicationProvider",
                "await waitForStableTargetFrontmost",
                "Task.sleep",
            ]
        ) and "postToPid" not in autopaste and ".activate(options:" not in autopaste,
        "image_pasteboard_writes_png_and_tiff": (
            '"public.png"' in autopaste
            and "NSBitmapImageRep(data: sourcePNGData)" in broker
            and "using: .tiff" in broker
            and "setData(derivedTIFF, forType: .tiff)" in broker
            and "tiffData(fromPNGData:" not in autopaste
        ),
        "file_url_pasteboard_uses_url_and_filenames_types": all(
            needle in autopaste + "\n" + broker
            for needle in [
                "NSURL(string: urlString)",
                "NSPasteboard.PasteboardType(\"NSFilenamesPboardType\")",
                "setPropertyList",
            ]
        ),
        "coordinator_marks_internal_write_and_preserves_partial_copy": all(
            needle in autopaste + "\n" + capture + "\n" + broker + "\n" + partial_failure_section
            for needle in [
                "ClipboardPasteboardWriteOrigin",
                "suppressedChangeCounts",
                "clipboardStore.pasteAttempt?.state = .pasteboardWritten",
                "switch failure.reason",
            ]
        ),
        "accessibility_denial_sets_retry_and_user_status": all(
            needle in accessibility_branch
            for needle in [
                "pendingPasteRequest = request",
                "clipboardStore.pasteAttempt?.failureReason = .notAuthorized",
                "presentAccessibilityAssist {",
                'title: "status.clipboardPastePermission.title"',
                'L10n.string("status.clipboardPastePermission.detail")',
            ]
        ),
        "quick_paste_uses_same_copy_and_promotion_path": all(
            needle in quick_paste_section
            for needle in [
                "makePendingPasteRequest(",
                "promptForAccessibility: true",
                "startPaste(request)",
            ]
        ) and "markRecent" not in quick_paste_section,
        "double_click_and_return_use_same_paste_path": (
            "pasteRecord: { [weak self] in self?.pasteRecord(recordID: $0) }" in clipboard_coordinator
            and "actions.pasteRecord(recordID)" in panel
            and "onSubmitSearch: pasteSelectedRecordFromKeyboard" in panel
            and "action: .paste" in panel
        ),
        "permission_status_is_localized": localization_ok,
        "file_urls_remain_file_references_on_capture": (
            "fileURL" in broker_capture_section
            and "Data(contentsOf:" not in broker_capture_section
            and "NSImage(contentsOf:" not in broker_capture_section
            and "imageFileURLSnapshot" not in capture
        ),
        "plain_image_paths_do_not_trigger_file_io": (
            "imageFilePathSnapshot" not in capture + "\n" + broker
            and "String(contentsOf:" not in broker_capture_section
            and "Data(contentsOf:" not in broker_capture_section
        ),
        "captured_image_payload_stays_binary_in_memory": (
            "pngData: pngData" in capture + "\n" + broker
            and "pngDataBase64" not in capture + "\n" + broker
            and ".base64EncodedString()" not in capture + "\n" + broker
        ),
        "pasteboard_image_capture_has_size_guards": all(
            needle in capture + "\n" + broker + "\n" + broker_protocol
            for needle in [
                "ClipboardBrokerLimits.maxRawImageBytes",
                "ClipboardBrokerLimits.maxCanonicalPNGBytes",
            ]
        )
        and any(
            token in capture + "\n" + broker + "\n" + broker_protocol
            for token in ("32 * 1024 * 1024", "33_554_432")
        )
        and any(
            token in capture + "\n" + broker + "\n" + broker_protocol
            for token in ("25 * 1024 * 1024", "26_214_400")
        ),
        "source_app_is_marked_best_effort": all(
            needle in capture
            for needle in [
                "sourceAppBestEffort",
                "PrivacyPathSanitizer",
                "bundlePathHash",
            ]
        ),
    }

    failures = [name for name, ok in checks.items() if not ok]
    result = {
        "gate": "P005A",
        "ok": not failures,
        "status": "pass" if not failures else "fail",
        "checks": checks,
        "missing_localizations": missing_localizations,
        "failures": failures,
        "note": "Static gate only; denied Accessibility runtime evidence still requires an untrusted TCC environment.",
        "checked_files": [
            str(AUTOPASTE.relative_to(ROOT)),
            str(CAPTURE.relative_to(ROOT)),
            str(CLIPBOARD_COORDINATOR.relative_to(ROOT)),
            str(PASTE_ORCHESTRATOR.relative_to(ROOT)),
            str(PRESENTER.relative_to(ROOT)),
            str(PANEL.relative_to(ROOT)),
            *(str(path.relative_to(ROOT)) for path in PANEL_EXTRACTED),
            str(STRINGS.relative_to(ROOT)),
            str(BROKER.relative_to(ROOT)),
            str(BROKER_PROTOCOL.relative_to(ROOT)),
        ],
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
