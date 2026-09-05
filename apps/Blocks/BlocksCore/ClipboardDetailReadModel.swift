import Foundation

public enum ClipboardDetailEditableKind: String, Codable, CaseIterable {
    case plainText
    case url
    case richText
    case imageOCRText
}

public enum ClipboardDetailEditability: Equatable {
    case editable(ClipboardDetailEditableKind)
    case readOnly(reason: String)
}

public enum ClipboardDetailSaveStatus: String, Codable, CaseIterable {
    case view
    case readOnly
    case editClean
    case dirty
    case invalid
    case saving
    case saveSuccess
    case savedIndexPending
    case reindexFailed
    case saveFailed
    case recordUnavailable
    case dirtyNavigation
}

public enum ClipboardDetailSearchIndexState: String, Codable, CaseIterable {
    case completed
    case savedIndexPending
    case reindexFailed
}

public struct ClipboardBoundedPreview: Equatable {
    public let title: String
    public let body: String
    public let badge: String
    public let isTruncated: Bool

    public init(title: String, body: String, badge: String, isTruncated: Bool) {
        self.title = title
        self.body = body
        self.badge = badge
        self.isTruncated = isTruncated
    }
}

public enum ClipboardMetadataCategory: String, Codable, CaseIterable {
    case short
    case long
    case conditionalShort
}

public enum ClipboardMetadataCopyPurpose: String, Codable, CaseIterable {
    case none
    case detailFullValueRead
}

public struct ClipboardMetadataItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let titleKey: String?
    public let boundedValue: String
    public let fullValueAvailable: Bool
    public let category: ClipboardMetadataCategory
    public let copyPurpose: ClipboardMetadataCopyPurpose
    public let accessibilityLabel: String

    public init(
        id: String,
        title: String,
        titleKey: String? = nil,
        boundedValue: String,
        fullValueAvailable: Bool = false,
        category: ClipboardMetadataCategory = .short,
        copyPurpose: ClipboardMetadataCopyPurpose = .none,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.titleKey = titleKey
        self.boundedValue = boundedValue
        self.fullValueAvailable = fullValueAvailable
        self.category = category
        self.copyPurpose = copyPurpose
        self.accessibilityLabel = accessibilityLabel ?? "\(title): \(boundedValue)"
    }
}

public struct ClipboardMetadataSnapshot: Equatable {
    public let items: [ClipboardMetadataItem]

    public init(items: [ClipboardMetadataItem]) {
        self.items = items
    }
}

public struct ClipboardDetailReadModel: Identifiable, Equatable {
    public let id: String
    public let recordID: String
    public let contentRevision: Int64
    public let captureIdentityRevision: String
    public let kind: ClipboardRecorderItemKind
    public let title: String
    public let titleIsCustom: Bool
    public let boundedPreview: ClipboardBoundedPreview
    public let metadata: ClipboardMetadataSnapshot
    public let editability: ClipboardDetailEditability
    public let ocrState: ClipboardOCRState
    public let ocrTextSource: ClipboardOCRTextSource
    public let searchIndexState: ClipboardDetailSearchIndexState
    public let updatedAt: Date
    public let contentUpdatedAt: Date?

    public init(
        recordID: String,
        contentRevision: Int64,
        captureIdentityRevision: String,
        kind: ClipboardRecorderItemKind,
        title: String,
        titleIsCustom: Bool = false,
        boundedPreview: ClipboardBoundedPreview,
        metadata: ClipboardMetadataSnapshot,
        editability: ClipboardDetailEditability,
        ocrState: ClipboardOCRState,
        ocrTextSource: ClipboardOCRTextSource,
        searchIndexState: ClipboardDetailSearchIndexState = .completed,
        updatedAt: Date,
        contentUpdatedAt: Date?
    ) {
        self.id = recordID
        self.recordID = recordID
        self.contentRevision = max(1, contentRevision)
        self.captureIdentityRevision = captureIdentityRevision
        self.kind = kind
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.boundedPreview = boundedPreview
        self.metadata = metadata
        self.editability = editability
        self.ocrState = ocrState
        self.ocrTextSource = ocrTextSource
        self.searchIndexState = searchIndexState
        self.updatedAt = updatedAt
        self.contentUpdatedAt = contentUpdatedAt
    }
}
