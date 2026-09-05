import BlocksCore
import Darwin
import Foundation
import OSLog

struct ClipboardPasteboardWriteLease: Equatable, Sendable {
    let changeCount: Int
    let brokerGeneration: UInt64

    init(changeCount: Int, brokerGeneration: UInt64 = 0) {
        self.changeCount = changeCount
        self.brokerGeneration = brokerGeneration
    }
}

struct ClipboardPreparedPasteboardWriteLease: Equatable, Sendable {
    let preparedWriteID: UUID
    let brokerGeneration: UInt64
}

protocol ClipboardBrokerServing: AnyObject, Sendable {
    func baseline() async throws -> Int
    func observe(_ request: ClipboardBrokerObserveRequest) async throws -> ClipboardBrokerObservationResult
    func resolve(
        ticket: ClipboardBrokerResolutionTicket,
        timeout: Duration
    ) async throws -> ClipboardBrokerObservationResult
    func write(_ request: ClipboardBrokerWriteRequest) async throws -> ClipboardPasteboardWriteLease
    func supportsPreparedWrites() async -> Bool
    func prepare(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPreparedPasteboardWriteLease
    func commit(
        _ lease: ClipboardPreparedPasteboardWriteLease
    ) async throws -> ClipboardPasteboardWriteLease
    func cancel(_ lease: ClipboardPreparedPasteboardWriteLease) async throws
    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool
    func generationIsCurrent(_ brokerGeneration: UInt64) async -> Bool
    func currentPlainText(limit: Int) async throws -> ClipboardBrokerPlainTextResult
    func snapshot() async throws -> ClipboardBrokerSnapshotResult
    func suppressExternalChangeCounts(_ changeCounts: [Int]) async
    func updatePassiveMonitoring(
        ownerID: UUID,
        revision: UInt64,
        active: Bool
    ) async
    func shutdown() async
}

extension ClipboardBrokerServing {
    func supportsPreparedWrites() async -> Bool { false }

    func prepare(
        _: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPreparedPasteboardWriteLease {
        throw ClipboardBrokerClientError.preparedWritesUnsupported
    }

    func commit(
        _: ClipboardPreparedPasteboardWriteLease
    ) async throws -> ClipboardPasteboardWriteLease {
        throw ClipboardBrokerClientError.preparedWritesUnsupported
    }

    func cancel(_: ClipboardPreparedPasteboardWriteLease) async throws {}

    func resolve(
        ticket: ClipboardBrokerResolutionTicket,
        timeout: Duration
    ) async throws -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .skipped,
            changeCount: ticket.changeCount,
            observedAfterChangeCount: ticket.changeCount,
            skipReason: .unsupported
        )
    }

    func generationIsCurrent(_ brokerGeneration: UInt64) async -> Bool {
        // Fake/named-pasteboard backends do not own a recoverable subprocess.
        brokerGeneration == 0
    }

    func updatePassiveMonitoring(
        ownerID: UUID,
        revision: UInt64,
        active: Bool
    ) async {
        // Test backends do not supervise a recoverable subprocess.
    }

    func snapshot() async throws -> ClipboardBrokerSnapshotResult {
        ClipboardBrokerSnapshotResult(
            status: .unsupported,
            changeCount: try await baseline()
        )
    }

    func suppressExternalChangeCounts(_: [Int]) async {}
}

enum ClipboardBrokerClientError: Error, Equatable {
    case executableUnavailable
    case launchFailed
    case requestTimedOut
    case brokerTerminated
    case requestSuperseded
    case requestOversized
    case malformedResponse
    case brokerFailure(String)
    case writeChanged
    case writeFailed
    case preparedWritesUnsupported
}

struct ClipboardBrokerClientDiagnostics: Equatable, Sendable {
    let processIdentifier: pid_t?
    let generation: UInt64
    let pendingRequestCount: Int
    let circuitIsOpen: Bool
}

enum ClipboardBrokerDataTransport {
    private enum Phase {
        case running
        case finalizing
        case terminated
    }

    private final class PinnedRoot: @unchecked Sendable {
        let url: URL
        let descriptor: Int32
        let metadata: stat

        init(url: URL, descriptor: Int32, metadata: stat) {
            self.url = url
            self.descriptor = descriptor
            self.metadata = metadata
        }

        deinit {
            close(descriptor)
        }
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var pinnedRoot: PinnedRoot?
        var activeOperationCount = 0
        var phase: Phase = .running
#if DEBUG
        var waitingForActiveOperations = false
#endif
    }

    private final class RootOperation: @unchecked Sendable {
        let descriptor: Int32
        let metadata: stat
        private let state: State
        private let finishLock = NSLock()
        private var isFinished = false

        init(descriptor: Int32, metadata: stat, state: State) {
            self.descriptor = descriptor
            self.metadata = metadata
            self.state = state
        }

        deinit {
            finish()
        }

        func finish() {
            finishLock.lock()
            guard !isFinished else {
                finishLock.unlock()
                return
            }
            isFinished = true
            finishLock.unlock()

            close(descriptor)
            state.condition.lock()
            precondition(state.activeOperationCount > 0)
            state.activeOperationCount -= 1
            if state.activeOperationCount == 0 {
                state.condition.broadcast()
            }
            state.condition.unlock()
        }
    }

    private static let state = State()
    private static let candidateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "\(ClipboardBrokerStaging.directoryName)-\(getpid())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        .standardizedFileURL

    static var rootDirectory: URL {
        state.condition.lock()
        defer { state.condition.unlock() }
        return state.pinnedRoot?.url ?? candidateRoot
    }

