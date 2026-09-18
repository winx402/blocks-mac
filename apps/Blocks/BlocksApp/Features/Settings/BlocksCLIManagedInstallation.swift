import AppKit
import BlocksCore
import Darwin
import Foundation
import Security

/// The only UI boundary for first-use sandbox authorization. The caller owns
/// the security-scoped access lifetime and the existing installer transaction.
@MainActor
enum BlocksCLIDirectoryAuthorization {
    static func request(_ suggestedDirectory: URL) async -> URL? {
        let request = Request(suggestedDirectory: suggestedDirectory)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.begin(continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    @MainActor
    private final class Request {
        private let panel = NSOpenPanel()
        private var continuation: CheckedContinuation<URL?, Never>?
        private var cancelled = false

        init(suggestedDirectory: URL) {
            panel.title = L10n.string("settings.agentCLI.install.directoryAuthorization.title")
            panel.message = L10n.string("settings.agentCLI.install.directoryAuthorization.detail")
            panel.prompt = L10n.string("settings.agentCLI.install.directoryAuthorization.allow")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.showsHiddenFiles = true
            panel.directoryURL = suggestedDirectory
        }

        func begin(_ continuation: CheckedContinuation<URL?, Never>) {
            guard !cancelled, !Task.isCancelled else { continuation.resume(returning: nil); return }
            self.continuation = continuation
            panel.begin { [self] response in
                finish(response == .OK && !cancelled ? panel.url : nil)
            }
        }

        func cancel() {
            cancelled = true
            panel.cancel(nil)
            finish(nil)
        }

        private func finish(_ url: URL?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: url)
        }
    }
}

enum BlocksCLIManagedInstallationEnvironment {
    static var loginHomeDirectory: URL? {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static var requiresDirectoryAuthorization: Bool {
        // Official builds always use explicit directory authorization. Local
        // builds may also be sandboxed; unknown signing state fails closed.
        guard BlocksRuntimeIdentity.isLocalDevelopment else { return true }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return true }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return entitlements?["com.apple.security.app-sandbox"] as? Bool == true
    }

    /// Walk every component without following symlinks. Newly created entries
    /// are private, user-owned directories; existing directory modes are never
    /// changed. A directory selected by the user must already exist.
    static func prepareDirectory(_ directory: URL, createMissing: Bool) -> Bool {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { return false }
        // Foundation's standardizedFileURL rewrites canonical /private/var
        // paths to the /var symlink on macOS. Preserve the supplied path so our
        // no-follow walk neither introduces nor silently resolves symlinks.
        let components = directory.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty,
              !components.contains("."), !components.contains("..") else { return false }
        // Search-only directory descriptors do not request directory listing
        // access for ancestors outside a sandbox's selected security scope.
        var descriptor = open("/", O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        for (index, component) in components.enumerated() {
            var next = openat(descriptor, component, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, errno == ENOENT, createMissing {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { return false }
                next = openat(descriptor, component, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { return false }
            var info = stat()
            guard fstat(next, &info) == 0 else { close(next); return false }
            let isDestination = index == components.count - 1
            let owned = info.st_uid == getuid()
            // Root-owned system ancestors are expected. Sticky temporary roots
            // are permitted as ancestors for isolated tests, never destinations.
            let protectedAncestor = (owned || info.st_uid == 0)
                && (info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0)
            guard isDestination ? (owned && info.st_mode & 0o022 == 0) : protectedAncestor else {
                close(next)
                return false
            }
            close(descriptor)
            descriptor = next
        }
        return true
    }
}
