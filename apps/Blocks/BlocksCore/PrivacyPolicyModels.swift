import Foundation

public enum PrivacyPolicySubjectType: String, Codable, CaseIterable, Identifiable {
    case appBundle = "app_bundle"
    case bundleID = "bundle_id"
    case appPath = "app_path"
    case commandPath = "command_path"
    case loginItem = "login_item"
    case helper
    case launchLabel = "launch_label"

    public var id: String { rawValue }
}

public enum PrivacyPolicyStatus: String, Codable, CaseIterable, Identifiable {
    case defaultPolicy = "default"
    case allowed
    case restricted

    public var id: String { rawValue }
}

public enum PrivacyAppSourceDirectory: String, Codable, CaseIterable, Identifiable {
    case applications
    case userApplications = "user_applications"
    case systemApplications = "system_applications"
    case other

    public var id: String { rawValue }
}

public enum PrivacyIdentityIssue: String, Codable, CaseIterable, Identifiable {
    case none
    case duplicateBundleID = "duplicate_bundle_id"
    case missingBundleID = "missing_bundle_id"
    case unreadableBundle = "unreadable_bundle"
    case unsupported

    public var id: String { rawValue }
}

public enum PrivacyAppIconState: String, Codable, CaseIterable, Identifiable {
    case pending
    case loaded
    case failed
    case unsupported

    public var id: String { rawValue }
}

public enum PrivacyPolicyMutationState: String, Codable, CaseIterable, Identifiable {
    case pending
    case saving
    case saved
    case failed
    case retry
    case cancel
    case unsupported

    public var id: String { rawValue }
}

public struct PrivacyPolicySubject: Codable, Equatable, Identifiable {
    public let subjectRef: String
    public let type: PrivacyPolicySubjectType
    public let identifier: String
    public let displayName: String?
    public let pathHash: String?
    public let pathSummary: String?
    public let sourceDirectory: PrivacyAppSourceDirectory?

    public var id: String { subjectRef }

    public init(
        subjectRef: String,
        type: PrivacyPolicySubjectType,
        identifier: String,
        displayName: String? = nil,
        pathHash: String? = nil,
        pathSummary: String? = nil,
        sourceDirectory: PrivacyAppSourceDirectory? = nil
    ) {
        self.subjectRef = subjectRef
        self.type = type
        self.identifier = identifier
        self.displayName = displayName
        self.pathHash = pathHash
        self.pathSummary = pathSummary
        self.sourceDirectory = sourceDirectory
    }
}

public struct PrivacyPolicyRule: Codable, Equatable, Identifiable {
    public let subject: PrivacyPolicySubject
    public let policy: PrivacyPolicyStatus
    public let updatedAt: Date

    public var id: String { subject.subjectRef }

    public init(subject: PrivacyPolicySubject, policy: PrivacyPolicyStatus, updatedAt: Date) {
        self.subject = subject
        self.policy = policy
        self.updatedAt = updatedAt
    }
}

public struct PrivacyAppInstance: Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let subjectRef: String?
    public let canonicalPath: String
    public let pathHash: String
    public let pathSummary: String
    public let sourceDirectory: PrivacyAppSourceDirectory
    public var policyStatus: PrivacyPolicyStatus
    public var identityIssue: PrivacyIdentityIssue
    public var iconState: PrivacyAppIconState

    public init(
        id: String,
        displayName: String,
        bundleIdentifier: String?,
        subjectRef: String?,
        canonicalPath: String = "",
        pathHash: String,
        pathSummary: String,
        sourceDirectory: PrivacyAppSourceDirectory,
        policyStatus: PrivacyPolicyStatus = .defaultPolicy,
        identityIssue: PrivacyIdentityIssue = .none,
        iconState: PrivacyAppIconState = .pending
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.subjectRef = subjectRef
        self.canonicalPath = canonicalPath
        self.pathHash = pathHash
        self.pathSummary = pathSummary
        self.sourceDirectory = sourceDirectory
        self.policyStatus = policyStatus
        self.identityIssue = identityIssue
        self.iconState = iconState
    }
}

