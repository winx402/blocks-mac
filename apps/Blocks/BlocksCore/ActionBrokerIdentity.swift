import Foundation
import OSLog
import Security

/// Only fixed categories and numeric status codes are safe to log. In
/// particular, do not attach Security CFError userInfo or signing dictionaries.
public struct ActionBrokerIdentityFailure: Error, Equatable, Hashable, Sendable {
    public enum Subject: String, Hashable, Sendable { case own, peer, policy }
    public enum Stage: String, Hashable, Sendable {
        case user, process, copySelf, copyGuest, requirement, validity, copyStatic, signingInformation, team, identifier
    }
    public enum Reason: String, Hashable, Sendable {
        case securityError, missingValue, userMismatch, invalidProcess, missingTeam, invalidTeam, teamMismatch, identifierNotAllowed
        case capacityExceeded, cancelled
    }

    public let subject: Subject
    public let stage: Stage
    public let reason: Reason
    public let osStatus: OSStatus?

    public init(subject: Subject, stage: Stage, reason: Reason, osStatus: OSStatus? = nil) {
        self.subject = subject
        self.stage = stage
        self.reason = reason
        self.osStatus = osStatus
    }
}

public struct ActionBrokerSigningIdentity: Equatable, Sendable {
    public let teamID: String
    public let identifier: String

    public init(teamID: String, identifier: String) {
        self.teamID = teamID
        self.identifier = identifier
    }
}

public struct ActionBrokerPeerAuthorization: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case appHost, client }
    public let role: Role
    /// This narrower, role-specific requirement must be installed on the
    /// actual NSXPCConnection before resume. PID classification alone is not
    /// authority to export either protocol.
    public let connectionRequirement: String
}

public enum ActionBrokerSignatureValidation: Equatable, Sendable {
    case valid
    case requirementFailure(OSStatus)
    case invalid(OSStatus)
}

/// Generic handles let tests exercise every Security stage without constructing
/// SecCode objects, registering a service, or opening a real XPC connection.
public struct ActionBrokerSigningOperations<Code, StaticCode> {
    public let copySelf: () -> (OSStatus, Code?)
    public let copyGuest: (Int32) -> (OSStatus, Code?)
    public let checkValidity: (Code, SecCSFlags, String?) -> ActionBrokerSignatureValidation
    public let copyStatic: (Code) -> (OSStatus, StaticCode?)
    public let signingInformation: (StaticCode) -> (OSStatus, ActionBrokerSigningIdentity?)

    public init(
        copySelf: @escaping () -> (OSStatus, Code?),
        copyGuest: @escaping (Int32) -> (OSStatus, Code?),
        checkValidity: @escaping (Code, SecCSFlags, String?) -> ActionBrokerSignatureValidation,
        copyStatic: @escaping (Code) -> (OSStatus, StaticCode?),
        signingInformation: @escaping (StaticCode) -> (OSStatus, ActionBrokerSigningIdentity?)
    ) {
        self.copySelf = copySelf
        self.copyGuest = copyGuest
        self.checkValidity = checkValidity
        self.copyStatic = copyStatic
        self.signingInformation = signingInformation
    }
}

extension ActionBrokerSigningOperations where Code == SecCode, StaticCode == SecStaticCode {
    public static var system: Self {
        Self(copySelf: {
            var code: SecCode?
            let status = ActionBrokerSecurityTelemetry.measure(stage: .copySelf) { SecCodeCopySelf([], &code) }
            return (status, code)
        }, copyGuest: { processID in
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: NSNumber(value: processID)] as CFDictionary
            let status = ActionBrokerSecurityTelemetry.measure(stage: .copyGuest) {
                SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
            }
            return (status, code)
        }, checkValidity: { code, flags, requirementString in
            var requirement: SecRequirement?
            if let requirementString {
                let status = ActionBrokerSecurityTelemetry.measure(stage: .requirement) {
                    SecRequirementCreateWithString(requirementString as CFString, [], &requirement)
                }
                guard status == errSecSuccess, requirement != nil else {
                    return .requirementFailure(status)
                }
            }
            let status = ActionBrokerSecurityTelemetry.measure(stage: .validity) { SecCodeCheckValidity(code, flags, requirement) }
            return status == errSecSuccess ? .valid : .invalid(status)
        }, copyStatic: { code in
            var staticCode: SecStaticCode?
            let status = ActionBrokerSecurityTelemetry.measure(stage: .copyStatic) { SecCodeCopyStaticCode(code, [], &staticCode) }
            return (status, staticCode)
        }, signingInformation: { code in
            var information: CFDictionary?
            let status = ActionBrokerSecurityTelemetry.measure(stage: .signingInformation) {
                SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            }
            guard status == errSecSuccess, let values = information as? [CFString: Any] else {
                return (status, nil)
            }
            return (status, ActionBrokerSigningIdentity(
                teamID: values[kSecCodeInfoTeamIdentifier] as? String ?? "",
                identifier: values[kSecCodeInfoIdentifier] as? String ?? ""
            ))
        })
    }
}

