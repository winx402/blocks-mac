import Combine
import AppKit
import Foundation
import BlocksCore
import OSLog

enum ClipboardRetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case days7
    case days30
    case days90
    case forever

    var id: String { rawValue }

    var dayCount: Int? {
        switch self {
        case .days7: 7
        case .days30: 30
        case .days90: 90
        case .forever: nil
        }
    }

    var localizedTitle: String {
        dayCount.map(String.init) ?? L10n.string("settings.clipboardPolicyForever")
    }

    var retentionSeconds: Int? {
        dayCount.map { $0 * 86_400 }
    }
}

enum ClipboardCleanupMode: String, CaseIterable, Identifiable, Sendable {
    case time
    case count

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .time:
            L10n.string("settings.clipboardPolicyCleanupByTime")
        case .count:
            L10n.string("settings.clipboardPolicyCleanupByCount")
        }
    }
}

enum ClipboardPolicyApplyResult: Equatable {
    case success(redactedCount: Int)
    case failure
}

enum ClipboardCleanupMutationState: Equatable, Sendable {
    case committed
    case previewing
    case awaitingConfirmation
    case applying

    // Compatibility aliases for existing non-settings cleanup callers.
    static let idle = ClipboardCleanupMutationState.committed
    static let policyPending = ClipboardCleanupMutationState.previewing
    static let active = ClipboardCleanupMutationState.applying
}

/// Opaque settings capability that binds a repository deletion plan to the
/// exact policy values the user previewed. Callers can retain and return it,
/// but cannot substitute a different persisted policy at confirmation time.
struct ClipboardPolicyConfirmationToken: Equatable, Sendable {
    fileprivate let repositoryPlanToken: ClipboardRepositoryPrunePlanToken
    let cleanupMode: ClipboardCleanupMode
    let retentionPolicy: ClipboardRetentionPolicy
    let maxItems: Int
    let preserveFavorite: Bool

    fileprivate init(
        repositoryPlanToken: ClipboardRepositoryPrunePlanToken,
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool
    ) {
        self.repositoryPlanToken = repositoryPlanToken
        self.cleanupMode = cleanupMode
        self.retentionPolicy = retentionPolicy
        self.maxItems = max(1, maxItems)
        self.preserveFavorite = preserveFavorite
    }

    fileprivate func makeRepositoryPolicy(now: Date = Date()) -> ClipboardRepositoryPrunePolicy {
        ClipboardRepositoryPrunePolicy(
            retentionSeconds: cleanupMode == .time ? retentionPolicy.retentionSeconds : nil,
            maxItems: cleanupMode == .count ? maxItems : nil,
            preserveFavorite: preserveFavorite,
            now: now
        )
    }

    fileprivate func replacingRepositoryPlanToken(
        _ token: ClipboardRepositoryPrunePlanToken
    ) -> ClipboardPolicyConfirmationToken {
        ClipboardPolicyConfirmationToken(
            repositoryPlanToken: token,
            cleanupMode: cleanupMode,
            retentionPolicy: retentionPolicy,
            maxItems: maxItems,
            preserveFavorite: preserveFavorite
        )
    }
}

enum ClipboardPolicyConfirmationResult: Equatable {
    case preview(deleteCount: Int, token: ClipboardPolicyConfirmationToken)
    case committed(visibleRecordCount: Int?)
    case stale(deleteCount: Int, token: ClipboardPolicyConfirmationToken)
    case failed
    case rejectedWhileBusy
}

enum ClipboardCleanupMutationFailure: Error, Equatable, Sendable {
    case repository
    case injected
}

enum ClipboardClearUnfavoritedResult: Equatable {
    case success(deletedCount: Int, remainingCount: Int)
    case failure(ClipboardCleanupMutationFailure)
    case rejectedWhileBusy
}

enum ClipboardCopyEventSource: String {
    case panelPaste = "panel-paste"
    case quickPaste = "quick-paste"
    case plainTextCopy = "plain-text-copy"
    case translationResult = "translation-result"
    case plugin = "plugin"
}

struct ClipboardRecordRecencyUpdate: Equatable {
    let recordFound: Bool
    let persisted: Bool
    let promotedAt: Date?

    static let notFound = ClipboardRecordRecencyUpdate(
        recordFound: false,
        persisted: false,
        promotedAt: nil
    )
}

struct ClipboardLiveCaptureIngestResult {
    let succeeded: Bool
    let durablyCommitted: Bool
    let duplicate: Bool
    let record: ClipboardRecorderRecord?
    let invalidated: Bool

    static let failed = ClipboardLiveCaptureIngestResult(
        succeeded: false,
        durablyCommitted: false,
        duplicate: false,
        record: nil,
        invalidated: false
    )

    static let invalidated = ClipboardLiveCaptureIngestResult(
        succeeded: false,
        durablyCommitted: false,
        duplicate: false,
        record: nil,
        invalidated: true
    )
}

private struct ClipboardCapturePersistenceOutcome: @unchecked Sendable {
    let insertResult: ClipboardRepositoryInsertResult?
    let policyResult: ClipboardRepositoryPruneResult?
    let errorDescription: String?
    let invalidated: Bool

    var succeeded: Bool {
        insertResult != nil && errorDescription == nil
    }
}

struct ClipboardCapturePersistencePipelineHooks: Sendable {
    var beforePrivacyAdmission: @Sendable () -> Void = {}
    var beforeInsert: @Sendable () -> Void = {}
    var afterCommitBeforeContinuation: @Sendable () -> Void = {}
}

final class ClipboardCaptureGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func capture() -> UInt64 {
        lock.withLock { value }
    }

    func invalidate() {
        lock.withLock { value &+= 1 }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { value == generation }
    }

    /// Linearizes a capture mutation with feature invalidation. The body must
    /// remain synchronous and must not re-enter this generation gate.
    func withCurrentAdmission<Result>(
        _ generation: UInt64,
        _ body: () -> Result
    ) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard value == generation else { return nil }
        return body()
    }
}

struct ClipboardRecordActionLease: Equatable, Sendable {
    fileprivate let recordID: String
    fileprivate let token: UUID
}

struct ClipboardRecordCommitPermit: Equatable, Sendable {
    fileprivate let token: UUID
}

/// Linearizes record-backed pasteboard commits with repository mutations that
/// can delete the supplying record. The permit is held by the caller, rather
/// than across an actor-isolated closure, so awaits inside Broker/database work
/// cannot make the gate reentrant.
actor ClipboardRecordCommitGate {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<ClipboardRecordCommitPermit?, Never>
    }

    private var ownerToken: UUID?
    private var waiters: [Waiter] = []

    func acquire() async -> ClipboardRecordCommitPermit? {
        guard !Task.isCancelled else { return nil }
        let token = UUID()
        if ownerToken == nil {
            ownerToken = token
            return ClipboardRecordCommitPermit(token: token)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append(Waiter(token: token, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    func release(_ permit: ClipboardRecordCommitPermit) {
        guard ownerToken == permit.token else {
            assertionFailure("Clipboard record commit permit released by a non-owner")
            return
        }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            ownerToken = waiter.token
            waiter.continuation.resume(
                returning: ClipboardRecordCommitPermit(token: waiter.token)
            )
            return
        }
        ownerToken = nil
    }

    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}

/// Keeps record-backed actions bound to the lifetime that supplied their
/// payload. Repository mutations run off MainActor, so relying on the
/// published `records` array leaves a window where a committed deletion can
/// still authorize a stale clipboard write.
private final class ClipboardRecordActionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var activeTokensByRecordID: [String: Set<UUID>] = [:]

    func lease(recordID: String) -> ClipboardRecordActionLease {
        lock.withLock {
            let token = UUID()
            activeTokensByRecordID[recordID, default: []].insert(token)
            return ClipboardRecordActionLease(recordID: recordID, token: token)
        }
    }

    func isCurrent(_ lease: ClipboardRecordActionLease) -> Bool {
        lock.withLock {
            activeTokensByRecordID[lease.recordID]?.contains(lease.token) == true
        }
    }

    func finish(_ lease: ClipboardRecordActionLease) {
        lock.withLock {
            guard var activeTokens = activeTokensByRecordID[lease.recordID] else {
                return
            }
            activeTokens.remove(lease.token)
            if activeTokens.isEmpty {
                activeTokensByRecordID.removeValue(forKey: lease.recordID)
            } else {
                activeTokensByRecordID[lease.recordID] = activeTokens
            }
        }
    }

    func invalidate(recordIDs: some Sequence<String>) {
        lock.withLock {
            for recordID in recordIDs {
                activeTokensByRecordID.removeValue(forKey: recordID)
            }
        }
    }

    func invalidateAll() {
        lock.withLock { activeTokensByRecordID.removeAll() }
    }
}

enum ClipboardCleanupMutationKind: Equatable, Sendable {
    case applyPolicy
    case clearUnfavorited
}

struct ClipboardCleanupMutationPipelineHooks: Sendable {
    var beforeMutation: @Sendable (ClipboardCleanupMutationKind) -> Void = { _ in }
    var shouldFailMutation: @Sendable (ClipboardCleanupMutationKind) -> Bool = { _ in false }
    var shouldFailVisibleCountRead: @Sendable () -> Bool = { false }
}

private enum ClipboardCleanupMutationOutcome {
    case policy(
        ClipboardRepositoryPruneResult,
        visibleRecordCount: Int?,
        postMutationFailure: ClipboardCleanupMutationFailure?
    )
    case clear(ClipboardRepositoryClearResult)
    case stale(ClipboardRepositoryPrunePlan)
    case failure(ClipboardCleanupMutationFailure)
}

private struct ClipboardCommittedCleanupPolicy: Sendable {
    let retentionSeconds: Int?
    let maxItems: Int?
    let preserveFavorite: Bool

    init(_ policy: ClipboardRepositoryPrunePolicy) {
        retentionSeconds = policy.retentionSeconds
        maxItems = policy.maxItems
        preserveFavorite = policy.preserveFavorite
    }

    func makePolicy() -> ClipboardRepositoryPrunePolicy {
        ClipboardRepositoryPrunePolicy(
            retentionSeconds: retentionSeconds,
            maxItems: maxItems,
            preserveFavorite: preserveFavorite
        )
    }
}

/// Preserves repository mutation order across live capture, policy cleanup,
/// and explicit clear operations. These paths all touch the same record, FTS,
/// tag, and sidecar graph, so separate background queues can otherwise apply
/// a stale cleanup policy after a newer one has committed.
private final class ClipboardRepositoryMutationQueue: ClipboardRepositoryMutationExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.blocks.clipboard.repository-mutation",
        qos: .utility
    )
    private var committedPolicy: ClipboardCommittedCleanupPolicy?

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    func recordCommittedPolicy(_ policy: ClipboardRepositoryPrunePolicy) {
        dispatchPrecondition(condition: .onQueue(queue))
        committedPolicy = ClipboardCommittedCleanupPolicy(policy)
    }

    func effectivePolicy(
        fallback: ClipboardRepositoryPrunePolicy
    ) -> ClipboardRepositoryPrunePolicy {
        dispatchPrecondition(condition: .onQueue(queue))
        return committedPolicy?.makePolicy() ?? fallback
    }
}

private enum ClipboardRecordMutationOutcome: Sendable {
    case deleted
    case copied(Date)
    case notFound
    case revisionConflict
    case failure
}