    static func prepareRoot() throws {
        state.condition.lock()
        defer { state.condition.unlock() }

        guard state.phase == .running else {
            throw ClipboardBrokerClientError.brokerTerminated
        }

        if let pinnedRoot = state.pinnedRoot {
            var metadata = stat()
            guard fstat(pinnedRoot.descriptor, &metadata) == 0,
                  metadata.st_dev == pinnedRoot.metadata.st_dev,
                  metadata.st_ino == pinnedRoot.metadata.st_ino,
                  isSecureRoot(metadata) else {
                throw ClipboardBrokerClientError.malformedResponse
            }
            return
        }

        guard mkdir(candidateRoot.path, mode_t(0o700)) == 0 else {
            // The per-process random path must never adopt a pre-existing
            // directory whose creator and inode are outside this session.
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = open(
            candidateRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            _ = rmdir(candidateRoot.path)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              isSecureRoot(metadata),
              lstat(candidateRoot.path, &pathMetadata) == 0,
              pathMetadata.st_dev == metadata.st_dev,
              pathMetadata.st_ino == metadata.st_ino else {
            close(descriptor)
            _ = rmdir(candidateRoot.path)
            throw ClipboardBrokerClientError.malformedResponse
        }
        state.pinnedRoot = PinnedRoot(
            url: candidateRoot,
            descriptor: descriptor,
            metadata: metadata
        )
    }

    static func rootIdentity() throws -> (
        url: URL,
        device: UInt64,
        inode: UInt64
    ) {
        try prepareRoot()
        state.condition.lock()
        defer { state.condition.unlock() }
        guard state.phase == .running,
              let pinnedRoot = state.pinnedRoot,
              pathStillReferencesPinnedRoot(pinnedRoot) else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        return (
            pinnedRoot.url,
            UInt64(pinnedRoot.metadata.st_dev),
            UInt64(pinnedRoot.metadata.st_ino)
        )
    }

    static func removeRoot() {
        guard let openedRoot = try? duplicatePreparedRootDescriptor() else {
            return
        }
        defer { openedRoot.finish() }
        guard let names = directoryEntryNames(
            descriptor: openedRoot.descriptor,
            maximumCount: 256
        ) else {
            return
        }
        for name in names {
            guard token(forPayloadName: name) != nil else {
                return
            }
            var metadata = stat()
            guard fstatat(
                openedRoot.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            isSecurePayload(metadata) else {
                return
            }
        }
        for name in names {
            guard unlinkat(openedRoot.descriptor, name, 0) == 0 else {
                return
            }
        }
        // Keep the directory FD and inode pinned for the App process lifetime.
        // Broker restarts therefore cannot adopt a same-path replacement.
    }

    static func finalizeRoot() {
        state.condition.lock()
        guard state.phase == .running else {
            state.condition.unlock()
            return
        }
        state.phase = .finalizing
        state.condition.broadcast()
        while state.activeOperationCount > 0 {
#if DEBUG
            state.waitingForActiveOperations = true
            state.condition.broadcast()
#endif
            state.condition.wait()
        }
#if DEBUG
        state.waitingForActiveOperations = false
#endif
        let pinnedRoot = state.pinnedRoot
        state.condition.unlock()

        var rootWasRemoved = false
        defer {
            state.condition.lock()
            if rootWasRemoved,
               let pinnedRoot,
               state.pinnedRoot === pinnedRoot {
                state.pinnedRoot = nil
            }
            state.phase = .terminated
            state.condition.broadcast()
            state.condition.unlock()
        }

        guard let pinnedRoot else {
            return
        }
        let operationDescriptor = openat(
            pinnedRoot.descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard operationDescriptor >= 0 else {
            return
        }
        defer { close(operationDescriptor) }

        guard let names = directoryEntryNames(
            descriptor: operationDescriptor,
            maximumCount: 256
        ) else {
            return
        }
        for name in names {
            guard token(forPayloadName: name) != nil else {
                return
            }
            var metadata = stat()
            guard fstatat(
                operationDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            isSecurePayload(metadata) else {
                return
            }
        }
        for name in names {
            guard unlinkat(operationDescriptor, name, 0) == 0 else {
                return
            }
        }
        guard directoryEntryNames(
            descriptor: operationDescriptor,
            maximumCount: 1
        )?.isEmpty == true else {
            return
        }

        var currentMetadata = stat()
        guard lstat(pinnedRoot.url.path, &currentMetadata) == 0,
              currentMetadata.st_dev == pinnedRoot.metadata.st_dev,
              currentMetadata.st_ino == pinnedRoot.metadata.st_ino else {
            return
        }
        rootWasRemoved = rmdir(pinnedRoot.url.path) == 0
    }

    static func reference(
        for data: Data,
        stagesLargePayload: Bool
    ) throws -> ClipboardBrokerDataReference {
        guard stagesLargePayload, data.count > ClipboardBrokerLimits.inlineImageBytes else {
            return .inline(data)
        }
        guard data.count <= ClipboardBrokerLimits.maxFrameBytes else {
            throw ClipboardBrokerFrameError.oversized(data.count)
        }
        try prepareRoot()
        let token = ClipboardBrokerStaging.makeToken()
        guard ClipboardBrokerStaging.fileURL(
            rootDirectory: rootDirectory,
            token: token
        ) != nil else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        do {
            try writeSecurely(data, token: token)
        } catch {
            removePayload(token: token)
            throw error
        }
        return .staged(token: token, byteCount: data.count)
    }

    static func resolve(
        _ reference: ClipboardBrokerDataReference,
        maximumByteCount: Int
    ) async throws -> Data {
        switch reference {
        case let .inline(data):
            guard data.count <= maximumByteCount else {
                throw ClipboardBrokerFrameError.oversized(data.count)
            }
            return data
        case let .staged(token, expectedByteCount):
            guard expectedByteCount >= 0,
                  expectedByteCount <= maximumByteCount,
                  ClipboardBrokerStaging.fileURL(
                      rootDirectory: rootDirectory,
                      token: token
                  ) != nil else {
                throw ClipboardBrokerClientError.malformedResponse
            }
            let readTask = Task.detached(priority: .utility) {
                defer { removePayload(token: token) }
                return try readSecurely(
                    token: token,
                    expectedByteCount: expectedByteCount,
                    maximumByteCount: maximumByteCount
                )
            }
            return try await withTaskCancellationHandler {
                try await readTask.value
            } onCancel: {
                readTask.cancel()
            }
        }
    }

    static func removeStagedReferences(in request: ClipboardBrokerWriteRequest) {
        for item in request.items {
            for entry in item.representations {
                guard case let .data(.staged(token, _)) = entry.value else {
                    continue
                }
                removePayload(token: token)
            }
        }
    }

    static func removeStagedReference(
        _ reference: ClipboardBrokerDataReference?
    ) {
        guard case let .staged(token, _) = reference else {
            return
        }
        removePayload(token: token)
    }

    private static func writeSecurely(_ data: Data, token: String) throws {
        let openedRoot = try duplicatePinnedRootDescriptor()
        defer { openedRoot.finish() }
        let descriptor = openat(
            openedRoot.descriptor,
            payloadName(for: token),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              isSecurePayload(metadata) else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                try Task.checkCancellation()
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }

    private static func readSecurely(
        token: String,
        expectedByteCount: Int,
        maximumByteCount: Int
    ) throws -> Data {
        let openedRoot = try duplicatePinnedRootDescriptor()
        defer { openedRoot.finish() }
        let descriptor = openat(
            openedRoot.descriptor,
            payloadName(for: token),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              isSecurePayload(metadata),
              metadata.st_size >= 0,
              metadata.st_size == expectedByteCount,
              metadata.st_size <= maximumByteCount else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var readCount = 0
            while readCount < bytes.count {
                try Task.checkCancellation()
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: readCount),
                    bytes.count - readCount
                )
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                readCount += result
            }
        }
        return data
    }

    private static func removePayload(token: String) {
        guard let openedRoot = try? duplicatePreparedRootDescriptor() else {
            return
        }
        defer { openedRoot.finish() }
        let name = payloadName(for: token)
        var metadata = stat()
        guard fstatat(
            openedRoot.descriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        isSecurePayload(metadata) else {
            return
        }
        _ = unlinkat(openedRoot.descriptor, name, 0)
    }

    private static func duplicatePinnedRootDescriptor() throws -> RootOperation {
        try prepareRoot()
        return try duplicatePreparedRootDescriptor()
    }

    private static func duplicatePreparedRootDescriptor() throws -> RootOperation {
        state.condition.lock()
        defer { state.condition.unlock() }
        guard state.phase == .running,
              let pinnedRoot = state.pinnedRoot else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        let descriptor = openat(
            pinnedRoot.descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_dev == pinnedRoot.metadata.st_dev,
              metadata.st_ino == pinnedRoot.metadata.st_ino,
              isSecureRoot(metadata) else {
            close(descriptor)
            throw ClipboardBrokerClientError.malformedResponse
        }
        state.activeOperationCount += 1
        return RootOperation(
            descriptor: descriptor,
            metadata: metadata,
            state: state
        )
    }

#if DEBUG
    static func isWaitingForActiveOperationsForTesting() -> Bool {
        state.condition.lock()
        defer { state.condition.unlock() }
        return state.phase == .finalizing
            && state.waitingForActiveOperations
    }

    static func resetAfterTerminationForTesting() throws {
        state.condition.lock()
        defer { state.condition.unlock() }
        guard state.activeOperationCount == 0 else {
            throw ClipboardBrokerClientError.requestSuperseded
        }
        switch state.phase {
        case .running:
            return
        case .finalizing:
            throw ClipboardBrokerClientError.requestSuperseded
        case .terminated:
            guard state.pinnedRoot == nil else {
                throw ClipboardBrokerClientError.malformedResponse
            }
            state.phase = .running
            state.waitingForActiveOperations = false
            state.condition.broadcast()
        }
    }

    static func withPinnedRootOperationForTesting(
        _ operation: @Sendable (Int32) throws -> Void
    ) throws {
        let openedRoot = try duplicatePinnedRootDescriptor()
        defer { openedRoot.finish() }
        try operation(openedRoot.descriptor)
    }
#endif

    private static func payloadName(for token: String) -> String {
        guard let url = ClipboardBrokerStaging.fileURL(
            rootDirectory: rootDirectory,
            token: token
        ) else {
            return ""
        }
        return url.lastPathComponent
    }

    private static func token(forPayloadName name: String) -> String? {
        let url = URL(fileURLWithPath: name)
        guard url.lastPathComponent == name,
              url.pathExtension == ClipboardBrokerStaging.fileExtension else {
            return nil
        }
        let token = url.deletingPathExtension().lastPathComponent
        guard payloadName(for: token) == name else {
            return nil
        }
        return token
    }

    private static func isSecurePayload(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == geteuid()
            && metadata.st_nlink == 1
            && (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
    }

    private static func isSecureRoot(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == geteuid()
            && (metadata.st_mode & mode_t(0o777)) == mode_t(0o700)
    }

    private static func pathStillReferencesPinnedRoot(
        _ pinnedRoot: PinnedRoot
    ) -> Bool {
        var currentMetadata = stat()
        return lstat(pinnedRoot.url.path, &currentMetadata) == 0
            && currentMetadata.st_dev == pinnedRoot.metadata.st_dev
            && currentMetadata.st_ino == pinnedRoot.metadata.st_ino
            && isSecureRoot(currentMetadata)
    }

    private static func directoryEntryNames(
        descriptor: Int32,
        maximumCount: Int
    ) -> [String]? {
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else { return nil }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            return nil
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                return errno == 0 ? names : nil
            }
            var entryValue = entry.pointee
            let length = Int(entryValue.d_namlen)
            let capacity = MemoryLayout.size(ofValue: entryValue.d_name)
            guard length >= 0, length < capacity else { return nil }
            let name = withUnsafePointer(to: &entryValue.d_name) {
                tuplePointer in
                tuplePointer.withMemoryRebound(
                    to: UInt8.self,
                    capacity: capacity
                ) {
                    String(
                        decoding: UnsafeBufferPointer(
                            start: $0,
                            count: length
                        ),
                        as: UTF8.self
                    )
                }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < maximumCount else { return nil }
            names.append(name)
        }
        return names
    }
}

actor ClipboardBrokerClient: ClipboardBrokerServing {
    static let shared = ClipboardBrokerClient()

    private enum RequestPriority: Equatable {
        case passive
        case explicit
    }

    private enum RequestCancellationBehavior: Equatable, Sendable {
        case terminateBroker
        case awaitTerminal
    }

    private struct PendingRequest {
        let operation: ClipboardBrokerOperation
        let priority: RequestPriority
        let startedAt: ContinuousClock.Instant
        var startedChangeCount: Int?
        let continuation: CheckedContinuation<ClipboardBrokerTerminalResult, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct PerformedRequest {
        let terminal: ClipboardBrokerTerminalResult
        let brokerGeneration: UInt64
    }

    private struct PassiveMonitoringOwnerState {
        let revision: UInt64
        let active: Bool
    }

    private struct ExplicitPreparation {
        let id: UUID
        let task: Task<ClipboardBrokerWriteRequest, Error>
    }

    private struct OutstandingPreparedWrite: Equatable, Sendable {
        let expiresAtSystemUptime: TimeInterval
        let brokerGeneration: UInt64
    }

    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "ClipboardBroker"
    )
    private static let passiveRestartWindow: TimeInterval = 30
    private static let passiveRestartLimit = 3
    private static let circuitBreakerDuration: TimeInterval = 30
    private static let idleReapDelay: Duration = .milliseconds(1_500)
    private static let shutdownCommitGracePeriod: Duration = .seconds(2)
    private static let stagedImagePasteboardTypes: Set<String> = [
        "public.png",
        "public.tiff",
    ]

    private let executableURLProvider: @Sendable () -> URL?
    private let executableArguments: [String]
    private let environmentOverrides: [String: String]
    private let requestIOQueue = DispatchQueue(
        label: "app.blocks.clipboard-broker.request-io",
        qos: .userInitiated
    )
    private var process: Process?
    private var launchIdentity: UUID?
    private var requestInputChannel: DispatchIO?
    private var responseOutput: FileHandle?
    private var responseReaderTask: Task<Void, Never>?
    private var responseBuffer = Data()
    private var pendingRequests: [UUID: PendingRequest] = [:]
    private var generation: UInt64 = 0
    private var cachedChangeCount: Int = 0
    private var suppressedChangeCounts: Set<Int> = []
    private var poisonedChangeCount: Int?
    private var passiveRestartDates: [Date] = []
    private var circuitOpenUntil: Date?
    private var requiresBaselineAfterRestart = true
    private var shuttingDown = false
    private var explicitPreparation: ExplicitPreparation?
    private var outstandingPreparedWrites: [UUID: OutstandingPreparedWrite] = [:]
    private var preparedWriteExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var idleReapTask: Task<Void, Never>?
    private var passiveMonitoringOwners: [UUID: PassiveMonitoringOwnerState] = [:]
    private var commitSettlementWaiters: [
        UUID: CheckedContinuation<Void, Error>
    ] = [:]
    private var shutdownWaiters: [
        UUID: CheckedContinuation<Void, Never>
    ] = [:]
    private var shutdownCommitSettlementWaiters: [
        UUID: CheckedContinuation<Void, Never>
    ] = [:]
    private var shutdownCommitTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(
        executableURLProvider: @escaping @Sendable () -> URL? = {
#if DEBUG
            if let override = ProcessInfo.processInfo.environment[
                "BLOCKS_CLIPBOARD_BROKER_EXECUTABLE"
            ], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
#endif
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("BlocksClipboardBroker", isDirectory: false)
        },
        executableArguments: [String] = [],
        environmentOverrides: [String: String] = [:]
    ) {
        self.executableURLProvider = executableURLProvider
        self.executableArguments = executableArguments
        self.environmentOverrides = environmentOverrides
    }

    func baseline() async throws -> Int {
        let baseline = try await performBaseline()
        return baseline.changeCount
    }

    private func performBaseline() async throws -> (
        changeCount: Int,
        brokerGeneration: UInt64
    ) {
        // A baseline used by a newer paste must observe an already accepted
        // commit after it settles, rather than preempting the helper midway
        // through its irreversible pasteboard mutation.
        try await waitForInFlightCommitToSettle()
        let performed = try await perform(command: .baseline, priority: .passive)
        guard case let .baseline(changeCount) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        cachedChangeCount = changeCount
        requiresBaselineAfterRestart = false
        return (changeCount, performed.brokerGeneration)
    }

    func observe(
        _ request: ClipboardBrokerObserveRequest
    ) async throws -> ClipboardBrokerObservationResult {
        if let circuitOpenUntil, circuitOpenUntil > Date() {
            return ClipboardBrokerObservationResult(
                status: .noChange,
                changeCount: cachedChangeCount,
                observedAfterChangeCount: cachedChangeCount,
                brokerGeneration: generation
            )
        }
        self.circuitOpenUntil = nil

        if requiresBaselineAfterRestart {
            let baseline = try await performBaseline()
            guard baseline.brokerGeneration == generation else {
                throw ClipboardBrokerClientError.brokerTerminated
            }
            return ClipboardBrokerObservationResult(
                status: .noChange,
                changeCount: baseline.changeCount,
                observedAfterChangeCount: baseline.changeCount,
                brokerGeneration: baseline.brokerGeneration
            )
        }

        let effectiveRequest = ClipboardBrokerObserveRequest(
            baselineChangeCount: request.baselineChangeCount ?? cachedChangeCount,
            poisonedChangeCount: poisonedChangeCount,
            suppressedChangeCounts: Array(
                suppressedChangeCounts.union(request.suppressedChangeCounts)
            ),
            prefilterDisposition: request.prefilterDisposition,
            screenSharingActive: request.screenSharingActive
        )
        let performed = try await perform(
            command: .observe(effectiveRequest),
            priority: .passive
        )
        guard case let .observation(observation) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        let taggedObservation = observation.tagged(
            brokerGeneration: performed.brokerGeneration
        )
        cachedChangeCount = taggedObservation.observedAfterChangeCount
        if taggedObservation.changeCount != poisonedChangeCount {
            poisonedChangeCount = nil
        }
        if taggedObservation.skipReason == .selfWrite {
            suppressedChangeCounts.remove(taggedObservation.changeCount)
        }
        trimSuppressedChangeCounts()
        return taggedObservation
    }

    func resolve(
        ticket: ClipboardBrokerResolutionTicket,
        timeout: Duration
    ) async throws -> ClipboardBrokerObservationResult {
        let performed = try await perform(
            command: .resolve(ClipboardBrokerResolveRequest(ticket: ticket)),
            priority: .passive,
            timeout: timeout
        )
        guard case let .observation(observation) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        let taggedObservation = observation.tagged(
            brokerGeneration: performed.brokerGeneration
        )
        // A stale ticket reports the newer current change count only so the
        // caller can reject the old result. It has not inspected that newer
        // item, so advancing the observation baseline here would silently
        // consume it.
        if taggedObservation.skipReason != .stale {
            cachedChangeCount = taggedObservation.observedAfterChangeCount
        }
        requiresBaselineAfterRestart = false
        return taggedObservation
    }

    func write(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPasteboardWriteLease {
        let stagedRequest = try await stageExplicitWriteRequest(request)
        defer {
            ClipboardBrokerDataTransport.removeStagedReferences(
                in: stagedRequest
            )
        }
        let performed = try await perform(
            command: .write(stagedRequest),
            priority: .explicit,
            priorityWasPrepared: true
        )
        return try consumeWriteResult(performed)
    }

    func supportsPreparedWrites() async -> Bool { true }

    func prepare(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPreparedPasteboardWriteLease {
        let stagedRequest = try await stageExplicitWriteRequest(request)
        defer {
            ClipboardBrokerDataTransport.removeStagedReferences(
                in: stagedRequest
            )
        }
        let performed = try await perform(
            command: .prepareWrite(ClipboardBrokerPrepareWriteRequest(
                write: stagedRequest
            )),
            priority: .explicit,
            priorityWasPrepared: true
        )
        guard case let .preparedWrite(result) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        return ClipboardPreparedPasteboardWriteLease(
            preparedWriteID: result.preparedWriteID,
            brokerGeneration: performed.brokerGeneration
        )
    }

    func commit(
        _ lease: ClipboardPreparedPasteboardWriteLease
    ) async throws -> ClipboardPasteboardWriteLease {
        expirePreparedWritesIfNeeded()
        guard outstandingPreparedWrites[lease.preparedWriteID] != nil else {
            throw ClipboardBrokerClientError.requestSuperseded
        }
        try Task.checkCancellation()
        guard lease.brokerGeneration == generation else {
            removeOutstandingPreparedWrite(lease.preparedWriteID)
            throw ClipboardBrokerClientError.brokerTerminated
        }
        // Reject local scheduling conflicts before consuming the lease. The
        // caller can retry or cancel after the competing request settles.
        guard !shuttingDown,
              explicitPreparation == nil,
              pendingRequests.isEmpty else {
            throw ClipboardBrokerClientError.requestSuperseded
        }
        removeOutstandingPreparedWrite(lease.preparedWriteID)
        let performed = try await perform(
            command: .commitWrite(ClipboardBrokerCommitWriteRequest(
                preparedWriteID: lease.preparedWriteID
            )),
            priority: .explicit,
            cancellationBehavior: .awaitTerminal,
            // Sending commit transfers ownership of the irreversible
            // clear/write sequence to the Broker. From this point a timeout
            // must not kill it between clear and write.
            timeout: nil
        )
        guard performed.brokerGeneration == lease.brokerGeneration else {
            throw ClipboardBrokerClientError.brokerTerminated
        }
        // Once the Broker removes the prepared ID, that commit owns the
        // synchronous clear/write sequence and must be allowed to settle.
        // Its terminal lease is physical truth, even if the awaiting task was
        // cancelled while the Broker cleared and replaced the pasteboard.
        // Higher-level automatic-paste code decides whether it may continue
        // with UI state or Cmd+V after receiving this lease.
        return try consumeWriteResult(performed)
    }

    func cancel(_ lease: ClipboardPreparedPasteboardWriteLease) async throws {
        expirePreparedWritesIfNeeded()
        guard outstandingPreparedWrites[lease.preparedWriteID] != nil else {
            throw ClipboardBrokerClientError.requestSuperseded
        }
        guard lease.brokerGeneration == generation else {
            removeOutstandingPreparedWrite(lease.preparedWriteID)
            throw ClipboardBrokerClientError.brokerTerminated
        }
        removeOutstandingPreparedWrite(lease.preparedWriteID)
        let performed = try await perform(
            command: .cancelWrite(ClipboardBrokerCancelWriteRequest(
                preparedWriteID: lease.preparedWriteID
            )),
            priority: .explicit
        )
        guard performed.brokerGeneration == lease.brokerGeneration,
              case .cancelledWrite = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
    }

    private func waitForInFlightCommitToSettle() async throws {
        while pendingRequests.values.contains(where: {
            $0.operation == .commitWrite
        }) {
            try Task.checkCancellation()
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await suspendUntilInFlightCommitSettles(
                    waiterID: waiterID
                )
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelCommitSettlementWaiter(waiterID)
                }
            }
        }
    }

    private func suspendUntilInFlightCommitSettles(
        waiterID: UUID
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            guard pendingRequests.values.contains(where: {
                $0.operation == .commitWrite
            }) else {
                continuation.resume()
                return
            }
            commitSettlementWaiters[waiterID] = continuation
        }
    }

    private func cancelCommitSettlementWaiter(_ waiterID: UUID) {
        guard let continuation = commitSettlementWaiters.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeCommitSettlementWaitersIfPossible() {
        guard !pendingRequests.values.contains(where: {
            $0.operation == .commitWrite
        }) else {
            return
        }
        let waiters = commitSettlementWaiters.values
        commitSettlementWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
        let shutdownWaiterIDs = Array(
            shutdownCommitSettlementWaiters.keys
        )
        for waiterID in shutdownWaiterIDs {
            finishShutdownCommitGracePeriod(waiterID)
        }
    }

    private func stageExplicitWriteRequest(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardBrokerWriteRequest {
        // User-initiated writes must never queue behind a blocked observation.
        // An accepted commit is the irreversible linearization point. A newer
        // explicit write waits for that commit to finish, then writes after it;
        // it must never kill the helper between clearContents and writeObjects.
        try await waitForInFlightCommitToSettle()
        // Preempt passive work, then stage large image bytes off the supervisor
        // actor.
        idleReapTask?.cancel()
        idleReapTask = nil
        try prepareForPriority(.explicit)
        try preflightWriteRequest(request)
        let preparationID = UUID()
        let preparationTask = Task.detached(priority: .userInitiated) {
            try Self.stageLargeImagePayloads(in: request)
        }
        explicitPreparation = ExplicitPreparation(
            id: preparationID,
            task: preparationTask
        )

        var preparedRequest: ClipboardBrokerWriteRequest?
        do {
            preparedRequest = try await withTaskCancellationHandler {
                try await preparationTask.value
            } onCancel: {
                preparationTask.cancel()
            }
            try Task.checkCancellation()
        } catch {
            if let preparedRequest {
                ClipboardBrokerDataTransport.removeStagedReferences(
                    in: preparedRequest
                )
            }
            if explicitPreparation?.id == preparationID {
                explicitPreparation = nil
            }
            throw error
        }
        guard explicitPreparation?.id == preparationID,
              !shuttingDown,
              let stagedRequest = preparedRequest else {
            if let preparedRequest {
                ClipboardBrokerDataTransport.removeStagedReferences(
                    in: preparedRequest
                )
            }
            if explicitPreparation?.id == preparationID {
                explicitPreparation = nil
            }
            throw ClipboardBrokerClientError.requestSuperseded
        }
        explicitPreparation = nil
        return stagedRequest
    }

    private func consumeWriteResult(
        _ performed: PerformedRequest
    ) throws -> ClipboardPasteboardWriteLease {
        guard case let .write(writeResult) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        applyWriteTerminalBookkeeping(writeResult)
        switch writeResult.status {
        case .succeeded:
            return ClipboardPasteboardWriteLease(
                changeCount: writeResult.afterChangeCount,
                brokerGeneration: performed.brokerGeneration
            )
        case .changed:
            throw ClipboardBrokerClientError.writeChanged
        case .failed:
            throw ClipboardBrokerClientError.writeFailed
        }
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        guard lease.brokerGeneration == generation else { return false }
        do {
            let performed = try await perform(
                command: .validate(ClipboardBrokerValidateRequest(
                    expectedChangeCount: lease.changeCount
                )),
                priority: .explicit
            )
            guard case let .validation(result) = performed.terminal else {
                return false
            }
            cachedChangeCount = result.changeCount
            return result.current
                && lease.brokerGeneration == performed.brokerGeneration
        } catch {
            return false
        }
    }

    func generationIsCurrent(_ brokerGeneration: UInt64) async -> Bool {
        brokerGeneration == generation && process?.isRunning == true
    }

    func currentPlainText(
        limit: Int
    ) async throws -> ClipboardBrokerPlainTextResult {
        let performed = try await perform(
            command: .currentPlainText(ClipboardBrokerPlainTextRequest(
                maximumCharacterCount: limit
            )),
            priority: .explicit
        )
        guard case let .plainText(result) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        cachedChangeCount = result.changeCount
        return result
    }

    func snapshot() async throws -> ClipboardBrokerSnapshotResult {
        let performed = try await perform(
            command: .snapshot(ClipboardBrokerSnapshotRequest()),
            priority: .explicit,
            timeout: .seconds(1)
        )
        guard case let .snapshot(result) = performed.terminal else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        cachedChangeCount = result.changeCount
        return result
    }

    func suppressExternalChangeCounts(
        _ changeCounts: [Int]
    ) async {
        suppressedChangeCounts.formUnion(
            changeCounts.filter { $0 > 0 }
        )
        trimSuppressedChangeCounts()
    }

    func updatePassiveMonitoring(
        ownerID: UUID,
        revision: UInt64,
        active: Bool
    ) async {
        if let current = passiveMonitoringOwners[ownerID],
           revision <= current.revision {
            return
        }
        // Keep the latest inactive revision as a tombstone. The production
        // service owns one stable ID, and the tombstone prevents a late start
        // task from reactivating monitoring after stop().
        passiveMonitoringOwners[ownerID] = PassiveMonitoringOwnerState(
            revision: revision,
            active: active
        )
        if active {
            idleReapTask?.cancel()
            idleReapTask = nil
        } else {
            scheduleIdleReap()
        }
    }

    func shutdown() async {
        guard !shuttingDown else {
            await waitForShutdownToFinish()
            return
        }
        shuttingDown = true
        defer {
            shuttingDown = false
            resumeShutdownWaiters()
        }
        explicitPreparation?.task.cancel()
        explicitPreparation = nil
        removeAllOutstandingPreparedWrites()
        idleReapTask?.cancel()
        idleReapTask = nil

        // A commit owns an irreversible clear/write sequence once the Broker
        // accepts it.  Do not terminate the helper between those operations:
        // shutdown is final cleanup and must wait for that terminal response
        // even if its caller task has already been cancelled.
        await waitForInFlightCommitDuringShutdown(
            gracePeriod: Self.shutdownCommitGracePeriod
        )

        if process?.isRunning == true, pendingRequests.isEmpty {
            _ = try? await perform(
                command: .shutdown,
                priority: .explicit,
                allowsDuringShutdown: true,
                allowsLaunch: false
            )
        }
        if process != nil || !pendingRequests.isEmpty {
            terminateBroker(
                reason: "shutdown",
                signal: SIGTERM,
                error: .brokerTerminated
            )
        }
        ClipboardBrokerDataTransport.removeRoot()
    }

    private func waitForShutdownToFinish() async {
        guard shuttingDown else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard shuttingDown else {
                    continuation.resume()
                    return
                }
                shutdownWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelShutdownWaiter(waiterID)
            }
        }
    }

    private func cancelShutdownWaiter(_ waiterID: UUID) {
        guard let continuation = shutdownWaiters.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        continuation.resume()
    }

    private func resumeShutdownWaiters() {
        let waiters = shutdownWaiters.values
        shutdownWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func waitForInFlightCommitDuringShutdown(
        gracePeriod: Duration
    ) async {
        guard pendingRequests.values.contains(where: {
            $0.operation == .commitWrite
        }) else {
            return
        }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            guard pendingRequests.values.contains(where: {
                $0.operation == .commitWrite
            }) else {
                continuation.resume()
                return
            }
            shutdownCommitSettlementWaiters[waiterID] = continuation
            shutdownCommitTimeoutTasks[waiterID] = Task { [weak self] in
                do {
                    try await Task.sleep(for: gracePeriod)
                } catch {
                    return
                }
                await self?.finishShutdownCommitGracePeriod(waiterID)
            }
        }
    }

    private func finishShutdownCommitGracePeriod(_ waiterID: UUID) {
        guard let continuation = shutdownCommitSettlementWaiters.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        shutdownCommitTimeoutTasks[waiterID]?.cancel()
        shutdownCommitTimeoutTasks[waiterID] = nil
        continuation.resume()
    }

    func diagnostics() -> ClipboardBrokerClientDiagnostics {
        ClipboardBrokerClientDiagnostics(
            processIdentifier: process?.isRunning == true
                ? process?.processIdentifier
                : nil,
            generation: generation,
            pendingRequestCount: pendingRequests.count,
            circuitIsOpen: circuitOpenUntil.map { $0 > Date() } ?? false
        )
    }

    private func perform(
        command: ClipboardBrokerCommand,
        priority: RequestPriority,
        priorityWasPrepared: Bool = false,
        allowsDuringShutdown: Bool = false,
        allowsLaunch: Bool = true,
        cancellationBehavior: RequestCancellationBehavior = .terminateBroker,
        timeout: Duration? = .seconds(1)
    ) async throws -> PerformedRequest {
        guard !shuttingDown || allowsDuringShutdown else {
            throw ClipboardBrokerClientError.brokerTerminated
        }
        idleReapTask?.cancel()
        idleReapTask = nil
        if !priorityWasPrepared {
            try prepareForPriority(priority)
        }

        let request = ClipboardBrokerRequestEnvelope(command: command)
        let frame = try ClipboardBrokerFrameCodec.frame(request)
        if allowsLaunch {
            try launchBrokerIfNeeded()
        } else {
            guard process?.isRunning == true else {
                throw ClipboardBrokerClientError.brokerTerminated
            }
        }
        guard let requestInputChannel, let process else {
            throw ClipboardBrokerClientError.launchFailed
        }
        let processIdentifier = process.processIdentifier
        let requestGeneration = generation
        let startMessage = "event=request-start request=\(request.requestID.uuidString) operation=\(command.operation.rawValue) pid=\(processIdentifier) generation=\(requestGeneration) frameBytes=\(frame.count)"
        if command.operation == .observe || command.operation == .baseline {
            Self.logger.debug("\(startMessage, privacy: .public)")
        } else {
            Self.logger.info("\(startMessage, privacy: .public)")
        }

        let terminal: ClipboardBrokerTerminalResult
        do {
            terminal = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingRequests[request.requestID] = PendingRequest(
                        operation: command.operation,
                        priority: priority,
                        startedAt: .now,
                        startedChangeCount: nil,
                        continuation: continuation,
                        timeoutTask: nil
                    )
                    if let timeout {
                        pendingRequests[request.requestID]?.timeoutTask = Task { [weak self] in
                            do {
                                try await Task.sleep(for: timeout)
                            } catch {
                                return
                            }
                            await self?.requestTimedOut(
                                requestID: request.requestID,
                                requestGeneration: requestGeneration
                            )
                        }
                    }
                    let dispatchData = frame.withUnsafeBytes {
                        DispatchData(bytes: $0)
                    }
                    requestInputChannel.write(
                        offset: 0,
                        data: dispatchData,
                        queue: requestIOQueue
                    ) { [weak self] done, _, error in
                        guard done, error != 0 else { return }
                        Task {
                            await self?.pipeWriteFailed(
                                requestID: request.requestID,
                                requestGeneration: requestGeneration
                            )
                        }
                    }
                }
            } onCancel: {
                guard cancellationBehavior == .terminateBroker else {
                    return
                }
                Task { [weak self] in
                    await self?.cancelRequest(request.requestID)
                }
            }
        } catch {
            scheduleIdleReap()
            throw error
        }
        scheduleIdleReap()
        // A commit terminal is authoritative once the response reader has
        // accepted it. Shutdown may now terminate the Broker before this
        // resumed continuation retakes the actor, which advances generation;
        // do not turn that completed commit into brokerTerminated. Requests
        // without an accepted terminal still fail through terminateBroker,
        // and every other operation retains the generation guard.
        guard requestGeneration == generation
                || command.operation == .commitWrite else {
            throw ClipboardBrokerClientError.brokerTerminated
        }
        return PerformedRequest(
            terminal: terminal,
            brokerGeneration: requestGeneration
        )
    }

    private func prepareForPriority(
        _ priority: RequestPriority
    ) throws {
        expirePreparedWritesIfNeeded()
        guard explicitPreparation == nil else {
            throw ClipboardBrokerClientError.requestSuperseded
        }
        // Prepared-write IDs live only inside the current Broker process.
        // Starting any passive request while one is outstanding would let a
        // later explicit commit preempt that request by terminating the Broker,
        // losing the prepared state. Keep the process quiescent until every
        // prepared write is committed or cancelled.
        if priority == .passive,
           !outstandingPreparedWrites.isEmpty {
            throw ClipboardBrokerClientError.requestSuperseded
        }
        if priority == .explicit,
           pendingRequests.values.contains(where: { $0.priority == .passive }) {
            terminateBroker(
                reason: "explicit-preempt",
                signal: SIGKILL,
                error: .requestSuperseded
            )
        } else if !pendingRequests.isEmpty {
            throw ClipboardBrokerClientError.requestSuperseded
        }
    }

    private nonisolated static func stageLargeImagePayloads(
        in request: ClipboardBrokerWriteRequest
    ) throws -> ClipboardBrokerWriteRequest {
        var newlyStagedReferences: [ClipboardBrokerDataReference] = []
        do {
            let items = try request.items.map { item in
                let representations = try item.representations.map { entry in
                    try Task.checkCancellation()
                    guard stagedImagePasteboardTypes.contains(
                        entry.pasteboardType
                    ),
                    case let .data(.inline(data)) = entry.value else {
                        return entry
                    }
                    let reference = try ClipboardBrokerDataTransport.reference(
                        for: data,
                        stagesLargePayload: true
                    )
                    if case .staged = reference {
                        newlyStagedReferences.append(reference)
                    }
                    return ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: entry.pasteboardType,
                        value: .data(reference)
                    )
                }
                return ClipboardBrokerWriteItem(
                    representations: representations,
                    semanticFileURLString: item.semanticFileURLString
                )
            }
            try Task.checkCancellation()
            return ClipboardBrokerWriteRequest(
                items: items,
                expectedChangeCount: request.expectedChangeCount
            )
        } catch {
            for reference in newlyStagedReferences {
                ClipboardBrokerDataTransport.removeStagedReference(reference)
            }
            throw error
        }
    }

    private func preflightWriteRequest(
        _ request: ClipboardBrokerWriteRequest
    ) throws {
        guard !request.items.isEmpty, request.items.count <= 64 else {
            throw ClipboardBrokerClientError.malformedResponse
        }

        var representationCount = 0
        var totalByteCount = 0
        func addByteCount(_ count: Int) throws {
            guard count >= 0,
                  count <= ClipboardBrokerLimits.maxFrameBytes - totalByteCount
            else {
                throw ClipboardBrokerClientError.requestOversized
            }
            totalByteCount += count
        }

        for item in request.items {
            if let semanticFileURLString = item.semanticFileURLString {
                guard item.representations.isEmpty,
                      semanticFileURLString.utf8.count
                        <= ClipboardBrokerLimits.maxTextBytes,
                      let fileURL = URL(string: semanticFileURLString),
                      fileURL.isFileURL else {
                    throw ClipboardBrokerClientError.malformedResponse
                }
                representationCount += 1
                guard representationCount <= 256 else {
                    throw ClipboardBrokerClientError.malformedResponse
                }
                try addByteCount(semanticFileURLString.utf8.count)
                continue
            }
            guard !item.representations.isEmpty else {
                throw ClipboardBrokerClientError.malformedResponse
            }
            var seenTypes = Set<String>()
            for entry in item.representations {
                try Task.checkCancellation()
                guard !entry.pasteboardType.isEmpty,
                      seenTypes.insert(entry.pasteboardType).inserted else {
                    throw ClipboardBrokerClientError.malformedResponse
                }
                representationCount += 1
                guard representationCount <= 256 else {
                    throw ClipboardBrokerClientError.malformedResponse
                }

                switch entry.value {
                case let .string(value):
                    let byteCount = value.utf8.count
                    guard byteCount <= Self.stringLimit(
                        for: entry.pasteboardType
                    ) else {
                        throw ClipboardBrokerClientError.requestOversized
                    }
                    try addByteCount(byteCount)

                case let .data(reference):
                    guard reference.byteCount <= Self.dataLimit(
                        for: entry.pasteboardType
                    ) else {
                        throw ClipboardBrokerClientError.requestOversized
                    }
                    try addByteCount(reference.byteCount)

                case let .stringList(values):
                    var listByteCount = 0
                    for value in values {
                        let valueByteCount = value.utf8.count
                        guard valueByteCount
                            <= ClipboardBrokerLimits.maxTextBytes
                                - listByteCount else {
                            throw ClipboardBrokerClientError.requestOversized
                        }
                        listByteCount += valueByteCount
                    }
                    try addByteCount(listByteCount)
                }
            }
        }
    }

    private static func stringLimit(for pasteboardType: String) -> Int {
        pasteboardType == "public.rtf"
            ? ClipboardBrokerLimits.maxRTFBytes
            : ClipboardBrokerLimits.maxTextBytes
    }

    private static func dataLimit(for pasteboardType: String) -> Int {
        switch pasteboardType {
        case "public.png":
            ClipboardBrokerLimits.maxCanonicalPNGBytes
        case "public.tiff":
            ClipboardBrokerLimits.maxRawImageBytes
        case "public.rtf":
            ClipboardBrokerLimits.maxRTFBytes
        default:
            ClipboardBrokerLimits.maxFrameBytes
        }
    }

    private func launchBrokerIfNeeded() throws {
        if let process {
            if process.isRunning { return }
            terminateBroker(
                reason: "stale-process",
                signal: SIGKILL,
                error: .brokerTerminated,
                sendsSignal: false
            )
        }
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClipboardBrokerClientError.executableUnavailable
        }
        let stagingIdentity = try ClipboardBrokerDataTransport.rootIdentity()
        var launchCompleted = false
        defer {
            if !launchCompleted {
                ClipboardBrokerDataTransport.removeRoot()
            }
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let launchedProcess = Process()
        launchedProcess.executableURL = executableURL
        launchedProcess.arguments = executableArguments
        launchedProcess.standardInput = inputPipe.fileHandleForReading
        launchedProcess.standardOutput = outputPipe.fileHandleForWriting
        let inheritedEnvironment = ProcessInfo.processInfo.environment
#if DEBUG
        // Broker stderr is normally discarded because the wire protocol owns
        // stdout. Unit-test hosts inherit stderr so an early helper crash is
        // diagnosable instead of collapsing into an opaque pipe EOF.
        launchedProcess.standardError =
            inheritedEnvironment["BLOCKS_UNIT_TESTING"] == "1"
                ? FileHandle.standardError
                : FileHandle.nullDevice
#else
        launchedProcess.standardError = FileHandle.nullDevice
#endif
        var environment: [String: String] = [:]
        for key in [
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "__CF_USER_TEXT_ENCODING",
            "OS_ACTIVITY_MODE",
        ] {
            environment[key] = inheritedEnvironment[key]
        }
        environment["BLOCKS_CLIPBOARD_STAGING_ROOT"] =
            stagingIdentity.url.path
        environment["BLOCKS_CLIPBOARD_STAGING_DEVICE"] =
            String(stagingIdentity.device)
        environment["BLOCKS_CLIPBOARD_STAGING_INODE"] =
            String(stagingIdentity.inode)
        environment["BLOCKS_CLIPBOARD_PARENT_PID"] = String(getpid())
#if DEBUG
        for (key, value) in environmentOverrides
        where key.hasPrefix("BLOCKS_CLIPBOARD_BROKER_TEST_") {
            environment[key] = value
        }
#endif
        launchedProcess.environment = environment
        let launchedIdentity = UUID()
        launchedProcess.terminationHandler = { [weak self, weak launchedProcess] process in
            guard let launchedProcess, process === launchedProcess else { return }
            Task {
                await self?.brokerTerminated(
                    processIdentifier: process.processIdentifier,
                    launchIdentity: launchedIdentity
                )
            }
        }
        do {
            try launchedProcess.run()
        } catch {
            inputPipe.fileHandleForReading.closeFile()
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            outputPipe.fileHandleForWriting.closeFile()
            throw ClipboardBrokerClientError.launchFailed
        }

        // The child owns the opposite pipe ends after Process.run(). Closing the
        // parent copies is essential: a killed Broker must make pending writes
        // fail with EPIPE and response reads reach EOF.
        inputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()

        let requestDescriptor = dup(inputPipe.fileHandleForWriting.fileDescriptor)
        inputPipe.fileHandleForWriting.closeFile()
        guard requestDescriptor >= 0 else {
            _ = Darwin.kill(launchedProcess.processIdentifier, SIGKILL)
            outputPipe.fileHandleForReading.closeFile()
            throw ClipboardBrokerClientError.launchFailed
        }
        guard fcntl(requestDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            Darwin.close(requestDescriptor)
            _ = Darwin.kill(launchedProcess.processIdentifier, SIGKILL)
            outputPipe.fileHandleForReading.closeFile()
            throw ClipboardBrokerClientError.launchFailed
        }
        let requestChannel = DispatchIO(
            type: .stream,
            fileDescriptor: requestDescriptor,
            queue: requestIOQueue
        ) { _ in
            Darwin.close(requestDescriptor)
        }
        requestChannel.setLimit(lowWater: 1)

        process = launchedProcess
        launchIdentity = launchedIdentity
        requestInputChannel = requestChannel
        responseOutput = outputPipe.fileHandleForReading
        responseBuffer.removeAll(keepingCapacity: true)
        generation &+= 1
        let launchedGeneration = generation
        let processIdentifier = launchedProcess.processIdentifier
        let responseHandle = outputPipe.fileHandleForReading
        responseReaderTask = Task.detached(priority: .userInitiated) { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(
                        responseHandle.fileDescriptor,
                        $0.baseAddress,
                        $0.count
                    )
                }
                if count > 0 {
                    await self?.receive(
                        Data(bytes.prefix(Int(count))),
                        generation: launchedGeneration
                    )
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    break
                }
            }
            await self?.responseReaderFinished(
                processIdentifier: processIdentifier,
                generation: launchedGeneration
            )
        }
        requiresBaselineAfterRestart = true
        if generation > 1 {
            Self.logger.info(
                "event=restarted pid=\(launchedProcess.processIdentifier) generation=\(self.generation)"
            )
        } else {
            Self.logger.info(
                "event=started pid=\(launchedProcess.processIdentifier) generation=\(self.generation)"
            )
        }
        launchCompleted = true
    }

