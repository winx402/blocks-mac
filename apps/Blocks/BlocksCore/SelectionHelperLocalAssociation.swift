import Foundation
import CryptoKit
import Darwin
import Security

/// This protocol is deliberately not a second command transport. Its only
/// operations are read-only status and a one-time, code-identity-authorized
/// bootstrap of the existing authenticated pairing protocol.
public enum SelectionHelperLocalAssociation {
    public static let version = 1
    /// Non-secret, durable opt-out. It is deliberately independent of the
    /// expiring acknowledgement that contains the old disconnect key.
    public static let disabledKeychainService = "\(BlocksSelectionHelperProtocol.keychainService).automatic-association-disabled"
    public static let disabledKeychainAccount = "v1"
    public static let disabledMarker = Data([1])

    /// nil means unreadable or malformed; false alone means confirmed absent.
    public static func disabledMarkerPresence(
        query: [String: Any], copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) -> Bool? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copy(read as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess, result as? Data == disabledMarker else { return nil }
        return true
    }

    /// Only the non-secret opt-out item is handled here. Both stores supply
    /// their existing no-UI, build-specific shared Keychain query and calls.
    public static func persistDisabledMarker(
        query: [String: Any],
        copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
        add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) -> Bool {
        var item = query
        item[kSecValueData as String] = disabledMarker
        let status = add(item as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return copy(read as CFDictionary, &result) == errSecSuccess && result as? Data == disabledMarker
    }

    public static func clearDisabledMarkerForExplicitOptIn(
        query: [String: Any],
        copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
        delete: (CFDictionary) -> OSStatus
    ) -> Bool {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copy(read as CFDictionary, &result)
        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess, result as? Data == disabledMarker else { return false }
        let removed = delete(query as CFDictionary)
        return removed == errSecSuccess || removed == errSecItemNotFound
    }
    public struct Intent: Codable, Equatable, Sendable {
        public let nonce: String
        public let generation: UInt64
        public let expiresAt: Date
    }
    public struct Request: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case status, authorize, pair, disable }
        public let version: Int
        public let kind: Kind
        public let requestID: String
        public let clientPublicKey: Data?
        public let pairRequest: SelectionHelperPairRequest?
        public let intent: Intent?
        public init(kind: Kind, requestID: String, clientPublicKey: Data? = nil,
                    pairRequest: SelectionHelperPairRequest? = nil, intent: Intent? = nil) {
            version = SelectionHelperLocalAssociation.version
            self.kind = kind
            self.requestID = requestID
            self.clientPublicKey = clientPublicKey
            self.pairRequest = pairRequest
            self.intent = intent
        }
    }
    public struct Authorization: Codable, Sendable {
        public let requestID: String
        public let clientPublicKey: Data
        public let generation: UInt64
        public let expiresAt: Date
        public let code: String
        public let bootstrapKey: Data
    }
    public struct Response: Codable, Sendable {
        public let version: Int
        public let isPaired: Bool
        public let authorization: Authorization?
        public let pairPacket: Data?
        public let intent: Intent?
        public let automaticAssociationDisabled: Bool?
        public init(isPaired: Bool, authorization: Authorization? = nil, pairPacket: Data? = nil,
                    intent: Intent? = nil, automaticAssociationDisabled: Bool? = nil) {
            version = SelectionHelperLocalAssociation.version
            self.isPaired = isPaired
            self.authorization = authorization
            self.pairPacket = pairPacket
            self.intent = intent
            self.automaticAssociationDisabled = automaticAssociationDisabled
        }
    }

    /// Confined to the Helper's serial pairing queue. A bounded single grant
    /// cannot accumulate memory or authorize a different transcript. Removal
    /// precedes verification/commit: even a failed attempt spends the grant.
    public struct Authority {
        private var pending: Authorization?
        private var pendingPeerToken: Data?
        private struct PendingIntent {
            let value: Intent
            let requestID: String
            let publicKey: Data
            let peerToken: Data
        }
        private var pendingIntent: PendingIntent?
        public init() {}
        public mutating func invalidate() {
            pending = nil
            pendingPeerToken = nil
            pendingIntent = nil
        }
        public mutating func issueIntent(requestID: String, clientPublicKey: Data,
                                         generation: UInt64, isPaired: Bool, now: Date,
                                         peerToken: Data) -> Intent? {
            guard !isPaired, UUID(uuidString: requestID) != nil,
                  peerToken.count == MemoryLayout<audit_token_t>.size,
                  (try? P256.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey)) != nil else { return nil }
            invalidate()
            let value = Intent(nonce: UUID().uuidString, generation: generation, expiresAt: now.addingTimeInterval(5))
            pendingIntent = .init(value: value, requestID: requestID, publicKey: clientPublicKey, peerToken: peerToken)
            return value
        }
        /// Comparison, consumption, marker clearing and grant issue are all on
        /// the Helper pairing queue. A reset/disable invalidates this nonce.
        public mutating func consumeIntent(_ intent: Intent, requestID: String, clientPublicKey: Data,
                                           generation: UInt64, isPaired: Bool, now: Date,
                                           peerToken: Data) -> Bool {
            let expected = pendingIntent
            pendingIntent = nil
            guard let expected, expected.value == intent, !isPaired,
                  intent.generation == generation, now < intent.expiresAt,
                  now >= intent.expiresAt.addingTimeInterval(-5),
                  expected.requestID == requestID, expected.publicKey == clientPublicKey,
                  expected.peerToken == peerToken else { return false }
            return true
        }
        public mutating func issue(requestID: String, clientPublicKey: Data,
                                   generation: UInt64, isPaired: Bool, now: Date,
                                   peerToken: Data? = nil) -> Authorization? {
            #if !BLOCKS_LOCAL_DEVELOPMENT
            guard peerToken?.count == MemoryLayout<audit_token_t>.size else { return nil }
            #endif
            guard !isPaired, UUID(uuidString: requestID) != nil,
                  (try? P256.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey)) != nil else { return nil }
            var bytes = Data(count: 36)
            let status = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard status == errSecSuccess else { return nil }
            // V4's existing HMAC transcript accepts exactly six decimal
            // digits. This field is a transcript nonce, NOT the authority:
            // authentication still requires the independent 256-bit secret,
            // verified code identity, and the bound request/key/generation.
            let codeValue = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let grant = Authorization(requestID: requestID, clientPublicKey: clientPublicKey,
                                      generation: generation, expiresAt: now.addingTimeInterval(5),
                                      code: String(format: "%06u", codeValue % 1_000_000),
                                      bootstrapKey: Data(bytes.prefix(32)))
            pending = grant
            pendingPeerToken = peerToken
            return grant
        }
        public mutating func consume(request: SelectionHelperPairRequest,
                                     generation: UInt64, isPaired: Bool, now: Date,
                                     peerToken: Data? = nil) -> Authorization? {
            let grant = pending
            let expectedPeer = pendingPeerToken
            pending = nil
            pendingPeerToken = nil
            guard let grant, expectedPeer == peerToken, !isPaired, grant.generation == generation,
                  now < grant.expiresAt, now >= grant.expiresAt.addingTimeInterval(-5),
                  request.protocolVersion == BlocksSelectionHelperProtocol.version,
                  request.requestID == grant.requestID, request.clientPublicKey == grant.clientPublicKey,
                  request.pairingCode == grant.code else { return nil }
            return grant
        }
    }
}

