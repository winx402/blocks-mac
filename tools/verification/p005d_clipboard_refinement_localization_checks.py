#!/usr/bin/env python3
"""005-D localization gate for clipboard refinement.

This gate is intentionally scoped to the 005 retrofit surface: clipboard panel
menus, tag quick actions, detail editor states/errors, and detail metadata.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
LOCALIZABLE = APP / "Resources" / "Localizable.xcstrings"
FILTER_BAR = APP / "Views" / "ClipboardFilterBarView.swift"
FILTER_BAR_SOURCES = [
    FILTER_BAR,
    APP / "Features" / "Clipboard" / "Filters" / "ClipboardTagFilterChips.swift",
    APP / "Features" / "Clipboard" / "Filters" / "ClipboardFilterControls.swift",
]
RECORD_VIEWS = APP / "Views" / "ClipboardRecordViews.swift"
RECORD_VIEW_SOURCES = [
    RECORD_VIEWS,
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordPreviewViews.swift",
    APP / "Features" / "Clipboard" / "Records" / "ClipboardRecordMenus.swift",
]

LANGUAGES = ["zh-Hans", "en", "ja"]

REQUIRED_KEYS = [
    "common.cancel",
    "common.close",
    "common.save",
    "clipboard.tags.defaultName",
    "clipboard.tags.createDefault",
    "clipboard.tags.new",
    "clipboard.tags.rename",
    "clipboard.tags.delete",
    "clipboard.tags.delete.confirmTitle",
    "clipboard.tags.delete.confirmMessage",
    "clipboard.detail.editor.accessibilityLabel",
    "clipboard.detail.title",
    "clipboard.detail.edit",
    "clipboard.detail.unsaved.title",
    "clipboard.detail.saveAndContinue",
    "clipboard.detail.discardChanges",
    "clipboard.detail.continueEditing",
    "clipboard.detail.unsaved.message",
    "clipboard.detail.unsaved.confirmationMessage",
    "clipboard.detail.showFullValue",
    "clipboard.detail.showFullValue.accessibilityHint",
    "clipboard.detail.fullValue.accessibilityLabel",
    "clipboard.detail.metadata.accessibilityLabel",
    "clipboard.detail.fullValueUnavailable",
    "clipboard.detail.fullValueLoaded",
    "clipboard.detail.error.repositoryUnavailable",
    "clipboard.detail.error.recordUnavailable",
    "clipboard.detail.error.editableUnavailable",
    "clipboard.detail.error.richTextFidelity",
    "clipboard.detail.error.invalidURL",
    "clipboard.detail.error.revisionConflict",
    "clipboard.detail.error.saveFailed",
    "clipboard.detail.status.ready",
    "clipboard.detail.status.readOnly",
    "clipboard.detail.status.editing",
    "clipboard.detail.status.unsaved",
    "clipboard.detail.status.invalid",
    "clipboard.detail.status.saving",
    "clipboard.detail.status.saved",
    "clipboard.detail.status.savedIndexing",
    "clipboard.detail.status.indexFailed",
    "clipboard.detail.status.saveFailed",
    "clipboard.detail.status.unavailable",
    "clipboard.detail.type",
    "clipboard.detail.created",
    "clipboard.detail.lastCopied",
    "clipboard.detail.updated",
    "clipboard.detail.revision",
    "clipboard.detail.source",
    "clipboard.detail.ocr",
    "clipboard.detail.privacy",
    "clipboard.detail.tags",
    "clipboard.detail.hash",
    "clipboard.detail.url",
    "clipboard.detail.fileURL",
    "clipboard.detail.bundleIdentifier",
    "clipboard.detail.bundlePath",
    "clipboard.detail.bundlePathHash",
    "clipboard.detail.payloadHash",
    "clipboard.detail.ocrWithSource",
    "clipboard.detail.ocr.notRequired",
    "clipboard.detail.ocr.pending",
    "clipboard.detail.ocr.running",
    "clipboard.detail.ocr.succeeded",
    "clipboard.detail.ocr.failed",
    "clipboard.detail.ocr.source.none",
    "clipboard.detail.ocr.source.vision",
    "clipboard.detail.ocr.source.userEdited",
    "clipboard.detail.privacy.excluded",
    "clipboard.detail.privacy.snapshotSkipped",
    "clipboard.detail.privacy.notRestorable",
    "clipboard.detail.privacy.allowed",
    "clipboard.detail.headerRevision",
    "clipboard.detail.previewBounded",
    "privacy.title",
    "privacy.capturePolicy.title",
    "privacy.capturePolicy.detail",
    "privacy.refresh",
    "privacy.search.title",
    "privacy.search.detail",
    "privacy.search.placeholder",
    "privacy.filters.title",
    "privacy.filters.detail",
    "privacy.filter.policy",
    "privacy.filter.identity",
    "privacy.filter.all",
    "privacy.discoveredApps",
    "privacy.empty.noRows",
    "privacy.empty.noApps",
    "privacy.empty.noMatches",
    "privacy.mutation.title",
    "privacy.mutation.detail",
    "privacy.retry",
    "privacy.menu.policy",
    "privacy.duplicate.confirm",
    "privacy.noBundleIdentifier",
    "privacy.policy.default",
    "privacy.policy.allowed",
    "privacy.policy.restricted",
    "privacy.identity.verified",
    "privacy.identity.duplicateBundle",
    "privacy.identity.duplicateBundleID",
    "privacy.identity.missingBundle",
    "privacy.identity.missingBundleID",
    "privacy.identity.unreadable",
    "privacy.identity.unreadableApp",
    "privacy.identity.unsupported",
    "privacy.mutation.pending",
    "privacy.mutation.saving",
    "privacy.mutation.saved",
    "privacy.mutation.failed",
    "privacy.mutation.retry",
    "privacy.mutation.cancel",
    "privacy.mutation.unsupported",
]

SOURCE_FILES = [
    APP / "Views" / "ClipboardDetailEditorView.swift",
    APP / "Features" / "Clipboard" / "ClipboardDetailStore.swift",
    *RECORD_VIEW_SOURCES,
    *FILTER_BAR_SOURCES,
    APP / "Features" / "Clipboard" / "ClipboardStore.swift",
    APP / "Features" / "Privacy" / "PrivacySettingsPane.swift",
    APP / "Features" / "Privacy" / "PrivacyAppRowView.swift",
    CORE / "ClipboardDetailReadModel.swift",
    CORE / "ClipboardRepository+DetailEdit.swift",
]

FORBIDDEN_SOURCE_SNIPPETS = [
    'Label("Edit details"',
    '"Edit details", systemImage',
    "clipboard.context.editDetails",
    'private static let defaultQuickTagName = "New Tag"',
    'TextField("Title"',
    '"Unsaved changes"',
    '"Save and Continue"',
    '"Discard Changes"',
    '"Continue Editing"',
    '"Repository unavailable."',
    '"Record unavailable."',
    '"Save failed."',
    '"Full value loaded."',
    '"Full value unavailable."',
    "clipboard.filter.tags",
    'Text("Clipboard Privacy"',
    'title: "App capture policy"',
    'TextField("Search"',
    'Label("Refresh"',
    'Label("Policy"',
    '"Apply this policy to all copies with the same bundle identifier?"',
    'app.bundleIdentifier ?? "No bundle identifier"',
    'mutationState.rawValue',
    'Text("\\(model.boundedPreview.badge) · revision',
    '"Preview is bounded. Full value requires an explicit detail read."',
]

REQUIRED_SOURCE_SNIPPETS = {
    APP / "Views" / "ClipboardDetailEditorView.swift": [
        "metadataTitle(_ item:",
        "metadataValue(_ item:",
        "localizedOCRValue",
        "localizedPrivacyValue",
        "displayTitle(_ model:",
        "displayPreviewBody(_ model:",
        "clipboard.detail.headerRevision",
        "clipboard.detail.previewBounded",
        "clipboard.detail.editor.accessibilityLabel",
        "clipboard.detail.showFullValue",
    ],
    APP / "Features" / "Clipboard" / "ClipboardDetailStore.swift": [
        "clipboard.detail.error.repositoryUnavailable",
        "clipboard.detail.error.invalidURL",
        "clipboard.detail.unsaved.message",
    ],
    RECORD_VIEWS: [
        "clipboard.tags.defaultName",
        "clipboard.tags.createDefault",
    ],
    FILTER_BAR: [
        "clipboard.tags.new",
        "clipboard.tags.rename",
        "clipboard.tags.delete",
        "clipboard.tags.delete.confirmTitle",
        "clipboard.tags.delete.confirmMessage",
    ],
    APP / "Features" / "Clipboard" / "ClipboardStore.swift": [
        "displayBody(for record:",
        "clipboard.preview.contentUnavailable",
        "clipboard.preview.imageBodyUnknown",
        "ClipboardCaptureSkipReason(summaryCode: snapshotBody)",
        "skipReason.localizedPreviewBody",
    ],
    APP / "Features" / "Privacy" / "PrivacySettingsPane.swift": [
        'L10n.string("privacy.title")',
        'L10n.format("privacy.filters.detail"',
        "mutationState.localizedTitle",
    ],
    APP / "Features" / "Privacy" / "PrivacyAppRowView.swift": [
        'L10n.string("privacy.menu.policy")',
        'L10n.string("privacy.duplicate.confirm")',
        "displayedMutationState.localizedTitle",
    ],
    CORE / "ClipboardDetailReadModel.swift": [
        "titleKey",
        "titleIsCustom",
    ],
    CORE / "ClipboardRepository+DetailEdit.swift": [
        'titleKey: "clipboard.detail.type"',
        'titleKey: "clipboard.detail.lastCopied"',
        'titleKey: "clipboard.detail.privacy"',
        'titleKey: "clipboard.detail.payloadHash"',
    ],
}

SOURCE_AGGREGATES = {
    FILTER_BAR: FILTER_BAR_SOURCES,
    RECORD_VIEWS: RECORD_VIEW_SOURCES,
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    failures: list[dict[str, str]] = []
    localizable = json.loads(read(LOCALIZABLE))
    strings = localizable.get("strings", {})

    for key in REQUIRED_KEYS:
        entry = strings.get(key)
        missing = []
        for language in LANGUAGES:
            value = (
                entry
                or {}
            ).get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", "")
            if not value:
                missing.append(language)
            if "clipboard." in value or ".filter." in value:
                failures.append({"code": "internal_key_value_exposed", "detail": f"{key}:{language}", "file": str(LOCALIZABLE.relative_to(ROOT))})
        if entry is None or missing:
            failures.append({"code": "missing_localization", "detail": f"{key}:{','.join(missing or LANGUAGES)}", "file": str(LOCALIZABLE.relative_to(ROOT))})

    source_blob = "\n".join(read(path) for path in SOURCE_FILES)
    for snippet in FORBIDDEN_SOURCE_SNIPPETS:
        if snippet in source_blob:
            failures.append({"code": "forbidden_source_snippet", "detail": snippet, "file": "005 clipboard source scope"})

    for path, snippets in REQUIRED_SOURCE_SNIPPETS.items():
        content = "\n".join(read(source_path) for source_path in SOURCE_AGGREGATES.get(path, [path]))
        for snippet in snippets:
            if snippet not in content:
                failures.append({"code": "required_source_snippet_missing", "detail": snippet, "file": str(path.relative_to(ROOT))})

    report = {
        "gate": "P005D",
        "ok": not failures,
        "status": "pass" if not failures else "fail",
        "checked_localization_keys": len(REQUIRED_KEYS),
        "languages": LANGUAGES,
        "checked_files": [str(path.relative_to(ROOT)) for path in SOURCE_FILES] + [str(LOCALIZABLE.relative_to(ROOT))],
        "failures": failures,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