    private func receive(_ data: Data, generation responseGeneration: UInt64) {
        guard responseGeneration == generation, !data.isEmpty else { return }
        responseBuffer.append(data)
        do {
            while let payload = try ClipboardBrokerFrameCodec.takePayload(
                from: &responseBuffer
            ) {
                let response = try PropertyListDecoder().decode(
                    ClipboardBrokerResponseEnvelope.self,
                    from: payload
                )
                handle(response)
            }
        } catch {
            terminateBroker(
                reason: "malformed-response",
                signal: SIGKILL,
                error: .malformedResponse
            )
        }
    }

    private func responseReaderFinished(
        processIdentifier: pid_t,
        generation responseGeneration: UInt64
    ) {
        guard responseGeneration == generation,
              process?.processIdentifier == processIdentifier else {
            return
        }
        terminateBroker(
            reason: "pipe-eof",
            signal: SIGKILL,
            error: .brokerTerminated
        )
    }

    private func pipeWriteFailed(
        requestID: UUID,
        requestGeneration: UInt64
    ) {
        guard requestGeneration == generation,
              pendingRequests[requestID] != nil else {
            return
        }
        failRequest(
            requestID,
            error: ClipboardBrokerClientError.brokerTerminated
        )
        terminateBroker(
            reason: "pipe-write-failed",
            signal: SIGKILL,
            error: .brokerTerminated
        )
    }

