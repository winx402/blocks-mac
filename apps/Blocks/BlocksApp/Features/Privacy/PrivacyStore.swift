import BlocksCore
import Combine
import Foundation

enum PrivacyPolicyAvailability: Equatable {
    case loading
    case ready
    case failed
}

/// Atomically admits a live capture's database transaction against privacy
/// revocation. A token is valid only while the gate remains open for its
/// generation; revocation closes the gate under the same lock that protects
/// admitted insert and retention work.
struct PrivacyCaptureAdmissionToken: @unchecked Sendable {
    fileprivate let gate: PrivacyCaptureAdmissionGate
    let generation: Int

    func withAuthorizedAdmission<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        try gate.withAuthorizedAdmission(
            expectedGeneration: generation,
            operation
        )
    }
}

final class PrivacyCaptureAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var isClosed = true

    func invalidate(generation: Int) {
        lock.withLock {
            self.generation = generation
            isClosed = true
        }
    }

    func open(generation: Int) {
        lock.withLock {
            guard self.generation == generation else { return }
            isClosed = false
        }
    }

    func token(generation: Int) -> PrivacyCaptureAdmissionToken? {
        lock.withLock {
            guard !isClosed, self.generation == generation else { return nil }
            return PrivacyCaptureAdmissionToken(gate: self, generation: generation)
        }
    }

    func withAuthorizedAdmission<Result>(
        expectedGeneration: Int,
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, generation == expectedGeneration else { return nil }
        return try operation()
    }
}

@MainActor
final class PrivacyStore: ObservableObject {
    @Published private(set) var apps: [PrivacyAppInstance] = []
    @Published private(set) var policySnapshot = PrivacyPolicySnapshot()
    @Published private(set) var capturePolicyAvailability: PrivacyPolicyAvailability = .loading
    @Published private(set) var privacyCaptureAuthorizationGeneration = 0
    @Published private(set) var mutationState: PrivacyPolicyMutationState = .pending
    @Published private(set) var mutationSubjectID: String?
    @Published private(set) var lastErrorCode: String?
    @Published var searchQuery = ""
    @Published var policyFilter: PrivacyPolicyStatus?
    @Published var identityFilter: PrivacyIdentityIssue?

    private struct PendingMutation {
        let subject: PrivacyPolicySubject
        let policy: PrivacyPolicyStatus
        let appID: String
    }

    private let repository: PrivacyPolicyRepository?
    private let scanner: PrivacyAppScanning
    private let iconProvider: AppIconProviding
    private var hasLoadedApps = false
    private var lastValidPolicySnapshot: PrivacyPolicySnapshot?
    private var pendingMutation: PendingMutation?
    private var scanRequestID: UUID?
    private var snapshotRequestID: UUID?
    private var mutationRequestID: UUID?
    private var privacyPolicyMutationInFlight = false
    private var scanWorkItem: DispatchWorkItem?
    private let captureAdmissionGate = PrivacyCaptureAdmissionGate()

    init(
        repository: PrivacyPolicyRepository? = PrivacyStore.makeRepository(),
        scanner: PrivacyAppScanning = PrivacyAppScanner(),
        iconProvider: AppIconProviding = SystemAppIconProvider()
    ) {
        self.repository = repository
        self.scanner = scanner
        self.iconProvider = iconProvider
        reloadSnapshot()
    }

