import Foundation
import OSLog
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
    enum Intent: String { case update, quit }
    enum DiagnosticEvent: Equatable {
        enum ParticipantState: String { case started, completed }
        enum FailureCategory: String {
            case missingParticipants = "missing_participants"
            case preparationInProgress = "preparation_in_progress"
            case globalAdmissionBusy = "global_admission_busy"
            case globalAdmissionPaused = "global_admission_paused"
            case participantDrainFailed = "participant_drain_failed"
            case cancelled
        }

        case started(Intent)
        case participant(Intent, id: String, state: ParticipantState)
        case completed(Intent)
        case failed(Intent, FailureCategory)
        case recoveryStarted(Intent)
        case recoveryCompleted(Intent)
    }

    typealias DiagnosticRecorder = (DiagnosticEvent) -> Void
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks.app",
        category: "application-lifecycle"
    )
    private static let diagnosticParticipantIDs: Set<String> = [
        "app", "shortcuts", "cliInstallation", "helper", "actionBroker",
        "clipboard", "translation", "provider", "screenshot", "plugins",
        "database", "remote", "producer",
    ]
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
    private let diagnosticRecorder: DiagnosticRecorder

    init(requiredParticipantIDs: Set<String>, diagnosticRecorder: @escaping DiagnosticRecorder = { _ in }) {
        self.requiredParticipantIDs = requiredParticipantIDs
        self.diagnosticRecorder = diagnosticRecorder
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
        record(.started(requestedIntent))
        if requestedIntent == .quit {
            beginQuit()
        } else if quitCommitted {
            record(.failed(requestedIntent, .preparationInProgress))
            throw SafetyError.preparationInProgress
        }
        if state == .prepared {
            guard intent == .update || requestedIntent == .quit else {
                record(.failed(requestedIntent, .preparationInProgress))
                throw SafetyError.preparationInProgress
            }
            record(.completed(requestedIntent))
            return
        }
        guard state == .active else {
            record(.failed(requestedIntent, .preparationInProgress))
            throw SafetyError.preparationInProgress
        }
        let missing = requiredParticipantIDs.subtracting(participants.map(\.id))
        guard missing.isEmpty else {
            record(.failed(requestedIntent, .missingParticipants))
            throw SafetyError.missingParticipants(missing.sorted())
        }
        if requestedIntent == .update {
            do {
                try ApplicationOperationAdmissionGate.pauseAllIfIdle()
            } catch {
                record(.failed(requestedIntent, globalAdmissionFailureCategory(for: error)))
                throw error
            }
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
                record(.participant(requestedIntent, id: participant.id, state: .started))
                onParticipant?(participant.id, false)
                try await participant.pauseAndDrain()
                if requestedIntent == .update, quitCommitted { throw CancellationError() }
                onParticipant?(participant.id, true)
                record(.participant(requestedIntent, id: participant.id, state: .completed))
            }
            try Task.checkCancellation()
            state = .prepared
            record(.completed(requestedIntent))
        } catch {
            record(.failed(requestedIntent, preparationFailureCategory(for: error)))
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
        record(.recoveryStarted(.update))
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
        record(.recoveryCompleted(.update))
    }

    private func globalAdmissionFailureCategory(for error: Error) -> DiagnosticEvent.FailureCategory {
        guard let admissionError = error as? ApplicationOperationAdmissionGate.AdmissionError else {
            return .globalAdmissionBusy
        }
        switch admissionError {
        case .busy:
            return .globalAdmissionBusy
        case .paused:
            return .globalAdmissionPaused
        }
    }

    private func preparationFailureCategory(for error: Error) -> DiagnosticEvent.FailureCategory {
        error is CancellationError ? .cancelled : .participantDrainFailed
    }

    private func record(_ event: DiagnosticEvent) {
        diagnosticRecorder(event)
        switch event {
        case let .started(intent):
            Self.logger.info("application-lifecycle event=started intent=\(intent.rawValue, privacy: .public)")
        case let .participant(intent, id, state):
            let participant = Self.diagnosticParticipantIDs.contains(id) ? id : "other"
            Self.logger.info("application-lifecycle event=participant intent=\(intent.rawValue, privacy: .public) participant=\(participant, privacy: .public) state=\(state.rawValue, privacy: .public)")
        case let .completed(intent):
            Self.logger.info("application-lifecycle event=completed intent=\(intent.rawValue, privacy: .public)")
        case let .failed(intent, category):
            Self.logger.error("application-lifecycle event=failed intent=\(intent.rawValue, privacy: .public) category=\(category.rawValue, privacy: .public)")
        case let .recoveryStarted(intent):
            Self.logger.info("application-lifecycle event=recovery_started intent=\(intent.rawValue, privacy: .public)")
        case let .recoveryCompleted(intent):
            Self.logger.info("application-lifecycle event=recovery_completed intent=\(intent.rawValue, privacy: .public)")
        }
    }
}
