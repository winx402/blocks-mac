import Foundation

enum PermissionDiagnosticKind: String, Equatable {
    case screenRecording
    case accessibility
    case inputMonitoring
}

enum PermissionCodeSigningClassifier {
    // `CS_ADHOC` from <sys/codesign.h>. Keep the value here because Security's
    // Swift overlay does not expose every CodeDirectory flag consistently.
    private static let adHocSigningFlag: UInt32 = 0x0000_0002

    static func signatureKind(
        signingFlags: UInt32?,
        certificateCount: Int?,
        teamID: String?
    ) -> String {
        if signingFlags.map({ $0 & adHocSigningFlag != 0 }) == true {
            return "adhoc"
        }

        // A certificate chain is the evidence that distinguishes a fixed
        // self-signed identity from ad-hoc signing. Team IDs are only issued
        // for Apple-issued identities, so their absence is not ad-hoc proof.
        if certificateCount.map({ $0 > 0 }) == true {
            return teamID == nil ? "signed-no-team" : "signed"
        }
        return "unknown"
    }
}

extension PermissionDiagnosticKind {
    var tccResetService: String? {
        switch self {
        case .screenRecording:
            "ScreenCapture"
        case .accessibility:
            "Accessibility"
        case .inputMonitoring:
            // This recovery flow is intentionally limited to the two services
            // whose targeted reset behavior is documented for this product.
            nil
        }
    }
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

    var manualTCCResetCommand: String? {
        guard
            let service = kind.tccResetService,
            bundleID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
        else {
            return nil
        }
        return "tccutil reset \(service) \(bundleID)"
    }
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
