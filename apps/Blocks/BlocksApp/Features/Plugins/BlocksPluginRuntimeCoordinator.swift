import BlocksCore
import CryptoKit
import Darwin
import Foundation

/// Serializes the short interval between durable outcome accounting and the
/// MainActor lifecycle cutoff.  Runner replies deliberately capture a token
/// before leaving the actor; a reply which crosses a safety/reload settlement
/// must not subsequently mutate host state, request actions, or block a hook.
@MainActor
final class PluginExecutionSettlementGate {
    struct Token: Sendable {
        fileprivate let pluginID: String
        fileprivate let hookID: String?
        fileprivate let pluginGeneration: UInt64
        fileprivate let hookGeneration: UInt64
        fileprivate let globalGeneration: UInt64
    }

    private struct Key: Hashable { let pluginID: String; let hookID: String? }
    private var pluginGenerations: [String: UInt64] = [:]
    private var hookGenerations: [Key: UInt64] = [:]
    private var globalGeneration: UInt64 = 0
    private var pendingKeyCounts: [Key: Int] = [:]
    private var pendingPluginCounts: [String: Int] = [:]
    private var globalPendingCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Internal test seam. Production leaves this nil; it exposes only the
    // point after a continuation is durably registered in `waiters`.
    var onWaiterRegistered: (() -> Void)?

    func captureToken(pluginID: String, hookID: String? = nil) -> Token {
        let key = Key(pluginID: pluginID, hookID: hookID)
        return Token(pluginID: pluginID, hookID: hookID,
                     pluginGeneration: pluginGenerations[pluginID, default: 0],
                     hookGeneration: hookGenerations[key, default: 0],
                     globalGeneration: globalGeneration)
    }

    /// Must be called synchronously on MainActor before the detached SQLite
    /// transaction begins.
    func beginOutcomeSettlement(_ token: Token) {
        let key = Key(pluginID: token.pluginID, hookID: token.hookID)
        pendingKeyCounts[key, default: 0] += 1
        pendingPluginCounts[token.pluginID, default: 0] += 1
    }

    func beginGlobalSettlement() { globalPendingCount += 1 }

    func invalidatePlugin(_ pluginID: String) {
        pluginGenerations[pluginID, default: 0] &+= 1
        resumeWaiters()
    }

    func authorizeEffects(_ token: Token) async -> Bool {
        let key = Key(pluginID: token.pluginID, hookID: token.hookID)
        while globalPendingCount > 0 || pendingKeyCounts[key, default: 0] > 0
            || pendingPluginCounts[token.pluginID, default: 0] > 0 {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                onWaiterRegistered?()
            }
        }
        return token.globalGeneration == globalGeneration
            && token.pluginGeneration == pluginGenerations[token.pluginID, default: 0]
            && token.hookGeneration == hookGenerations[key, default: 0]
    }

    func finishOutcomeSettlement(_ token: Token, invalidatePlugin: Bool = false,
                                 invalidateHook: Bool = false) {
        let key = Key(pluginID: token.pluginID, hookID: token.hookID)
        if invalidatePlugin { pluginGenerations[token.pluginID, default: 0] &+= 1 }
        if invalidateHook { hookGenerations[key, default: 0] &+= 1 }
        let keyRemaining = pendingKeyCounts[key, default: 1] - 1
        if keyRemaining == 0 { pendingKeyCounts.removeValue(forKey: key) }
        else { pendingKeyCounts[key] = keyRemaining }
        let remaining = pendingPluginCounts[token.pluginID, default: 1] - 1
        if remaining == 0 { pendingPluginCounts.removeValue(forKey: token.pluginID) }
        else { pendingPluginCounts[token.pluginID] = remaining }
        resumeWaiters()
    }

    /// A failed recovery deliberately invalidates all captured replies so they
    /// fail open rather than applying a snapshot which is no longer trusted.
    func finishGlobalSettlement(invalidatingPluginIDs: Set<String> = [],
                                invalidateAll: Bool = false) {
        for pluginID in invalidatingPluginIDs { pluginGenerations[pluginID, default: 0] &+= 1 }
        if invalidateAll { globalGeneration &+= 1 }
        globalPendingCount = max(0, globalPendingCount - 1)
        resumeWaiters()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// A synchronous admission barrier for host operations issued by the isolated
/// plugin runner.  This deliberately avoids actor isolation: the XPC callback
/// is synchronous and must not wait on the main actor while a lifecycle change
/// is draining work that has already entered the callback.
final class BlocksPluginHostOperationAdmissionGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: BlocksPluginHostOperationAdmissionGate?
        private let pluginID: String

        fileprivate init(
            gate: BlocksPluginHostOperationAdmissionGate,
            pluginID: String
        ) {
            self.gate = gate
            self.pluginID = pluginID
        }

        func release() {
            let gate = lock.withLock { () -> BlocksPluginHostOperationAdmissionGate? in
                defer { self.gate = nil }
                return self.gate
            }
            gate?.release(pluginID: pluginID)
        }

        deinit {
            release()
        }
    }

    private let condition = NSCondition()
    private var globallyRevoked = false
    private var permanentlyRevoked = false
    private var revokedPluginIDs: Set<String> = []
    private var activeOperationCounts: [String: Int] = [:]
    private let admissionCheckpoint: (@Sendable (String) -> Void)?

    init(
        admissionCheckpoint: (@Sendable (String) -> Void)? = nil
    ) {
        self.admissionCheckpoint = admissionCheckpoint
    }

    func withAdmittedOperation<T>(
        pluginID: String,
        _ body: () throws -> T
    ) throws -> T {
        let lease = try acquire(pluginID: pluginID)
        defer { lease.release() }
        return try body()
    }

    /// Async host actions retain this lease across their awaited handler. The
    /// same counter therefore forms one lifecycle barrier for synchronous XPC
    /// requests and asynchronous business actions.
    func acquire(pluginID: String) throws -> Lease {
        condition.lock()
        guard !globallyRevoked, !revokedPluginIDs.contains(pluginID) else {
            condition.unlock()
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "plugin_host_operations_unavailable"
            )
        }
        activeOperationCounts[pluginID, default: 0] += 1
        condition.unlock()

        admissionCheckpoint?(pluginID)
        return Lease(gate: self, pluginID: pluginID)
    }

    private func release(pluginID: String) {
        condition.lock()
        let remaining = activeOperationCounts[pluginID, default: 1] - 1
        if remaining == 0 {
            activeOperationCounts.removeValue(forKey: pluginID)
        } else {
            activeOperationCounts[pluginID] = remaining
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Setting the revocation flag while holding `condition` is the admission
    /// linearization point.  The following wait makes a completed lifecycle
    /// transition a barrier for every handler admitted before that point.
    func revokeAllAndDrain(permanently: Bool = false) {
        revokeAll(permanently: permanently)
        drainAll()
    }

    func revokeAll(permanently: Bool = false) {
        condition.lock()
        globallyRevoked = true
        permanentlyRevoked = permanentlyRevoked || permanently
        condition.unlock()
    }

    func drainAll() {
        condition.lock()
        while !activeOperationCounts.isEmpty {
            condition.wait()
        }
        condition.unlock()
    }

    func resumeAll() {
        condition.lock()
        if !permanentlyRevoked {
            globallyRevoked = false
        }
        condition.unlock()
    }

    /// Fast path used by the synchronous safe-mode toggle. If an async action
    /// is still holding a lease, the caller leaves admission closed and waits
    /// off the main actor before calling `resumeAll()`.
    func resumeAllIfDrained() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard activeOperationCounts.isEmpty else { return false }
        if !permanentlyRevoked {
            globallyRevoked = false
        }
        return !permanentlyRevoked
    }

    func revokeAndDrain(pluginID: String) {
        condition.lock()
        revokedPluginIDs.insert(pluginID)
        while activeOperationCounts[pluginID, default: 0] > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    /// Cuts off new operations synchronously without waiting for operations
    /// that already crossed the admission point. Lifecycle owners call this
    /// before hopping off the main actor to drain admitted work.
    func revoke(pluginID: String) {
        condition.lock()
        revokedPluginIDs.insert(pluginID)
        condition.unlock()
    }

    func drain(pluginID: String) {
        condition.lock()
        while activeOperationCounts[pluginID, default: 0] > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func allow(pluginID: String) {
        condition.lock()
        revokedPluginIDs.remove(pluginID)
        condition.unlock()
    }

    func isRevoked(pluginID: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return globallyRevoked || revokedPluginIDs.contains(pluginID)
    }
}

/// A feature owner may synchronously revoke an already-running module without
/// waiting for a non-cooperative runner. Tokens are intentionally usable from
/// the resource broker's lock-protected synchronous XPC path.
struct BlocksPluginFeatureAdmissionToken: Sendable, Hashable {
    let module: BlocksPluginModule
    fileprivate let generation: UInt64
}

final class BlocksPluginFeatureAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [BlocksPluginModule: UInt64] = [:]
    /// A module that has exhausted its generation space stays revoked. This
    /// deliberately sacrifices future feature dispatch instead of allowing a
    /// stale token to become current again after an integer wraparound.
    private var exhaustedModules: Set<BlocksPluginModule> = []

    /// Internal deterministic seam for boundary tests. Production uses the
    /// empty default and therefore always starts at generation zero.
    init(
        testingInitialGenerations: [BlocksPluginModule: UInt64] = [:]
    ) {
        generations = testingInitialGenerations
    }

    func capture(module: BlocksPluginModule) -> BlocksPluginFeatureAdmissionToken {
        lock.withLock {
            .init(module: module, generation: generations[module, default: 0])
        }
    }

    func invalidate(module: BlocksPluginModule) {
        lock.withLock {
            guard !exhaustedModules.contains(module) else { return }
            let generation = generations[module, default: 0]
            guard generation < UInt64.max else {
                exhaustedModules.insert(module)
                return
            }
            generations[module] = generation + 1
        }
    }

    func isCurrent(_ token: BlocksPluginFeatureAdmissionToken) -> Bool {
        lock.withLock {
            !exhaustedModules.contains(token.module)
                && generations[token.module, default: 0] == token.generation
        }
    }

    /// The final resource-read commit and `invalidate(module:)` are mutually
    /// exclusive. A request that reaches this boundary after invalidation
    /// fails instead of returning bytes authorized by an old token.
    func commitIfCurrent<T>(
        _ token: BlocksPluginFeatureAdmissionToken?,
        _ body: () -> T
    ) -> T? {
        lock.withLock {
            guard token.map({
                !exhaustedModules.contains($0.module)
                    && generations[$0.module, default: 0] == $0.generation
            }) ?? true else {
                return nil
            }
            return body()
        }
    }
}
import OSLog

final class BlocksPluginHostOperationRouter: @unchecked Sendable {
    typealias Handler = @Sendable (
        BlocksPluginHostOperationRequest
    ) -> BlocksPluginHostOperationResponse

    private let lock = NSLock()
    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func perform(
        _ request: BlocksPluginHostOperationRequest
    ) -> BlocksPluginHostOperationResponse {
        guard let handler = lock.withLock({ handler }) else {
            return .init(
                requestID: request.requestID,
                ok: false,
                errorCode: "plugin_runtime_not_ready",
                errorMessage: "The Blocks plugin runtime is not ready."
            )
        }
        return handler(request)
    }
}

final class BlocksPluginResourceBroker: @unchecked Sendable {
    private enum Backing {
        case data(Data)
        case file(URL, securityScoped: Bool, removeWhenReleased: Bool)
    }

    private struct Entry {
        let backing: Backing
        let reference: BlocksPluginResourceReference
    }

    private struct ScopedAuthorization {
        let pluginID: String
        let featureAdmission: BlocksPluginFeatureAdmissionToken?
    }

    private enum ReadAdmission {
        case unscopedOrNonFeatureScoped
        case featureScoped(BlocksPluginFeatureAdmissionToken)
    }

    private let lock = NSLock()
    private let stagingSessionDirectory: URL?
    private let stagingChunkHook: @Sendable () -> Void
    /// Internal deterministic seam for the feature-admission read boundary.
    /// Production uses the empty default.
    private let resourceReadCheckpoint: @Sendable () -> Void
    private let featureAdmissionGate: BlocksPluginFeatureAdmissionGate
    private var entries: [String: Entry] = [:]
    private var authorizedPluginIDsByResourceID:
        [String: Set<String>] = [:]
    private var scopedAuthorizationsByResourceID:
        [String: [UUID: ScopedAuthorization]] = [:]
    private var hostLeaseCountsByResourceID: [String: Int] = [:]
    private var pendingRemovalResourceIDs: Set<String> = []
    private var shutdownRequested = false
    private var activeStagingOperationCount = 0

    init(
        stagingBaseDirectory: URL? = nil,
        stagingChunkHook: @escaping @Sendable () -> Void = {},
        resourceReadCheckpoint: @escaping @Sendable () -> Void = {},
        featureAdmissionGate: BlocksPluginFeatureAdmissionGate = .init()
    ) {
        let baseDirectory = stagingBaseDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "BlocksPluginResources",
                    isDirectory: true
                )
        stagingSessionDirectory = Self.prepareStagingSession(
            baseDirectory: baseDirectory
        )
        self.stagingChunkHook = stagingChunkHook
        self.resourceReadCheckpoint = resourceReadCheckpoint
        self.featureAdmissionGate = featureAdmissionGate
    }

    deinit {
        shutdown()
    }

    func register(
        data: Data,
        kind: BlocksPluginResourceKind,
        mediaType: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) -> BlocksPluginResourceReference {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = BlocksPluginResourceReference(
            id: UUID().uuidString,
            kind: kind,
            mediaType: mediaType,
            byteCount: Int64(data.count),
            sha256: digest,
            metadata: metadata
        )
        lock.withLock {
            entries[reference.id] = Entry(
                backing: .data(data),
                reference: reference
            )
        }
        return reference
    }

    /// Stages textual plugin content off the main actor. The file is not made
    /// visible to plugins until its write and digest have both completed.
    func stageTextResource(
        _ text: String,
        kind: BlocksPluginResourceKind,
        mediaType: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) async -> BlocksPluginResourceReference? {
        let stagingTask = Task.detached(priority: .utility) {
            [weak self] () -> BlocksPluginResourceReference? in
            guard let self,
                  !Task.isCancelled,
                  self.beginStagingOperation() else {
                return nil
            }
            defer { self.completeStagingOperation() }
            guard let directory = self.stagingSessionDirectory else {
                return nil
            }
            let url = directory.appendingPathComponent(UUID().uuidString)
            do {
                guard Self.validatePrivateDirectory(directory),
                      let descriptor = Self.createPrivateFile(at: url) else {
                    return nil
                }
                var removeTemporaryFile = true
                defer {
                    if removeTemporaryFile {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                let handle = FileHandle(
                    fileDescriptor: descriptor,
                    closeOnDealloc: true
                )
                defer { try? handle.close() }
                var digest = SHA256()
                var byteCount: Int64 = 0
                var bytes: [UInt8] = []
                bytes.reserveCapacity(64 * 1024)
                for byte in text.utf8 {
                    if Task.isCancelled { return nil }
                    bytes.append(byte)
                    if bytes.count == 64 * 1024 {
                        self.stagingChunkHook()
                        guard !Task.isCancelled else { return nil }
                        let chunk = Data(bytes)
                        try handle.write(contentsOf: chunk)
                        digest.update(data: chunk)
                        byteCount += Int64(chunk.count)
                        bytes.removeAll(keepingCapacity: true)
                    }
                }
                if !bytes.isEmpty {
                    self.stagingChunkHook()
                    guard !Task.isCancelled else { return nil }
                    let chunk = Data(bytes)
                    try handle.write(contentsOf: chunk)
                    digest.update(data: chunk)
                    byteCount += Int64(chunk.count)
                }
                guard !Task.isCancelled else { return nil }
                try handle.synchronize()
                let reference = BlocksPluginResourceReference(
                    id: UUID().uuidString,
                    kind: kind,
                    mediaType: mediaType,
                    byteCount: byteCount,
                    sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                    metadata: metadata
                )
                let accepted = self.lock.withLock {
                    guard !self.shutdownRequested else { return false }
                    self.entries[reference.id] = Entry(
                        backing: .file(
                            url,
                            securityScoped: false,
                            removeWhenReleased: true
                        ),
                        reference: reference
                    )
                    return true
                }
                guard accepted else { return nil }
                removeTemporaryFile = false
                return reference
            } catch {
                return nil
            }
        }
        return await withTaskCancellationHandler(
            operation: { await stagingTask.value },
            onCancel: { stagingTask.cancel() }
        )
    }

    func registerUserAuthorizedFile(
        url: URL,
        mediaType: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) throws -> BlocksPluginResourceReference {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                guard !chunk.isEmpty else { break }
                digest.update(data: chunk)
            }
            let reference = BlocksPluginResourceReference(
                id: UUID().uuidString,
                kind: .file,
                mediaType: mediaType,
                byteCount: byteCount,
                sha256: digest.finalize().map {
                    String(format: "%02x", $0)
                }.joined(),
                metadata: metadata
            )
            lock.withLock {
                entries[reference.id] = Entry(
                    backing: .file(
                        url,
                        securityScoped: scoped,
                        removeWhenReleased: false
                    ),
                    reference: reference
                )
            }
            return reference
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func remove(ids: [String]) {
        lock.withLock {
            for id in ids {
                if hostLeaseCountsByResourceID[id, default: 0] > 0 {
                    pendingRemovalResourceIDs.insert(id)
                } else {
                    removeEntry(id: id)
                }
            }
        }
    }

    func shutdown() {
        lock.withLock {
            shutdownRequested = true
            for id in Array(entries.keys) {
                if hostLeaseCountsByResourceID[id, default: 0] > 0 {
                    pendingRemovalResourceIDs.insert(id)
                } else {
                    removeEntry(id: id)
                }
            }
            removeStagingSessionDirectoryIfPossible()
        }
    }

    /// Removes the current staging session even when a terminating process has
    /// hooks that have not released their host leases. Only the application
    /// termination finalizer may use this stronger operation.
    func forceShutdown() {
        lock.withLock {
            shutdownRequested = true
            for id in Array(entries.keys) {
                removeEntry(id: id)
            }
            removeStagingSessionDirectoryIfPossible(force: true)
        }
    }

    /// Keeps event resources alive while an asynchronous post-hook consumes
    /// them. Business owners may request removal immediately; the backing is
    /// released only after the last host lease ends.
    func retainHostLease(ids: [String]) {
        lock.withLock {
            guard !shutdownRequested else { return }
            for id in ids where entries[id] != nil {
                hostLeaseCountsByResourceID[id, default: 0] += 1
            }
        }
    }

    func releaseHostLease(ids: [String]) {
        lock.withLock {
            for id in ids {
                let current = hostLeaseCountsByResourceID[id, default: 0]
                if current > 1 {
                    hostLeaseCountsByResourceID[id] = current - 1
                    continue
                }
                hostLeaseCountsByResourceID.removeValue(forKey: id)
                if pendingRemovalResourceIDs.remove(id) != nil {
                    removeEntry(id: id)
                }
            }
            removeStagingSessionDirectoryIfPossible()
        }
    }

    private func removeEntry(id: String) {
        if case let .file(url, securityScoped, removeWhenReleased)? =
            entries.removeValue(forKey: id)?.backing {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            if removeWhenReleased { try? FileManager.default.removeItem(at: url) }
        }
        authorizedPluginIDsByResourceID.removeValue(forKey: id)
        scopedAuthorizationsByResourceID.removeValue(forKey: id)
        hostLeaseCountsByResourceID.removeValue(forKey: id)
        pendingRemovalResourceIDs.remove(id)
    }

    private func beginStagingOperation() -> Bool {
        lock.withLock {
            guard !shutdownRequested else { return false }
            activeStagingOperationCount += 1
            return true
        }
    }

    private func completeStagingOperation() {
        lock.withLock {
            activeStagingOperationCount = max(
                0,
                activeStagingOperationCount - 1
            )
            removeStagingSessionDirectoryIfPossible()
        }
    }

    private func removeStagingSessionDirectoryIfPossible(force: Bool = false) {
        guard shutdownRequested,
              entries.isEmpty,
              (force || activeStagingOperationCount == 0),
              let stagingSessionDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: stagingSessionDirectory)
    }

    func authorize(pluginID: String, resourceIDs: [String]) {
        lock.withLock {
            for id in resourceIDs where entries[id] != nil && (
                !shutdownRequested || hostLeaseCountsByResourceID[id, default: 0] > 0
            ) {
                authorizedPluginIDsByResourceID[id, default: []]
                    .insert(pluginID)
            }
        }
    }

    func revoke(pluginID: String, resourceIDs: [String]) {
        lock.withLock {
            for id in resourceIDs {
                authorizedPluginIDsByResourceID[id]?.remove(pluginID)
                if authorizedPluginIDsByResourceID[id]?.isEmpty == true {
                    authorizedPluginIDsByResourceID.removeValue(forKey: id)
                }
            }
        }
    }

    /// Per-invocation authorization never changes the existing UI/settings
    /// authorization set. A lease is removed precisely by the invocation
    /// defer, so an old invocation cannot revoke a newer one.
    func authorizeScoped(
        pluginID: String,
        resourceIDs: [String],
        featureAdmission: BlocksPluginFeatureAdmissionToken?
    ) -> UUID {
        let leaseID = UUID()
        lock.withLock {
            for id in resourceIDs where entries[id] != nil && (
                !shutdownRequested || hostLeaseCountsByResourceID[id, default: 0] > 0
            ) {
                scopedAuthorizationsByResourceID[id, default: [:]][leaseID] = .init(
                    pluginID: pluginID,
                    featureAdmission: featureAdmission
                )
            }
        }
        return leaseID
    }

    func revokeScoped(_ leaseID: UUID, resourceIDs: [String]) {
        lock.withLock {
            for id in resourceIDs {
                scopedAuthorizationsByResourceID[id]?.removeValue(forKey: leaseID)
                if scopedAuthorizationsByResourceID[id]?.isEmpty == true {
                    scopedAuthorizationsByResourceID.removeValue(forKey: id)
                }
            }
        }
    }

    func read(
        pluginID: String,
        id: String,
        offset: Int,
        length: Int
    ) throws -> [String: JSONValue] {
        let admitted: (entry: Entry, admission: ReadAdmission)? = lock.withLock {
            let hasUnscopedAuthorization = authorizedPluginIDsByResourceID[id]?
                .contains(pluginID) == true
            if hasUnscopedAuthorization, let entry = entries[id] {
                return (entry, .unscopedOrNonFeatureScoped)
            }
            let scopedAuthorizations = scopedAuthorizationsByResourceID[id] ?? [:]
            for authorization in scopedAuthorizations.values {
                guard authorization.pluginID == pluginID else { continue }
                guard let featureAdmission = authorization.featureAdmission else {
                    guard let entry = entries[id] else { return nil }
                    return (entry, .unscopedOrNonFeatureScoped)
                }
                guard featureAdmissionGate.isCurrent(featureAdmission),
                      let entry = entries[id] else {
                    continue
                }
                return (entry, .featureScoped(featureAdmission))
            }
            return nil
        }
        guard let admitted else {
            throw BlocksPluginRuntimeError.resourceUnavailable(id)
        }
        let entry = admitted.entry
        resourceReadCheckpoint()
        let safeOffset = max(0, offset)
        let safeLength = min(max(1, length), 1_048_576)
        let totalCount = Int(entry.reference.byteCount ?? 0)
        guard safeOffset <= totalCount else {
            throw BlocksPluginRuntimeError.invalidHostOperation("resource.read")
        }
        let end = min(totalCount, safeOffset + safeLength)
        let chunk: Data
        switch entry.backing {
        case let .data(data):
            chunk = data.subdata(in: safeOffset..<end)
        case let .file(url, _, _):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(safeOffset))
            chunk = try handle.read(upToCount: end - safeOffset) ?? Data()
        }
        let featureAdmission: BlocksPluginFeatureAdmissionToken?
        switch admitted.admission {
        case .unscopedOrNonFeatureScoped:
            featureAdmission = nil
        case let .featureScoped(token):
            featureAdmission = token
        }
        guard let response = featureAdmissionGate.commitIfCurrent(
            featureAdmission,
            { () -> [String: JSONValue] in
                [
                    "resource_id": .string(id),
                    "offset": .int(safeOffset),
                    "next_offset": .int(end),
                    "eof": .bool(end == totalCount),
                    "data_base64": .string(chunk.base64EncodedString()),
                ]
            }
        ) else {
            throw BlocksPluginRuntimeError.resourceUnavailable(id)
        }
        return response
    }

    private static func prepareStagingSession(
        baseDirectory: URL
    ) -> URL? {
        do {
            try createOrValidatePrivateDirectory(baseDirectory)
            try removeStaleSessions(in: baseDirectory)
            let sessionDirectory = baseDirectory.appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard validatePrivateDirectory(sessionDirectory) else {
                try? FileManager.default.removeItem(at: sessionDirectory)
                return nil
            }
            return sessionDirectory
        } catch {
            return nil
        }
    }

    private static func createOrValidatePrivateDirectory(
        _ directory: URL
    ) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ) {
            guard isDirectory.boolValue,
                  validatePrivateDirectory(directory) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard validatePrivateDirectory(directory) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func validatePrivateDirectory(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: directory.path
        ),
        (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        else {
            return false
        }
        return chmod(directory.path, S_IRWXU) == 0
    }

    private static func createPrivateFile(at url: URL) -> Int32? {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return descriptor
    }

    private static func removeStaleSessions(in baseDirectory: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for child in children {
            let values = try? child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]
            )
            guard values?.isSymbolicLink != true else {
                try? FileManager.default.removeItem(at: child)
                continue
            }
            guard values?.isDirectory == true else {
                // Migrates residual files written by the pre-session layout.
                if let modifiedAt = values?.contentModificationDate,
                   Date().timeIntervalSince(modifiedAt) >= 3_600 {
                    try? FileManager.default.removeItem(at: child)
                }
                continue
            }
            guard let pidPrefix = child.lastPathComponent.split(
                separator: "-",
                maxSplits: 1
            ).first,
            let pid = Int32(pidPrefix),
            pid != currentPID else {
                continue
            }
            errno = 0
            if kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}

