import Foundation

enum PermissionDiagnosticKind: String, Equatable {
    case screenRecording
    case accessibility
    case inputMonitoring
}

enum PermissionRecommendedAction: String, Equatable {
    case granted
    case requestInSystemSettings
    case reopenApp
    case stableSigningRecommended
    case signingOrIdentityMismatch
}

struct PermissionDiagnosticSnapshot: Equatable {
    let kind: PermissionDiagnosticKind
    let granted: Bool
    let bundleID: String
    let appPath: String
    let signatureKind: String
    let teamID: String?
    let hasUsageDescription: Bool
    let lastCheckedAt: Date
    let recommendedAction: PermissionRecommendedAction
    let matchingRunningAppPaths: [String]
    let identityIssue: PermissionDiagnosticIdentityIssue
}

enum PermissionDiagnosticIdentityIssue: String, Equatable {
    case none
    case adHocSigned
    case missingUsageDescription
    case signingOrIdentityMismatch
}

struct PermissionStateSnapshot: Equatable {
    let screenRecording: PermissionDiagnosticSnapshot
    let accessibility: PermissionDiagnosticSnapshot
    let inputMonitoring: PermissionDiagnosticSnapshot
    let capturedAt: Date

    var screenRecordingGranted: Bool {
        screenRecording.granted
    }

    var accessibilityGranted: Bool {
        accessibility.granted
    }

    var inputMonitoringGranted: Bool {
        inputMonitoring.granted
    }

    var codeSigningTeamIdentifier: String? {
        screenRecording.teamID
    }

    var isAdHocSigned: Bool {
        screenRecording.signatureKind == "adhoc"
    }

    var screenRecordingRestartLikely: Bool {
        !screenRecordingGranted && isAdHocSigned
    }
}

enum PermissionDiagnostics {
    static func recommendedAction(
        granted: Bool,
        signatureKind: String,
        hasUsageDescription: Bool,
        identityIssue: PermissionDiagnosticIdentityIssue
    ) -> PermissionRecommendedAction {
        if granted {
            return .granted
        }
        if identityIssue == .signingOrIdentityMismatch {
            return .signingOrIdentityMismatch
        }
        if signatureKind == "adhoc" {
            return .stableSigningRecommended
        }
        if !hasUsageDescription {
            return .reopenApp
        }
        return .requestInSystemSettings
    }

    static func identityIssue(
        granted: Bool,
        signatureKind: String,
        hasUsageDescription: Bool
    ) -> PermissionDiagnosticIdentityIssue {
        if granted {
            return .none
        }
        if !hasUsageDescription {
            return .missingUsageDescription
        }
        if signatureKind == "adhoc" {
            return .signingOrIdentityMismatch
        }
        return .none
    }
}