enum ClipboardRecordMutationKind: Equatable, Sendable {
    case delete
    case markCopied
}

struct ClipboardRecordMutationPipelineHooks: Sendable {
    var beforeCommitGateAcquire: @Sendable (ClipboardRecordMutationKind) -> Void = { _ in }
    var beforeMutation: @Sendable (ClipboardRecordMutationKind) -> Void = { _ in }
    var shouldFailMutation: @Sendable (ClipboardRecordMutationKind) -> Bool = { _ in false }
}

/// Runs record metadata and deletion writes on the same serial queue as
/// capture, retention cleanup, and tag mutations. Once submitted, a database
/// write is allowed to settle even if its caller is cancelled; the MainActor
/// then publishes the committed truth instead of pretending the write did not
/// happen.
private final class ClipboardRecordMutationPipeline: @unchecked Sendable {
    private let repository: ClipboardRepository?
    private let mutationQueue: ClipboardRepositoryMutationQueue
    private let hooks: ClipboardRecordMutationPipelineHooks
    private let recordActionValidity: ClipboardRecordActionValidity
    private let commitGate: ClipboardRecordCommitGate

    init(
        repository: ClipboardRepository?,
        mutationQueue: ClipboardRepositoryMutationQueue,
        hooks: ClipboardRecordMutationPipelineHooks,
        recordActionValidity: ClipboardRecordActionValidity,
        commitGate: ClipboardRecordCommitGate
    ) {
        self.repository = repository
        self.mutationQueue = mutationQueue
        self.hooks = hooks
        self.recordActionValidity = recordActionValidity
        self.commitGate = commitGate
    }

    func delete(
        recordID: String,
        expectedContentRevision: Int64? = nil
    ) async -> ClipboardRecordMutationOutcome {
        hooks.beforeCommitGateAcquire(.delete)
        guard let permit = await commitGate.acquire() else { return .failure }
        guard !Task.isCancelled else {
            await commitGate.release(permit)
            return .failure
        }
        let outcome = await perform(.delete) { repository in
            do {
                switch try repository.delete(
                    recordID: recordID,
                    expectedContentRevision: expectedContentRevision,
                    onCommittedDeletion: { deletedRecordIDs in
                        self.recordActionValidity.invalidate(
                            recordIDs: deletedRecordIDs
                        )
                    }
                ) {
                case .deleted:
                    return .deleted
                case .recordNotFound:
                    return .notFound
                case .revisionConflict:
                    return .revisionConflict
                }
            } catch {
                return .failure
            }
        }
        await commitGate.release(permit)
        return outcome
    }

    func markCopied(
        recordID: String,
        at date: Date
    ) async -> ClipboardRecordMutationOutcome {
        await perform(.markCopied) { repository in
            do {
                return .copied(try repository.markCopied(recordID: recordID, at: date))
            } catch ClipboardRepositoryError.recordNotFound(_) {
                return .notFound
            } catch {
                return .failure
            }
        }
    }

    func updateRecordFromPlugin(
        recordID: String,
        customTitle: String?,
        text: String?,
        expectedContentRevision: Int64
    ) async throws -> ClipboardDetailSaveResult {
        guard let permit = await commitGate.acquire() else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            await commitGate.release(permit)
            throw CancellationError()
        }
        do {
            let result: ClipboardDetailSaveResult = try await withCheckedThrowingContinuation { continuation in
                mutationQueue.enqueue { [repository] in
                    guard let repository else {
                        continuation.resume(throwing: BlocksPluginRuntimeError.invalidHostOperation(
                            "clipboard.record.update:repository_unavailable"
                        ))
                        return
                    }
                    do {
                        let model = try repository.loadDetailReadModel(
                            recordID: recordID
                        )
                        let editableKind: ClipboardDetailEditableKind
                        if text != nil {
                            guard case let .editable(kind) = model.editability else {
                                throw ClipboardDetailSaveFailure.notEditable
                            }
                            editableKind = kind
                        } else {
                            // The kind is not consulted when updatesPayload is false.
                            editableKind = .plainText
                        }
                        let result = try repository.saveDetailEdit(
                            command: ClipboardDetailEditCommand(
                                recordID: recordID,
                                expectedContentRevision: expectedContentRevision,
                                editableKind: editableKind,
                                draft: ClipboardDetailDraft(text: text ?? ""),
                                customTitle: customTitle,
                                updatesPayload: text != nil,
                                updatesCustomTitle: customTitle != nil,
                                purpose: ClipboardDetailEditSavePurpose.pluginRecordUpdate.rawValue
                            ),
                            onCommittedDeletion: { deletedRecordIDs in
                                self.recordActionValidity.invalidate(
                                    recordIDs: deletedRecordIDs
                                )
                            }
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            await commitGate.release(permit)
            return result
        } catch {
            await commitGate.release(permit)
            throw error
        }
    }

    private func perform(
        _ kind: ClipboardRecordMutationKind,
        _ operation: @escaping @Sendable (ClipboardRepository) -> ClipboardRecordMutationOutcome
    ) async -> ClipboardRecordMutationOutcome {
        await withCheckedContinuation { continuation in
            mutationQueue.enqueue { [repository, hooks] in
                hooks.beforeMutation(kind)
                guard let repository else {
                    continuation.resume(returning: .failure)
                    return
                }
                guard !hooks.shouldFailMutation(kind) else {
                    continuation.resume(returning: .failure)
                    return
                }
                continuation.resume(returning: operation(repository))
            }
        }
    }
}

/// Serializes expensive cleanup writes away from `MainActor`.
///
/// Policy application and clearing unfavorited records can fan out into record,
/// FTS, tag, and sidecar deletion work. Requests are intentionally not
/// cancelled once submitted: database mutations remain ordered, while the
/// store generation prevents an older completion from publishing over a newer
/// user request.
private final class ClipboardCleanupMutationPipeline: @unchecked Sendable {
    private let repository: ClipboardRepository?
    private let hooks: ClipboardCleanupMutationPipelineHooks
    private let mutationQueue: ClipboardRepositoryMutationQueue
    private let recordActionValidity: ClipboardRecordActionValidity
    private let commitGate: ClipboardRecordCommitGate

    init(
        repository: ClipboardRepository?,
        hooks: ClipboardCleanupMutationPipelineHooks,
        mutationQueue: ClipboardRepositoryMutationQueue,
        recordActionValidity: ClipboardRecordActionValidity,
        commitGate: ClipboardRecordCommitGate
    ) {
        self.repository = repository
        self.hooks = hooks
        self.mutationQueue = mutationQueue
        self.recordActionValidity = recordActionValidity
        self.commitGate = commitGate
    }

    func applyPolicy(
        _ policy: ClipboardRepositoryPrunePolicy,
        visibleLimit: Int
    ) async -> ClipboardCleanupMutationOutcome {
        guard let permit = await commitGate.acquire() else { return .failure(.repository) }
        guard !Task.isCancelled else {
            await commitGate.release(permit)
            return .failure(.repository)
        }
        let outcome = await perform(.applyPolicy) { repository in
            let result = try repository.applyPolicy(
                policy,
                onCommittedDeletion: { deletedRecordIDs in
                    self.recordActionValidity.invalidate(
                        recordIDs: deletedRecordIDs
                    )
                }
            )
            self.mutationQueue.recordCommittedPolicy(policy)
            // The follow-up read is not part of the mutation's success
            // contract: a completed deletion must not be reported as failed
            // when only its optional visible-count refresh fails.
            do {
                if self.hooks.shouldFailVisibleCountRead() {
                    throw ClipboardCleanupVisibleCountReadFailure.injected
                }
                let visibleRecordCount = try repository.loadRecent(
                    limit: max(1, visibleLimit)
                ).count
                return .policy(result, visibleRecordCount: visibleRecordCount, postMutationFailure: nil)
            } catch ClipboardCleanupVisibleCountReadFailure.injected {
                return .policy(result, visibleRecordCount: nil, postMutationFailure: .injected)
            } catch {
                return .policy(result, visibleRecordCount: nil, postMutationFailure: .repository)
            }
        }
        await commitGate.release(permit)
        return outcome
    }

    func previewPolicy(
        _ policy: ClipboardRepositoryPrunePolicy
    ) async -> Result<ClipboardRepositoryPrunePlan, ClipboardCleanupMutationFailure> {
        guard let permit = await commitGate.acquire() else { return .failure(.repository) }
        let outcome: Result<ClipboardRepositoryPrunePlan, ClipboardCleanupMutationFailure> = await withCheckedContinuation { continuation in
            mutationQueue.enqueue { [repository] in
                do {
                    guard let repository else { throw ClipboardRepositoryError.recordNotFound("repository") }
                    continuation.resume(returning: .success(try repository.makePrunePlan(policy)))
                } catch {
                    continuation.resume(returning: .failure(.repository))
                }
            }
        }
        await commitGate.release(permit)
        return outcome
    }

    func applyConfirmedPolicy(
        _ policy: ClipboardRepositoryPrunePolicy,
        token: ClipboardRepositoryPrunePlanToken,
        visibleLimit: Int
    ) async -> ClipboardCleanupMutationOutcome {
        guard let permit = await commitGate.acquire() else { return .failure(.repository) }
        let outcome = await perform(.applyPolicy) { repository in
            guard let result = try repository.applyPolicyConfirming(
                policy,
                expectedPlanToken: token,
                onCommittedDeletion: { deletedRecordIDs in
                    self.recordActionValidity.invalidate(recordIDs: deletedRecordIDs)
                }
            ) else {
                return .stale(try repository.makePrunePlan(policy))
            }
            self.mutationQueue.recordCommittedPolicy(policy)
            do {
                if self.hooks.shouldFailVisibleCountRead() {
                    throw ClipboardCleanupVisibleCountReadFailure.injected
                }
                let visibleRecordCount = try repository.loadRecent(limit: max(1, visibleLimit)).count
                return .policy(result, visibleRecordCount: visibleRecordCount, postMutationFailure: nil)
            } catch ClipboardCleanupVisibleCountReadFailure.injected {
                return .policy(result, visibleRecordCount: nil, postMutationFailure: .injected)
            } catch {
                return .policy(result, visibleRecordCount: nil, postMutationFailure: .repository)
            }
        }
        await commitGate.release(permit)
        return outcome
    }

    func clearUnfavorited() async -> ClipboardCleanupMutationOutcome {
        guard let permit = await commitGate.acquire() else { return .failure(.repository) }
        guard !Task.isCancelled else {
            await commitGate.release(permit)
            return .failure(.repository)
        }
        let outcome = await perform(.clearUnfavorited) { repository in
            let result = try repository.clearUnfavorited(
                onCommittedDeletion: { deletedRecordIDs in
                    self.recordActionValidity.invalidate(
                        recordIDs: deletedRecordIDs
                    )
                }
            )
            return .clear(result)
        }
        await commitGate.release(permit)
        return outcome
    }

    private func perform(
        _ kind: ClipboardCleanupMutationKind,
        operation: @escaping (ClipboardRepository) throws -> ClipboardCleanupMutationOutcome
    ) async -> ClipboardCleanupMutationOutcome {
        await withCheckedContinuation { continuation in
            mutationQueue.enqueue { [repository, hooks] in
                hooks.beforeMutation(kind)
                guard let repository else {
                    continuation.resume(returning: .failure(.repository))
                    return
                }
                guard !hooks.shouldFailMutation(kind) else {
                    continuation.resume(returning: .failure(.injected))
                    return
                }
                do {
                    continuation.resume(returning: try operation(repository))
                } catch {
                    continuation.resume(returning: .failure(.repository))
                }
            }
        }
    }
}

private enum ClipboardCleanupVisibleCountReadFailure: Error {
    case injected
}

/// Serializes image/text persistence away from `MainActor`.
///
/// Clipboard payloads may contain multi-megabyte images. Persisting them also
/// performs signature lookup, BLOB/sidecar I/O, FTS updates and retention
/// pruning, none of which may block AppKit or SwiftUI updates.
private final class ClipboardCapturePersistencePipeline: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-capture-persistence"
    )
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-capture-persistence"
    )