public struct PrivacyPolicySnapshot: Codable, Equatable {
    public var allowedBundleIDs: Set<String>
    public var restrictedBundleIDs: Set<String>
    public var allowedAppPathHashes: Set<String>
    public var restrictedAppPathHashes: Set<String>
    public let generatedAt: Date
    public let revision: Int64

    public init(
        allowedBundleIDs: Set<String> = [],
        restrictedBundleIDs: Set<String> = [],
        allowedAppPathHashes: Set<String> = [],
        restrictedAppPathHashes: Set<String> = [],
        generatedAt: Date = Date(),
        revision: Int64 = 0
    ) {
        self.allowedBundleIDs = allowedBundleIDs
        self.restrictedBundleIDs = restrictedBundleIDs
        self.allowedAppPathHashes = allowedAppPathHashes
        self.restrictedAppPathHashes = restrictedAppPathHashes
        self.generatedAt = generatedAt
        self.revision = revision
    }

    public func match(sourceApp: ClipboardRecorderSourceApp?) -> PrivacyPolicyCaptureMatch {
        guard let sourceApp else {
            return PrivacyPolicyCaptureMatch(decision: .allow, matchedRuleType: .defaultRule)
        }
        if let pathHash = sourceApp.bundlePathHash, restrictedAppPathHashes.contains(pathHash) {
            return PrivacyPolicyCaptureMatch(decision: .deny, matchedRuleType: .appPath)
        }
        if let pathHash = sourceApp.bundlePathHash, allowedAppPathHashes.contains(pathHash) {
            return PrivacyPolicyCaptureMatch(decision: .allow, matchedRuleType: .appPath)
        }
        if let bundleIdentifier = sourceApp.bundleIdentifier?.lowercased(), restrictedBundleIDs.contains(bundleIdentifier) {
            return PrivacyPolicyCaptureMatch(decision: .deny, matchedRuleType: .bundleID)
        }
        if let bundleIdentifier = sourceApp.bundleIdentifier?.lowercased(), allowedBundleIDs.contains(bundleIdentifier) {
            return PrivacyPolicyCaptureMatch(decision: .allow, matchedRuleType: .bundleID)
        }
        return PrivacyPolicyCaptureMatch(decision: .allow, matchedRuleType: .defaultRule)
    }
}

public enum PrivacyPolicyCaptureDecision: String, Codable {
    case allow
    case deny
}

public enum PrivacyPolicyMatchedRuleType: String, Codable {
    case appPath = "app_path"
    case bundleID = "bundle_id"
    case defaultRule = "default"
}

public struct PrivacyPolicyCaptureMatch: Codable, Equatable {
    public let decision: PrivacyPolicyCaptureDecision
    public let matchedRuleType: PrivacyPolicyMatchedRuleType

    public init(decision: PrivacyPolicyCaptureDecision, matchedRuleType: PrivacyPolicyMatchedRuleType) {
        self.decision = decision
        self.matchedRuleType = matchedRuleType
    }
}

public struct PrivacyPolicyMutationResult: Codable, Equatable {
    public let subjectRef: String
    public let policyBefore: PrivacyPolicyStatus
    public let policyAfter: PrivacyPolicyStatus
    public let mutationPerformed: Bool
    public let requiresConfirmation: Bool
    public let systemActionUnlocked: Bool

    public init(
        subjectRef: String,
        policyBefore: PrivacyPolicyStatus,
        policyAfter: PrivacyPolicyStatus,
        mutationPerformed: Bool,
        requiresConfirmation: Bool,
        systemActionUnlocked: Bool = false
    ) {
        self.subjectRef = subjectRef
        self.policyBefore = policyBefore
        self.policyAfter = policyAfter
        self.mutationPerformed = mutationPerformed
        self.requiresConfirmation = requiresConfirmation
        self.systemActionUnlocked = systemActionUnlocked
    }
}
