import ApplicationServices
import AppKit
import BlocksCore
import Security

enum PermissionStateService {
    private struct SnapshotContext: Sendable {
        let bundleID: String
        let appPath: String
        let matchingRunningPaths: [String]
        let hasScreenCaptureUsageDescription: Bool
        let screenRecordingGranted: Bool
        let accessibilityGranted: Bool
        let inputMonitoringGranted: Bool
        let capturedAt: Date
    }

    @MainActor
    static func initialSnapshot() -> PermissionStateSnapshot {
        makeSnapshot(
            context: captureContext(),
            signingInfo: (signatureKind: "unknown", teamID: nil)
        )
    }

    @MainActor
    static func snapshot() async -> PermissionStateSnapshot {
        let context = captureContext()
        let signingInfo = await Task.detached(priority: .utility) {
            currentCodeSigningInfo()
        }.value
        return makeSnapshot(context: context, signingInfo: signingInfo)
    }

    @MainActor
    private static func captureContext() -> SnapshotContext {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let appPath = Bundle.main.bundleURL.path
        let matchingRunningPaths = matchingRunningAppPaths(bundleID: bundleID)
        let hasScreenCaptureUsageDescription = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") != nil
        let screenRecordingGranted = ScreenRecordingPermission.isAuthorized
        let accessibilityGranted = AXIsProcessTrusted()
        let inputMonitoringGranted = CGPreflightListenEventAccess()
        return SnapshotContext(
            bundleID: bundleID,
            appPath: appPath,
            matchingRunningPaths: matchingRunningPaths,
            hasScreenCaptureUsageDescription: hasScreenCaptureUsageDescription,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted,
            capturedAt: Date()
        )
    }

    private static func makeSnapshot(
        context: SnapshotContext,
        signingInfo: (signatureKind: String, teamID: String?)
    ) -> PermissionStateSnapshot {
        let screenIssue = PermissionDiagnostics.identityIssue(
            granted: context.screenRecordingGranted,
            signatureKind: signingInfo.signatureKind,
            hasUsageDescription: context.hasScreenCaptureUsageDescription
        )
        let accessibilityIssue = PermissionDiagnostics.identityIssue(
            granted: context.accessibilityGranted,
            signatureKind: signingInfo.signatureKind,
            hasUsageDescription: true
        )
        let inputMonitoringIssue = PermissionDiagnostics.identityIssue(
            granted: context.inputMonitoringGranted,
            signatureKind: signingInfo.signatureKind,
            hasUsageDescription: true
        )
        return PermissionStateSnapshot(
            screenRecording: PermissionDiagnosticSnapshot(
                kind: .screenRecording,
                granted: context.screenRecordingGranted,
                bundleID: context.bundleID,
                appPath: context.appPath,
                signatureKind: signingInfo.signatureKind,
                teamID: signingInfo.teamID,
                hasUsageDescription: context.hasScreenCaptureUsageDescription,
                lastCheckedAt: context.capturedAt,
                recommendedAction: PermissionDiagnostics.recommendedAction(
                    granted: context.screenRecordingGranted,
                    signatureKind: signingInfo.signatureKind,
                    hasUsageDescription: context.hasScreenCaptureUsageDescription,
                    identityIssue: screenIssue
                ),
                matchingRunningAppPaths: context.matchingRunningPaths,
                identityIssue: screenIssue
            ),
            accessibility: PermissionDiagnosticSnapshot(
                kind: .accessibility,
                granted: context.accessibilityGranted,
                bundleID: context.bundleID,
                appPath: context.appPath,
                signatureKind: signingInfo.signatureKind,
                teamID: signingInfo.teamID,
                hasUsageDescription: true,
                lastCheckedAt: context.capturedAt,
                recommendedAction: PermissionDiagnostics.recommendedAction(
                    granted: context.accessibilityGranted,
                    signatureKind: signingInfo.signatureKind,
                    hasUsageDescription: true,
                    identityIssue: accessibilityIssue
                ),
                matchingRunningAppPaths: context.matchingRunningPaths,
                identityIssue: accessibilityIssue
            ),
            inputMonitoring: PermissionDiagnosticSnapshot(
                kind: .inputMonitoring,
                granted: context.inputMonitoringGranted,
                bundleID: context.bundleID,
                appPath: context.appPath,
                signatureKind: signingInfo.signatureKind,
                teamID: signingInfo.teamID,
                hasUsageDescription: true,
                lastCheckedAt: context.capturedAt,
                recommendedAction: PermissionDiagnostics.recommendedAction(
                    granted: context.inputMonitoringGranted,
                    signatureKind: signingInfo.signatureKind,
                    hasUsageDescription: true,
                    identityIssue: inputMonitoringIssue
                ),
                matchingRunningAppPaths: context.matchingRunningPaths,
                identityIssue: inputMonitoringIssue
            ),
            capturedAt: context.capturedAt
        )
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    @MainActor
    private static func matchingRunningAppPaths(bundleID: String) -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .compactMap { $0.bundleURL?.path }
            .uniqued()
            .sorted()
    }

    nonisolated private static func currentCodeSigningInfo() -> (signatureKind: String, teamID: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
              let code else {
            return ("unknown", nil)
        }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        ) == errSecSuccess,
              let info = rawInfo as? [String: Any] else {
            return ("unknown", nil)
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        return (teamID == nil ? "adhoc" : "signed", teamID)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