enum BlocksPluginRuntimeError: Error, LocalizedError {
    case invalidHostOperation(String)
    case idempotencyConflict
    case resourceUnavailable(String)
    case blocked(pluginID: String, reason: String)
    case chainTimedOut
    case recursiveInvocation

    var errorDescription: String? {
        switch self {
        case let .invalidHostOperation(operation):
            return "Invalid plugin host operation: \(operation)."
        case .idempotencyConflict:
            return "A plugin host action idempotency key conflicts with a different request."
        case let .resourceUnavailable(id):
            return "Plugin resource is unavailable: \(id)."
        case let .blocked(pluginID, reason):
            return "Plugin \(pluginID) blocked the operation: \(reason)."
        case .chainTimedOut:
            return "The plugin hook chain timed out."
        case .recursiveInvocation:
            return "A recursive plugin invocation was rejected."
        }
    }
}

struct BlocksPluginEventDispatchResult: Sendable {
    let envelope: BlocksPluginEventEnvelope
    let allowed: Bool
    let blockedByPluginID: String?
    let reason: String?

    static func allowed(_ envelope: BlocksPluginEventEnvelope) -> Self {
        .init(
            envelope: envelope,
            allowed: true,
            blockedByPluginID: nil,
            reason: nil
        )
    }
}

enum BlocksPluginHostInvocationOrigin: Sendable, Equatable {
    case explicitUser
    /// Deprecated compatibility spelling. It conveys no destructive authority.
    @available(*, deprecated, message: "Destructive authority is host-issued and request-bound.")
    case hostConfirmedExplicitUser
    /// The associated value is retained only for CLI wire compatibility and is
    /// never accepted as destructive authority.
    case commandLine(destructiveActionConfirmed: Bool = false)
    case scheduled
    case background

    var userInitiated: Bool {
        switch self {
        case .explicitUser, .hostConfirmedExplicitUser, .commandLine:
            true
        case .scheduled, .background:
            false
        }
    }

    /// Never use origin as authorization. Kept false for source compatibility.
    var destructiveActionConfirmed: Bool { false }
}

/// A confirmation is bound to one requested host operation.  The runtime never
/// accepts plugin-provided confirmation UI or input fields as this authority.
struct BlocksPluginDestructiveActionConfirmationRequest: Sendable, Equatable {
    let requestID: UUID
    let pluginID: String
    let actionID: String
    let targetID: String
    let causationID: UUID
    let expectedRevision: Int64?
}

