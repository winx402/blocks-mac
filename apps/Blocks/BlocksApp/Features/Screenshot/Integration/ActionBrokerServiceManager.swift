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

/// A PID alone can be reused while the app is not running. Recovery is allowed
/// to address only the kernel lifetime authenticated before the remote pause.
struct ActionBrokerLegacyProcessIdentity: Codable, Equatable, Sendable {
    let processID: Int32
    let startSeconds: Int64
    let startMicroseconds: Int64

    var isValid: Bool { processID > 0 && startSeconds > 0 && (0..<1_000_000).contains(startMicroseconds) }
}

struct ActionBrokerLegacyMigrationTicket: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case preparing, unregisterStarted }
    let schemaVersion: Int
    let serviceLabel: String
    let token: String
    let identity: ActionBrokerLegacyProcessIdentity
    let owner: ActionBrokerLegacyProcessIdentity
    var phase: Phase

    init(token: String = UUID().uuidString, identity: ActionBrokerLegacyProcessIdentity,
         owner: ActionBrokerLegacyProcessIdentity, phase: Phase = .preparing) {
        schemaVersion = 2
        serviceLabel = BlocksActionBrokerXPC.launchAgentLabel
        self.token = token
        self.identity = identity
        self.owner = owner
        self.phase = phase
    }

    var isValid: Bool {
        schemaVersion == 2 && serviceLabel == BlocksActionBrokerXPC.launchAgentLabel
            && UUID(uuidString: token) != nil && identity.isValid && owner.isValid
    }

    func canReplace(_ existing: Self) -> Bool {
        schemaVersion == existing.schemaVersion && serviceLabel == existing.serviceLabel
            && token == existing.token && identity == existing.identity && owner == existing.owner
            && (phase == existing.phase || existing.phase == .preparing && phase == .unregisterStarted)
    }
}

/// Deliberately separate from the official update journal: migration recovery
/// must never interpret saved intent as permission to register the old agent.
final class ActionBrokerLegacyMigrationJournal {
    private let url: URL?
    private var memoryTicket: ActionBrokerLegacyMigrationTicket?

    init(url: URL? = nil) { self.url = url }

    func load() throws -> ActionBrokerLegacyMigrationTicket? {
        guard url != nil else { return memoryTicket }
        return try withLockedFile { try loadLocked(directory: $0) }
    }

    private func loadLocked(directory: Int32) throws -> ActionBrokerLegacyMigrationTicket? {
        let descriptor = openat(directory, url!.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 4096 else { throw ActionBrokerUpdateError.invalidRecoveryState }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 4097), data.count <= 4096,
              let ticket = try? JSONDecoder().decode(ActionBrokerLegacyMigrationTicket.self, from: data),
              ticket.isValid else { throw ActionBrokerUpdateError.invalidRecoveryState }
        return ticket
    }

    func save(_ ticket: ActionBrokerLegacyMigrationTicket) throws {
        guard ticket.isValid else { throw ActionBrokerUpdateError.invalidRecoveryState }
        guard let url else {
            if let memoryTicket, !ticket.canReplace(memoryTicket) { throw ActionBrokerUpdateError.invalidRecoveryState }
            memoryTicket = ticket
            return
        }
        try withLockedFile { directory in
            if let existing = try loadLocked(directory: directory), !ticket.canReplace(existing) {
                throw ActionBrokerUpdateError.invalidRecoveryState
            }
            try saveLocked(ticket, directory: directory, fileName: url.lastPathComponent)
        }
    }

    /// Startup proves the old owner ended, then atomically claims that exact
    /// ticket. Two replacement Apps cannot both adopt the dead owner's token.
    func claim(expected ticket: ActionBrokerLegacyMigrationTicket,
               newOwner: ActionBrokerLegacyProcessIdentity) throws -> ActionBrokerLegacyMigrationTicket {
        let claimed = ActionBrokerLegacyMigrationTicket(token: ticket.token, identity: ticket.identity,
            owner: newOwner, phase: ticket.phase)
        guard claimed.isValid else { throw ActionBrokerUpdateError.invalidRecoveryState }
        guard let url else {
            guard memoryTicket == ticket else { throw ActionBrokerUpdateError.invalidRecoveryState }
            memoryTicket = claimed
            return claimed
        }
        return try withLockedFile { directory in
            guard try loadLocked(directory: directory) == ticket else { throw ActionBrokerUpdateError.invalidRecoveryState }
            try saveLocked(claimed, directory: directory, fileName: url.lastPathComponent)
            return claimed
        }
    }

