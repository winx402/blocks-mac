import Foundation

public struct ActionError: Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ConfirmationRequest: Codable {
    public let level: String
    public let reason: String
    public let preview: [String: JSONValue]

    public init(level: String, reason: String, preview: [String: JSONValue]) {
        self.level = level
        self.reason = reason
        self.preview = preview
    }
}

public struct ActionEnvelope<Result: Codable>: Codable {
    public let ok: Bool
    public let action: String
    public let result: Result
    public let warnings: [String]
    public let auditID: String
    public let requiresConfirmation: ConfirmationRequest?
    public let error: ActionError?

    enum CodingKeys: String, CodingKey {
        case ok
        case action
        case result
        case warnings
        case auditID = "audit_id"
        case requiresConfirmation = "requires_confirmation"
        case error
    }

    public init(
        ok: Bool,
        action: String,
        result: Result,
        warnings: [String] = [],
        auditID: String? = nil,
        requiresConfirmation: ConfirmationRequest? = nil,
        error: ActionError? = nil
    ) {
        self.ok = ok
        self.action = action
        self.result = result
        self.warnings = warnings
        self.auditID = auditID ?? Audit.makeID(action: action)
        self.requiresConfirmation = requiresConfirmation
        self.error = error
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct ActionBrokerRequest<Payload: Codable>: Codable {
    public static var currentProtocolVersion: Int { 1 }

    public let protocolVersion: Int
    public let requestID: ActionRequestID
    public let actionID: ActionID
    public let payload: Payload

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case actionID = "action_id"
        case payload
    }

    public init(
        requestID: ActionRequestID,
        actionID: ActionID,
        payload: Payload
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.requestID = requestID
        self.actionID = actionID
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.currentProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported action broker protocol version."
            )
        }
        self.protocolVersion = protocolVersion
        self.requestID = try container.decode(ActionRequestID.self, forKey: .requestID)
        self.actionID = try container.decode(ActionID.self, forKey: .actionID)
        self.payload = try container.decode(Payload.self, forKey: .payload)
    }
}

extension ActionBrokerRequest: Equatable where Payload: Equatable {}
extension ActionBrokerRequest: Sendable where Payload: Sendable {}

public enum ActionBrokerErrorCategory: String, Codable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case availability
    case permission
    case timeout
    case transport
    case execution
    case cancelled
}

public struct ActionBrokerError: Codable, Equatable, Error, Sendable {
    public let category: ActionBrokerErrorCategory
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: [String: JSONValue]

    public init(
        category: ActionBrokerErrorCategory,
        code: String,
        message: String,
        retryable: Bool,
        details: [String: JSONValue] = [:]
    ) {
        self.category = category
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public enum ActionBrokerTerminalStatus: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

public struct ActionBrokerTerminalResponse<Result: Codable>: Codable {
    public static var currentProtocolVersion: Int { 1 }

    public let protocolVersion: Int
    public let requestID: ActionRequestID
    public let actionID: ActionID
    public let status: ActionBrokerTerminalStatus
    public let result: Result?
    public let error: ActionBrokerError?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case actionID = "action_id"
        case status
        case result
        case error
    }

    private init(
        requestID: ActionRequestID,
        actionID: ActionID,
        status: ActionBrokerTerminalStatus,
        result: Result?,
        error: ActionBrokerError?
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.requestID = requestID
        self.actionID = actionID
        self.status = status
        self.result = result
        self.error = error
    }

    public static func completed(
        requestID: ActionRequestID,
        actionID: ActionID,
        result: Result
    ) -> Self {
        Self(requestID: requestID, actionID: actionID, status: .completed, result: result, error: nil)
    }

    public static func cancelled(
        requestID: ActionRequestID,
        actionID: ActionID,
        code: String,
        message: String
    ) -> Self {
        Self(
            requestID: requestID,
            actionID: actionID,
            status: .cancelled,
            result: nil,
            error: ActionBrokerError(
                category: .cancelled,
                code: code,
                message: message,
                retryable: false
            )
        )
    }

    public static func failed(
        requestID: ActionRequestID,
        actionID: ActionID,
        error: ActionBrokerError
    ) -> Self {
        precondition(error.category != .cancelled, "Use cancelled(...) for cancellation terminals.")
        return Self(requestID: requestID, actionID: actionID, status: .failed, result: nil, error: error)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.currentProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported action broker protocol version."
            )
        }

        let status = try container.decode(ActionBrokerTerminalStatus.self, forKey: .status)
        let result = try container.decodeIfPresent(Result.self, forKey: .result)
        let error = try container.decodeIfPresent(ActionBrokerError.self, forKey: .error)
        let isValid: Bool
        switch status {
        case .completed:
            isValid = result != nil && error == nil
        case .cancelled:
            isValid = result == nil && error?.category == .cancelled
        case .failed:
            isValid = result == nil && error != nil && error?.category != .cancelled
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Terminal status, result, and error do not form a valid action outcome."
            )
        }

        self.protocolVersion = protocolVersion
        self.requestID = try container.decode(ActionRequestID.self, forKey: .requestID)
        self.actionID = try container.decode(ActionID.self, forKey: .actionID)
        self.status = status
        self.result = result
        self.error = error
    }
}

extension ActionBrokerTerminalResponse: Equatable where Result: Equatable {}
extension ActionBrokerTerminalResponse: Sendable where Result: Sendable {}

public enum Audit {
    public static func makeID(action: String, now: Date = Date()) -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        let raw = "\(action):\(timestamp):\(UUID().uuidString)"
        return "act_\(timestamp)_\(raw.fnv1a64Hex.prefix(12))"
    }
}

private extension String {
    var fnv1a64Hex: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
