import Foundation

public struct PrivacyAppScanRoot: Equatable {
    public let url: URL
    public let sourceDirectory: PrivacyAppSourceDirectory

    public init(url: URL, sourceDirectory: PrivacyAppSourceDirectory) {
        self.url = url
        self.sourceDirectory = sourceDirectory
    }
}

public protocol PrivacyAppScanning {
    func scan(roots: [PrivacyAppScanRoot], maxDepth: Int) throws -> [PrivacyAppInstance]
}

public struct PrivacyAppScanner: PrivacyAppScanning {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func defaultRoots(fileManager: FileManager = .default) -> [PrivacyAppScanRoot] {
        let homeApplications = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        return [
            PrivacyAppScanRoot(url: URL(fileURLWithPath: "/Applications", isDirectory: true), sourceDirectory: .applications),
            PrivacyAppScanRoot(url: homeApplications, sourceDirectory: .userApplications),
            PrivacyAppScanRoot(url: URL(fileURLWithPath: "/System/Applications", isDirectory: true), sourceDirectory: .systemApplications),
        ]
    }

    public func scan(roots: [PrivacyAppScanRoot] = PrivacyAppScanner.defaultRoots(), maxDepth: Int = 2) throws -> [PrivacyAppInstance] {
        let boundedDepth = max(0, min(maxDepth, 2))
        var apps: [PrivacyAppInstance] = []
        for root in roots {
            guard !isSymbolicLink(root.url), directoryExists(root.url) else {
                continue
            }
            try scanDirectory(root.url, sourceDirectory: root.sourceDirectory, depth: 0, maxDepth: boundedDepth, output: &apps)
        }
        return annotateDuplicateBundleIDs(apps)
            .sorted { lhs, rhs in
                if lhs.displayName == rhs.displayName {
                    return lhs.pathSummary < rhs.pathSummary
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func scanDirectory(
        _ directory: URL,
        sourceDirectory: PrivacyAppSourceDirectory,
        depth: Int,
        maxDepth: Int,
        output: inout [PrivacyAppInstance]
    ) throws {
        guard depth <= maxDepth else {
            return
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents {
            if isSymbolicLink(url) {
                continue
            }
            if url.pathExtension.lowercased() == "app" {
                output.append(appInstance(url: url, sourceDirectory: sourceDirectory))
                continue
            }
            guard depth < maxDepth, directoryExists(url) else {
                continue
            }
            try scanDirectory(url, sourceDirectory: sourceDirectory, depth: depth + 1, maxDepth: maxDepth, output: &output)
        }
    }

    private func appInstance(url: URL, sourceDirectory: PrivacyAppSourceDirectory) -> PrivacyAppInstance {
        let pathHash = PrivacyPathSanitizer.pathHash(for: url)
        let info = appInfo(url: url)
        let displayName = info.displayName ?? url.deletingPathExtension().lastPathComponent
        let identityIssue: PrivacyIdentityIssue = {
            if info.unreadable {
                return .unreadableBundle
            }
            if info.bundleIdentifier == nil || info.bundleIdentifier?.isEmpty == true {
                return .missingBundleID
            }
            return .none
        }()
        return PrivacyAppInstance(
            id: pathHash,
            displayName: displayName,
            bundleIdentifier: info.bundleIdentifier,
            subjectRef: info.bundleIdentifier.map { PrivacySubjectResolver.subjectRef(type: .bundleID, identifier: $0) }
                ?? PrivacySubjectResolver.subjectRef(type: .appPath, canonicalIdentifier: pathHash),
            canonicalPath: url.standardizedFileURL.path,
            pathHash: pathHash,
            pathSummary: PrivacyPathSanitizer.pathSummary(for: url),
            sourceDirectory: sourceDirectory,
            policyStatus: .defaultPolicy,
            identityIssue: identityIssue,
            iconState: .pending
        )
    }

    private func appInfo(url: URL) -> (displayName: String?, bundleIdentifier: String?, unreadable: Bool) {
        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let dictionary = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return (nil, nil, true)
        }
        let displayName = dictionary["CFBundleDisplayName"] as? String
            ?? dictionary["CFBundleName"] as? String
        let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String
        return (displayName, bundleIdentifier, false)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private func annotateDuplicateBundleIDs(_ apps: [PrivacyAppInstance]) -> [PrivacyAppInstance] {
        let counts = Dictionary(grouping: apps.compactMap(\.bundleIdentifier), by: { $0 })
            .mapValues(\.count)
        return apps.map { app in
            guard let bundleIdentifier = app.bundleIdentifier, counts[bundleIdentifier, default: 0] > 1 else {
                return app
            }
            var duplicate = app
            duplicate.identityIssue = .duplicateBundleID
            return duplicate
        }
    }
}