    private let repository: ClipboardRepository?
    private let mutationQueue: ClipboardRepositoryMutationQueue
    private let hooks: ClipboardCapturePersistencePipelineHooks
    private let recordActionValidity: ClipboardRecordActionValidity
    private let commitGate: ClipboardRecordCommitGate

    init(
        repository: ClipboardRepository?,
        mutationQueue: ClipboardRepositoryMutationQueue,
        hooks: ClipboardCapturePersistencePipelineHooks,
        recordActionValidity: ClipboardRecordActionValidity,
        commitGate: ClipboardRecordCommitGate
    ) {
        self.repository = repository
        self.mutationQueue = mutationQueue
        self.hooks = hooks
        self.recordActionValidity = recordActionValidity
        self.commitGate = commitGate
    }

    func persist(
        snapshot: ClipboardLiveCaptureSnapshot,
        capturePolicy: ClipboardCapturePolicy,
        prunePolicy: ClipboardRepositoryPrunePolicy,
        captureGeneration: ClipboardCaptureGeneration?,
        captureGenerationValue: UInt64,
        privacyCaptureAdmissionToken: PrivacyCaptureAdmissionToken?
    ) async -> ClipboardCapturePersistenceOutcome {
        guard let permit = await commitGate.acquire() else {
            return ClipboardCapturePersistenceOutcome(
                insertResult: nil,
                policyResult: nil,
                errorDescription: nil,
                invalidated: true
            )
        }
        let outcome: ClipboardCapturePersistenceOutcome = await withCheckedContinuation { continuation in
            mutationQueue.enqueue { [repository, mutationQueue, hooks] in
                let startedAt = ContinuousClock.now
                let interval = Self.signposter.beginInterval("Persist")
                defer { Self.signposter.endInterval("Persist", interval) }
                guard let repository else {
                    continuation.resume(returning: ClipboardCapturePersistenceOutcome(
                        insertResult: nil,
                        policyResult: nil,
                        errorDescription: "repository_unavailable",
                        invalidated: false
                    ))
                    return
                }
                // Test and observability hook deliberately precedes privacy
                // admission, so revocation can linearize first without waiting
                // on a hook that has not begun database work.
                hooks.beforePrivacyAdmission()
                let performAdmittedDatabaseTransaction = {
                    do {
                        let insertResult = try repository.insert(
                            record: snapshot.record,
                            payload: snapshot.payload,
                            capturePolicy: capturePolicy
                        )
                        let effectivePrunePolicy = mutationQueue.effectivePolicy(
                            fallback: prunePolicy
                        )
                        let policyResult = insertResult.duplicate
                            ? nil
                            : try repository.applyPolicy(
                                effectivePrunePolicy,
                                onCommittedDeletion: { deletedRecordIDs in
                                    self.recordActionValidity.invalidate(
                                        recordIDs: deletedRecordIDs
                                    )
                                }
                            )
                        return ClipboardCapturePersistenceOutcome(
                            insertResult: insertResult,
                            policyResult: policyResult,
                            errorDescription: nil,
                            invalidated: false
                        )
                    } catch {
                        Self.logger.error(
                            "stage=failed record=\(snapshot.record.id, privacy: .public) kind=\(snapshot.record.kind.rawValue, privacy: .public) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt)) error=\(String(describing: error), privacy: .public)"
                        )
                        return ClipboardCapturePersistenceOutcome(
                            insertResult: nil,
                            policyResult: nil,
                            errorDescription: String(describing: error),
                            invalidated: false
                        )
                    }
                }
                let performDatabaseTransaction = {
                    // This hook remains outside the generation lease so a
                    // feature disable can linearize before database work.
                    hooks.beforeInsert()
                    guard let captureGeneration else {
                        return performAdmittedDatabaseTransaction()
                    }
                    return captureGeneration.withCurrentAdmission(
                        captureGenerationValue,
                        performAdmittedDatabaseTransaction
                    ) ?? ClipboardCapturePersistenceOutcome(
                            insertResult: nil,
                            policyResult: nil,
                            errorDescription: nil,
                            invalidated: true
                    )
                }
                let outcome: ClipboardCapturePersistenceOutcome
                if let privacyCaptureAdmissionToken {
                    // This is the privacy revoke/insert linearization point.
                    // The insert and retention transaction run while the gate
                    // is held, so a later revoke waits for their durable result.
                    guard let admittedOutcome =
                        privacyCaptureAdmissionToken.withAuthorizedAdmission(
                            performDatabaseTransaction
                        )
                    else {
                        continuation.resume(returning: ClipboardCapturePersistenceOutcome(
                            insertResult: nil,
                            policyResult: nil,
                            errorDescription: nil,
                            invalidated: true
                        ))
                        return
                    }
                    outcome = admittedOutcome
                } else {
                    outcome = performDatabaseTransaction()
                }
                if outcome.succeeded {
                    hooks.afterCommitBeforeContinuation()
                    Self.logger.info(
                        "stage=finished record=\(snapshot.record.id, privacy: .public) kind=\(snapshot.record.kind.rawValue, privacy: .public) duplicate=\(outcome.insertResult?.duplicate ?? false) inserted=\(outcome.insertResult?.inserted ?? false) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                }
                continuation.resume(returning: outcome)
            }
        }
        await commitGate.release(permit)
        return outcome
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

@MainActor
final class ClipboardStore: ObservableObject {
    private static let orderingLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-ordering"
    )
    private static let performanceSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-performance"
    )
    private let repository: ClipboardRepository?
    private let historyReadPipeline: ClipboardHistoryReadPipeline
    private let recordActionPipeline: ClipboardRecordActionPipeline
    private let recordMutationPipeline: ClipboardRecordMutationPipeline
    private let capturePersistencePipeline: ClipboardCapturePersistencePipeline
    private let cleanupMutationPipeline: ClipboardCleanupMutationPipeline
    private let recordActionValidity: ClipboardRecordActionValidity
    let recordCommitGate: ClipboardRecordCommitGate
    private let cleanupPolicyDebounce: Duration
    let tagStore: ClipboardTagStore
    let detailStore: ClipboardDetailStore
    private var ocrScheduler: ClipboardOCRScheduler?
    private var lastLoadLimit = 500
    private var repositoryHistoryExhausted = false
    private var payloadCache: [ClipboardPayloadCacheKey: ClipboardRecorderPayload] = [:]
    private var imagePreviewCache: [String: NSImage] = [:]
    private var imagePreviewTasks: [String: Task<Void, Never>] = [:]
    private var imagePreviewFailures: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var didScheduleIndexMaintenance = false
    @Published var records: [ClipboardRecorderRecord] = []
    @Published var filterState = ClipboardFilterState()
    @Published var recorderPaused = false
    @Published var pasteAttempt: ClipboardPasteAttempt?
    @Published var floatingSelectedRecordID: String?
    @Published private(set) var repositoryUnavailable = false
    @Published private(set) var cleanupMutationState: ClipboardCleanupMutationState = .idle
    @Published private(set) var pendingAttachmentCleanupCount = 0
    @Published private(set) var currentSearchResult: ClipboardSearchResultSet = .idle(records: [])
    private(set) var searchRevision: UInt64 = 0
    private var previewSnapshots: [String: ClipboardContentPreviewSnapshot] = [:]
    private var activeSearchQuery = ""
    private var activeSearchLimit: Int?
    private var pendingTagSearchRefresh: Task<Void, Never>?
    private var favoriteMutationRecordIDs: Set<String> = []
    private var historyReadTask: Task<Void, Never>?
    private var historyReadGeneration: UInt64 = 0
    private var cleanupMutationGeneration: UInt64 = 0
    private var cleanupPolicyRequestTask: Task<Void, Never>?
    private var cleanupClearRequestTask: Task<Void, Never>?
    private var pendingPolicyConfirmation: ClipboardPolicyConfirmationToken?
    private var isApplyingHistoryReadSnapshot = false
    private var dispatchPluginEvent: @MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult = { .allowed($0) }

    var cleanupMutationInProgress: Bool {
        cleanupMutationState != .committed
    }

    init(
        repository: ClipboardRepository?,
        ocrQueue: ClipboardVisionOCRQueue? = nil,
        ocrCoordinator: LocalOCRCoordinator? = nil,
        ocrService: LocalVisionOCRService? = nil,
        cleanupPolicyDebounce: Duration = .milliseconds(250),
        cleanupMutationPipelineHooks: ClipboardCleanupMutationPipelineHooks = ClipboardCleanupMutationPipelineHooks(),
        capturePersistencePipelineHooks: ClipboardCapturePersistencePipelineHooks = ClipboardCapturePersistencePipelineHooks(),
        recordMutationPipelineHooks: ClipboardRecordMutationPipelineHooks = ClipboardRecordMutationPipelineHooks()
    ) {
        let repositoryMutationQueue = ClipboardRepositoryMutationQueue()
        let recordActionValidity = ClipboardRecordActionValidity()
        let recordCommitGate = ClipboardRecordCommitGate()
        self.repository = repository
        self.recordActionValidity = recordActionValidity
        self.recordCommitGate = recordCommitGate
        self.historyReadPipeline = ClipboardHistoryReadPipeline(repository: repository)
        self.recordActionPipeline = ClipboardRecordActionPipeline(repository: repository)
        self.recordMutationPipeline = ClipboardRecordMutationPipeline(
            repository: repository,
            mutationQueue: repositoryMutationQueue,
            hooks: recordMutationPipelineHooks,
            recordActionValidity: recordActionValidity,
            commitGate: recordCommitGate
        )
        self.capturePersistencePipeline = ClipboardCapturePersistencePipeline(
            repository: repository,
            mutationQueue: repositoryMutationQueue,
            hooks: capturePersistencePipelineHooks,
            recordActionValidity: recordActionValidity,
            commitGate: recordCommitGate
        )
        self.cleanupMutationPipeline = ClipboardCleanupMutationPipeline(
            repository: repository,
            hooks: cleanupMutationPipelineHooks,
            mutationQueue: repositoryMutationQueue,
            recordActionValidity: recordActionValidity,
            commitGate: recordCommitGate
        )
        self.cleanupPolicyDebounce = cleanupPolicyDebounce
        self.tagStore = ClipboardTagStore(
            repository: repository,
            mutationExecutor: repositoryMutationQueue
        )
        self.detailStore = ClipboardDetailStore(
            repository: repository,
            mutationExecutor: repositoryMutationQueue,
            recordCommitGate: recordCommitGate,
            onCommittedDeletion: { deletedRecordIDs in
                recordActionValidity.invalidate(recordIDs: deletedRecordIDs)
            }
        )
        let resolvedOCRQueue: ClipboardVisionOCRQueue?
        if let ocrQueue {
            resolvedOCRQueue = ocrQueue
        } else if let repository {
            resolvedOCRQueue = ClipboardVisionOCRQueue(
                repository: repository,
                ocrCoordinator: ocrCoordinator
                    ?? LocalOCRCoordinator(service: ocrService ?? LocalVisionOCRService())
            )
        } else {
            resolvedOCRQueue = nil
        }
        repositoryUnavailable = repository == nil
        pendingAttachmentCleanupCount = (try? repository?.pendingSidecarCleanupCount()) ?? 0
        detailStore.configure { [weak self] result in
            guard let self else {
                return
            }
            self.invalidateCaches(for: result.recordID)
            self.refreshSearchResult(query: self.activeSearchQuery, limit: self.activeSearchLimit)
            await self.dispatchRecordUpdated(
                recordID: result.recordID,
                operation: "content_updated",
                contentRevision: result.newContentRevision
            )
        }
        tagStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        tagStore.objectWillChange
            .sink { [weak self] _ in
                guard let self, !self.isApplyingHistoryReadSnapshot else { return }
                self.scheduleTagSearchRefresh()
            }
            .store(in: &cancellables)
        if let resolvedOCRQueue {
            ocrScheduler = ClipboardOCRScheduler(queue: resolvedOCRQueue) { [weak self] recordIDs in
                self?.refreshAfterOCRWork(recordIDs: recordIDs)
            }
        }
        scheduleIndexMaintenance()
    }

    func configurePluginEventDispatcher(
        _ dispatcher: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult
    ) {
        dispatchPluginEvent = dispatcher
    }

    deinit {
        ocrScheduler?.requestShutdown()
        pendingTagSearchRefresh?.cancel()
        historyReadTask?.cancel()
        cleanupPolicyRequestTask?.cancel()
        cleanupClearRequestTask?.cancel()
        imagePreviewTasks.values.forEach { $0.cancel() }
    }

    func refreshRepositoryStateAfterExternalCommit() {
        refreshPendingAttachmentCleanupCount()
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
        ocrScheduler?.schedule(context: .screenshotHistory, quietDelay: 1.5)
    }

    private func refreshPendingAttachmentCleanupCount() {
        guard let repository else {
            pendingAttachmentCleanupCount = 0
            return
        }
        pendingAttachmentCleanupCount = (try? repository.pendingSidecarCleanupCount()) ?? pendingAttachmentCleanupCount
    }

    @discardableResult
    func loadRepositoryState(limit: Int) -> Bool {
        guard repository != nil else {
            repositoryUnavailable = true
            previewSnapshots = [:]
            recordActionValidity.invalidateAll()
            publishSearchResult(ClipboardSearchResultSet(
                query: activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                records: [],
                state: activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .failed,
                indexActivity: ClipboardSearchIndexActivity()
            ))
            return false
        }
        let safeLimit = max(1, limit)
        lastLoadLimit = safeLimit
        refreshSearchResult(
            query: activeSearchQuery,
            limit: activeSearchLimit ?? safeLimit
        )
        return true
    }

    var canLoadMoreHistory: Bool {
        repository != nil && !repositoryHistoryExhausted
    }

    func restorableCount() -> Int {
        ClipboardController.restorableCount(in: records)
    }

    func excludedCount() -> Int {
        ClipboardController.excludedCount(in: records)
    }

    func repositoryStateSummary() -> ClipboardRepositoryStateSummary {
        if repositoryUnavailable {
            return .unavailable()
        }
        if records.isEmpty {
            return .empty()
        }
        return .normal(recordCount: records.count)
    }

    func activeFilterCount() -> Int {
        ClipboardController.activeFilterCount(effectiveFilterState)
    }

    var hasActiveFilters: Bool {
        effectiveFilterState.hasActiveFilters
    }

    func sourceFilterOptions() -> [ClipboardSourceFilterOption] {
        ClipboardController.sourceFilterOptions(from: records)
    }

    func preview(for record: ClipboardRecorderRecord) -> ClipboardRecordPreview {
        if let snapshot = previewSnapshots[record.id] {
            return ClipboardRecordPreview(
                title: displayTitle(for: record),
                body: displayBody(for: record, snapshotBody: snapshot.body),
                badge: record.kind.localizedTitle,
                image: previewImage(for: record)
            )
        }
        return boundedFallbackPreview(for: record)
    }

    func ocrState(for record: ClipboardRecorderRecord) -> ClipboardOCRState {
        previewSnapshots[record.id]?.ocrState ?? .notRequired
    }

    func resolveRecord(recordID: String) -> ClipboardRecorderRecord? {
        if let loaded = records.first(where: { $0.id == recordID }) {
            return loaded
        }
        if let searchRecord = currentSearchResult.records.first(where: { $0.id == recordID }) {
            return searchRecord
        }
        guard let repository else {
            return nil
        }
        do {
            let record = try repository.loadRecord(recordID: recordID)
            repositoryUnavailable = false
            return record
        } catch {
            repositoryUnavailable = true
            Self.orderingLogger.error(
                "stage=record-resolve-failed record=\(recordID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func recordActionLease(recordID: String) -> ClipboardRecordActionLease? {
        // Register before resolving. If a destructive repository mutation is
        // already in flight, its committed deletion invalidates this token;
        // if it already finished, the lookup fails and the temporary token is
        // removed. This closes the resolve-then-register race without keeping
        // a permanent tombstone for every deleted record.
        let lease = recordActionValidity.lease(recordID: recordID)
        let recordExists: Bool
        if let repository {
            do {
                recordExists = try repository.loadRecord(recordID: recordID) != nil
                repositoryUnavailable = false
            } catch {
                repositoryUnavailable = true
                recordExists = false
            }
        } else {
            recordExists = records.contains { $0.id == recordID }
                || currentSearchResult.records.contains { $0.id == recordID }
        }
        guard recordExists else {
            recordActionValidity.finish(lease)
            return nil
        }
        return lease
    }

    func isCurrentRecordActionLease(
        _ lease: ClipboardRecordActionLease
    ) -> Bool {
        recordActionValidity.isCurrent(lease)
    }

    func finishRecordActionLease(_ lease: ClipboardRecordActionLease) {
        recordActionValidity.finish(lease)
    }

    func committedDeletionHandler() -> @Sendable ([String]) -> Void {
        { [recordActionValidity] deletedRecordIDs in
            recordActionValidity.invalidate(recordIDs: deletedRecordIDs)
        }
    }

    func readPayload(recordID: String, purpose: ClipboardPayloadReadPurpose) -> ClipboardPayloadReadResult {
        guard let record = resolveRecord(recordID: recordID) else {
            return .failure(recordID: recordID, purpose: purpose, failure: .recordNotFound)
        }
        guard record.restorable else {
            return .failure(recordID: recordID, purpose: purpose, failure: .recordNotRestorable)
        }
        let cacheKey = ClipboardPayloadCacheKey(recordID: recordID, purpose: purpose)
        if let cachedPayload = payloadCache[cacheKey] {
            return .success(recordID: recordID, purpose: purpose, payload: cachedPayload)
        }
        guard let repository else {
            return .failure(recordID: recordID, purpose: purpose, failure: .repositoryUnavailable)
        }
        do {
            guard let payload = try repository.readPayload(recordID: recordID) else {
                return .failure(recordID: recordID, purpose: purpose, failure: .payloadUnavailable)
            }
            payloadCache[cacheKey] = payload
            return .success(recordID: recordID, purpose: purpose, payload: payload)
        } catch {
            repositoryUnavailable = true
            return .failure(recordID: recordID, purpose: purpose, failure: .repositoryUnavailable)
        }
    }

    func readPayloadForAction(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose
    ) async -> ClipboardPayloadReadResult {
        let cacheKey = ClipboardPayloadCacheKey(recordID: recordID, purpose: purpose)
        if let cachedPayload = payloadCache[cacheKey] {
            return .success(recordID: recordID, purpose: purpose, payload: cachedPayload)
        }
        if let loadedRecord = records.first(where: { $0.id == recordID })
            ?? currentSearchResult.records.first(where: { $0.id == recordID }),
           !loadedRecord.restorable {
            return .failure(
                recordID: recordID,
                purpose: purpose,
                failure: .recordNotRestorable
            )
        }

        let result = await recordActionPipeline.read(recordID: recordID)
        guard !Task.isCancelled else {
            return .failure(
                recordID: recordID,
                purpose: purpose,
                failure: .payloadUnavailable
            )
        }
        guard let payload = result.payload, result.failure == nil else {
            repositoryUnavailable = result.failure == .repositoryUnavailable
            return .failure(
                recordID: recordID,
                purpose: purpose,
                failure: result.failure ?? .payloadUnavailable
            )
        }
        repositoryUnavailable = false
        payloadCache[cacheKey] = payload
        return .success(recordID: recordID, purpose: purpose, payload: payload)
    }

    func readTextForAction(
        recordID: String,
        purpose: ClipboardPayloadReadPurpose,
        maximumCharacterCount: Int
    ) async -> ClipboardTextReadResult {
        if let loadedRecord = records.first(where: { $0.id == recordID })
            ?? currentSearchResult.records.first(where: { $0.id == recordID }),
           !loadedRecord.restorable {
            return .failure(
                recordID: recordID,
                purpose: purpose,
                failure: .recordNotRestorable
            )
        }

        let result = await recordActionPipeline.readText(
            recordID: recordID,
            purpose: purpose,
            maximumCharacterCount: maximumCharacterCount
        )
        guard !Task.isCancelled else {
            return .failure(
                recordID: recordID,
                purpose: purpose,
                failure: .payloadUnavailable
            )
        }
        repositoryUnavailable = result.failure == .repositoryUnavailable
        return result
    }

    func readDetailPreview(recordID: String) async -> ClipboardDetailPreviewRead {
        await recordActionPipeline.readDetailPreview(recordID: recordID)
    }

    func replacePayloadCacheForFixtures(_ payloads: [String: ClipboardRecorderPayload]) {
        payloadCache = Dictionary(
            uniqueKeysWithValues: payloads.flatMap { recordID, payload in
                ClipboardPayloadReadPurpose.allCases.map { purpose in
                    (ClipboardPayloadCacheKey(recordID: recordID, purpose: purpose), payload)
                }
            }
        )
    }

    func payloadCacheSnapshotForFixtures() -> [String: ClipboardRecorderPayload] {
        Dictionary(
            uniqueKeysWithValues: payloadCache.compactMap { key, payload in
                key.purpose == .paste ? (key.recordID, payload) : nil
            }
        )
    }

    func refreshSearchResult(query: String, limit: Int? = nil) {
        activeSearchQuery = query
        activeSearchLimit = limit
        historyReadGeneration &+= 1
        let generation = historyReadGeneration
        historyReadTask?.cancel()
        let request = ClipboardHistoryReadRequest(
            generation: generation,
            query: query,
            limit: max(1, limit ?? lastLoadLimit),
            filterState: effectiveFilterState,
            recordTags: tagStore.recordTags,
            fallbackRecords: records,
            repositoryWasUnavailable: repositoryUnavailable
        )
        let pipeline = historyReadPipeline
        historyReadTask = Task { @MainActor [weak self] in
            let snapshot = await pipeline.read(request)
            guard let self,
                  !Task.isCancelled,
                  snapshot.generation == self.historyReadGeneration else {
                return
            }
            self.applyHistoryReadSnapshot(snapshot)
        }
    }

    private func refreshSearchResultAndWait(
        query: String,
        limit: Int? = nil
    ) async {
        refreshSearchResult(query: query, limit: limit)
        while !Task.isCancelled {
            let generation = historyReadGeneration
            let task = historyReadTask
            await task?.value
            guard historyReadGeneration != generation else {
                return
            }
        }
    }

    /// Applies the same transactional edit path as the clipboard detail UI.
    /// Plugins may update only the custom title and the editable text payload;
    /// record identity, source metadata, timestamps and storage remain host
    /// managed.
    func updateRecordFromPlugin(
        recordID: String,
        customTitle: String?,
        text: String?,
        expectedContentRevision: Int64?,
        causationID: UUID? = nil
    ) async throws -> ClipboardDetailSaveResult {
        guard customTitle != nil || text != nil else {
            throw BlocksPluginRuntimeError.invalidHostOperation(
                "clipboard.record.update:empty"
            )
        }
        guard let expectedContentRevision, expectedContentRevision > 0 else {
            throw ClipboardDetailSaveFailure.revisionConflict
        }
        let result = try await recordMutationPipeline.updateRecordFromPlugin(
            recordID: recordID,
            customTitle: customTitle,
            text: text,
            expectedContentRevision: expectedContentRevision
        )
        invalidateCaches(for: recordID)
        await refreshSearchResultAndWait(
            query: activeSearchQuery,
            limit: activeSearchLimit
        )
        await detailStore.refreshAfterExternalUpdate(recordID: recordID)
        await dispatchRecordUpdated(
            recordID: recordID,
            operation: "content_updated",
            contentRevision: result.newContentRevision,
            causationID: causationID
        )
        return result
    }

    private func refreshActiveSearchResult() {
        pendingTagSearchRefresh?.cancel()
        pendingTagSearchRefresh = nil
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
    }

    private func scheduleTagSearchRefresh() {
        pendingTagSearchRefresh?.cancel()
        pendingTagSearchRefresh = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingTagSearchRefresh = nil
            self.refreshSearchResult(query: self.activeSearchQuery, limit: self.activeSearchLimit)
        }
    }

    private func publishSearchResult(_ result: ClipboardSearchResultSet) {
        searchRevision &+= 1
        currentSearchResult = result
    }

    private func applyHistoryReadSnapshot(_ snapshot: ClipboardHistoryReadSnapshot) {
        let signpostState = Self.performanceSignposter.beginInterval("SearchPublish")
        defer { Self.performanceSignposter.endInterval("SearchPublish", signpostState) }
        isApplyingHistoryReadSnapshot = true
        defer { isApplyingHistoryReadSnapshot = false }

        if let loadedRecords = snapshot.loadedRecords {
            records = loadedRecords
            lastLoadLimit = max(lastLoadLimit, activeSearchLimit ?? loadedRecords.count)
            repositoryHistoryExhausted = snapshot.repositoryHistoryExhausted
                ?? repositoryHistoryExhausted
        }
        previewSnapshots.merge(snapshot.previewSnapshots) { _, new in new }
        tagStore.applyReadSnapshot(
            tags: snapshot.tags,
            recordTags: snapshot.recordTags,
            recordIDs: snapshot.loadedRecords?.map(\.id) ?? snapshot.resultSet.records.map(\.id),
            replacesRecordTags: snapshot.loadedRecords != nil
        )
        repositoryUnavailable = snapshot.repositoryUnavailable
        publishSearchResult(snapshot.resultSet)
        pruneFilterAfterHistoryRead(snapshot)
        historyReadTask = nil
    }

    func retryOCR(recordID: String) {
        ocrScheduler?.retry(recordID: recordID)
    }

    func openDetailEditor(recordID: String) {
        detailStore.open(recordID: recordID)
    }

    func closeDetailEditor() {
        detailStore.close()
    }

    @discardableResult
    func ingestLiveCapture(
        _ snapshot: ClipboardLiveCaptureSnapshot,
        capturePolicy: ClipboardCapturePolicy,
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool
    ) -> Bool {
        logOrderingStage("capture-received", record: snapshot.record)
        let decision = capturePolicy.evaluate(record: snapshot.record, payload: snapshot.payload)
        guard let repository else {
            repositoryUnavailable = true
            return ingestLiveCaptureInMemory(
                decision,
                cleanupMode: cleanupMode,
                retentionPolicy: retentionPolicy,
                maxItems: maxItems,
                preserveFavorite: preserveFavorite
            )
        }
        do {
            let result = try repository.insert(
                record: snapshot.record,
                payload: snapshot.payload,
                capturePolicy: capturePolicy
            )
            repositoryUnavailable = false
            logOrderingStage(result.duplicate ? "capture-duplicate" : "capture-inserted", record: result.record)
            guard !result.duplicate else {
                return loadRepositoryState(limit: lastLoadLimit)
            }
            let policyResult = applyPolicy(
                cleanupMode: cleanupMode,
                retentionPolicy: retentionPolicy,
                maxItems: maxItems,
                preserveFavorite: preserveFavorite
            )
            guard case .success = policyResult else {
                return false
            }
            if snapshot.record.kind == .image {
                ocrScheduler?.schedule(context: .clipboardImage, quietDelay: 1.5)
            }
            return true
        } catch {
            repositoryUnavailable = true
            return ingestLiveCaptureInMemory(
                decision,
                cleanupMode: cleanupMode,
                retentionPolicy: retentionPolicy,
                maxItems: maxItems,
                preserveFavorite: preserveFavorite
            )
        }
    }

    @discardableResult
    func ingestLiveCaptureAsync(
        _ snapshot: ClipboardLiveCaptureSnapshot,
        capturePolicy: ClipboardCapturePolicy,
        captureDecision: ClipboardCapturePolicyDecision? = nil,
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        captureGeneration: ClipboardCaptureGeneration? = nil,
        captureGenerationValue: UInt64 = 0,
        privacyCaptureAdmissionToken: PrivacyCaptureAdmissionToken? = nil,
        publishCommittedEffects: @MainActor () -> Bool = { true },
        causationID: UUID? = nil
    ) async -> ClipboardLiveCaptureIngestResult {
        logOrderingStage("capture-received", record: snapshot.record)
        if let captureDecision, captureDecision.skipped {
            return .failed
        }
        let persistencePolicy: ClipboardCapturePolicy
        if captureDecision == nil {
            persistencePolicy = capturePolicy
        } else {
            // The coordinator already evaluated the captured policy snapshot
            // before exposing content to plugins. Preserve that authorization
            // through persistence instead of re-reading mutable privacy state.
            persistencePolicy = ClipboardCapturePolicy(
                supportedKinds: capturePolicy.supportedKinds
            )
        }
        guard repository != nil else {
            repositoryUnavailable = true
            let ingestInMemory = { () -> ClipboardLiveCaptureIngestResult in
                let duplicate = self.records.contains {
                    $0.signatureSHA256 == snapshot.record.signatureSHA256
                }
                let decision = captureDecision ?? capturePolicy.evaluate(
                    record: snapshot.record,
                    payload: snapshot.payload
                )
                let succeeded = self.ingestLiveCaptureInMemory(
                    decision,
                    cleanupMode: cleanupMode,
                    retentionPolicy: retentionPolicy,
                    maxItems: maxItems,
                    preserveFavorite: preserveFavorite
                )
                return ClipboardLiveCaptureIngestResult(
                    succeeded: succeeded,
                    durablyCommitted: false,
                    duplicate: duplicate,
                    record: self.records.first {
                        $0.signatureSHA256 == snapshot.record.signatureSHA256
                    },
                    invalidated: false
                )
            }
            guard let privacyCaptureAdmissionToken else {
                guard let captureGeneration else {
                    return ingestInMemory()
                }
                return captureGeneration.withCurrentAdmission(
                    captureGenerationValue,
                    ingestInMemory
                ) ?? .invalidated
            }
            // Keep all in-memory mutations inside the same privacy-admission
            // critical section as durable capture. This prevents a revoked
            // privacy token from publishing records, payloads, or search state
            // through the repository-unavailable fallback.
            guard let result = privacyCaptureAdmissionToken.withAuthorizedAdmission({
                guard let captureGeneration else {
                    return ingestInMemory()
                }
                return captureGeneration.withCurrentAdmission(
                    captureGenerationValue,
                    ingestInMemory
                ) ?? .invalidated
            }) else {
                return .invalidated
            }
            return result
        }

        let outcome = await capturePersistencePipeline.persist(
            snapshot: snapshot,
            capturePolicy: persistencePolicy,
            prunePolicy: ClipboardRepositoryPrunePolicy(
                retentionSeconds: cleanupMode == .time
                    ? retentionPolicy.retentionSeconds
                    : nil,
                maxItems: cleanupMode == .count ? max(1, maxItems) : nil,
                preserveFavorite: preserveFavorite
            ),
            captureGeneration: captureGeneration,
            captureGenerationValue: captureGenerationValue,
            privacyCaptureAdmissionToken: privacyCaptureAdmissionToken
        )
        guard !outcome.invalidated else {
            return .invalidated
        }
        guard let insertResult = outcome.insertResult, outcome.succeeded else {
            repositoryUnavailable = true
            Self.orderingLogger.error(
                "stage=capture-persist-failed record=\(snapshot.record.id, privacy: .public) error=\(outcome.errorDescription ?? "unknown", privacy: .public)"
            )
            return .failed
        }

        repositoryUnavailable = false
        guard publishCommittedEffects() else {
            // Privacy authorization can be revoked after the database
            // transaction linearizes but before this MainActor continuation.
            // Preserve the durable truth while suppressing late plugin, UI,
            // search, and OCR publication derived from the revoked capture.
            return ClipboardLiveCaptureIngestResult(
                succeeded: true,
                durablyCommitted: true,
                duplicate: insertResult.duplicate,
                record: insertResult.record,
                invalidated: false
            )
        }
        if let policyResult = outcome.policyResult {
            await dispatchRecordDeletions(
                recordIDs: policyResult.deletedRecordIDs,
                operation: "retention_policy",
                causationID: causationID
            )
        }
        logOrderingStage(
            insertResult.duplicate ? "capture-duplicate" : "capture-inserted",
            record: insertResult.record
        )
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
        if !insertResult.duplicate,
           !insertResult.skipped,
           insertResult.record.kind == .image {
            ocrScheduler?.schedule(context: .clipboardImage, quietDelay: 1.5)
        }
        return ClipboardLiveCaptureIngestResult(
            succeeded: true,
            durablyCommitted: true,
            duplicate: insertResult.duplicate,
            record: insertResult.record,
            invalidated: false
        )
    }

    private func logOrderingStage(_ stage: String, record: ClipboardRecorderRecord?) {
        guard let record else {
            Self.orderingLogger.debug("stage=\(stage, privacy: .public) result=empty")
            return
        }
        Self.orderingLogger.debug(
            "stage=\(stage, privacy: .public) record=\(String(record.id.suffix(8)), privacy: .public) kind=\(record.kind.rawValue, privacy: .public) changeCount=\(record.changeCount) createdAt=\(record.createdAt.timeIntervalSince1970) lastCopiedAt=\(record.lastCopiedAt.timeIntervalSince1970)"
        )
    }

    private func dispatchRecordUpdated(
        recordID: String,
        operation: String,
        contentRevision: Int64? = nil,
        causationID: UUID? = nil,
        payload additions: [String: JSONValue] = [:]
    ) async {
        guard repository != nil else { return }
        var payload = additions
        payload["record_id"] = .string(recordID)
        payload["operation"] = .string(operation)
        if let contentRevision {
            payload["content_revision"] = .int(Int(contentRevision))
        }
        _ = await dispatchPluginEvent(
            BlocksPluginEventEnvelope(
                name: .clipboardRecordUpdated,
                revision: contentRevision,
                causationID: causationID,
                payload: payload
            )
        )
    }

    private func dispatchRecordDeletions(
        recordIDs: [String],
        operation: String,
        causationID: UUID? = nil
    ) async {
        guard repository != nil, !recordIDs.isEmpty else { return }
        let resolvedCausationID = causationID ?? UUID()
        for recordID in recordIDs.sorted() {
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .clipboardRecordDeleted,
                    causationID: resolvedCausationID,
                    payload: [
                        "record_id": .string(recordID),
                        "operation": .string(operation),
                    ]
                )
            )
        }
    }

    func toggleFavorite(
        recordID: String,
        causationID: UUID? = nil,
        requiresPersistence: Bool = false
    ) async -> Bool? {
        if requiresPersistence, repository == nil {
            return nil
        }
        let isLoaded = records.contains { $0.id == recordID }
            || currentSearchResult.records.contains { $0.id == recordID }
        guard isLoaded || repository != nil else {
            return nil
        }
        guard favoriteMutationRecordIDs.insert(recordID).inserted else {
            return nil
        }
        defer { favoriteMutationRecordIDs.remove(recordID) }
        guard await tagStore.toggleFavorite(recordID: recordID) else { return nil }
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
        let isFavorite = tagStore.isFavorite(recordID: recordID)
        await dispatchRecordUpdated(
            recordID: recordID,
            operation: "favorite_changed",
            causationID: causationID,
            payload: ["is_favorite": .bool(isFavorite)]
        )
        return isFavorite
    }

    func setFavoriteFromPlugin(
        recordID: String,
        isFavorite: Bool,
        expectedContentRevision: Int64,
        causationID: UUID? = nil,
        requiresPersistence: Bool = false
    ) async throws -> Int64 {
        if requiresPersistence, repository == nil {
            throw ClipboardTagOperationError.repositoryUnavailable
        }
        let isLoaded = records.contains { $0.id == recordID }
            || currentSearchResult.records.contains { $0.id == recordID }
        guard isLoaded || repository != nil else {
            throw ClipboardTagMutationError.recordNotFound(recordID)
        }
        guard favoriteMutationRecordIDs.insert(recordID).inserted else {
            throw ClipboardTagMutationError.revisionConflict
        }
        defer { favoriteMutationRecordIDs.remove(recordID) }
        let contentRevision = try await tagStore.setFavoriteFromPlugin(
            recordID: recordID,
            isFavorite: isFavorite,
            expectedContentRevision: expectedContentRevision
        )
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
        await dispatchRecordUpdated(
            recordID: recordID,
            operation: "favorite_changed",
            causationID: causationID,
            payload: [
                "is_favorite": .bool(isFavorite),
                "content_revision": .int(Int(contentRevision)),
            ]
        )
        return contentRevision
    }

    func ensureTagAndAttachFromPlugin(
        recordID: String,
        displayName: String,
        requiresPersistence: Bool = false
    ) async throws -> ClipboardPluginEnsureTagAttachment {
        if requiresPersistence, repository == nil {
            throw ClipboardTagOperationError.repositoryUnavailable
        }
        let result = try await tagStore.ensureTagAndAttachFromPlugin(
            recordID: recordID,
            displayName: displayName
        )
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
        return result
    }

    func delete(
        recordID: String,
        causationID: UUID? = nil,
        requiresPersistence: Bool = false
    ) async -> Bool {
        if repository == nil {
            guard !requiresPersistence else { return false }
            guard resolveRecord(recordID: recordID) != nil else {
                return false
            }
            recordActionValidity.invalidate(recordIDs: [recordID])
            records.removeAll { $0.id == recordID }
            payloadCache = payloadCache.filter { $0.key.recordID != recordID }
            previewSnapshots.removeValue(forKey: recordID)
            tagStore.load(recordIDs: records.map(\.id))
            refreshActiveSearchResult()
            return true
        }

        switch await recordMutationPipeline.delete(recordID: recordID) {
        case .deleted:
            repositoryUnavailable = false
            refreshPendingAttachmentCleanupCount()
            removeRecordFromPublishedState(recordID: recordID)
            refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
            await dispatchRecordDeletions(
                recordIDs: [recordID],
                operation: "deleted",
                causationID: causationID
            )
            return true
        case .notFound:
            return false
        case .revisionConflict:
            return false
        case .failure:
            repositoryUnavailable = true
            return false
        case .copied:
            assertionFailure("Unexpected copy outcome for delete mutation")
            return false
        }
    }

    func deleteRecordFromPlugin(
        recordID: String,
        expectedContentRevision: Int64,
        causationID: UUID? = nil,
        requiresPersistence: Bool = false
    ) async throws -> Bool {
        guard expectedContentRevision > 0 else {
            throw ClipboardDetailSaveFailure.revisionConflict
        }
        guard repository != nil else {
            if requiresPersistence {
                return false
            }
            throw ClipboardDetailSaveFailure.revisionConflict
        }
        switch await recordMutationPipeline.delete(
            recordID: recordID,
            expectedContentRevision: expectedContentRevision
        ) {
        case .deleted:
            repositoryUnavailable = false
            refreshPendingAttachmentCleanupCount()
            removeRecordFromPublishedState(recordID: recordID)
            refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
            await dispatchRecordDeletions(
                recordIDs: [recordID],
                operation: "deleted",
                causationID: causationID
            )
            return true
        case .notFound:
            return false
        case .revisionConflict:
            throw ClipboardDetailSaveFailure.revisionConflict
        case .failure:
            repositoryUnavailable = true
            return false
        case .copied:
            assertionFailure("Unexpected copy outcome for delete mutation")
            return false
        }
    }

    private func removeRecordFromPublishedState(recordID: String) {
        records.removeAll { $0.id == recordID }
        invalidateCaches(for: recordID)
        tagStore.removeRecordFromPublishedSnapshot(recordID: recordID)

        let remaining = currentSearchResult.records.filter { $0.id != recordID }
        let state: ClipboardSearchResultState
        if currentSearchResult.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .idle
        } else if remaining.isEmpty {
            state = currentSearchResult.indexActivity.hasPendingWork ? .emptyIndexing : .empty
        } else {
            state = currentSearchResult.indexActivity.hasPendingWork ? .partialIndexing : .results
        }
        publishSearchResult(ClipboardSearchResultSet(
            query: currentSearchResult.query,
            records: remaining,
            state: state,
            indexActivity: currentSearchResult.indexActivity
        ))
    }

