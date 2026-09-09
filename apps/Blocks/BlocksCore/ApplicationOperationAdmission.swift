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

    public static func resumeAll() { admissionLock.withLock { globallyPaused = false } }

    /// Quit closes admission even when existing leases are still draining.
    /// This is deliberately separate from the updater's all-idle transaction.
    public static func closeAdmissionForQuit() {
        admissionLock.withLock { globallyPaused = true }
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
        lock.withLock {
            precondition(activeCount > 0)
            activeCount -= 1
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
