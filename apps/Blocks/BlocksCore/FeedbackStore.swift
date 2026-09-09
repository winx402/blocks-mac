import Darwin
import Foundation

struct FeedbackSubmissionLedger: Codable {
    let reportID: UUID
    let fingerprint: String
    let date: Date
    let automatic: Bool
    let account: String
    var issueURL: String?
}

struct FeedbackState: Codable {
    var reports: [FeedbackReport] = []
    var consent = FeedbackConsent()
    var submissions: [FeedbackSubmissionLedger] = []
}

/// Synchronous disk primitives; callers must use a background queue.
/// A private descriptor-relative store shared by the CLI and app, never the broker.
public final class FeedbackStore: @unchecked Sendable {
    public static let shared = FeedbackStore()
    let directory: URL
    private let version: String
    private let clock: @Sendable () -> Date

    public init(directory: URL? = nil, appVersion: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Blocks/Feedback", isDirectory: true)
        version = appVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        clock = now
    }

    public func recordShutdownEvent(_ event: FeedbackShutdownEvent) throws {
        try withState { state in
            if let index = state.reports.firstIndex(where: { $0.id == event.attemptID }) {
                // Keep both the beginning and recent terminal events within a strict bound.
                if state.reports[index].events.count >= 128 { state.reports[index].events.remove(at: 1) }
                state.reports[index].events.append(event)
            } else {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                #if arch(arm64)
                let architecture = "arm64"
                #elseif arch(x86_64)
                let architecture = "x86_64"
                #else
                let architecture = "unknown"
                #endif
                state.reports.append(FeedbackReport(id: event.attemptID, createdAt: clock(), appVersion: version,
                    osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
                    events: [event], status: "local", issueURL: nil, lastCode: nil))
            }
            if event.isAbnormal, let index = state.reports.firstIndex(where: { $0.id == event.attemptID }),
               state.reports[index].status == "local" { state.reports[index].status = "pending" }
        }
    }

    public func list() throws -> [FeedbackReport] { try withState { $0.reports.sorted { $0.createdAt > $1.createdAt } } }
    /// Invoke once at main-app startup, never from CLI inspection or while exiting.
    /// The launch boundary excludes attempts initiated in this new app run.
    public func recoverIncompleteAttempts(before launchBoundary: Date) throws {
        try withState { state in
            for index in state.reports.indices {
                let report = state.reports[index]
                guard report.createdAt < launchBoundary, report.status == "local",
                      report.events.contains(where: { $0.phase == "requested" }),
                      !report.events.contains(where: { $0.phase == "graceful" || $0.isAbnormal }) else { continue }
                state.reports[index].events.append(FeedbackShutdownEvent(attemptID: report.id,
                    phase: "incomplete_previous_attempt", participant: "app", code: "incomplete_shutdown",
                    elapsedMS: report.events.last?.elapsedMS ?? 0, forced: false,
                    activeOperations: report.events.last?.activeOperations ?? -1))
                state.reports[index].status = "pending"
            }
        }
    }
    public func report(id: UUID?) throws -> FeedbackReport {
        guard let report = try list().first(where: { id == nil || $0.id == id }) else { throw FeedbackFailure("report_not_found") }
        return report
    }
    public func consent() throws -> FeedbackConsent { try withState { $0.consent } }
    public func setConsent(enabled: Bool, account: String? = nil) throws {
        if enabled { guard let account, FeedbackGitHubClient.validAccount(account) else { throw FeedbackFailure("authentication_required") } }
        try withState {
            $0.consent.enabled = enabled
            $0.consent.account = enabled ? account : nil
            $0.consent.acceptedAt = enabled ? clock() : nil
            $0.consent.pausedCode = nil
        }
    }

    func withState<T>(_ operation: (inout FeedbackState) throws -> T) throws -> T {
        let root = try openDirectory()
        defer { close(root) }
        let lock = try openPrivate(root: root, name: "state.lock", flags: O_RDWR | O_CREAT)
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw FeedbackFailure("store_unavailable") }
        defer { flock(lock, LOCK_UN) }
        var state = FeedbackState()
        let fd = openat(root, "state.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            try validateFile(fd)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count >= 0 else { throw FeedbackFailure("store_unavailable") }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 2_000_000 else { throw FeedbackFailure("store_invalid") }
            }
            do { state = try JSONDecoder().decode(FeedbackState.self, from: data) }
            catch { throw FeedbackFailure("store_invalid") }
        } else if errno != ENOENT { throw FeedbackFailure("store_unsafe") }
        prune(&state)
        let result = try operation(&state)
        prune(&state)
        let data = try JSONEncoder().encode(state)
        let temporary = ".state-\(UUID().uuidString)"
        let output = try openPrivate(root: root, name: temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(output); unlinkat(root, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw FeedbackFailure("store_unavailable") }
                offset += count
            }
        }
        guard fsync(output) == 0, renameat(root, temporary, root, "state.json") == 0 else { throw FeedbackFailure("store_unavailable") }
        return result
    }

    func withSubmissionLock<T>(_ operation: () throws -> T) throws -> T {
        let root = try openDirectory()
        defer { close(root) }
        let lock = try openPrivate(root: root, name: "submit.lock", flags: O_RDWR | O_CREAT)
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw FeedbackFailure("submission_busy") }
        defer { flock(lock, LOCK_UN) }
        return try operation()
    }

    private func prune(_ state: inout FeedbackState) {
        let cutoff = clock().addingTimeInterval(-FeedbackPolicy.retention)
        state.reports = Array(state.reports.filter { $0.createdAt >= cutoff }.sorted { $0.createdAt > $1.createdAt }.prefix(FeedbackPolicy.reportLimit))
        // An unresolved POST is a no-body tombstone, not a retained report.
        // Age is never evidence that GitHub did not accept it. Keep its identity
        // so retry must reconcile; the overall state size limit fails closed.
        state.submissions.removeAll { $0.date < cutoff && $0.issueURL != nil }
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw FeedbackFailure("store_unsafe") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FeedbackFailure("store_unavailable") }
        do {
            let parts = directory.pathComponents.filter { $0 != "/" }
            guard !parts.isEmpty else { throw FeedbackFailure("store_unsafe") }
            for (index, part) in parts.enumerated() {
                guard part != ".", part != ".." else { throw FeedbackFailure("store_unsafe") }
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else { throw FeedbackFailure("store_unavailable") }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw FeedbackFailure("store_unsafe") }
                close(fd); fd = next
                if index == parts.count - 1 {
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw FeedbackFailure("store_unsafe") }
                }
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func openPrivate(root: Int32, name: String, flags: Int32) throws -> Int32 {
        let fd = openat(root, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FeedbackFailure("store_unsafe") }
        do { try validateFile(fd); return fd } catch { close(fd); throw error }
    }
    private func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw FeedbackFailure("store_unsafe") }
    }
}
