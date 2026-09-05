import CoreGraphics
import Foundation

public enum ScreenshotCaptureActionKind: String, Codable, Equatable, Sendable {
    case smart
    case region
    case window
    case display
}

public enum ScreenshotCaptureInteraction: String, Codable, Equatable, Sendable {
    case interactive
    case noEditor = "no_editor"
}

public enum ScreenshotCaptureFormat: String, Codable, Equatable, Sendable {
    case png
    case jpeg
}

public enum ScreenshotCaptureWatermarkSelection: Equatable, Sendable {
    case `default`
    case none
    case presetID(UUID)
}

extension ScreenshotCaptureWatermarkSelection: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "default": self = .default
        case "none": self = .none
        default:
            guard let id = UUID(uuidString: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Watermark must be default, none, or a preset UUID."
                )
            }
            self = .presetID(id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .default: try container.encode("default")
        case .none: try container.encode("none")
        case let .presetID(id): try container.encode(id.uuidString.lowercased())
        }
    }
}

public enum ScreenshotCaptureActionDisplayScope: Codable, Equatable, Sendable {
    case current
    case all
    case displayID(UInt32)

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case current
        case all
        case displayID = "display_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .current:
            self = .current
        case .all:
            self = .all
        case .displayID:
            self = .displayID(try container.decode(UInt32.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current:
            try container.encode(Kind.current, forKey: .kind)
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case .displayID(let id):
            try container.encode(Kind.displayID, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

public enum ScreenshotCaptureActionValidationError: Error, Equatable, Sendable {
    case interactiveRequiresSmart
    case noEditorRequiresExplicitKind
    case displayScopeRequiresDisplayKind
    case outputPathIsEmpty

    public var code: String {
        switch self {
        case .interactiveRequiresSmart:
            "interactive_requires_smart"
        case .noEditorRequiresExplicitKind:
            "no_editor_requires_explicit_kind"
        case .displayScopeRequiresDisplayKind:
            "display_scope_requires_display"
        case .outputPathIsEmpty:
            "output_path_is_empty"
        }
    }

    public var message: String {
        switch self {
        case .interactiveRequiresSmart:
            "Interactive capture only accepts smart kind."
        case .noEditorRequiresExplicitKind:
            "No-editor capture requires region, window, or display kind."
        case .displayScopeRequiresDisplayKind:
            "Display scope is only valid for display capture."
        case .outputPathIsEmpty:
            "Output path must not be empty."
        }
    }
}

public struct ScreenshotCaptureActionInput: Codable, Equatable, Sendable {
    public let kind: ScreenshotCaptureActionKind
    public let displayScope: ScreenshotCaptureActionDisplayScope?
    public let interaction: ScreenshotCaptureInteraction
    public let copy: Bool
    public let outputPath: String?
    public let format: ScreenshotCaptureFormat
    public let watermark: ScreenshotCaptureWatermarkSelection

    private enum CodingKeys: String, CodingKey {
        case kind
        case displayScope = "display_scope"
        case interaction
        case copy
        case outputPath = "output_path"
        case format
        case watermark
    }

    public init(
        kind: ScreenshotCaptureActionKind,
        interaction: ScreenshotCaptureInteraction,
        displayScope: ScreenshotCaptureActionDisplayScope? = nil,
        copy: Bool? = nil,
        outputPath: String? = nil,
        format: ScreenshotCaptureFormat = .png,
        watermark: ScreenshotCaptureWatermarkSelection = .default
    ) throws {
        if interaction == .interactive, kind != .smart {
            throw ScreenshotCaptureActionValidationError.interactiveRequiresSmart
        }
        if interaction == .noEditor, kind == .smart {
            throw ScreenshotCaptureActionValidationError.noEditorRequiresExplicitKind
        }
        if kind != .display, displayScope != nil {
            throw ScreenshotCaptureActionValidationError.displayScopeRequiresDisplayKind
        }
        if let outputPath, outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ScreenshotCaptureActionValidationError.outputPathIsEmpty
        }

        self.kind = kind
        self.displayScope = kind == .display ? (displayScope ?? .current) : nil
        self.interaction = interaction
        self.outputPath = outputPath
        self.copy = copy ?? (outputPath == nil)
        self.format = format
        self.watermark = watermark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ScreenshotCaptureActionKind.self, forKey: .kind),
            interaction: container.decode(ScreenshotCaptureInteraction.self, forKey: .interaction),
            displayScope: container.decodeIfPresent(ScreenshotCaptureActionDisplayScope.self, forKey: .displayScope),
            copy: container.decodeIfPresent(Bool.self, forKey: .copy),
            outputPath: container.decodeIfPresent(String.self, forKey: .outputPath),
            format: container.decodeIfPresent(ScreenshotCaptureFormat.self, forKey: .format) ?? .png,
            watermark: container.decodeIfPresent(
                ScreenshotCaptureWatermarkSelection.self,
                forKey: .watermark
            ) ?? .default
        )
    }
}

public enum ScreenshotCaptureActionResolvedKind: String, Codable, Equatable, Sendable {
    case region
    case window
    case display
}

public struct ScreenshotPixelDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum ScreenshotCaptureActionColorSpace: String, Codable, Equatable, Sendable {
    case sRGB
}

public enum ScreenshotActionSinkStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case notRequested = "not_requested"
}

