import BlocksCore
import Combine
import Foundation
import ServiceManagement

struct ActionBrokerEmbeddedServiceValidator {
    let bundleURL: URL
    let fileManager: FileManager

    init(bundleURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func isAvailable() -> Bool {
        let plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(BlocksActionBrokerXPC.launchAgentPlistName, isDirectory: false)
        guard fileManager.isReadableFile(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              dictionary["Label"] as? String == BlocksActionBrokerXPC.launchAgentLabel,
              let bundleProgram = dictionary["BundleProgram"] as? String,
              !bundleProgram.isEmpty,
              !bundleProgram.hasPrefix("/"),
              let machServices = dictionary["MachServices"] as? [String: Any],
              machServices[BlocksActionBrokerXPC.machServiceName] as? Bool == true else {
            return false
        }

        let executableURL = bundleURL.appendingPathComponent(bundleProgram, isDirectory: false).standardizedFileURL
        guard executableURL.path.hasPrefix(bundleURL.path + "/"),
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            return false
        }
        return true
    }
}

@MainActor
struct ActionBrokerServiceControl {
    let status: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () throws -> Void

    init(service: SMAppService) {
        status = { service.status }
        register = { try service.register() }
        unregister = { try service.unregister() }
    }

    init(
        status: @escaping () -> SMAppService.Status,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
    }
}

struct ActionBrokerRetryPolicy: Equatable {
    let delays: [Duration]
    let healthCheckDelay: Duration

    init(
        delays: [Duration],
        healthCheckDelay: Duration = .seconds(30)
    ) {
        self.delays = delays
        self.healthCheckDelay = healthCheckDelay
    }

    static let `default` = Self(
        delays: [.milliseconds(250), .seconds(1), .seconds(3)],
        healthCheckDelay: .seconds(30)
    )
}

typealias ActionBrokerRetryScheduler = (
    _ delay: Duration,
    _ action: @escaping @MainActor () -> Void
) -> AnyCancellable

@MainActor
final class ActionBrokerServiceManager: ObservableObject {
    enum State: Equatable {
        case disabled
        case requiresApproval
        case connecting
        case reconnecting
        case recovering
        case enabled
        case unavailable
        case failed(String)
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var isServiceRegistered = false

    private let service: ActionBrokerServiceControl
    private let host: any ActionBrokerHosting
    private let embeddedServiceAvailable: Bool
    private let retryPolicy: ActionBrokerRetryPolicy
    private let retryScheduler: ActionBrokerRetryScheduler
    private var hostAttempt = 0
    private var successfulHostAttempt: Int?
    private var hostIsActive = false
    private var retryAttempt = 0
    private var reconnectTask: AnyCancellable?

    init(
        screenshotStore: ScreenshotStore,
        historyService: ScreenshotHistoryActionService,
        translationSourceService: TranslationSourceManagementService,
        pluginDevelopmentService: PluginDevelopmentService
    ) {
        service = ActionBrokerServiceControl(
            service: SMAppService.agent(plistName: BlocksActionBrokerXPC.launchAgentPlistName)
        )
        embeddedServiceAvailable = ActionBrokerEmbeddedServiceValidator().isAvailable()
        host = ScreenshotActionHost(
            screenshotStore: screenshotStore,
            historyService: historyService,
            translationSourceService: translationSourceService,
            pluginDevelopmentService: pluginDevelopmentService
        )
        retryPolicy = .default
        retryScheduler = Self.liveRetryScheduler
        refresh()
    }

    /// Test seam: exercises the registration and retry state machine without
    /// registering a real SMAppService or opening an XPC connection.
    init(
        service: ActionBrokerServiceControl,
        host: some ActionBrokerHosting,
        embeddedServiceAvailable: Bool = true,
        retryPolicy: ActionBrokerRetryPolicy = .default,
        retryScheduler: @escaping ActionBrokerRetryScheduler
    ) {
        self.service = service
        self.host = host
        self.embeddedServiceAvailable = embeddedServiceAvailable
        self.retryPolicy = retryPolicy
        self.retryScheduler = retryScheduler
        refresh()
    }

    deinit {
        reconnectTask?.cancel()
    }

    /// This remains the Switch value: it reports LaunchAgent registration, not
    /// whether the App host has completed its independent XPC registration.
    var isEnabled: Bool { isServiceRegistered }

