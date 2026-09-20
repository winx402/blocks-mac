import Foundation

/// Fixed, content-free control messages for the locally signed source installer.
/// This is not a general CLI or Helper command channel.
public enum SourceUpgradeProtocol {
    public static let version = 1
    public static var isAvailable: Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        true
        #else
        false
        #endif
    }

    public struct Request: Codable, Sendable {
        public enum Operation: String, Codable, Sendable { case probe, prepare, commit, cancel }
        public let version: Int
        public let token: UUID
        public let operation: Operation
        public init(version: Int = SourceUpgradeProtocol.version, token: UUID, operation: Operation) {
            self.version = version; self.token = token; self.operation = operation
        }
    }

    public struct Response: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case ready, prepared, committed, cancelled, failed }
        public let version: Int
        public let token: UUID
        public let status: Status
        public let errorCode: String?
        public init(version: Int = SourceUpgradeProtocol.version, token: UUID, status: Status,
                    errorCode: String? = nil) {
            self.version = version; self.token = token; self.status = status; self.errorCode = errorCode
        }

        public func matches(_ request: Request) -> Bool {
            guard version == SourceUpgradeProtocol.version, request.version == version,
                  token == request.token else { return false }
            if status == .failed { return errorCode.map(SourceUpgradeProtocol.errorCodes.contains) ?? false }
            guard errorCode == nil else { return false }
            switch request.operation {
            case .probe: return status == .ready
            case .prepare: return status == .prepared
            case .commit: return status == .committed
            case .cancel: return status == .cancelled
            }
        }
    }

    /// Never transport exception descriptions, paths, or user content.
    public static let errorCodes: Set<String> = [
        "unsupported", "invalid_arguments", "unavailable", "invalid_request", "busy",
        "prepare_failed", "not_prepared", "timeout", "cancelled", "transport_failed",
        "unsupported_version", "invalid_state", "quitting", "preparation_failed", "disconnected",
    ]
}
