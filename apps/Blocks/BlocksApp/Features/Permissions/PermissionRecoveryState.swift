import Foundation
import BlocksCore

/// Process-local, allowlisted feedback only. Never retain an arbitrary error,
/// participant payload, path or credential in recovery state or its ticket.
enum PermissionRestartFailure: String, Equatable, CaseIterable {
    case helperNotPaired = "helper_not_paired"
    case busy
    case timedOut = "timed_out"
    case connectionUnavailable = "connection_unavailable"
    case authenticationUnavailable = "authentication_unavailable"
    case recoveryConflict = "recovery_conflict"
    case componentNotReady = "component_not_ready"
    case database
    case launchFailed = "launch_failed"
    case unknown

    var localizationKey: String { "settings.permissionRecovery.failure.\(rawValue)" }
    var message: String { L10n.string(localizationKey) }

    init(preparationError error: Error) {
        let drain = error as? ApplicationLifecycleCoordinator.ParticipantDrainError
        let underlying = drain?.underlying ?? error
        if let admission = underlying as? ApplicationOperationAdmissionGate.AdmissionError {
            switch admission {
            case .busy:
                self = .busy
            case .paused:
                self = .recoveryConflict
            }
            return
        }
        if let safety = underlying as? ApplicationLifecycleCoordinator.SafetyError {
            switch safety {
            case .preparationInProgress, .configurationLocked: self = .recoveryConflict
            case .missingParticipants: self = .componentNotReady
            }
            return
        }
        if let helper = underlying as? SelectionHelperUpdatePreparationFailure {
            switch helper {
            case .helperNotPaired: self = .helperNotPaired
            case .preparationUnavailable: self = .connectionUnavailable
            case .preparationRejected: self = .componentNotReady
            }
            return
        }
        if let helper = underlying as? SelectionAgentServiceFailure {
            switch helper {
            case .timedOut: self = .timedOut
            case .keychainUnavailable, .bootstrapUnavailable, .notPaired, .invalidPairingCode:
                self = .authenticationUnavailable
            case .connectionFailed, .helperNotRunning: self = .connectionUnavailable
            case .disconnectNotConfirmed: self = .recoveryConflict
            case .helperNotInstalled, .helperInstallationConflict, .incompatibleVersion, .invalidResponse:
                self = .componentNotReady
            }
            return
        }
        guard underlying is ActionBrokerUpdateError || drain?.participantID == "database" else {
            self = .unknown
            return
        }
        // Reuse semantic classifications, never the update-specific message
        // (which describes a downloaded update rather than permission recovery).
        switch AppUpdatePreparationFailure(error: error).reason {
        case .helperNotPaired: self = .helperNotPaired
        case .helperKeyUnavailable, .brokerUntrusted: self = .authenticationUnavailable
        case .helperUnavailable, .brokerUnavailable: self = .connectionUnavailable
        case .brokerBusy, .busy: self = .busy
        case .brokerTimeout: self = .timedOut
        case .brokerRecovery: self = .recoveryConflict
        case .database: self = .database
        case .helperBusy, .brokerMigration, .brokerUnsupported,
             .brokerRejected, .brokerApproval, .brokerShutdown:
            self = .componentNotReady
        case .other: self = .unknown
        }
    }
}

enum PermissionRecoveryStage: String, Codable, Equatable {
    case checking
    case restartSuggested
    case restarting
    /// The launcher accepted the handoff; neither exit nor recovery is proven.
    case restartScheduled
    case resumingAfterRestart
    case recovered
    case needsReauthorization
    case restartFailed

    var isInFlight: Bool {
        switch self {
        case .checking, .restarting, .restartScheduled, .resumingAfterRestart: true
        case .restartSuggested, .recovered, .needsReauthorization, .restartFailed: false
        }
    }
}

struct PermissionRecoveryState: Equatable {
    let kind: PermissionDiagnosticKind
    let stage: PermissionRecoveryStage
    let failure: PermissionRestartFailure?