    func setEnabled(_ enabled: Bool) {
        guard embeddedServiceAvailable else {
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            state = .unavailable
            return
        }
        do {
            if enabled {
                try service.register()
                refresh()
            } else {
                try service.unregister()
                cancelReconnectAndStopHost()
                isServiceRegistered = false
                state = .disabled
            }
        } catch {
            if enabled {
                recoverAfterRegisterFailure(error)
            } else {
                recoverAfterUnregisterFailure(error)
            }
        }
    }

    func refresh() {
        guard embeddedServiceAvailable else {
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            state = .unavailable
            return
        }

        switch service.status() {
        case .enabled:
            isServiceRegistered = true
            startHost(
                isReconnect: state == .reconnecting || state == .recovering || retryAttempt > 0,
                isHealthCheck: state == .recovering
            )
        case .requiresApproval:
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            state = .requiresApproval
        case .notRegistered, .notFound:
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            state = .disabled
        @unknown default:
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            state = .unavailable
        }
    }

    static func resolvedState(
        for status: SMAppService.Status,
        embeddedServiceAvailable: Bool
    ) -> State {
        switch status {
        case .enabled: .connecting
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound:
            embeddedServiceAvailable ? .disabled : .unavailable
        @unknown default: .unavailable
        }
    }

    private func startHost(isReconnect: Bool, isHealthCheck: Bool = false) {
        guard isServiceRegistered, reconnectTask == nil, !hostIsActive else { return }
        hostAttempt &+= 1
        let attempt = hostAttempt
        hostIsActive = true
        state = isHealthCheck ? .recovering : (isReconnect ? .reconnecting : .connecting)
        host.start(
            completion: { [weak self] result in
                guard let self, self.isCurrentHostAttempt(attempt) else { return }
                switch result {
                case .success:
                    self.retryAttempt = 0
                    self.successfulHostAttempt = attempt
                    self.state = .enabled
                case let .failure(error):
                    self.hostIsActive = false
                    self.scheduleReconnect(after: error)
                }
            },
            onInvalidated: { [weak self] in
                guard let self, self.isCurrentHostAttempt(attempt) else { return }
                self.hostIsActive = false
                self.scheduleReconnect(after: ScreenshotActionBrokerConnectionError.invalidated)
            }
        )
    }

    private func scheduleReconnect(after error: Error) {
        guard isServiceRegistered, reconnectTask == nil else { return }
        let isHealthCheck = retryAttempt >= retryPolicy.delays.count
        let delay: Duration
        if isHealthCheck {
            delay = retryPolicy.healthCheckDelay
            state = .recovering
        } else {
            delay = retryPolicy.delays[retryAttempt]
            retryAttempt += 1
            state = .reconnecting
        }
        reconnectTask = retryScheduler(delay) { [weak self] in
            guard let self else { return }
            self.reconnectTask = nil
            guard self.service.status() == .enabled else {
                self.refresh()
                return
            }
            self.isServiceRegistered = true
            self.startHost(isReconnect: true, isHealthCheck: isHealthCheck)
        }
    }

    private func isCurrentHostAttempt(_ attempt: Int) -> Bool {
        isServiceRegistered && attempt == hostAttempt
    }

    private func cancelReconnectAndStopHost() {
        reconnectTask?.cancel()
        reconnectTask = nil
        hostAttempt &+= 1
        hostIsActive = false
        retryAttempt = 0
        host.stop()
    }

    private func recoverAfterRegisterFailure(_ error: Error) {
        guard service.status() == .enabled else {
            refresh()
            return
        }

        isServiceRegistered = true
        let hostAttemptBeforeRecovery = hostAttempt
        if !hostIsActive, reconnectTask == nil {
            startHost(isReconnect: true)
        }
        guard !(hostAttempt != hostAttemptBeforeRecovery && successfulHostAttempt == hostAttempt) else {
            return
        }
        state = .failed(error.localizedDescription)
    }

    private func recoverAfterUnregisterFailure(_ error: Error) {
        guard service.status() == .enabled else {
            refresh()
            return
        }

        isServiceRegistered = true
        let hostAttemptBeforeRecovery = hostAttempt
        if !hostIsActive, reconnectTask == nil {
            startHost(isReconnect: true)
        }
        guard !(hostAttempt != hostAttemptBeforeRecovery && successfulHostAttempt == hostAttempt) else {
            return
        }
        state = .failed(error.localizedDescription)
    }

    private static let liveRetryScheduler: ActionBrokerRetryScheduler = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return AnyCancellable { task.cancel() }
    }
}

private enum ScreenshotActionBrokerConnectionError: LocalizedError {
    case invalidated

    var errorDescription: String? {
        "The Action Broker connection was interrupted."
    }
}