    func commitCopyEvent(
        recordID: String,
        source: ClipboardCopyEventSource,
        at requestedDate: Date = Date(),
        causationID: UUID? = nil,
        shouldPublishPluginEvent: @MainActor () -> Bool = { true }
    ) async -> ClipboardRecordRecencyUpdate {
        let signpostState = Self.performanceSignposter.beginInterval("RecencyPromotion")
        defer { Self.performanceSignposter.endInterval("RecencyPromotion", signpostState) }
        let currentRecord = records.first(where: { $0.id == recordID })
            ?? currentSearchResult.records.first(where: { $0.id == recordID })
        guard currentRecord != nil || repository != nil else {
            Self.orderingLogger.error(
                "stage=copy-event-not-found source=\(source.rawValue, privacy: .public) record=\(recordID, privacy: .public)"
            )
            return .notFound
        }
        let inMemoryMaximum = (records + currentSearchResult.records)
            .map(\.lastCopiedAt.timeIntervalSince1970)
            .max() ?? 0
        let requestedTimestamp = requestedDate.timeIntervalSince1970
        var promotionDate = Date(
            timeIntervalSince1970: requestedTimestamp > inMemoryMaximum
                ? requestedTimestamp
                : inMemoryMaximum + 0.000_001
        )
        Self.orderingLogger.info(
            "stage=copy-event-start source=\(source.rawValue, privacy: .public) record=\(recordID, privacy: .public) kind=\(currentRecord?.kind.rawValue ?? "unloaded", privacy: .public) changeCount=\(currentRecord?.changeCount ?? -1) requestedAt=\(requestedTimestamp)"
        )
        var persisted = false
        if repository != nil {
            switch await recordMutationPipeline.markCopied(
                recordID: recordID,
                at: promotionDate
            ) {
            case let .copied(committedDate):
                promotionDate = committedDate
                repositoryUnavailable = false
                persisted = true
            case .notFound:
                Self.orderingLogger.error(
                    "stage=copy-event-not-found source=\(source.rawValue, privacy: .public) record=\(recordID, privacy: .public)"
                )
                return .notFound
            case .revisionConflict:
                assertionFailure("Unexpected revision conflict for copy mutation")
                return .notFound
            case .failure:
                repositoryUnavailable = true
                Self.orderingLogger.error(
                    "stage=copy-event-persist-failed source=\(source.rawValue, privacy: .public) record=\(recordID, privacy: .public)"
                )
                return ClipboardRecordRecencyUpdate(
                    recordFound: true,
                    persisted: false,
                    promotedAt: nil
                )
            case .deleted:
                assertionFailure("Unexpected delete outcome for copy mutation")
            }
        }
        let recordForPublication = records.first(where: { $0.id == recordID })
            ?? currentSearchResult.records.first(where: { $0.id == recordID })
        if let recordForPublication,
           promotionDate >= recordForPublication.lastCopiedAt {
            let promotedRecord = recordForPublication.replacing(lastCopiedAt: promotionDate)
            if let recordIndex = records.firstIndex(where: { $0.id == recordID }) {
                records[recordIndex] = promotedRecord
            } else {
                records.append(promotedRecord)
            }
            records.sort { ClipboardRecordOrdering.isMoreRecent($0, than: $1) }
            if records.count > lastLoadLimit {
                records.removeLast(records.count - lastLoadLimit)
            }
            updateActiveSearchResultAfterPromotion(promotedRecord)
        } else if persisted {
            // A committed copy must be visible before this method reports
            // success. Newly inserted translation/OCR copies are not present
            // in the previous in-memory snapshot yet.
            await refreshSearchResultAndWait(
                query: activeSearchQuery,
                limit: activeSearchLimit
            )
        }
        Self.orderingLogger.info(
            "stage=copy-event-finished source=\(source.rawValue, privacy: .public) record=\(recordID, privacy: .public) promotedAt=\(promotionDate.timeIntervalSince1970) persisted=\(persisted) first=\(self.records.first?.id ?? "none", privacy: .public)"
        )
        if persisted, shouldPublishPluginEvent() {
            await dispatchRecordUpdated(
                recordID: recordID,
                operation: source == .plugin
                    ? "bring_to_front"
                    : "recency_promoted",
                causationID: causationID,
                payload: [
                    "last_copied_at": .double(
                        promotionDate.timeIntervalSince1970
                    ),
                    "source": .string(source.rawValue),
                ]
            )
        }
        return ClipboardRecordRecencyUpdate(
            recordFound: true,
            persisted: persisted,
            promotedAt: promotionDate
        )
    }

