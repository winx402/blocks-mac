import Foundation

/// A business-operation boundary, not a Task-handle heuristic. Pausing refuses
/// while admitted work is active; it never cancels that work. Callers can retry
/// after leases finish, even when a completed Task handle remains stored.
public final class ApplicationOperationAdmissionGate: @unchecked Sendable {
    private final class WeakGate {
        weak var value: ApplicationOperationAdmissionGate?
        init(_ value: ApplicationOperationAdmissionGate) { self.value = value }
    }
    private static let admissionLock = NSRecursiveLock()
    private static var gates: [WeakGate] = []
    private static var globallyPaused = false
    private static var pauseOwner: UUID?
    private static var pauseWaiters: [UUID: PauseWaiter] = [:]
    /// Only the already-committed termination hook may perform cleanup after
    /// the global cutoff. UI/external tasks never receive this task-local scope.
    @TaskLocal private static var permitsQuitCleanup = false

    @MainActor
    public static func withQuitCleanup(_ operation: @MainActor () async -> Void) async {
        await $permitsQuitCleanup.withValue(true) { await operation() }
    }
    public enum AdmissionError: Error, LocalizedError {
        case busy(String)
        case paused(String)
        public var errorDescription: String? {
            switch self {
            case let .busy(name): return "\(name) still has active work. Finish it and retry."
            case let .paused(name): return "\(name) is paused while the application prepares to update."
            }
        }
    }

    /// An update may reopen only the cutoff it acquired. A real Quit (or a
    /// newer cutoff) invalidates this token before any asynchronous recovery.
    public final class UpdatePause: @unchecked Sendable {
        fileprivate let id: UUID
        fileprivate init(id: UUID) { self.id = id }

        public var isCurrent: Bool {
            ApplicationOperationAdmissionGate.admissionLock.withLock {
                ApplicationOperationAdmissionGate.globallyPaused && ApplicationOperationAdmissionGate.pauseOwner == id
            }
        }

        @discardableResult
        public func resumeIfOwned() -> Bool {
            ApplicationOperationAdmissionGate.admissionLock.withLock {
                guard ApplicationOperationAdmissionGate.globallyPaused,
                      ApplicationOperationAdmissionGate.pauseOwner == id else { return false }
                ApplicationOperationAdmissionGate.pauseOwner = nil
                ApplicationOperationAdmissionGate.globallyPaused = false
                return true
            }
        }

        deinit { resumeIfOwned() }
    }

    public struct DiagnosticSnapshot: Equatable, Sendable {
        public struct Activity: Equatable, Sendable {
            public let gateID: String
            public let activeCount: Int
        }
        public let globallyPaused: Bool
        public let activeGates: [Activity]
    }

    /// All request state is protected by admissionLock, including cancellation
    /// before the continuation is installed and release-before-await races.
    private final class PauseWaiter: @unchecked Sendable {
        let id = UUID()
        let deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<UpdatePause, Error>?
        var result: Result<UpdatePause, Error>?
        var timeoutTask: Task<Void, Never>?

