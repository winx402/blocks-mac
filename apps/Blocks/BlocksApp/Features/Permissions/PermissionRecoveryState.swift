import Foundation

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
