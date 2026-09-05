import AppKit
import BlocksCore

enum ClipboardRepositoryStorageState: String {
    case normal
    case unavailable
    case empty
    case filtered
    case redacted
}

struct ClipboardRepositoryStateSummary: Equatable {
    let state: ClipboardRepositoryStorageState
    let title: String
    let detail: String

    static func normal(recordCount: Int) -> ClipboardRepositoryStateSummary {
        ClipboardRepositoryStateSummary(
            state: .normal,
            title: L10n.string("clipboard.hardening.storage.normal.title"),
            detail: L10n.format("clipboard.hardening.storage.normal.detail", recordCount)
        )
    }

    static func unavailable() -> ClipboardRepositoryStateSummary {
        ClipboardRepositoryStateSummary(
            state: .unavailable,
            title: L10n.string("clipboard.hardening.state.unavailable.title"),
            detail: L10n.string("clipboard.hardening.state.unavailable.detail")
        )
    }

    static func empty() -> ClipboardRepositoryStateSummary {
        ClipboardRepositoryStateSummary(
            state: .empty,
            title: L10n.string("clipboard.hardening.state.empty.title"),
            detail: L10n.string("clipboard.hardening.state.empty.detail")
        )
    }

    static func redacted(recordCount: Int) -> ClipboardRepositoryStateSummary {
        ClipboardRepositoryStateSummary(
            state: .redacted,
            title: L10n.string("clipboard.hardening.state.redacted.title"),
            detail: L10n.string("clipboard.hardening.state.redacted.detail")
        )
    }
}

enum ClipboardRedactedPreviewBuilder {
    static func preview(
        record: ClipboardRecorderRecord,
        metadata: ClipboardPinnedItemMetadata? = nil,
        pinboardName: String? = nil
    ) -> ClipboardRecordPreview {
        return ClipboardRecordPreview(
            title: redactedTitle(for: record),
            body: redactedBody(for: record, pinboardName: pinboardName),
            badge: record.kind.localizedTitle,
            image: nil
        )
    }

    static func searchableText(
        record: ClipboardRecorderRecord,
        metadata: ClipboardPinnedItemMetadata? = nil,
        pinboardName: String? = nil
    ) -> String {
        [
            pinboardName ?? "",
            record.sourceDisplayName,
            record.kind.localizedTitle,
            record.formatSummary.types.joined(separator: " "),
            record.signatureSHA256_12,
            redactedBody(for: record, pinboardName: pinboardName)
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func redactedTitle(for record: ClipboardRecorderRecord) -> String {
        if record.excluded || record.snapshotSkipped {
            return L10n.string("clipboard.preview.excludedTitle")
        }
        switch record.kind {
        case .text:
            return L10n.string("clipboard.preview.textTitle")
        case .richText:
            return L10n.string("clipboard.preview.richTextTitle")
        case .image:
            return L10n.string("clipboard.preview.imageTitle")
        case .url:
            return L10n.string("clipboard.preview.urlTitle")
        case .fileURL:
            return L10n.string("clipboard.preview.fileTitle")
        case .mixed:
            return L10n.string("clipboard.preview.mixedTitle")
        case .unknown:
            return L10n.string("clipboard.preview.unknownTitle")
        }
    }

    private static func redactedBody(for record: ClipboardRecorderRecord, pinboardName: String?) -> String {
        if record.excluded || record.snapshotSkipped {
            return L10n.string("clipboard.preview.excludedBody")
        }
        if let textLength = record.formatSummary.textLength {
            return L10n.format("clipboard.preview.textLength", textLength)
        }
        if let fileCount = record.formatSummary.fileCount {
            return L10n.format("clipboard.preview.fileBody", fileCount)
        }
        if let urlCount = record.formatSummary.urlCount {
            return L10n.format("clipboard.hardening.urlCount", urlCount)
        }
        if let byteCount = record.formatSummary.byteCount {
            return L10n.format("clipboard.preview.byteCount", byteCount)
        }
        let pinboard = pinboardName.map { L10n.format("clipboard.hardening.pinboardSummary", $0) }
        return pinboard ?? L10n.string("clipboard.hardening.state.redacted.detail")
    }
}

extension ClipboardRecorderRecord {
    func redactedPreview(
        metadata: ClipboardPinnedItemMetadata? = nil,
        pinboardName: String? = nil
    ) -> ClipboardRecordPreview {
        ClipboardRedactedPreviewBuilder.preview(record: self, metadata: metadata, pinboardName: pinboardName)
    }

    func redactedSearchableText(
        metadata: ClipboardPinnedItemMetadata? = nil,
        pinboardName: String? = nil
    ) -> String {
        ClipboardRedactedPreviewBuilder.searchableText(record: self, metadata: metadata, pinboardName: pinboardName)
    }
}