    private func handle(_ response: ClipboardBrokerResponseEnvelope) {
        guard var pending = pendingRequests[response.requestID] else { return }
        switch response.event {
        case let .started(operation, changeCount):
            guard operation == pending.operation else {
                terminateBroker(
                    reason: "operation-mismatch",
                    signal: SIGKILL,
                    error: .malformedResponse
                )
                return
            }
            pending.startedChangeCount = changeCount
            pendingRequests[response.requestID] = pending
            Self.logger.debug(
                "event=operation-started request=\(response.requestID.uuidString, privacy: .public) operation=\(operation.rawValue, privacy: .public) changeCount=\(changeCount ?? -1)"
            )
        case let .terminal(result):
            pending.timeoutTask?.cancel()
            applyTerminalBookkeeping(result, operation: pending.operation)
            resumeTerminalResponse(response, pending: pending, result: result)
        }
    }

    private func applyTerminalBookkeeping(
        _ result: ClipboardBrokerTerminalResult,
        operation: ClipboardBrokerOperation
    ) {
        switch (operation, result) {
        case let (.prepareWrite, .preparedWrite(prepared)):
            trackOutstandingPreparedWrite(
                prepared,
                brokerGeneration: generation
            )
        case let (.write, .write(writeResult)),
             let (.commitWrite, .write(writeResult)):
            applyWriteTerminalBookkeeping(writeResult)
        default:
            break
        }
    }

