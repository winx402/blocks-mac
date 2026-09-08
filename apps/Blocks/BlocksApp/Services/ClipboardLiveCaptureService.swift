import AppKit
import BlocksCore
import CryptoKit
import OSLog

private let clipboardLiveCaptureLogger = Logger(
    subsystem: "app.blocks.app",
    category: "clipboard-capture"
)

/// Notification-backed workspace state used by the clipboard polling hot path.
///
/// `runningApplications` is sampled once at startup. Subsequent polls only read
/// these cached values; launch, terminate and activation notifications perform
/// the updates.
@MainActor
final class ClipboardWorkspaceContextMonitor {
    static let shared = ClipboardWorkspaceContextMonitor()

    private static let screenSharingBundleIdentifier =
        "com.apple.screensharing.agent"

    private let workspace: NSWorkspace
    private var observerTokens: [NSObjectProtocol] = []
    private var screenSharingProcessIdentifiers = Set<pid_t>()
    private(set) var sourceApp: ClipboardRecorderSourceApp?

    var screenSharingActive: Bool {
        !screenSharingProcessIdentifiers.isEmpty
    }

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        screenSharingProcessIdentifiers = Set(
            workspace.runningApplications.compactMap { application in
                application.bundleIdentifier
                    == Self.screenSharingBundleIdentifier
                    ? application.processIdentifier
                    : nil
            }
        )
        sourceApp = Self.makeSourceApp(workspace.frontmostApplication)

        let center = workspace.notificationCenter
        observerTokens = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.applicationDidLaunch(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.applicationDidTerminate(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.applicationDidActivate(notification)
                }
            },
        ]
    }

    deinit {
        for token in observerTokens {
            workspace.notificationCenter.removeObserver(token)
        }
    }

    private func applicationDidLaunch(_ notification: Notification) {
        guard let application = Self.application(from: notification),
              application.bundleIdentifier
                == Self.screenSharingBundleIdentifier else {
            return
        }
        screenSharingProcessIdentifiers.insert(application.processIdentifier)
    }

    private func applicationDidTerminate(_ notification: Notification) {
        guard let application = Self.application(from: notification) else {
            return
        }
        screenSharingProcessIdentifiers.remove(application.processIdentifier)
    }

    private func applicationDidActivate(_ notification: Notification) {
        sourceApp = Self.makeSourceApp(Self.application(from: notification))
    }

    private static func application(
        from notification: Notification
    ) -> NSRunningApplication? {
        notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication
    }

    private static func makeSourceApp(
        _ application: NSRunningApplication?
    ) -> ClipboardRecorderSourceApp? {
        guard let application else { return nil }
        let bundleURL = application.bundleURL
        return ClipboardRecorderSourceApp(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            sourceAppIsCandidate: true,
            bundlePathHash: bundleURL.map {
                PrivacyPathSanitizer.pathHash(for: $0)
            },
            bundlePathSummary: bundleURL.map {
                PrivacyPathSanitizer.pathSummary(for: $0)
            },
            sourceDirectory: bundleURL.map {
                PrivacyPathSanitizer.sourceDirectory(for: $0)
            }
        )
    }
}

struct ClipboardLiveCaptureSnapshot: @unchecked Sendable {
    let record: ClipboardRecorderRecord
    let payload: ClipboardRecorderPayload?
}

enum ClipboardExplicitTextSnapshotFactory {
    nonisolated static func signature(for text: String) -> String {
        ClipboardLiveCaptureService.explicitTextSignature(text)
    }

    nonisolated static func make(
        text: String,
        recordID: String,
        changeCount: Int,
        createdAt: Date = Date()
    ) -> ClipboardLiveCaptureSnapshot? {
        guard !text.isEmpty,
              text.utf8.count <= ClipboardBrokerLimits.maxTextBytes else {
            return nil
        }
        return ClipboardLiveCaptureService.makeExplicitTextSnapshot(
            text: text,
            recordID: recordID,
            changeCount: changeCount,
            createdAt: createdAt
        )
    }
}

struct ClipboardLiveCapturePrefilter: Sendable {
    let disposition: ClipboardBrokerPrefilterDisposition
    let screenSharingActive: Bool