    private func saveLocked(_ ticket: ActionBrokerLegacyMigrationTicket, directory: Int32, fileName: String) throws {
        // The stable lock covers conflict/ownership checks through publication.
        let temporary = ".legacy-migration-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
        defer { _ = close(descriptor); _ = unlinkat(directory, temporary, 0) }
        let data = try JSONEncoder().encode(ticket)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, fileName) == 0,
              fsync(directory) == 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
    }

    func clear(expected ticket: ActionBrokerLegacyMigrationTicket) throws {
        guard let url else {
            if let memoryTicket, memoryTicket != ticket { throw ActionBrokerUpdateError.invalidRecoveryState }
            memoryTicket = nil
            return
        }
        try withLockedFile { directory in
            guard let existing = try loadLocked(directory: directory) else { return }
            guard existing == ticket else { throw ActionBrokerUpdateError.invalidRecoveryState }
            guard unlinkat(directory, url.lastPathComponent, 0) == 0, fsync(directory) == 0 else {
                throw ActionBrokerUpdateError.invalidRecoveryState
            }
        }
    }

    private func withLockedFile<Value>(_ operation: (Int32) throws -> Value) throws -> Value {
        let url = url!
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
        defer { _ = close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_mode & 0o022 == 0 else {
            throw ActionBrokerUpdateError.invalidRecoveryState
        }
        // Never unlink this lock on clear: replacing the inode would let a
        // concurrent process hold a different lock for the same journal path.
        let descriptor = openat(directory, url.lastPathComponent + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ActionBrokerUpdateError.invalidRecoveryState }
        defer { _ = flock(descriptor, LOCK_UN) }
        // File-only synchronous critical section. Contention fails closed;
        // no lock is held across an XPC wait or SMAppService mutation.
        return try operation(directory)
    }
}

@MainActor
protocol ActionBrokerLegacyMigrationSession: AnyObject {
    var identity: ActionBrokerLegacyProcessIdentity { get }
    func prepare(token: String) async throws
    func resume(token: String) async throws
    func invalidate()
}

typealias ActionBrokerLegacyMigrationConnector = @MainActor (
    _ expectedIdentity: ActionBrokerLegacyProcessIdentity?
) async throws -> any ActionBrokerLegacyMigrationSession

private final class LegacyMigrationReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { defer { self.continuation = nil }; return self.continuation }
        continuation?.resume(with: result)
    }
}

/// Holds one authenticated connection across prepare and cancellation. Unlike
/// the official host adapter, recovery may not reconnect to a replacement PID.
@MainActor
private final class ActionBrokerLegacyMigrationConnection: ActionBrokerLegacyMigrationSession {
    let identity: ActionBrokerLegacyProcessIdentity
    private let connection: NSXPCConnection

    private init(connection: NSXPCConnection, identity: ActionBrokerLegacyProcessIdentity) {
        self.connection = connection
        self.identity = identity
    }