    private func applyWriteTerminalBookkeeping(
        _ writeResult: ClipboardBrokerWriteResult
    ) {
        if writeResult.status == .succeeded {
            cachedChangeCount = writeResult.afterChangeCount
            suppressedChangeCounts.formUnion(writeResult.changedCounts)
        } else {
            // The returned current count can be an external publication, so
            // preserve the prior observation baseline while allowing the next
            // observe to inspect it instead of consuming a restart baseline.
            requiresBaselineAfterRestart = false
        }
        trimSuppressedChangeCounts()
    }

    private func resumeTerminalResponse(
        _ response: ClipboardBrokerResponseEnvelope,
        pending: PendingRequest,
        result: ClipboardBrokerTerminalResult
    ) {
        guard pendingRequests[response.requestID] != nil else { return }
        pendingRequests[response.requestID] = nil
        if pending.operation == .commitWrite {
            resumeCommitSettlementWaitersIfPossible()
        }
        let elapsed = Self.elapsedMilliseconds(since: pending.startedAt)
        if case let .failure(code) = result {
            Self.logger.error(
                "event=request-failed request=\(response.requestID.uuidString, privacy: .public) operation=\(pending.operation.rawValue, privacy: .public) pid=\(self.process?.processIdentifier ?? 0) generation=\(self.generation) code=\(code, privacy: .public) elapsedMS=\(elapsed)"
            )
            pending.continuation.resume(
                throwing: ClipboardBrokerClientError.brokerFailure(code)
            )
            return
        }
        let finishMessage = "event=request-finished request=\(response.requestID.uuidString) operation=\(pending.operation.rawValue) pid=\(self.process?.processIdentifier ?? 0) generation=\(self.generation) elapsedMS=\(elapsed)"
        if pending.operation == .observe || pending.operation == .baseline {
            Self.logger.debug("\(finishMessage, privacy: .public)")
        } else {
            Self.logger.info("\(finishMessage, privacy: .public)")
        }
        pending.continuation.resume(returning: result)
    }

