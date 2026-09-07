import Foundation

public enum BlocksActionBrokerXPC {
    public static let launchAgentLabel =
        BlocksRuntimeIdentity.actionBrokerLaunchAgentLabel
    public static let machServiceName =
        BlocksRuntimeIdentity.actionBrokerMachServiceName
    public static let launchAgentPlistName =
        BlocksRuntimeIdentity.actionBrokerLaunchAgentPlistName
    public static let appBundleIdentifier =
        BlocksRuntimeIdentity.applicationBundleIdentifier
}

@objc public protocol BlocksActionBrokerHostXPCProtocol {
    /// Optional so older running Brokers fail closed without an unchecked
    /// shutdown message. No request data is sent until the peer is verified.
    @objc optional func probeUpdateLifecycle(withReply reply: @escaping () -> Void)
    @objc optional func prepareForApplicationUpdate(
        _ token: String, withReply reply: @escaping (Bool, String?) -> Void
    )
    @objc optional func resumeAfterCancelledApplicationUpdate(
        _ token: String, withReply reply: @escaping (Bool, String?) -> Void
    )
    func registerHost(
        _ endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}

public enum ActionBrokerUpdateError: Error, LocalizedError {
    case unsupportedPeer
    case untrustedPeer
    case busy
    case invalidRecoveryState
    case requiresApproval
    case serviceDidNotStop

    public var errorDescription: String? {
        switch self {
        case .unsupportedPeer:
            return "The running Action Broker does not support safe update preparation. Finish its work and quit or upgrade the old Broker, then retry."
        case .untrustedPeer: return "The Action Broker peer could not be authenticated. No service was stopped."
        case .busy: return "Action Broker still has active requests. Wait for them to finish and retry."
        case .invalidRecoveryState: return "Action Broker update recovery state is invalid; the enabled preference was not discarded."
        case .requiresApproval: return "Action Broker requires approval in System Settings > Login Items. The enabled preference has been retained."
        case .serviceDidNotStop: return "Action Broker service shutdown could not be confirmed. The application will not be replaced."
        }
    }
}

/// One gate is shared by *all* Broker connections. A request retains its lease
/// through the terminal XPC reply, including time spent waiting for AppHost.
public final class ActionBrokerUpdateAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let operations = ApplicationOperationAdmissionGate(name: "Action Broker requests")
    private var preparedToken: String?
    private var cancelledTokens: [String] = []

    public init() {}
    public func begin() -> ApplicationOperationAdmissionGate.Lease? { lock.withLock { operations.begin() } }

    public func prepare(token: String) throws {
        try lock.withLock {
            guard UUID(uuidString: token) != nil, !cancelledTokens.contains(token) else {
                throw ActionBrokerUpdateError.invalidRecoveryState
            }
            if let preparedToken {
                guard preparedToken == token else { throw ActionBrokerUpdateError.busy }
                return
            }
            do { try operations.pauseIfIdle() } catch { throw ActionBrokerUpdateError.busy }
            preparedToken = token
        }
    }

    public func resume(token: String) throws {
        try lock.withLock {
            guard UUID(uuidString: token) != nil else { throw ActionBrokerUpdateError.invalidRecoveryState }
            if let preparedToken, preparedToken != token { throw ActionBrokerUpdateError.busy }
            preparedToken = nil
            if !cancelledTokens.contains(token) { cancelledTokens.append(token) }
            if cancelledTokens.count > 128 { cancelledTokens.removeFirst(cancelledTokens.count - 128) }
            operations.resume()
        }
    }
}

public struct ActionBrokerUpdateRecoveryTicket: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let serviceLabel: String
    public let token: String
    public var processID: Int32?

    public init(token: String = UUID().uuidString, processID: Int32? = nil) {
        schemaVersion = 1
        serviceLabel = BlocksActionBrokerXPC.launchAgentLabel
        self.token = token
        self.processID = processID
    }
}

/// Contains only a service identity and random recovery token, never a secret.
/// The production path is in the app's existing, namespaced storage directory;
/// tests can use the in-memory form or a synthetic directory.
public final class ActionBrokerUpdateRecoveryJournal {
    private let url: URL?
    private var memoryTicket: ActionBrokerUpdateRecoveryTicket?
    public init(url: URL? = nil) { self.url = url }

    public func load() throws -> ActionBrokerUpdateRecoveryTicket? {
        guard let url else { return memoryTicket }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, let size = attributes.fileSize, size <= 4096 else {
            throw ActionBrokerUpdateError.invalidRecoveryState
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 4096,
              let ticket = try? JSONDecoder().decode(ActionBrokerUpdateRecoveryTicket.self, from: data),
              ticket.schemaVersion == 1, ticket.serviceLabel == BlocksActionBrokerXPC.launchAgentLabel,
              UUID(uuidString: ticket.token) != nil,
              ticket.processID.map({ $0 > 0 }) ?? true else {
            throw ActionBrokerUpdateError.invalidRecoveryState
        }
        return ticket
    }

    public func save(_ ticket: ActionBrokerUpdateRecoveryTicket) throws {
        guard ticket.schemaVersion == 1, ticket.serviceLabel == BlocksActionBrokerXPC.launchAgentLabel,
              UUID(uuidString: ticket.token) != nil, ticket.processID.map({ $0 > 0 }) ?? true else {
            throw ActionBrokerUpdateError.invalidRecoveryState
        }
        if let existing = try load(), existing.token != ticket.token { throw ActionBrokerUpdateError.invalidRecoveryState }
        guard let url else { memoryTicket = ticket; return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(ticket).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        guard let url else { memoryTicket = nil; return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@objc public protocol BlocksActionBrokerClientXPCProtocol {
    /// A non-sensitive handshake used before local-development clients send
    /// request data. Optional preserves compatibility with older signed peers.
    @objc optional func probe(withReply reply: @escaping () -> Void)

    func submit(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    )

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    )
}

@objc public protocol BlocksActionHostXPCProtocol {
    func execute(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    )

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    )
}
