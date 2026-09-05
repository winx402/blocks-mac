import Foundation

public struct ActionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains(where: { $0.isWhitespace })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Action ID must be a non-empty string without whitespace."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ActionRequestID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.contains(where: { $0.isWhitespace })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static func make() -> Self {
        Self(rawValue: "req_\(UUID().uuidString.lowercased())")!
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Request ID must be a non-empty string without whitespace."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BlocksAction: String, CaseIterable, Codable, Sendable {
    case screenshotCapture = "blocks.screenshot.capture"
    case screenshotHistoryQuery = "blocks.screenshot.history.query"
    case screenshotHistorySearch = "blocks.screenshot.history.search"
    case screenshotOCRStatus = "blocks.screenshot.ocr.status"
    case screenshotOCRRetry = "blocks.screenshot.ocr.retry"
    case screenshotHistoryExport = "blocks.screenshot.history.export"
    case screenshotScrollingStatus = "blocks.screenshot.scrolling.status"
    case screenshotScrollingFinish = "blocks.screenshot.scrolling.finish"
    case screenshotScrollingCancel = "blocks.screenshot.scrolling.cancel"
    case translationSourceManage = "blocks.translation.sources.manage"
    case pluginManage = "blocks.plugin.manage"

    public var actionID: ActionID {
        ActionID(rawValue: rawValue)!
    }
}

public struct ActionDescriptor: Codable, Sendable {
    public let actionID: ActionID
    public let protocolVersion: Int
    public let requestType: String
    public let resultType: String
    public let risk: String

    private enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case protocolVersion = "protocol_version"
        case requestType = "request_type"
        case resultType = "result_type"
        case risk
    }

    public init(
        actionID: ActionID,
        protocolVersion: Int,
        requestType: String,
        resultType: String,
        risk: String
    ) {
        self.actionID = actionID
        self.protocolVersion = protocolVersion
        self.requestType = requestType
        self.resultType = resultType
        self.risk = risk
    }
}

public enum ActionRegistry {
    public static let actions: [ActionDescriptor] = [
        ActionDescriptor(
            actionID: BlocksAction.screenshotCapture.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotCaptureActionInput>.currentProtocolVersion,
            requestType: "ScreenshotCaptureActionInput",
            resultType: "ScreenshotCaptureActionResult",
            risk: "sensitive_local_capture"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotHistoryQuery.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotHistoryQueryActionInput>.currentProtocolVersion,
            requestType: "ScreenshotHistoryQueryActionInput",
            resultType: "ScreenshotHistoryPageActionResult",
            risk: "sensitive_local_history_read"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotHistorySearch.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotHistorySearchActionInput>.currentProtocolVersion,
            requestType: "ScreenshotHistorySearchActionInput",
            resultType: "ScreenshotHistoryPageActionResult",
            risk: "sensitive_local_history_read"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotOCRStatus.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotOCRStatusActionInput>.currentProtocolVersion,
            requestType: "ScreenshotOCRStatusActionInput",
            resultType: "ScreenshotOCRStatusActionResult",
            risk: "sensitive_local_history_read"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotOCRRetry.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotOCRRetryActionInput>.currentProtocolVersion,
            requestType: "ScreenshotOCRRetryActionInput",
            resultType: "ScreenshotOCRRetryActionResult",
            risk: "sensitive_local_processing"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotHistoryExport.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotHistoryExportActionInput>.currentProtocolVersion,
            requestType: "ScreenshotHistoryExportActionInput",
            resultType: "ScreenshotHistoryExportActionResult",
            risk: "sensitive_local_file_write"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotScrollingStatus.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotScrollingStatusActionInput>.currentProtocolVersion,
            requestType: "ScreenshotScrollingStatusActionInput",
            resultType: "ScreenshotScrollingStatusActionResult",
            risk: "sensitive_local_capture_status"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotScrollingFinish.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotScrollingFinishActionInput>.currentProtocolVersion,
            requestType: "ScreenshotScrollingFinishActionInput",
            resultType: "ScreenshotScrollingFinishActionResult",
            risk: "sensitive_local_capture_control"
        ),
        ActionDescriptor(
            actionID: BlocksAction.screenshotScrollingCancel.actionID,
            protocolVersion: ActionBrokerRequest<ScreenshotScrollingCancelActionInput>.currentProtocolVersion,
            requestType: "ScreenshotScrollingCancelActionInput",
            resultType: "ScreenshotScrollingCancelActionResult",
            risk: "sensitive_local_capture_control"
        ),
        ActionDescriptor(
            actionID: BlocksAction.translationSourceManage.actionID,
            protocolVersion: ActionBrokerRequest<TranslationSourceManagementActionInput>.currentProtocolVersion,
            requestType: "TranslationSourceManagementActionInput",
            resultType: "TranslationSourceManagementActionResult",
            risk: "sensitive_local_plugin_management"
        ),
        ActionDescriptor(
            actionID: BlocksAction.pluginManage.actionID,
            protocolVersion: ActionBrokerRequest<PluginDevelopmentActionInput>.currentProtocolVersion,
            requestType: "PluginDevelopmentActionInput",
            resultType: "PluginDevelopmentActionResult",
            risk: "sensitive_local_plugin_management"
        )
    ]

    public static func contains(_ action: String) -> Bool {
        actions.contains { $0.actionID.rawValue == action }
    }
}