/// File-private host state: never serialized or exposed to plugins/CLI.
final class BlocksPluginDestructiveActionCapability {
    private let pluginID: String; private let actionID: String; private let targetID: String
    private let requestID: UUID; private let dispatchID: UUID; private let causationID: UUID; private let expectedRevision: Int64?
    private let executionGeneration: UInt64; private let lifecycleGeneration: UInt
    private var consumed = false
    fileprivate init(pluginID: String, actionID: String, targetID: String, requestID: UUID, dispatchID: UUID, causationID: UUID, expectedRevision: Int64?, executionGeneration: UInt64, lifecycleGeneration: UInt) {
        self.pluginID = pluginID; self.actionID = actionID; self.targetID = targetID
        self.requestID = requestID; self.dispatchID = dispatchID; self.causationID = causationID; self.expectedRevision = expectedRevision
        self.executionGeneration = executionGeneration; self.lifecycleGeneration = lifecycleGeneration
    }
    fileprivate func consume(pluginID: String, invocation: BlocksPluginActionInvocation, requestID: UUID?, causationID: UUID, dispatchID: UUID, executionGeneration: UInt64, lifecycleGeneration: UInt) -> Bool {
        guard !consumed, self.pluginID == pluginID, actionID == invocation.actionID,
              self.requestID == requestID, self.dispatchID == dispatchID, self.causationID == causationID,
              self.expectedRevision == invocation.expectedRevision,
              self.executionGeneration == executionGeneration, self.lifecycleGeneration == lifecycleGeneration,
              targetID == BlocksPluginRuntimeCoordinator.destructiveTargetID(invocation) else { return false }
        consumed = true
        return true
    }

#if DEBUG
    static func makeForTesting(
        pluginID: String, actionID: String, targetID: String, requestID: UUID,
        dispatchID: UUID, causationID: UUID, expectedRevision: Int64?,
        executionGeneration: UInt64, lifecycleGeneration: UInt
    ) -> Self {
        .init(
            pluginID: pluginID, actionID: actionID, targetID: targetID,
            requestID: requestID, dispatchID: dispatchID, causationID: causationID,
            expectedRevision: expectedRevision, executionGeneration: executionGeneration,
            lifecycleGeneration: lifecycleGeneration
        )
    }
#endif
}

@MainActor
final class BlocksPluginHostActionRegistry {
    struct Context: Sendable {
        let requestingPluginID: String
        let causationID: UUID
        let expectedRevision: Int64?
        let origin: BlocksPluginHostInvocationOrigin
        /// Set only by `perform` after consuming a private, request-bound host
        /// capability immediately before invoking a destructive handler.
        let destructiveActionAuthorized: Bool

        init(
            requestingPluginID: String,
            causationID: UUID,
            expectedRevision: Int64? = nil,
            origin: BlocksPluginHostInvocationOrigin = .background
        ) {
            self.requestingPluginID = requestingPluginID
            self.causationID = causationID
            self.expectedRevision = expectedRevision
            self.origin = origin
            self.destructiveActionAuthorized = false
        }

        fileprivate init(requestingPluginID: String, causationID: UUID,
                         expectedRevision: Int64?, origin: BlocksPluginHostInvocationOrigin,
                         destructiveActionAuthorized: Bool) {
            self.requestingPluginID = requestingPluginID
            self.causationID = causationID
            self.expectedRevision = expectedRevision
            self.origin = origin
            self.destructiveActionAuthorized = destructiveActionAuthorized
        }
    }

    typealias Handler = @MainActor @Sendable (
        Context,
        [String: JSONValue]
    ) async throws -> JSONValue

    private var handlers: [String: Handler] = [:]
    private(set) var capabilities:
        [String: BlocksPluginHostCapabilityDescriptor] = [:]

    func register(_ actionID: String, handler: @escaping Handler) {
        register(
            BlocksPluginHostCapabilityDescriptor(
                id: actionID,
                apiVersion: BlocksPluginHostActionRegistryV1.version
            ),
            handler: handler
        )
    }

    func register(
        _ capability: BlocksPluginHostCapabilityDescriptor,
        handler: @escaping Handler
    ) {
        capabilities[capability.id] = capability
        handlers[capability.id] = handler
    }

    func capability(
        id: String
    ) -> BlocksPluginHostCapabilityDescriptor? {
        capabilities[id]
    }

    func perform(
        _ invocation: BlocksPluginActionInvocation,
        context: Context,
        destructiveCapability: BlocksPluginDestructiveActionCapability? = nil,
        destructiveConfirmationRequestID: UUID? = nil,
        dispatchID: UUID = UUID(),
        executionGeneration: UInt64 = 0,
        lifecycleGeneration: UInt = 0
    ) async throws -> JSONValue {
        guard let handler = handlers[invocation.actionID] else {
            throw BlocksPluginRuntimeError.invalidHostOperation(invocation.actionID)
        }
        let risk = capabilities[invocation.actionID]?.risk ?? .unknown
        guard risk != .unknown else {
            throw BlocksPluginRuntimeError.invalidHostOperation("unknown_host_action_risk")
        }
        let destructiveActionAuthorized: Bool
        if risk == .destructive {
            guard destructiveCapability?.consume(pluginID: context.requestingPluginID, invocation: invocation, requestID: destructiveConfirmationRequestID, causationID: context.causationID, dispatchID: dispatchID, executionGeneration: executionGeneration, lifecycleGeneration: lifecycleGeneration) == true else {
                throw BlocksPluginRuntimeError.invalidHostOperation("destructive_host_action_capability_required")
            }
            destructiveActionAuthorized = true
        } else { destructiveActionAuthorized = false }
        return try await handler(
            .init(
                requestingPluginID: context.requestingPluginID,
                causationID: context.causationID,
                expectedRevision: invocation.expectedRevision,
                origin: context.origin,
                destructiveActionAuthorized: destructiveActionAuthorized
            ),
            invocation.input
        )
    }
}

struct BlocksPluginRecentActivity: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed
    }

    let state: State
    let event: BlocksPluginEventName
    let occurredAt: Date
    let message: String?
}


@MainActor
final class BlocksPluginRuntimeCoordinator: ObservableObject {
    struct HostActionLifecycleToken: Sendable {
        fileprivate let generation: UInt
    }
    @TaskLocal private static var asyncDispatchingModule: BlocksPluginModule?

    private struct HostActionIdempotencyKey: Hashable {
        let pluginID: String
        let key: String
    }

    /// Equality is deliberately structural so JSON object key ordering cannot
    /// change the identity of a request.
    private struct HostActionIdempotencyFingerprint: Equatable {
        let actionID: String
        let input: [String: JSONValue]
        let expectedRevision: Int64?
    }

    /// Captures the identity a scheduler task was authorized to run.  The
    /// binding is checked again synchronously immediately before the runner,
    /// rather than treating an asynchronous schedule reload as that boundary.
    private struct ScheduleRunnerAdmission: Sendable {
        let executionGeneration: UInt64
        let entryFunction: String
    }

    private enum HostActionIdempotencyEntry {
        case inFlight(
            fingerprint: HostActionIdempotencyFingerprint,
            id: UUID,
            task: Task<JSONValue, Error>
        )
        case completed(
            fingerprint: HostActionIdempotencyFingerprint,
            result: JSONValue
        )
    }

    @Published private(set) var uiStateByPluginID:
        [String: [String: [String: JSONValue]]] = [:]
    @Published private(set) var safeModeEnabled: Bool
    @Published private(set) var safeModeTransitionInProgress = false
    @Published private(set) var recentActivityByPluginID:
        [String: BlocksPluginRecentActivity] = [:]

    static let maximumHookChainSeconds: Double = 5
    private static let maximumHostActionIdempotencyKeyBytes = 256
    private static let maximumCompletedHostActionIdempotencyEntries = 256
    private static let maximumCompletedHostActionIdempotencyBytes = 4 * 1_024 * 1_024

    let actionRegistry = BlocksPluginHostActionRegistry()
    let resources: BlocksPluginResourceBroker
    private let featureAdmissionGate: BlocksPluginFeatureAdmissionGate

    private let manager: BlocksNativePluginManager
    private let repository: BlocksPluginPlatformRepository?
    private let debugLogStore: BlocksPluginDebugLogStore?
    private let distributionChannel: DistributionChannel
    private let logger = Logger(subsystem: "com.toooops.blocks", category: "plugin-runtime")
    private var activeInvocationKeys: Set<String> = []
    private var scheduleTasks: [String: Task<Void, Never>] = [:]
    private var asyncDispatchTasksByModule:
        [BlocksPluginModule: (id: UUID, task: Task<Void, Never>)] = [:]
    private var asyncDispatchGenerationByModule: [BlocksPluginModule: UInt] = [:]
    private var dispatchInvalidationGeneration: UInt = 0
    private var asyncDispatchesTerminated = false
    private var hostActionIdempotencyEntries:
        [HostActionIdempotencyKey: HostActionIdempotencyEntry] = [:]
    private var completedHostActionIdempotencyKeys:
        [HostActionIdempotencyKey] = []
    private var completedHostActionIdempotencyByteCounts:
        [HostActionIdempotencyKey: Int] = [:]
    private var completedHostActionIdempotencyBytes = 0
    private var destructiveActionConfirmationHandler:
        (@MainActor @Sendable (BlocksPluginDestructiveActionConfirmationRequest) async -> Bool)?
    private var safeModeTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    /// Internal deterministic test seams. Production leaves both nil.
    var scheduleTaskBeforeExecutionHook: (() async -> Void)?
    var scheduleTaskDidCompleteExecutionHook: (() async -> Void)?
    var asyncDispatchEnqueuedHook: ((BlocksPluginEventEnvelope) -> Void)?

    func configureDestructiveActionConfirmationHandler(
        _ handler: (@MainActor @Sendable (BlocksPluginDestructiveActionConfirmationRequest) async -> Bool)?
    ) {
        destructiveActionConfirmationHandler = handler
    }
    var hostActionPermissionApprovedHook: (() async -> Void)?

    init(
        manager: BlocksNativePluginManager,
        distributionChannel: DistributionChannel = .current,
        resourceReadCheckpoint: @escaping @Sendable () -> Void = {}
    ) {
        let featureAdmissionGate = BlocksPluginFeatureAdmissionGate()
        self.manager = manager
        self.distributionChannel = distributionChannel
        self.featureAdmissionGate = featureAdmissionGate
        self.resources = BlocksPluginResourceBroker(
            resourceReadCheckpoint: resourceReadCheckpoint,
            featureAdmissionGate: featureAdmissionGate
        )
        safeModeEnabled = UserDefaults.standard.bool(
            forKey: "blocks.plugins.safeMode"
        )
        repository = manager.platformRepository
        debugLogStore = manager.debugLogStore
        if safeModeEnabled {
            manager.hostOperationAdmissionGate.revokeAllAndDrain()
        }
        manager.hostOperationRouter.install { [weak self] request in
            guard let self else {
                return .init(
                    requestID: request.requestID,
                    ok: false,
                    errorCode: "plugin_runtime_unavailable",
                    errorMessage: "The plugin runtime is unavailable."
                )
            }
            return self.performSynchronousHostOperation(request)
        }
    }

    /// Feature owners call this synchronously before cancelling their own
    /// work. Existing runner/resource/action admissions for that module fail
    /// closed without invalidating newly captured module tokens.
    func invalidateFeatureAdmission(for module: BlocksPluginModule) {
        featureAdmissionGate.invalidate(module: module)
    }

    private func featureAdmissionIsCurrent(
        _ token: BlocksPluginFeatureAdmissionToken?
    ) -> Bool {
        token.map(featureAdmissionGate.isCurrent) ?? true
    }

    private func combinedFeatureAdmission(
        _ admissionIsCurrent: (@MainActor () -> Bool)?,
        token: BlocksPluginFeatureAdmissionToken
    ) -> @MainActor () -> Bool {
        { [featureAdmissionGate] in
            featureAdmissionGate.isCurrent(token)
                && (admissionIsCurrent?() ?? true)
        }
    }