    private func requestTimedOut(
        requestID: UUID,
        requestGeneration: UInt64
    ) {
        guard requestGeneration == generation,
              let pending = pendingRequests[requestID] else {
            return
        }
        if pending.priority == .passive {
            switch pending.operation {
            case .observe:
                poisonedChangeCount = pending.startedChangeCount
                recordPassiveRestart()
            case .baseline:
                recordPassiveRestart()
            default:
                break
            }
        }
        Self.logger.error(
            "event=timeout request=\(requestID.uuidString, privacy: .public) operation=\(pending.operation.rawValue, privacy: .public) pid=\(self.process?.processIdentifier ?? 0) generation=\(self.generation) elapsedMS=\(Self.elapsedMilliseconds(since: pending.startedAt))"
        )
        terminateBroker(
            reason: "request-timeout",
            signal: SIGKILL,
            error: .requestTimedOut
        )
    }

    private func recordPassiveRestart() {
        let now = Date()
        passiveRestartDates = passiveRestartDates.filter {
            now.timeIntervalSince($0) <= Self.passiveRestartWindow
        }
        passiveRestartDates.append(now)
        if passiveRestartDates.count >= Self.passiveRestartLimit {
            circuitOpenUntil = now.addingTimeInterval(Self.circuitBreakerDuration)
            passiveRestartDates.removeAll()
            Self.logger.error(
                "event=circuit-open durationSeconds=\(Int(Self.circuitBreakerDuration))"
            )
        }
    }