public struct ScreenshotCaptureActionResult: Codable, Equatable, Sendable {
    public let captureID: String
    public let kind: ScreenshotCaptureActionResolvedKind
    public let displayScope: ScreenshotCaptureActionDisplayScope?
    public let pixelSize: ScreenshotPixelDimensions
    public let colorSpace: ScreenshotCaptureActionColorSpace
    public let pasteboard: ScreenshotActionSinkStatus
    public let history: ScreenshotActionSinkStatus
    public let output: ScreenshotActionSinkStatus

    private enum CodingKeys: String, CodingKey {
        case captureID = "capture_id"
        case kind
        case displayScope = "display_scope"
        case pixelSize = "pixel_size"
        case colorSpace = "color_space"
        case pasteboard
        case history
        case output
    }

    public init(
        captureID: String,
        kind: ScreenshotCaptureActionResolvedKind,
        displayScope: ScreenshotCaptureActionDisplayScope?,
        pixelSize: ScreenshotPixelDimensions,
        colorSpace: ScreenshotCaptureActionColorSpace = .sRGB,
        pasteboard: ScreenshotActionSinkStatus,
        history: ScreenshotActionSinkStatus,
        output: ScreenshotActionSinkStatus
    ) {
        self.captureID = captureID
        self.kind = kind
        self.displayScope = displayScope
        self.pixelSize = pixelSize
        self.colorSpace = colorSpace
        self.pasteboard = pasteboard
        self.history = history
        self.output = output
    }
}

public enum ScreenshotHistoryActionValidationError: Error, Equatable, Sendable {
    case invalidCursor
    case invalidLimit
    case invalidQuery
    case recordIDsRequired
    case invalidRecordID

    public var code: String {
        switch self {
        case .invalidCursor:
            "invalid_cursor"
        case .invalidLimit:
            "invalid_limit"
        case .invalidQuery:
            "invalid_query"
        case .recordIDsRequired:
            "record_ids_required"
        case .invalidRecordID:
            "invalid_record_id"
        }
    }

    public var message: String {
        switch self {
        case .invalidCursor:
            "Cursor must be a non-empty opaque value."
        case .invalidLimit:
            "Limit must be between 1 and 100."
        case .invalidQuery:
            "Search query must not be empty."
        case .recordIDsRequired:
            "At least one record ID is required."
        case .invalidRecordID:
            "Record ID must not be empty."
        }
    }
}

public struct ScreenshotHistoryQueryActionInput: Codable, Equatable, Sendable {
    public static let defaultLimit = 24
    public static let maximumLimit = 100

    public let cursor: String?
    public let limit: Int
    public let includeOCR: Bool

