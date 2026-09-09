import BlocksCore
import Combine
import Foundation

@MainActor
final class FeedbackController: ObservableObject {
    static let shared = FeedbackController()
    @Published private(set) var consent = FeedbackConsent()
    @Published private(set) var account: String?
    @Published private(set) var isBusy = false
    @Published private(set) var statusCode = "local"
    @Published private(set) var latest: FeedbackReport?
    @Published private(set) var issueURL: String?
    private let service = FeedbackService()
    private var started = false
    private var startupTask: Task<Void, Never>?

    /// Permanent for this app run, synchronous and without waiting for I/O.
    func stopForQuit() {
        service.stopForQuit()
        startupTask?.cancel()
        startupTask = nil
    }

    /// Startup only. Exiting never performs a network request.
    func startIfEnabled() {
        guard !started, !service.stopGate.isStopped else { return }
        started = true
        let service = service
        let launchBoundary = Date()
        startupTask = Task.detached(priority: .utility) {
            guard !service.stopGate.isStopped else { return }
            try? service.store.recoverIncompleteAttempts(before: launchBoundary)
            service.processAutomaticQueue()
        }
    }

    func refresh() {
        guard !isBusy, !service.stopGate.isStopped else { return }
        isBusy = true
        let service = service
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                (service.doctor(), try? service.store.consent(), try? service.store.report(id: nil))
            }.value
            guard !service.stopGate.isStopped else { return }
            account = snapshot.0.account
            consent = snapshot.1 ?? FeedbackConsent()
            latest = snapshot.2
            statusCode = consent.pausedCode ?? snapshot.0.code
            isBusy = false
        }
    }

    func setAutomatic(_ enabled: Bool, account: String? = nil) {
        if !enabled { service.suspendAutomatic() }
        perform { service in
            if enabled {
                guard let account else { throw FeedbackFailure("authentication_required") }
                try service.enableAutomatic(expectedAccount: account)
            } else { try service.store.setConsent(enabled: false) }
            return nil
        }
    }

    func submitLatest(id: UUID, expectedAccount: String) {
        perform { try $0.submit(id: id, expectedAccount: expectedAccount) }
    }

    func create(title: String, body: String, expectedAccount: String) {
        perform { try $0.create(title: title, body: body, expectedAccount: expectedAccount) }
    }

    func prepareComposer() { issueURL = nil }

    private func perform(_ work: @escaping @Sendable (FeedbackService) throws -> String?) {
        guard !isBusy, !service.stopGate.isStopped else { return }
        isBusy = true
        statusCode = "working"
        issueURL = nil
        let service = service
        Task {
            let outcome = await Task.detached(priority: .utility) {
                Result { try work(service) }
            }.value
            guard !service.stopGate.isStopped else { return }
            let snapshot = await Task.detached(priority: .utility) {
                (try? service.store.consent(), try? service.store.report(id: nil))
            }.value
            consent = snapshot.0 ?? FeedbackConsent()
            latest = snapshot.1
            switch outcome {
            case .success(let url): issueURL = url; statusCode = url == nil ? "saved" : "submitted"
            case .failure(let error): statusCode = (error as? FeedbackFailure)?.code ?? "feedback_unavailable"
            }
            isBusy = false
        }
    }

    var statusText: String {
        switch statusCode {
        case "local": return L10n.string("feedback.status.local")
        case "ready", "saved": return L10n.string("feedback.status.ready")
        case "working": return L10n.string("feedback.status.working")
        case "submitted": return L10n.string("feedback.status.submitted")
        case "gh_missing": return L10n.string("feedback.status.ghMissing")
        case "authentication_required": return L10n.string("feedback.status.authRequired")
        case "account_changed": return L10n.string("feedback.status.accountChanged")
        case "submission_unknown": return L10n.string("feedback.status.unknown")
        case "credential_detected": return L10n.string("feedback.status.credential")
        default: return L10n.format("feedback.status.error", statusCode)
        }
    }
}
