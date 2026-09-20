import Foundation
#if canImport(BlocksCore)
import BlocksCore
#endif

/// Each participant owns its *business* admission boundary, including queued
/// work that has not reached SQLite yet. A database lock alone is not a drain.
@MainActor
final class ApplicationLifecycleCoordinator {
    struct Participant {
        let id: String
        let pauseAndDrain: @MainActor () async throws -> Void
        let resume: @MainActor () async -> Void
    }

    enum State: Equatable { case active, preparing, prepared, resuming }
    enum Intent { case update, quit }
    private(set) var intent: Intent?
    private var quitCommitted = false
    var onParticipant: ((String, Bool) -> Void)?
    var beforeQuitDrain: (() async -> Void)?
    enum SafetyError: Error, LocalizedError {
        case missingParticipants([String])
        case preparationInProgress
        case configurationLocked

        var errorDescription: String? {
            switch self {
            case let .missingParticipants(ids):
                return "Update safety is not configured for: \(ids.joined(separator: ", "))."
            case .preparationInProgress:
                return "The application is already preparing to update or quit."
            case .configurationLocked:
                return "Application lifecycle participants cannot change during shutdown."
            }
        }
    }

    let requiredParticipantIDs: Set<String>
    private(set) var state: State = .active
    private var participants: [Participant] = []
    private var pausedParticipants: [Participant] = []
    private var recoveryTask: Task<Void, Never>?

    init(requiredParticipantIDs: Set<String>) {
        self.requiredParticipantIDs = requiredParticipantIDs
    }

    var hasCompleteSafetyCoverage: Bool {
        requiredParticipantIDs.isSubset(of: Set(participants.map(\.id)))
    }

    /// Registration order is shutdown order; register storage last, after all
    /// producers. Failed/cancelled preparation resumes in reverse order.
    func register(_ participant: Participant) throws {
        guard state == .active else { throw SafetyError.configurationLocked }
        if let index = participants.firstIndex(where: { $0.id == participant.id }) {
            participants[index] = participant
        } else {
            participants.append(participant)
        }
    }

    /// Synchronous quit fence: a cancelled update must not reopen participants
    /// before the asynchronous quit dispatcher gets its next actor turn.
    func beginQuit() {
        quitCommitted = true
        ApplicationOperationAdmissionGate.closeAdmissionForQuit()
        // Only real quit may cancel recovery. A cancelled update caller must
        // never pass its cancellation bit into remote resume commands.
        recoveryTask?.cancel()
    }

    func prepare(for requestedIntent: Intent = .update) async throws {
        if requestedIntent == .quit {
            beginQuit()
        } else if quitCommitted {
            throw SafetyError.preparationInProgress
        }
        if state == .prepared {
            guard intent == .update || requestedIntent == .quit else { throw SafetyError.preparationInProgress }
            return
        }
        guard state == .active else { throw SafetyError.preparationInProgress }
        let missing = requiredParticipantIDs.subtracting(participants.map(\.id))
        guard missing.isEmpty else { throw SafetyError.missingParticipants(missing.sorted()) }
        if requestedIntent == .update {
            try ApplicationOperationAdmissionGate.pauseAllIfIdle()
        } else {
            ApplicationOperationAdmissionGate.closeAdmissionForQuit()
        }
        intent = requestedIntent
        state = .preparing
        do {
            if requestedIntent == .quit {
                while ApplicationOperationAdmissionGate.totalActiveOperationCount > 0 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                await ApplicationOperationAdmissionGate.withQuitCleanup {
                    await beforeQuitDrain?()
                }
                while ApplicationOperationAdmissionGate.totalActiveOperationCount > 0 {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            let ordered = participants.filter { $0.id != "database" }
                + participants.filter { $0.id == "database" }
            for participant in ordered {
                try Task.checkCancellation()
                // Include the currently preparing participant: it may have
                // closed admission before discovering that it cannot drain.
                pausedParticipants.append(participant)
                onParticipant?(participant.id, false)
                try await participant.pauseAndDrain()
                if requestedIntent == .update, quitCommitted { throw CancellationError() }
                onParticipant?(participant.id, true)
            }
            try Task.checkCancellation()
            state = .prepared
        } catch {
            if requestedIntent == .update, !quitCommitted { await recoverPausedParticipants() }
            throw error
        }
    }

    /// Used after Sparkle aborts installation. This never cancels admitted
    /// operations. A participant must make its own resume idempotent.
    func resumeAfterCancelledUpdate() async {
        if let recoveryTask {
            await recoveryTask.value
            return
        }
        guard state == .prepared, intent == .update, !quitCommitted else { return }
        await recoverPausedParticipants()
    }

    private func recoverPausedParticipants() async {
        if let recoveryTask {
            await recoveryTask.value
            return
        }
        guard !quitCommitted else { return }
        state = .resuming
        let task = Task { @MainActor [self] in
            await resumePausedParticipants()
            recoveryTask = nil
        }
        recoveryTask = task
        // Unstructured tasks do not inherit caller cancellation. Keep the
        // lifecycle and transaction owner blocked until all recovery finishes.
        await task.value
    }

    private func resumePausedParticipants() async {
        guard !quitCommitted else { return }
        state = .resuming
        let toResume = pausedParticipants.reversed()
        pausedParticipants.removeAll()
        // Storage is always the last participant prepared, so resume it before
        // allowing any producer to enqueue work on reopened connections.
        if let database = toResume.first(where: { $0.id == "database" }) {
            await database.resume()
        }
        guard !quitCommitted else { return }
        ApplicationOperationAdmissionGate.resumeAll()
        for participant in toResume where participant.id != "database" {
            guard !quitCommitted else { return }
            await participant.resume()
        }
        guard !quitCommitted else { return }
        state = .active
        intent = nil
    }
}
