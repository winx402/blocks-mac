import Foundation
import BlocksCore

/// A management transaction, deliberately outside business admission leases:
/// holding one would prevent the all-application idle check from ever passing.
@MainActor
final class SourceUpgradeCoordinator {
    typealias Request = SourceUpgradeProtocol.Request
    typealias Response = SourceUpgradeProtocol.Response
    typealias Reply = @Sendable (Response) -> Void
    struct Owner: Equatable { let sessionID: UUID; let token: UUID }
    enum Phase: Equatable { case idle, preparing, prepared, committing, resuming, terminated }

    private(set) var phase: Phase = .idle
    private(set) var owner: Owner?
    var hasTransaction: Bool { owner != nil }
    private let canPrepare: () -> Bool
    private let prepare: () async throws -> Void
    private let resume: () async -> Void
    private let terminate: () -> Void
    private let timeout: Duration
    private var quitting = false
    private var usedTokens = Set<UUID>()
    private var disconnectedSessions = Set<UUID>()
    private var sessionHistoryExhausted = false
    private var preparation: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var cancellationCode: String?
    private var prepareReply: Reply?
    private var cancelReplies: [Reply] = []

    init(timeout: Duration = .seconds(30), canPrepare: @escaping () -> Bool,
         prepare: @escaping () async throws -> Void,
         resume: @escaping () async -> Void, terminate: @escaping () -> Void) {
        self.timeout = timeout
        self.canPrepare = canPrepare
        self.prepare = prepare
        self.resume = resume
        self.terminate = terminate
    }

    func handle(sessionID: UUID, request: Request, completion: @escaping Reply) {
        let candidate = Owner(sessionID: sessionID, token: request.token)
        func fail(_ code: String) {
            completion(Response(token: request.token, status: .failed, errorCode: code))
        }
        guard !quitting else { fail("quitting"); return }
        guard !sessionHistoryExhausted, !disconnectedSessions.contains(sessionID) else {
            fail("disconnected")
            return
        }
        guard request.version == 1 else { fail("unsupported_version"); return }
        switch request.operation {
        case .probe:
            completion(Response(token: request.token, status: .ready))
        case .prepare:
            guard owner == nil else { fail("busy"); return }
            guard !usedTokens.contains(request.token) else { fail("invalid_state"); return }
            guard usedTokens.count < 4096, disconnectedSessions.count < 4096,
                  canPrepare() else { fail("busy"); return }
            usedTokens.insert(request.token)
            owner = candidate
            phase = .preparing
            cancellationCode = nil
            prepareReply = completion
            deadline = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard !Task.isCancelled else { return }
                self?.cancel(candidate, code: "timeout")
            }
            preparation = Task { [self] in
                do {
                    try Task.checkCancellation()
                    try await prepare()
                    try Task.checkCancellation()
                    guard !quitting, owner == candidate, cancellationCode == nil else {
                        throw CancellationError()
                    }
                    preparation = nil
                    phase = .prepared
                    let reply = prepareReply
                    prepareReply = nil
                    reply?(Response(token: candidate.token, status: .prepared))
                } catch {
                    preparation = nil
                    guard owner == candidate else { return }
                    cancellationCode = cancellationCode ?? "preparation_failed"
                    beginRecovery(candidate)
                }
            }
        case .commit:
            guard owner == candidate else { fail(owner == nil ? "invalid_state" : "busy"); return }
            guard phase == .prepared else { fail("invalid_state"); return }
            phase = .committing
            // Once the transport owns the ACK, its bounded write/disconnect
            // arbitration is authoritative. A local deadline must not roll
            // back while an already-written ACK awaits its MainActor callback.
            deadline?.cancel()
            deadline = nil
            // This is only permission to write the ACK. The transport must call
            // didCommit *after* the complete response was successfully written.
            completion(Response(token: request.token, status: .committed))
        case .cancel:
            guard owner == candidate else { fail(owner == nil ? "invalid_state" : "busy"); return }
            guard phase != .terminated else { fail("invalid_state"); return }
            cancelReplies.append(completion)
            cancel(candidate, code: "cancelled")
        }
    }

    func didCommit(sessionID: UUID, token: UUID) {
        guard !quitting, owner == Owner(sessionID: sessionID, token: token), phase == .committing else { return }
        deadline?.cancel()
        deadline = nil
        phase = .terminated
        terminate()
    }

    func disconnected(sessionID: UUID) {
        // Transport callbacks hop to MainActor independently. Retain terminal
        // sessions even before prepare arrives, without assuming FIFO delivery.
        if disconnectedSessions.count < 4096 {
            disconnectedSessions.insert(sessionID)
        } else if !disconnectedSessions.contains(sessionID) {
            // Never evict a safety tombstone. Exhaustion fails closed for this
            // process instead of letting an unrecorded late request revive.
            sessionHistoryExhausted = true
        }
        guard let owner, owner.sessionID == sessionID, phase != .terminated else { return }
        cancel(owner, code: "disconnected")
    }

    /// Called synchronously by the real quit observer, before transport stop.
    /// No recovery callback may reopen services after this irreversible fence.
    func beginQuit() {
        quitting = true
        deadline?.cancel()
        deadline = nil
        preparation?.cancel()
        cancellationCode = "quitting"
    }

    private func cancel(_ expected: Owner, code: String) {
        guard owner == expected, !quitting, phase != .terminated else { return }
        cancellationCode = cancellationCode ?? code
        deadline?.cancel()
        deadline = nil
        if let preparation {
            preparation.cancel()
            // Even cancellation-insensitive participants must finish before
            // their resources can be resumed or a new owner can be admitted.
        } else {
            beginRecovery(expected)
        }
    }

    private func beginRecovery(_ expected: Owner) {
        guard owner == expected, recovery == nil else { return }
        phase = .resuming
        // A new unstructured task does not inherit the cancelled prepare task.
        recovery = Task { [self] in
            if !quitting { await resume() }
            guard owner == expected else { return }
            let pendingPrepare = prepareReply
            let pendingCancels = cancelReplies
            let code = cancellationCode ?? "preparation_failed"
            prepareReply = nil
            cancelReplies.removeAll()
            deadline?.cancel()
            deadline = nil
            recovery = nil
            owner = nil
            phase = quitting ? .terminated : .idle
            pendingPrepare?(Response(token: expected.token, status: .failed, errorCode: code))
            for reply in pendingCancels {
                reply(Response(token: expected.token, status: quitting ? .failed : .cancelled,
                               errorCode: quitting ? "quitting" : nil))
            }
        }
    }
}
