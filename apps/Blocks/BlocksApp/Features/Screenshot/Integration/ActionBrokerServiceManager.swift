import BlocksCore
import Combine
import Foundation
import ServiceManagement
import Darwin

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
    static let appOwnedPreferenceKey = "blocks.dev.cli.appOwnedEnabled"

    static func appOwned(defaults: UserDefaults = .standard, inheritedIntent: Bool) -> Self {
        if defaults.object(forKey: appOwnedPreferenceKey) == nil {
            defaults.set(inheritedIntent, forKey: appOwnedPreferenceKey)
        }
        return Self(
            status: { defaults.bool(forKey: appOwnedPreferenceKey) ? .enabled : .notRegistered },
            register: { defaults.set(true, forKey: appOwnedPreferenceKey) },
            unregister: { defaults.set(false, forKey: appOwnedPreferenceKey) }
        )
    }
    let status: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () throws -> Void
    let unregisterAndWait: () async throws -> Void

    init(service: SMAppService) {
        status = { service.status }
        register = { try service.register() }
        unregister = { try service.unregister() }
        // The async SMAppService variant completes after the running job has
        // been killed; the synchronous variant explicitly does not wait.
        unregisterAndWait = { try await service.unregister() }
    }

    init(
        status: @escaping () -> SMAppService.Status,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void,
        unregisterAndWait: (() async throws -> Void)? = nil
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        self.unregisterAndWait = unregisterAndWait ?? { try unregister() }
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
    @Published private(set) var enabledModules: Set<CLIModule> = []
    let moduleAccess: CLIModuleAccessPolicy

    func isModuleEnabled(_ module: CLIModule) -> Bool { moduleAccess.isEnabled(module) }

    func setModuleEnabled(_ module: CLIModule, enabled: Bool) {
        guard !isQuitting, !applicationUpdatePaused, serviceChangeTask == nil else { return }
        moduleAccess.setEnabled(enabled, for: module)
        enabledModules = Set(CLIModule.allCases.filter(moduleAccess.isEnabled))
        if enabled { setEnabled(true) }
        else { host.revokeModule(module) }
    }

    private let service: ActionBrokerServiceControl
    let usesAppOwnedService: Bool
    private let legacyServiceStatus: () -> SMAppService.Status
    var hasLegacyServiceRegistration: Bool {
        usesAppOwnedService && (legacyServiceStatus() == .enabled || legacyServiceStatus() == .requiresApproval)
    }
    private let host: any ActionBrokerHosting
    private let embeddedServiceAvailable: Bool
    private let retryPolicy: ActionBrokerRetryPolicy
    private let retryScheduler: ActionBrokerRetryScheduler
    private var hostAttempt = 0
    private var successfulHostAttempt: Int?
    private var hostIsActive = false
    private var retryAttempt = 0
    private var reconnectTask: AnyCancellable?
    private var applicationUpdatePaused = false
    private let applicationManagementGate = ApplicationOperationAdmissionGate(name: "Action Broker management")
    private let updateRecoveryJournal: ActionBrokerUpdateRecoveryJournal
    private let updateRecoveryStorageAvailable: Bool
    private let runningBrokerProcessIDs: () throws -> [Int32]
    private let processHasExited: (Int32) -> Bool
    private var updateRecoveryTicket: ActionBrokerUpdateRecoveryTicket?
    private var updateRecoveryTask: Task<Void, Never>?
    private(set) var serviceChangeTask: Task<Void, Never>?
    private var updateRecoveryFailureMessage: String?
    private var isQuitting = false
    private var recoveryGeneration = 0

    /// No service unregister, journal mutation or remote recovery on ordinary
    /// quit. Fence suspended callbacks before closing local admission.
    func beginApplicationQuit() {
        isQuitting = true
        recoveryGeneration += 1
        updateRecoveryTask?.cancel()
        updateRecoveryTask = nil
        serviceChangeTask?.cancel()
        applicationUpdatePaused = true
        reconnectTask?.cancel()
        reconnectTask = nil
        hostAttempt &+= 1
    }

    func prepareForApplicationUpdate(stopService: Bool = true) async throws {
        // Migrating an old registered LaunchAgent still needs an authenticated
        // drain. A socket timeout or missing PID is not authority to kill it.
        if stopService, hasLegacyServiceRegistration { throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration }
        // The update coordinator must not resume or consume an explicit
        // disable transaction that is currently awaiting the remote peer.
        if stopService, serviceChangeTask != nil { throw ActionBrokerUpdateError.invalidRecoveryState }
        try await prepareServiceRemoval(stopService: stopService)
    }

    private func prepareServiceRemoval(stopService: Bool = true) async throws {
        if stopService, updateRecoveryTask != nil { throw ActionBrokerUpdateError.invalidRecoveryState }
        try applicationManagementGate.pauseIfIdle()
        applicationUpdatePaused = true
        try await host.pauseAndDrainForApplicationUpdate()
        guard stopService else { return }
        if usesAppOwnedService {
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            return
        }
        guard updateRecoveryStorageAvailable else { throw ActionBrokerUpdateError.invalidRecoveryState }
        guard try updateRecoveryJournal.load() == nil else { throw ActionBrokerUpdateError.invalidRecoveryState }
        guard service.status() == .enabled else {
            // An unregistered/approval-denied job cannot launch on demand, but
            // do not ignore an already lingering binary from an older install.
            guard try runningBrokerProcessIDs().isEmpty else { throw ActionBrokerUpdateError.serviceDidNotStop }
            return
        }
        var ticket = ActionBrokerUpdateRecoveryTicket()
        updateRecoveryTicket = ticket
        // Persist enabled intent before the first remote pause or SM mutation.
        try updateRecoveryJournal.save(ticket)
        ticket.processID = try await host.prepareBrokerForApplicationUpdate(token: ticket.token)
        updateRecoveryTicket = ticket
        try updateRecoveryJournal.save(ticket)
        try Task.checkCancellation()
        // The Broker has atomically closed all submit/cancel/register admission
        // and proved zero active requests. Only now is stopping its job safe.
        try await service.unregisterAndWait()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let registrationRemoved = service.status() == .notRegistered || service.status() == .notFound
            if registrationRemoved, let processID = ticket.processID, processHasExited(processID),
               try runningBrokerProcessIDs().isEmpty {
                cancelReconnectAndStopHost()
                isServiceRegistered = false
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ActionBrokerUpdateError.serviceDidNotStop
    }

    func resumeAfterCancelledApplicationUpdate() async {
        guard serviceChangeTask == nil else { return }
        await restoreServiceAfterUpdate()
    }

    init(
        screenshotStore: ScreenshotStore,
        historyService: ScreenshotHistoryActionService,
        translationSourceService: TranslationSourceManagementService,
        pluginDevelopmentService: PluginDevelopmentService,
        clipboardStore: ClipboardStore? = nil
    ) {
        let moduleAccess = CLIModuleAccessPolicy()
        self.moduleAccess = moduleAccess
        enabledModules = Set(CLIModule.allCases.filter(moduleAccess.isEnabled))
        let legacy = SMAppService.agent(plistName: BlocksActionBrokerXPC.launchAgentPlistName)
        #if BLOCKS_LOCAL_DEVELOPMENT
        usesAppOwnedService = true
        legacyServiceStatus = { legacy.status }
        let storageForIntent = try? StorageEnvironment.appSupport()
        let oldJournal = ActionBrokerUpdateRecoveryJournal(url: storageForIntent?.rootDirectory
            .appendingPathComponent("ActionBrokerUpdateRecovery.json"))
        service = .appOwned(inheritedIntent: legacy.status == .enabled || legacy.status == .requiresApproval
            || (try? oldJournal.load()) != nil)
        embeddedServiceAvailable = true
        #else
        usesAppOwnedService = false
        legacyServiceStatus = { .notRegistered }
        service = ActionBrokerServiceControl(service: legacy)
        embeddedServiceAvailable = ActionBrokerEmbeddedServiceValidator().isAvailable()
        #endif
        host = ScreenshotActionHost(
            screenshotStore: screenshotStore,
            historyService: historyService,
            translationSourceService: translationSourceService,
            pluginDevelopmentService: pluginDevelopmentService,
            clipboardStore: clipboardStore,
            moduleAccess: moduleAccess
        )
        retryPolicy = .default
        retryScheduler = Self.liveRetryScheduler
        let storage = try? StorageEnvironment.appSupport()
        updateRecoveryStorageAvailable = storage != nil
        updateRecoveryJournal = ActionBrokerUpdateRecoveryJournal(url: storage?.rootDirectory
            .appendingPathComponent("ActionBrokerUpdateRecovery.json"))
        runningBrokerProcessIDs = Self.currentBrokerProcessIDs
        processHasExited = { kill($0, 0) != 0 && errno == ESRCH }
        if !beginStartupUpdateRecoveryIfNeeded() { refresh() }
    }

    /// Test seam: exercises the registration and retry state machine without
    /// registering a real SMAppService or opening an XPC connection.
    init(
        service: ActionBrokerServiceControl,
        host: some ActionBrokerHosting,
        embeddedServiceAvailable: Bool = true,
        retryPolicy: ActionBrokerRetryPolicy = .default,
        retryScheduler: @escaping ActionBrokerRetryScheduler,
        updateRecoveryJournal: ActionBrokerUpdateRecoveryJournal = .init(),
        runningBrokerProcessIDs: @escaping () throws -> [Int32] = { [] },
        processHasExited: @escaping (Int32) -> Bool = { _ in true },
        moduleAccess: CLIModuleAccessPolicy? = nil,
        usesAppOwnedService: Bool = false,
        legacyServiceStatus: @escaping () -> SMAppService.Status = { .notRegistered }
    ) {
        // Isolated tests may inject their own policy through the additional
        // initializer argument; no module defaults are written by this path.
        let policy = moduleAccess ?? CLIModuleAccessPolicy()
        self.moduleAccess = policy
        enabledModules = Set(CLIModule.allCases.filter(policy.isEnabled))
        self.service = service
        self.usesAppOwnedService = usesAppOwnedService
        self.legacyServiceStatus = legacyServiceStatus
        self.host = host
        self.embeddedServiceAvailable = embeddedServiceAvailable
        self.retryPolicy = retryPolicy
        self.retryScheduler = retryScheduler
        self.updateRecoveryJournal = updateRecoveryJournal
        self.updateRecoveryStorageAvailable = true
        self.runningBrokerProcessIDs = runningBrokerProcessIDs
        self.processHasExited = processHasExited
        if !beginStartupUpdateRecoveryIfNeeded() { refresh() }
    }

    deinit {
        reconnectTask?.cancel()
    }

    /// Temporary update unregistration must not turn the user's enabled
    /// preference off. The journal preserves that intent across app relaunch.
    var isEnabled: Bool {
        usesAppOwnedService ? service.status() == .enabled : isServiceRegistered || updateRecoveryTicket != nil
    }

    private func beginStartupUpdateRecoveryIfNeeded() -> Bool {
        if usesAppOwnedService {
            // Intent was imported once into the local preference. Never resume
            // an obsolete Broker just to bring up the new in-process endpoint.
            if !hasLegacyServiceRegistration { try? updateRecoveryJournal.clear() }
            return false
        }
        do {
            guard let ticket = try updateRecoveryJournal.load() else { return false }
            updateRecoveryTicket = ticket
            state = .recovering
            // Main-actor synchronous journal/register mutations cannot interleave
            // with quit. The remote wait must not hold a business admission lease.
            updateRecoveryTask = Task { @MainActor [weak self] in
                await self?.restoreServiceAfterUpdate()
                self?.updateRecoveryTask = nil
            }
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return true
        }
    }

    private func restoreServiceAfterUpdate() async {
        guard !isQuitting else { return }
        if usesAppOwnedService {
            applicationUpdatePaused = false
            applicationManagementGate.resume()
            // A busy drain has not stopped the host. Stopping it here would
            // revoke the very work that made disabling unsafe. If preparation
            // did stop it, refresh() observes hostIsActive == false and restarts.
            host.resumeAfterCancelledApplicationUpdate()
            refresh()
            return
        }
        let generation = recoveryGeneration
        do {
            let recoveredTicket: ActionBrokerUpdateRecoveryTicket?
            if let updateRecoveryTicket { recoveredTicket = updateRecoveryTicket }
            else { recoveredTicket = try updateRecoveryJournal.load() }
            if let ticket = recoveredTicket {
                updateRecoveryTicket = ticket
                if service.status() != .enabled { try service.register() }
                guard service.status() == .enabled else { throw ActionBrokerUpdateError.requiresApproval }
                try await host.resumeBrokerAfterCancelledApplicationUpdate(token: ticket.token)
                guard !isQuitting, recoveryGeneration == generation else { return }
                try Task.checkCancellation()
                try updateRecoveryJournal.clear()
                updateRecoveryTicket = nil
            }
            updateRecoveryFailureMessage = nil
            applicationUpdatePaused = false
            applicationManagementGate.resume()
            cancelReconnectAndStopHost()
            host.resumeAfterCancelledApplicationUpdate()
            refresh()
        } catch {
            guard !isQuitting, recoveryGeneration == generation else { return }
            updateRecoveryFailureMessage = error.localizedDescription
            applicationUpdatePaused = false
            applicationManagementGate.resume()
            cancelReconnectAndStopHost()
            host.resumeAfterCancelledApplicationUpdate()
            isServiceRegistered = service.status() == .enabled
            // A failed update must not needlessly disable the old, still
            // registered CLI host. Keep it usable while retaining the error
            // and recovery ticket; this does not declare the update complete.
            if isServiceRegistered { refresh() }
            state = service.status() == .requiresApproval ? .requiresApproval : .failed(error.localizedDescription)
            // Keep the recovery ticket and enabled intent for a later retry.
        }
    }

    private static func currentBrokerProcessIDs() throws -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw ActionBrokerUpdateError.serviceDidNotStop }
        var processes = [Int32](repeating: 0, count: Int(count) + 64)
        let received = processes.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard received > 0, Int(received) < processes.count else { throw ActionBrokerUpdateError.serviceDidNotStop }
        let expectedPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BlocksActionBroker").standardizedFileURL.path
        return processes.prefix(Int(received)).filter { processID in
            guard processID > 0 else { return false }
            // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
            // that macro is not imported by this Swift SDK.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return String(cString: buffer) == expectedPath
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isQuitting, !applicationUpdatePaused, serviceChangeTask == nil, updateRecoveryTask == nil else { return }
        if !enabled, embeddedServiceAvailable {
            // A user disabling CLI integration has not authorized interrupting
            // a write. Reuse the authenticated idle proof and async SM removal.
            serviceChangeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.serviceChangeTask = nil }
                await self.disableServiceSafely()
            }
            return
        }
        guard let lease = applicationManagementGate.begin() else { return }
        defer { lease.release() }
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
            }
        } catch {
            recoverAfterRegisterFailure(error)
        }
    }

    private func disableServiceSafely() async {
        let generation = recoveryGeneration
        do {
            try Task.checkCancellation()
            try await prepareServiceRemoval()
            guard !isQuitting, generation == recoveryGeneration else { return }
            try Task.checkCancellation()
            if usesAppOwnedService {
                try await service.unregisterAndWait()
                cancelReconnectAndStopHost()
                isServiceRegistered = false
                applicationUpdatePaused = false
                applicationManagementGate.resume()
                host.resumeAfterCancelledApplicationUpdate()
                state = .disabled
                return
            }
            if service.status() == .requiresApproval {
                // Cancelling a pending registration is an explicit user action.
                // It has no runnable job, but a lingering old binary still makes
                // removal unsafe and must not be killed without an idle proof.
                guard try runningBrokerProcessIDs().isEmpty else { throw ActionBrokerUpdateError.serviceDidNotStop }
                try await service.unregisterAndWait()
                guard !isQuitting, generation == recoveryGeneration else { return }
                try Task.checkCancellation()
                guard try runningBrokerProcessIDs().isEmpty else { throw ActionBrokerUpdateError.serviceDidNotStop }
            }
            guard service.status() == .notRegistered || service.status() == .notFound else {
                throw ActionBrokerUpdateError.requiresApproval
            }
            // Explicit disable consumes saved enabled intent only after the
            // service is gone. Module authorization preferences are untouched.
            try updateRecoveryJournal.clear()
            updateRecoveryTicket = nil
            updateRecoveryFailureMessage = nil
            cancelReconnectAndStopHost()
            isServiceRegistered = false
            applicationUpdatePaused = false
            applicationManagementGate.resume()
            host.resumeAfterCancelledApplicationUpdate()
            state = .disabled
        } catch {
            guard !isQuitting, generation == recoveryGeneration else { return }
            // Cancellation of the attempted disable must not cancel the
            // authenticated resume command needed to undo its remote pause.
            // Track this independent task so quit still cancels/fences it.
            let recovery = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.restoreServiceAfterUpdate()
            }
            updateRecoveryTask = recovery
            await recovery.value
            guard !isQuitting, generation == recoveryGeneration else { return }
            updateRecoveryTask = nil
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() {
        guard !applicationUpdatePaused else { return }
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
        guard !applicationUpdatePaused, applicationManagementGate.isAcceptingOperations else { return }
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
                    self.state = self.updateRecoveryFailureMessage.map(State.failed) ?? .enabled
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
        guard !applicationUpdatePaused, isServiceRegistered, reconnectTask == nil else { return }
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
        !applicationUpdatePaused && isServiceRegistered && attempt == hostAttempt
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