/// Official-build policy only. LocalDevelopment keeps its existing registry
/// policy and must not invoke this validator to trust empty-Team signatures.
public final class ActionBrokerIdentityValidator<Code, StaticCode> {
    public static var expectedBrokerIdentifier: String { BlocksRuntimeIdentity.identifierPrefix + ".action-broker" }
    public static var ownRequirement: String {
        "anchor apple generic and identifier \"\(expectedBrokerIdentifier)\""
    }

    public let ownIdentity: Result<ActionBrokerSigningIdentity, ActionBrokerIdentityFailure>
    private let operations: ActionBrokerSigningOperations<Code, StaticCode>

    /// Eagerly validates the running self before the caller starts its listener.
    /// Snapshot both success and failure: a replaced executable must neither
    /// alter our trust anchor nor cause a later disk-based self lookup.
    public init(operations: ActionBrokerSigningOperations<Code, StaticCode>) {
        self.operations = operations
        ownIdentity = Self.readIdentity(subject: .own, processID: nil, operations: operations)
            .flatMap { identity in
                guard !identity.teamID.isEmpty else {
                    return .failure(.init(subject: .own, stage: .team, reason: .missingTeam))
                }
                guard Self.isValidTeam(identity.teamID) else {
                    return .failure(.init(subject: .own, stage: .team, reason: .invalidTeam))
                }
                guard identity.identifier == Self.expectedBrokerIdentifier else {
                    return .failure(.init(subject: .own, stage: .identifier, reason: .identifierNotAllowed))
                }
                return .success(identity)
            }
    }

    public func authorizeCandidate(
        processID: Int32,
        effectiveUserID: UInt32,
        currentUserID: UInt32
    ) -> Result<ActionBrokerPeerAuthorization, ActionBrokerIdentityFailure> {
        guard effectiveUserID == currentUserID else {
            return .failure(.init(subject: .policy, stage: .user, reason: .userMismatch))
        }
        guard processID > 0 else {
            return .failure(.init(subject: .policy, stage: .process, reason: .invalidProcess))
        }
        return ownIdentity.flatMap { own in
            Self.readIdentity(subject: .peer, processID: processID, operations: operations).flatMap { peer in
                guard !peer.teamID.isEmpty else {
                    return .failure(.init(subject: .peer, stage: .team, reason: .missingTeam))
                }
                guard peer.teamID == own.teamID else {
                    return .failure(.init(subject: .policy, stage: .team, reason: .teamMismatch))
                }
                let role: ActionBrokerPeerAuthorization.Role
                let identifiers: String
                switch peer.identifier {
                case BlocksActionBrokerXPC.appBundleIdentifier:
                    role = .appHost
                    identifiers = "identifier \"\(BlocksActionBrokerXPC.appBundleIdentifier)\""
                case "app.blocks.cli", "blocks":
                    role = .client
                    identifiers = "identifier \"\(peer.identifier)\""
                default:
                    return .failure(.init(subject: .policy, stage: .identifier, reason: .identifierNotAllowed))
                }
                return .success(ActionBrokerPeerAuthorization(
                    role: role,
                    connectionRequirement: "anchor apple generic and \(identifiers) and certificate leaf[subject.OU] = \"\(own.teamID)\""
                ))
            }
        }
    }

    /// Read the running App once, never its replaceable bundle on disk. The
    /// same strict Apple/role/Team policy is retained on every XPC connection.
    public static func hostConnectionRequirement(
        operations: ActionBrokerSigningOperations<Code, StaticCode>
    ) -> Result<String, ActionBrokerIdentityFailure> {
        readIdentity(subject: .own, processID: nil, operations: operations,
            selfRequirement: "anchor apple generic and identifier \"\(BlocksActionBrokerXPC.appBundleIdentifier)\"")
            .flatMap { identity in
                guard !identity.teamID.isEmpty else {
                    return .failure(.init(subject: .own, stage: .team, reason: .missingTeam))
                }
                guard isValidTeam(identity.teamID) else {
                    return .failure(.init(subject: .own, stage: .team, reason: .invalidTeam))
                }
                guard identity.identifier == BlocksActionBrokerXPC.appBundleIdentifier else {
                    return .failure(.init(subject: .own, stage: .identifier, reason: .identifierNotAllowed))
                }
                return .success("anchor apple generic and identifier \"\(expectedBrokerIdentifier)\" and certificate leaf[subject.OU] = \"\(identity.teamID)\"")
            }
    }

