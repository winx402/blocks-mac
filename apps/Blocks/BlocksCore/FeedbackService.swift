import CryptoKit
import Foundation

/// Process-local revocation. The lock protects only booleans and callbacks, never
/// disk, process launch, or networking. stop() never waits for a request to finish.
public final class FeedbackStopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var automaticSuspended = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private var startedSubmissions = Set<UUID>()

    public init() {}
    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func check(automatic: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw FeedbackFailure("feedback_stopped") }
        if automatic && automaticSuspended { throw FeedbackFailure("automatic_disabled") }
    }
    public func suspendAutomatic() { lock.lock(); automaticSuspended = true; lock.unlock() }
    func resumeAutomatic() throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw FeedbackFailure("feedback_stopped") }
        automaticSuspended = false
    }
    public func stop() {
        lock.lock()
        stopped = true
        let actions = Array(cancellations.values)
        cancellations.removeAll()
        lock.unlock()
        for action in actions { DispatchQueue.global(qos: .utility).async(execute: action) }
    }
    func register(_ action: @escaping @Sendable () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw FeedbackFailure("feedback_stopped") }
        let id = UUID()
        cancellations[id] = action
        return id
    }
    func unregister(_ id: UUID) { lock.lock(); cancellations.removeValue(forKey: id); lock.unlock() }

    /// This is the submission's start linearization point. Revocation and this
    /// transition use the same lock. Slow preparation must precede this call;
    /// after admission the request is in-flight, not a future automatic request.
    func admitSubmission(_ id: UUID, automatic: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw FeedbackFailure("feedback_stopped") }
        if startedSubmissions.contains(id) { return }
        if automatic && automaticSuspended { throw FeedbackFailure("automatic_disabled") }
        startedSubmissions.insert(id)
    }
    func hasAdmittedSubmission(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return startedSubmissions.contains(id)
    }
    func finishSubmission(_ id: UUID) { lock.lock(); startedSubmissions.remove(id); lock.unlock() }
}

public final class FeedbackService: @unchecked Sendable {
    public let store: FeedbackStore
    private let client: any FeedbackGitHubServing
    private let clock: @Sendable () -> Date
    public let stopGate: FeedbackStopGate
    public init(store: FeedbackStore = .shared, client: (any FeedbackGitHubServing)? = nil,
                stopGate: FeedbackStopGate = FeedbackStopGate(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.stopGate = stopGate
        self.client = client ?? FeedbackGitHubClient(stopGate: stopGate)
        clock = now
    }
    public func stopForQuit() { stopGate.stop() }
    public func suspendAutomatic() { stopGate.suspendAutomatic() }
    public func doctor() -> FeedbackDoctor {
        guard !stopGate.isStopped else { return FeedbackDoctor(ghAvailable: false, account: nil, code: "feedback_stopped") }
        let result = client.doctor()
        guard !stopGate.isStopped else { return FeedbackDoctor(ghAvailable: false, account: nil, code: "feedback_stopped") }
        return result
    }
    public func preview(id: UUID?) throws -> FeedbackPreview {
        let report = try store.report(id: id)
        return FeedbackPreview(title: report.publicTitle, body: report.publicBody)
    }

    /// Explicitly enabling is only valid for the freshly checked, displayed account.
    public func enableAutomatic(expectedAccount: String) throws {
        try stopGate.check()
        let doctor = self.doctor()
        try stopGate.check()
        guard let account = doctor.account else { throw FeedbackFailure(doctor.code) }
        guard account == expectedAccount else { throw FeedbackFailure("account_changed") }
        try store.setConsent(enabled: true, account: account)
        try stopGate.resumeAutomatic()
    }

    public func submit(id: UUID?, automatic: Bool = false, expectedAccount: String? = nil) throws -> String {
        try stopGate.check(automatic: automatic)
        return try store.withSubmissionLock {
            let report = try store.report(id: id)
            if let url = report.issueURL, FeedbackGitHubClient.validIssueURL(url) { return url }
            if automatic, !report.isAbnormal { throw FeedbackFailure("not_eligible") }
            return try submitLocked(id: report.id, fingerprint: report.fingerprint, title: report.publicTitle,
                                    body: report.publicBody, automatic: automatic, expectedAccount: expectedAccount)
        }
    }

    public func manualPreview(title: String, body: String) throws -> FeedbackPreview {
        try FeedbackCredentialGuard.validate(title: title, body: body)
        let id = manualID(title: title, body: body)
        return FeedbackPreview(title: title, body: body + "\n\n<!-- blocks-feedback:\(id.uuidString.lowercased()) -->")
    }

    private func manualID(title: String, body: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data((title + "\u{0}" + body).utf8)))
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                          hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    public func create(title: String, body: String, expectedAccount: String? = nil) throws -> String {
        try stopGate.check()
        try FeedbackCredentialGuard.validate(title: title, body: body)
        // Stable identity also makes an explicit retry of identical manual content safe.
        let id = manualID(title: title, body: body)
        return try store.withSubmissionLock {
            try submitLocked(id: id, fingerprint: "manual-\(id.uuidString)", title: title,
                             body: try manualPreview(title: title, body: body).body, automatic: false, expectedAccount: expectedAccount)
        }
    }