    static func connect(expectedIdentity: ActionBrokerLegacyProcessIdentity?) async throws -> any ActionBrokerLegacyMigrationSession {
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard let requirement = BlocksLocalBuildTrust.connectionRequirement(role: "broker") else {
            throw ActionBrokerUpdateError.untrustedPeer
        }
        if let expectedIdentity, !ActionBrokerServiceManager.legacyProcessMatches(expectedIdentity) {
            throw ActionBrokerUpdateError.untrustedPeer
        }
        let connection = NSXPCConnection(machServiceName: BlocksActionBrokerXPC.machServiceName)
        // Applied before resume: each RPC remains bound to the peer's audit
        // identity and registered CDHash, not just a reusable numeric PID.
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: BlocksActionBrokerHostXPCProtocol.self)
        connection.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let reply = LegacyMigrationReply(continuation)
                connection.invalidationHandler = { reply.finish(.failure(ActionBrokerUpdateError.connectionUnavailable)) }
                connection.interruptionHandler = { reply.finish(.failure(ActionBrokerUpdateError.connectionUnavailable)) }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    reply.finish(.failure(ActionBrokerUpdateError.connectionUnavailable))
                } as? BlocksActionBrokerHostXPCProtocol
                guard let proxy else { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)); return }
                let invoked: Void? = proxy.probeUpdateLifecycle?(withReply: { reply.finish(.success(())) })
                if invoked == nil { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)) }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    reply.finish(.failure(ActionBrokerUpdateError.timedOut))
                }
            }
            try Task.checkCancellation()
            guard !AppTerminationCoordinator.shared.isQuitting,
                  connection.effectiveUserIdentifier == getuid(),
                  BlocksLocalBuildTrust.accepts(processIdentifier: connection.processIdentifier,
                    userIdentifier: connection.effectiveUserIdentifier, role: "broker"),
                  let identity = ActionBrokerServiceManager.legacyProcessIdentity(connection.processIdentifier),
                  expectedIdentity.map({ $0 == identity }) ?? true else { throw ActionBrokerUpdateError.untrustedPeer }
            return Self(connection: connection, identity: identity)
        } catch { connection.invalidate(); throw error }
        #else
        throw ActionBrokerUpdateError.unsupportedPeer
        #endif
    }

    func prepare(token: String) async throws { try await command(token: token, preparing: true) }
    func resume(token: String) async throws { try await command(token: token, preparing: false) }
    func invalidate() { connection.invalidate() }

    private func command(token: String, preparing: Bool) async throws {
        try Task.checkCancellation()
        guard !AppTerminationCoordinator.shared.isQuitting,
              connection.processIdentifier == identity.processID,
              ActionBrokerServiceManager.legacyProcessMatches(identity) else { throw ActionBrokerUpdateError.untrustedPeer }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = LegacyMigrationReply(continuation)
            connection.invalidationHandler = { reply.finish(.failure(ActionBrokerUpdateError.connectionUnavailable)) }
            connection.interruptionHandler = { reply.finish(.failure(ActionBrokerUpdateError.connectionUnavailable)) }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                reply.finish(.failure(ActionBrokerUpdateError.connectionUnavailable))
            } as? BlocksActionBrokerHostXPCProtocol
            guard let proxy else { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)); return }
            let completion: (Bool, String?) -> Void = { accepted, code in
                reply.finish(accepted ? .success(()) : .failure(ActionBrokerUpdateError.rejection(wireCode: code)))
            }
            let invoked: Void? = preparing
                ? proxy.prepareForApplicationUpdate?(token, withReply: completion)
                : proxy.resumeAfterCancelledApplicationUpdate?(token, withReply: completion)
            if invoked == nil { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)) }
            Task {
                try? await Task.sleep(for: .seconds(2))
                reply.finish(.failure(ActionBrokerUpdateError.timedOut))
            }
        }
    }
}

@MainActor
final class ActionBrokerServiceManager: ObservableObject {
    enum State: Equatable {
        case disabled
        case requiresApproval
        case connecting
        case reconnecting
        case recovering
        case recoveryRequired
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
    private let legacyService: ActionBrokerServiceControl
    private let legacyLaunchdJobsAreAbsent: () async throws -> Bool
    private let legacyMigrationJournal: ActionBrokerLegacyMigrationJournal
    private let legacyMigrationConnect: ActionBrokerLegacyMigrationConnector
    private let legacyProcessLifetimeState: @MainActor (ActionBrokerLegacyProcessIdentity) -> LegacyProcessLifetimeState
    private let legacyMigrationOwnerIdentity: @MainActor () -> ActionBrokerLegacyProcessIdentity?
    private let legacyMigrationVerificationTimeout: Duration
    private var legacyMigrationTicket: ActionBrokerLegacyMigrationTicket?
    private var legacyMigrationSession: (any ActionBrokerLegacyMigrationSession)?
    var hasLegacyServiceRegistration: Bool {
        usesAppOwnedService && (legacyService.status() == .enabled || legacyService.status() == .requiresApproval)
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
        legacyMigrationSession?.invalidate()
        legacyMigrationSession = nil
        applicationUpdatePaused = true
        reconnectTask?.cancel()
        reconnectTask = nil
        hostAttempt &+= 1
    }

