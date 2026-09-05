import CryptoKit
import Foundation

public struct ClipboardDetailDraft: Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ClipboardDetailEditCommand: Equatable {
    public let recordID: String
    public let expectedContentRevision: Int64
    public let editableKind: ClipboardDetailEditableKind
    public let draft: ClipboardDetailDraft
    public let customTitle: String?
    public let updatesPayload: Bool
    public let updatesCustomTitle: Bool
    public let purpose: String
    public let now: Date

    public init(
        recordID: String,
        expectedContentRevision: Int64,
        editableKind: ClipboardDetailEditableKind,
        draft: ClipboardDetailDraft,
        customTitle: String? = nil,
        updatesPayload: Bool = true,
        updatesCustomTitle: Bool = false,
        purpose: String,
        now: Date = Date()
    ) {
        self.recordID = recordID
        self.expectedContentRevision = max(1, expectedContentRevision)
        self.editableKind = editableKind
        self.draft = draft
        self.customTitle = customTitle
        self.updatesPayload = updatesPayload
        self.updatesCustomTitle = updatesCustomTitle
        self.purpose = purpose
        self.now = now
    }
}

public enum ClipboardDetailPayloadSignature {
    public static func canonicalSHA256(for payload: ClipboardRecorderPayload) -> String? {
        var hasher = SHA256()
        hasher.update(data: Data("\(payload.kind.rawValue):".utf8))
        switch payload.kind {
        case .text, .url:
            guard let text = payload.urlString ?? payload.text else {
                return nil
            }
            hasher.update(data: Data(text.utf8))
        case .richText:
            guard let richText = payload.rtfData else {
                return nil
            }
            hasher.update(data: richText)
        case .image, .fileURL, .mixed, .unknown:
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClipboardDetailChangedFields: OptionSet, Codable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let payload = ClipboardDetailChangedFields(rawValue: 1 << 0)
    public static let summary = ClipboardDetailChangedFields(rawValue: 1 << 1)
    public static let searchDocument = ClipboardDetailChangedFields(rawValue: 1 << 2)
    public static let fts = ClipboardDetailChangedFields(rawValue: 1 << 3)
    public static let ocrText = ClipboardDetailChangedFields(rawValue: 1 << 4)
    public static let contentRevision = ClipboardDetailChangedFields(rawValue: 1 << 5)
    public static let customTitle = ClipboardDetailChangedFields(rawValue: 1 << 6)
    public static let signature = ClipboardDetailChangedFields(rawValue: 1 << 7)
    public static let conflictMerged = ClipboardDetailChangedFields(rawValue: 1 << 8)
}

public struct ClipboardDetailSaveResult: Equatable {
    public let recordID: String
    public let newContentRevision: Int64
    public let contentUpdatedAt: Date
    public let updatedPreview: ClipboardContentPreviewSnapshot
    public let updatedDetailReadModel: ClipboardDetailReadModel
    public let searchIndexState: ClipboardDetailSearchIndexState
    public let changedFields: ClipboardDetailChangedFields
    public let mutationCount: Int

    public init(
        recordID: String,
        newContentRevision: Int64,
        contentUpdatedAt: Date,
        updatedPreview: ClipboardContentPreviewSnapshot,
        updatedDetailReadModel: ClipboardDetailReadModel,
        searchIndexState: ClipboardDetailSearchIndexState = .completed,
        changedFields: ClipboardDetailChangedFields,
        mutationCount: Int
    ) {
        self.recordID = recordID
        self.newContentRevision = max(1, newContentRevision)
        self.contentUpdatedAt = contentUpdatedAt
        self.updatedPreview = updatedPreview
        self.updatedDetailReadModel = updatedDetailReadModel
        self.searchIndexState = searchIndexState
        self.changedFields = changedFields
        self.mutationCount = max(0, mutationCount)
    }
}

public enum ClipboardDetailSaveFailure: Error, Equatable {
    case recordNotFound
    case payloadMissing
    case notEditable
    case invalidURL
    case richTextFidelityFailed
    case ocrStateNotEditable
    case userEditedOCRConflict
    case revisionConflict
    case transactionFailed
    case reindexFailed
}
