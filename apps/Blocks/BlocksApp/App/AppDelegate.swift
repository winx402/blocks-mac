import AppKit
import BlocksCore

@MainActor
final class AppTerminationCoordinator {
    typealias Dispatcher = () async -> Void
    typealias Finalizer = () -> Void
    typealias TimeoutSleeper = (UInt64) async -> Void
    typealias ReplyHandler = (Bool) -> Void

    static let shared = AppTerminationCoordinator(
        replyHandler: { shouldTerminate in
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    )

    static let defaultTimeoutNanoseconds: UInt64 = 1_500_000_000

    private let timeoutNanoseconds: UInt64
    private let timeoutSleeper: TimeoutSleeper
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
        self.timeoutNanoseconds = timeoutNanoseconds
        self.timeoutSleeper = timeoutSleeper
        self.replyHandler = replyHandler
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
        guard !finalizerHasRun else { return }
        finalizerHasRun = true
        finalizer?()
    }

    func requestTermination() -> NSApplication.TerminateReply {
        guard !terminationHasCompleted else { return .terminateNow }
        guard !terminationIsPending else { return .terminateLater }
        guard let dispatcher else { return .terminateNow }

        terminationIsPending = true
        Task { [weak self] in
            await dispatcher()
            self?.completeTerminationIfNeeded()
        }
        Task { [weak self] in
            guard let self else { return }
            await timeoutSleeper(timeoutNanoseconds)
            completeTerminationIfNeeded()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard BlocksRuntimeEnvironment.isUnitTestHost else { return }
        NSApp.windows
            .filter {
                $0.isVisible
                    && $0.parent == nil
                    && $0.level == .normal
                    && !($0 is NSPanel)
            }
            .forEach { window in
                window.animationBehavior = .none
                window.orderOut(nil)
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppTerminationCoordinator.shared.finalizeTerminationResourcesIfNeeded()
        ClipboardBrokerDataTransport.finalizeRoot()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.requestTermination()
    }
}
