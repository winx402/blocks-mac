import AppKit
import BlocksCore
import Combine
import Foundation
import Sparkle

enum AppUpdateTrack: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }
    var title: String { L10n.string("updates.track.\(rawValue)") }
    var feedURL: URL {
        // The updater never accepts an arbitrary feed from defaults or a URL scheme.
        URL(string: "https://winx402.github.io/blocks-mac/appcast/\(rawValue).xml")!
    }
    var allowedChannels: Set<String> { self == .beta ? ["beta"] : [] }
}

/// Pure configuration validation, deliberately independent of Sparkle startup,
/// network access, Keychain, and the installed application.
struct AppUpdateConfiguration {
    let isOfficialDistribution: Bool
    let isLocalDevelopment: Bool
    let isUnitTestHost: Bool
    let bundleIdentifier: String?
    let feedURLString: String?
    let publicKey: String?
    let allowsAutomaticInstallation: Bool

    var unavailableReasonKey: String? {
        guard !isUnitTestHost else { return "updates.unavailable.testing" }
        guard !isLocalDevelopment, isOfficialDistribution,
              bundleIdentifier == "app.blocks.app" else {
            return "updates.unavailable.distribution"
        }
        guard feedURLString == AppUpdateTrack.stable.feedURL.absoluteString else {
            return "updates.unavailable.feed"
        }
        guard let publicKey, let bytes = Data(base64Encoded: publicKey),
              bytes.count == 32, bytes.contains(where: { $0 != 0 }) else {
            return "updates.unavailable.key"
        }
        guard !allowsAutomaticInstallation else {
            return "updates.unavailable.automaticInstallation"
        }
        return nil
    }

    static var current: Self {
        #if BLOCKS_LOCAL_DEVELOPMENT
        let isLocalDevelopment = true
        #else
        let isLocalDevelopment = false
        #endif
        return Self(
            isOfficialDistribution: [.directStable, .directBeta].contains(DistributionChannel.current),
            isLocalDevelopment: isLocalDevelopment,
            isUnitTestHost: BlocksRuntimeEnvironment.isUnitTestHost,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            feedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            // Missing policy is unsafe: Sparkle defaults to allowing automatic installs.
            allowsAutomaticInstallation:
                Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool ?? true
        )
    }

    static func acceptsDownloadURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host != nil && url.user == nil && url.password == nil
    }

    static func hasEd25519Signature(in properties: [AnyHashable: Any]) -> Bool {
        guard let enclosure = properties["enclosure"] as? [String: Any],
              let signature = enclosure["sparkle:edSignature"] as? String,
              let bytes = Data(base64Encoded: signature), bytes.count == 64 else {
            return false
        }
        return bytes.contains(where: { $0 != 0 })
    }
}

/// SwiftUI owns this observable bridge; Sparkle owns checking, download,
/// signature validation, installation, and its standard update windows.
@MainActor
final class AppUpdateCoordinator: NSObject, ObservableObject {
    typealias InstallationPreparation = @MainActor () async throws -> Void
    typealias InstallationRecovery = @MainActor () async -> Void

    static let shared = AppUpdateCoordinator()
    static let trackDefaultsKey = "app.updates.track"

    @Published private var driverCanCheckForUpdates = false
    @Published private(set) var canRetryInstallationPreparation = false
    @Published private(set) var isPreparingInstallation = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var statusKey = "updates.status.ready"
    @Published private(set) var unavailableReasonKey: String?
    @Published private(set) var track: AppUpdateTrack

    private let configuration: AppUpdateConfiguration
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var prepareForUpdate: InstallationPreparation?
    private var resumeAfterCancelledUpdate: InstallationRecovery?
    private var startRequested = false
    private var installationPreparationTask: Task<Void, Never>?
    private var pendingInstallHandler: (() -> Void)?
    private var recoveryTask: Task<Void, Never>?
    private var preparationNeedsRecovery = false