    private func updateActiveSearchResultAfterPromotion(_ promotedRecord: ClipboardRecorderRecord) {
        let trimmedQuery = currentSearchResult.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = trimmedQuery.isEmpty ? records : currentSearchResult.records
        if let index = candidates.firstIndex(where: { $0.id == promotedRecord.id }) {
            candidates[index] = promotedRecord
        } else if trimmedQuery.isEmpty {
            candidates.append(promotedRecord)
        }
        let filtered = ClipboardSearchCoordinator.applyFilters(
            candidates,
            filterState: effectiveFilterState,
            recordTags: tagStore.recordTags
        )
        let limited = Array(filtered.prefix(activeSearchLimit ?? lastLoadLimit))
        let state: ClipboardSearchResultState
        if trimmedQuery.isEmpty {
            state = .idle
        } else if limited.isEmpty {
            state = currentSearchResult.indexActivity.hasPendingWork ? .emptyIndexing : .empty
        } else {
            state = currentSearchResult.indexActivity.hasPendingWork ? .partialIndexing : .results
        }
        publishSearchResult(ClipboardSearchResultSet(
            query: trimmedQuery,
            records: limited,
            state: state,
            indexActivity: currentSearchResult.indexActivity
        ))
    }

    @discardableResult
    func applyPolicy(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool
    ) -> ClipboardPolicyApplyResult {
        let maxItemCount = max(1, maxItems)
        let retentionSeconds = cleanupMode == .time ? retentionPolicy.retentionSeconds : nil
        let itemLimit = cleanupMode == .count ? maxItemCount : nil
        if let repository {
            do {
                let result = try repository.applyPolicy(
                    ClipboardRepositoryPrunePolicy(
                        retentionSeconds: retentionSeconds,
                        maxItems: itemLimit,
                        preserveFavorite: preserveFavorite
                    ),
                    onCommittedDeletion: { [recordActionValidity] deletedRecordIDs in
                        recordActionValidity.invalidate(
                            recordIDs: deletedRecordIDs
                        )
                    }
                )
                guard loadRepositoryState(limit: lastLoadLimit) else {
                    return .failure
                }
                return .success(redactedCount: result.redactedCount)
            } catch {
                repositoryUnavailable = true
                return .failure
            }
        }

        let previousRecordIDs = Set(records.map(\.id))
        let ageFiltered = records.filter { record in
            if preserveFavorite, tagStore.isFavorite(recordID: record.id) {
                return true
            }
            guard let retentionSeconds else {
                return true
            }
            return record.lastCopiedAt >= Date().addingTimeInterval(-TimeInterval(retentionSeconds))
        }
        let sorted = ageFiltered.sorted { ClipboardRecordOrdering.isMoreRecent($0, than: $1) }
        if let itemLimit, preserveFavorite {
            let favorites = sorted.filter { tagStore.isFavorite(recordID: $0.id) }
            let ordinaryLimit = max(0, itemLimit - favorites.count)
            let ordinary = sorted.filter { !tagStore.isFavorite(recordID: $0.id) }.prefix(ordinaryLimit)
            records = (favorites + ordinary).sorted { ClipboardRecordOrdering.isMoreRecent($0, than: $1) }
        } else if let itemLimit {
            records = Array(sorted.prefix(itemLimit))
        } else {
            records = sorted
        }
        recordActionValidity.invalidate(
            recordIDs: previousRecordIDs.subtracting(records.map(\.id))
        )
        tagStore.load(recordIDs: records.map(\.id))
        prunePayloadsToCurrentRecords()
        prunePreviewSnapshotsToCurrentRecords()
        refreshActiveSearchResult()
        return .success(redactedCount: 0)
    }

