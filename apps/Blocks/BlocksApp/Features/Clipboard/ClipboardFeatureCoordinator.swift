import AppKit
import BlocksCore
import Combine
import OSLog
private typealias ClipboardQuickPasteRequest = (index: Int, snapshotRecordID: String?, fallbackRecordIDs: [String])

enum ClipboardExplicitTextCopyOutcome: Equatable {
    case copiedAndRecorded
    case copiedWithoutHistory
    case failed
}

enum ClipboardPasteSessionPhase: String, Equatable {
    case idle
    case copying
    case copied
    case targetVerifying
    case dispatching
    case completed
    case failed
}

struct ClipboardPasteTransactionState: Equatable {
    private(set) var generation = 0
    private(set) var activeToken: UUID?
    private(set) var phase: ClipboardPasteSessionPhase = .idle
    mutating func begin(token: UUID) -> Int {
        generation += 1
        activeToken = token
        phase = .copying
        return generation
    }
    mutating func invalidate() {
        generation += 1
        activeToken = nil
        phase = .idle
    }
    func isCurrent(generation: Int, token: UUID) -> Bool {
        self.generation == generation && activeToken == token
    }
    @discardableResult
    mutating func transition(
        generation: Int,
        token: UUID,
        to nextPhase: ClipboardPasteSessionPhase
    ) -> Bool {
        guard isCurrent(generation: generation, token: token) else { return false }
        phase = nextPhase
        return true
    }
    func canWrite(expectedChangeCount: Int, currentChangeCount: Int) -> Bool {
        expectedChangeCount == currentChangeCount
    }
}