    private static func isValidTeam(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func readIdentity(
        subject: ActionBrokerIdentityFailure.Subject,
        processID: Int32?,
        operations: ActionBrokerSigningOperations<Code, StaticCode>,
        selfRequirement: String? = nil
    ) -> Result<ActionBrokerSigningIdentity, ActionBrokerIdentityFailure> {
        ActionBrokerSecurityTelemetry.$subject.withValue(subject) {
        let copied = processID.map(operations.copyGuest) ?? operations.copySelf()
        let copyStage: ActionBrokerIdentityFailure.Stage = processID == nil ? .copySelf : .copyGuest
        guard copied.0 == errSecSuccess else {
            return .failure(.init(subject: subject, stage: copyStage, reason: .securityError, osStatus: copied.0))
        }
        guard let code = copied.1 else {
            return .failure(.init(subject: subject, stage: copyStage, reason: .missingValue, osStatus: copied.0))
        }
        switch operations.checkValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), processID == nil ? (selfRequirement ?? ownRequirement) : nil) {
        case .valid: break
        case let .requirementFailure(status):
            return .failure(.init(subject: subject, stage: .requirement,
                reason: status == errSecSuccess ? .missingValue : .securityError, osStatus: status))
        case let .invalid(status):
            return .failure(.init(subject: subject, stage: .validity, reason: .securityError, osStatus: status))
        }
        let copiedStatic = operations.copyStatic(code)
        guard copiedStatic.0 == errSecSuccess else {
            return .failure(.init(subject: subject, stage: .copyStatic, reason: .securityError, osStatus: copiedStatic.0))
        }
        guard let staticCode = copiedStatic.1 else {
            return .failure(.init(subject: subject, stage: .copyStatic, reason: .missingValue, osStatus: copiedStatic.0))
        }
        let information = operations.signingInformation(staticCode)
        guard information.0 == errSecSuccess else {
            return .failure(.init(subject: subject, stage: .signingInformation, reason: .securityError, osStatus: information.0))
        }
        guard let identity = information.1 else {
            return .failure(.init(subject: subject, stage: .signingInformation, reason: .missingValue, osStatus: information.0))
        }
        return .success(identity)
        }
    }
}

/// Capacity covers queued and executing native validation, not just live XPC
/// requests. Cancelling a ticket never releases its permit; only actual worker
/// completion (or a skipped queued operation) does that.
public final class ActionBrokerSecurityWorkAdmission: @unchecked Sendable {
    public final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var release: (() -> Void)?
        private var cancelled = false
        private var resultClaimed = false
        fileprivate init(release: @escaping () -> Void) { self.release = release }
        public var isCancelled: Bool { lock.withLock { cancelled } }
        @discardableResult public func cancel() -> Bool {
            lock.withLock {
                guard !cancelled, !resultClaimed else { return false }
                cancelled = true
                return true
            }
        }
        /// The single publication point races cancellation, never Security.
        public func claimResult() -> Bool {
            lock.withLock {
                guard !cancelled, !resultClaimed else { return false }
                resultClaimed = true
                return true
            }
        }
        public func finish() {
            let release = lock.withLock { defer { self.release = nil }; return self.release }
            release?()
        }
        deinit { finish() }
    }

    private let lock = NSLock()
    private let capacity: Int
    private var occupied = 0
    public init(capacity: Int = 16) { self.capacity = max(1, capacity) }
    public var inFlightCount: Int { lock.withLock { occupied } }
    public func reserve() -> Ticket? {
        lock.withLock {
            guard occupied < capacity else { return nil }
            occupied += 1
            return Ticket { [self] in lock.withLock { occupied -= 1 } }
        }
    }
}

