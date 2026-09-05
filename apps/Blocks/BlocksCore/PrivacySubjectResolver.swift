import Foundation

public enum PrivacySubjectResolver {
    public static func subjectRef(type: PrivacyPolicySubjectType, identifier: String) -> String {
        let canonical = canonicalIdentifier(type: type, identifier: identifier)
        return subjectRef(type: type, canonicalIdentifier: canonical)
    }

    public static func canonicalIdentifier(type: PrivacyPolicySubjectType, identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .bundleID:
            return trimmed.lowercased()
        case .appPath, .appBundle, .commandPath:
            return PrivacyPathSanitizer.pathHash(for: trimmed)
        case .loginItem, .helper, .launchLabel:
            return trimmed.lowercased()
        }
    }

    public static func subjectRef(type: PrivacyPolicySubjectType, canonicalIdentifier: String) -> String {
        "sub_v1_\(type.rawValue)_\(PrivacyPathSanitizer.sha256(canonicalIdentifier).prefix(20))"
    }

    public static func type(fromSubjectRef subjectRef: String) -> PrivacyPolicySubjectType? {
        guard subjectRef.hasPrefix("sub_v1_") else {
            return nil
        }
        let tail = subjectRef.dropFirst("sub_v1_".count)
        return PrivacyPolicySubjectType.allCases
            .sorted { $0.rawValue.count > $1.rawValue.count }
            .first { type in tail.hasPrefix(type.rawValue + "_") }
    }

    public static func subject(
        type: PrivacyPolicySubjectType,
        identifier: String,
        displayName: String? = nil
    ) -> PrivacyPolicySubject {
        let canonical = canonicalIdentifier(type: type, identifier: identifier)
        let pathURL = pathURLIfNeeded(type: type, identifier: identifier)
        return PrivacyPolicySubject(
            subjectRef: subjectRef(type: type, canonicalIdentifier: canonical),
            type: type,
            identifier: canonical,
            displayName: displayName ?? displayNameFallback(type: type, identifier: identifier),
            pathHash: pathURL.map { PrivacyPathSanitizer.pathHash(for: $0) },
            pathSummary: pathURL.map { PrivacyPathSanitizer.pathSummary(for: $0) },
            sourceDirectory: pathURL.map { PrivacyPathSanitizer.sourceDirectory(for: $0) }
        )
    }

    public static func bundleSubject(bundleIdentifier: String, displayName: String? = nil) -> PrivacyPolicySubject {
        let canonical = canonicalIdentifier(type: .bundleID, identifier: bundleIdentifier)
        return PrivacyPolicySubject(
            subjectRef: subjectRef(type: .bundleID, canonicalIdentifier: canonical),
            type: .bundleID,
            identifier: canonical,
            displayName: displayName
        )
    }

    public static func appPathSubject(url: URL, displayName: String? = nil) -> PrivacyPolicySubject {
        let hash = PrivacyPathSanitizer.pathHash(for: url)
        return PrivacyPolicySubject(
            subjectRef: subjectRef(type: .appPath, canonicalIdentifier: hash),
            type: .appPath,
            identifier: hash,
            displayName: displayName,
            pathHash: hash,
            pathSummary: PrivacyPathSanitizer.pathSummary(for: url),
            sourceDirectory: PrivacyPathSanitizer.sourceDirectory(for: url)
        )
    }

    public static func appBundleSubject(url: URL, displayName: String? = nil) -> PrivacyPolicySubject {
        let hash = PrivacyPathSanitizer.pathHash(for: url)
        return PrivacyPolicySubject(
            subjectRef: subjectRef(type: .appBundle, canonicalIdentifier: hash),
            type: .appBundle,
            identifier: hash,
            displayName: displayName ?? url.deletingPathExtension().lastPathComponent,
            pathHash: hash,
            pathSummary: PrivacyPathSanitizer.pathSummary(for: url),
            sourceDirectory: PrivacyPathSanitizer.sourceDirectory(for: url)
        )
    }

    public static func subject(from app: PrivacyAppInstance) -> PrivacyPolicySubject {
        if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
            return PrivacyPolicySubject(
                subjectRef: subjectRef(type: .bundleID, identifier: bundleIdentifier),
                type: .bundleID,
                identifier: canonicalIdentifier(type: .bundleID, identifier: bundleIdentifier),
                displayName: app.displayName,
                pathHash: app.pathHash,
                pathSummary: app.pathSummary,
                sourceDirectory: app.sourceDirectory
            )
        }
        return PrivacyPolicySubject(
            subjectRef: subjectRef(type: .appPath, canonicalIdentifier: app.pathHash),
            type: .appPath,
            identifier: app.pathHash,
            displayName: app.displayName,
            pathHash: app.pathHash,
            pathSummary: app.pathSummary,
            sourceDirectory: app.sourceDirectory
        )
    }

    private static func pathURLIfNeeded(type: PrivacyPolicySubjectType, identifier: String) -> URL? {
        switch type {
        case .appPath, .appBundle, .commandPath:
            return URL(fileURLWithPath: identifier)
        case .bundleID, .loginItem, .helper, .launchLabel:
            return nil
        }
    }

    private static func displayNameFallback(type: PrivacyPolicySubjectType, identifier: String) -> String? {
        switch type {
        case .appPath, .appBundle, .commandPath:
            let name = URL(fileURLWithPath: identifier).lastPathComponent
            return name.isEmpty ? nil : name
        case .bundleID, .loginItem, .helper, .launchLabel:
            return identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
