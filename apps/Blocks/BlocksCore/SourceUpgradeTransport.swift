import Foundation
#if BLOCKS_LOCAL_DEVELOPMENT
import Darwin

/// Only locally signed builds contain this endpoint. All socket I/O has an
/// absolute monotonic deadline. Socket I/O always executes on background queues.
public enum SourceUpgradeTransport {
    static let maximumFrameBytes = 4_096
    private static let socketName = "upgrade.sock"
    private static let lockName = "listener.lock"
    private static var directoryPath: String? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return String(cString: home) + "/Library/Application Support/Blocks Dev/SourceUpgrade"
    }

    public static func prepareAndQuit(timeout: TimeInterval = 35) -> SourceUpgradeProtocol.Response? {
        let bounded = boundedTimeout(timeout)
        let deadline = uptime + bounded
        let result = ClientResult()
        DispatchQueue.global(qos: .userInitiated).async {
            result.complete(runClient(deadline: deadline))
        }
        return result.wait(timeout: bounded + 0.25)
    }

    private static func runClient(deadline: TimeInterval) -> SourceUpgradeProtocol.Response? {
        let token = UUID()
        let startupDeadline = min(deadline, uptime + 5)
        guard let path = directoryPath else { return nil }
        var connected: (Int32, Int32, Identity)?
        repeat {
            switch connectClient(path: path, deadline: deadline) {
            case .connected(let peer, let directory, let identity): connected = (peer, directory, identity)
            case .rejected: return nil
            case .notReady:
                guard uptime < startupDeadline else { return nil }
                // Startup retry only: never retry identity failures or replies.
                Thread.sleep(forTimeInterval: min(0.05, startupDeadline - uptime))
            }
        } while connected == nil
        guard let (peer, directory, endpoint) = connected else { return nil }
        defer { close(directory) }
        defer { close(peer) }
        for operation in [SourceUpgradeProtocol.Request.Operation.probe, .prepare, .commit] {
            let request = SourceUpgradeProtocol.Request(token: token, operation: operation)
            guard directoryStillMatches(path, directory), endpointIdentity(directory) == endpoint,
                  let bytes = try? JSONEncoder().encode(request),
                  writeFrame(bytes, descriptor: peer, deadline: deadline),
                  let reply = readFrame(descriptor: peer, deadline: deadline),
                  let response = try? JSONDecoder().decode(SourceUpgradeProtocol.Response.self, from: reply),
                  response.matches(request) else { return nil }
            if response.status == .failed || response.status == .committed { return response }
        }
        return nil
    }

    private final class ClientResult: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var response: SourceUpgradeProtocol.Response?
        func complete(_ response: SourceUpgradeProtocol.Response?) {
            lock.lock(); self.response = response; lock.unlock()
            ready.signal()
        }
        func wait(timeout: TimeInterval) -> SourceUpgradeProtocol.Response? {
            guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return response
        }
    }

    private enum ClientConnection {
        case connected(Int32, Int32, Identity), notReady, rejected
    }
    private static func connectClient(path: String, deadline: TimeInterval) -> ClientConnection {
        guard let directory = openPrivateDirectory(path: path, create: false) else {
            return errno == ENOENT ? .notReady : .rejected
        }
        var keep = false
        defer { if !keep { close(directory) } }
        guard let endpoint = endpointIdentity(directory) else {
            return errno == ENOENT ? .notReady : .rejected
        }
        guard directoryStillMatches(path, directory) else { return .rejected }
        let peer = socket(AF_UNIX, SOCK_STREAM, 0)
        guard peer >= 0 else { return .rejected }
        defer { if !keep { close(peer) } }
        guard configure(peer) else { return .rejected }
        let result = withAddress(path + "/" + socketName) { Darwin.connect(peer, $0, $1) }
        if result != 0 {
            let failure = errno
            if failure == ENOENT || failure == ECONNREFUSED { return .notReady }
            guard failure == EINPROGRESS, wait(peer, event: Int16(POLLOUT), deadline: min(deadline, uptime + 1)) else {
                return .rejected
            }
        }
        guard socketHasNoError(peer), directoryStillMatches(path, directory),
              endpointIdentity(directory) == endpoint,
              BlocksLocalBuildTrust.accepts(connectedSocket: peer, role: "app") else { return .rejected }
        keep = true
        return .connected(peer, directory, endpoint)
    }

    public final class Server: @unchecked Sendable {
        public typealias Handler = @Sendable (UUID, SourceUpgradeProtocol.Request,
            @escaping @Sendable (SourceUpgradeProtocol.Response) -> Void) -> Void
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "app.blocks.dev.source-upgrade.accept")
        private var source: DispatchSourceRead?
        private var generation = UUID()
        private var peers: [UUID: Connection] = [:]
        private let path: String?
        public init() { path = directoryPath }
        #if SOURCE_UPGRADE_FIXTURE
        /// Only the standalone test binary has an isolated endpoint override.
        /// Production builds have no path, trust, or environment override.
        init(directoryPathForTesting: String) { path = directoryPathForTesting }
        #endif
        deinit { stop() }

        @discardableResult
        public func start(handler: @escaping Handler,
                          didCommit: @escaping @Sendable (UUID, UUID) -> Void,
                          disconnected: @escaping @Sendable (UUID) -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard source == nil, let path,
                  let directory = openPrivateDirectory(path: path, create: true) else { return false }
            let lockFD = openat(directory, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            var lockInfo = stat()
            guard lockFD >= 0, fstat(lockFD, &lockInfo) == 0,
                  lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
                  lockInfo.st_mode & 0o777 == 0o600, lockInfo.st_nlink == 1,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                if lockFD >= 0 { close(lockFD) }; close(directory); return false
            }
            let lockIdentity = Identity(lockInfo)
            var previous = stat()
            if fstatat(directory, socketName, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
                guard previous.st_uid == getuid(), previous.st_mode & S_IFMT == S_IFSOCK,
                      previous.st_mode & 0o777 == 0o600, unlinkat(directory, socketName, 0) == 0 else {
                    close(lockFD); close(directory); return false
                }
            } else if errno != ENOENT { close(lockFD); close(directory); return false }
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { close(lockFD); close(directory); return false }
            guard configure(listener), directoryStillMatches(path, directory),
                  withAddress(path + "/" + socketName, { Darwin.bind(listener, $0, $1) }) == 0 else {
                close(listener); close(lockFD); close(directory); return false
            }
            guard directoryStillMatches(path, directory),
                  fchmodat(directory, socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
                  let endpoint = endpointIdentity(directory), listen(listener, 4) == 0 else {
                // Do not unlink a path whose identity could have changed.
                close(listener); close(lockFD); close(directory); return false
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            let resources = EndpointResources(path: path, directory: directory, lockFD: lockFD, identity: endpoint)
            let generation = UUID()
            self.generation = generation
            source.setCancelHandler {
                close(listener)
            }
            source.setEventHandler { [weak self, resources] in
                guard let self else { return }
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { return }
                self.lock.lock()
                guard self.source != nil, self.generation == generation, self.peers.count < 4, configure(peer) else {
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
                    guard directoryStillMatches(path, directory), endpointIdentity(directory) == endpoint,
                          fileIdentity(directory, lockName) == lockIdentity,
                          BlocksLocalBuildTrust.accepts(connectedSocket: peer, role: "cli") else { return }
                    var committed = false
                    defer { if !committed { disconnected(connection.id) } }
                    let deadline = uptime + 35
                    var token: UUID?
                    var expected = SourceUpgradeProtocol.Request.Operation.probe
                    for _ in 0..<3 {
                        guard !connection.isCancelled, directoryStillMatches(path, directory),
                              endpointIdentity(directory) == endpoint,
                              fileIdentity(directory, lockName) == lockIdentity,
                              let data = readFrame(descriptor: peer, deadline: deadline),
                              let request = try? JSONDecoder().decode(SourceUpgradeProtocol.Request.self, from: data),
                              request.version == SourceUpgradeProtocol.version,
                              token == nil || token == request.token,
                              request.operation == expected || (token != nil && request.operation == .cancel) else { return }
                        token = request.token
                        let reply = Reply()
                        handler(connection.id, request, { reply.complete($0) })
                        guard let response = reply.wait(until: deadline, connection: connection),
                              response.matches(request), !connection.isCancelled,
                              directoryStillMatches(path, directory), endpointIdentity(directory) == endpoint,
                              let bytes = try? JSONEncoder().encode(response) else { return }
                        if response.status == .committed {
                            // Completion and stop arbitration are atomic with the
                            // final nonblocking write, so an acknowledged commit
                            // can never subsequently turn into cancellation.
                            guard connection.writeCommittedFrame(bytes, deadline: deadline) else { return }
                            committed = true
                            didCommit(connection.id, request.token)
                            return
                        }
                        guard writeFrame(bytes, descriptor: peer, deadline: deadline) else { return }
                        if response.status == .cancelled || response.status == .failed { return }
                        expected = request.operation == .probe ? .prepare : .commit
                    }
                }
            }
            self.source = source
            source.resume()
            return true
        }

        /// Cancels waits and shuts down peers without waiting on the caller's
        /// queue. Each authenticated session receives exactly one terminal callback.
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

    /// Keep opened directory and lock descriptors alive until all peers stop;
    /// closing them in listener cancellation would permit descriptor-reuse races.
    private final class EndpointResources: @unchecked Sendable {
        let path: String
        let directory: Int32
        let lockFD: Int32
        let identity: Identity
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
        let id = UUID()
        let descriptor: Int32
        private let lock = NSLock()
        private var cancelled = false
        private var committed = false
        private var closed = false
        init(descriptor: Int32) { self.descriptor = descriptor }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            guard !closed, !committed else { return }
            cancelled = true
            shutdown(descriptor, SHUT_RDWR)
        }
        func writeCommittedFrame(_ data: Data, deadline: TimeInterval) -> Bool {
            guard !data.isEmpty, data.count <= maximumFrameBytes, !data.contains(0x0A) else { return false }
            let frame = data + Data([0x0A])
            return frame.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    guard SourceUpgradeTransport.wait(descriptor, event: Int16(POLLOUT), deadline: deadline) else { return false }
                    lock.lock()
                    guard !cancelled, !closed, uptime < deadline else { lock.unlock(); return false }
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    let failure = errno
                    if count > 0 {
                        offset += count
                        if offset == buffer.count { committed = true }
                    }
                    lock.unlock()
                    if count > 0 { continue }
                    if count < 0 && (failure == EINTR || failure == EAGAIN) { continue }
                    return false
                }
                return true
            }
        }
        func closeDescriptor() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true; close(descriptor)
        }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var response: SourceUpgradeProtocol.Response?
        func complete(_ response: SourceUpgradeProtocol.Response) {
            lock.lock(); defer { lock.unlock() }
            guard self.response == nil else { return }
            self.response = response; ready.signal()
        }
        func wait(until deadline: TimeInterval, connection: Connection) -> SourceUpgradeProtocol.Response? {
            while uptime < deadline && !connection.isCancelled {
                var byte: UInt8 = 0
                let count = recv(connection.descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { return nil }
                if ready.wait(timeout: .now() + min(0.05, deadline - uptime)) == .success {
                    lock.lock(); defer { lock.unlock() }
                    return uptime < deadline && !connection.isCancelled ? response : nil
                }
            }
            return nil
        }
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

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        timeout.isFinite ? min(35, max(0.1, timeout)) : 35
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
    static func wait(_ descriptor: Int32, event: Int16, deadline: TimeInterval,
                     maximumPollMilliseconds: Int32 = 15_000) -> Bool {
        while uptime < deadline {
            var pollState = pollfd(fd: descriptor, events: event, revents: 0)
            let interval = min(Double(max(1, maximumPollMilliseconds)), (deadline - uptime) * 1_000)
            let result = poll(&pollState, 1, Int32(max(1, interval)))
            if result > 0 { return pollState.revents & event != 0 }
            if result == 0 { continue }
            if result < 0 && errno == EINTR { continue }
            return false
        }
        return false
    }
    private static func withAddress(_ path: String,
                                    _ operation: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    static func writeFrame(_ data: Data, descriptor: Int32, deadline: TimeInterval) -> Bool {
        guard !data.isEmpty, data.count <= maximumFrameBytes, !data.contains(0x0A) else { return false }
        let frame = data + Data([0x0A])
        return frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard wait(descriptor, event: Int16(POLLOUT), deadline: deadline) else { return false }
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { return false }
            }
            return uptime < deadline
        }
    }
    static func readFrame(descriptor: Int32, deadline: TimeInterval) -> Data? {
        var data = Data()
        while data.count <= maximumFrameBytes {
            guard wait(descriptor, event: Int16(POLLIN), deadline: deadline) else { return nil }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count == 1 else { return nil }
            if byte == 0x0A { return data.isEmpty ? nil : data }
            data.append(byte)
        }
        return nil
    }
}
#endif