    static let allow = ClipboardLiveCapturePrefilter(
        disposition: .allow,
        screenSharingActive: false
    )
}

/// Main-actor scheduling around the isolated clipboard process.
///
/// There is never more than one broker observation in flight. Timer ticks that
/// arrive while it is running replace one latest-pending slot, so a promised
/// pasteboard provider cannot grow an unbounded queue in the App process.
@MainActor
final class ClipboardLiveCaptureService {
    private static let performanceSignposter = OSSignposter(
        subsystem: "app.blocks.app",
        category: "ClipboardPerformance"
    )
    typealias PrefilterProvider = (
        _ sourceApp: ClipboardRecorderSourceApp?
    ) -> ClipboardLiveCapturePrefilter

    private struct PendingObservation {
        let sourceApp: ClipboardRecorderSourceApp?
        let prefilter: ClipboardLiveCapturePrefilter
    }

    private let pollInterval: TimeInterval
    private let deferredInitialDelay: Duration
    private let deferredRetryDelay: Duration
    private let deferredFirstTimeout: Duration
    private let deferredRetryTimeout: Duration
    private let broker: any ClipboardBrokerServing
    private let applicationUpdateGate: ApplicationOperationAdmissionGate
    private let monitoringOwnerID = UUID()
    private var timer: Timer?
    private var serviceGeneration: UInt64 = 0
    private var monitoringRevision: UInt64 = 0
    private var monitoringActivationTask: Task<Void, Never>?
    private var lastObservedChangeCount: Int?
    private var observationTask: Task<Void, Never>?
    private var observationTaskID: UUID?
    private var resolutionTask: Task<Void, Never>?
    private var resolutionTaskID: UUID?
    private var deferredChangeCount: Int?
    private var latestPendingObservation: PendingObservation?
    private var prefilterProvider: PrefilterProvider = { _ in .allow }
    private var onCapture: ((ClipboardLiveCaptureSnapshot) -> Void)?
    private var onAvailabilityChange: ((Bool) -> Void)?
    private var captureUnavailable = false

    var observedChangeCount: Int? {
        lastObservedChangeCount
    }

    init(
        pollInterval: TimeInterval = 0.7,
        deferredInitialDelay: Duration = .milliseconds(500),
        deferredRetryDelay: Duration = .milliseconds(1_500),
        deferredFirstTimeout: Duration = .seconds(1),
        deferredRetryTimeout: Duration = .milliseconds(250),
        broker: any ClipboardBrokerServing = ClipboardBrokerClient.shared,
        applicationUpdateGate: ApplicationOperationAdmissionGate = ApplicationOperationAdmissionGate(name: "Clipboard live capture")
    ) {
        self.pollInterval = pollInterval
        self.deferredInitialDelay = deferredInitialDelay
        self.deferredRetryDelay = deferredRetryDelay
        self.deferredFirstTimeout = deferredFirstTimeout
        self.deferredRetryTimeout = deferredRetryTimeout
        self.broker = broker
        self.applicationUpdateGate = applicationUpdateGate
    }