    func prepareForApplicationUpdate(stopService: Bool = true) async throws {
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
            try await retireLegacyService()
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
        legacyService = ActionBrokerServiceControl(service: legacy)
        legacyLaunchdJobsAreAbsent = Self.currentLegacyLaunchdJobsAreAbsent
        #if BLOCKS_LOCAL_DEVELOPMENT
        usesAppOwnedService = true
        let storageForIntent = try? StorageEnvironment.appSupport()
        let oldJournal = ActionBrokerUpdateRecoveryJournal(url: storageForIntent?.rootDirectory
            .appendingPathComponent("ActionBrokerUpdateRecovery.json"))
        service = .appOwned(inheritedIntent: legacy.status == .enabled || legacy.status == .requiresApproval
            || (try? oldJournal.load()) != nil)
        embeddedServiceAvailable = true
        #else
        usesAppOwnedService = false
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
        legacyMigrationJournal = ActionBrokerLegacyMigrationJournal(url: storage?.rootDirectory
            .appendingPathComponent("ActionBrokerLegacyMigration.json"))
        legacyMigrationConnect = ActionBrokerLegacyMigrationConnection.connect
        legacyProcessLifetimeState = Self.legacyProcessLifetimeState
        legacyMigrationOwnerIdentity = { Self.legacyProcessIdentity(getpid()) }
        legacyMigrationVerificationTimeout = .seconds(3)
        let processScanPolicy = Self.brokerProcessScanPolicy(
            usesAppOwnedService: usesAppOwnedService, bundleURL: Bundle.main.bundleURL
        )
        runningBrokerProcessIDs = { try Self.currentBrokerProcessIDs(policy: processScanPolicy) }
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
        legacyService: ActionBrokerServiceControl? = nil,
        legacyLaunchdJobsAreAbsent: @escaping () async throws -> Bool = { true },
        legacyMigrationJournal: ActionBrokerLegacyMigrationJournal = .init(),
        legacyMigrationConnect: @escaping ActionBrokerLegacyMigrationConnector = ActionBrokerLegacyMigrationConnection.connect,
        legacyProcessLifetimeState: @escaping @MainActor (ActionBrokerLegacyProcessIdentity) -> LegacyProcessLifetimeState = ActionBrokerServiceManager.legacyProcessLifetimeState,
        legacyMigrationOwnerIdentity: @escaping @MainActor () -> ActionBrokerLegacyProcessIdentity? = { ActionBrokerServiceManager.legacyProcessIdentity(getpid()) },
        legacyMigrationVerificationTimeout: Duration = .seconds(3)
    ) {
        // Isolated tests may inject their own policy through the additional
        // initializer argument; no module defaults are written by this path.
        let policy = moduleAccess ?? CLIModuleAccessPolicy()
        self.moduleAccess = policy
        enabledModules = Set(CLIModule.allCases.filter(policy.isEnabled))
        self.service = service
        self.usesAppOwnedService = usesAppOwnedService
        self.legacyService = legacyService ?? .init(status: { .notRegistered }, register: {}, unregister: {})
        self.legacyLaunchdJobsAreAbsent = legacyLaunchdJobsAreAbsent
        self.legacyMigrationJournal = legacyMigrationJournal
        self.legacyMigrationConnect = legacyMigrationConnect
        self.legacyProcessLifetimeState = legacyProcessLifetimeState
        self.legacyMigrationOwnerIdentity = legacyMigrationOwnerIdentity
        self.legacyMigrationVerificationTimeout = legacyMigrationVerificationTimeout
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
            do {
                guard let ticket = try legacyMigrationJournal.load() else {
                    // Importing old intent never authorizes registering a job.
                    if !hasLegacyServiceRegistration { try? updateRecoveryJournal.clear() }
                    return false
                }
                // A new App process may recover a crashed owner, but may not
                // cancel another still-live App's preparation transaction.
                guard legacyProcessLifetimeState(ticket.owner) == .ended else {
                    throw ActionBrokerUpdateError.invalidRecoveryState
                }
                guard let owner = legacyMigrationOwnerIdentity(), owner.isValid else {
                    throw ActionBrokerUpdateError.invalidRecoveryState
                }
                legacyMigrationTicket = try legacyMigrationJournal.claim(expected: ticket, newOwner: owner)
                try applicationManagementGate.pauseIfIdle()
                applicationUpdatePaused = true
                state = .recovering
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
            let generation = recoveryGeneration
            do {
                try await recoverLegacyMigration()
                guard !isQuitting, recoveryGeneration == generation else { return }
                try Task.checkCancellation()
                updateRecoveryFailureMessage = nil
            } catch {
                guard !isQuitting, recoveryGeneration == generation else { return }
                updateRecoveryFailureMessage = error.localizedDescription
            }
            applicationUpdatePaused = false
            applicationManagementGate.resume()
            // A busy drain has not stopped the host. Stopping it here would
            // revoke the very work that made disabling unsafe. If preparation
            // did stop it, refresh() observes hostIsActive == false and restarts.
            host.resumeAfterCancelledApplicationUpdate()
            refresh()
            if let updateRecoveryFailureMessage { state = .failed(updateRecoveryFailureMessage) }
            else if isServiceRegistered, hostIsActive, successfulHostAttempt == hostAttempt { state = .enabled }
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

    enum BrokerProcessScanPolicy: Equatable {
        case developmentMigration
        case currentBundle(executablePath: String)
    }

    static func brokerProcessScanPolicy(usesAppOwnedService: Bool, bundleURL: URL) -> BrokerProcessScanPolicy {
        // Production selects App-owned transport only in LocalDevelopment.
        // A sandboxed official build must not inherit cross-install migration
        // inspection: it already uses the authenticated drain + PID exit proof.
        if usesAppOwnedService { return .developmentMigration }
        return .currentBundle(executablePath: bundleURL
            .appendingPathComponent("Contents/MacOS/BlocksActionBroker").standardizedFileURL.path)
    }

    private static func currentBrokerProcessIDs(policy: BrokerProcessScanPolicy) throws -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw ActionBrokerUpdateError.serviceDidNotStop }
        var processes = [Int32](repeating: 0, count: Int(count) + 64)
        let received = processes.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard received > 0, Int(received) < processes.count else { throw ActionBrokerUpdateError.serviceDidNotStop }
        return try brokerProcessIDs(in: Array(processes.prefix(Int(received))), policy: policy,
            executablePath: processExecutablePath, kernelName: kernelProcessName,
            hasExited: { kill($0, 0) != 0 && errno == ESRCH },
            kernelSnapshot: kernelProcessSnapshot)
    }