    init(
        kind: PermissionDiagnosticKind,
        stage: PermissionRecoveryStage,
        failure: PermissionRestartFailure? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.failure = stage == .restartFailed ? failure : nil
    }

    var isInFlight: Bool { stage.isInFlight }
    // Re-adding a permission can itself require a new process. This remains
    // an explicit button, never an automatic loop after a failed check.
    var canRestart: Bool {
        stage == .restartSuggested || stage == .restartFailed || stage == .needsReauthorization
    }
}

/// View-local intent only: the store stays restartable until its owning sheet
/// has actually dismissed. Recreating or leaving that owner must not restart.
struct PermissionRecoveryRestartPresentationGate {
    private var pendingState: PermissionRecoveryState?

    static func canPresentRecoverySheet(for state: PermissionRecoveryState?) -> Bool {
        guard let state else { return false }
        switch state.stage {
        case .restarting, .restartScheduled:
            // Reopening a sheet during the prepared restart can prevent the
            // pending AppKit termination from reaching the delegate.
            return false
        case .checking, .restartSuggested, .resumingAfterRestart,
             .recovered, .needsReauthorization, .restartFailed:
            return true
        }
    }

    mutating func requestRestart(for state: PermissionRecoveryState?) -> Bool {
        guard pendingState == nil, let state, state.canRestart else { return false }
        pendingState = state
        return true
    }

    mutating func consumeDismissedRestart(currentState: PermissionRecoveryState?) -> Bool {
        let requestedState = pendingState
        pendingState = nil
        guard let requestedState, requestedState == currentState else { return false }
        return requestedState.canRestart
    }

    mutating func cancelPendingRestart() {
        pendingState = nil
    }
}

/// No credentials, TCC data, installation paths, or persisted process IDs.
struct PermissionRecoveryTicket: Codable, Equatable {
    let kind: PermissionDiagnosticKind
    let stage: PermissionRecoveryStage
}

@MainActor
protocol PermissionRecoveryPersisting {
    func pendingTicket(for processID: Int32) -> PermissionRecoveryTicket?
    func save(_ ticket: PermissionRecoveryTicket, originatingProcessID: Int32)
    func consume(for processID: Int32) -> PermissionRecoveryTicket?
    func clear()
}

@MainActor
final class UserDefaultsPermissionRecoveryTicketStore: PermissionRecoveryPersisting {
    static let shared = UserDefaultsPermissionRecoveryTicketStore()

    private let defaults: UserDefaults
    private let key: String
    // This fence intentionally does not cross process boundaries, but does
    // cover repository recreation in the same process. Injected domains can
    // use a unique key to keep test persistence namespaces independent.
    private static var originatingProcessIDs: [String: Int32] = [:]

    init(
        defaults: UserDefaults = .standard,
        key: String = "blocks.permissions.recoveryTicket"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func pendingTicket(for processID: Int32) -> PermissionRecoveryTicket? {
        guard Self.originatingProcessIDs[key] != processID else { return nil }
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let ticket = try? JSONDecoder().decode(PermissionRecoveryTicket.self, from: data),
              ticket.stage == .restarting || ticket.stage == .restartScheduled else {
            clear()
            return nil
        }
        return ticket
    }

    func save(_ ticket: PermissionRecoveryTicket, originatingProcessID: Int32) {
        guard let data = try? JSONEncoder().encode(ticket) else { return }
        Self.originatingProcessIDs[key] = originatingProcessID
        defaults.set(data, forKey: key)
    }

    func consume(for processID: Int32) -> PermissionRecoveryTicket? {
        guard let ticket = pendingTicket(for: processID) else { return nil }
        clear()
        return ticket
    }

    func clear() {
        defaults.removeObject(forKey: key)
        Self.originatingProcessIDs.removeValue(forKey: key)
    }
}
