import CryptoKit
import Foundation

public enum PrivacyPathSanitizer {
    public static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func pathHash(for path: String) -> String {
        sha256(standardizedPath(path))
    }

    public static func pathHash(for url: URL) -> String {
        pathHash(for: url.standardizedFileURL.path)
    }

    public static func pathSummary(for path: String) -> String {
        let standardized = standardizedPath(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if standardized == home {
            return "~"
        }
        if standardized.hasPrefix(home + "/") {
            return "~/" + standardized.dropFirst(home.count + 1)
        }
        if standardized.hasPrefix("/System/Applications/") {
            return "System Applications/" + URL(fileURLWithPath: standardized).lastPathComponent
        }
        if standardized.hasPrefix("/Applications/") {
            return "Applications/" + URL(fileURLWithPath: standardized).lastPathComponent
        }
        return standardized
    }

    public static func pathSummary(for url: URL) -> String {
        pathSummary(for: url.standardizedFileURL.path)
    }

    public static func sourceDirectory(for url: URL) -> PrivacyAppSourceDirectory {
        let path = standardizedPath(url.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path.hasPrefix(home + "/Applications/") || path == home + "/Applications" {
            return .userApplications
        }
        if path.hasPrefix("/System/Applications/") || path == "/System/Applications" {
            return .systemApplications
        }
        if path.hasPrefix("/Applications/") || path == "/Applications" {
            return .applications
        }
        return .other
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
