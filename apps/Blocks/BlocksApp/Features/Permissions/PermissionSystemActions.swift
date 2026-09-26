import AppKit
import BlocksCore

enum PermissionRestartResult: Equatable {
    /// A separate launcher has accepted the handoff. The app has not quit yet.
    case scheduled
    case failed
}

@MainActor
struct DefaultPermissionSnapshotProvider: PermissionSnapshotProviding {
    typealias UnitTestHostCheck = @MainActor () -> Bool
    typealias LiveInitialSnapshot = @MainActor () -> PermissionStateSnapshot
    typealias LiveSnapshot = @MainActor () async -> PermissionStateSnapshot

    private let isUnitTestHost: UnitTestHostCheck
    private let unitTestSnapshot: PermissionStateSnapshot
    private let liveInitialSnapshot: LiveInitialSnapshot
    private let liveSnapshot: LiveSnapshot

    init(
        isUnitTestHost: @escaping UnitTestHostCheck = {
            BlocksRuntimeEnvironment.isUnitTestHost
        },
        unitTestSnapshot: PermissionStateSnapshot? = nil,
        liveInitialSnapshot: @escaping LiveInitialSnapshot = {
            PermissionStateService.initialSnapshot()
        },
        liveSnapshot: @escaping LiveSnapshot = {
            await PermissionStateService.snapshot()
        }
    ) {
        self.isUnitTestHost = isUnitTestHost
        self.unitTestSnapshot = unitTestSnapshot ?? Self.makeUnitTestSnapshot()
        self.liveInitialSnapshot = liveInitialSnapshot
        self.liveSnapshot = liveSnapshot
    }

    func initialSnapshot() -> PermissionStateSnapshot {
        guard !isUnitTestHost() else { return unitTestSnapshot }
        return liveInitialSnapshot()
    }

    func snapshot() async -> PermissionStateSnapshot {
        guard !isUnitTestHost() else { return unitTestSnapshot }
        return await liveSnapshot()
    }

    private static func makeUnitTestSnapshot() -> PermissionStateSnapshot {
        let capturedAt = Date()
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let appPath = Bundle.main.bundleURL.path
        func diagnostic(
            _ kind: PermissionDiagnosticKind,
            hasUsageDescription: Bool = true
        ) -> PermissionDiagnosticSnapshot {
            PermissionDiagnosticSnapshot(
                kind: kind,
                granted: false,
                bundleID: bundleID,
                appPath: appPath,
                signatureKind: "unknown",
                teamID: nil,
                hasUsageDescription: hasUsageDescription,
                lastCheckedAt: capturedAt,
                recommendedAction: .requestInSystemSettings,
                matchingRunningAppPaths: [],
                identityIssue: .none
            )
        }
        return PermissionStateSnapshot(
            screenRecording: diagnostic(
                .screenRecording,
                hasUsageDescription:
                    Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") != nil
            ),
            accessibility: diagnostic(.accessibility),
            inputMonitoring: diagnostic(.inputMonitoring),
            capturedAt: capturedAt
        )
    }
}

@MainActor
struct DefaultPermissionAccessRequester: PermissionAccessRequesting {
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        PermissionStateService.requestScreenRecordingAccess()
    }

    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        PermissionStateService.requestAccessibilityAccess()
    }

    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        PermissionStateService.requestInputMonitoringAccess()
    }
}

@MainActor
final class DefaultPermissionAssistPresenter: PermissionAssistPresenting {
    private let presenter: PermissionAssistPanelPresenter

    init(presenter: PermissionAssistPanelPresenter? = nil) {
        self.presenter = presenter ?? PermissionAssistPanelPresenter()
    }

    func present(kind: PermissionAssistKind, onRefresh: @escaping () -> Void) {
        presenter.present(kind: kind, onFlowEnded: onRefresh)
    }
}

@MainActor
struct DefaultPermissionSystemActions: PermissionSystemActioning {
    typealias Relauncher = @MainActor (URL, pid_t, @escaping @Sendable (pid_t?, Error?) -> Void) -> Void

    private let relauncher: Relauncher
    private let applicationTerminator: @MainActor () -> Void
    private let bundleURL: URL
    private let processID: pid_t
    private let restartGate = PermissionRestartGate()

    init(
        relauncher: @escaping Relauncher = { bundleURL, processID, completion in
            PermissionRelaunchProcess.launch(
                bundleURL: bundleURL,
                parentProcessID: processID,
                completion: completion
            )
        },
        applicationTerminator: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        },
        bundleURL: URL = Bundle.main.bundleURL,
        processID: pid_t = getpid()
    ) {
        self.relauncher = relauncher
        self.applicationTerminator = applicationTerminator
        self.bundleURL = bundleURL
        self.processID = processID
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func restartForPermissionRefresh(
        completion: @escaping (PermissionRestartResult) -> Void
    ) {
        guard restartGate.enqueue(completion) else { return }
        let restartHandler = PermissionRestartHandler(
            terminator: applicationTerminator,
            restartGate: restartGate,
            parentProcessID: processID
        )
        relauncher(bundleURL, processID) { childProcessID, error in
            let didStart = error == nil
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    restartHandler.complete(childProcessID: childProcessID, didStart: didStart)
                }
            } else {
                Task { @MainActor in
                    restartHandler.complete(childProcessID: childProcessID, didStart: didStart)
                }
            }
        }
    }
}

@MainActor
private final class PermissionRestartGate {
    private var hasRequest = false
    private var result: PermissionRestartResult?
    private var callbacks: [(PermissionRestartResult) -> Void] = []

    /// Returns true only for the first request. Concurrent taps receive the
    /// same eventual result rather than a premature success indication.
    func enqueue(_ completion: @escaping (PermissionRestartResult) -> Void) -> Bool {
        if let result {
            completion(result)
            return false
        }
        callbacks.append(completion)
        guard !hasRequest else { return false }
        hasRequest = true
        return true
    }

    func resolve(_ result: PermissionRestartResult) {
        self.result = result == .scheduled ? result : nil
        hasRequest = result == .scheduled
        let callbacks = self.callbacks
        self.callbacks.removeAll()
        callbacks.forEach { $0(result) }
    }
}

@MainActor
private final class PermissionRestartHandler {
    private let terminator: @MainActor () -> Void
    private let restartGate: PermissionRestartGate
    private let parentProcessID: pid_t
    private var hasCompleted = false

    init(
        terminator: @escaping @MainActor () -> Void,
        restartGate: PermissionRestartGate,
        parentProcessID: pid_t
    ) {
        self.terminator = terminator
        self.restartGate = restartGate
        self.parentProcessID = parentProcessID
    }

    func complete(childProcessID: pid_t?, didStart: Bool) {
        guard !hasCompleted else { return }
        hasCompleted = true
        guard didStart,
              let childProcessID,
              childProcessID > 0,
              childProcessID != parentProcessID else {
            restartGate.resolve(.failed)
            return
        }
        restartGate.resolve(.scheduled)
        terminator()
    }
}