@MainActor
final class ClipboardFeatureCoordinator {
    static let applicationUpdateParticipantID = "clipboard"
    static let transactionLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-transaction"
    )

    struct PendingPasteRequest {
        let recordID: String
        let copyEventSource: ClipboardCopyEventSource
        let invocationOrigin: BlocksPluginHostInvocationOrigin
        let pluginLifecycleToken:
            BlocksPluginRuntimeCoordinator.HostActionLifecycleToken?
        let pluginLifecycleLeaseProvider: @MainActor () ->
            BlocksPluginHostOperationAdmissionGate.Lease?
        let pluginLifecycleIsCurrent: @MainActor (
            BlocksPluginRuntimeCoordinator.HostActionLifecycleToken
        ) -> Bool
        let targetContext: ClipboardPasteTargetContext?
        /// The floating-panel invocation that authorized this request, if any.
        /// Requests initiated with no visible panel must not acquire one later.
        let panelInvocationID: UUID?
        let promptForAccessibility: Bool
        let token: UUID
        let expectedPasteboardChangeCount: Int?
        let preparedWriteLease: ClipboardPasteboardWriteLease?
        let historySyncPending: Bool

        func retryingAfterAccessibilityGrant() -> PendingPasteRequest {
            PendingPasteRequest(
                recordID: recordID,
                copyEventSource: copyEventSource,
                invocationOrigin: invocationOrigin,
                pluginLifecycleToken: pluginLifecycleToken,
                pluginLifecycleLeaseProvider: pluginLifecycleLeaseProvider,
                pluginLifecycleIsCurrent: pluginLifecycleIsCurrent,
                targetContext: targetContext,
                panelInvocationID: panelInvocationID,
                promptForAccessibility: false,
                token: token,
                expectedPasteboardChangeCount: expectedPasteboardChangeCount,
                preparedWriteLease: preparedWriteLease,
                historySyncPending: historySyncPending
            )
        }

        func waitingForAccessibilityRetry(
            lease: ClipboardPasteboardWriteLease,
            historySyncPending: Bool
        ) -> PendingPasteRequest {
            PendingPasteRequest(
                recordID: recordID,
                copyEventSource: copyEventSource,
                invocationOrigin: invocationOrigin,
                pluginLifecycleToken: pluginLifecycleToken,
                pluginLifecycleLeaseProvider: pluginLifecycleLeaseProvider,
                pluginLifecycleIsCurrent: pluginLifecycleIsCurrent,
                targetContext: targetContext,
                panelInvocationID: panelInvocationID,
                promptForAccessibility: promptForAccessibility,
                token: token,
                expectedPasteboardChangeCount: lease.changeCount,
                preparedWriteLease: lease,
                historySyncPending: historySyncPending
            )
        }
    }
    let clipboardStore: ClipboardStore
    let privacyStore: PrivacyStore
    let notificationCoordinator = ClipboardNotificationCoordinator()
    let featureAvailabilityStore: FeatureAvailabilityStore
    let clipboardHistoryPanelPresenter: ClipboardHistoryPanelPresenter
    let autoPasteCoordinator: ClipboardAutoPasteCoordinator
    let liveCaptureService: ClipboardLiveCaptureService
    private var filterClearTask: Task<Void, Never>?
    var pasteTask: Task<Void, Never>?
    var pasteTransactionState = ClipboardPasteTransactionState()
    var pendingPasteRequest: PendingPasteRequest?
    var activePasteRequest: PendingPasteRequest?
    private let pasteboardChangeCountForTesting: (() -> Int)?
    let screenSharingClipboardIsActive: () -> Bool
    var liveCaptureTask: Task<Void, Never>?
    var liveCaptureTaskOwner: UUID?
    var latestPendingLiveCapture: ClipboardLiveCaptureSnapshot?
    let liveCaptureGeneration = ClipboardCaptureGeneration()
    private var privacyCaptureAuthorizationObservation: AnyCancellable?
    var plainTextCopyTask: Task<Void, Never>?
    var plainTextCopyTaskOwner: UUID?
    var plainTextCopyPayloadReader: @MainActor (
        String
    ) async -> ClipboardPayloadReadResult
    private var statusRecorder: (AppStatus) -> Void = { _ in }
    private var sectionSelector: (AppSection) -> Void = { _ in }
    private var closeTranslationPanel: () -> Void = {}
    var translateRecord: (String) -> Void = { _ in }
    private var refreshPermissionState: () -> Void = {}
    weak var pluginRuntime: BlocksPluginRuntimeCoordinator?
    var dispatchPluginEvent: @MainActor (
        BlocksPluginEventEnvelope
    ) async -> BlocksPluginEventDispatchResult = { .allowed($0) }
    var stagePluginTextResource: @Sendable (
        String,
        BlocksPluginResourceKind,
        String?,
        [String: JSONValue]
    ) async -> BlocksPluginResourceReference? = { _, _, _, _ in nil }
    var removePluginResources: ([String]) -> Void = { _ in }
    var accessibilityGranted: () -> Bool = { false }
    var presentAccessibilityAssist: (@escaping () -> Void) -> Void = { _ in }

    init(
        clipboardStore: ClipboardStore,
        privacyStore: PrivacyStore,
        featureAvailabilityStore: FeatureAvailabilityStore,
        pasteboardChangeCount: (() -> Int)? = nil,
        screenSharingClipboardIsActive: (() -> Bool)? = nil,
        autoPasteCoordinator: ClipboardAutoPasteCoordinator? = nil,
        clipboardHistoryPanelPresenter: ClipboardHistoryPanelPresenter? = nil
    ) {
        self.clipboardStore = clipboardStore
        self.privacyStore = privacyStore
        self.featureAvailabilityStore = featureAvailabilityStore
        self.clipboardHistoryPanelPresenter =
            clipboardHistoryPanelPresenter ?? ClipboardHistoryPanelPresenter()
        self.autoPasteCoordinator =
            autoPasteCoordinator ?? ClipboardAutoPasteCoordinator()
        self.liveCaptureService = ClipboardLiveCaptureService(
            applicationUpdateGate: clipboardStore.applicationUpdateGate
        )
        plainTextCopyPayloadReader = { [clipboardStore] recordID in
            await clipboardStore.readPayloadForAction(
                recordID: recordID,
                purpose: .copyPlainText
            )
        }
        pasteboardChangeCountForTesting = pasteboardChangeCount
        if let screenSharingClipboardIsActive {
            self.screenSharingClipboardIsActive =
                screenSharingClipboardIsActive
        } else {
            let workspaceContext = ClipboardWorkspaceContextMonitor.shared
            self.screenSharingClipboardIsActive = {
                workspaceContext.screenSharingActive
            }
        }
        privacyCaptureAuthorizationObservation = privacyStore
            .$privacyCaptureAuthorizationGeneration
            .sink { [weak self] _ in
                self?.invalidateLiveCapturePersistence()
            }
    }

    var tagStore: ClipboardTagStore { clipboardStore.tagStore }
    var isClipboardFeatureEnabled: Bool { featureAvailabilityStore.clipboardEnabled }

    func configure(
        statusRecorder: @escaping (AppStatus) -> Void,
        sectionSelector: @escaping (AppSection) -> Void,
        closeTranslationPanel: @escaping () -> Void,
        translateRecord: @escaping (String) -> Void,
        refreshPermissionState: @escaping () -> Void,
        pluginManager: BlocksNativePluginManager? = nil,
        pluginRuntime: BlocksPluginRuntimeCoordinator? = nil,
        dispatchPluginEvent: @escaping @MainActor (
            BlocksPluginEventEnvelope
        ) async -> BlocksPluginEventDispatchResult,
        stagePluginTextResource: @escaping @Sendable (
            String,
            BlocksPluginResourceKind,
            String?,
            [String: JSONValue]
        ) async -> BlocksPluginResourceReference?,
        removePluginResources: @escaping ([String]) -> Void,
        accessibilityGranted: @escaping () -> Bool,
        presentAccessibilityAssist: @escaping (@escaping () -> Void) -> Void
    ) {
        self.statusRecorder = statusRecorder
        self.sectionSelector = sectionSelector
        self.closeTranslationPanel = closeTranslationPanel
        self.translateRecord = translateRecord
        self.refreshPermissionState = refreshPermissionState
        self.pluginRuntime = pluginRuntime
        clipboardHistoryPanelPresenter.configurePluginPlatform(
            manager: pluginManager,
            runtime: pluginRuntime
        )
        self.dispatchPluginEvent = dispatchPluginEvent
        self.stagePluginTextResource = stagePluginTextResource
        self.removePluginResources = removePluginResources
        clipboardStore.configurePluginEventDispatcher(dispatchPluginEvent)
        self.accessibilityGranted = accessibilityGranted
        self.presentAccessibilityAssist = presentAccessibilityAssist
    }

    func loadRepositoryState(limit: Int? = nil) {
        clipboardStore.refreshSearchResult(
            query: "",
            limit: max(1, limit ?? ClipboardPanelPagination.initialVisibleLimit)
        )
    }

    func startLiveCapture() {
        guard featureAvailabilityStore.clipboardEnabled else { return }
        invalidateLiveCapturePersistence()
        liveCaptureService.start(
            prefilterProvider: { [weak self] sourceApp in
                guard let self else { return .allow }
                let disposition: ClipboardBrokerPrefilterDisposition
                if !self.privacyStore.canCaptureClipboard {
                    disposition = .redactPrivacyUnavailable
                } else if self.clipboardStore.recorderPaused {
                    disposition = .redactPaused
                } else if self.privacyStore.policySnapshot.match(
                    sourceApp: sourceApp
                ).decision == .deny {
                    disposition = .redactExcludedSource
                } else {
                    disposition = .allow
                }
                return ClipboardLiveCapturePrefilter(
                    disposition: disposition,
                    screenSharingActive: self.screenSharingClipboardIsActive()
                )
            },
            onCapture: { [weak self] in self?.ingestLiveCapture($0) }
        )
    }

    func disableRuntime() {
        pluginRuntime?.invalidateFeatureAdmission(for: .clipboard)
        liveCaptureService.stop()
        invalidateLiveCapturePersistence()
        invalidatePlainTextCopy()
        filterClearTask?.cancel()
        filterClearTask = nil
        pendingPasteRequest = nil
        invalidatePasteTransaction(stage: "feature-disabled")
        clipboardHistoryPanelPresenter.forceCloseForRuntimeDisable()
        recordFeatureDisabledStatus()
    }

    /// Participant entry point registered by the application lifecycle layer.
    /// This never cancels current work: a busy gate rejects the update attempt.
    func prepareForApplicationUpdate() async throws {
        try clipboardStore.pauseForApplicationUpdate()
    }

    /// Idempotent recovery after a cancelled update. Timers and future capture
    /// work may obtain fresh leases again; completed Task references are not
    /// treated as active work.
    func resumeAfterCancelledApplicationUpdate() async {
        clipboardStore.resumeAfterCancelledApplicationUpdate()
        if isClipboardFeatureEnabled {
            startLiveCapture()
        }
    }

    func showHistory() { sectionSelector(.clipboardSettings); statusRecorder(clipboardStatus()) }
    func showFloatingPanel(
        openMainWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        invocationSource: ClipboardPanelInvocationSource = .floatingPanel
    ) {
        guard featureAvailabilityStore.clipboardEnabled else {
            recordFeatureDisabledStatus()
            return
        }
        guard !clipboardHistoryPanelPresenter.shouldSuppressOpen() else {
            return
        }
        let invocationContext = clipboardHistoryPanelPresenter.captureInvocation(
            source: invocationSource
        )
        pendingPasteRequest = nil
        invalidatePasteTransaction(stage: "panel-opened")
        filterClearTask?.cancel()
        filterClearTask = nil
        closeTranslationPanel()
        liveCaptureService.pollPasteboard()
        statusRecorder(clipboardStatus())
        let position = resolvedFloatingPanelPosition()
        let actions = makeClipboardPanelActions()
        switch clipboardHistoryPanelPresenter.present(
            clipboardStore: clipboardStore,
            notificationState: notificationCoordinator.presentationState,
            actions: actions,
            position: position,
            invocationContext: invocationContext,
            openMainWindow: openMainWindow,
            openSettings: openSettings,
            onCloseStarted: { [weak self] pasteSessionID, closingInvocationID in
                self?.cancelPasteBoundToClosingPanel(
                    pasteSessionID: pasteSessionID,
                    closingInvocationID: closingInvocationID
                )
            },
            onClosed: { [weak self] pasteInitiatedSessionID in
                guard let self else { return }
                self.notificationCoordinator.setHostVisible(false)
                self.scheduleFilterClearAfterPanelClose()
                Self.transactionLogger.info(
                    "stage=panel-closed-for-paste session=\(pasteInitiatedSessionID?.uuidString ?? "none", privacy: .public)"
                )
            }
        ) {
        case .shown:
            notificationCoordinator.dismissCopiedFallback()
            notificationCoordinator.setHostVisible(true)
            if clipboardStore.repositoryUnavailable {
                notificationCoordinator.repositoryUnavailable()
            }
        case .suppressed:
            notificationCoordinator.setHostVisible(false)
        }
    }

    func openPanelForVerificationIfRequested(
        openMainWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        guard ProcessInfo.processInfo.environment["BLOCKS_OPEN_CLIPBOARD_PANEL_ON_LAUNCH"] == "1" else {
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.showFloatingPanel(
                openMainWindow: openMainWindow,
                openSettings: openSettings,
                invocationSource: .verification
            )
        }
    }

    func closeFloatingPanel(afterClose: @escaping () -> Void) { clipboardHistoryPanelPresenter.close(afterClose: afterClose) }

    @discardableResult
    func pasteRecord(
        recordID: String,
        invocationOrigin: BlocksPluginHostInvocationOrigin = .explicitUser,
        pluginLifecycleToken:
            BlocksPluginRuntimeCoordinator.HostActionLifecycleToken? = nil,
        pluginLifecycleLeaseProvider: @escaping @MainActor () ->
            BlocksPluginHostOperationAdmissionGate.Lease? = { nil },
        pluginLifecycleIsCurrent: @escaping @MainActor (
            BlocksPluginRuntimeCoordinator.HostActionLifecycleToken
        ) -> Bool = { _ in true }
    ) -> Bool {
        guard featureAvailabilityStore.clipboardEnabled else {
            recordFeatureDisabledStatus()
            return false
        }
        guard invocationOrigin.userInitiated else { return false }
        refreshPermissionState()
        guard clipboardStore.resolveRecord(recordID: recordID) != nil else {
            recordNotFoundStatus()
            return false
        }
        let targetContext = pasteTargetContextForCurrentAction()
        let request = makePendingPasteRequest(
            recordID: recordID,
            targetContext: targetContext,
            panelInvocationID: clipboardHistoryPanelPresenter.invocationID,
            promptForAccessibility: true,
            invocationOrigin: invocationOrigin,
            pluginLifecycleToken: pluginLifecycleToken,
            pluginLifecycleLeaseProvider: pluginLifecycleLeaseProvider,
            pluginLifecycleIsCurrent: pluginLifecycleIsCurrent
        )
        clipboardHistoryPanelPresenter.authorizePasteAction { [weak self] in
            self?.startPaste(request)
        }
        return true
    }

    func pasteQuickRecord(index: Int) {
        guard featureAvailabilityStore.clipboardEnabled else {
            recordFeatureDisabledStatus()
            return
        }
        captureQuickPasteSnapshotIfNeeded()
        let quickPasteRequest = makeQuickPasteRequest(index: index)
        let zeroBasedIndex = quickPasteRequest.index - 1
        let fallbackRecordID = zeroBasedIndex >= 0 && zeroBasedIndex < min(9, quickPasteRequest.fallbackRecordIDs.count)
            ? quickPasteRequest.fallbackRecordIDs[zeroBasedIndex]
            : nil
        guard let recordID = quickPasteRequest.snapshotRecordID ?? fallbackRecordID else {
            recordNotFoundStatus()
            return
        }
        let targetContext = pasteTargetContextForCurrentAction()
        let request = makePendingPasteRequest(
            recordID: recordID,
            targetContext: targetContext,
            panelInvocationID: clipboardHistoryPanelPresenter.invocationID,
            promptForAccessibility: true,
            copyEventSource: .quickPaste,
            invocationOrigin: .explicitUser,
            pluginLifecycleToken: nil,
            pluginLifecycleLeaseProvider: { nil },
            pluginLifecycleIsCurrent: { _ in true }
        )
        clipboardHistoryPanelPresenter.authorizePasteAction { [weak self] in
            self?.startPaste(request)
        }
    }

    private func pasteTargetContextForCurrentAction() -> ClipboardPasteTargetContext? {
        if clipboardHistoryPanelPresenter.isVisible {
            return clipboardHistoryPanelPresenter.targetContextForPaste()
        }
        return clipboardHistoryPanelPresenter.targetContextForDirectAction()
    }
    private func makeQuickPasteRequest(index: Int) -> ClipboardQuickPasteRequest {
        let isPanelVisible = clipboardHistoryPanelPresenter.isVisible
        let sourceRecords = isPanelVisible ? clipboardStore.currentSearchResult.records : clipboardStore.records
        let snapshotRecordID = isPanelVisible ? clipboardHistoryPanelPresenter.quickPasteSnapshotRecordID(index: index) : nil
        return (index: index, snapshotRecordID: snapshotRecordID, fallbackRecordIDs: sourceRecords.map(\.id))
    }

    private func captureQuickPasteSnapshotIfNeeded() {
        guard clipboardHistoryPanelPresenter.isVisible else {
            return
        }
        clipboardHistoryPanelPresenter.captureQuickPasteSnapshotIfNeeded(
            visibleRecordIDs: clipboardStore.currentSearchResult.records.map(\.id)
        )
    }

    func toggleRecorderPaused() {
        guard featureAvailabilityStore.clipboardEnabled else {
            recordFeatureDisabledStatus()
            return
        }
        clipboardStore.recorderPaused.toggle()
        statusRecorder(clipboardStatus())
    }

    func recordFeatureDisabledStatus() {
        statusRecorder(AppStatus(
            kind: .ready,
            title: L10n.string("feature.clipboard.disabled.title"),
            detail: L10n.string("feature.clipboard.disabled.detail")
        ))
    }

    func scheduleFilterClearAfterPanelClose() {
        filterClearTask?.cancel()
        guard clipboardStore.hasActiveFilters else {
            return
        }
        let rawValue = UserDefaults.standard.string(forKey: ClipboardPanelSettings.Keys.filterClearDelay)
            ?? ClipboardFilterClearDelay.seconds30.rawValue
        let delay = ClipboardFilterClearDelay(rawValue: rawValue) ?? .seconds30
        guard let seconds = delay.delaySeconds else {
            return
        }
        if seconds <= 0 {
            clipboardStore.clearFilters()
            return
        }
        filterClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.clipboardStore.clearFilters()
            self?.filterClearTask = nil
        }
    }

    func toggleFavorite(recordID: String) {
        Task { @MainActor [weak self] in
            guard let self,
                  let nextFavorite = await clipboardStore.toggleFavorite(recordID: recordID) else {
                return
            }
            recordStatus(
                .ready,
                title: nextFavorite ? "status.clipboardFavorite.title" : "status.clipboardFavoriteRemoved.title",
                detail: L10n.string(
                    nextFavorite ? "status.clipboardFavorite.detail" : "status.clipboardFavoriteRemoved.detail"
                )
            )
            notificationCoordinator.favoriteChanged(recordID: recordID, isFavorite: nextFavorite)
        }
    }

    func deleteHistoryItem(recordID: String) async -> Bool {
        guard await clipboardStore.delete(recordID: recordID) else {
            return false
        }
        recordStatus(
            .ready,
            title: "status.clipboardRemoved.title",
            detail: L10n.format("status.clipboardRemoved.detail", clipboardStore.records.count)
        )
        notificationCoordinator.recordRemoved(remainingCount: clipboardStore.records.count)
        return true
    }

    func setTagFilter(_ tagID: String?) { clipboardStore.setTagFilter(tagID) }

    func invalidatePasteTransaction(stage: String) {
        let cancelledSession = pasteTransactionState.activeToken?.uuidString ?? "none"
        let cancelledPhase = pasteTransactionState.phase.rawValue
        pasteTransactionState.invalidate()
        activePasteRequest = nil
        pasteTask?.cancel()
        pasteTask = nil
        Self.transactionLogger.info(
            "stage=\(stage, privacy: .public) generation=\(self.pasteTransactionState.generation) cancelledSession=\(cancelledSession, privacy: .public) cancelledPhase=\(cancelledPhase, privacy: .public) lastObservedChangeCount=\(self.cachedPasteboardChangeCount)"
        )
    }

    private func cancelPasteBoundToClosingPanel(
        pasteSessionID: UUID?,
        closingInvocationID: UUID?
    ) {
        guard let closingInvocationID else { return }
        let activeMatches = activePasteRequest?.panelInvocationID == closingInvocationID
        let pendingMatches = pendingPasteRequest?.panelInvocationID == closingInvocationID
        guard activeMatches || pendingMatches else { return }
        let pasteInitiatedCloseMatchesCurrentSession = pasteSessionID.map { sessionID in
            sessionID == activePasteRequest?.token
                || sessionID == pasteTransactionState.activeToken
        } ?? false
        guard !pasteInitiatedCloseMatchesCurrentSession else {
            return
        }
        pendingPasteRequest = nil
        invalidatePasteTransaction(stage: "panel-close-started")
    }
    func pasteTransactionIsCurrent(_ generation: Int, request: PendingPasteRequest) -> Bool {
        pasteTransactionState.isCurrent(generation: generation, token: request.token)
    }

    func pastePluginLifecycleIsCurrent(_ request: PendingPasteRequest) -> Bool {
        guard let token = request.pluginLifecycleToken else { return true }
        return request.pluginLifecycleIsCurrent(token)
    }

    var cachedPasteboardChangeCount: Int {
        pasteboardChangeCountForTesting?()
            ?? liveCaptureService.observedChangeCount
            ?? -1
    }
    private func clipboardStatus() -> AppStatus {
        if clipboardStore.recorderPaused {
            return AppStatus(
                kind: .placeholder,
                title: L10n.string("status.clipboardPaused.title"),
                detail: L10n.string("status.clipboardPaused.detail")
            )
        }
        return AppStatus(
            kind: .ready,
            title: L10n.string("status.clipboardReady.title"),
            detail: L10n.format("status.clipboardReady.detail", clipboardStore.records.count)
        )
    }

    func recordNotFoundStatus() {
        recordStatus(
            .failed,
            title: "status.clipboardPasteFailed.title",
            detail: L10n.string("status.clipboardPasteFailed.notFound")
        )
    }

    func recordStatus(_ kind: AppStatusKind, title: String, detail: String) {
        statusRecorder(AppStatus(kind: kind, title: L10n.string(title), detail: detail))
    }
}