    private enum CodingKeys: String, CodingKey {
        case cursor
        case limit
        case includeOCR = "include_ocr"
    }

    public init(
        cursor: String? = nil,
        limit: Int = Self.defaultLimit,
        includeOCR: Bool = false
    ) throws {
        if let cursor, cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ScreenshotHistoryActionValidationError.invalidCursor
        }
        guard (1...Self.maximumLimit).contains(limit) else {
            throw ScreenshotHistoryActionValidationError.invalidLimit
        }
        self.cursor = cursor
        self.limit = limit
        self.includeOCR = includeOCR
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cursor: container.decodeIfPresent(String.self, forKey: .cursor),
            limit: container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit,
            includeOCR: container.decodeIfPresent(Bool.self, forKey: .includeOCR) ?? false
        )
    }
}

public struct ScreenshotHistorySearchActionInput: Codable, Equatable, Sendable {
    public let query: String
    public let cursor: String?
    public let limit: Int
    public let includeOCR: Bool

    private enum CodingKeys: String, CodingKey {
        case query
        case cursor
        case limit
        case includeOCR = "include_ocr"
    }

    public init(
        query: String,
        cursor: String? = nil,
        limit: Int = ScreenshotHistoryQueryActionInput.defaultLimit,
        includeOCR: Bool = false
    ) throws {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw ScreenshotHistoryActionValidationError.invalidQuery
        }
        let page = try ScreenshotHistoryQueryActionInput(
            cursor: cursor,
            limit: limit,
            includeOCR: includeOCR
        )
        self.query = normalizedQuery
        self.cursor = page.cursor
        self.limit = page.limit
        self.includeOCR = page.includeOCR
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            query: container.decode(String.self, forKey: .query),
            cursor: container.decodeIfPresent(String.self, forKey: .cursor),
            limit: container.decodeIfPresent(Int.self, forKey: .limit)
                ?? ScreenshotHistoryQueryActionInput.defaultLimit,
            includeOCR: container.decodeIfPresent(Bool.self, forKey: .includeOCR) ?? false
        )
    }
}

public enum ScreenshotOCRActionState: String, Codable, Equatable, Sendable {
    case notRequired = "not_required"
    case pending
    case running
    case succeeded
    case failed
}

public struct ScreenshotHistoryActionItem: Codable, Equatable, Sendable {
    public let recordID: String
    public let createdAt: Date
    public let lastCopiedAt: Date
    public let pixelSize: ScreenshotPixelDimensions
    public let isFavorite: Bool
    public let tags: [String]
    public let title: String?
    public let ocrState: ScreenshotOCRActionState
    public let contentRevision: Int64
    public let ocrSummary: String
    public let ocr: String?

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case createdAt = "created_at"
        case lastCopiedAt = "last_copied_at"
        case pixelSize = "pixel_size"
        case isFavorite = "is_favorite"
        case tags
        case title
        case ocrState = "ocr_state"
        case contentRevision = "content_revision"
        case ocrSummary = "ocr_summary"
        case ocr
    }

    public init(
        recordID: String,
        createdAt: Date,
        lastCopiedAt: Date,
        pixelSize: ScreenshotPixelDimensions,
        isFavorite: Bool,
        tags: [String],
        title: String?,
        ocrState: ScreenshotOCRActionState,
        contentRevision: Int64,
        ocrSummary: String,
        ocr: String?
    ) {
        self.recordID = recordID
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.pixelSize = pixelSize
        self.isFavorite = isFavorite
        self.tags = tags
        self.title = title
        self.ocrState = ocrState
        self.contentRevision = contentRevision
        self.ocrSummary = ocrSummary
        self.ocr = ocr
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastCopiedAt, forKey: .lastCopiedAt)
        try container.encode(pixelSize, forKey: .pixelSize)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(tags, forKey: .tags)
        try container.encode(title, forKey: .title)
        try container.encode(ocrState, forKey: .ocrState)
        try container.encode(contentRevision, forKey: .contentRevision)
        try container.encode(ocrSummary, forKey: .ocrSummary)
        try container.encodeIfPresent(ocr, forKey: .ocr)
    }
}