    func clearUnfavorited() -> (deletedCount: Int, remainingCount: Int)? {
        let previousCount = records.count
        if let repository {
            do {
                let result = try repository.clearUnfavorited(
                    onCommittedDeletion: { [recordActionValidity] deletedRecordIDs in
                        recordActionValidity.invalidate(
                            recordIDs: deletedRecordIDs
                        )
                    }
                )
                guard loadRepositoryState(limit: lastLoadLimit) else {
                    return nil
                }
                return (result.deletedCount, result.remainingCount)
            } catch {
                repositoryUnavailable = true
                return nil
            }
        } else {
            let retainedIDs = Set(records.filter { tagStore.isFavorite(recordID: $0.id) }.map(\.id))
            recordActionValidity.invalidate(
                recordIDs: Set(records.map(\.id)).subtracting(retainedIDs)
            )
            records.removeAll { !tagStore.isFavorite(recordID: $0.id) }
            payloadCache = payloadCache.filter { retainedIDs.contains($0.key.recordID) }
            tagStore.load(recordIDs: records.map(\.id))
            refreshActiveSearchResult()
        }
        return (previousCount - records.count, records.count)
    }

    /// Previews a settings-policy deletion on the same gate and mutation queue
    /// used for capture and clear. No defaults or repository rows are changed.
    @discardableResult
    func requestPolicyPreview(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) -> Bool {
        guard repository != nil, cleanupMutationState == .committed else {
            completion(.rejectedWhileBusy)
            return false
        }
        let policy = ClipboardRepositoryPrunePolicy(
            retentionSeconds: cleanupMode == .time ? retentionPolicy.retentionSeconds : nil,
            maxItems: cleanupMode == .count ? max(1, maxItems) : nil,
            preserveFavorite: preserveFavorite
        )
        cleanupMutationState = .previewing
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.cleanupMutationPipeline.previewPolicy(policy) {
            case let .success(plan):
                guard self.cleanupMutationState == .previewing else { return }
                let token = ClipboardPolicyConfirmationToken(
                    repositoryPlanToken: plan.token,
                    cleanupMode: cleanupMode,
                    retentionPolicy: retentionPolicy,
                    maxItems: maxItems,
                    preserveFavorite: preserveFavorite
                )
                self.pendingPolicyConfirmation = token
                if plan.deleteCount == 0 {
                    self.confirmPolicyApplication(token: token, completion: completion)
                } else {
                    self.cleanupMutationState = .awaitingConfirmation
                    completion(.preview(deleteCount: plan.deleteCount, token: token))
                }
            case .failure:
                self.pendingPolicyConfirmation = nil
                self.cleanupMutationState = .committed
                completion(.failed)
            }
        }
        return true
    }

    func cancelPolicyPreview() {
        guard cleanupMutationState == .previewing || cleanupMutationState == .awaitingConfirmation else { return }
        pendingPolicyConfirmation = nil
        cleanupMutationState = .committed
    }

    func confirmPolicyApplication(
        token: ClipboardPolicyConfirmationToken,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) {
        guard cleanupMutationState == .awaitingConfirmation || cleanupMutationState == .previewing,
              let pending = pendingPolicyConfirmation,
              pending == token else {
            completion(.rejectedWhileBusy)
            return
        }
        cleanupMutationState = .applying
        let visibleLimit = max(1, activeSearchLimit ?? lastLoadLimit)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.cleanupMutationPipeline.applyConfirmedPolicy(
                pending.makeRepositoryPolicy(),
                token: pending.repositoryPlanToken,
                visibleLimit: visibleLimit
            )
            switch outcome {
            case let .policy(result, visibleRecordCount, postMutationFailure):
                self.pendingPolicyConfirmation = nil
                self.cleanupMutationState = .committed
                self.repositoryUnavailable = postMutationFailure == .repository
                self.refreshPendingAttachmentCleanupCount()
                await self.dispatchRecordDeletions(
                    recordIDs: result.deletedRecordIDs,
                    operation: "retention_policy",
                    causationID: UUID()
                )
                self.refreshSearchResult(query: self.activeSearchQuery, limit: self.activeSearchLimit)
                completion(.committed(visibleRecordCount: visibleRecordCount))
            case let .stale(plan):
                let staleToken = pending.replacingRepositoryPlanToken(plan.token)
                self.pendingPolicyConfirmation = staleToken
                self.cleanupMutationState = .awaitingConfirmation
                completion(.stale(deleteCount: plan.deleteCount, token: staleToken))
            case .clear, .failure:
                self.pendingPolicyConfirmation = nil
                self.cleanupMutationState = .committed
                completion(.failed)
            }
        }
    }

    /// Coalesces policy changes that have not started yet and reports the
    /// database outcome for the policy that actually ran. Once a destructive
    /// mutation starts, later settings changes are rejected until it finishes
    /// so an earlier deletion cannot be hidden by a newer completion.
    #if DEBUG
    @discardableResult
    func requestPolicyApplication(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (ClipboardPolicyApplyResult, Int?) -> Void
    ) -> Bool {
        guard repository != nil else {
            completion(applyPolicy(
                cleanupMode: cleanupMode,
                retentionPolicy: retentionPolicy,
                maxItems: maxItems,
                preserveFavorite: preserveFavorite
            ), records.count)
            return true
        }

        // DEBUG-only fixture path keeps its historical debounce/coalescing
        // contract. A real confirmation preview also uses `.previewing`, but
        // never owns `cleanupPolicyRequestTask`, so it cannot be bypassed here.
        guard cleanupMutationState == .committed
                || (cleanupMutationState == .previewing && cleanupPolicyRequestTask != nil) else {
            return false
        }

        cleanupPolicyRequestTask?.cancel()
        cleanupMutationGeneration &+= 1
        let generation = cleanupMutationGeneration
        let policy = ClipboardRepositoryPrunePolicy(
            retentionSeconds: cleanupMode == .time ? retentionPolicy.retentionSeconds : nil,
            maxItems: cleanupMode == .count ? max(1, maxItems) : nil,
            preserveFavorite: preserveFavorite
        )
        let visibleLimit = max(1, activeSearchLimit ?? lastLoadLimit)
        let pipeline = cleanupMutationPipeline
        let debounce = cleanupPolicyDebounce
        let causationID = UUID()
        cleanupMutationState = .policyPending
        cleanupPolicyRequestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self,
                  generation == self.cleanupMutationGeneration,
                  !Task.isCancelled else {
                return
            }
            self.cleanupMutationState = .active
            defer {
                if generation == self.cleanupMutationGeneration {
                    self.cleanupMutationState = .idle
                    self.cleanupPolicyRequestTask = nil
                }
            }
            let outcome = await pipeline.applyPolicy(policy, visibleLimit: visibleLimit)
            if case let .policy(result, _, _) = outcome {
                await self.dispatchRecordDeletions(
                    recordIDs: result.deletedRecordIDs,
                    operation: "retention_policy",
                    causationID: causationID
                )
            }
            guard generation == self.cleanupMutationGeneration else { return }
            guard case let .policy(result, visibleRecordCount, postMutationFailure) = outcome else {
                if case .failure(.repository) = outcome {
                    self.repositoryUnavailable = true
                }
                completion(.failure, nil)
                return
            }
            if postMutationFailure == .repository {
                self.repositoryUnavailable = true
            } else {
                self.repositoryUnavailable = false
            }
            completion(.success(redactedCount: result.redactedCount), visibleRecordCount)
            self.refreshSearchResult(
                query: self.activeSearchQuery,
                limit: self.activeSearchLimit
            )
        }
        return true
    }
    #endif

    /// Rejects an unfavorited-record deletion while any policy change is
    /// pending or active. Its completion reports the write result, not the
    /// cancellable follow-up history read.
    func requestClearUnfavorited(
        completion: @escaping @MainActor (ClipboardClearUnfavoritedResult) -> Void
    ) {
        guard repository != nil else {
            if let result = clearUnfavorited() {
                completion(.success(deletedCount: result.deletedCount, remainingCount: result.remainingCount))
            } else {
                completion(.failure(.repository))
            }
            return
        }

        guard cleanupMutationState == .idle else {
            completion(.rejectedWhileBusy)
            return
        }

        cleanupMutationGeneration &+= 1
        let generation = cleanupMutationGeneration
        let pipeline = cleanupMutationPipeline
        let causationID = UUID()
        cleanupMutationState = .active
        cleanupClearRequestTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   generation == self.cleanupMutationGeneration {
                    self.cleanupMutationState = .idle
                    self.cleanupClearRequestTask = nil
                }
            }
            let outcome = await pipeline.clearUnfavorited()
            guard let self else { return }
            if case let .clear(result) = outcome {
                await self.dispatchRecordDeletions(
                    recordIDs: result.deletedRecordIDs,
                    operation: "clear_unfavorited",
                    causationID: causationID
                )
            }
            guard generation == self.cleanupMutationGeneration else { return }
            guard case let .clear(result) = outcome else {
                if case .failure(.repository) = outcome {
                    self.repositoryUnavailable = true
                }
                if case let .failure(failure) = outcome {
                    completion(.failure(failure))
                } else {
                    completion(.failure(.repository))
                }
                return
            }
            completion(.success(deletedCount: result.deletedCount, remainingCount: result.remainingCount))
            self.repositoryUnavailable = false
            self.refreshPendingAttachmentCleanupCount()
            self.refreshSearchResult(
                query: self.activeSearchQuery,
                limit: self.activeSearchLimit
            )
        }
    }

    /// Live capture waits for a user-requested cleanup to settle before it
    /// snapshots the persisted policy. Repository writes are also serialized,
    /// covering a capture that was already submitted when the setting changed.
    func waitForCleanupMutationToSettle() async {
        while !Task.isCancelled {
            let generation = cleanupMutationGeneration
            let policyTask = cleanupPolicyRequestTask
            let clearTask = cleanupClearRequestTask

            guard policyTask != nil || clearTask != nil else {
                return
            }

            await policyTask?.value
            await clearTask?.value

            // A pending policy may be cancelled and replaced while awaiting
            // its task. Re-read the generation and task handles before a
            // capture is allowed to snapshot the committed cleanup policy.
            guard generation == cleanupMutationGeneration,
                  cleanupMutationState == .idle,
                  cleanupPolicyRequestTask == nil,
                  cleanupClearRequestTask == nil else {
                continue
            }
            return
        }
    }

    func clearFilters() {
        filterState.clear()
        tagStore.setSelectedTagID(nil)
        refreshActiveSearchResult()
    }

    func setFormatFilter(_ filter: ClipboardFormatFilter) {
        filterState.format = filter
        refreshActiveSearchResult()
    }

    func setTimeFilter(_ filter: ClipboardTimeFilter) {
        filterState.time = filter
        refreshActiveSearchResult()
    }

    func setTagFilter(_ tagID: String?) {
        tagStore.setSelectedTagID(tagID)
        refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
    }

    func setSourceFilter(_ sourceFilterKey: ClipboardSourceFilterKey?) {
        filterState.sourceFilterKey = sourceFilterKey
        refreshActiveSearchResult()
    }

    func prunePayloadsToCurrentRecords() {
        let recordIDs = Set(records.map(\.id))
        payloadCache = payloadCache.filter { recordIDs.contains($0.key.recordID) }
    }

    private func pruneImagePreviewCachesToVisibleRecords() {
        let recordIDs = Set(
            records.map(\.id) + currentSearchResult.records.map(\.id)
        )
        imagePreviewCache = imagePreviewCache.filter { recordIDs.contains($0.key) }
        imagePreviewFailures = imagePreviewFailures.filter { recordIDs.contains($0) }
        for recordID in Array(imagePreviewTasks.keys) where !recordIDs.contains(recordID) {
            imagePreviewTasks.removeValue(forKey: recordID)?.cancel()
        }
    }

    private func ingestLiveCaptureInMemory(
        _ decision: ClipboardCapturePolicyDecision,
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool
    ) -> Bool {
        var cachedPayloadsByRecordID = payloadCacheSnapshotForFixtures()
        let inserted = ClipboardController.ingestLiveCapture(
            decision,
            records: &records,
            payloads: &cachedPayloadsByRecordID
        )
        guard inserted else {
            return false
        }
        replacePayloadCacheForFixtures(cachedPayloadsByRecordID)
        _ = applyPolicy(
            cleanupMode: cleanupMode,
            retentionPolicy: retentionPolicy,
            maxItems: maxItems,
            preserveFavorite: preserveFavorite
        )
        return true
    }

    private func pruneFilterAfterHistoryRead(_ snapshot: ClipboardHistoryReadSnapshot) {
        if let selectedTagID = tagStore.selectedTagID,
           !tagStore.tags.contains(where: { $0.id == selectedTagID }) {
            tagStore.setSelectedTagID(nil)
        }
        prunePayloadsToCurrentRecords()
        let visibleRecordIDs = Set(
            (snapshot.loadedRecords ?? records).map(\.id)
                + snapshot.resultSet.records.map(\.id)
        )
        previewSnapshots = previewSnapshots.filter { visibleRecordIDs.contains($0.key) }
        imagePreviewCache = imagePreviewCache.filter { visibleRecordIDs.contains($0.key) }
        imagePreviewFailures = imagePreviewFailures.filter { visibleRecordIDs.contains($0) }
        for recordID in Array(imagePreviewTasks.keys) where !visibleRecordIDs.contains(recordID) {
            imagePreviewTasks.removeValue(forKey: recordID)?.cancel()
        }
    }

    private func previewImage(for record: ClipboardRecorderRecord) -> NSImage? {
        guard record.kind == .image,
              !(record.excluded || record.snapshotSkipped) else {
            return nil
        }
        if let cachedImage = imagePreviewCache[record.id] {
            return cachedImage
        }
        guard imagePreviewTasks[record.id] == nil,
              !imagePreviewFailures.contains(record.id) else {
            return nil
        }

        let recordID = record.id
        let pipeline = recordActionPipeline
        imagePreviewTasks[recordID] = Task { @MainActor [weak self] in
            let result = await pipeline.readImagePreview(recordID: recordID)
            guard let self else { return }
            self.imagePreviewTasks[recordID] = nil
            guard !Task.isCancelled else { return }
            guard let pngData = result.pngData,
                  let image = NSImage(data: pngData) else {
                self.imagePreviewFailures.insert(recordID)
                if result.failure == .repositoryUnavailable {
                    self.repositoryUnavailable = true
                }
                return
            }
            self.repositoryUnavailable = false
            self.imagePreviewCache[recordID] = image
            self.objectWillChange.send()
        }
        return nil
    }

    private func invalidateCaches(for recordID: String) {
        imagePreviewTasks.removeValue(forKey: recordID)?.cancel()
        imagePreviewCache[recordID] = nil
        imagePreviewFailures.remove(recordID)
        previewSnapshots[recordID] = nil
        payloadCache = payloadCache.filter { $0.key.recordID != recordID }
        Self.orderingLogger.debug(
            "stage=record-cache-invalidated record=\(String(recordID.suffix(8)), privacy: .public)"
        )
    }

    private func boundedFallbackPreview(
        for record: ClipboardRecorderRecord
    ) -> ClipboardRecordPreview {
        let title: String
        if record.excluded || record.snapshotSkipped {
            title = displayTitle(for: record)
        } else {
            title = displayTitle(for: record)
        }
        let body: String
        if record.excluded || record.snapshotSkipped {
            body = displayBody(for: record, snapshotBody: record.summary)
        } else if !record.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = bounded(record.summary, limit: 500)
        } else {
            body = L10n.string("clipboard.preview.contentUnavailable")
        }
        return ClipboardRecordPreview(
            title: title,
            body: body,
            badge: record.kind.localizedTitle,
            image: nil
        )
    }

    private func bounded(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed
        }
        return String(trimmed.prefix(limit))
    }

    private func displayTitle(for record: ClipboardRecorderRecord) -> String {
        let customTitle = record.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return customTitle?.isEmpty == false ? customTitle! : record.kind.localizedTitle
    }

    private func displayBody(for record: ClipboardRecorderRecord, snapshotBody: String) -> String {
        if let skipReason = ClipboardCaptureSkipReason(summaryCode: snapshotBody) {
            return skipReason.localizedPreviewBody
        }
        switch snapshotBody {
        case "Content not available":
            return L10n.string("clipboard.preview.contentUnavailable")
        case "Image content":
            return L10n.string("clipboard.preview.imageBodyUnknown")
        default:
            return snapshotBody
        }
    }

    private var effectiveFilterState: ClipboardFilterState {
        var state = filterState
        state.selectedTagID = tagStore.selectedTagID
        return state
    }

    private func prunePreviewSnapshotsToCurrentRecords() {
        let recordIDs = Set(records.map(\.id))
        previewSnapshots = previewSnapshots.filter { recordIDs.contains($0.key) }
    }

    private func scheduleIndexMaintenance() {
        guard !didScheduleIndexMaintenance, let repository else {
            return
        }
        didScheduleIndexMaintenance = true
        DispatchQueue.global(qos: .utility).async { [weak self, repository] in
            do {
                let recoveredOCRCount = try repository.recoverInterruptedOCR()
                let indexBatchSize = 96
                var rebuiltCount = try repository.rebuildPendingSearchDocuments(limit: indexBatchSize)
                var totalRebuiltCount = rebuiltCount
                while rebuiltCount == indexBatchSize {
                    rebuiltCount = try repository.rebuildPendingSearchDocuments(limit: indexBatchSize)
                    totalRebuiltCount += rebuiltCount
                }
                let activity = try repository.searchIndexActivity()
                guard recoveredOCRCount > 0 || totalRebuiltCount > 0 || activity.pendingOCRCount > 0 else {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }
                    self.refreshSearchResult(
                        query: self.activeSearchQuery,
                        limit: self.activeSearchLimit
                    )
                    if activity.pendingOCRCount > 0 {
                        self.ocrScheduler?.schedule(context: .startupRecovery, quietDelay: 3)
                    }
                }
            } catch {
                // Normal reads remain available; a later app launch retries maintenance.
            }
        }
    }

    private func refreshAfterOCRWork(recordIDs: Set<String> = []) {
        if let repository {
            for recordID in recordIDs {
                if let snapshot = try? repository.loadPreviewSnapshot(recordID: recordID) {
                    previewSnapshots[recordID] = snapshot
                }
            }
            refreshSearchResult(query: activeSearchQuery, limit: activeSearchLimit)
        }
        for recordID in recordIDs {
            detailStore.refreshPresentedOCRIfNeeded(recordID: recordID)
            guard let snapshot = previewSnapshots[recordID] else { continue }
            let event = BlocksPluginEventEnvelope(
                name: .clipboardOCRCompleted,
                payload: [
                    "record_id": .string(recordID),
                    "content_revision": .string(snapshot.revision),
                    "state": .string(snapshot.ocrState.rawValue),
                    "ocr_text": .string(snapshot.body)
                ]
            )
            Task { @MainActor [dispatchPluginEvent] in
                _ = await dispatchPluginEvent(event)
            }
        }
    }
}
