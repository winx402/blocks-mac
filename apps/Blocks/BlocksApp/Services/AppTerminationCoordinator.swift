import AppKit
import OSLog
#if canImport(BlocksCore)
import BlocksCore
#endif

/// No main-actor, database, diagnostic-store or business-queue dependency.
private final class QuitWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blocks.quit-watchdog", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var fired = false
    var hasFired: Bool { lock.withLock { fired } }
    init(nanoseconds: UInt64, action: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(min(nanoseconds, 5_000_000_000))), leeway: .nanoseconds(0))
        timer.setEventHandler { [self] in
            lock.withLock { fired = true }
            timer.cancel()
            timer.setEventHandler {}
            action()
        }
        timer.resume()
    }
}

@MainActor
final class AppTerminationCoordinator {
    typealias Dispatcher = () async throws -> Void
    typealias Finalizer = () -> Void
    typealias ReplyHandler = (Bool) -> Void

    static let shared = AppTerminationCoordinator(
        hideUI: {
            NSApp.windows.forEach { $0.orderOut(nil) }
            NSApp.hide(nil)
            ApplicationOperationAdmissionGate.closeAdmissionForQuit()
        },
        forceExit: {
            ShutdownPrivateProcesses.terminateRegisteredProcesses()
            _exit(EXIT_SUCCESS)
        },
        eventRecorder: { event in
            diagnosticsQueue.async { try? FeedbackStore.shared.recordShutdownEvent(event) }
        },
        replyHandler: { NSApp.reply(toApplicationShouldTerminate: $0) }
    )
    nonisolated static let defaultTimeoutNanoseconds: UInt64 = 5_000_000_000
    nonisolated private static let diagnosticsQueue = DispatchQueue(label: "app.blocks.quit-diagnostics", qos: .utility)
    nonisolated private static let logger = Logger(subsystem: "app.blocks", category: "Termination")

    private let replyHandler: ReplyHandler
    private let hideUI: () -> Void
    private let forceExit: @Sendable () -> Void
    private let eventRecorder: @Sendable (FeedbackShutdownEvent) -> Void
    private let timeoutNanoseconds: UInt64
    private var watchdog: QuitWatchdog?
    private(set) var isQuitting = false
    private let attemptID = UUID()
    private var started = ContinuousClock.now
    private var dispatcher: Dispatcher?
    private var finalizer: Finalizer?
    private var onQuit: (() -> Void)?
    private var terminationIsPending = false
    private var terminationHasCompleted = false
    private var finalizerHasRun = false

    init(
        dispatcher: Dispatcher? = nil,
        finalizer: Finalizer? = nil,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
        hideUI: @escaping () -> Void = {},
        forceExit: @escaping @Sendable () -> Void = {},
        eventRecorder: @escaping @Sendable (FeedbackShutdownEvent) -> Void = { _ in },
        replyHandler: @escaping ReplyHandler
    ) {
        self.dispatcher = dispatcher
        self.finalizer = finalizer
        self.replyHandler = replyHandler
        self.timeoutNanoseconds = min(timeoutNanoseconds, Self.defaultTimeoutNanoseconds)
        self.hideUI = hideUI
        self.forceExit = forceExit
        self.eventRecorder = eventRecorder
    }

    func installDispatcher(_ dispatcher: @escaping Dispatcher) {
        guard !terminationIsPending, !terminationHasCompleted else { return }
        self.dispatcher = dispatcher
    }

    func installQuitObserver(_ observer: @escaping () -> Void) {
        guard !isQuitting else { return }
        onQuit = observer
    }

    func installFinalizer(_ finalizer: @escaping Finalizer) {
        guard !terminationHasCompleted, !finalizerHasRun else { return }
        self.finalizer = finalizer
    }

    func finalizeTerminationResourcesIfNeeded() {
        guard terminationHasCompleted, !finalizerHasRun else { return }
        finalizerHasRun = true
        finalizer?()
    }

    func requestTermination() -> NSApplication.TerminateReply {
        guard !terminationHasCompleted else { return .terminateNow }
        guard !terminationIsPending else { return .terminateLater }
        terminationIsPending = true
        isQuitting = true
        started = .now
        let id = attemptID
        let recorder = eventRecorder
        let exit = forceExit
        let timeout = timeoutNanoseconds
        // Arm before touching UI, admission locks or finalizers. It stays armed
        // through AppKit termination hooks, which may themselves be blocked.
        watchdog = QuitWatchdog(nanoseconds: timeout) {
            Self.logger.error("Quit deadline expired; forcing process exit")
            recorder(.init(attemptID: id, phase: "forced_timeout", participant: "unknown",
                code: "timeout", elapsedMS: Int(timeout / 1_000_000), forced: true, activeOperations: -1))
            exit()
        }
        record(phase: "requested")
        hideUI()
        onQuit?()
        guard let dispatcher else {
            record(phase: "failed", code: "configuration_missing")
            return .terminateLater
        }
        Task { [weak self] in
            do {
                try await dispatcher()
                self?.completeTerminationIfNeeded()
            } catch {
                // Quit is committed. Never reopen admission or retry old UI.
                self?.record(phase: "failed", code: "preparation_failed")
            }
        }
        return .terminateLater
    }

    func recordParticipant(_ participant: String, completed: Bool) {
        guard isQuitting, !terminationHasCompleted, watchdog?.hasFired != true else { return }
        record(phase: completed ? "participant_completed" : "participant_started", participant: participant)
    }

    private func record(phase: String, participant: String = "app", code: String = "none") {
        let elapsed = started.duration(to: .now).components
        eventRecorder(.init(attemptID: attemptID, phase: phase, participant: participant, code: code,
            elapsedMS: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
            forced: false, activeOperations: -1))
        Self.logger.info("Quit phase=\(phase, privacy: .public) participant=\(participant, privacy: .public) code=\(code, privacy: .public)")
    }

    private func completeTerminationIfNeeded() {
        guard terminationIsPending, !terminationHasCompleted, watchdog?.hasFired != true else { return }
        terminationIsPending = false
        terminationHasCompleted = true
        finalizeTerminationResourcesIfNeeded()
        guard watchdog?.hasFired != true else { return }
        record(phase: "graceful")
        replyHandler(true)
    }
}
