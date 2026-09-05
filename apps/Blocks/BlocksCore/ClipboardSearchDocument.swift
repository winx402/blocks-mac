import Foundation

public enum ClipboardOCRState: String, Codable, CaseIterable {
    case notRequired
    case pending
    case running
    case succeeded
    case failed
}

public enum ClipboardPayloadDerivationState: String, Codable, CaseIterable {
    case available
    case pendingIndex
    case redacted
    case degraded
}

public enum ClipboardSearchResultState: String, Codable, CaseIterable {
    case idle
    case results
    case empty
    case emptyIndexing
    case partialIndexing
    case failed
}

public enum ClipboardOCRTextSource: String, Codable, CaseIterable {
    case none
    case vision
    case userEdited
    case ignoredLateVision
}

public struct ClipboardSearchIndexActivity: Codable, Equatable {
    public let pendingIndexCount: Int
    public let pendingOCRCount: Int
    public let failedOCRCount: Int

    public init(pendingIndexCount: Int = 0, pendingOCRCount: Int = 0, failedOCRCount: Int = 0) {
        self.pendingIndexCount = max(0, pendingIndexCount)
        self.pendingOCRCount = max(0, pendingOCRCount)
        self.failedOCRCount = max(0, failedOCRCount)
    }

    public var hasPendingWork: Bool {
        pendingIndexCount > 0 || pendingOCRCount > 0
    }
}

public struct ClipboardSearchResultSet: Codable {
    public let query: String
    public let records: [ClipboardRecorderRecord]
    public let state: ClipboardSearchResultState
    public let indexActivity: ClipboardSearchIndexActivity

    public init(
        query: String,
        records: [ClipboardRecorderRecord],
        state: ClipboardSearchResultState,
        indexActivity: ClipboardSearchIndexActivity = ClipboardSearchIndexActivity()
    ) {
        self.query = query
        self.records = records
        self.state = state
        self.indexActivity = indexActivity
    }

    public static func idle(records: [ClipboardRecorderRecord]) -> ClipboardSearchResultSet {
        ClipboardSearchResultSet(query: "", records: records, state: .idle)
    }
}

public struct ClipboardContentPreviewSnapshot: Codable, Equatable {
    public let recordID: String
    public let revision: String
    public let title: String
    public let body: String
    public let badge: String
    public let contentKind: ClipboardRecorderItemKind
    public let imageState: String?
    public let ocrState: ClipboardOCRState
    public let isTruncated: Bool

    public init(
        recordID: String,
        revision: String,
        title: String,
        body: String,
        badge: String,
        contentKind: ClipboardRecorderItemKind,
        imageState: String? = nil,
        ocrState: ClipboardOCRState = .notRequired,
        isTruncated: Bool = false
    ) {
        self.recordID = recordID
        self.revision = revision
        self.title = title
        self.body = body
        self.badge = badge
        self.contentKind = contentKind
        self.imageState = imageState
        self.ocrState = ocrState
        self.isTruncated = isTruncated
    }
}

public struct ClipboardSearchDocument: Codable, Equatable {
    public let recordID: String
    public let revision: String
    public let contentRevision: Int64
    public let updatedAt: Date
    public let preview: ClipboardContentPreviewSnapshot
    public let contentText: String?
    public let richTextPlainText: String?
    public let urlTokens: [String]
    public let fileTokens: [String]
    public let sourceTokens: [String]
    public let typeTokens: [String]
    public let timeTokens: [String]
    public let tagTokens: [String]
    public let ocrText: String?
    public let ocrState: ClipboardOCRState
    public let ocrTextSource: ClipboardOCRTextSource
    public let ocrErrorCode: String?
    public let ocrAttemptCount: Int
    public let ocrLastAttemptAt: Date?
    public let ocrNextRetryAfter: Date?
    public let ocrUserEditedAt: Date?
    public let ocrLockedContentRevision: Int64?
    public let indexTruncated: Bool
    public let payloadDerivationState: ClipboardPayloadDerivationState

