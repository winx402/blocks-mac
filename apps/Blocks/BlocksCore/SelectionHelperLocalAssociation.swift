import Foundation
import CryptoKit
import Darwin
import Security

/// This protocol is deliberately not a second command transport. Its only
/// operations are read-only status and a one-time, code-identity-authorized
/// bootstrap of the existing authenticated pairing protocol.
public enum SelectionHelperLocalAssociation {
    public static let version = 1
    public struct Request: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case status, authorize, pair }
        public let version: Int
        public let kind: Kind
        public let requestID: String
        public let clientPublicKey: Data?
        public let pairRequest: SelectionHelperPairRequest?
        public init(kind: Kind, requestID: String, clientPublicKey: Data? = nil,
                    pairRequest: SelectionHelperPairRequest? = nil) {
            version = SelectionHelperLocalAssociation.version
            self.kind = kind
            self.requestID = requestID
            self.clientPublicKey = clientPublicKey
            self.pairRequest = pairRequest
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
        public init(isPaired: Bool, authorization: Authorization? = nil, pairPacket: Data? = nil) {
            version = SelectionHelperLocalAssociation.version
            self.isPaired = isPaired
            self.authorization = authorization
            self.pairPacket = pairPacket
        }
    }

    #if BLOCKS_LOCAL_DEVELOPMENT
    /// Confined to the Helper's serial pairing queue. A bounded single grant
    /// cannot accumulate memory or authorize a different transcript. Removal
    /// precedes verification/commit: even a failed attempt spends the grant.
    public struct Authority {
        private var pending: Authorization?
        public init() {}
        public mutating func issue(requestID: String, clientPublicKey: Data,
                                   generation: UInt64, isPaired: Bool, now: Date) -> Authorization? {
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
            return grant
        }
        public mutating func consume(request: SelectionHelperPairRequest,
                                     generation: UInt64, isPaired: Bool, now: Date) -> Authorization? {
            let grant = pending
            pending = nil
            guard let grant, !isPaired, grant.generation == generation,
                  now < grant.expiresAt, now >= grant.expiresAt.addingTimeInterval(-5),
                  request.protocolVersion == BlocksSelectionHelperProtocol.version,
                  request.requestID == grant.requestID, request.clientPublicKey == grant.clientPublicKey,
                  request.pairingCode == grant.code else { return nil }
            return grant
        }
    }
    #endif
}

#if BLOCKS_LOCAL_DEVELOPMENT
/// Bounded blocking I/O, used only from background queues. No fallback to TCP
/// or PID-only trust is permitted when the local peer cannot be authenticated.
public enum SelectionHelperLocalAssociationTransport {
    private static let maximumFrameBytes = 16_384
    private static let socketName = "helper.sock"
    private static var directoryPath: String? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return String(cString: home) + "/Library/Application Support/Blocks Dev/Association"
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
              BlocksLocalBuildTrust.accepts(connectedSocket: descriptor, role: "helper"),
              let data = try? JSONEncoder().encode(request), writeFrame(data, descriptor: descriptor),
              let reply = readFrame(descriptor: descriptor),
              let response = try? JSONDecoder().decode(SelectionHelperLocalAssociation.Response.self, from: reply),
              response.version == SelectionHelperLocalAssociation.version else { return nil }
        return response
    }

    public final class Server: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.blocks.dev.selection-helper.association")
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
        public func start(handler: @escaping @Sendable (Data) -> Data?) -> Bool {
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
                guard BlocksLocalBuildTrust.accepts(connectedSocket: peer, role: "app"),
                      let request = readFrame(descriptor: peer), let response = handler(request) else { return }
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
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            if last && create {
                if mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST { close(descriptor); return nil }
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
#endif