    struct BrokerProcessSnapshot: Equatable {
        let processID: Int32
        let startSeconds: Int64
        let startMicroseconds: Int64
        let status: Int32

        var isZombie: Bool { status == SZOMB }
    }

    /// proc_pidpath can return ENOENT for a live executable unlinked during an
    /// unrelated app update. proc_name reads the kernel's executable name, not
    /// argv/ps display text. Use it only to exclude a positively different name;
    /// Missing/empty names and possible Broker names fail closed unless two
    /// kernel snapshots prove an unchanged zombie lifetime.
    /// The managed Broker contract fixes its executable name to BlocksActionBroker.
    static func brokerProcessIDs(
        in processIDs: [Int32],
        policy: BrokerProcessScanPolicy,
        executablePath: (Int32) -> String?,
        kernelName: (Int32) -> String?,
        hasExited: (Int32) -> Bool,
        kernelSnapshot: (Int32) -> BrokerProcessSnapshot? = { _ in nil }
    ) throws -> [Int32] {
        let brokerName = "BlocksActionBroker"
        return try processIDs.filter { processID in
            guard processID > 0 else { return false }
            if case let .currentBundle(expectedPath) = policy {
                // Preserve the official sandbox's pre-existing exact-path
                // scan. An unreadable unrelated process is not an error here;
                // the authenticated Broker PID is separately drained and its
                // exit checked before removal can succeed.
                return executablePath(processID) == expectedPath
            }
            if let path = executablePath(processID) {
                // Include old/moved installations, not only the current bundle.
                return path.hasSuffix("/Contents/MacOS/\(brokerName)")
            }
            let before = kernelSnapshot(processID)
            if hasExited(processID) { return false }
            guard let name = kernelName(processID), !name.isEmpty,
                  !brokerName.hasPrefix(name), !name.hasPrefix(brokerName) else {
                // Signal 0 succeeds for zombies, while libproc can report
                // ESRCH for both their path and name. Only exclude a process
                // whose kernel state proves the same lifetime was already
                // terminal on both sides of these inconclusive probes. Never
                // treat an unreadable snapshot or a reused PID as exit proof.
                if let before, before.processID == processID, before.isZombie,
                   let after = kernelSnapshot(processID), after == before {
                    return false
                }
                throw ActionBrokerUpdateError.serviceDidNotStop
            }
            return false
        }
    }

    static func kernelProcessSnapshot(_ processID: Int32) -> BrokerProcessSnapshot? {
        guard processID > 0 else { return nil }
        // KERN_PROC_PID includes unreaped zombies that proc_pidpath/proc_name
        // cannot inspect. p_starttime is a kernel lifetime identifier, not ps
        // output or argv. A failed/short response (including permission denial
        // or disappearance) is not evidence of a terminal process.
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        let expectedSize = MemoryLayout<kinfo_proc>.stride
        var size = expectedSize
        let result = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        guard result == 0, size == expectedSize, info.kp_proc.p_pid == processID else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0, start.tv_usec < 1_000_000 else { return nil }
        return BrokerProcessSnapshot(processID: processID,
            startSeconds: Int64(start.tv_sec), startMicroseconds: Int64(start.tv_usec),
            status: Int32(info.kp_proc.p_stat))
    }