    public func processAutomaticQueue() {
        guard (try? stopGate.check(automatic: true)) != nil else { return }
        guard let consent = try? store.consent(), consent.enabled, consent.pausedCode == nil else { return }
        guard let reports = try? store.list() else { return }
        for report in reports.reversed() where report.isAbnormal && ["pending", "unknown", "submitting"].contains(report.status) {
            guard (try? stopGate.check(automatic: true)) != nil else { return }
            do { _ = try submit(id: report.id, automatic: true) }
            catch let error as FeedbackFailure {
                if stopGate.isStopped || error.code == "automatic_disabled" { break }
                try? store.withState { state in
                    if let index = state.reports.firstIndex(where: { $0.id == report.id }) { state.reports[index].lastCode = error.code }
                }
                if ["account_changed", "authentication_required", "gh_missing", "daily_limit", "submission_busy"].contains(error.code) { break }
            } catch { break }
        }
    }

    private func submitLocked(id: UUID, fingerprint: String, title: String, body: String, automatic: Bool, expectedAccount: String? = nil) throws -> String {
        try stopGate.check(automatic: automatic)
        try FeedbackCredentialGuard.validate(title: title, body: body)
        let doctor = self.doctor()
        try stopGate.check(automatic: automatic)
        guard let account = doctor.account else { throw FeedbackFailure(doctor.code) }
        if let expectedAccount, expectedAccount != account { throw FeedbackFailure("account_changed") }
        if automatic {
            let consent = try store.consent()
            guard consent.enabled, consent.pausedCode == nil else { throw FeedbackFailure("automatic_disabled") }
            guard consent.account == account else {
                try store.withState { $0.consent.pausedCode = "account_changed" }
                throw FeedbackFailure("account_changed")
            }
        }
        if let previous = try store.withState({ $0.submissions.first { $0.reportID == id } }) {
            guard previous.account == account else { throw FeedbackFailure("account_changed") }
            if let url = previous.issueURL, FeedbackGitHubClient.validIssueURL(url) { return url }
            try stopGate.check(automatic: automatic)
            if let url = try client.find(marker: id.uuidString, account: account) {
                try stopGate.check(automatic: automatic)
                try finish(id: id, url: url)
                return url
            }
            // Search may lag GitHub's write. Absence is not proof the POST failed.
            throw FeedbackFailure("submission_unknown")
        }
        if automatic {
            let cutoff = clock().addingTimeInterval(-FeedbackPolicy.retention)
            let existing = try store.withState { $0.submissions.first { $0.automatic && $0.fingerprint == fingerprint && $0.date >= cutoff } }
            if let existing {
                try store.withState { state in
                    if let index = state.reports.firstIndex(where: { $0.id == id }) {
                        state.reports[index].status = "deduplicated"
                        state.reports[index].issueURL = existing.issueURL
                    }
                }
                throw FeedbackFailure("duplicate_suppressed")
            }
        }
        try store.withState { state in
            try stopGate.check(automatic: automatic)
            if automatic {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let today = calendar.startOfDay(for: clock())
                guard state.submissions.filter({ $0.automatic && $0.date >= today }).count < FeedbackPolicy.dailyAutomaticLimit else {
                    throw FeedbackFailure("daily_limit")
                }
            }
            state.submissions.append(FeedbackSubmissionLedger(reportID: id, fingerprint: fingerprint, date: clock(), automatic: automatic, account: account, issueURL: nil))
            if let index = state.reports.firstIndex(where: { $0.id == id }) { state.reports[index].status = "submitting" }
        }
        // A durable reservation is committed before the only external write.
        // Never store manual title/body or stderr in the state file.
        let submissionAdmission = UUID()
        defer { stopGate.finishSubmission(submissionAdmission) }
        do {
            let url = try client.create(title: title, body: body, authorize: { [self] in
                if !stopGate.hasAdmittedSubmission(submissionAdmission) {
                    try stopGate.check(automatic: automatic)
                    if automatic {
                        let current = try store.consent()
                        guard current.enabled, current.pausedCode == nil else { throw FeedbackFailure("automatic_disabled") }
                        guard current.account == account else { throw FeedbackFailure("account_changed") }
                    }
                }
                try stopGate.admitSubmission(submissionAdmission, automatic: automatic)
            })
            try stopGate.check()
            guard FeedbackGitHubClient.validIssueURL(url) else { throw FeedbackFailure("submission_unknown") }
            try finish(id: id, url: url)
            return url
        } catch {
            let admitted = stopGate.hasAdmittedSubmission(submissionAdmission)
            let code = admitted ? "submission_unknown" : ((error as? FeedbackFailure)?.code ?? "feedback_unavailable")
            try? store.withState { state in
                if !admitted {
                    // Revocation before the start boundary proves no request was
                    // admitted. Keep the report retryable; do not invent uncertainty.
                    state.submissions.removeAll { $0.reportID == id && $0.issueURL == nil }
                }
                if let index = state.reports.firstIndex(where: { $0.id == id }) {
                    state.reports[index].status = admitted ? "unknown" : (state.reports[index].isAbnormal ? "pending" : "local")
                    state.reports[index].lastCode = code
                }
            }
            throw FeedbackFailure(code)
        }
    }

    private func finish(id: UUID, url: String) throws {
        try store.withState { state in
            if let index = state.submissions.firstIndex(where: { $0.reportID == id }) { state.submissions[index].issueURL = url }
            if let index = state.reports.firstIndex(where: { $0.id == id }) {
                state.reports[index].status = "submitted"
                state.reports[index].issueURL = url
                state.reports[index].lastCode = nil
            }
        }
    }
}