public struct ScreenshotHistoryPageActionResult: Codable, Equatable, Sendable {
    public let items: [ScreenshotHistoryActionItem]
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }

    public init(items: [ScreenshotHistoryActionItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct ScreenshotOCRStatusActionInput: Codable, Equatable, Sendable {
    public let recordIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case recordIDs = "record_ids"
    }

    public init(recordIDs: [String]) throws {
        guard !recordIDs.isEmpty else {
            throw ScreenshotHistoryActionValidationError.recordIDsRequired
        }
        guard recordIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ScreenshotHistoryActionValidationError.invalidRecordID
        }
        self.recordIDs = recordIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recordIDs: container.decode([String].self, forKey: .recordIDs))
    }
}

public struct ScreenshotOCRStatusActionItem: Codable, Equatable, Sendable {
    public let recordID: String
    public let ocrState: ScreenshotOCRActionState
    public let captureIdentityRevision: String
    public let contentRevision: Int64

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case ocrState = "ocr_state"
        case captureIdentityRevision = "capture_identity_revision"
        case contentRevision = "content_revision"
    }

    public init(
        recordID: String,
        ocrState: ScreenshotOCRActionState,
        captureIdentityRevision: String,
        contentRevision: Int64
    ) {
        self.recordID = recordID
        self.ocrState = ocrState
        self.captureIdentityRevision = captureIdentityRevision
        self.contentRevision = contentRevision
    }
}

public struct ScreenshotOCRStatusActionResult: Codable, Equatable, Sendable {
    public let items: [ScreenshotOCRStatusActionItem]

    public init(items: [ScreenshotOCRStatusActionItem]) {
        self.items = items
    }
}

public struct ScreenshotOCRRetryActionInput: Codable, Equatable, Sendable {
    public let recordID: String

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
    }

    public init(recordID: String) throws {
        guard !recordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotHistoryActionValidationError.invalidRecordID
        }
        self.recordID = recordID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recordID: container.decode(String.self, forKey: .recordID))
    }
}

public struct ScreenshotOCRRetryActionResult: Codable, Equatable, Sendable {
    public let ocrState: ScreenshotOCRActionState
    public let recordID: String
    public let captureIdentityRevision: String
    public let contentRevision: Int64

    private enum CodingKeys: String, CodingKey {
        case ocrState = "ocr_state"
        case recordID = "record_id"
        case captureIdentityRevision = "capture_identity_revision"
        case contentRevision = "content_revision"
    }

    public init(
        recordID: String,
        captureIdentityRevision: String,
        contentRevision: Int64
    ) {
        self.ocrState = .pending
        self.recordID = recordID
        self.captureIdentityRevision = captureIdentityRevision
        self.contentRevision = contentRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ocrState = try container.decode(ScreenshotOCRActionState.self, forKey: .ocrState)
        guard ocrState == .pending else {
            throw DecodingError.dataCorruptedError(
                forKey: .ocrState,
                in: container,
                debugDescription: "OCR retry result must be pending."
            )
        }
        self.init(
            recordID: try container.decode(String.self, forKey: .recordID),
            captureIdentityRevision: try container.decode(String.self, forKey: .captureIdentityRevision),
            contentRevision: try container.decode(Int64.self, forKey: .contentRevision)
        )
    }
}

public struct ScreenshotHistoryExportActionInput: Codable, Equatable, Sendable {
    public let recordID: String
    public let format: ScreenshotCaptureFormat

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case format
    }

    public init(recordID: String, format: ScreenshotCaptureFormat = .png) throws {
        guard !recordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotHistoryActionValidationError.invalidRecordID
        }
        self.recordID = recordID
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordID: container.decode(String.self, forKey: .recordID),
            format: container.decodeIfPresent(ScreenshotCaptureFormat.self, forKey: .format) ?? .png
        )
    }
}