    static func legacyProcessIdentity(_ processID: Int32) -> ActionBrokerLegacyProcessIdentity? {
        guard let snapshot = kernelProcessSnapshot(processID), !snapshot.isZombie else { return nil }
        return .init(processID: processID, startSeconds: snapshot.startSeconds, startMicroseconds: snapshot.startMicroseconds)
    }

    static func legacyProcessMatches(_ identity: ActionBrokerLegacyProcessIdentity) -> Bool {
        legacyProcessLifetimeState(identity) == .same
    }

    enum LegacyProcessLifetimeState: Equatable { case same, ended, unknown }

    static func legacyProcessLifetimeState(_ identity: ActionBrokerLegacyProcessIdentity) -> LegacyProcessLifetimeState {
        processLifetimeState(identity, snapshot: kernelProcessSnapshot(identity.processID),
            hasExited: { kill(identity.processID, 0) != 0 && errno == ESRCH })
    }

    static func processLifetimeState(_ identity: ActionBrokerLegacyProcessIdentity,
                                    snapshot: BrokerProcessSnapshot?, hasExited: () -> Bool) -> LegacyProcessLifetimeState {
        guard identity.isValid else { return .unknown }
        if let snapshot, snapshot.processID == identity.processID {
            if snapshot.startSeconds != identity.startSeconds || snapshot.startMicroseconds != identity.startMicroseconds {
                return .ended // The numeric PID now denotes a different lifetime.
            }
            return snapshot.isZombie ? .ended : .same
        }
        return hasExited() ? .ended : .unknown
    }

    static func processExecutablePath(_ processID: Int32) -> String? {
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
        // that macro is not imported by this Swift SDK.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func kernelProcessName(_ processID: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = proc_name(processID, &buffer, UInt32(buffer.count))
        // proc_name returns the name length, excluding its trailing NUL.
        guard count > 0, Int(count) < buffer.count,
              let terminator = buffer.firstIndex(of: 0), terminator > 0, terminator <= Int(count) else { return nil }
        return String(bytes: buffer.prefix(terminator), encoding: .utf8)
    }

    /// An absent job needs no RPC. A loaded job needs a trusted, bounded session,
    /// a durable recovery token, and the peer's global idle/admission proof.
    /// No branch bootouts, force-kills, registers or changes pairing metadata.
    private func retireLegacyService() async throws {
        guard usesAppOwnedService else { return }
        try checkLegacyMigrationCanContinue()
        guard try legacyMigrationJournal.load() == nil, legacyMigrationTicket == nil else {
            throw ActionBrokerUpdateError.invalidRecoveryState
        }
        let jobsAbsent = try await legacyLaunchdJobsAreAbsent()
        try checkLegacyMigrationCanContinue()
        if !jobsAbsent {
            guard legacyService.status() == .enabled, updateRecoveryStorageAvailable else {
                throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
            }
            let session = try await legacyMigrationConnect(nil)
            var retained = false
            defer { if !retained { session.invalidate() } }
            try checkLegacyMigrationCanContinue()
            guard session.identity.isValid, legacyProcessLifetimeState(session.identity) == .same,
                  Set(try runningBrokerProcessIDs()) == [session.identity.processID],
                  legacyService.status() == .enabled else { throw ActionBrokerUpdateError.untrustedPeer }
            guard let owner = legacyMigrationOwnerIdentity(), owner.isValid else { throw ActionBrokerUpdateError.invalidRecoveryState }
            var ticket = ActionBrokerLegacyMigrationTicket(identity: session.identity, owner: owner)
            // Save the authenticated *lifetime* before prepare. This also covers
            // a timeout or a crash after pause but before the reply arrives.
            try legacyMigrationJournal.save(ticket)
            legacyMigrationTicket = ticket
            legacyMigrationSession = session
            retained = true
            try await session.prepare(token: ticket.token)
            try checkLegacyMigrationCanContinue()
            guard legacyProcessLifetimeState(ticket.identity) == .same,
                  Set(try runningBrokerProcessIDs()) == [ticket.identity.processID],
                  legacyService.status() == .enabled else { throw ActionBrokerUpdateError.untrustedPeer }
            // SM may report an error while its asynchronous kill is still in
            // flight. Publish this irreversible boundary before invoking it;
            // after it, recovery may never reopen the old peer's admission.
            ticket.phase = .unregisterStarted
            legacyMigrationTicket = ticket
            try legacyMigrationJournal.save(ticket)
            try await legacyService.unregisterAndWait()
            try checkLegacyMigrationCanContinue()
            try await waitForLegacyRemoval(ticket: ticket)
            return
        }
        guard try runningBrokerProcessIDs().isEmpty else {
            throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
        }
        try checkLegacyMigrationCanContinue()
        if hasLegacyServiceRegistration {
            try await legacyService.unregisterAndWait()
            try checkLegacyMigrationCanContinue()
        }
        guard legacyService.status() == .notRegistered || legacyService.status() == .notFound,
              try await legacyLaunchdJobsAreAbsent(), try runningBrokerProcessIDs().isEmpty else {
            throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
        }
        // This obsolete ticket must never cause startup to resurrect a legacy
        // job. App-owned enabled intent is independent and remains unchanged.
        try updateRecoveryJournal.clear()
    }

