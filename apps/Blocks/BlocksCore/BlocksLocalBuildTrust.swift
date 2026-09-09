import Foundation
import Security
import Darwin

/// Certificate-free trust is an explicit build policy, never a fallback for a
/// failed production Team-ID check. The local developer owns this installation;
/// it is not a security boundary against an administrator or that same developer.
public enum BlocksLocalBuildTrust {
    public struct Peer: Codable, Equatable, Sendable {
        public let role: String
        public let identifier: String
        public let relativeExecutablePath: String
        public let cdHash: String
    }

    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let appBundlePath: String
        public let peers: [Peer]
    }

    public static var manifestURL: URL? {
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Blocks Dev/Installation/peers.json")
        #else
        return nil
        #endif
    }

    public static func accepts(processIdentifier: pid_t, userIdentifier: uid_t, role: String) -> Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard processIdentifier > 0, userIdentifier == getuid(),
              let manifest = loadManifest(),
              let expected = manifest.peers.first(where: { $0.role == role }) else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return matches(staticCode: staticCode, expected: expected, root: manifest.appBundlePath)
        #else
        return false
        #endif
    }

    /// The token comes from the already connected AF_UNIX socket, never a PID
    /// supplied in a request. Security.framework binds it to that process
    /// incarnation, including the audit token's PID version.
    public static func accepts(connectedSocket: Int32, role: String) -> Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(connectedSocket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size,
              token.val.1 == getuid(), token.val.3 == getuid(),
              let manifest = loadManifest(),
              let expected = manifest.peers.first(where: { $0.role == role }) else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        return matches(staticCode: staticCode, expected: expected, root: manifest.appBundlePath)
        #else
        return false
        #endif
    }

    /// Applied to an XPC connection before resume, binding every message to
    /// the registered build rather than relying only on a reusable PID.
    public static func connectionRequirement(role: String) -> String? {
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard let manifest = loadManifest(),
              let peer = manifest.peers.first(where: { $0.role == role }) else { return nil }
        return "identifier \"\(peer.identifier)\" and cdhash H\"\(peer.cdHash)\""
        #else
        return nil
        #endif
    }

    public static func accepts(executableURL: URL, role: String) -> Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard let manifest = loadManifest(),
              let expected = manifest.peers.first(where: { $0.role == role }),
              executableURL.standardizedFileURL.path == URL(fileURLWithPath: manifest.appBundlePath)
                .appendingPathComponent(expected.relativeExecutablePath).standardizedFileURL.path else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        return matches(staticCode: code, expected: expected, root: manifest.appBundlePath)
        #else
        return false
        #endif
    }

    #if BLOCKS_LOCAL_DEVELOPMENT
    private static func loadManifest() -> Manifest? {
        guard let url = manifestURL,
              let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let expectedRoot = URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Applications/Blocks.app").path
        return loadManifest(at: url, expectedRoot: expectedRoot)
    }

    // Internal reader seam for isolated filesystem tests. Public trust entry
    // points always use the fixed login-home path above, never caller input.
    static func loadManifest(at url: URL, expectedRoot: String) -> Manifest? {
        guard let data = readPrivateManifest(url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.peers.count == 4,
              Set(manifest.peers.map(\.role)).count == manifest.peers.count else { return nil }
        let layout = [
            "app": ("app.blocks.dev", "Contents/MacOS/Blocks"),
            "cli": ("app.blocks.dev.cli", "Contents/Resources/CLI/blocks"),
            "broker": ("app.blocks.dev.action-broker", "Contents/MacOS/BlocksActionBroker"),
            "helper": ("app.blocks.dev.selection-helper", "Contents/Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper"),
        ]
        guard manifest.appBundlePath == expectedRoot,
              manifest.peers.allSatisfy({ peer in
                  guard let expected = layout[peer.role] else { return false }
                  return peer.identifier == expected.0
                    && peer.relativeExecutablePath == expected.1
                    && peer.cdHash.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil
              }) else { return nil }
        return manifest
    }

    private static func readPrivateManifest(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 32_768 else { return nil }
        for directory in [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()] {
            var parent = stat()
            guard lstat(directory.path, &parent) == 0,
                  parent.st_uid == getuid(), parent.st_mode & S_IFMT == S_IFDIR,
                  parent.st_mode & 0o022 == 0 else { return nil }
        }
        var buffer = [UInt8](repeating: 0, count: 32_769)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0, count == info.st_size, count <= 32_768 else { return nil }
        return Data(buffer.prefix(count))
    }

    private static func matches(staticCode: SecStaticCode, expected: Peer, root: String) -> Bool {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let information = raw as? [CFString: Any],
              let identifier = information[kSecCodeInfoIdentifier] as? String,
              let hash = information[kSecCodeInfoUnique] as? Data,
              let executable = information[kSecCodeInfoMainExecutable] as? URL else { return false }
        let expectedURL = URL(fileURLWithPath: root).appendingPathComponent(expected.relativeExecutablePath).standardizedFileURL
        return identifier == expected.identifier
            && hash.map { String(format: "%02x", $0) }.joined() == expected.cdHash
            && executable.standardizedFileURL == expectedURL
            && executable.resolvingSymlinksInPath() == expectedURL
    }
    #endif
}