/// Bounded blocking I/O, used only from background queues. No fallback to TCP
/// or PID-only trust is permitted when the local peer cannot be authenticated.
public enum SelectionHelperLocalAssociationTransport {
    private static let maximumFrameBytes = 16_384
    private static let socketName = "helper.sock"
    private static var directoryPath: String? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        #if BLOCKS_LOCAL_DEVELOPMENT
        return String(cString: home) + "/Library/Application Support/Blocks Dev/Association"
        #else
        let library = String(cString: home) + "/Library/Containers/app.blocks.app/Data/Library"
        if Bundle.main.bundleIdentifier == "app.blocks.app" {
            guard FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.standardizedFileURL.path == library else { return nil }
        }
        return library + "/BlocksAssociation"
        #endif
    }

    #if !BLOCKS_LOCAL_DEVELOPMENT
    private static let officialTrust = SelectionHelperOfficialAssociationTrust.make()
    #endif

    public struct Peer: Sendable {
        public let auditToken: Data
        fileprivate let descriptor: Int32
    }

    private static func authenticatedPeer(_ descriptor: Int32, role: String) -> Peer? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size,
              token.val.1 == getuid(), token.val.3 == getuid() else { return nil }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard BlocksLocalBuildTrust.accepts(connectedSocket: descriptor, role: role) else { return nil }
        #else
        guard officialTrust?.authenticate(auditToken: data, role: role) == true else { return nil }
        #endif
        return .init(auditToken: data, descriptor: descriptor)
    }

    /// Handler-only context: the descriptor remains open for the synchronous
    /// handler, and both the kernel token and pinned installation are rechecked.
    public static func isCurrent(_ peer: Peer, role: String) -> Bool {
        authenticatedPeer(peer.descriptor, role: role)?.auditToken == peer.auditToken
    }

    private static func responsePeerIsCurrent(_ peer: Peer) -> Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        // The server may already have closed its side after writing the reply.
        // Development retains its original pre-message registry validation.
        return true
        #else
        return officialTrust?.authenticate(auditToken: peer.auditToken, role: "helper") == true
        #endif
    }

    public static func send(_ request: SelectionHelperLocalAssociation.Request,
                            timeout: TimeInterval = 0.5) -> SelectionHelperLocalAssociation.Response? {
        guard let path = directoryPath, let directory = openPrivateDirectory(path: path, create: false) else { return nil }
        defer { close(directory) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        configure(descriptor, timeout: timeout)
        guard connect(descriptor, path: path + "/" + socketName, timeout: timeout),
              let peer = authenticatedPeer(descriptor, role: "helper"),
              let data = try? JSONEncoder().encode(request), writeFrame(data, descriptor: descriptor),
              let reply = readFrame(descriptor: descriptor),
              let response = try? JSONDecoder().decode(SelectionHelperLocalAssociation.Response.self, from: reply),
              response.version == SelectionHelperLocalAssociation.version,
              responsePeerIsCurrent(peer) else { return nil }
        return response
    }

    public final class Server: @unchecked Sendable {
        private let queue = DispatchQueue(label: "\(BlocksRuntimeIdentity.identifierPrefix).selection-helper.association")
        private var source: DispatchSourceRead?
        private var listener: Int32 = -1
        private var directory: Int32 = -1
        private var lockFile: Int32 = -1

        public init() {}
        deinit {
            source?.cancel()
            if listener >= 0 { close(listener) }
            if directory >= 0 {
                unlinkat(directory, socketName, 0)
                close(directory)
            }
            if lockFile >= 0 { close(lockFile) }
        }

        /// Failure only disables this optional enhancement. The legacy manual
        /// pairing listener is independent and remains available.
        @discardableResult
        public func start(handler: @escaping @Sendable (Data, Peer) -> Data?) -> Bool {
            #if !BLOCKS_LOCAL_DEVELOPMENT
            guard officialTrust?.snapshotIsCurrent() == true else { return false }
            #endif
            guard listener < 0, let path = directoryPath,
                  let directory = openPrivateDirectory(path: path, create: true) else { return false }
            let lock = openat(directory, "listener.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            var info = stat()
            guard lock >= 0, fstat(lock, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
                  info.st_nlink == 1, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                if lock >= 0 { close(lock) }; close(directory); return false
            }
            var existing = stat()
            if fstatat(directory, socketName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid(),
                      unlinkat(directory, socketName, 0) == 0 else {
                    close(lock); close(directory); return false
                }
            } else if errno != ENOENT {
                close(lock); close(directory); return false
            }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { close(lock); close(directory); return false }
            configure(descriptor, timeout: 0.5)
            guard withAddress(path: path + "/" + socketName, operation: {
                Darwin.bind(descriptor, $0, $1)
            }) == 0 else { close(descriptor); close(lock); close(directory); return false }
            guard fchmodat(directory, socketName, 0o600, 0) == 0,
                  listen(descriptor, 4) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                unlinkat(directory, socketName, 0)
                close(descriptor); close(lock); close(directory); return false
            }
            self.directory = directory
            self.lockFile = lock
            self.listener = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                _ = self
                let peer = accept(descriptor, nil, nil)
                guard peer >= 0 else { return }
                defer { close(peer) }
                configure(peer, timeout: 0.5)
                guard let identity = authenticatedPeer(peer, role: "app"),
                      let request = readFrame(descriptor: peer), isCurrent(identity, role: "app"),
                      let response = handler(request, identity) else { return }
                _ = writeFrame(response, descriptor: peer)
            }
            self.source = source
            source.resume()
            return true
        }
    }

    /// Open every component without following symlinks. Ancestors must belong
    /// to root/the login user and be non-writable by other users; the endpoint
    /// directory itself must be exactly 0700 and owned by the login user.
    static func openPrivateDirectory(path: String, create: Bool) -> Int32? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        var descriptor = open("/", O_SEARCH | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            if last && create {
                if mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST { close(descriptor); return nil }
            }
            let next = openat(descriptor, component, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  (info.st_uid == getuid() || (!last && info.st_uid == 0)),
                  info.st_mode & 0o022 == 0,
                  !last || info.st_mode & 0o777 == 0o700 else { close(descriptor); return nil }
        }
        return descriptor
    }

    private static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, 0)
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let bounded = timeout.isFinite ? max(0.05, min(timeout, 1)) : 0.5
        var value = timeval(tv_sec: 0, tv_usec: Int32(bounded * 1_000_000))
        if bounded == 1 { value = timeval(tv_sec: 1, tv_usec: 0) }
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connect(_ descriptor: Int32, path: String, timeout: TimeInterval) -> Bool {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(descriptor, F_SETFL, 0) }
        let result = withAddress(path: path) { Darwin.connect(descriptor, $0, $1) }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        let bounded = timeout.isFinite ? max(0.05, min(timeout, 1)) : 0.5
        var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptorState, 1, Int32(bounded * 1_000)) == 1,
              descriptorState.revents & Int16(POLLOUT) != 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    private static func withAddress(path: String, operation: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func writeFrame(_ data: Data, descriptor: Int32) -> Bool {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { return false }
        let frame = data + Data([0x0A])
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        return frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count, ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return offset == bytes.count
        }
    }

    private static func readFrame(descriptor: Int32) -> Data? {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while data.count <= maximumFrameBytes, ProcessInfo.processInfo.systemUptime < deadline {
            let count = read(descriptor, &bytes, bytes.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: bytes.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) {
                guard newline == data.index(before: data.endIndex), newline <= maximumFrameBytes else { return nil }
                return Data(data[..<newline])
            }
        }
        return nil
    }
}