    private func checkLegacyMigrationCanContinue() throws {
        try Task.checkCancellation()
        guard !isQuitting else { throw CancellationError() }
    }

    private func legacyRemovalIsConfirmed(identity: ActionBrokerLegacyProcessIdentity) async throws -> Bool {
        guard legacyService.status() == .notRegistered || legacyService.status() == .notFound else { return false }
        guard try await legacyLaunchdJobsAreAbsent() else { return false }
        guard legacyProcessLifetimeState(identity) == .ended else { return false }
        return try runningBrokerProcessIDs().isEmpty
    }

    private func waitForLegacyRemoval(ticket: ActionBrokerLegacyMigrationTicket) async throws {
        let deadline = ContinuousClock.now.advanced(by: legacyMigrationVerificationTimeout)
        while true {
            if try await legacyRemovalIsConfirmed(identity: ticket.identity) {
                try checkLegacyMigrationCanContinue()
                try finishLegacyMigration()
                return
            }
            guard ContinuousClock.now < deadline else { throw ActionBrokerUpdateError.serviceDidNotStop }
            try await Task.sleep(for: .milliseconds(25))
            try checkLegacyMigrationCanContinue()
        }
    }

    private func finishLegacyMigration() throws {
        guard let legacyMigrationTicket else { throw ActionBrokerUpdateError.invalidRecoveryState }
        try legacyMigrationJournal.clear(expected: legacyMigrationTicket)
        // The official ticket is now obsolete, but is never replayed by the
        // app-owned path, including after a partially successful unregister.
        try updateRecoveryJournal.clear()
        self.legacyMigrationTicket = nil
        legacyMigrationSession?.invalidate()
        legacyMigrationSession = nil
    }

    private func recoverLegacyMigration() async throws {
        try checkLegacyMigrationCanContinue()
        // Only startup or this manager's own successful save may adopt a
        // ticket. A failed competing attempt must not load and cancel its owner.
        guard let ticket = legacyMigrationTicket else { return }
        let lifetime = legacyProcessLifetimeState(ticket.identity)
        if lifetime == .ended {
            guard try await legacyRemovalIsConfirmed(identity: ticket.identity) else {
                throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
            }
            try checkLegacyMigrationCanContinue()
            try finishLegacyMigration()
            return
        }
        guard lifetime == .same else { throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration }
        if ticket.phase == .unregisterStarted {
            // Crash may have occurred after journaling but before the OS call.
            // Re-establish the *same* peer's idempotent global pause before a
            // bounded retry. Never resume while an earlier kill may be pending.
            try await continueLegacyRemoval(ticket: ticket)
            return
        }
        try checkLegacyMigrationCanContinue()
        let session: any ActionBrokerLegacyMigrationSession
        // A held connection can safely undo our own pause even when a later
        // launchctl diagnostic failed. Only reconnecting needs loaded-job
        // evidence; neither recovery path may register a replacement process.
        if let existing = legacyMigrationSession, existing.identity == ticket.identity { session = existing }
        else {
            guard !(try await legacyLaunchdJobsAreAbsent()) else {
                throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
            }
            try checkLegacyMigrationCanContinue()
            session = try await legacyMigrationConnect(ticket.identity)
            legacyMigrationSession = session
        }
        do {
            try checkLegacyMigrationCanContinue()
            guard session.identity == ticket.identity, legacyProcessLifetimeState(ticket.identity) == .same else {
                throw ActionBrokerUpdateError.untrustedPeer
            }
            try await session.resume(token: ticket.token)
            try checkLegacyMigrationCanContinue()
            try legacyMigrationJournal.clear(expected: ticket)
        } catch {
            // An interrupted NSXPCConnection is not a reusable recovery path.
            // Keep the token/journal, but require fresh authentication of the
            // same saved lifetime on a later explicit recovery attempt.
            session.invalidate()
            legacyMigrationSession = nil
            throw error
        }
        legacyMigrationTicket = nil
        session.invalidate()
        legacyMigrationSession = nil
    }

