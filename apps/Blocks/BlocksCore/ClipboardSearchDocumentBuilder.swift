import Foundation

public struct ClipboardSearchDocumentBuilder {
    public struct Configuration {
        public let titleLimit: Int
        public let bodyLimit: Int
        public let searchTextLimit: Int
        public let tokenLimit: Int

        public init(
            titleLimit: Int = 120,
            bodyLimit: Int = 500,
            searchTextLimit: Int = 64 * 1024,
            tokenLimit: Int = 80
        ) {
            self.titleLimit = max(1, titleLimit)
            self.bodyLimit = max(1, bodyLimit)
            self.searchTextLimit = max(1, searchTextLimit)
            self.tokenLimit = max(1, tokenLimit)
        }
    }

    private let configuration: Configuration
    private let calendar: Calendar

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        self.calendar = calendar
    }

    public func build(
        record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload?,
        tags: [String] = [],
        ocrText: String? = nil,
        ocrState: ClipboardOCRState? = nil,
        imagePayloadAvailable: Bool? = nil,
        ocrTextSource: ClipboardOCRTextSource = .none,
        contentRevision: Int64 = 1,
        updatedAt: Date = Date()
    ) -> ClipboardSearchDocument {
        let revision = Self.revision(for: record)
        let hasImagePayload = imagePayloadAvailable ?? (payload?.pngData != nil)
        let sourceTokens = tokens([
            record.sourceApp?.bundleIdentifier,
            record.sourceApp?.localizedName
        ])
        let typeTokens = tokens(typeTerms(for: record.kind) + record.formatSummary.types)
        let timeTokens = wholeTokens(timeTerms(for: record.lastCopiedAt))
        let tagTokens = wholeTokens(tags)

        if record.excluded || record.snapshotSkipped {
            let preview = ClipboardContentPreviewSnapshot(
                recordID: record.id,
                revision: revision,
                title: bounded("clipboard.capture.skipped", limit: configuration.titleLimit).text,
                body: bounded(record.summary, limit: configuration.bodyLimit).text,
                badge: record.kind.rawValue,
                contentKind: record.kind,
                imageState: imageState(for: record, hasImagePayload: hasImagePayload),
                ocrState: .notRequired,
                isTruncated: false
            )
            return ClipboardSearchDocument(
                recordID: record.id,
                revision: revision,
                contentRevision: contentRevision,
                updatedAt: updatedAt,
                preview: preview,
                contentText: nil,
                sourceTokens: sourceTokens,
                typeTokens: typeTokens,
                timeTokens: timeTokens,
                tagTokens: tagTokens,
                ocrState: .notRequired,
                payloadDerivationState: .redacted
            )
        }

        let normalizedText = primaryText(for: record, payload: payload)
        let boundedSearchText = bounded(normalizedText, limit: configuration.searchTextLimit)
        let title = titleText(for: record, payload: payload, primaryText: normalizedText)
        let body = bodyText(
            for: record,
            payload: payload,
            primaryText: normalizedText,
            hasImagePayload: hasImagePayload
        )
        let boundedTitle = bounded(title, limit: configuration.titleLimit)
        let boundedBody = bounded(body, limit: configuration.bodyLimit)
        let urlTokens = tokens(urlTerms(for: record, payload: payload))
        let fileTokens = tokens(fileTerms(for: record, payload: payload))
        let resolvedOCRState = ocrState ?? defaultOCRState(
            for: record,
            hasImagePayload: hasImagePayload
        )

        let preview = ClipboardContentPreviewSnapshot(
            recordID: record.id,
            revision: revision,
            title: boundedTitle.text,
            body: boundedBody.text,
            badge: record.kind.rawValue,
            contentKind: record.kind,
            imageState: imageState(for: record, hasImagePayload: hasImagePayload),
            ocrState: resolvedOCRState,
            isTruncated: boundedTitle.truncated || boundedBody.truncated
        )

        return ClipboardSearchDocument(
            recordID: record.id,
            revision: revision,
            contentRevision: contentRevision,
            updatedAt: updatedAt,
            preview: preview,
            contentText: boundedSearchText.text,
            richTextPlainText: record.kind == .richText ? boundedSearchText.text : nil,
            urlTokens: urlTokens,
            fileTokens: fileTokens,
            sourceTokens: sourceTokens,
            typeTokens: typeTokens,
            timeTokens: timeTokens,
            tagTokens: tagTokens,
            ocrText: normalized(ocrText),
            ocrState: resolvedOCRState,
            ocrTextSource: resolvedOCRState == .succeeded && normalized(ocrText) != nil ? ocrTextSource : .none,
            indexTruncated: boundedSearchText.truncated,
            payloadDerivationState: .available
        )
    }

    public static func revision(for record: ClipboardRecorderRecord) -> String {
        "v2:\(record.changeCount):\(record.signatureSHA256_12)"
    }

    private func primaryText(for record: ClipboardRecorderRecord, payload: ClipboardRecorderPayload?) -> String? {
        switch record.kind {
        case .text, .richText:
            return normalized(payload?.text) ?? normalized(record.summary)
        case .url:
            return normalized(payload?.urlString) ?? normalized(payload?.text) ?? normalized(record.summary)
        case .fileURL:
            return fileDisplayName(payload: payload) ?? normalized(record.summary)
        case .image:
            return nil
        case .mixed, .unknown:
            return normalized(payload?.text) ?? normalized(record.summary)
        }
    }

    private func titleText(
        for record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload?,
        primaryText: String?
    ) -> String {
        if let customTitle = normalized(record.customTitle) {
            return customTitle
        }
        return typeTitle(for: record.kind)
    }

    private func bodyText(
        for record: ClipboardRecorderRecord,
        payload: ClipboardRecorderPayload?,
        primaryText: String?,
        hasImagePayload: Bool
    ) -> String {
        switch record.kind {
        case .text, .richText:
            return primaryText ?? unavailablePreviewText
        case .url:
            return urlDisplaySummary(payload: payload) ?? primaryText ?? unavailablePreviewText
        case .fileURL:
            return fileDisplayName(payload: payload) ?? unavailablePreviewText
        case .image:
            return imageState(for: record, hasImagePayload: hasImagePayload) == "imagePayloadAvailable"
                ? "Image content"
                : unavailablePreviewText
        case .mixed, .unknown:
            return primaryText ?? typeTitle(for: record.kind)
        }
    }

    private var unavailablePreviewText: String {
        "Content not available"
    }

    private func typeTitle(for kind: ClipboardRecorderItemKind) -> String {
        switch kind {
        case .text:
            return "Text"
        case .richText:
            return "Rich text"
        case .image:
            return "Image"
        case .url:
            return "Link"
        case .fileURL:
            return "File"
        case .mixed:
            return "Mixed content"
        case .unknown:
            return "Clipboard item"
        }
    }

    private func defaultOCRState(for record: ClipboardRecorderRecord, hasImagePayload: Bool) -> ClipboardOCRState {
        guard record.kind == .image, hasImagePayload else {
            return .notRequired
        }
        return .pending
    }

    private func imageState(for record: ClipboardRecorderRecord, hasImagePayload: Bool) -> String? {
        guard record.kind == .image else {
            return nil
        }
        if hasImagePayload {
            return "imagePayloadAvailable"
        }
        return "imagePayloadUnavailable"
    }

    private func urlHost(payload: ClipboardRecorderPayload?) -> String? {
        guard let rawURL = payload?.urlString ?? payload?.text,
              let components = URLComponents(string: rawURL),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return normalized(host)
    }

    private func urlDisplaySummary(payload: ClipboardRecorderPayload?) -> String? {
        guard let rawURL = payload?.urlString ?? payload?.text,
              let components = URLComponents(string: rawURL) else {
            return nil
        }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        guard let host = components.host, !host.isEmpty else {
            return normalized(rawURL)
        }
        let displayPath = path.isEmpty || path == "/" ? "" : path
        return normalized("\(host)\(displayPath)")
    }

    private func urlTerms(for record: ClipboardRecorderRecord, payload: ClipboardRecorderPayload?) -> [String] {
        guard record.kind == .url else {
            return []
        }
        guard let rawURL = payload?.urlString ?? payload?.text,
              let components = URLComponents(string: rawURL) else {
            return tokens([payload?.urlString, payload?.text])
        }
        var terms: [String] = [
            components.scheme,
            components.host,
            components.path
        ].compactMap { $0 }
        terms += components.path.split(separator: "/").map(String.init)
        terms += (components.queryItems ?? []).flatMap { item in [item.name, item.value].compactMap { $0 } }
        return terms
    }

    private func fileDisplayName(payload: ClipboardRecorderPayload?) -> String? {
        guard let rawValue = payload?.urlString ?? payload?.text, !rawValue.isEmpty else {
            return nil
        }
        if let url = URL(string: rawValue), url.isFileURL {
            return normalized(url.lastPathComponent)
        }
        return normalized(URL(fileURLWithPath: rawValue).lastPathComponent)
    }

    private func fileTerms(for record: ClipboardRecorderRecord, payload: ClipboardRecorderPayload?) -> [String] {
        guard record.kind == .fileURL else {
            return []
        }
        guard let rawValue = payload?.urlString ?? payload?.text, !rawValue.isEmpty else {
            return []
        }
        let fileURL = URL(string: rawValue) ?? URL(fileURLWithPath: rawValue)
        let filename = fileURL.lastPathComponent
        let nameWithoutExtension = (filename as NSString).deletingPathExtension
        let pathExtension = fileURL.pathExtension
        return [filename, nameWithoutExtension, pathExtension].filter { !$0.isEmpty }
    }

    private func timeTerms(for date: Date) -> [String] {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return []
        }
        return [
            String(format: "%04d", year),
            String(format: "%04d-%02d", year, month),
            String(format: "%04d-%02d-%02d", year, month, day),
            String(format: "%02d-%02d", month, day),
            String(format: "%02d/%02d", month, day)
        ]
    }

    private func typeTerms(for kind: ClipboardRecorderItemKind) -> [String] {
        switch kind {
        case .text:
            return ["text", "txt", "plain text", "plaintext", "文本", "文字"]
        case .richText:
            return ["rich text", "rich_text", "rtf", "formatted text", "富文本"]
        case .image:
            return ["image", "img", "ima", "pic", "picture", "photo", "图片", "图", "照片"]
        case .url:
            return ["url", "link", "web", "website", "链接", "网址"]
        case .fileURL:
            return ["file", "file url", "file_url", "filename", "document", "doc", "文件"]
        case .mixed:
            return ["mixed", "multiple", "组合", "混合"]
        case .unknown:
            return ["unknown", "clipboard", "剪贴板"]
        }
    }

    private func tokens(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let normalizedValue = normalized(value) else {
                continue
            }
            for token in normalizedValue.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
                let text = String(token)
                guard !text.isEmpty, !seen.contains(text) else {
                    continue
                }
                seen.insert(text)
                result.append(text)
                if result.count >= configuration.tokenLimit {
                    return result
                }
            }
        }
        return result
    }

    private func wholeTokens(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let normalizedValue = normalized(value), !seen.contains(normalizedValue) else {
                continue
            }
            seen.insert(normalizedValue)
            result.append(normalizedValue)
            if result.count >= configuration.tokenLimit {
                return result
            }
        }
        return result
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let folded = value
            .replacingOccurrences(of: "\u{0000}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.isEmpty ? nil : folded
    }

    private func bounded(_ value: String?, limit: Int) -> (text: String, truncated: Bool) {
        guard let normalizedValue = normalized(value) else {
            return ("", false)
        }
        guard normalizedValue.count > limit else {
            return (normalizedValue, false)
        }
        return (String(normalizedValue.prefix(limit)), true)
    }
}