/// Only immutable Sendable results leave this serial utility queue. Security
/// handles, the validator and its cached self snapshot stay on the worker.
public final class ActionBrokerIdentityWorker<Code, StaticCode>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blocks.broker-identity", qos: .utility)
    private let operations: ActionBrokerSigningOperations<Code, StaticCode>
    private var validator: ActionBrokerIdentityValidator<Code, StaticCode>?
    private let authorizationAdmission: ActionBrokerSecurityWorkAdmission

    public init(operations: ActionBrokerSigningOperations<Code, StaticCode>, authorizationCapacity: Int = 16) {
        self.operations = operations
        authorizationAdmission = .init(capacity: authorizationCapacity)
    }

    public func reserveAuthorization() -> ActionBrokerSecurityWorkAdmission.Ticket? { authorizationAdmission.reserve() }
    public var pendingAuthorizationCount: Int { authorizationAdmission.inFlightCount }

    private func snapshot() -> ActionBrokerIdentityValidator<Code, StaticCode> {
        if let validator { return validator }
        let started = ContinuousClock.now
        let value = ActionBrokerIdentityValidator(operations: operations)
        validator = value
        ActionBrokerSecurityTelemetry.record("broker_snapshot", started: started,
            failure: value.ownIdentity.failure)
        return value
    }

    public func prepare(completion: @escaping @Sendable (Result<Void, ActionBrokerIdentityFailure>) -> Void) {
        queue.async { [self] in completion(snapshot().ownIdentity.map { _ in () }) }
    }

    public func authorizeCandidate(processID: Int32, effectiveUserID: UInt32, currentUserID: UInt32,
        reservation: ActionBrokerSecurityWorkAdmission.Ticket? = nil,
        completion: @escaping @Sendable (Result<ActionBrokerPeerAuthorization, ActionBrokerIdentityFailure>) -> Void) {
        guard let ticket = reservation ?? authorizationAdmission.reserve() else {
            completion(.failure(.init(subject: .policy, stage: .process, reason: .capacityExceeded)))
            return
        }
        queue.async { [self] in
            defer { ticket.finish() }
            guard !ticket.isCancelled else {
                completion(.failure(.init(subject: .policy, stage: .process, reason: .cancelled))); return
            }
            let started = ContinuousClock.now
            let validator = snapshot()
            guard !ticket.isCancelled else {
                completion(.failure(.init(subject: .policy, stage: .process, reason: .cancelled))); return
            }
            let result = validator.authorizeCandidate(processID: processID,
                effectiveUserID: effectiveUserID, currentUserID: currentUserID)
            guard !ticket.isCancelled else {
                completion(.failure(.init(subject: .policy, stage: .process, reason: .cancelled))); return
            }
            ActionBrokerSecurityTelemetry.record("peer_authorization", started: started, failure: result.failure)
            completion(result)
        }
    }
}

/// A single running-App requirement snapshot, including failures. Callers may
/// cancel their wait without cancelling or restarting an in-flight Security API.
public final class ActionBrokerRequirementWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blocks.host-identity", qos: .utility)
    private let resolve: () -> Result<String, ActionBrokerIdentityFailure>
    private var cached: Result<String, ActionBrokerIdentityFailure>?

    public init(resolve: @escaping () -> Result<String, ActionBrokerIdentityFailure>) {
        self.resolve = resolve
    }

    public func load(completion: @escaping @Sendable (Result<String, ActionBrokerIdentityFailure>) -> Void) {
        queue.async { [self] in
            if let cached { completion(cached); return }
            let started = ContinuousClock.now
            let result = resolve()
            cached = result
            ActionBrokerSecurityTelemetry.record("host_requirement", started: started, failure: result.failure)
            completion(result)
        }
    }
}

private extension Result where Failure == ActionBrokerIdentityFailure {
    var failure: Failure? { if case let .failure(value) = self { return value }; return nil }
}

private enum ActionBrokerSecurityTelemetry {
    static let logger = Logger(subsystem: "app.blocks", category: "BrokerSecurity")
    @TaskLocal static var subject: ActionBrokerIdentityFailure.Subject = .policy
    static func measure(stage: ActionBrokerIdentityFailure.Stage, operation: () -> OSStatus) -> OSStatus {
        let measuredSubject = subject
        let mainThread = Thread.isMainThread
        let started = ContinuousClock.now
        let status = operation()
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let outcome = status == errSecSuccess ? "success" : "failure"
        logger.info("Security API subject=\(measuredSubject.rawValue, privacy: .public) stage=\(stage.rawValue, privacy: .public) mainThread=\(mainThread, privacy: .public) elapsedMS=\(milliseconds, privacy: .public) outcome=\(outcome, privacy: .public) osstatus=\(status, privacy: .public)")
        return status
    }
    static func record(_ phase: String, started: ContinuousClock.Instant, failure: ActionBrokerIdentityFailure?) {
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let outcome = failure == nil ? "accepted" : "rejected"
        let status = failure?.osStatus.map { String($0) } ?? "none"
        logger.info("Security phase=\(phase, privacy: .public) mainThread=\(Thread.isMainThread, privacy: .public) elapsedMS=\(milliseconds, privacy: .public) outcome=\(outcome, privacy: .public) osstatus=\(status, privacy: .public)")
    }
}

/// One bounded log budget per fixed subject/stage/reason, not per PID or raw
/// OSStatus. A hostile client cannot grow the map by varying status codes.
public final class ActionBrokerIdentityDiagnosticLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: [String: TimeInterval] = [:]
    private let interval: TimeInterval
    private let now: () -> TimeInterval

    public init(interval: TimeInterval = 30, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.now = now
    }

    public func shouldLog(_ failure: ActionBrokerIdentityFailure) -> Bool {
        lock.withLock {
            let key = "\(failure.subject.rawValue).\(failure.stage.rawValue).\(failure.reason.rawValue)"
            let timestamp = now()
            if let last = lastEmission[key], timestamp - last < interval { return false }
            lastEmission[key] = timestamp
            return true
        }
    }
}
