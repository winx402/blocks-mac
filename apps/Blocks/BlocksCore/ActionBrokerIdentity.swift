import Foundation
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
            let status = SecCodeCopySelf([], &code)
            return (status, code)
        }, copyGuest: { processID in
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: NSNumber(value: processID)] as CFDictionary
            let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
            return (status, code)
        }, checkValidity: { code, flags, requirementString in
            var requirement: SecRequirement?
            if let requirementString {
                let status = SecRequirementCreateWithString(requirementString as CFString, [], &requirement)
                guard status == errSecSuccess, requirement != nil else {
                    return .requirementFailure(status)
                }
            }
            let status = SecCodeCheckValidity(code, flags, requirement)
            return status == errSecSuccess ? .valid : .invalid(status)
        }, copyStatic: { code in
            var staticCode: SecStaticCode?
            let status = SecCodeCopyStaticCode(code, [], &staticCode)
            return (status, staticCode)
        }, signingInformation: { code in
            var information: CFDictionary?
            let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
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

    private static func isValidTeam(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func readIdentity(
        subject: ActionBrokerIdentityFailure.Subject,
        processID: Int32?,
        operations: ActionBrokerSigningOperations<Code, StaticCode>
    ) -> Result<ActionBrokerSigningIdentity, ActionBrokerIdentityFailure> {
        let copied = processID.map(operations.copyGuest) ?? operations.copySelf()
        let copyStage: ActionBrokerIdentityFailure.Stage = processID == nil ? .copySelf : .copyGuest
        guard copied.0 == errSecSuccess else {
            return .failure(.init(subject: subject, stage: copyStage, reason: .securityError, osStatus: copied.0))
        }
        guard let code = copied.1 else {
            return .failure(.init(subject: subject, stage: copyStage, reason: .missingValue, osStatus: copied.0))
        }
        switch operations.checkValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), processID == nil ? ownRequirement : nil) {
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
