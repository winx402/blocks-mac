import AppKit
import BlocksCore

enum PermissionRestartResult: Equatable {
    case launched
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
    private let applicationLauncher: (@escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void
    private let applicationTerminator: @MainActor () -> Void

    init(
        applicationLauncher: @escaping (@escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void = { completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration,
                completionHandler: completion
            )
        },
        applicationTerminator: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        }
    ) {
        self.applicationLauncher = applicationLauncher
        self.applicationTerminator = applicationTerminator
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
        let restartHandler = PermissionRestartHandler(
            completion: completion,
            terminator: applicationTerminator
        )
        applicationLauncher { application, error in
            let didLaunch = error == nil && application != nil
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    restartHandler.complete(didLaunch: didLaunch)
                }
            } else {
                Task { @MainActor in
                    restartHandler.complete(didLaunch: didLaunch)
                }
            }
        }
    }
}

@MainActor
private final class PermissionRestartHandler {
    private let completion: (PermissionRestartResult) -> Void
    private let terminator: @MainActor () -> Void

    init(
        completion: @escaping (PermissionRestartResult) -> Void,
        terminator: @escaping @MainActor () -> Void
    ) {
        self.completion = completion
        self.terminator = terminator
    }

    func complete(didLaunch: Bool) {
        guard didLaunch else {
            completion(.failed)
            return
        }
        completion(.launched)
        terminator()
    }
}
