import AppKit
import BlocksCore

struct ClipboardRecordPreview {
    let title: String
    let body: String
    let badge: String
    let image: NSImage?

    var searchableText: String {
        [title, body, badge].joined(separator: " ").lowercased()
    }
}

extension ClipboardRecorderRecord {
    func preview(metadata: ClipboardPinnedItemMetadata? = nil, payload: ClipboardRecorderPayload? = nil) -> ClipboardRecordPreview {
        let recordTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = recordTitle?.isEmpty == false ? recordTitle! : kind.localizedTitle
        return ClipboardRecordPreview(
            title: title,
            body: previewBody(payload: payload),
            badge: kind.localizedTitle,
            image: previewImage(payload: payload)
        )
    }

    private func previewBody(payload: ClipboardRecorderPayload?) -> String {
        if excluded || snapshotSkipped {
            if let skipReason = ClipboardCaptureSkipReason(summaryCode: summary) {
                return skipReason.localizedPreviewBody
            }
            return L10n.string("clipboard.preview.excludedBody")
        }
        switch kind {
        case .text, .richText:
            return payload?.text?.isEmpty == false ? payload!.text! : sanitizedSummaryOrFallback(L10n.string("clipboard.preview.contentUnavailable"))
        case .image:
            return L10n.string("clipboard.preview.imageBodyUnknown")
        case .url:
            return urlDisplaySummary(payload: payload) ?? sanitizedSummaryOrFallback(L10n.string("clipboard.preview.contentUnavailable"))
        case .fileURL:
            return fileDisplayName(payload: payload) ?? L10n.string("clipboard.preview.fileBodyUnknown")
        case .mixed:
            return L10n.format("clipboard.preview.mixedBody", formatSummary.itemCount)
        case .unknown:
            return sanitizedSummaryOrFallback(L10n.string("clipboard.preview.contentUnavailable"))
        }
    }

    private func previewImage(payload: ClipboardRecorderPayload?) -> NSImage? {
        guard kind == .image,
              let data = payload?.pngData else {
            return nil
        }
        return NSImage(data: data)
    }

    var sourceDisplayName: String {
        if let name = sourceApp?.localizedName, !name.isEmpty {
            return name
        }
        if let bundleIdentifier = sourceApp?.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return L10n.string("clipboard.sourceUnknown")
    }

    var searchableText: String {
        [
            redactedPreview().searchableText,
            sourceDisplayName,
            kind.localizedTitle,
            formatSummary.types.joined(separator: " "),
            signatureSHA256_12
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func urlDisplaySummary(payload: ClipboardRecorderPayload?) -> String? {
        guard let rawValue = payload?.urlString ?? payload?.text,
              let url = URL(string: rawValue) else {
            return nil
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return rawValue
        }
        let path = url.path(percentEncoded: false)
        return path.isEmpty || path == "/" ? host : "\(host)\(path)"
    }

    private func fileDisplayName(payload: ClipboardRecorderPayload?) -> String? {
        guard let rawValue = payload?.urlString ?? payload?.text, !rawValue.isEmpty else {
            return nil
        }
        if let url = URL(string: rawValue), url.isFileURL {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: rawValue).lastPathComponent
    }

    private func sanitizedSummaryOrFallback(_ fallback: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }
        let blockedFragments = [
            "content redacted",
            "payload omitted",
            "no base64",
            "redacted from record summary"
        ]
        if blockedFragments.contains(where: { trimmed.lowercased().contains($0) }) {
            return fallback
        }
        return trimmed
    }
}