    public init(
        recordID: String,
        revision: String,
        contentRevision: Int64 = 1,
        updatedAt: Date,
        preview: ClipboardContentPreviewSnapshot,
        contentText: String?,
        richTextPlainText: String? = nil,
        urlTokens: [String] = [],
        fileTokens: [String] = [],
        sourceTokens: [String] = [],
        typeTokens: [String] = [],
        timeTokens: [String] = [],
        tagTokens: [String] = [],
        ocrText: String? = nil,
        ocrState: ClipboardOCRState,
        ocrTextSource: ClipboardOCRTextSource = .none,
        ocrErrorCode: String? = nil,
        ocrAttemptCount: Int = 0,
        ocrLastAttemptAt: Date? = nil,
        ocrNextRetryAfter: Date? = nil,
        ocrUserEditedAt: Date? = nil,
        ocrLockedContentRevision: Int64? = nil,
        indexTruncated: Bool = false,
        payloadDerivationState: ClipboardPayloadDerivationState
    ) {
        self.recordID = recordID
        self.revision = revision
        self.contentRevision = max(1, contentRevision)
        self.updatedAt = updatedAt
        self.preview = preview
        self.contentText = contentText
        self.richTextPlainText = richTextPlainText
        self.urlTokens = urlTokens
        self.fileTokens = fileTokens
        self.sourceTokens = sourceTokens
        self.typeTokens = typeTokens
        self.timeTokens = timeTokens
        self.tagTokens = tagTokens
        self.ocrText = ocrText
        self.ocrState = ocrState
        self.ocrTextSource = ocrTextSource
        self.ocrErrorCode = ocrErrorCode
        self.ocrAttemptCount = ocrAttemptCount
        self.ocrLastAttemptAt = ocrLastAttemptAt
        self.ocrNextRetryAfter = ocrNextRetryAfter
        self.ocrUserEditedAt = ocrUserEditedAt
        self.ocrLockedContentRevision = ocrLockedContentRevision
        self.indexTruncated = indexTruncated
        self.payloadDerivationState = payloadDerivationState
    }

    public var isSearchIndexable: Bool {
        payloadDerivationState != .redacted
    }

    public var ftsProjectionText: String {
        guard isSearchIndexable else {
            return ""
        }
        return [
            contentText,
            richTextPlainText,
            tokenText(urlTokens),
            tokenText(fileTokens),
            tokenText(sourceTokens),
            tokenText(typeTokens),
            tokenText(timeTokens),
            tokenText(tagTokens),
            ocrText
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    public func replacingOCR(
        text: String?,
        state: ClipboardOCRState,
        errorCode: String? = nil,
        attemptCount: Int? = nil,
        lastAttemptAt: Date? = nil,
        nextRetryAfter: Date? = nil,
        source: ClipboardOCRTextSource? = nil,
        userEditedAt: Date? = nil,
        lockedContentRevision: Int64? = nil,
        contentRevision: Int64? = nil,
        updatedAt: Date = Date()
    ) -> ClipboardSearchDocument {
        ClipboardSearchDocument(
            recordID: recordID,
            revision: revision,
            contentRevision: contentRevision ?? self.contentRevision,
            updatedAt: updatedAt,
            preview: ClipboardContentPreviewSnapshot(
                recordID: preview.recordID,
                revision: preview.revision,
                title: preview.title,
                body: preview.body,
                badge: preview.badge,
                contentKind: preview.contentKind,
                imageState: preview.imageState,
                ocrState: state,
                isTruncated: preview.isTruncated
            ),
            contentText: contentText,
            richTextPlainText: richTextPlainText,
            urlTokens: urlTokens,
            fileTokens: fileTokens,
            sourceTokens: sourceTokens,
            typeTokens: typeTokens,
            timeTokens: timeTokens,
            tagTokens: tagTokens,
            ocrText: text,
            ocrState: state,
            ocrTextSource: source ?? ocrTextSource,
            ocrErrorCode: errorCode,
            ocrAttemptCount: attemptCount ?? ocrAttemptCount,
            ocrLastAttemptAt: lastAttemptAt,
            ocrNextRetryAfter: nextRetryAfter,
            ocrUserEditedAt: userEditedAt ?? ocrUserEditedAt,
            ocrLockedContentRevision: lockedContentRevision ?? ocrLockedContentRevision,
            indexTruncated: indexTruncated,
            payloadDerivationState: payloadDerivationState
        )
    }

    public func replacingTags(
        tagTokens: [String],
        updatedAt: Date = Date()
    ) -> ClipboardSearchDocument {
        ClipboardSearchDocument(
            recordID: recordID,
            revision: revision,
            contentRevision: contentRevision,
            updatedAt: updatedAt,
            preview: preview,
            contentText: contentText,
            richTextPlainText: richTextPlainText,
            urlTokens: urlTokens,
            fileTokens: fileTokens,
            sourceTokens: sourceTokens,
            typeTokens: typeTokens,
            timeTokens: timeTokens,
            tagTokens: tagTokens,
            ocrText: ocrText,
            ocrState: ocrState,
            ocrTextSource: ocrTextSource,
            ocrErrorCode: ocrErrorCode,
            ocrAttemptCount: ocrAttemptCount,
            ocrLastAttemptAt: ocrLastAttemptAt,
            ocrNextRetryAfter: ocrNextRetryAfter,
            ocrUserEditedAt: ocrUserEditedAt,
            ocrLockedContentRevision: ocrLockedContentRevision,
            indexTruncated: indexTruncated,
            payloadDerivationState: payloadDerivationState
        )
    }

    private func tokenText(_ tokens: [String]) -> String? {
        let text = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