public struct ScreenshotHistoryExportActionResult: Codable, Equatable, Sendable {
    public let bytesWritten: Int64
    public let format: ScreenshotCaptureFormat

    private enum CodingKeys: String, CodingKey {
        case bytesWritten = "bytes_written"
        case format
    }

    public init(bytesWritten: Int64, format: ScreenshotCaptureFormat) {
        self.bytesWritten = bytesWritten
        self.format = format
    }
}

public enum ScreenshotScrollingSessionState: String, Codable, Equatable, Sendable {
    case selecting
    case capturing
    case recovering
    case paused
    case possibleEnd = "possible_end"
    case finishing
    case completed
    case cancelled
    case failed
}

public enum ScreenshotScrollingRequiredPermission: String, Codable, Equatable, Sendable {
    case screenRecording = "screen_recording"
    case inputMonitoring = "input_monitoring"
    case screenRecordingAndInputMonitoring = "screen_recording_and_input_monitoring"
}

public enum ScreenshotScrollingActionValidationError: Error, Equatable, Sendable {
    case sessionIDRequired
    case cancellationConfirmationRequired

    public var code: String {
        switch self {
        case .sessionIDRequired:
            "session_id_required"
        case .cancellationConfirmationRequired:
            "cancellation_confirmation_required"
        }
    }

    public var message: String {
        switch self {
        case .sessionIDRequired:
            "A scrolling screenshot session ID is required."
        case .cancellationConfirmationRequired:
            "Scrolling screenshot cancellation requires confirm=true."
        }
    }
}

public struct ScreenshotScrollingStatusActionInput: Codable, Equatable, Sendable {
    public init() {}
}

public struct ScreenshotScrollingStatusActionResult: Codable, Equatable, Sendable {
    public let sessionID: String?
    public let state: ScreenshotScrollingSessionState?
    public let size: ScreenshotPixelDimensions?
    public let warning: String?
    public let permission: ScreenshotScrollingRequiredPermission?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
        case size
        case warning
        case permission
    }

    public init(
        sessionID: String? = nil,
        state: ScreenshotScrollingSessionState? = nil,
        size: ScreenshotPixelDimensions? = nil,
        warning: String? = nil,
        permission: ScreenshotScrollingRequiredPermission? = nil
    ) {
        self.sessionID = sessionID
        self.state = state
        self.size = size
        self.warning = warning
        self.permission = permission
    }
}

public struct ScreenshotScrollingFinishActionInput: Codable, Equatable, Sendable {
    public let sessionID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }

    public init(sessionID: String) throws {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotScrollingActionValidationError.sessionIDRequired
        }
        self.sessionID = sessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionID: container.decode(String.self, forKey: .sessionID))
    }
}

public struct ScreenshotScrollingFinishActionResult: Codable, Equatable, Sendable {
    public let sessionID: String
    public let finishRequested: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case finishRequested = "finish_requested"
    }

    public init(sessionID: String, finishRequested: Bool) {
        self.sessionID = sessionID
        self.finishRequested = finishRequested
    }
}

public struct ScreenshotScrollingCancelActionInput: Codable, Equatable, Sendable {
    public let sessionID: String
    public let confirm: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case confirm
    }

    public init(sessionID: String, confirm: Bool) throws {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotScrollingActionValidationError.sessionIDRequired
        }
        guard confirm else {
            throw ScreenshotScrollingActionValidationError.cancellationConfirmationRequired
        }
        self.sessionID = sessionID
        self.confirm = true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            confirm: container.decode(Bool.self, forKey: .confirm)
        )
    }
}

public struct ScreenshotScrollingCancelActionResult: Codable, Equatable, Sendable {
    public let sessionID: String
    public let cancelled: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cancelled
    }

    public init(sessionID: String, cancelled: Bool) {
        self.sessionID = sessionID
        self.cancelled = cancelled
    }
}

public enum ScreenRecordingPermission {
    public static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }
}