        init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
    }

    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: ApplicationOperationAdmissionGate?
        fileprivate init(_ gate: ApplicationOperationAdmissionGate) { self.gate = gate }
        public func release() {
            let gate = lock.withLock {
                defer { self.gate = nil }
                return self.gate
            }
            gate?.finish()
        }
        deinit { release() }
    }

    private let lock = NSLock()
    private let name: String
    private var accepting = true
    private var activeCount = 0

    public init(name: String) {
        self.name = name
        Self.admissionLock.withLock {
            Self.gates.removeAll { $0.value == nil }
            Self.gates.append(WeakGate(self))
        }
    }

    public var isAcceptingOperations: Bool {
        Self.admissionLock.withLock { (!Self.globallyPaused || Self.permitsQuitCleanup) && lock.withLock { accepting } }
    }
    public var activeOperationCount: Int { lock.withLock { activeCount } }

    public func begin() -> Lease? {
        Self.admissionLock.withLock {
            guard !Self.globallyPaused || Self.permitsQuitCleanup else { return nil }
            return lock.withLock {
                guard accepting else { return nil }
                activeCount += 1
                return Lease(self)
            }
        }
    }

    /// One cross-feature linearization point: either all already-admitted
    /// operations are finished, or *no* feature is paused. This prevents
    /// partially paused dependencies from breaking another feature's work.
    public static func pauseAllIfIdle() throws {
        try admissionLock.withLock {
            try ensureAllIdle()
            globallyPaused = true
            pauseOwner = nil
            rejectPauseWaiters()
        }
    }

    /// Absorb only a short post-Hook admission race. Existing work is never
    /// cancelled or partially paused. Lease completion, not timer polling,
    /// retries the all-idle test and closes admission under the same lock.
    /// The caller still owns its outer preparation deadline.
    /// A zero duration makes one immediate all-idle attempt without waiting.
    @MainActor
    public static func pauseAllWhenIdle(for timeout: Duration) async throws -> UpdatePause {
        let boundedTimeout = min(max(timeout, .zero), .seconds(1))
        let waiter = PauseWaiter(deadline: ContinuousClock.now.advanced(by: boundedTimeout))
        let pause = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                admissionLock.withLock {
                    if let result = waiter.result {
                        continuation.resume(with: result)
                        return
                    }
                    waiter.continuation = continuation
                    guard !globallyPaused else {
                        resolve(waiter, .failure(AdmissionError.paused("Application")))
                        return
                    }
                    pauseWaiters[waiter.id] = waiter
                    settlePauseWaiters(immediateWaiterID: waiter.id)
                    guard waiter.result == nil else { return }
                    waiter.timeoutTask = Task {
                        do { try await Task.sleep(until: waiter.deadline, clock: .continuous) }
                        catch { return }
                        admissionLock.withLock {
                            resolve(waiter, .failure(AdmissionError.busy("Application")))
                        }
                    }
                }
            }
        } onCancel: {
            admissionLock.withLock { resolve(waiter, .failure(CancellationError())) }
        }
        // Completion can win the lock immediately before cancellation. Never
        // strand a successfully acquired cutoff in the cancelled awaiter.
        do {
            try Task.checkCancellation()
            return pause
        } catch {
            pause.resumeIfOwned()
            throw error
        }
    }

    /// Only fixed structural IDs leave this boundary. Even a dynamically
    /// named gate is grouped into "other", never logged as arbitrary text.
    public static var diagnosticSnapshot: DiagnosticSnapshot {
        admissionLock.withLock {
            var counts: [String: Int] = [:]
            for gate in gates.compactMap(\.value) {
                let count = gate.activeOperationCount
                guard count > 0 else { continue }
                counts[diagnosticID(for: gate.name), default: 0] += count
            }
            return DiagnosticSnapshot(
                globallyPaused: globallyPaused,
                activeGates: counts.keys.sorted().map {
                    .init(gateID: $0, activeCount: counts[$0]!)
                }
            )
        }
    }

    public static func ensureAllIdle() throws {
        try admissionLock.withLock {
            guard !globallyPaused else { throw AdmissionError.paused("Application") }
            for gate in gates.compactMap(\.value) {
                guard gate.activeOperationCount == 0 else { throw AdmissionError.busy(gate.name) }
            }
        }
    }

    public static func resumeAll() {
        admissionLock.withLock {
            pauseOwner = nil
            globallyPaused = false
        }
    }

    /// Quit closes admission even when existing leases are still draining.
    /// This is deliberately separate from the updater's all-idle transaction.
    public static func closeAdmissionForQuit() {
        admissionLock.withLock {
            pauseOwner = nil
            globallyPaused = true
            rejectPauseWaiters()
        }
    }

    public static var totalActiveOperationCount: Int {
        admissionLock.withLock { gates.compactMap(\.value).reduce(0) { $0 + $1.activeOperationCount } }
    }

    public func requireLease() throws -> Lease {
        guard let lease = begin() else { throw AdmissionError.paused(name) }
        return lease
    }

    public func pauseIfIdle() throws {
        try lock.withLock {
            guard activeCount == 0 else { throw AdmissionError.busy(name) }
            accepting = false
        }
    }

    public func resume() { lock.withLock { accepting = true } }

    private func finish() {
        Self.admissionLock.withLock {
            lock.withLock {
                precondition(activeCount > 0)
                activeCount -= 1
            }
            Self.settlePauseWaiters()
        }
    }

    /// Called only with admissionLock held. Resuming a continuation merely
    /// schedules its task; no caller-provided code executes under this lock.
    private static func resolve(_ waiter: PauseWaiter, _ result: Result<UpdatePause, Error>) {
        guard waiter.result == nil else { return }
        waiter.result = result
        pauseWaiters.removeValue(forKey: waiter.id)
        waiter.timeoutTask?.cancel()
        waiter.timeoutTask = nil
        waiter.continuation?.resume(with: result)
        waiter.continuation = nil
    }

    private static func rejectPauseWaiters() {
        for waiter in Array(pauseWaiters.values) {
            resolve(waiter, .failure(AdmissionError.paused("Application")))
        }
    }

    private static func settlePauseWaiters(immediateWaiterID: UUID? = nil) {
        guard !pauseWaiters.isEmpty else { return }
        guard !globallyPaused else { rejectPauseWaiters(); return }
        let idle = gates.compactMap(\.value).allSatisfy { $0.activeOperationCount == 0 }
        for waiter in Array(pauseWaiters.values) {
            if idle, ContinuousClock.now < waiter.deadline || waiter.id == immediateWaiterID {
                globallyPaused = true
                pauseOwner = waiter.id
                resolve(waiter, .success(UpdatePause(id: waiter.id)))
                rejectPauseWaiters()
                return
            } else if ContinuousClock.now >= waiter.deadline {
                resolve(waiter, .failure(AdmissionError.busy("Application")))
            }
        }
    }

    private static func diagnosticID(for name: String) -> String {
        switch name {
        case "Application background work": return "app"
        case "Action Broker requests": return "action_broker_requests"
        case "Action Broker management": return "action_broker_management"
        case "Clipboard": return "clipboard"
        case "Clipboard live capture": return "clipboard_capture"
        case "Clipboard detail": return "clipboard_detail"
        case "Clipboard tags": return "clipboard_tags"
        case "Clipboard OCR": return "clipboard_ocr"
        case "Clipboard OCR scheduler": return "clipboard_ocr_scheduler"
        case "provider": return "provider"
        case "translation": return "translation"
        case "Plugin host operations": return "plugin_host"
        case "Plugin runtime": return "plugin_runtime"
        case "Plugin management": return "plugin_management"
        case "Screenshot": return "screenshot"
        case "Selection Helper launch": return "selection_helper_launch"
        case "Selection Helper client": return "selection_helper_client"
        case "Selection Helper capture operation": return "selection_helper_capture"
        case "CLI installation": return "cli_installation"
        default: return "other"
        }
    }

    /// Acquire before enqueuing so a not-yet-started task is not mistaken for
    /// idle. Existing cancellation behavior remains owned by the feature.
    @MainActor
    @discardableResult
    public func task(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard let lease = begin() else { return nil }
        return Task { @MainActor in
            defer { lease.release() }
            await operation()
        }
    }
}
