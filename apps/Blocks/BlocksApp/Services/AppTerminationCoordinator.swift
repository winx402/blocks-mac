import AppKit

@MainActor
final class AppTerminationCoordinator {
    typealias Dispatcher = () async throws -> Void
    typealias Finalizer = () -> Void
    typealias TimeoutSleeper = (UInt64) async -> Void
    typealias ReplyHandler = (Bool) -> Void

    static let shared = AppTerminationCoordinator(
        replyHandler: { NSApp.reply(toApplicationShouldTerminate: $0) }
    )
    static let defaultTimeoutNanoseconds: UInt64 = 1_500_000_000

    private let replyHandler: ReplyHandler
    private var dispatcher: Dispatcher?
    private var finalizer: Finalizer?
    private var terminationIsPending = false
    private var terminationHasCompleted = false
    private var finalizerHasRun = false

    init(
        dispatcher: Dispatcher? = nil,
        finalizer: Finalizer? = nil,
        timeoutNanoseconds: UInt64 = 1_500_000_000,
        timeoutSleeper: @escaping TimeoutSleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        replyHandler: @escaping ReplyHandler
    ) {
        self.dispatcher = dispatcher
        self.finalizer = finalizer
        self.replyHandler = replyHandler
        // Keep the old initializer source-compatible, but do not use elapsed
        // time as permission to interrupt work or finalize its resources.
        _ = timeoutNanoseconds
        _ = timeoutSleeper
    }

    func installDispatcher(_ dispatcher: @escaping Dispatcher) {
        guard !terminationIsPending, !terminationHasCompleted else { return }
        self.dispatcher = dispatcher
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
        guard let dispatcher else { return .terminateCancel }
        terminationIsPending = true
        Task { [weak self] in
            do {
                try await dispatcher()
                self?.completeTerminationIfNeeded()
            } catch {
                guard let self, terminationIsPending else { return }
                terminationIsPending = false
                replyHandler(false)
            }
        }
        return .terminateLater
    }

    private func completeTerminationIfNeeded() {
        guard terminationIsPending, !terminationHasCompleted else { return }
        terminationIsPending = false
        terminationHasCompleted = true
        finalizeTerminationResourcesIfNeeded()
        replyHandler(true)
    }
}