    func dispatch(
        _ envelope: BlocksPluginEventEnvelope,
        targetPluginID: String? = nil,
        admissionIsCurrent: (@MainActor () -> Bool)? = nil,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) async -> BlocksPluginEventDispatchResult {
        let allowsTerminationDispatch = envelope.name == .appWillTerminate
        let invalidationGeneration = dispatchInvalidationGeneration
        guard isDispatchValid(
            invalidationGeneration,
            allowsTerminationDispatch: allowsTerminationDispatch
        ), manager.pluginSnapshotIsAuthoritative,
              featureAdmissionIsCurrent(featureAdmission),
              admissionIsCurrent?() ?? true else {
            return .allowed(envelope)
        }
        guard let repository else { return .allowed(envelope) }
        let loaded = await manager.hookBindings(
            event: envelope.name,
            distributionChannel: distributionChannel
        )
        guard isDispatchValid(
            invalidationGeneration,
            allowsTerminationDispatch: allowsTerminationDispatch
        ), manager.pluginSnapshotIsAuthoritative,
              featureAdmissionIsCurrent(featureAdmission),
              admissionIsCurrent?() ?? true else {
            return .allowed(envelope)
        }
        let bindings = targetPluginID.map { pluginID in
            loaded.filter { $0.pluginID == pluginID }
        } ?? loaded
        guard !bindings.isEmpty else { return .allowed(envelope) }

        var current = envelope
        let chainStarted = ContinuousClock.now
        for binding in bindings {
            guard isDispatchValid(
                invalidationGeneration,
                allowsTerminationDispatch: allowsTerminationDispatch
            ), featureAdmissionIsCurrent(featureAdmission),
               admissionIsCurrent?() ?? true else {
                return .allowed(current)
            }
            let declaredHook = hookDeclaration(for: binding)
            guard let declaredHook,
                  bindingMatchesDeclaration(binding, declaredHook),
                  binding.event == current.name else {
                // A historical or externally corrupted binding must not be
                // allowed to retarget a valid declaration to another event.
                // Skip it before timeout, runner, resource, mutation, or
                // action handling; stale metadata is never a fail-closed
                // reason to block the host operation.
                recentActivityByPluginID[binding.pluginID] = .init(
                    state: .failed,
                    event: current.name,
                    occurredAt: Date(),
                    message: "hook_binding_event_mismatch"
                )
                continue
            }
            if chainStarted.duration(to: .now) > .seconds(Self.maximumHookChainSeconds),
               declaredHook.isExecutionEligible {
                if binding.failurePolicy == .failClosed,
                   current.phase == .will,
                   !allowsTerminationDispatch {
                    return .init(
                        envelope: current,
                        allowed: false,
                        blockedByPluginID: binding.pluginID,
                        reason: BlocksPluginRuntimeError.chainTimedOut.localizedDescription
                    )
                }
                break
            }
            // Historical packages may predate the installation validator rule.
            // Refuse an invalid foreground-only declaration before allocating
            // runner, resource, mutation, or action work; this is fail-open
            // even when the persisted binding says fail_closed.
            let hook = declaredHook
            guard hook.isExecutionEligible else {
                recentActivityByPluginID[binding.pluginID] = .init(
                    state: .failed,
                    event: current.name,
                    occurredAt: Date(),
                    message: "foreground_only_hook_not_preflight"
                )
                continue
            }
            let executionGeneration = manager.executionGeneration(
                pluginID: binding.pluginID
            )
            // A lifecycle cutoff is published synchronously before disable,
            // uninstall, or replacement starts waiting for older work. Do not
            // allocate a new runner invocation from a binding loaded before
            // that cutoff; stale bindings are fail-open for the host event.
            guard isPluginRunnerAdmissionCurrent(
                binding.pluginID,
                executionGeneration,
                allowsTerminationDispatch: allowsTerminationDispatch
            ) else {
                continue
            }
            let invocationKey = "\(binding.pluginID)|\(binding.event.rawValue)|\(envelope.causationID.uuidString)"
            guard activeInvocationKeys.insert(invocationKey).inserted else {
                if featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true {
                    await recordFailure(
                        binding: binding,
                        envelope: current,
                        error: BlocksPluginRuntimeError.recursiveInvocation,
                        durationMilliseconds: 0,
                        settlementToken: manager.executionSettlementGate.captureToken(
                            pluginID: binding.pluginID, hookID: binding.hookID
                        ),
                        featureAdmission: featureAdmission
                    )
                }
                continue
            }
            let started = ContinuousClock.now
            let settlementToken = manager.executionSettlementGate.captureToken(
                pluginID: binding.pluginID, hookID: binding.hookID
            )
            recentActivityByPluginID[binding.pluginID] = .init(
                state: .running,
                event: current.name,
                occurredAt: Date(),
                message: nil
            )
            defer { activeInvocationKeys.remove(invocationKey) }
            do {
                // Feature-scoped privacy or lifecycle admission may be revoked
                // while bindings are loaded. Recheck before authorizing staged
                // resources or entering a runner that can perform external I/O.
                guard featureAdmissionIsCurrent(featureAdmission),
                      admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                let pluginEnvelope = authorizedEnvelope(
                    current,
                    pluginID: binding.pluginID
                )
                let invocation = BlocksPluginRuntimeInvocation(
                    pluginID: binding.pluginID,
                    kind: .hook,
                    entryFunction: hook.entryFunction,
                    event: pluginEnvelope
                )
                let resourceIDs = pluginEnvelope.resources.map(\.id)
                let scopedResourceLease = resources.authorizeScoped(
                    pluginID: binding.pluginID,
                    resourceIDs: resourceIDs,
                    featureAdmission: featureAdmission
                )
                defer {
                    resources.revokeScoped(
                        scopedResourceLease,
                        resourceIDs: resourceIDs
                    )
                }
                // Loading/authorizing resources can race a lifecycle cutoff.
                // Revalidate immediately before the runner boundary so a
                // disabled, uninstalled, or replaced revision cannot begin
                // external work from a stale binding.
                guard isPluginRunnerAdmissionCurrent(
                    binding.pluginID,
                    executionGeneration,
                    allowsTerminationDispatch: allowsTerminationDispatch
                ), featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                let result = try await manager.executePlatform(
                    pluginID: binding.pluginID,
                    invocation: invocation,
                    timeoutSeconds: Double(binding.timeoutMilliseconds) / 1_000
                )
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ) else { return .allowed(current) }
                guard isDispatchValid(
                    invalidationGeneration,
                    allowsTerminationDispatch: allowsTerminationDispatch
                ), isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                ), featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                let hook = result.hook ?? BlocksPluginHookResult(
                    uiStatePatches: result.uiStatePatches,
                    diagnostics: result.diagnostics
                )
                if current.phase == .will {
                    guard await manager.executionSettlementGate.authorizeEffects(
                        settlementToken
                    ) else { return .allowed(current) }
                    guard isPluginExecutionCurrent(
                        binding.pluginID,
                        executionGeneration
                    ), featureAdmissionIsCurrent(featureAdmission),
                       admissionIsCurrent?() ?? true else {
                        return .allowed(current)
                    }
                    if !allowsTerminationDispatch {
                        try validateMutationAuthorization(
                            hook.mutations,
                            event: current.name,
                            pluginID: binding.pluginID
                        )
                        current = try applying(hook.mutations, to: current)
                    }
                } else if !hook.mutations.isEmpty {
                    throw BlocksPluginRuntimeError.invalidHostOperation(
                        "mutations_not_allowed:\(current.name.rawValue)"
                    )
                }
                if !allowsTerminationDispatch {
                    guard await manager.executionSettlementGate.authorizeEffects(
                        settlementToken
                    ) else { return .allowed(current) }
                    guard isPluginExecutionCurrent(
                        binding.pluginID,
                        executionGeneration
                    ), featureAdmissionIsCurrent(featureAdmission),
                       admissionIsCurrent?() ?? true else {
                        return .allowed(current)
                    }
                    try applyUIState(
                        hook.uiStatePatches,
                        pluginID: binding.pluginID
                    )
                    for action in hook.actions {
                        guard await manager.executionSettlementGate.authorizeEffects(
                            settlementToken
                        ) else { return .allowed(current) }
                        guard isPluginExecutionCurrent(
                            binding.pluginID,
                            executionGeneration
                        ), featureAdmissionIsCurrent(featureAdmission),
                           admissionIsCurrent?() ?? true else {
                            return .allowed(current)
                        }
                        do {
                            _ = try await performRequestedAction(
                                action,
                                requestingPluginID: binding.pluginID,
                                causationID: current.causationID,
                                origin: hostInvocationOrigin(for: current),
                                executionGeneration: executionGeneration,
                                featureAdmission: featureAdmission
                            )
                        } catch {
                            if featureAdmissionIsCurrent(featureAdmission),
                               admissionIsCurrent?() ?? true {
                                await recordActionFailure(
                                    pluginID: binding.pluginID,
                                    envelope: current,
                                    actionID: action.actionID,
                                    error: error,
                                    featureAdmission: featureAdmission
                                )
                            }
                        }
                        guard await manager.executionSettlementGate.authorizeEffects(
                            settlementToken
                        ) else { return .allowed(current) }
                        guard isDispatchValid(
                            invalidationGeneration,
                            allowsTerminationDispatch: false
                        ), isPluginExecutionCurrent(
                            binding.pluginID,
                            executionGeneration
                        ), featureAdmissionIsCurrent(featureAdmission),
                           admissionIsCurrent?() ?? true else {
                            return .allowed(current)
                        }
                    }
                }
                let elapsed = started.duration(to: .now).milliseconds
                guard isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                ), featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                manager.executionSettlementGate.beginOutcomeSettlement(
                    settlementToken
                )
                let featureAdmissionGate = self.featureAdmissionGate
                let outcomeDisabled = (try? await Task.detached {
                    guard featureAdmission.map(featureAdmissionGate.isCurrent)
                        ?? true else {
                        return false
                    }
                    return try repository.recordHookExecutionOutcomeAndAppendAudit(
                        pluginID: binding.pluginID,
                        hookID: binding.hookID,
                        succeeded: true,
                        eventID: current.eventID,
                        requestID: invocation.requestID,
                        causationID: current.causationID,
                        level: .info,
                        category: "hook",
                        outcome: hook.disposition.rawValue,
                        durationMilliseconds: elapsed,
                        metadata: ["event": .string(current.name.rawValue)]
                    )
                }.value) ?? false
                manager.executionSettlementGate.finishOutcomeSettlement(
                    settlementToken, invalidateHook: outcomeDisabled
                )
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ) else { return .allowed(current) }
                guard isDispatchValid(
                    invalidationGeneration,
                    allowsTerminationDispatch: allowsTerminationDispatch
                ), isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                ), featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                writeDebugLog(
                    pluginID: binding.pluginID,
                    entry: [
                        "category": .string("hook"),
                        "event": .string(current.name.rawValue),
                        "outcome": .string(hook.disposition.rawValue),
                        "duration_ms": .double(elapsed),
                        "input_summary": BlocksPluginLogRedactor
                            .structuralSummary(pluginEnvelope.payload),
                        "mutation_count": .int(hook.mutations.count),
                        "requested_action_count": .int(hook.actions.count),
                        "approved_action_ids": .array(
                            approvedHostActionIDs(
                                hook.actions,
                                pluginID: binding.pluginID
                            ).map(JSONValue.string)
                        ),
                        "ui_state_patch_count": .int(
                            hook.uiStatePatches.count
                        ),
                        "diagnostic_count": .int(hook.diagnostics.count),
                        "diagnostic_levels": .array(hook.diagnostics.map {
                            .string($0.level.rawValue)
                        }),
                    ],
                    debugOnlyPayload: true
                )
                recentActivityByPluginID[binding.pluginID] = .init(
                    state: .succeeded,
                    event: current.name,
                    occurredAt: Date(),
                    message: nil
                )
                if hook.disposition == .block,
                   current.phase == .will,
                   !allowsTerminationDispatch {
                    return .init(
                        envelope: current,
                        allowed: false,
                        blockedByPluginID: binding.pluginID,
                        reason: hook.reason ?? "Blocked by plugin."
                    )
                }
            } catch {
                guard isDispatchValid(
                    invalidationGeneration,
                    allowsTerminationDispatch: allowsTerminationDispatch
                ), isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                ), featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                let elapsed = started.duration(to: .now).milliseconds
                await recordFailure(
                    binding: binding,
                    envelope: current,
                    error: error,
                    durationMilliseconds: elapsed,
                    settlementToken: settlementToken,
                    featureAdmission: featureAdmission
                )
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ), isDispatchValid(
                    invalidationGeneration,
                    allowsTerminationDispatch: allowsTerminationDispatch
                ), isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                ), featureAdmissionIsCurrent(featureAdmission),
                   admissionIsCurrent?() ?? true else {
                    return .allowed(current)
                }
                recentActivityByPluginID[binding.pluginID] = .init(
                    state: .failed,
                    event: current.name,
                    occurredAt: Date(),
                    message: error.localizedDescription
                )
                if binding.failurePolicy == .failClosed,
                   current.phase == .will,
                   !allowsTerminationDispatch {
                    return .init(
                        envelope: current,
                        allowed: false,
                        blockedByPluginID: binding.pluginID,
                        reason: error.localizedDescription
                    )
                }
            }
        }
        return .allowed(current)
    }

    func dispatchAppWillTerminate() async {
        let gate = manager.hostOperationAdmissionGate
        gate.revokeAll(permanently: true)
        cancelSchedules()
        manager.cancelAllActiveExecutions()
        invalidateAsyncDispatches(permanently: true)
        clearHostActionIdempotencyLedger()
        await Task.detached {
            gate.drainAll()
        }.value
        // `resource.read` is a synchronous host operation covered by the
        // admission gate, but it does not retain a separate resource lease.
        // Keep staged resources alive until every operation admitted before
        // the termination cutoff has finished reading them.
        resources.shutdown()
        _ = await dispatch(BlocksPluginEventEnvelope(name: .appWillTerminate))
    }

    func forceShutdownForApplicationTermination() {
        // The finalizer can run on the main thread after the graceful timeout.
        // It must cut admission synchronously, but cannot wait for an async
        // MainActor host-action handler that ignored cancellation.
        manager.hostOperationAdmissionGate.revokeAll(permanently: true)
        cancelSchedules()
        manager.cancelAllActiveExecutions()
        invalidateAsyncDispatches(permanently: true)
        clearHostActionIdempotencyLedger()
        resources.forceShutdown()
    }

    /// Feature coordinators need a result only for transaction-gating hooks.
    /// Post/failed/manual events are deliberately detached so plugin work can
    /// never extend an operation that has already completed.
    func dispatchFromFeature(
        _ envelope: BlocksPluginEventEnvelope,
        admissionIsCurrent: (@MainActor () -> Bool)? = nil
    ) async -> BlocksPluginEventDispatchResult {
        let featureAdmission = featureAdmissionGate.capture(module: envelope.module)
        let combinedAdmission = combinedFeatureAdmission(
            admissionIsCurrent,
            token: featureAdmission
        )
        guard envelope.phase.canMutateTransaction else {
            dispatchAsync(
                envelope,
                admissionIsCurrent: combinedAdmission,
                featureAdmission: featureAdmission
            )
            return .allowed(envelope)
        }
        let module = envelope.module
        let generation = asyncDispatchGenerationByModule[module, default: 0]
        if Self.asyncDispatchingModule != envelope.module,
           let precedingPost = asyncDispatchTasksByModule[module]?.task {
            await precedingPost.value
        }
        guard !Task.isCancelled,
              !safeModeEnabled,
              !asyncDispatchesTerminated,
              combinedAdmission(),
              asyncDispatchGenerationByModule[module, default: 0]
                == generation else {
            return .allowed(envelope)
        }
        return await dispatch(
            envelope,
            admissionIsCurrent: combinedAdmission,
            featureAdmission: featureAdmission
        )
    }

    /// Enqueues an immutable post-event through the same per-module FIFO as
    /// `dispatchFromFeature`, but does not return until that event has reached
    /// a terminal runtime state. Use this only when the host must keep a
    /// surrounding lifecycle barrier active until plugin side effects finish.
    func dispatchFromFeatureAwaitingCompletion(
        _ envelope: BlocksPluginEventEnvelope,
        admissionIsCurrent: (@MainActor () -> Bool)? = nil
    ) async -> BlocksPluginEventDispatchResult {
        guard !envelope.phase.canMutateTransaction else {
            return await dispatchFromFeature(
                envelope,
                admissionIsCurrent: admissionIsCurrent
            )
        }
        let featureAdmission = featureAdmissionGate.capture(module: envelope.module)
        let combinedAdmission = combinedFeatureAdmission(
            admissionIsCurrent,
            token: featureAdmission
        )
        // A same-module hook can synchronously request a host action that
        // emits another post-event. Waiting for an item queued behind the
        // currently executing hook would deadlock that XPC round trip, so the
        // nested event retains the platform's normal detached FIFO semantics.
        guard Self.asyncDispatchingModule != envelope.module else {
            dispatchAsync(
                envelope,
                admissionIsCurrent: combinedAdmission,
                featureAdmission: featureAdmission
            )
            return .allowed(envelope)
        }
        guard let task = dispatchAsync(
            envelope,
            admissionIsCurrent: combinedAdmission,
            featureAdmission: featureAdmission
        ) else {
            return .allowed(envelope)
        }
        await task.value
        return .allowed(envelope)
    }

    func setSafeModeEnabled(_ enabled: Bool) async {
        await waitForSafeModeTransition()
        guard safeModeEnabled != enabled else { return }
        safeModeTransitionInProgress = true
        defer {
            safeModeTransitionInProgress = false
            let waiters = safeModeTransitionWaiters
            safeModeTransitionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let gate = manager.hostOperationAdmissionGate
        if enabled {
            gate.revokeAll()
            // Publish the cutoff before the first suspension point so every
            // runtime entry guarded by safeModeEnabled rejects new work while
            // already-admitted synchronous host operations drain.
            safeModeEnabled = true
            UserDefaults.standard.set(true, forKey: "blocks.plugins.safeMode")
            activeInvocationKeys.removeAll()
            manager.cancelAllActiveExecutions()
            cancelSchedules()
            invalidateAsyncDispatches()
            clearHostActionIdempotencyLedger()
            await Task.detached {
                gate.drainAll()
            }.value
        } else {
            await Task.detached {
                gate.drainAll()
            }.value
            gate.resumeAll()
            safeModeEnabled = false
            UserDefaults.standard.set(false, forKey: "blocks.plugins.safeMode")
            await reloadSchedules()
        }
    }

    private func waitForSafeModeTransition() async {
        while safeModeTransitionInProgress {
            await withCheckedContinuation { continuation in
                safeModeTransitionWaiters.append(continuation)
            }
        }
    }

    func reloadSchedules() async {
        cancelSchedules()
        guard !safeModeEnabled, !asyncDispatchesTerminated else { return }
        let bindings = await manager.scheduleBindings()
        guard !Task.isCancelled,
              !safeModeEnabled,
              !asyncDispatchesTerminated else { return }
        for binding in bindings {
            guard let admission = scheduleRunnerAdmission(for: binding) else {
                continue
            }
            scheduleTasks[binding.id] = makeScheduleTask(
                binding,
                admission: admission
            )
        }
    }

    private func makeScheduleTask(
        _ binding: BlocksPluginScheduleBinding,
        admission: ScheduleRunnerAdmission
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.safeModeEnabled, !self.asyncDispatchesTerminated else {
                    return
                }
                let nextFireAt = self.nextScheduleDate(binding)
                await self.manager.updateScheduleTiming(
                    pluginID: binding.pluginID,
                    scheduleID: binding.scheduleID,
                    nextFireAt: nextFireAt,
                    lastFiredAt: nil
                )
                guard !Task.isCancelled,
                      !self.safeModeEnabled,
                      !self.asyncDispatchesTerminated else { return }
                let delay = Duration.milliseconds(
                    Int64(max(1, nextFireAt.timeIntervalSinceNow) * 1_000)
                )
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled,
                      !self.safeModeEnabled,
                      !self.asyncDispatchesTerminated else { return }
                await self.scheduleTaskBeforeExecutionHook?()
                guard !Task.isCancelled,
                      !self.safeModeEnabled,
                      !self.asyncDispatchesTerminated else { return }
                await self.executeSchedule(binding, admission: admission)
                await self.scheduleTaskDidCompleteExecutionHook?()
                guard !Task.isCancelled,
                      !self.safeModeEnabled,
                      !self.asyncDispatchesTerminated else { return }
                await self.manager.updateScheduleTiming(
                    pluginID: binding.pluginID,
                    scheduleID: binding.scheduleID,
                    nextFireAt: nil,
                    lastFiredAt: Date()
                )
                guard !Task.isCancelled,
                      !self.safeModeEnabled,
                      !self.asyncDispatchesTerminated else { return }
                if binding.kind == .calendar {
                    await Task.yield()
                    guard !Task.isCancelled,
                          !self.safeModeEnabled,
                          !self.asyncDispatchesTerminated else { return }
                }
            }
        }
    }

    private func nextScheduleDate(
        _ binding: BlocksPluginScheduleBinding,
        now: Date = Date()
    ) -> Date {
        switch binding.kind {
        case .interval:
            let seconds = max(
                1,
                binding.configuration.double("seconds") ?? 60
            )
            return now.addingTimeInterval(seconds)
        case .calendar:
            let calendar = Calendar.current
            let hour = min(23, max(0, binding.configuration.int("hour") ?? 9))
            let minute = min(59, max(0, binding.configuration.int("minute") ?? 0))
            var components = calendar.dateComponents(
                [.year, .month, .day],
                from: now
            )
            components.hour = hour
            components.minute = minute
            components.second = 0
            var next = calendar.date(from: components) ?? now.addingTimeInterval(60)
            if next <= now {
                next = calendar.date(byAdding: .day, value: 1, to: next)
                    ?? now.addingTimeInterval(86_400)
            }
            return next
        }
    }

    // Internal solely so the app test target can drive the same schedule path
    // with a deterministic suspended executor; production callers still use
    // the scheduler task above.
    func executeSchedule(
        _ binding: BlocksPluginScheduleBinding
    ) async {
        await executeSchedule(binding, admission: nil)
    }

    private func executeSchedule(
        _ binding: BlocksPluginScheduleBinding,
        admission: ScheduleRunnerAdmission?
    ) async {
        guard !safeModeEnabled,
              !asyncDispatchesTerminated,
              currentRunnableScheduleDeclaration(
                for: binding,
                admission: admission
              ) != nil else { return }
        let executionGeneration = admission?.executionGeneration
            ?? manager.executionGeneration(pluginID: binding.pluginID)
        let settlementToken = manager.executionSettlementGate.captureToken(
            pluginID: binding.pluginID
        )
        let causationID = UUID()
        let event = BlocksPluginEventEnvelope(
            name: .automationScheduledTrigger,
            causationID: causationID,
            payload: [
                "plugin_id": .string(binding.pluginID),
                "schedule_id": .string(binding.scheduleID),
            ]
        )
        _ = await dispatch(event)
        guard !Task.isCancelled,
              !safeModeEnabled,
              !asyncDispatchesTerminated,
              isPluginExecutionCurrent(
                binding.pluginID,
                executionGeneration
              ),
              let declaration = currentRunnableScheduleDeclaration(
                  for: binding,
                  admission: admission
              ) else { return }
        do {
            guard !Task.isCancelled,
                  !safeModeEnabled,
                  !asyncDispatchesTerminated,
                  isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                  ) else { return }
            let result = try await manager.executePlatform(
                pluginID: binding.pluginID,
                invocation: BlocksPluginRuntimeInvocation(
                    pluginID: binding.pluginID,
                    kind: .schedule,
                    entryFunction: declaration.entryFunction,
                    event: event,
                    input: binding.configuration
                ),
                timeoutSeconds: 30
            )
            guard await manager.executionSettlementGate.authorizeEffects(
                settlementToken
            ) else { return }
            guard !Task.isCancelled,
                  !safeModeEnabled,
                  !asyncDispatchesTerminated,
                  isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                  ) else { return }
            try applyUIState(
                result.uiStatePatches,
                pluginID: binding.pluginID
            )
            for requestedAction in result.actions {
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ) else { return }
                guard !Task.isCancelled,
                      !safeModeEnabled,
                      !asyncDispatchesTerminated,
                      isPluginExecutionCurrent(
                        binding.pluginID,
                        executionGeneration
                      ) else { return }
                _ = try await performRequestedAction(
                    requestedAction,
                    requestingPluginID: binding.pluginID,
                    causationID: causationID,
                    origin: .scheduled,
                    executionGeneration: executionGeneration
                )
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ) else { return }
                guard !Task.isCancelled,
                      !safeModeEnabled,
                      !asyncDispatchesTerminated,
                      isPluginExecutionCurrent(
                        binding.pluginID,
                        executionGeneration
                      ) else { return }
            }
            guard !Task.isCancelled,
                  !safeModeEnabled,
                  !asyncDispatchesTerminated,
                  isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                  ) else { return }
            await recordPlatformActionOutcome(
                pluginID: binding.pluginID,
                actionID: "schedule:\(binding.scheduleID)",
                requestID: nil,
                causationID: causationID,
                succeeded: true,
                durationMilliseconds: nil,
                error: nil,
                input: binding.configuration,
                result: result,
                settlementToken: settlementToken
            )
        } catch {
            guard !Task.isCancelled,
                  !safeModeEnabled,
                  !asyncDispatchesTerminated,
                  isPluginExecutionCurrent(
                    binding.pluginID,
                    executionGeneration
                  ) else { return }
            await recordPlatformActionOutcome(
                pluginID: binding.pluginID,
                actionID: "schedule:\(binding.scheduleID)",
                requestID: nil,
                causationID: causationID,
                succeeded: false,
                durationMilliseconds: nil,
                error: error,
                input: binding.configuration,
                result: nil,
                settlementToken: settlementToken
            )
            let errorSummary = Self.logErrorSummary(error)
            let errorCode: String
            if case let .string(value)? = errorSummary["error_code"] {
                errorCode = value
            } else {
                errorCode = "unknown"
            }
            logger.error(
                "schedule plugin=\(binding.pluginID, privacy: .public) id=\(binding.scheduleID, privacy: .public) error_code=\(errorCode, privacy: .public)"
            )
        }
    }

    @discardableResult
    func dispatchAsync(
        _ envelope: BlocksPluginEventEnvelope,
        admissionIsCurrent: (@MainActor () -> Bool)? = nil,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) -> Task<Void, Never>? {
        // A post-event can wait behind another FIFO item after its feature
        // operation has completed. Do not retain staged resources once its
        // source-bound admission has already been revoked.
        guard !safeModeEnabled,
              !asyncDispatchesTerminated,
              featureAdmissionIsCurrent(featureAdmission),
              admissionIsCurrent?() ?? true else {
            return nil
        }
        let resourceIDs = envelope.resources.map(\.id)
        let resourceBroker = resources
        resourceBroker.retainHostLease(ids: resourceIDs)
        let module = envelope.module
        let generation = asyncDispatchGenerationByModule[module, default: 0]
        let taskID = UUID()
        let previousTask = asyncDispatchTasksByModule[module]?.task
        let task = Task { @MainActor [weak self] in
            defer {
                resourceBroker.releaseHostLease(ids: resourceIDs)
                self?.completeAsyncDispatch(
                    module: module,
                    generation: generation,
                    taskID: taskID
                )
            }
            await previousTask?.value
            guard !Task.isCancelled else { return }
            guard let self,
                  !self.safeModeEnabled,
                  !self.asyncDispatchesTerminated,
                  self.featureAdmissionIsCurrent(featureAdmission),
                  admissionIsCurrent?() ?? true,
                  self.asyncDispatchGenerationByModule[module, default: 0]
                    == generation else {
                return
            }
            _ = await Self.$asyncDispatchingModule.withValue(module) {
                await self.dispatch(
                    envelope,
                    admissionIsCurrent: admissionIsCurrent,
                    featureAdmission: featureAdmission
                )
            }
        }
        asyncDispatchTasksByModule[module] = (id: taskID, task: task)
        asyncDispatchEnqueuedHook?(envelope)
        return task
    }

    private func completeAsyncDispatch(
        module: BlocksPluginModule,
        generation: UInt,
        taskID: UUID
    ) {
        guard asyncDispatchGenerationByModule[module, default: 0] == generation,
              asyncDispatchTasksByModule[module]?.id == taskID else { return }
        asyncDispatchTasksByModule.removeValue(forKey: module)
    }

    private func invalidateAsyncDispatches(permanently: Bool = false) {
        dispatchInvalidationGeneration &+= 1
        for (module, entry) in asyncDispatchTasksByModule {
            entry.task.cancel()
            asyncDispatchGenerationByModule[module, default: 0] &+= 1
        }
        asyncDispatchTasksByModule.removeAll()
        if permanently {
            asyncDispatchesTerminated = true
        }
    }

    private func cancelSchedules() {
        scheduleTasks.values.forEach { $0.cancel() }
        scheduleTasks.removeAll()
    }

    /// Synchronous runner admission.  The repository query is deliberately
    /// performed at the runner boundary under its SQLite connection lock, so
    /// an old task cannot use a stale in-memory subscriber snapshot after a
    /// same-ID schedule has been reconfigured or replaced.
    private func currentRunnableScheduleDeclaration(
        for binding: BlocksPluginScheduleBinding,
        admission: ScheduleRunnerAdmission?
    ) -> BlocksPluginScheduleDeclaration? {
        guard !Task.isCancelled,
              binding.isEnabled,
              manager.pluginSnapshotIsAuthoritative,
              let repository,
              let currentBinding = try? repository.scheduleBindings(
                  pluginID: binding.pluginID,
                  runnableOnly: true
              ).first(where: { $0.id == binding.id }),
              currentBinding.id == binding.id,
              currentBinding.pluginID == binding.pluginID,
              currentBinding.scheduleID == binding.scheduleID,
              currentBinding.kind == binding.kind,
              currentBinding.configuration == binding.configuration,
              currentBinding.isEnabled == binding.isEnabled,
              let manifest = manager.manifest(pluginID: binding.pluginID),
              let declaration = manifest.platform?.schedules.first(where: {
                  $0.id == binding.scheduleID
              }),
              declaration.kind == binding.kind,
              declaration.configuration == binding.configuration else {
            return nil
        }
        let executionGeneration = admission?.executionGeneration
            ?? manager.executionGeneration(pluginID: binding.pluginID)
        let expectedEntryFunction = admission?.entryFunction
        guard isPluginExecutionCurrent(
            binding.pluginID,
            executionGeneration
        ), (expectedEntryFunction == nil
            || declaration.entryFunction == expectedEntryFunction) else {
            return nil
        }
        return declaration
    }

    private func scheduleRunnerAdmission(
        for binding: BlocksPluginScheduleBinding
    ) -> ScheduleRunnerAdmission? {
        guard let declaration = currentRunnableScheduleDeclaration(
            for: binding,
            admission: nil
        ) else { return nil }
        return ScheduleRunnerAdmission(
            executionGeneration: manager.executionGeneration(
                pluginID: binding.pluginID
            ),
            entryFunction: declaration.entryFunction
        )
    }

    private func isDispatchValid(
        _ generation: UInt,
        allowsTerminationDispatch: Bool
    ) -> Bool {
        !Task.isCancelled
            && !safeModeEnabled
            && dispatchInvalidationGeneration == generation
            && (allowsTerminationDispatch || !asyncDispatchesTerminated)
    }

    func captureHostActionLifecycleToken() -> HostActionLifecycleToken {
        HostActionLifecycleToken(
            generation: dispatchInvalidationGeneration
        )
    }

    func isHostActionLifecycleCurrent(
        _ token: HostActionLifecycleToken
    ) -> Bool {
        isDispatchValid(
            token.generation,
            allowsTerminationDispatch: false
        )
    }

    func retainHostActionLifecycle(
        pluginID: String
    ) throws -> BlocksPluginHostOperationAdmissionGate.Lease {
        try manager.hostOperationAdmissionGate.acquire(pluginID: pluginID)
    }

    private func hostInvocationOrigin(
        for _: BlocksPluginEventEnvelope
    ) -> BlocksPluginHostInvocationOrigin {
        // A Hook is approved indirect automation, even when the event that
        // invoked it originated from an explicit user operation. It must not
        // launder that operation into authority for a sensitive host action.
        .background
    }

    func performPluginAction(
        pluginID: String,
        actionID: String,
        input: [String: JSONValue] = [:],
        kind: BlocksPluginRuntimeInvocationKind = .action,
        causationID: UUID = UUID(),
        origin: BlocksPluginHostInvocationOrigin? = nil,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) async throws -> BlocksPluginRuntimeResult {
        let resolvedOrigin = origin
            ?? (kind == .uiAction ? .explicitUser : .background)
        guard let metadata = manager.plugins.first(where: { $0.id == pluginID }) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
        }
        guard metadata.approvalStatus == .approved else {
            throw BlocksNativePluginExecutionError.pluginNotApproved
        }
        guard metadata.isEnabled, !metadata.safetyDisabled else {
            throw BlocksNativePluginExecutionError.pluginDisabled
        }
        let executionGeneration = manager.executionGeneration(pluginID: pluginID)
        let settlementToken = manager.executionSettlementGate.captureToken(
            pluginID: pluginID
        )
        let invalidationGeneration = dispatchInvalidationGeneration
        guard isDispatchValid(
            invalidationGeneration,
            allowsTerminationDispatch: false
        ), isPluginExecutionCurrent(pluginID, executionGeneration),
           featureAdmissionIsCurrent(featureAdmission) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "plugins_disabled_by_safe_mode"
            )
        }
        guard let manifest = try? JSONDecoder().decode(
                  BlocksNativePluginManifest.self,
                  from: Data(metadata.manifestJSON.utf8)
              ),
              let action = manifest.platform?.actions.first(where: { $0.id == actionID }) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(actionID)
        }
        guard metadata.approvedPermissions.contains("action:\(actionID)") else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "unapproved:action:\(actionID)"
            )
        }
        if kind == .action || kind == .uiAction {
            _ = await dispatch(BlocksPluginEventEnvelope(
                name: .automationManualTrigger,
                causationID: causationID,
                source: [
                    "kind": .string(kind.rawValue),
                    "plugin_id": .string(pluginID),
                ],
                payload: [
                    "plugin_id": .string(pluginID),
                    "action_id": .string(actionID),
                    "invocation_kind": .string(kind.rawValue),
                ]
            ), featureAdmission: featureAdmission)
        }
        guard isDispatchValid(
            invalidationGeneration,
            allowsTerminationDispatch: false
        ), isPluginExecutionCurrent(pluginID, executionGeneration),
           featureAdmissionIsCurrent(featureAdmission) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "plugins_disabled_by_safe_mode"
            )
        }
        let started = ContinuousClock.now
        let invocation = BlocksPluginRuntimeInvocation(
            pluginID: pluginID,
            kind: kind,
            entryFunction: action.entryFunction,
            input: input
        )
        do {
            guard isDispatchValid(
                invalidationGeneration,
                allowsTerminationDispatch: false
            ), isPluginExecutionCurrent(pluginID, executionGeneration),
               featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "plugins_disabled_by_safe_mode"
                )
            }
            let result = try await manager.executePlatform(
                pluginID: pluginID,
                invocation: invocation,
                timeoutSeconds: 30
            )
            guard await manager.executionSettlementGate.authorizeEffects(
                settlementToken
            ) else { return .init() }
            guard isDispatchValid(
                invalidationGeneration,
                allowsTerminationDispatch: false
            ), isPluginExecutionCurrent(pluginID, executionGeneration),
               featureAdmissionIsCurrent(featureAdmission) else {
                return .init()
            }
            guard isPluginExecutionCurrent(pluginID, executionGeneration),
                  featureAdmissionIsCurrent(featureAdmission) else {
                return .init()
            }
            try applyUIState(result.uiStatePatches, pluginID: pluginID)
            for requestedAction in result.actions {
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ) else { return .init() }
                guard isPluginExecutionCurrent(pluginID, executionGeneration),
                      featureAdmissionIsCurrent(featureAdmission) else {
                    return .init()
                }
                _ = try await performRequestedAction(
                    requestedAction,
                    requestingPluginID: pluginID,
                    causationID: causationID,
                    origin: resolvedOrigin,
                    executionGeneration: executionGeneration,
                    featureAdmission: featureAdmission
                )
                guard await manager.executionSettlementGate.authorizeEffects(
                    settlementToken
                ) else { return .init() }
                guard isDispatchValid(
                    invalidationGeneration,
                    allowsTerminationDispatch: false
                ), isPluginExecutionCurrent(pluginID, executionGeneration),
                   featureAdmissionIsCurrent(featureAdmission) else {
                    return .init()
                }
            }
            guard isPluginExecutionCurrent(pluginID, executionGeneration),
                  featureAdmissionIsCurrent(featureAdmission) else {
                return .init()
            }
            await recordPlatformActionOutcome(
                pluginID: pluginID,
                actionID: actionID,
                requestID: invocation.requestID,
                causationID: causationID,
                succeeded: true,
                durationMilliseconds: started.duration(to: .now).milliseconds,
                error: nil,
                input: input,
                result: result,
                settlementToken: settlementToken,
                featureAdmission: featureAdmission
            )
            return result
        } catch {
            guard isPluginExecutionCurrent(pluginID, executionGeneration),
                  featureAdmissionIsCurrent(featureAdmission) else {
                return .init()
            }
            await recordPlatformActionOutcome(
                pluginID: pluginID,
                actionID: actionID,
                requestID: invocation.requestID,
                causationID: causationID,
                succeeded: false,
                durationMilliseconds: started.duration(to: .now).milliseconds,
                error: error,
                input: input,
                result: nil,
                settlementToken: settlementToken,
                featureAdmission: featureAdmission
            )
            throw error
        }
    }

    private func performRequestedAction(
        _ invocation: BlocksPluginActionInvocation,
        requestingPluginID: String,
        causationID: UUID,
        origin: BlocksPluginHostInvocationOrigin,
        executionGeneration: UInt64,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) async throws -> JSONValue {
        guard featureAdmissionIsCurrent(featureAdmission) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "feature_admission_revoked"
            )
        }
        // Interactive destructive actions are deliberately excluded from the
        // idempotency ledger: replaying a completed key must not replay a prior
        // confirmation for a new user gesture.
        if requiresHostDestructiveConfirmation(invocation, origin: origin) {
            return try await performRequestedActionUncached(
                invocation,
                requestingPluginID: requestingPluginID,
                causationID: causationID,
                origin: origin,
                executionGeneration: executionGeneration,
                featureAdmission: featureAdmission
            )
        }
        guard let idempotencyKey = invocation.idempotencyKey else {
            return try await performRequestedActionUncached(
                invocation,
                requestingPluginID: requestingPluginID,
                causationID: causationID,
                origin: origin,
                executionGeneration: executionGeneration,
                featureAdmission: featureAdmission
            )
        }
        guard !idempotencyKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              idempotencyKey.utf8.count
                <= Self.maximumHostActionIdempotencyKeyBytes else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "invalid_idempotency_key"
            )
        }

        let key = HostActionIdempotencyKey(
            pluginID: requestingPluginID,
            key: idempotencyKey
        )
        let fingerprint = HostActionIdempotencyFingerprint(
            actionID: invocation.actionID,
            input: invocation.input,
            expectedRevision: invocation.expectedRevision
        )
        if let entry = hostActionIdempotencyEntries[key] {
            switch entry {
            case let .completed(existingFingerprint, result):
                guard existingFingerprint == fingerprint else {
                    throw BlocksPluginRuntimeError.idempotencyConflict
                }
                guard featureAdmissionIsCurrent(featureAdmission) else {
                    throw BlocksPluginRuntimeError.invalidHostOperation(
                        "feature_admission_revoked"
                    )
                }
                return result
            case let .inFlight(existingFingerprint, _, task):
                guard existingFingerprint == fingerprint else {
                    throw BlocksPluginRuntimeError.idempotencyConflict
                }
                let result = try await task.value
                guard featureAdmissionIsCurrent(featureAdmission) else {
                    throw BlocksPluginRuntimeError.invalidHostOperation(
                        "feature_admission_revoked"
                    )
                }
                return result
            }
        }

        let entryID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "plugin_runtime_unavailable"
                )
            }
            return try await self.performRequestedActionUncached(
                invocation,
                requestingPluginID: requestingPluginID,
                causationID: causationID,
                origin: origin,
                executionGeneration: executionGeneration,
                featureAdmission: featureAdmission
            )
        }
        hostActionIdempotencyEntries[key] = .inFlight(
            fingerprint: fingerprint,
            id: entryID,
            task: task
        )
        do {
            let result = try await task.value
            guard featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "feature_admission_revoked"
                )
            }
            completeHostActionIdempotencyEntry(
                key: key,
                fingerprint: fingerprint,
                entryID: entryID,
                result: result
            )
            return result
        } catch {
            removeFailedHostActionIdempotencyEntry(
                key: key,
                entryID: entryID
            )
            throw error
        }
    }

    private func performRequestedActionUncached(
        _ invocation: BlocksPluginActionInvocation,
        requestingPluginID: String,
        causationID: UUID,
        origin: BlocksPluginHostInvocationOrigin,
        executionGeneration: UInt64,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil,
        destructiveCapability: BlocksPluginDestructiveActionCapability? = nil,
        destructiveConfirmationRequestID: UUID? = nil,
        dispatchID: UUID = UUID()
    ) async throws -> JSONValue {
        guard !Task.isCancelled,
              !safeModeEnabled,
              !asyncDispatchesTerminated,
              featureAdmissionIsCurrent(featureAdmission) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "plugins_disabled_by_safe_mode"
            )
        }
        if actionRegistry.capability(id: invocation.actionID)?.risk == .destructive,
           case .commandLine = origin {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "destructive_host_actions_unavailable_from_cli"
            )
        }
        if destructiveCapability == nil,
           requiresHostDestructiveConfirmation(invocation, origin: origin) {
            // Do a short preflight before presenting UI, but do not retain the
            // host-operation lease while the sheet is awaiting a response.
            let lifecycleToken = captureHostActionLifecycleToken()
            try await preflightDestructiveConfirmation(
                invocation,
                requestingPluginID: requestingPluginID,
                executionGeneration: executionGeneration,
                featureAdmission: featureAdmission
            )
            let request = try destructiveConfirmationRequest(
                invocation,
                pluginID: requestingPluginID,
                causationID: causationID
            )
            guard let destructiveActionConfirmationHandler,
                  await destructiveActionConfirmationHandler(request) else {
                throw CancellationError()
            }
            guard isPluginExecutionCurrent(
                requestingPluginID,
                executionGeneration
            ), isHostActionLifecycleCurrent(lifecycleToken) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "plugins_disabled_by_safe_mode"
                )
            }
            // Re-enter through the normal admission and permission path. The
            // capability is private, target-bound and consumed by the registry.
            let capability = BlocksPluginDestructiveActionCapability(
                pluginID: requestingPluginID, actionID: invocation.actionID,
                targetID: request.targetID, requestID: request.requestID,
                dispatchID: dispatchID,
                causationID: causationID, expectedRevision: invocation.expectedRevision,
                executionGeneration: executionGeneration,
                lifecycleGeneration: lifecycleToken.generation
            )
            return try await performRequestedActionUncached(
                invocation,
                requestingPluginID: requestingPluginID,
                causationID: causationID,
                origin: origin,
                executionGeneration: executionGeneration,
                featureAdmission: featureAdmission,
                destructiveCapability: capability,
                destructiveConfirmationRequestID: request.requestID,
                dispatchID: dispatchID
            )
        }
        if invocation.actionID == "plugin.action.invoke" {
            let targetPluginID = try invocation.input.requiredString("plugin_id")
            let targetActionID = try invocation.input.requiredString("action_id")
            let permission = "plugin_action:\(targetPluginID):\(targetActionID)"
            let lease = try manager.hostOperationAdmissionGate.acquire(
                pluginID: requestingPluginID
            )
            defer { lease.release() }
            try await manager.requireRunnableHostActionPermission(
                pluginID: requestingPluginID,
                permission: permission
            )
            await hostActionPermissionApprovedHook?()
            guard featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "feature_admission_revoked"
                )
            }
            let recursionKey = "plugin-action|\(requestingPluginID)|\(targetPluginID)|\(targetActionID)|\(causationID.uuidString)"
            guard activeInvocationKeys.insert(recursionKey).inserted else {
                throw BlocksPluginRuntimeError.recursiveInvocation
            }
            defer { activeInvocationKeys.remove(recursionKey) }
            let targetInput: [String: JSONValue]
            if case let .object(value)? = invocation.input["input"] {
                targetInput = value
            } else {
                targetInput = [:]
            }
            let result = try await performPluginAction(
                pluginID: targetPluginID,
                actionID: targetActionID,
                input: targetInput,
                causationID: causationID,
                origin: origin,
                featureAdmission: featureAdmission
            )
            guard featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "feature_admission_revoked"
                )
            }
            return .object(result.output)
        }
        let permission = "host_action:\(invocation.actionID)"
        let lease = try manager.hostOperationAdmissionGate.acquire(
            pluginID: requestingPluginID
        )
        defer { lease.release() }
        try await manager.requireRunnableHostActionPermission(
            pluginID: requestingPluginID,
            permission: permission,
            unapprovedOperation: invocation.actionID
        )
        await hostActionPermissionApprovedHook?()
        do {
            guard featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "feature_admission_revoked"
                )
            }
            let output = try await actionRegistry.perform(
                invocation,
                context: .init(
                    requestingPluginID: requestingPluginID,
                    causationID: causationID,
                    origin: origin
                ),
                destructiveCapability: destructiveCapability,
                destructiveConfirmationRequestID: destructiveConfirmationRequestID,
                dispatchID: dispatchID,
                executionGeneration: executionGeneration,
                lifecycleGeneration: dispatchInvalidationGeneration
            )
            guard !Task.isCancelled,
                  !safeModeEnabled,
                  !asyncDispatchesTerminated,
                  featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "plugins_disabled_by_safe_mode"
                )
            }
            _ = await dispatch(
                BlocksPluginEventEnvelope(
                    name: .pluginHostActionCompleted,
                    causationID: causationID,
                    payload: [
                        "requesting_plugin_id": .string(requestingPluginID),
                        "action_id": .string(invocation.actionID),
                        "operation_id": invocation.input["operation_id"] ?? .null,
                        "output": output,
                    ]
                ),
                targetPluginID: requestingPluginID,
                featureAdmission: featureAdmission
            )
            return output
        } catch {
            guard featureAdmissionIsCurrent(featureAdmission) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "feature_admission_revoked"
                )
            }
            _ = await dispatch(
                BlocksPluginEventEnvelope(
                    name: .pluginHostActionFailed,
                    causationID: causationID,
                    payload: [
                        "requesting_plugin_id": .string(requestingPluginID),
                        "action_id": .string(invocation.actionID),
                        "operation_id": invocation.input["operation_id"] ?? .null,
                    ].merging(
                        Self.logErrorSummary(error),
                        uniquingKeysWith: { _, new in new }
                    )
                ),
                targetPluginID: requestingPluginID,
                featureAdmission: featureAdmission
            )
            throw error
        }
    }

    private func requiresHostDestructiveConfirmation(
        _ invocation: BlocksPluginActionInvocation,
        origin: BlocksPluginHostInvocationOrigin
    ) -> Bool {
        origin == .explicitUser
            && actionRegistry.capability(id: invocation.actionID)?.risk == .destructive
    }

    nonisolated static func destructiveTargetID(
        _ invocation: BlocksPluginActionInvocation
    ) -> String? {
        switch invocation.actionID {
        case "clipboard.record.delete": return invocation.input.string("record_id")
        case "clipboard.tag.delete": return invocation.input.string("tag_id")
        default: return nil
        }
    }

    private func destructiveConfirmationRequest(
        _ invocation: BlocksPluginActionInvocation,
        pluginID: String,
        causationID: UUID
    ) throws -> BlocksPluginDestructiveActionConfirmationRequest {
        let targetID: String
        switch invocation.actionID {
        case "clipboard.record.delete":
            targetID = try invocation.input.requiredString("record_id")
            guard let expectedRevision = invocation.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardDetailSaveFailure.revisionConflict
            }
        case "clipboard.tag.delete":
            targetID = try invocation.input.requiredString("tag_id")
            guard let expectedRevision = invocation.expectedRevision,
                  expectedRevision > 0 else {
                throw ClipboardTagMutationError.revisionConflict
            }
        default:
            throw BlocksPluginRuntimeError.invalidHostOperation(invocation.actionID)
        }
        return .init(
            requestID: UUID(),
            pluginID: pluginID,
            actionID: invocation.actionID,
            targetID: targetID,
            causationID: causationID,
            expectedRevision: invocation.expectedRevision
        )
    }

    private func preflightDestructiveConfirmation(
        _ invocation: BlocksPluginActionInvocation,
        requestingPluginID: String,
        executionGeneration: UInt64,
        featureAdmission: BlocksPluginFeatureAdmissionToken?
    ) async throws {
        guard !Task.isCancelled,
              !safeModeEnabled,
              !asyncDispatchesTerminated,
              isPluginExecutionCurrent(
                requestingPluginID,
                executionGeneration
              ),
              featureAdmissionIsCurrent(featureAdmission) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "plugins_disabled_by_safe_mode"
            )
        }
        try await manager.requireRunnableHostActionPermission(
            pluginID: requestingPluginID,
            permission: "host_action:\(invocation.actionID)",
            unapprovedOperation: invocation.actionID
        )
        guard isPluginExecutionCurrent(
            requestingPluginID,
            executionGeneration
        ) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "plugins_disabled_by_safe_mode"
            )
        }
    }

    private func completeHostActionIdempotencyEntry(
        key: HostActionIdempotencyKey,
        fingerprint: HostActionIdempotencyFingerprint,
        entryID: UUID,
        result: JSONValue
    ) {
        guard case let .inFlight(existingFingerprint, existingID, _)? =
                hostActionIdempotencyEntries[key],
              existingFingerprint == fingerprint,
              existingID == entryID else {
            return
        }
        let byteCount = Self.completedHostActionIdempotencyByteCount(
            key: key,
            fingerprint: fingerprint,
            result: result
        )
        guard byteCount <= Self.maximumCompletedHostActionIdempotencyBytes else {
            hostActionIdempotencyEntries.removeValue(forKey: key)
            return
        }
        hostActionIdempotencyEntries[key] = .completed(
            fingerprint: fingerprint,
            result: result
        )
        completedHostActionIdempotencyKeys.append(key)
        completedHostActionIdempotencyByteCounts[key] = byteCount
        completedHostActionIdempotencyBytes += byteCount
        while completedHostActionIdempotencyKeys.count
            > Self.maximumCompletedHostActionIdempotencyEntries
            || completedHostActionIdempotencyBytes
                > Self.maximumCompletedHostActionIdempotencyBytes {
            let oldest = completedHostActionIdempotencyKeys.removeFirst()
            if case .completed? = hostActionIdempotencyEntries[oldest] {
                hostActionIdempotencyEntries.removeValue(forKey: oldest)
            }
            completedHostActionIdempotencyBytes -=
                completedHostActionIdempotencyByteCounts.removeValue(
                    forKey: oldest
                ) ?? 0
        }
    }

    private static func completedHostActionIdempotencyByteCount(
        key: HostActionIdempotencyKey,
        fingerprint: HostActionIdempotencyFingerprint,
        result: JSONValue
    ) -> Int {
        let encoder = JSONEncoder()
        let inputBytes = (try? encoder.encode(fingerprint.input).count)
            ?? maximumCompletedHostActionIdempotencyBytes
        let resultBytes = (try? encoder.encode(result).count)
            ?? maximumCompletedHostActionIdempotencyBytes
        return key.pluginID.utf8.count
            + key.key.utf8.count
            + fingerprint.actionID.utf8.count
            + inputBytes
            + resultBytes
            + MemoryLayout<Int64?>.size
    }

    private func removeFailedHostActionIdempotencyEntry(
        key: HostActionIdempotencyKey,
        entryID: UUID
    ) {
        guard case let .inFlight(_, existingID, _)? =
                hostActionIdempotencyEntries[key],
              existingID == entryID else {
            return
        }
        hostActionIdempotencyEntries.removeValue(forKey: key)
    }

    private func clearHostActionIdempotencyLedger() {
        for entry in hostActionIdempotencyEntries.values {
            if case let .inFlight(_, _, task) = entry {
                task.cancel()
            }
        }
        hostActionIdempotencyEntries.removeAll()
        completedHostActionIdempotencyKeys.removeAll()
        completedHostActionIdempotencyByteCounts.removeAll()
        completedHostActionIdempotencyBytes = 0
    }

    private func hookDeclaration(
        for binding: BlocksPluginHookBinding
    ) -> BlocksPluginHookSubscription? {
        guard let metadata = manager.plugins.first(where: { $0.id == binding.pluginID }),
              let manifest = try? JSONDecoder().decode(
                  BlocksNativePluginManifest.self,
                  from: Data(metadata.manifestJSON.utf8)
              ),
              let hook = manifest.platform?.hooks.first(where: { $0.id == binding.hookID }) else {
            return nil
        }
        return hook
    }

    private func bindingMatchesDeclaration(
        _ binding: BlocksPluginHookBinding,
        _ declaration: BlocksPluginHookSubscription
    ) -> Bool {
        binding.event == declaration.event
            && binding.timeoutMilliseconds == declaration.timeoutMilliseconds
            && binding.failurePolicy == declaration.failurePolicy
    }

    private func isPluginExecutionCurrent(
        _ pluginID: String,
        _ generation: UInt64
    ) -> Bool {
        manager.isExecutionCurrent(pluginID: pluginID, generation: generation)
    }

    private func isPluginRunnerAdmissionCurrent(
        _ pluginID: String,
        _ generation: UInt64,
        allowsTerminationDispatch: Bool
    ) -> Bool {
        if allowsTerminationDispatch {
            return manager.isExecutionGenerationCurrent(
                pluginID: pluginID,
                generation: generation
            )
        }
        return isPluginExecutionCurrent(pluginID, generation)
    }

    private func isHostActionApproved(
        _ actionID: String,
        pluginID: String
    ) -> Bool {
        manager.plugins.first(where: { $0.id == pluginID })?
            .approvedPermissions
            .contains("host_action:\(actionID)") == true
    }

    private func validateMutationAuthorization(
        _ mutations: [BlocksPluginMutation],
        event: BlocksPluginEventName,
        pluginID: String
    ) throws {
        guard !mutations.isEmpty else { return }
        let approved = Set(
            manager.plugins.first(where: { $0.id == pluginID })?
                .approvedPermissions ?? []
        )
        let requiredPermission: String?
        switch event.module {
        case .clipboard:
            requiredPermission = mutations.contains {
                ["text", "plain_text"].contains($0.field)
            } ? "data:clipboard_content" : nil
        case .screenshot:
            requiredPermission = "data:screenshot_document"
        case .translation:
            requiredPermission = "data:translation_content"
        case .provider:
            requiredPermission = "data:provider_metadata"
        case .automation:
            requiredPermission = "data:app_context"
        case .app, .plugin:
            requiredPermission = nil
        }
        if let requiredPermission,
           !approved.contains(requiredPermission) {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "unapproved_mutation:\(event.rawValue)"
            )
        }
    }

    private func applying(
        _ mutations: [BlocksPluginMutation],
        to envelope: BlocksPluginEventEnvelope
    ) throws -> BlocksPluginEventEnvelope {
        var payload = envelope.payload
        for mutation in mutations {
            guard envelope.name.mutablePayloadFields.contains(
                mutation.field
            ) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "mutation:\(envelope.name.rawValue):\(mutation.field)"
                )
            }
            payload[mutation.field] = mutation.value
        }
        return BlocksPluginEventEnvelope(
            eventID: envelope.eventID,
            name: envelope.name,
            occurredAt: envelope.occurredAt,
            sessionID: envelope.sessionID,
            requestID: envelope.requestID,
            revision: envelope.revision,
            causationID: envelope.causationID,
            source: envelope.source,
            authorization: envelope.authorization,
            payload: payload,
            resources: envelope.resources
        )
    }

    private func authorizedEnvelope(
        _ envelope: BlocksPluginEventEnvelope,
        pluginID: String
    ) -> BlocksPluginEventEnvelope {
        guard let metadata = manager.plugins.first(where: {
            $0.id == pluginID
        }) else { return envelope }
        let permissions = Set(metadata.approvedPermissions)
        var payload = envelope.payload
        let sensitiveFields: Set<String>
        let dataPermission: String?
        switch envelope.module {
        case .clipboard:
            sensitiveFields = [
                "content", "text", "plain_text", "payload", "items",
                "ocr_text", "content_resource_id",
            ]
            dataPermission = "data:clipboard_content"
        case .screenshot:
            sensitiveFields = ["document", "image", "ocr_text"]
            dataPermission = "data:screenshot_document"
        case .translation:
            sensitiveFields = ["source_text", "translated_text"]
            dataPermission = "data:translation_content"
        case .provider:
            sensitiveFields = ["request", "response", "prompt"]
            dataPermission = "data:provider_metadata"
        case .automation, .app, .plugin:
            sensitiveFields = []
            dataPermission = "data:app_context"
        }
        if let dataPermission, !permissions.contains(dataPermission) {
            for key in sensitiveFields { payload.removeValue(forKey: key) }
        }
        let canReadImage = permissions.contains("data:screenshot_image")
        let canReadFiles = permissions.contains(
            BlocksPluginPermissionToken.userGrantedFiles
        )
        let resources = envelope.resources.filter { reference in
            switch reference.kind {
            case .image, .screenshot:
                canReadImage
            case .file, .binary:
                canReadFiles
            case .text:
                dataPermission.map(permissions.contains) ?? true
            }
        }
        return BlocksPluginEventEnvelope(
            eventID: envelope.eventID,
            name: envelope.name,
            occurredAt: envelope.occurredAt,
            sessionID: envelope.sessionID,
            requestID: envelope.requestID,
            revision: envelope.revision,
            causationID: envelope.causationID,
            source: envelope.source,
            authorization: BlocksPluginAuthorizationContext(
                approvedPermissionTokens: metadata.approvedPermissions,
                approvedDomains: metadata.approvedDomains,
                userInitiated: envelope.authorization.userInitiated
            ),
            payload: payload,
            resources: resources
        )
    }

    private func applyUIState(
        _ patches: [BlocksPluginUIStatePatch],
        pluginID: String
    ) throws {
        guard !patches.isEmpty else { return }
        let componentDefinitions = try approvedUIComponents(
            pluginID: pluginID
        )
        var pluginState = uiStateByPluginID[pluginID] ?? [:]
        for patch in patches {
            guard let definition = componentDefinitions[patch.componentID],
                  definition.kind.stateProperties.contains(
                    patch.property
                  ) else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "ui_patch:\(patch.componentID):\(patch.property)"
                )
            }
            var component = pluginState[patch.componentID] ?? [:]
            switch patch.operation {
            case .replace:
                component[patch.property] = patch.value ?? .null
            case .append:
                let old: [JSONValue]
                if case let .array(values)? = component[patch.property] { old = values }
                else if case let .array(values)? =
                    definition.properties[patch.property] { old = values }
                else { old = [] }
                component[patch.property] = .array(old + [patch.value ?? .null])
            case .remove:
                component.removeValue(forKey: patch.property)
            }
            pluginState[patch.componentID] = component
        }
        uiStateByPluginID[pluginID] = pluginState
    }

    private func approvedUIComponents(
        pluginID: String
    ) throws -> [String: BlocksPluginUIComponent] {
        guard let metadata = manager.plugins.first(where: {
            $0.id == pluginID
        }), let manifest = manager.manifest(pluginID: pluginID) else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "ui_manifest:\(pluginID)"
            )
        }
        let approved = Set(metadata.approvedPermissions)
        var result: [String: BlocksPluginUIComponent] = [:]
        for contribution in manifest.platform?.ui ?? []
            where approved.contains("ui:\(contribution.slot.rawValue)") {
            var pending = [contribution.root]
            while let component = pending.popLast() {
                result[component.id] = component
                pending.append(contentsOf: component.children)
            }
        }
        return result
    }

    private nonisolated func performSynchronousHostOperation(
        _ request: BlocksPluginHostOperationRequest
    ) -> BlocksPluginHostOperationResponse {
        do {
            let value = try manager.hostOperationAdmissionGate
                .withAdmittedOperation(pluginID: request.pluginID) {
                guard let repository else {
                    throw BlocksPluginRuntimeError.invalidHostOperation(request.operation)
                }
                let value: JSONValue
                switch request.operation {
            case "storage.get":
                let namespace = request.input.string("namespace") ?? "default"
                let key = try request.input.requiredString("key")
                let stored = try repository.privateValueForRuntime(
                    pluginID: request.pluginID,
                    namespace: namespace,
                    key: key
                )
                value = stored.map(Self.storedValueJSON) ?? .null
            case "storage.put":
                let namespace = request.input.string("namespace") ?? "default"
                let key = try request.input.requiredString("key")
                let newValue = request.input["value"] ?? .null
                let stored = try repository.putPrivateValueForRuntime(
                    pluginID: request.pluginID,
                    namespace: namespace,
                    key: key,
                    value: newValue,
                    expectedRevision: request.input.int64("expected_revision")
                )
                value = Self.storedValueJSON(stored)
            case "storage.queue.enqueue", "storage.queue.dequeue":
                let namespace = request.input.string("namespace") ?? "default"
                let key = try request.input.requiredString("key")
                let result: BlocksPluginQueueResult
                if request.operation == "storage.queue.enqueue" {
                    result = try repository.enqueuePrivateValueForRuntime(
                        pluginID: request.pluginID,
                        namespace: namespace,
                        key: key,
                        value: request.input["value"] ?? .null,
                        expectedRevision: request.input.int64("expected_revision")
                    )
                } else {
                    result = try repository.dequeuePrivateValueForRuntime(
                        pluginID: request.pluginID,
                        namespace: namespace,
                        key: key,
                        expectedRevision: request.input.int64("expected_revision")
                    )
                }
                value = .object([
                    "value": result.value ?? .null,
                    "remaining_count": .int(result.remainingCount),
                    "revision": .int(Int(result.revision)),
                ])
            case "shared.get":
                let owner = try request.input.requiredString("owner_plugin_id")
                let namespace = try request.input.requiredString("namespace")
                let key = try request.input.requiredString("key")
                let stored = try repository.sharedValueForRuntime(
                    actorPluginID: request.pluginID,
                    ownerPluginID: owner,
                    namespace: namespace,
                    key: key
                )
                value = stored.map(Self.storedValueJSON) ?? .null
            case "shared.put":
                let owner = request.input.string("owner_plugin_id") ?? request.pluginID
                let namespace = try request.input.requiredString("namespace")
                let key = try request.input.requiredString("key")
                let stored = try repository.putSharedValueForRuntime(
                    actorPluginID: request.pluginID,
                    ownerPluginID: owner,
                    namespace: namespace,
                    key: key,
                    schemaVersion: request.input.int("schema_version") ?? 1,
                    value: request.input["value"] ?? .null,
                    expectedRevision: request.input.int64("expected_revision")
                )
                value = Self.storedValueJSON(stored)
                Task { @MainActor [weak self] in
                    self?.dispatchAsync(BlocksPluginEventEnvelope(
                        name: .pluginSharedStateChanged,
                        source: [
                            "plugin_id": .string(request.pluginID),
                            "operation": .string("shared.put"),
                        ],
                        payload: [
                            "owner_plugin_id": .string(owner),
                            "namespace": .string(namespace),
                            "key": .string(key),
                            "revision": .int(Int(stored.revision)),
                            "schema_version": .int(
                                request.input.int("schema_version") ?? 1
                            ),
                        ]
                    ))
                }
            case "resource.read":
                try repository.requireRunnableForRuntime(
                    pluginID: request.pluginID
                )
                value = .object(try resources.read(
                    pluginID: request.pluginID,
                    id: request.input.requiredString("resource_id"),
                    offset: request.input.int("offset") ?? 0,
                    length: request.input.int("length") ?? 262_144
                ))
            default:
                throw BlocksPluginRuntimeError.invalidHostOperation(request.operation)
            }
                return value
            }
            return .init(requestID: request.requestID, ok: true, value: value)
        } catch BlocksPluginPlatformRepositoryError.storageQuotaExceeded {
            return .init(
                requestID: request.requestID,
                ok: false,
                errorCode: "storage_quota_exceeded",
                errorMessage: "The plugin storage quota was exceeded."
            )
        } catch BlocksPluginPlatformRepositoryError.storageKindNotDeclared {
            return .init(
                requestID: request.requestID,
                ok: false,
                errorCode: "storage_kind_not_declared",
                errorMessage: "The plugin did not declare this storage kind."
            )
        } catch {
            return .init(
                requestID: request.requestID,
                ok: false,
                errorCode: "host_operation_failed",
                errorMessage: "The host operation could not be completed."
            )
        }
    }

    private nonisolated static func storedValueJSON(
        _ stored: BlocksPluginStoredValue
    ) -> JSONValue {
        .object([
            "value": stored.value,
            "revision": .int(Int(clamping: stored.revision)),
            "updated_at": .double(stored.updatedAt.timeIntervalSince1970),
        ])
    }

    private func recordFailure(
        binding: BlocksPluginHookBinding,
        envelope: BlocksPluginEventEnvelope,
        error: Error,
        durationMilliseconds: Double,
        settlementToken: PluginExecutionSettlementGate.Token,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) async {
        guard featureAdmissionIsCurrent(featureAdmission),
              let repository else { return }
        let errorSummary = Self.logErrorSummary(error)
        manager.executionSettlementGate.beginOutcomeSettlement(settlementToken)
        let featureAdmissionGate = self.featureAdmissionGate
        let wasDisabled = (try? await Task.detached {
            guard featureAdmission.map(featureAdmissionGate.isCurrent) ?? true else {
                return false
            }
            return try repository.recordHookExecutionOutcomeAndAppendAudit(
                pluginID: binding.pluginID,
                hookID: binding.hookID,
                succeeded: false,
                eventID: envelope.eventID,
                causationID: envelope.causationID,
                level: .error,
                category: "hook",
                outcome: "failed",
                durationMilliseconds: durationMilliseconds,
                metadata: [
                    "event": .string(envelope.name.rawValue),
                ].merging(errorSummary, uniquingKeysWith: { _, new in new })
            )
        }.value) ?? false
        manager.executionSettlementGate.finishOutcomeSettlement(
            settlementToken, invalidateHook: wasDisabled
        )
        guard featureAdmissionIsCurrent(featureAdmission) else { return }
        writeDebugLog(
            pluginID: binding.pluginID,
            entry: [
                "category": .string("hook"),
                "event": .string(envelope.name.rawValue),
                "outcome": .string("failed"),
                "duration_ms": .double(durationMilliseconds),
            ].merging(errorSummary, uniquingKeysWith: { _, new in new }),
            debugOnlyPayload: true
        )
        if wasDisabled { await manager.reload() }
    }

    private func recordActionFailure(
        pluginID: String,
        envelope: BlocksPluginEventEnvelope,
        actionID: String,
        error: Error,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) async {
        guard featureAdmissionIsCurrent(featureAdmission),
              let repository else { return }
        let errorSummary = Self.logErrorSummary(error)
        let approvedActionID = approvedHostActionIDForLogging(
            actionID,
            pluginID: pluginID
        )
        var metadata = errorSummary
        if let approvedActionID {
            metadata["action"] = .string(approvedActionID)
        } else {
            metadata["action_classification"] = .string(
                "unapproved_or_unknown"
            )
        }
        guard featureAdmissionIsCurrent(featureAdmission) else { return }
        let featureAdmissionGate = self.featureAdmissionGate
        try? await Task.detached {
            guard featureAdmission.map(featureAdmissionGate.isCurrent) ?? true else {
                return
            }
            try repository.appendAudit(
                pluginID: pluginID,
                eventID: envelope.eventID,
                causationID: envelope.causationID,
                level: .error,
                category: "host_action",
                outcome: "failed",
                metadata: metadata
            )
        }.value
        guard featureAdmissionIsCurrent(featureAdmission) else { return }
        var entry: [String: JSONValue] = [
            "category": .string("host_action"),
            "outcome": .string("failed"),
        ]
        entry.merge(metadata, uniquingKeysWith: { _, new in new })
        writeDebugLog(
            pluginID: pluginID,
            entry: entry,
            debugOnlyPayload: true
        )
    }

    private func recordPlatformActionOutcome(
        pluginID: String,
        actionID: String,
        requestID: UUID?,
        causationID: UUID,
        succeeded: Bool,
        durationMilliseconds: Double?,
        error: Error?,
        input: [String: JSONValue],
        result: BlocksPluginRuntimeResult?,
        settlementToken: PluginExecutionSettlementGate.Token,
        featureAdmission: BlocksPluginFeatureAdmissionToken? = nil
    ) async {
        guard featureAdmissionIsCurrent(featureAdmission),
              let repository else { return }
        let errorSummary = error.map { Self.logErrorSummary($0) }
        manager.executionSettlementGate.beginOutcomeSettlement(settlementToken)
        let featureAdmissionGate = self.featureAdmissionGate
        let wasDisabled = (try? await Task.detached {
            guard featureAdmission.map(featureAdmissionGate.isCurrent) ?? true else {
                return false
            }
            var metadata: [String: JSONValue] = [
                "action": .string(actionID),
            ]
            if let errorSummary {
                metadata.merge(errorSummary, uniquingKeysWith: { _, new in new })
            }
            return try repository.recordExecutionOutcomeAndAppendAudit(
                pluginID: pluginID,
                succeeded: succeeded,
                requestID: requestID,
                causationID: causationID,
                level: succeeded ? .info : .error,
                category: actionID.hasPrefix("schedule:")
                    ? "schedule"
                    : "action",
                outcome: succeeded ? "completed" : "failed",
                durationMilliseconds: durationMilliseconds,
                metadata: metadata
            )
        }.value) ?? false
        if wasDisabled {
            manager.invalidateExecutionGeneration(pluginID: pluginID)
            // The failing action may itself hold an async admission lease.
            // Revoke at the persisted safety-cutoff boundary, then let that
            // already-admitted action unwind without waiting on itself.
            manager.revokeHostOperations(pluginID: pluginID)
            // Match the explicit-disable path: once the authoritative safety
            // threshold trips, cancel sibling executions before publishing the
            // refreshed disabled snapshot. The XPC executor still performs its
            // own database-backed eligibility check at dispatch boundaries.
            manager.cancelActiveExecutions(pluginID: pluginID)
            manager.executionSettlementGate.finishOutcomeSettlement(
                settlementToken, invalidatePlugin: true
            )
            guard featureAdmissionIsCurrent(featureAdmission) else { return }
            await manager.reload()
        } else {
            manager.executionSettlementGate.finishOutcomeSettlement(
                settlementToken
            )
        }
        guard featureAdmissionIsCurrent(featureAdmission) else { return }
        var entry: [String: JSONValue] = [
            "category": .string(
                actionID.hasPrefix("schedule:") ? "schedule" : "action"
            ),
            "action": .string(actionID),
            "outcome": .string(succeeded ? "completed" : "failed"),
            "input_summary": BlocksPluginLogRedactor.structuralSummary(input),
        ]
        if let durationMilliseconds {
            entry["duration_ms"] = .double(durationMilliseconds)
        }
        if let result {
            entry["output_summary"] = BlocksPluginLogRedactor
                .structuralSummary(result.output)
            entry["ui_state_patch_count"] = .int(result.uiStatePatches.count)
            entry["requested_action_count"] = .int(result.actions.count)
            entry["diagnostic_count"] = .int(result.diagnostics.count)
            entry["diagnostic_levels"] = .array(result.diagnostics.map {
                .string($0.level.rawValue)
            })
        }
        if let errorSummary {
            entry.merge(errorSummary, uniquingKeysWith: { _, new in new })
        }
        writeDebugLog(
            pluginID: pluginID,
            entry: entry,
            debugOnlyPayload: true
        )
    }

    private func writeDebugLog(
        pluginID: String,
        entry: [String: JSONValue],
        debugOnlyPayload: Bool
    ) {
        guard let metadata = manager.plugins.first(where: { $0.id == pluginID }) else { return }
        var output = entry
        if debugOnlyPayload, !metadata.debugEnabled {
            for key in [
                "input", "output", "mutations", "actions",
                "diagnostics", "ui_state_patches",
                "requested_actions", "network_request", "network_response",
                "stack", "error_detail", "idempotency_key",
                "input_summary", "output_summary", "mutation_count",
                "requested_action_count", "approved_action_ids",
                "ui_state_patch_count", "diagnostic_count",
                "diagnostic_levels",
            ] {
                output.removeValue(forKey: key)
            }
        }
        try? debugLogStore?.append(pluginID: pluginID, entry: output)
    }

    private func approvedHostActionIDs(
        _ actions: [BlocksPluginActionInvocation],
        pluginID: String
    ) -> [String] {
        Array(Set(actions.compactMap { action in
            approvedHostActionIDForLogging(
                action.actionID,
                pluginID: pluginID
            )
        })).sorted()
    }

    private func approvedHostActionIDForLogging(
        _ actionID: String,
        pluginID: String
    ) -> String? {
        guard actionID == "plugin.action.invoke"
            || isHostActionApproved(actionID, pluginID: pluginID) else {
            return nil
        }
        return actionID
    }

    private static func logErrorSummary(_ error: Error) -> [String: JSONValue] {
        let code: String
        let category: String
        if let error = error as? BlocksNativePluginExecutionError {
            category = "plugin_execution"
            switch error {
            case .runnerUnavailable: code = "runner_unavailable"
            case .pluginNotApproved: code = "plugin_not_approved"
            case .pluginDisabled: code = "plugin_disabled"
            case .packageHashMismatch: code = "package_hash_mismatch"
            case .capabilityUnavailable: code = "capability_unavailable"
            case .executionFailed: code = "execution_failed"
            }
        } else if let error = error as? BlocksPluginRuntimeError {
            category = "plugin_runtime"
            switch error {
            case .invalidHostOperation: code = "invalid_host_operation"
            case .idempotencyConflict: code = "idempotency_conflict"
            case .resourceUnavailable: code = "resource_unavailable"
            case .blocked: code = "blocked"
            case .chainTimedOut: code = "chain_timed_out"
            case .recursiveInvocation: code = "recursive_invocation"
            }
        } else {
            category = "plugin_unknown"
            code = String((error as NSError).code)
        }
        return BlocksPluginLogRedactor.errorSummary(
            error,
            category: category,
            code: code
        )
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw BlocksPluginRuntimeError.invalidHostOperation(key)
        }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case let .int(value)? = self[key] else { return nil }
        return value
    }

    func int64(_ key: String) -> Int64? {
        int(key).map(Int64.init)
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else { return nil }
        return value
    }
}