    init(configuration: AppUpdateConfiguration = .current, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        track = AppUpdateTrack(rawValue: defaults.string(forKey: Self.trackDefaultsKey) ?? "") ?? .stable
        unavailableReasonKey = configuration.unavailableReasonKey ?? "updates.unavailable.lifecycle"
        super.init()
    }

    var isAvailable: Bool { controller != nil && unavailableReasonKey == nil }
    var canCheckForUpdates: Bool {
        isAvailable && !isPreparingInstallation && (driverCanCheckForUpdates || canRetryInstallationPreparation)
    }
    var checkButtonTitle: String {
        L10n.string(canRetryInstallationPreparation ? "updates.retryPreparation" : "updates.check")
    }
    var canChangePreferences: Bool { isAvailable && !sessionInProgress && !isPreparingInstallation }
    var statusText: String { L10n.string(unavailableReasonKey ?? statusKey) }

    /// Register only after ALL app/Helper termination paths have a safe drain.
    /// The callback must reject new work, await existing work, back up storage,
    /// and terminate embedded Helpers normally. A failure must throw, not erase data.
    /// Sparkle's relaunch callback is not invoked on every install-on-quit path;
    /// NSApplicationDelegate must independently enforce the same termination gate.
    func configureInstallationSafety(
        prepareForUpdate: @escaping InstallationPreparation,
        resumeAfterCancelledUpdate: @escaping InstallationRecovery
    ) {
        guard !isPreparingInstallation, !preparationNeedsRecovery else { return }
        self.prepareForUpdate = prepareForUpdate
        self.resumeAfterCancelledUpdate = resumeAfterCancelledUpdate
        if startRequested { startIfPossible() }
    }

    func startIfPossible() {
        startRequested = true
        guard controller == nil else { return }
        if let reason = configuration.unavailableReasonKey {
            unavailableReasonKey = reason
            return
        }
        guard prepareForUpdate != nil, resumeAfterCancelledUpdate != nil else {
            unavailableReasonKey = "updates.unavailable.lifecycle"
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        do {
            // Starting through the updater exposes configuration errors without
            // scheduling the controller's delayed generic misconfiguration alert.
            try controller.updater.start()
            self.controller = controller
            unavailableReasonKey = nil
            observe(controller.updater)
        } catch {
            unavailableReasonKey = "updates.unavailable.start"
        }
    }

    func checkForUpdates() {
        guard isAvailable, canCheckForUpdates else { return }
        if canRetryInstallationPreparation {
            retryInstallationPreparation()
            return
        }
        statusKey = "updates.status.checking"
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard canChangePreferences else { return }
        // Sparkle persists consent; do not create a second copy in app defaults.
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setTrack(_ newTrack: AppUpdateTrack) {
        guard canChangePreferences, newTrack != track else { return }
        track = newTrack
        defaults.set(newTrack.rawValue, forKey: Self.trackDefaultsKey)
        statusKey = "updates.status.ready"
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    private func observe(_ updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.driverCanCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.sessionInProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sessionInProgress = $0 }
            .store(in: &subscriptions)
    }

    private func updateError(_ key: String) -> NSError {
        NSError(domain: "app.blocks.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.string(key)])
    }

    /// Kept separate from Sparkle delegate types so tests can prove that failed
    /// preparation never invokes an installation handler, without an updater.
    func postponeInstallation(until installHandler: @escaping () -> Void) {
        guard pendingInstallHandler == nil else { return }
        pendingInstallHandler = installHandler
        retryInstallationPreparation()
    }

    func retryInstallationPreparation() {
        guard !AppTerminationCoordinator.shared.isQuitting else { return }
        guard pendingInstallHandler != nil, installationPreparationTask == nil, recoveryTask == nil else { return }
        canRetryInstallationPreparation = false
        isPreparingInstallation = true
        statusKey = "updates.status.waiting"
        installationPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                installationPreparationTask = nil
                isPreparingInstallation = false
            }
            do {
                guard let prepareForUpdate, resumeAfterCancelledUpdate != nil else {
                    throw updateError("updates.unavailable.lifecycle")
                }
                preparationNeedsRecovery = true
                try await prepareForUpdate()
                try Task.checkCancellation()
                guard !AppTerminationCoordinator.shared.isQuitting else { throw CancellationError() }
                guard pendingInstallHandler != nil else { throw CancellationError() }
                statusKey = "updates.status.installing"
                let handler = pendingInstallHandler
                pendingInstallHandler = nil
                handler?()
                // An installer may synchronously report an abort from the handler.
                if Task.isCancelled { await recoverPausedWorkIfNeeded() }
            } catch {
                await recoverPausedWorkIfNeeded()
                guard pendingInstallHandler != nil else { return }
                // Do not invoke the installation handler on failure. Retain it
                // for an explicit retry, never for a timer/automatic retry loop.
                statusKey = "updates.status.preparationFailed"
                canRetryInstallationPreparation = true
            }
        }
    }

    /// Safe for repeated Sparkle cancellation/abort callbacks. An in-flight
    /// preparation is cancelled and must unwind before recovery may resume work.
    func cancelInstallationPreparation() {
        pendingInstallHandler = nil
        canRetryInstallationPreparation = false
        if let installationPreparationTask {
            installationPreparationTask.cancel()
            return
        }
        guard preparationNeedsRecovery, recoveryTask == nil else { return }
        isPreparingInstallation = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await recoverPausedWorkIfNeeded()
            recoveryTask = nil
            isPreparingInstallation = false
        }
    }

