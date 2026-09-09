import Darwin
import Foundation

/// Only children actually launched/validated by this instance may be reaped.
/// No process-name scan, Helper, launch agent or other installation is included.
public enum ShutdownPrivateProcesses {
    private struct Identity: Equatable {
        let pid: pid_t
        let parentPID: UInt32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let path: String
    }
    private static let lock = NSLock()
    private static var identities: [pid_t: Identity] = [:]
    private final class Snapshot {
        let values: [Identity]
        init(_ values: [Identity]) { self.values = values }
    }
    // Readers announce before loading the published pointer. Writers reclaim
    // retired snapshots only with no readers. The watchdog never takes lock.
    private static var publishedAddress: Int64 = 0
    private static var readerCount: Int32 = 0
    private static var retired: [UnsafeRawPointer] = []

    @discardableResult
    public static func registerClipboardChild(pid: pid_t, executableURL: URL) -> Bool {
        register(pid: pid, executableURL: executableURL,
                 relativePath: "Contents/MacOS/BlocksClipboardBroker", expectedParent: UInt32(getpid()))
    }

    /// Called only after the private NSXPCConnection's peer signature check.
    public static func registerValidatedRunner(pid: pid_t, executableURL: URL) {
        _ = register(pid: pid, executableURL: executableURL,
                 relativePath: "Contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner")
    }

    private static func register(pid: pid_t, executableURL: URL, relativePath: String,
                                 expectedParent: UInt32? = nil) -> Bool {
        guard let root = canonicalPath(Bundle.main.bundleURL.path) else { return false }
        // Resolve system aliases in the app root, then append the fixed in-bundle
        // path. Resolving the expected leaf itself would trust a symlink escaping
        // the bundle. /var and /private/var must not create different identities.
        let expected = root + "/" + relativePath
        guard canonicalPath(executableURL.path) == expected,
              let identity = identity(pid: pid), canonicalPath(identity.path) == expected,
              expectedParent == nil || identity.parentPID == expectedParent else { return false }
        return lock.withLock {
            guard identities[pid] != identity else { return true }
            identities = identities.filter { self.identity(pid: $0.key) == $0.value }
            identities[pid] = identity
            let pointer = Unmanaged.passRetained(Snapshot(Array(identities.values))).toOpaque()
            let address = Int64(Int(bitPattern: pointer))
            let previous = OSAtomicAdd64Barrier(0, &publishedAddress)
            precondition(OSAtomicCompareAndSwap64Barrier(previous, address, &publishedAddress))
            if previous != 0, let old = UnsafeRawPointer(bitPattern: Int(previous)) { retired.append(old) }
            if OSAtomicAdd32Barrier(0, &readerCount) == 0 {
                retired.forEach { Unmanaged<Snapshot>.fromOpaque($0).release() }
                retired.removeAll()
            }
            return true
        }
    }

    public static func terminateRegisteredProcesses() {
        OSAtomicIncrement32Barrier(&readerCount)
        let address = OSAtomicAdd64Barrier(0, &publishedAddress)
        let captured: [Identity]
        if let pointer = UnsafeRawPointer(bitPattern: Int(address)) {
            captured = Unmanaged<Snapshot>.fromOpaque(pointer).takeUnretainedValue().values
        } else { captured = [] }
        OSAtomicDecrement32Barrier(&readerCount)
        for old in captured where identity(pid: old.pid) == old {
            _ = kill(old.pid, SIGKILL)
        }
    }

    private static func identity(pid: pid_t) -> Identity? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        // Cache/compare the kernel's own path across the process lifetime.
        // Canonical filesystem resolution is registration-only: the deadline
        // path must not wait for filesystem I/O or a disconnected volume.
        return Identity(pid: pid, parentPID: info.pbi_ppid, startSeconds: info.pbi_start_tvsec,
                        startMicroseconds: info.pbi_start_tvusec, path: String(cString: path))
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