    func start(
        prefilterProvider: @escaping PrefilterProvider = { _ in .allow },
        onAvailabilityChange: @escaping (Bool) -> Void = { _ in },
        onCapture: @escaping (ClipboardLiveCaptureSnapshot) -> Void
    ) {
        stopObservationOnly()
        serviceGeneration &+= 1
        monitoringRevision &+= 1
        let activationRevision = monitoringRevision
        let generation = serviceGeneration
        self.prefilterProvider = prefilterProvider
        self.onCapture = onCapture
        self.onAvailabilityChange = onAvailabilityChange
        onAvailabilityChange(captureUnavailable)
        lastObservedChangeCount = nil
        monitoringActivationTask = applicationUpdateGate.task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.broker.updatePassiveMonitoring(
                ownerID: self.monitoringOwnerID,
                revision: activationRevision,
                active: true
            )
            guard !Task.isCancelled,
                  self.serviceGeneration == generation,
                  self.onCapture != nil else {
                return
            }
            self.timer = Timer.scheduledTimer(
                withTimeInterval: self.pollInterval,
                repeats: true
            ) { [weak self] _ in
                self?.pollPasteboard()
            }
            self.pollPasteboard()
        }
    }

    func stop() {
        stopObservationOnly()
        monitoringRevision &+= 1
        let deactivationRevision = monitoringRevision
        let ownerID = monitoringOwnerID
        let broker = broker
        Task {
            await broker.updatePassiveMonitoring(
                ownerID: ownerID,
                revision: deactivationRevision,
                active: false
            )
        }
        onCapture = nil
        lastObservedChangeCount = nil
        latestPendingObservation = nil
        // Cancellation terminates an in-flight passive Broker request. When
        // there is no request in flight, the shared supervisor's two-second
        // idle reap stops the helper. Do not issue a global shutdown here:
        // translation, OCR, and screenshot copy share the supervisor and an
        // unrelated feature toggle must not abort their explicit write.
    }

    func pollPasteboard() {
        guard onCapture != nil else { return }
        let sourceApp = sourceAppBestEffort()
        let pending = PendingObservation(
            sourceApp: sourceApp,
            prefilter: prefilterProvider(sourceApp)
        )
        guard observationTask == nil else {
            latestPendingObservation = pending
            clipboardLiveCaptureLogger.debug(
                "stage=observe-coalesced inFlight=1 pending=1"
            )
            return
        }
        startObservation(pending)
    }

    private func startObservation(_ pending: PendingObservation) {
        let generation = serviceGeneration
        let baseline = lastObservedChangeCount
        let startedAt = ContinuousClock.now
        let taskID = UUID()
        guard let task = applicationUpdateGate.task({ @MainActor [weak self] in
            guard let self else { return }
            defer {
                // A cancelled task may finish after stop/start has installed a
                // new generation. Only the task that still owns the slot may
                // clear it or consume the latest-pending observation.
                if self.observationTaskID == taskID {
                    self.observationTask = nil
                    self.observationTaskID = nil
                    if self.serviceGeneration == generation,
                       let latest = self.latestPendingObservation {
                        self.latestPendingObservation = nil
                        self.startObservation(latest)
                    }
                }
            }
            do {
                let result = try await self.broker.observe(
                    ClipboardBrokerObserveRequest(
                        baselineChangeCount: baseline,
                        prefilterDisposition: pending.prefilter.disposition,
                        screenSharingActive: pending.prefilter.screenSharingActive
                    )
                )
                guard !Task.isCancelled, self.serviceGeneration == generation else {
                    Self.discard(result)
                    return
                }
                guard await self.broker.generationIsCurrent(
                    result.brokerGeneration
                ) else {
                    Self.discard(result)
                    return
                }
                self.lastObservedChangeCount = result.observedAfterChangeCount
                if self.captureUnavailable {
                    self.captureUnavailable = false
                    self.onAvailabilityChange?(false)
                }
                if let deferredChangeCount = self.deferredChangeCount,
                   deferredChangeCount != result.changeCount {
                    self.cancelDeferredResolution()
                }
                if result.status != .noChange {
                    Self.performanceSignposter.emitEvent(
                        "Inspect",
                        "status=\(result.status.rawValue, privacy: .public)"
                    )
                }
                await self.handle(
                    result,
                    sourceApp: pending.sourceApp,
                    startedAt: startedAt
                )
            } catch {
                guard !Task.isCancelled, self.serviceGeneration == generation else {
                    return
                }
                guard error as? ClipboardBrokerClientError != .requestSuperseded else { return }
                // A circuit-open response is a degraded service, not a healthy
                // no-change observation. Report once until it really recovers.
                guard !self.captureUnavailable else { return }
                self.captureUnavailable = true
                self.onAvailabilityChange?(true)
                clipboardLiveCaptureLogger.error(
                    "stage=observe-failed elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
                )
            }
        }) else {
            return
        }
        observationTaskID = taskID
        observationTask = task
    }

    private func handle(
        _ result: ClipboardBrokerObservationResult,
        sourceApp: ClipboardRecorderSourceApp?,
        startedAt: ContinuousClock.Instant
    ) async {
        guard await broker.generationIsCurrent(result.brokerGeneration) else {
            Self.discard(result)
            return
        }
        switch result.status {
        case .noChange:
            return
        case .deferred:
            guard let ticket = result.resolutionTicket else { return }
            scheduleDeferredResolution(
                ticket,
                sourceApp: sourceApp,
                serviceGeneration: serviceGeneration,
                startedAt: startedAt
            )
        case .redacted:
            guard let snapshot = Self.makeRedactedSnapshot(
                disposition: result.prefilterDisposition,
                changeCount: result.changeCount,
                sourceApp: sourceApp
            ) else {
                return
            }
            guard await broker.generationIsCurrent(result.brokerGeneration) else {
                Self.discard(result)
                return
            }
            publish(snapshot, startedAt: startedAt)
        case .skipped:
            clipboardLiveCaptureLogger.info(
                "stage=observe-skipped reason=\(result.skipReason?.rawValue ?? "unknown", privacy: .public) changeCount=\(result.changeCount) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
            )
        case .captured:
            guard let representation = result.representation else { return }
            do {
                guard let snapshot = try await Self.makeCapturedSnapshot(
                    representation: representation,
                    changeCount: result.changeCount,
                    sourceApp: sourceApp
                ) else {
                    Self.discard(result)
                    return
                }
                guard !Task.isCancelled,
                      await broker.generationIsCurrent(
                          result.brokerGeneration
                      ) else {
                    Self.discard(result)
                    return
                }
                guard await broker.generationIsCurrent(
                    result.brokerGeneration
                ) else {
                    Self.discard(result)
                    return
                }
                publish(snapshot, startedAt: startedAt)
            } catch {
                clipboardLiveCaptureLogger.error(
                    "stage=payload-import-failed family=\(representation.family.rawValue, privacy: .public) changeCount=\(result.changeCount) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
                )
            }
        }
    }

    private func scheduleDeferredResolution(
        _ ticket: ClipboardBrokerResolutionTicket,
        sourceApp: ClipboardRecorderSourceApp?,
        serviceGeneration generation: UInt64,
        startedAt: ContinuousClock.Instant
    ) {
        cancelDeferredResolution()
        deferredChangeCount = ticket.changeCount
        let taskID = UUID()
        clipboardLiveCaptureLogger.info(
            "stage=deferred changeCount=\(ticket.changeCount) family=\(ticket.family.rawValue, privacy: .public) delayMS=500"
        )
        Self.performanceSignposter.emitEvent(
            "Defer",
            "family=\(ticket.family.rawValue, privacy: .public)"
        )
        guard let task = applicationUpdateGate.task({ @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.resolutionTaskID == taskID {
                    self.resolutionTask = nil
                    self.resolutionTaskID = nil
                    self.deferredChangeCount = nil
                }
            }
            do {
                try await Task.sleep(for: self.deferredInitialDelay)
                try Task.checkCancellation()
                guard self.serviceGeneration == generation else { return }
                clipboardLiveCaptureLogger.info(
                    "stage=resolve-start attempt=1 changeCount=\(ticket.changeCount) family=\(ticket.family.rawValue, privacy: .public)"
                )
                Self.performanceSignposter.emitEvent(
                    "Resolve",
                    "attempt=1 family=\(ticket.family.rawValue, privacy: .public)"
                )
                let result = try await self.broker.resolve(
                    ticket: ticket,
                    timeout: self.deferredFirstTimeout
                )
                try Task.checkCancellation()
                guard self.serviceGeneration == generation else {
                    Self.discard(result)
                    return
                }
                await self.finishDeferredResolution(
                    result,
                    ticket: ticket,
                    sourceApp: sourceApp,
                    startedAt: startedAt,
                    attempt: 1
                )
            } catch ClipboardBrokerClientError.requestTimedOut {
                guard !Task.isCancelled,
                      self.serviceGeneration == generation else {
                    return
                }
                clipboardLiveCaptureLogger.info(
                    "stage=resolve-timeout attempt=1 changeCount=\(ticket.changeCount) retryDelayMS=1500"
                )
                Self.performanceSignposter.emitEvent("Timeout", "attempt=1")
                do {
                    try await Task.sleep(for: self.deferredRetryDelay)
                    try Task.checkCancellation()
                    guard self.serviceGeneration == generation else { return }
                    clipboardLiveCaptureLogger.info(
                        "stage=resolve-start attempt=2 changeCount=\(ticket.changeCount) family=\(ticket.family.rawValue, privacy: .public) timeoutMS=250"
                    )
                    Self.performanceSignposter.emitEvent(
                        "Retry",
                        "attempt=2 family=\(ticket.family.rawValue, privacy: .public)"
                    )
                    let retryResult = try await self.broker.resolve(
                        ticket: ticket,
                        timeout: self.deferredRetryTimeout
                    )
                    try Task.checkCancellation()
                    guard self.serviceGeneration == generation else {
                        Self.discard(retryResult)
                        return
                    }
                    await self.finishDeferredResolution(
                        retryResult,
                        ticket: ticket,
                        sourceApp: sourceApp,
                        startedAt: startedAt,
                        attempt: 2
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    clipboardLiveCaptureLogger.info(
                        "stage=resolve-terminal result=retry-failed changeCount=\(ticket.changeCount) attempts=2"
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                clipboardLiveCaptureLogger.info(
                    "stage=resolve-terminal result=cancelled-or-failed changeCount=\(ticket.changeCount) attempts=1"
                )
            }
        }) else {
            deferredChangeCount = nil
            return
        }
        resolutionTaskID = taskID
        resolutionTask = task
    }

    private func finishDeferredResolution(
        _ result: ClipboardBrokerObservationResult,
        ticket: ClipboardBrokerResolutionTicket,
        sourceApp: ClipboardRecorderSourceApp?,
        startedAt: ContinuousClock.Instant,
        attempt: Int
    ) async {
        guard result.changeCount == ticket.changeCount else {
            Self.discard(result)
            return
        }
        guard await broker.generationIsCurrent(result.brokerGeneration) else {
            Self.discard(result)
            return
        }
        // A stale ticket has not inspected the newer pasteboard version.
        // Preserve the ticket baseline so the next poll observes that change.
        if result.skipReason != .stale {
            lastObservedChangeCount = result.observedAfterChangeCount
        }
        clipboardLiveCaptureLogger.info(
            "stage=resolve-terminal result=\(result.status.rawValue, privacy: .public) changeCount=\(ticket.changeCount) attempts=\(attempt)"
        )
        await handle(
            result,
            sourceApp: sourceApp,
            startedAt: startedAt
        )
    }

    nonisolated private static func discard(
        _ result: ClipboardBrokerObservationResult
    ) {
        ClipboardBrokerDataTransport.removeStagedReference(
            result.representation?.data
        )
    }

    private func publish(
        _ snapshot: ClipboardLiveCaptureSnapshot,
        startedAt: ContinuousClock.Instant
    ) {
        clipboardLiveCaptureLogger.info(
            "stage=external-capture kind=\(snapshot.record.kind.rawValue, privacy: .public) changeCount=\(snapshot.record.changeCount) typeCount=\(snapshot.record.formatSummary.types.count) byteCount=\(snapshot.record.formatSummary.byteCount ?? 0) elapsedMS=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        onCapture?(snapshot)
    }

    private func stopObservationOnly() {
        monitoringActivationTask?.cancel()
        monitoringActivationTask = nil
        timer?.invalidate()
        timer = nil
        serviceGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        observationTaskID = nil
        cancelDeferredResolution()
        latestPendingObservation = nil
    }

    private func cancelDeferredResolution() {
        resolutionTask?.cancel()
        resolutionTask = nil
        resolutionTaskID = nil
        deferredChangeCount = nil
    }

    nonisolated private static func makeRedactedSnapshot(
        disposition: ClipboardBrokerPrefilterDisposition,
        changeCount: Int,
        sourceApp: ClipboardRecorderSourceApp?
    ) -> ClipboardLiveCaptureSnapshot? {
        let reason: ClipboardCaptureSkipReason
        switch disposition {
        case .redactPaused:
            reason = .paused
        case .redactPrivacyUnavailable:
            reason = .privacyPolicyUnavailable
        case .redactExcludedSource:
            reason = .excludedSource
        case .allow:
            return nil
        }
        let now = Date()
        let recordID = recordID(changeCount: changeCount, now: now)
        let signature = signatureSHA256(
            kind: .unknown,
            text: "clipboard-skipped:\(reason.rawValue):\(recordID)"
        )
        return ClipboardLiveCaptureSnapshot(
            record: ClipboardRecorderRecord(
                id: recordID,
                createdAt: now,
                changeCount: changeCount,
                kind: .unknown,
                formatSummary: ClipboardRecorderFormatSummary(
                    itemCount: 1,
                    types: []
                ),
                sourceApp: sourceApp,
                signatureSHA256: signature,
                signatureSHA256_12: String(signature.prefix(12)),
                fixtureOwned: false,
                restorable: false,
                excluded: reason == .privacyPolicyUnavailable
                    || reason == .excludedSource,
                snapshotSkipped: true,
                summary: reason.summaryCode
            ),
            payload: nil
        )
    }

    nonisolated private static func makeCapturedSnapshot(
        representation: ClipboardBrokerCapturedRepresentation,
        changeCount: Int,
        sourceApp: ClipboardRecorderSourceApp?
    ) async throws -> ClipboardLiveCaptureSnapshot? {
        let now = Date()
        let recordID = recordID(changeCount: changeCount, now: now)
        let types = representation.advertisedTypes

        switch representation.family {
        case .fileURL:
            guard let value = representation.value,
                  value.utf8.count <= ClipboardBrokerLimits.maxTextBytes,
                  let url = URL(string: value),
                  url.isFileURL else {
                return nil
            }
            let path = url.path(percentEncoded: false)
            return makeSnapshot(
                recordID: recordID,
                kind: .fileURL,
                payload: ClipboardRecorderPayload(
                    recordID: recordID,
                    kind: .fileURL,
                    text: path,
                    urlString: value
                ),
                changeCount: changeCount,
                createdAt: now,
                types: types,
                byteCount: value.utf8.count,
                fileCount: 1,
                signature: signatureSHA256(kind: .fileURL, text: value),
                summary: shortPreview(path),
                sourceApp: sourceApp
            )

        case .url:
            guard let value = representation.value,
                  value.utf8.count <= ClipboardBrokerLimits.maxTextBytes,
                  let url = URL(string: value),
                  url.scheme != nil,
                  !url.isFileURL else {
                return nil
            }
            return makeSnapshot(
                recordID: recordID,
                kind: .url,
                payload: ClipboardRecorderPayload(
                    recordID: recordID,
                    kind: .url,
                    text: value,
                    urlString: value
                ),
                changeCount: changeCount,
                createdAt: now,
                types: types,
                textLength: value.count,
                byteCount: value.utf8.count,
                urlCount: 1,
                signature: signatureSHA256(kind: .url, text: value),
                summary: shortPreview(value),
                sourceApp: sourceApp
            )

        case .richText:
            guard let reference = representation.data,
                  let text = representation.plainText,
                  !text.isEmpty else {
                return nil
            }
            let rtfData = try await ClipboardBrokerDataTransport.resolve(
                reference,
                maximumByteCount: ClipboardBrokerLimits.maxRTFBytes
            )
            return makeSnapshot(
                recordID: recordID,
                kind: .richText,
                payload: ClipboardRecorderPayload(
                    recordID: recordID,
                    kind: .richText,
                    text: text,
                    rtfData: rtfData
                ),
                changeCount: changeCount,
                createdAt: now,
                types: types,
                textLength: text.count,
                byteCount: rtfData.count,
                signature: signatureSHA256(kind: .richText, bytes: rtfData),
                summary: shortPreview(text),
                sourceApp: sourceApp
            )

        case .text:
            guard let text = representation.value,
                  !text.isEmpty,
                  text.utf8.count <= ClipboardBrokerLimits.maxTextBytes else {
                return nil
            }
            return makeSnapshot(
                recordID: recordID,
                kind: .text,
                payload: ClipboardRecorderPayload(
                    recordID: recordID,
                    kind: .text,
                    text: text
                ),
                changeCount: changeCount,
                createdAt: now,
                types: types,
                textLength: text.count,
                byteCount: text.utf8.count,
                signature: signatureSHA256(kind: .text, text: text),
                summary: shortPreview(text),
                sourceApp: sourceApp
            )

        case .imagePNG, .imageTIFF:
            guard let reference = representation.data else { return nil }
            let pngData = try await ClipboardBrokerDataTransport.resolve(
                reference,
                maximumByteCount: ClipboardBrokerLimits.maxCanonicalPNGBytes
            )
            guard !pngData.isEmpty else { return nil }
            return makeSnapshot(
                recordID: recordID,
                kind: .image,
                payload: ClipboardRecorderPayload(
                    recordID: recordID,
                    kind: .image,
                    pngData: pngData
                ),
                changeCount: changeCount,
                createdAt: now,
                types: types,
                byteCount: pngData.count,
                signature: signatureSHA256(kind: .image, bytes: pngData),
                summary: L10n.format("clipboard.preview.imageBody", pngData.count),
                sourceApp: sourceApp
            )
        }
    }

    nonisolated static func explicitTextSignature(
        _ text: String
    ) -> String {
        signatureSHA256(kind: .text, text: text)
    }

    nonisolated static func makeExplicitTextSnapshot(
        text: String,
        recordID: String,
        changeCount: Int,
        createdAt: Date
    ) -> ClipboardLiveCaptureSnapshot {
        makeSnapshot(
            recordID: recordID,
            kind: .text,
            payload: ClipboardRecorderPayload(
                recordID: recordID,
                kind: .text,
                text: text
            ),
            changeCount: changeCount,
            createdAt: createdAt,
            types: [NSPasteboard.PasteboardType.string.rawValue],
            textLength: text.count,
            byteCount: text.utf8.count,
            signature: explicitTextSignature(text),
            summary: shortPreview(text),
            sourceApp: nil
        )
    }

    nonisolated private static func makeSnapshot(
        recordID: String,
        kind: ClipboardRecorderItemKind,
        payload: ClipboardRecorderPayload?,
        changeCount: Int,
        createdAt: Date,
        types: [String],
        textLength: Int? = nil,
        byteCount: Int? = nil,
        fileCount: Int? = nil,
        urlCount: Int? = nil,
        signature: String,
        summary: String,
        sourceApp: ClipboardRecorderSourceApp?
    ) -> ClipboardLiveCaptureSnapshot {
        ClipboardLiveCaptureSnapshot(
            record: ClipboardRecorderRecord(
                id: recordID,
                createdAt: createdAt,
                changeCount: changeCount,
                kind: kind,
                formatSummary: ClipboardRecorderFormatSummary(
                    itemCount: 1,
                    types: types,
                    textLength: textLength,
                    byteCount: byteCount,
                    fileCount: fileCount,
                    urlCount: urlCount
                ),
                sourceApp: sourceApp,
                signatureSHA256: signature,
                signatureSHA256_12: String(signature.prefix(12)),
                fixtureOwned: false,
                restorable: payload != nil,
                summary: summary
            ),
            payload: payload
        )
    }

    nonisolated private static func recordID(
        changeCount: Int,
        now: Date
    ) -> String {
        "clip_live_\(changeCount)_\(Int(now.timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
    }

    nonisolated private static func signatureSHA256(
        kind: ClipboardRecorderItemKind,
        text: String
    ) -> String {
        signatureSHA256(kind: kind, bytes: Data(text.utf8))
    }

    nonisolated private static func signatureSHA256(
        kind: ClipboardRecorderItemKind,
        bytes: Data
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(kind.rawValue):".utf8))
        hasher.update(data: bytes)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func shortPreview(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.count > 320 ? String(singleLine.prefix(320)) : singleLine
    }

    nonisolated private static func elapsedMilliseconds(
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

    private func sourceAppBestEffort() -> ClipboardRecorderSourceApp? {
        ClipboardWorkspaceContextMonitor.shared.sourceApp
    }
}