    private func recoverPausedWorkIfNeeded() async {
        guard !AppTerminationCoordinator.shared.isQuitting else { return }
        guard preparationNeedsRecovery, let resumeAfterCancelledUpdate else { return }
        preparationNeedsRecovery = false
        // An unstructured recovery task does not inherit the cancelled status of
        // preparation. Recovery must finish even when the user cancels an update.
        let recovery = Task { @MainActor in await resumeAfterCancelledUpdate() }
        await recovery.value
    }
}

extension AppUpdateCoordinator: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        track.feedURL.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        track.allowedChannels
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        // Sparkle remembers the answer. SUEnableAutomaticChecks must be absent.
        true
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard configuration.unavailableReasonKey == nil, prepareForUpdate != nil,
              resumeAfterCancelledUpdate != nil, !isPreparingInstallation else {
            throw updateError("updates.unavailable.lifecycle")
        }
        statusKey = "updates.status.checking"
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        try validateDownloadMetadata(updateItem)
        // Sparkle can choose a delta after selecting the top-level appcast item.
        // Reject an unsafe advertised delta rather than let it bypass this check.
        for delta in updateItem.deltaUpdates?.values ?? Dictionary<String, SUAppcastItem>().values {
            try validateDownloadMetadata(delta)
        }
    }

    private func validateDownloadMetadata(_ updateItem: SUAppcastItem) throws {
        guard AppUpdateConfiguration.acceptsDownloadURL(updateItem.fileURL) else {
            throw updateError("updates.error.insecureDownload")
        }
        guard AppUpdateConfiguration.hasEd25519Signature(in: updateItem.propertiesDictionary) else {
            throw updateError("updates.error.missingSignature")
        }
        // This is a presence/format policy, NOT signature verification. Sparkle
        // alone validates the downloaded archive using the required public key.
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        AppUpdateConfiguration.acceptsDownloadURL(updateItem.releaseNotesURL)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusKey = "updates.status.available"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // "No installable update" also covers a release requiring a newer OS;
        // do not misleadingly claim this running version is necessarily latest.
        statusKey = "updates.status.noUpdate"
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                 with request: NSMutableURLRequest) {
        statusKey = "updates.status.downloading"
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        statusKey = "updates.status.downloaded"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        cancelInstallationPreparation()
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
            statusKey = "updates.status.noUpdate"
        } else {
            statusKey = "updates.status.failed"
        }
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        cancelInstallationPreparation()
        statusKey = "updates.status.cancelled"
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice != .install {
            cancelInstallationPreparation()
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(until: installHandler)
        return true
    }
}