    private func continueLegacyRemoval(ticket: ActionBrokerLegacyMigrationTicket) async throws {
        guard legacyService.status() == .enabled, !(try await legacyLaunchdJobsAreAbsent()) else {
            throw ActionBrokerUpdateError.serviceDidNotStop
        }
        try checkLegacyMigrationCanContinue()
        let session: any ActionBrokerLegacyMigrationSession
        if let existing = legacyMigrationSession, existing.identity == ticket.identity { session = existing }
        else {
            session = try await legacyMigrationConnect(ticket.identity)
            legacyMigrationSession = session
        }
        do {
            try checkLegacyMigrationCanContinue()
            guard session.identity == ticket.identity, legacyProcessLifetimeState(ticket.identity) == .same,
                  Set(try runningBrokerProcessIDs()) == [ticket.identity.processID] else {
                throw ActionBrokerUpdateError.untrustedPeer
            }
            try await session.prepare(token: ticket.token)
            try checkLegacyMigrationCanContinue()
            guard legacyService.status() == .enabled, legacyProcessLifetimeState(ticket.identity) == .same,
                  Set(try runningBrokerProcessIDs()) == [ticket.identity.processID] else {
                throw ActionBrokerUpdateError.serviceDidNotStop
            }
            // The preceding attempt may have failed while persisting the OS
            // boundary. Every retry must durably confirm ownership and phase
            // again; an in-memory unregisterStarted value is not authority.
            try legacyMigrationJournal.save(ticket)
            try checkLegacyMigrationCanContinue()
            try await legacyService.unregisterAndWait()
            try checkLegacyMigrationCanContinue()
            try await waitForLegacyRemoval(ticket: ticket)
        } catch {
            session.invalidate()
            legacyMigrationSession = nil
            throw error
        }
    }

    static func legacyJobIsAbsent(exitCode: Int32, standardError: String, domain: String, uid: uid_t) -> Bool {
        let description = domain.hasPrefix("gui/") ? "user gui: \(uid)" : "uid: \(uid)"
        let missing = "Could not find service \"\(BlocksActionBrokerXPC.launchAgentLabel)\" in domain for \(description)"
        let lines = standardError.split(separator: "\n").map(String.init)
        return exitCode == 113 && (lines == [missing] || lines == ["Bad request.", missing])
    }

    private static func currentLegacyLaunchdJobsAreAbsent() async throws -> Bool {
        let uid = getuid()
        var allAbsent = true
        for domain in ["gui/\(uid)", "user/\(uid)"] {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "\(domain)/\(BlocksActionBrokerXPC.launchAgentLabel)"]
            process.environment = ["LC_ALL": "C", "LANG": "C"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            do {
                while process.isRunning {
                    guard ContinuousClock.now < deadline else { throw ActionBrokerUpdateError.serviceDidNotStop }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try Task.checkCancellation()
            } catch {
                if process.isRunning { process.terminate() } // Only our read-only diagnostic child.
                throw error
            }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            guard data.count <= 4096, let message = String(data: data, encoding: .utf8) else {
                throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
            }
            if process.terminationStatus == 0 { allAbsent = false }
            else if !legacyJobIsAbsent(exitCode: process.terminationStatus, standardError: message, domain: domain, uid: uid) {
                // A missing domain, permission failure or unexpected diagnostic
                // is unknown, not a loaded job that authenticated RPC may retire.
                throw ActionBrokerUpdateError.legacyRegistrationRequiresMigration
            }
        }
        return allAbsent
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
                isReconnect: state == .reconnecting || state == .recovering || state == .recoveryRequired || retryAttempt > 0,
                isHealthCheck: state == .recoveryRequired
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

    /// An explicit recheck is only a connection attempt. It cannot establish
    /// that an unreachable Broker is idle, so it never changes registration,
    /// clears recovery intent, or asks launchd to terminate the old process.
    func recheckConnection() {
        guard !isQuitting, !applicationUpdatePaused, serviceChangeTask == nil,
              updateRecoveryTask == nil, applicationManagementGate.isAcceptingOperations else { return }
        guard embeddedServiceAvailable, service.status() == .enabled else {
            refresh()
            return
        }
        guard !hostIsActive else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        retryAttempt = 0
        isServiceRegistered = true
        startHost(isReconnect: true)
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
        state = isHealthCheck ? .recoveryRequired : (isReconnect ? .reconnecting : .connecting)
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
            state = .recoveryRequired
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