    private func cancelRequest(_ requestID: UUID) {
        guard pendingRequests[requestID] != nil else { return }
        terminateBroker(
            reason: "request-cancelled",
            signal: SIGKILL,
            error: .requestSuperseded
        )
    }

    private func brokerTerminated(
        processIdentifier: pid_t,
        launchIdentity terminatedLaunchIdentity: UUID
    ) {
        guard launchIdentity == terminatedLaunchIdentity,
              process?.processIdentifier == processIdentifier else {
            return
        }
        if let passive = pendingRequests.values.first(where: {
            $0.priority == .passive && $0.operation == .observe
        }) {
            poisonedChangeCount = passive.startedChangeCount
            recordPassiveRestart()
        }
        terminateBroker(
            reason: shuttingDown ? "shutdown-complete" : "unexpected-exit",
            signal: SIGKILL,
            error: .brokerTerminated,
            sendsSignal: false
        )
    }

    private func failRequest(_ requestID: UUID, error: ClipboardBrokerClientError) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        if pending.operation == .commitWrite {
            resumeCommitSettlementWaitersIfPossible()
        }
        pending.continuation.resume(throwing: error)
    }

    private func terminateBroker(
        reason: String,
        signal: Int32,
        error: ClipboardBrokerClientError,
        sendsSignal: Bool = true
    ) {
        idleReapTask?.cancel()
        idleReapTask = nil
        removeAllOutstandingPreparedWrites()
        let terminatedProcess = process
        let processIdentifier = terminatedProcess?.processIdentifier ?? 0
        if sendsSignal, let terminatedProcess, terminatedProcess.isRunning {
            _ = Darwin.kill(terminatedProcess.processIdentifier, signal)
        }
        requestInputChannel?.close(flags: .stop)
        requestInputChannel = nil
        responseReaderTask?.cancel()
        responseReaderTask = nil
        // Do not synchronously close a FileHandle while its detached reader is
        // blocked. Killing the Broker closes the child pipe end, so the reader
        // reaches EOF and releases its handle without blocking this actor.
        responseOutput = nil
        process = nil
        launchIdentity = nil
        responseBuffer.removeAll(keepingCapacity: true)
        generation &+= 1
        requiresBaselineAfterRestart = true

        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
        resumeCommitSettlementWaitersIfPossible()

        ClipboardBrokerDataTransport.removeRoot()
        Self.logger.error(
            "event=killed reason=\(reason, privacy: .public) pid=\(processIdentifier) signal=\(signal) generation=\(self.generation)"
        )
    }

    private func scheduleIdleReap() {
        idleReapTask?.cancel()
        guard !passiveMonitoringIsActive,
              explicitPreparation == nil,
              outstandingPreparedWrites.isEmpty,
              process?.isRunning == true,
              pendingRequests.isEmpty else {
            idleReapTask = nil
            return
        }
        let scheduledGeneration = generation
        idleReapTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.idleReapDelay)
            } catch {
                return
            }
            await self?.reapIdleBroker(
                scheduledGeneration: scheduledGeneration
            )
        }
    }

    private func reapIdleBroker(scheduledGeneration: UInt64) {
        guard generation == scheduledGeneration,
              !passiveMonitoringIsActive,
              explicitPreparation == nil,
              outstandingPreparedWrites.isEmpty,
              pendingRequests.isEmpty,
              process?.isRunning == true else {
            return
        }
        terminateBroker(
            reason: "idle-reap",
            signal: SIGKILL,
            error: .brokerTerminated
        )
    }

    private func trackOutstandingPreparedWrite(
        _ prepared: ClipboardBrokerPreparedWriteResult,
        brokerGeneration: UInt64
    ) {
        let preparedWriteID = prepared.preparedWriteID
        let state = OutstandingPreparedWrite(
            expiresAtSystemUptime: prepared.expiresAtSystemUptime,
            brokerGeneration: brokerGeneration
        )
        outstandingPreparedWrites[preparedWriteID] = state
        preparedWriteExpiryTasks[preparedWriteID]?.cancel()
        preparedWriteExpiryTasks[preparedWriteID] = Task { [weak self] in
            await self?.waitForPreparedWriteExpiry(
                preparedWriteID,
                expectedState: state
            )
        }
    }

    private func waitForPreparedWriteExpiry(
        _ preparedWriteID: UUID,
        expectedState: OutstandingPreparedWrite
    ) async {
        while !Task.isCancelled {
            let remaining = expectedState.expiresAtSystemUptime
                - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                expirePreparedWrite(
                    preparedWriteID,
                    expectedState: expectedState
                )
                return
            }
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
        }
    }

    private func expirePreparedWritesIfNeeded(
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let expired = outstandingPreparedWrites.compactMap { id, state in
            state.expiresAtSystemUptime <= systemUptime ? id : nil
        }
        guard !expired.isEmpty else { return }
        for preparedWriteID in expired {
            removeOutstandingPreparedWrite(preparedWriteID)
        }
        scheduleIdleReap()
    }

    private func expirePreparedWrite(
        _ preparedWriteID: UUID,
        expectedState: OutstandingPreparedWrite
    ) {
        guard outstandingPreparedWrites[preparedWriteID] == expectedState,
              expectedState.brokerGeneration == generation,
              expectedState.expiresAtSystemUptime
                <= ProcessInfo.processInfo.systemUptime else {
            return
        }
        removeOutstandingPreparedWrite(preparedWriteID)
        scheduleIdleReap()
    }

    private func removeOutstandingPreparedWrite(_ preparedWriteID: UUID) {
        outstandingPreparedWrites[preparedWriteID] = nil
        preparedWriteExpiryTasks[preparedWriteID]?.cancel()
        preparedWriteExpiryTasks[preparedWriteID] = nil
    }

    private func removeAllOutstandingPreparedWrites() {
        outstandingPreparedWrites.removeAll()
        preparedWriteExpiryTasks.values.forEach { $0.cancel() }
        preparedWriteExpiryTasks.removeAll()
    }

    private var passiveMonitoringIsActive: Bool {
        passiveMonitoringOwners.values.contains(where: \.active)
    }

    private func trimSuppressedChangeCounts() {
        if suppressedChangeCounts.count > 24 {
            suppressedChangeCounts = Set(suppressedChangeCounts.sorted().suffix(12))
        }
    }

    private static func elapsedMilliseconds(
        since startedAt: ContinuousClock.Instant
    ) -> Int {
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        return max(
            0,
            Int(
                Double(components.seconds) * 1_000
                    + Double(components.attoseconds) / 1_000_000_000_000_000
            )
        )
    }
}