    var visibleApps: [PrivacyAppInstance] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return apps.filter { app in
            if let policyFilter, app.policyStatus != policyFilter {
                return false
            }
            if let identityFilter, app.identityIssue != identityFilter {
                return false
            }
            guard !trimmed.isEmpty else {
                return true
            }
            if trimmed.contains(FileManager.default.homeDirectoryForCurrentUser.path.lowercased()) {
                return false
            }
            let fields = [
                app.displayName,
                app.bundleIdentifier ?? "",
                app.sourceDirectory.rawValue,
                app.pathSummary,
                app.policyStatus.rawValue,
                app.identityIssue.rawValue,
            ]
            return fields.contains { $0.lowercased().contains(trimmed) }
        }
        .sorted { lhs, rhs in
            if lhs.displayName == rhs.displayName {
                return lhs.pathSummary < rhs.pathSummary
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var restrictedRuleCount: Int {
        policySnapshot.restrictedBundleIDs.count + policySnapshot.restrictedAppPathHashes.count
    }

    var canCaptureClipboard: Bool {
        capturePolicyAvailability == .ready && !privacyPolicyMutationInFlight
    }

    var captureAdmissionToken: PrivacyCaptureAdmissionToken? {
        guard canCaptureClipboard else { return nil }
        return captureAdmissionGate.token(
            generation: privacyCaptureAuthorizationGeneration
        )
    }

    var canRetryLastMutation: Bool {
        mutationState == .failed && pendingMutation != nil
    }

    var localizedErrorMessage: String? {
        guard let lastErrorCode else {
            return nil
        }
        switch lastErrorCode {
        case "duplicate_bundle_confirmation_required":
            return L10n.string("privacy.duplicate.confirm")
        case "repository_unavailable", "snapshot_failed":
            return L10n.string("privacy.capturePolicy.unavailable")
        case "scan_failed", "policy_mutation_failed":
            return L10n.string("privacy.mutation.failed")
        default:
            return L10n.string("privacy.mutation.failed")
        }
    }

    func loadAppsIfNeeded() {
        guard !hasLoadedApps else {
            return
        }
        loadApps()
    }

    func loadApps() {
        scanWorkItem?.cancel()
        let requestID = UUID()
        scanRequestID = requestID
        let scanner = scanner
        let iconProvider = iconProvider
        let workItem = DispatchWorkItem { [weak self] in
            do {
                let scanned = try scanner.scan(roots: PrivacyAppScanner.defaultRoots(), maxDepth: 2)
                let resolved = scanned.map { app -> PrivacyAppInstance in
                    var app = app
                    app.iconState = iconProvider.iconState(for: app)
                    return app
                }
                DispatchQueue.main.async {
                    guard let self, self.scanRequestID == requestID else {
                        return
                    }
                    self.apps = self.applySnapshot(to: resolved)
                    self.hasLoadedApps = true
                    self.lastErrorCode = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.scanRequestID == requestID else {
                        return
                    }
                    self.lastErrorCode = "scan_failed"
                }
            }
        }
        scanWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    func reloadSnapshot(completingMutationRequestID: UUID? = nil) {
        guard let repository else {
            advancePrivacyCaptureAuthorizationGeneration()
            capturePolicyAvailability = .failed
            lastErrorCode = "repository_unavailable"
            return
        }

        let requestID = UUID()
        snapshotRequestID = requestID
        advancePrivacyCaptureAuthorizationGeneration()
        capturePolicyAvailability = .loading
        DispatchQueue.global(qos: .userInitiated).async { [weak self, repository] in
            do {
                let snapshot = try repository.snapshot()
                DispatchQueue.main.async {
                    guard let self, self.snapshotRequestID == requestID else {
                        return
                    }
                    self.lastValidPolicySnapshot = snapshot
                    self.policySnapshot = snapshot
                    self.capturePolicyAvailability = .ready
                    if self.mutationRequestID == completingMutationRequestID {
                        self.privacyPolicyMutationInFlight = false
                    }
                    self.advancePrivacyCaptureAuthorizationGeneration()
                    self.openPrivacyCaptureAdmissionIfAuthorized()
                    self.apps = self.applySnapshot(to: self.apps)
                    self.lastErrorCode = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.snapshotRequestID == requestID else {
                        return
                    }
                    if let lastValidPolicySnapshot = self.lastValidPolicySnapshot {
                        self.policySnapshot = lastValidPolicySnapshot
                        self.apps = self.applySnapshot(to: self.apps)
                    }
                    self.capturePolicyAvailability = .failed
                    if self.mutationRequestID == completingMutationRequestID {
                        self.privacyPolicyMutationInFlight = false
                    }
                    self.advancePrivacyCaptureAuthorizationGeneration()
                    self.lastErrorCode = "snapshot_failed"
                }
            }
        }
    }

    func setPolicy(for app: PrivacyAppInstance, policy: PrivacyPolicyStatus, confirmed: Bool = false) {
        let subject = PrivacySubjectResolver.subject(from: app)
        let command = PendingMutation(subject: subject, policy: policy, appID: app.id)
        let requiresConfirmation = app.bundleIdentifier.map { duplicateBundleCount($0) > 1 } ?? false
        guard !requiresConfirmation || confirmed else {
            pendingMutation = command
            mutationState = .pending
            mutationSubjectID = app.id
            lastErrorCode = "duplicate_bundle_confirmation_required"
            return
        }
        performMutation(command)
    }

    func retryLastMutation() {
        guard let pendingMutation else {
            return
        }
        performMutation(pendingMutation)
    }

    func cancelPendingMutation() {
        guard mutationState == .pending, pendingMutation != nil else {
            return
        }
        pendingMutation = nil
        mutationSubjectID = nil
        mutationState = .cancel
        lastErrorCode = nil
    }

    func duplicateBundleCount(_ bundleIdentifier: String) -> Int {
        apps.filter { $0.bundleIdentifier == bundleIdentifier }.count
    }

    private func performMutation(_ command: PendingMutation) {
        guard canCaptureClipboard, let repository else {
            mutationState = .unsupported
            mutationSubjectID = command.appID
            lastErrorCode = "repository_unavailable"
            return
        }

        let requestID = UUID()
        mutationRequestID = requestID
        pendingMutation = command
        mutationSubjectID = command.appID
        privacyPolicyMutationInFlight = true
        mutationState = .saving
        advancePrivacyCaptureAuthorizationGeneration()
        lastErrorCode = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self, repository] in
            do {
                _ = try repository.applyPolicy(subject: command.subject, policy: command.policy, dryRun: false)
                DispatchQueue.main.async {
                    guard let self, self.mutationRequestID == requestID else {
                        return
                    }
                    self.mutationState = .saved
                    self.lastErrorCode = nil
                    self.reloadSnapshot(completingMutationRequestID: requestID)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.mutationRequestID == requestID else {
                        return
                    }
                    self.mutationState = .failed
                    self.privacyPolicyMutationInFlight = false
                    if let lastValidPolicySnapshot = self.lastValidPolicySnapshot {
                        self.policySnapshot = lastValidPolicySnapshot
                        self.capturePolicyAvailability = .ready
                        self.apps = self.applySnapshot(to: self.apps)
                    } else {
                        self.capturePolicyAvailability = .failed
                    }
                    self.advancePrivacyCaptureAuthorizationGeneration()
                    self.openPrivacyCaptureAdmissionIfAuthorized()
                    self.lastErrorCode = "policy_mutation_failed"
                }
            }
        }
    }

    private func applySnapshot(to apps: [PrivacyAppInstance]) -> [PrivacyAppInstance] {
        apps.map { app in
            var resolved = app
            if policySnapshot.restrictedAppPathHashes.contains(app.pathHash) {
                resolved.policyStatus = .restricted
            } else if policySnapshot.allowedAppPathHashes.contains(app.pathHash) {
                resolved.policyStatus = .allowed
            } else if let bundleIdentifier = app.bundleIdentifier,
                      policySnapshot.restrictedBundleIDs.contains(bundleIdentifier.lowercased()) {
                resolved.policyStatus = .restricted
            } else if let bundleIdentifier = app.bundleIdentifier,
                      policySnapshot.allowedBundleIDs.contains(bundleIdentifier.lowercased()) {
                resolved.policyStatus = .allowed
            } else {
                resolved.policyStatus = .defaultPolicy
            }
            return resolved
        }
    }

    private func advancePrivacyCaptureAuthorizationGeneration() {
        privacyCaptureAuthorizationGeneration &+= 1
        captureAdmissionGate.invalidate(
            generation: privacyCaptureAuthorizationGeneration
        )
    }

    private func openPrivacyCaptureAdmissionIfAuthorized() {
        guard canCaptureClipboard else { return }
        captureAdmissionGate.open(
            generation: privacyCaptureAuthorizationGeneration
        )
    }

    nonisolated private static func makeRepository() -> PrivacyPolicyRepository? {
        do {
            return try PrivacyPolicyRepository(database: AppDatabase.open())
        } catch {
            return nil
        }
    }
}
