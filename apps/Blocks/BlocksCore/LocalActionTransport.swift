#if BLOCKS_LOCAL_DEVELOPMENT
import Foundation
import Darwin

/// Development-only action channel. The installed signed peer manifest remains
/// the authority; socket ownership alone never authenticates a caller.
public enum LocalActionTransport {
    public enum Operation: String, Codable, Sendable { case probe, list, submit, cancel }
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case unavailable, untrustedPeer, timedOut, invalidFrame
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Local action service unavailable."
            case .untrustedPeer: return "Local action peer authentication failed."
            case .timedOut: return "Local action request timed out."
            case .invalidFrame: return "Invalid local action transport frame."
            }
        }
    }
    static let maximumFrameBytes = 36 * 1_024 * 1_024
    private static let socketName = "action.sock"
    private static let lockName = "listener.lock"
    private static var directoryPath: String? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return String(cString: home) + "/Library/Application Support/Blocks Dev/Actions"
    }
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static let operations: [Operation] = [.probe, .list, .submit, .cancel]

    /// Synchronous API for CLI background execution. Never retries a sent action.
    public static func request(operation: Operation, payload: Data = Data(),
                               outputFile: FileHandle? = nil, timeout: TimeInterval = 12) throws -> Data {
        guard let path = directoryPath else { throw Error.unavailable }
        return try request(path: path, operation: operation, payload: payload,
                           outputFile: outputFile, timeout: timeout)
    }

    #if LOCAL_ACTION_TRANSPORT_FIXTURE
    static func fixtureRequest(path: String, operation: Operation, payload: Data = Data(),
                               outputFile: FileHandle? = nil, timeout: TimeInterval = 12) throws -> Data {
        try request(path: path, operation: operation, payload: payload, outputFile: outputFile, timeout: timeout)
    }
    #endif

    private static func request(path: String, operation: Operation, payload: Data,
                                outputFile: FileHandle?, timeout: TimeInterval) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 600,
              payload.count <= maximumFrameBytes,
              outputFile == nil || operation == .submit else { throw Error.invalidFrame }
        let deadline = uptime + timeout
        guard let directory = openPrivateDirectory(path: path, create: false) else {
            throw errno == ENOENT ? Error.unavailable : Error.untrustedPeer
        }
        defer { close(directory) }
        guard let endpoint = endpointIdentity(directory), let lockIdentity = fileIdentity(directory, lockName) else {
            throw errno == ENOENT ? Error.unavailable : Error.untrustedPeer
        }
        let peer = socket(AF_UNIX, SOCK_STREAM, 0)
        guard peer >= 0 else { throw Error.unavailable }
        defer { close(peer) }
        guard configure(peer), directoryStillMatches(path, directory) else { throw Error.untrustedPeer }
        if withAddress(path + "/" + socketName, { Darwin.connect(peer, $0, $1) }) != 0 {
            guard errno == EINPROGRESS else { throw Error.unavailable }
            try waitFor(peer, event: Int16(POLLOUT), deadline: min(deadline, uptime + 2))
        }
        guard socketHasNoError(peer) else { throw Error.unavailable }
        guard matches(path, directory, endpoint, lockIdentity),
              BlocksLocalBuildTrust.accepts(connectedSocket: peer, role: "app") else { throw Error.untrustedPeer }
        let code = UInt8(operations.firstIndex(of: operation)!)
        try writeFrame(payload, code: code, timeout: timeout, output: outputFile?.fileDescriptor,
                       descriptor: peer, deadline: min(deadline, uptime + 10))
        let frame = try readFrame(descriptor: peer, firstByteDeadline: deadline,
                                  framingDeadline: deadline, allowOutput: false)
        guard frame.code == code | 0x80, matches(path, directory, endpoint, lockIdentity) else {
            throw Error.invalidFrame
        }
        return frame.data
    }

    public final class Server: @unchecked Sendable {
        public typealias Handler = @Sendable (Operation, Data, FileHandle?, @escaping @Sendable (Data) -> Void) -> Void
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "app.blocks.dev.actions.accept")
        private var source: DispatchSourceRead?
        private var generation = UUID()
        private var peers: [UUID: Connection] = [:]
        private let path: String?
        public init() { path = directoryPath }
        #if LOCAL_ACTION_TRANSPORT_FIXTURE
        init(directoryPathForTesting: String) { path = directoryPathForTesting }
        #endif
        deinit { stop() }

        @discardableResult
        public func start(handler: @escaping Handler) -> Bool {
            lock.lock(); defer { lock.unlock() }
            // Re-enabling integration does not replace an active listener or
            // its handler; only stop() begins a new listener lifetime.
            if source != nil { return true }
            guard let path,
                  let directory = openPrivateDirectory(path: path, create: true) else { return false }
            let lockFD = openat(directory, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            var info = stat()
            guard lockFD >= 0, fstat(lockFD, &info) == 0,
                  info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0,
                  fileIdentity(directory, lockName) == Identity(info) else {
                if lockFD >= 0 { close(lockFD) }; close(directory); return false
            }
            let lockIdentity = Identity(info)
            var previous = stat()
            if fstatat(directory, socketName, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
                guard previous.st_uid == getuid(), previous.st_mode & S_IFMT == S_IFSOCK,
                      previous.st_mode & 0o777 == 0o600,
                      unlinkat(directory, socketName, 0) == 0 else { close(lockFD); close(directory); return false }
            } else if errno != ENOENT { close(lockFD); close(directory); return false }
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { close(lockFD); close(directory); return false }
            guard configure(listener), directoryStillMatches(path, directory),
                  fileIdentity(directory, lockName) == lockIdentity,
                  withAddress(path + "/" + socketName, { Darwin.bind(listener, $0, $1) }) == 0 else {
                close(listener); close(lockFD); close(directory); return false
            }
            guard directoryStillMatches(path, directory),
                  fchmodat(directory, socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
                  let endpoint = endpointIdentity(directory),
                  fileIdentity(directory, lockName) == lockIdentity, listen(listener, 8) == 0 else {
                close(listener); close(lockFD); close(directory); return false
            }
            let resources = EndpointResources(path: path, directory: directory, lockFD: lockFD, identity: endpoint)
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            let generation = UUID()
            self.generation = generation
            source.setCancelHandler { close(listener) }
            source.setEventHandler { [weak self, resources] in
                guard let self else { return }
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { return }
                self.lock.lock()
                guard self.source != nil, self.generation == generation, self.peers.count < 8, configure(peer) else {
                    self.lock.unlock(); close(peer); return
                }
                let connection = Connection(descriptor: peer)
                self.peers[connection.id] = connection
                self.lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [weak self, resources] in
                    defer {
                        withExtendedLifetime(resources) {}
                        connection.closeDescriptor()
                        self?.remove(connection.id)
                    }
                    guard matches(path, directory, endpoint, lockIdentity),
                          BlocksLocalBuildTrust.accepts(connectedSocket: peer, role: "cli") else { return }
                    do {
                        let frame = try readFrame(descriptor: peer, firstByteDeadline: uptime + 3,
                                                  framingDeadline: uptime + 10, allowOutput: true)
                        // FileHandle(closeOnDealloc: true) transfers shared ARC
                        // ownership to the handler. A retained asynchronous
                        // action must keep its FD after transport disconnect or
                        // timeout; only action cancellation may stop that work.
                        guard Int(frame.code) < operations.count, !connection.isCancelled,
                              matches(path, directory, endpoint, lockIdentity) else { return }
                        let operation = operations[Int(frame.code)]
                        guard frame.output == nil || operation == .submit else { return }
                        let deadline = uptime + frame.timeout
                        let reply = Reply()
                        handler(operation, frame.data, frame.output, { reply.complete($0) })
                        guard let response = reply.wait(until: deadline, connection: connection),
                              matches(path, directory, endpoint, lockIdentity), !connection.isCancelled else { return }
                        try writeFrame(response, code: frame.code | 0x80, timeout: frame.timeout, output: nil,
                                       descriptor: peer, deadline: min(deadline, uptime + 10))
                    } catch { /* No peer-controlled data is logged. */ }
                }
            }
            self.source = source
            source.resume()
            return true
        }

        public func stop() {
            lock.lock()
            let source = self.source; self.source = nil
            let active = Array(peers.values)
            lock.unlock()
            active.forEach { $0.cancel() }
            source?.cancel()
        }
        private func remove(_ id: UUID) { lock.lock(); peers.removeValue(forKey: id); lock.unlock() }
    }

    private final class EndpointResources: @unchecked Sendable {
        let path: String; let directory: Int32; let lockFD: Int32; let identity: Identity
        init(path: String, directory: Int32, lockFD: Int32, identity: Identity) {
            self.path = path; self.directory = directory; self.lockFD = lockFD; self.identity = identity
        }
        deinit {
            if directoryStillMatches(path, directory), endpointIdentity(directory) == identity {
                unlinkat(directory, socketName, 0)
            }
            close(lockFD); close(directory)
        }
    }
    private final class Connection: @unchecked Sendable {
        let id = UUID(); let descriptor: Int32
        private let lock = NSLock(); private var cancelled = false; private var closed = false
        init(descriptor: Int32) { self.descriptor = descriptor }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }; cancelled = true; shutdown(descriptor, SHUT_RDWR)
        }
        func closeDescriptor() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }; closed = true; close(descriptor)
        }
    }
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock(); private let ready = DispatchSemaphore(value: 0)
        private var response: Data?
        func complete(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard response == nil else { return }; response = data; ready.signal()
        }
        func wait(until deadline: TimeInterval, connection: Connection) -> Data? {
            while uptime < deadline && !connection.isCancelled {
                var byte: UInt8 = 0
                let count = recv(connection.descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                // One request only: trailing bytes and disconnect both terminate.
                if count >= 0 || (errno != EAGAIN && errno != EINTR) { return nil }
                if ready.wait(timeout: .now() + min(0.05, max(0, deadline - uptime))) == .success {
                    lock.lock(); defer { lock.unlock() }
                    return !connection.isCancelled && uptime < deadline ? response : nil
                }
            }
            return nil
        }
    }

    private struct Frame { let code: UInt8; let timeout: TimeInterval; let data: Data; let output: FileHandle? }
    // Fixed 16-byte header: magic, version, operation, FD count, reserved,
    // big-endian payload length and timeout milliseconds. No JSON/base64 copy.
    private static func writeFrame(_ data: Data, code: UInt8, timeout: TimeInterval, output: Int32?,
                                    descriptor: Int32, deadline: TimeInterval) throws {
        guard data.count <= maximumFrameBytes else { throw Error.invalidFrame }
        var header = Data([0x42, 0x4c, 0x41, 0x43, 1, code, output == nil ? 0 : 1, 0])
        for value in [UInt32(data.count), UInt32(max(1, timeout * 1_000))] {
            var big = value.bigEndian; withUnsafeBytes(of: &big) { header.append(contentsOf: $0) }
        }
        // Ancillary data accompanies the first byte only. All subsequent I/O
        // uses recvmsg too, so late or duplicate descriptors cannot leak.
        var sent = false
        try header.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitFor(descriptor, event: Int16(POLLOUT), deadline: deadline)
                var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress!.advanced(by: offset)),
                                   iov_len: bytes.count - offset)
                let count: Int = withUnsafeMutablePointer(to: &vector) { vector in
                    var message = msghdr(); message.msg_iov = vector; message.msg_iovlen = 1
                    if let output, !sent {
                        var control = [UInt8](repeating: 0, count: 16)
                        return control.withUnsafeMutableBytes { buffer in
                            var h = cmsghdr(cmsg_len: 16, cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
                            withUnsafeBytes(of: &h) { buffer.copyBytes(from: $0) }
                            var fd = output
                            withUnsafeBytes(of: &fd) { buffer.baseAddress!.advanced(by: 12).copyMemory(from: $0.baseAddress!, byteCount: 4) }
                            message.msg_control = buffer.baseAddress; message.msg_controllen = 16
                            return sendmsg(descriptor, &message, 0)
                        }
                    }
                    return sendmsg(descriptor, &message, 0)
                }
                if count > 0 { sent = true; offset += count }
                else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { throw Error.invalidFrame }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitFor(descriptor, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { throw Error.invalidFrame }
            }
        }
    }

    private static func readFrame(descriptor: Int32, firstByteDeadline: TimeInterval,
                                  framingDeadline: TimeInterval, allowOutput: Bool) throws -> Frame {
        var descriptors: [Int32] = []
        var transferred = false
        defer { if !transferred { descriptors.forEach { close($0) } } }
        var header = try readExactly(1, descriptor: descriptor, deadline: firstByteDeadline, descriptors: &descriptors)
        header.append(try readExactly(15, descriptor: descriptor, deadline: min(framingDeadline, uptime + 3),
                                      descriptors: &descriptors))
        guard header.prefix(5) == Data([0x42, 0x4c, 0x41, 0x43, 1]), header[7] == 0,
              header[6] <= 1, allowOutput || header[6] == 0 else { throw Error.invalidFrame }
        func integer(_ offset: Int) -> UInt32 {
            header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let length = Int(integer(8)); let milliseconds = integer(12)
        guard length <= maximumFrameBytes, milliseconds > 0, milliseconds <= 600_000 else { throw Error.invalidFrame }
        let data = try readExactly(length, descriptor: descriptor, deadline: min(framingDeadline, uptime + 10),
                                   descriptors: &descriptors)
        guard descriptors.count == Int(header[6]), descriptors.count <= 1 else { throw Error.invalidFrame }
        if let fd = descriptors.first {
            let flags = fcntl(fd, F_GETFL)
            var info = stat()
            guard flags >= 0, flags & O_ACCMODE != O_RDONLY, fstat(fd, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFIFO || info.st_mode & S_IFMT == S_IFCHR else {
                throw Error.invalidFrame
            }
        }
        transferred = true
        return Frame(code: header[5], timeout: Double(milliseconds) / 1_000, data: data,
                     output: descriptors.first.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) })
    }

    private static func readExactly(_ length: Int, descriptor: Int32, deadline: TimeInterval,
                                    descriptors: inout [Int32]) throws -> Data {
        var result = Data(); result.reserveCapacity(length)
        while result.count < length {
            try waitFor(descriptor, event: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: min(65_536, length - result.count))
            var control = [UInt8](repeating: 0, count: 1_024)
            var invalid = false
            let count = bytes.withUnsafeMutableBytes { bytes in
                control.withUnsafeMutableBytes { control in
                    var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                    return withUnsafeMutablePointer(to: &vector) { vector in
                        var message = msghdr(); message.msg_iov = vector; message.msg_iovlen = 1
                        message.msg_control = control.baseAddress; message.msg_controllen = socklen_t(control.count)
                        let count = recvmsg(descriptor, &message, 0)
                        if count > 0 {
                            invalid = message.msg_flags & (MSG_CTRUNC | MSG_TRUNC) != 0
                            var offset = 0
                            while offset + 12 <= Int(message.msg_controllen) {
                                let h = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                                let size = Int(h.cmsg_len)
                                guard size >= 12, offset + size <= Int(message.msg_controllen) else { invalid = true; break }
                                if h.cmsg_level == SOL_SOCKET && h.cmsg_type == SCM_RIGHTS {
                                    if (size - 12) % 4 != 0 { invalid = true }
                                    for index in stride(from: offset + 12, to: offset + size - 3, by: 4) {
                                        let fd = control.loadUnaligned(fromByteOffset: index, as: Int32.self)
                                        descriptors.append(fd)
                                        if fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 { invalid = true }
                                    }
                                } else { invalid = true }
                                offset += (size + 3) & ~3
                            }
                        }
                        return count
                    }
                }
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0, !invalid, descriptors.count <= 1 else { throw Error.invalidFrame }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }



    private struct Identity: Equatable, Sendable {
        let device: dev_t; let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }
    private static func fileIdentity(_ directory: Int32, _ name: String) -> Identity? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return nil }
        return Identity(info)
    }
    private static func endpointIdentity(_ directory: Int32) -> Identity? {
        var info = stat()
        guard fstatat(directory, socketName, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o777 == 0o600 else { return nil }
        return Identity(info)
    }
    private static func directoryStillMatches(_ path: String, _ descriptor: Int32) -> Bool {
        guard let current = openPrivateDirectory(path: path, create: false) else { return false }
        defer { close(current) }
        var old = stat(); var new = stat()
        return fstat(descriptor, &old) == 0 && fstat(current, &new) == 0 && Identity(old) == Identity(new)
    }

    static func openPrivateDirectory(path: String, create: Bool) -> Int32? {
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !components.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            if create && (last || component == "Blocks Dev") {
                if mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST { close(descriptor); return nil }
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() || (!last && info.st_uid == 0),
                  info.st_mode & 0o022 == 0,
                  !last || info.st_mode & 0o777 == 0o700 else { close(descriptor); return nil }
        }
        return descriptor
    }

    static func configure(_ descriptor: Int32) -> Bool {
        var noSignal: Int32 = 1
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                          socklen_t(MemoryLayout<Int32>.size)) == 0
    }
    private static func socketHasNoError(_ descriptor: Int32) -> Bool {
        var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    private static func withAddress(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { errno = ENAMETOOLONG; return -1 }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    private static func matches(_ path: String, _ directory: Int32, _ endpoint: Identity, _ lock: Identity) -> Bool {
        directoryStillMatches(path, directory) && endpointIdentity(directory) == endpoint && fileIdentity(directory, lockName) == lock
    }
    private static func waitFor(_ descriptor: Int32, event: Int16, deadline: TimeInterval) throws {
        while uptime < deadline {
            var state = pollfd(fd: descriptor, events: event, revents: 0)
            let result = poll(&state, 1, Int32(max(1, min(1_000, (deadline - uptime) * 1_000))))
            if result > 0 {
                if state.revents & event != 0 { return }
                throw Error.invalidFrame
            }
            if result < 0 && errno != EINTR { throw Error.invalidFrame }
        }
        throw Error.timedOut
    }
}
#endif
