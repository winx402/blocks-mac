import CryptoKit
import Darwin
import Foundation

public enum BlobStoreError: Error, Equatable {
    case atomicReplacementFailed(Int32)
    case fileSystemFailure(Int32)
    case integrityCheckFailed(String)
    case invalidRelativePath(String)
    case invalidStorageDirectory(String)
    case invalidPermissions(String)
    case stagedFileMissing(String)
}

public struct BlobStoreStagedFile: Equatable, Sendable {
    public let stagingRelativePath: String
    public let relativePath: String
}

public struct BlobStoreRecoveryReport: Equatable, Sendable {
    public let promotedCount: Int
    public let removedStagingCount: Int
}

enum BlobStoreTestCheckpoint: Equatable, Sendable {
    case rootDescriptorOpened
    case readDescriptorOpened(String)
    case promoteSourceDescriptorOpened(String)
    case promoteRenamed(String)
}

public final class BlobStore {
    public static let defaultSidecarThresholdBytes = 1_048_576
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    public let directory: URL
    public let sidecarThresholdBytes: Int

    private let directoryState: BlobStoreDirectoryState
    private let operationLock: NSRecursiveLock
    var testCheckpointHandler: ((BlobStoreTestCheckpoint) -> Void)?
    var testDirectorySynchronizationHook: (() throws -> Void)?

    public init(directory: URL, sidecarThresholdBytes: Int = BlobStore.defaultSidecarThresholdBytes) {
        self.directory = directory.standardizedFileURL
        self.sidecarThresholdBytes = max(1, sidecarThresholdBytes)
        let directoryState = BlobStoreOperationLockRegistry.shared.state(for: self.directory)
        self.directoryState = directoryState
        self.operationLock = directoryState.operationLock
    }

    public func write(data: Data, recordID: String, fileExtension: String = "blob") throws -> String {
        guard let relativePath = try withRootDescriptor(createIfMissing: true, { rootDescriptor in
            let staged = try stage(
                data: data,
                recordID: recordID,
                fileExtension: fileExtension,
                rootDescriptor: rootDescriptor
            )
            do {
                try promote(staged, rootDescriptor: rootDescriptor)
                return staged.relativePath
            } catch {
                _ = try? unlink(staged.stagingRelativePath, rootDescriptor: rootDescriptor)
                throw error
            }
        }) else {
            throw BlobStoreError.invalidStorageDirectory(directory.path)
        }
        return relativePath
    }

    public func stage(data: Data, recordID: String, fileExtension: String = "blob") throws -> BlobStoreStagedFile {
        guard let staged = try withRootDescriptor(createIfMissing: true, { rootDescriptor in
            try stage(
                data: data,
                recordID: recordID,
                fileExtension: fileExtension,
                rootDescriptor: rootDescriptor
            )
        }) else {
            throw BlobStoreError.invalidStorageDirectory(directory.path)
        }
        return staged
    }

    public func promote(_ staged: BlobStoreStagedFile) throws {
        guard try withRootDescriptor(createIfMissing: false, { rootDescriptor in
            try promote(staged, rootDescriptor: rootDescriptor)
        }) != nil else {
            throw BlobStoreError.stagedFileMissing(staged.stagingRelativePath)
        }
    }

    public func abort(_ staged: BlobStoreStagedFile) throws {
        _ = try withRootDescriptor(createIfMissing: false) { rootDescriptor in
            try unlink(staged.stagingRelativePath, rootDescriptor: rootDescriptor)
        }
    }

    @discardableResult
    public func recover(retaining retainedRelativePaths: Set<String>) throws -> BlobStoreRecoveryReport {
        try recover(
            retainingPayloads: Dictionary(
                uniqueKeysWithValues: retainedRelativePaths.map { ($0, Optional<String>.none) }
            )
        )
    }

    @discardableResult
    public func recover(retaining retainedPayloadDigests: [String: String]) throws -> BlobStoreRecoveryReport {
        try recover(retainingPayloads: retainedPayloadDigests.mapValues(Optional.some))
    }

    @discardableResult
    public func recover(retainingPayloads retainedPayloadDigests: [String: String?]) throws -> BlobStoreRecoveryReport {
        for relativePath in retainedPayloadDigests.keys {
            try validate(relativePath: relativePath)
        }
        guard let report = try withRootDescriptor(createIfMissing: false, { rootDescriptor in
            for relativePath in retainedPayloadDigests.keys {
                if let descriptor = try openRegularFileIfExists(
                    relativePath,
                    rootDescriptor: rootDescriptor
                ) {
                    close(descriptor)
                }
            }

            var promotedCount = 0
            var removedStagingCount = 0
            let names = try entryNames(rootDescriptor: rootDescriptor)
            var stagedByFinalName: [String: [String]] = [:]
            for name in names {
                guard let marker = name.range(of: ".staged.") else { continue }
                let finalName = String(name[..<marker.lowerBound])
                stagedByFinalName[finalName, default: []].append(name)
            }

            for (finalName, stagedNames) in stagedByFinalName {
                let expectedDigest = retainedPayloadDigests[finalName] ?? nil
                let candidates: [String]
                if let expectedDigest {
                    candidates = try stagedNames.filter {
                        try sha256(relativePath: $0, rootDescriptor: rootDescriptor) == expectedDigest.lowercased()
                    }
                } else if retainedPayloadDigests.keys.contains(finalName), stagedNames.count == 1 {
                    candidates = stagedNames
                } else {
                    candidates = []
                }
                let selected = candidates.sorted().first
                if let selected {
                    try promote(
                        BlobStoreStagedFile(
                            stagingRelativePath: selected,
                            relativePath: finalName
                        ),
                        rootDescriptor: rootDescriptor
                    )
                    promotedCount += 1
                }
                for name in stagedNames where name != selected {
                    try unlink(name, rootDescriptor: rootDescriptor)
                    removedStagingCount += 1
                }
            }
            return BlobStoreRecoveryReport(
                promotedCount: promotedCount,
                removedStagingCount: removedStagingCount
            )
        }) else {
            return BlobStoreRecoveryReport(promotedCount: 0, removedStagingCount: 0)
        }
        return report
    }

    public func read(relativePath: String) throws -> Data {
        try read(relativePath: relativePath, expectedSHA256: nil)
    }

    public func read(relativePath: String, expectedSHA256: String?) throws -> Data {
        try validate(relativePath: relativePath)
        guard let data = try withRootDescriptor(createIfMissing: false, { rootDescriptor in
            let descriptor = try openRegularFile(
                relativePath,
                rootDescriptor: rootDescriptor,
                missingError: .fileSystemFailure(ENOENT)
            )
            defer { close(descriptor) }
            testCheckpointHandler?(.readDescriptorOpened(relativePath))
            let data = try readData(
                descriptor: descriptor,
                relativePath: relativePath
            )
            if let expectedSHA256,
               sha256(data) != expectedSHA256.lowercased() {
                throw BlobStoreError.integrityCheckFailed(relativePath)
            }
            return data
        }) else {
            throw BlobStoreError.fileSystemFailure(ENOENT)
        }
        return data
    }

    public func delete(relativePath: String?) throws {
        guard let relativePath, !relativePath.isEmpty else { return }
        try validate(relativePath: relativePath)
        _ = try withRootDescriptor(createIfMissing: false) { rootDescriptor in
            try unlink(relativePath, rootDescriptor: rootDescriptor)
        }
    }

    public func deleteAll(except retainedRelativePaths: Set<String> = []) throws {
        for relativePath in retainedRelativePaths {
            try validate(relativePath: relativePath)
        }
        _ = try withRootDescriptor(createIfMissing: false) { rootDescriptor in
            for name in try entryNames(rootDescriptor: rootDescriptor).sorted()
            where !retainedRelativePaths.contains(name) {
                try unlink(name, rootDescriptor: rootDescriptor)
            }
        }
    }

    public func cleanupOrphans(retaining retainedRelativePaths: Set<String>) throws {
        try deleteAll(except: retainedRelativePaths)
    }

    private func stage(
        data: Data,
        recordID: String,
        fileExtension: String,
        rootDescriptor: Int32
    ) throws -> BlobStoreStagedFile {
        let relativePath = makeRelativePath(recordID: recordID, fileExtension: fileExtension)
        let stagingRelativePath = "\(relativePath).staged.\(UUID().uuidString.lowercased())"
        try validate(relativePath: stagingRelativePath)
        let descriptor = stagingRelativePath.withCString { name in
            Darwin.openat(
                rootDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(Self.filePermissions)
            )
        }
        guard descriptor >= 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        var keepFile = false
        defer {
            close(descriptor)
            if !keepFile {
                _ = try? unlink(stagingRelativePath, rootDescriptor: rootDescriptor)
            }
        }
        _ = try secureRegularFileDescriptor(descriptor, relativePath: stagingRelativePath)
        try write(data, descriptor: descriptor)
        try synchronize(descriptor)
        _ = try secureRegularFileDescriptor(descriptor, relativePath: stagingRelativePath)
        keepFile = true
        return BlobStoreStagedFile(
            stagingRelativePath: stagingRelativePath,
            relativePath: relativePath
        )
    }

    private func promote(_ staged: BlobStoreStagedFile, rootDescriptor: Int32) throws {
        try validate(relativePath: staged.stagingRelativePath)
        try validate(relativePath: staged.relativePath)
        let sourceDescriptor = try openRegularFile(
            staged.stagingRelativePath,
            rootDescriptor: rootDescriptor,
            missingError: .stagedFileMissing(staged.stagingRelativePath)
        )
        defer { close(sourceDescriptor) }
        let sourceMetadata = try secureRegularFileDescriptor(
            sourceDescriptor,
            relativePath: staged.stagingRelativePath
        )
        testCheckpointHandler?(.promoteSourceDescriptorOpened(staged.stagingRelativePath))

        let renameResult = staged.stagingRelativePath.withCString { sourceName in
            staged.relativePath.withCString { destinationName in
                Darwin.renameat(rootDescriptor, sourceName, rootDescriptor, destinationName)
            }
        }
        guard renameResult == 0 else {
            throw BlobStoreError.atomicReplacementFailed(errno)
        }
        testCheckpointHandler?(.promoteRenamed(staged.relativePath))

        let finalDescriptor = try openRegularFile(
            staged.relativePath,
            rootDescriptor: rootDescriptor,
            missingError: .fileSystemFailure(ENOENT),
            hardenPermissions: false
        )
        defer { close(finalDescriptor) }
        let finalMetadata = try ownedRegularFileMetadata(
            finalDescriptor,
            relativePath: staged.relativePath
        )
        guard sameIdentity(sourceMetadata, finalMetadata) else {
            throw BlobStoreError.integrityCheckFailed(staged.relativePath)
        }
        _ = try secureRegularFileDescriptor(
            finalDescriptor,
            relativePath: staged.relativePath
        )
        try synchronizeDirectory(rootDescriptor)
    }

    private func makeRelativePath(recordID: String, fileExtension: String) -> String {
        let digest = SHA256.hash(data: Data(recordID.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .filter { $0.isLetter || $0.isNumber }
        return normalizedExtension.isEmpty ? key : "\(key).\(normalizedExtension)"
    }

    private func withRootDescriptor<T>(
        createIfMissing: Bool,
        _ body: (Int32) throws -> T
    ) throws -> T? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let opened = try openRootDescriptor(createIfMissing: createIfMissing) else {
            return nil
        }
        defer { close(opened.descriptor) }
        testCheckpointHandler?(.rootDescriptorOpened)
        let result = try body(opened.descriptor)
        try verifyRootIdentity(opened.metadata)
        return result
    }

    private func openRootDescriptor(createIfMissing: Bool) throws -> (descriptor: Int32, metadata: stat)? {
        if try metadataIfExists(at: directory) == nil {
            guard createIfMissing else { return nil }
            if directoryState.pinnedIdentity != nil {
                throw BlobStoreError.invalidStorageDirectory(directory.path)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
        }
        let descriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let error = errno
            if error == ELOOP || error == ENOTDIR {
                throw BlobStoreError.invalidStorageDirectory(directory.path)
            }
            if error == ENOENT, !createIfMissing { return nil }
            throw BlobStoreError.fileSystemFailure(error)
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw BlobStoreError.fileSystemFailure(errno)
            }
            guard isOwnedDirectory(metadata) else {
                throw BlobStoreError.invalidStorageDirectory(directory.path)
            }
            let openedIdentity = BlobStoreObjectIdentity(metadata)
            if let pinnedIdentity = directoryState.pinnedIdentity,
               pinnedIdentity != openedIdentity {
                throw BlobStoreError.invalidStorageDirectory(directory.path)
            }
            guard fchmod(descriptor, mode_t(Self.directoryPermissions)) == 0 else {
                throw BlobStoreError.fileSystemFailure(errno)
            }
            guard fstat(descriptor, &metadata) == 0 else {
                throw BlobStoreError.fileSystemFailure(errno)
            }
            guard isOwnedDirectory(metadata) else {
                throw BlobStoreError.invalidStorageDirectory(directory.path)
            }
            guard BlobStoreObjectIdentity(metadata) == openedIdentity else {
                throw BlobStoreError.invalidStorageDirectory(directory.path)
            }
            guard Int(metadata.st_mode & 0o777) == Self.directoryPermissions else {
                throw BlobStoreError.invalidPermissions(directory.lastPathComponent)
            }
            if directoryState.pinnedIdentity == nil {
                directoryState.pinnedIdentity = openedIdentity
            }
            return (descriptor, metadata)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func verifyRootIdentity(_ expected: stat) throws {
        let descriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw BlobStoreError.invalidStorageDirectory(directory.path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        guard isOwnedDirectory(metadata), sameIdentity(expected, metadata) else {
            throw BlobStoreError.invalidStorageDirectory(directory.path)
        }
        guard Int(metadata.st_mode & 0o777) == Self.directoryPermissions else {
            throw BlobStoreError.invalidPermissions(directory.lastPathComponent)
        }
    }

    private func openRegularFile(
        _ relativePath: String,
        rootDescriptor: Int32,
        missingError: BlobStoreError,
        hardenPermissions: Bool = true
    ) throws -> Int32 {
        try validate(relativePath: relativePath)
        let descriptor = relativePath.withCString { name in
            Darwin.openat(rootDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let error = errno
            if error == ENOENT { throw missingError }
            if error == ELOOP { throw BlobStoreError.invalidRelativePath(relativePath) }
            throw BlobStoreError.fileSystemFailure(error)
        }
        do {
            if hardenPermissions {
                _ = try secureRegularFileDescriptor(descriptor, relativePath: relativePath)
            } else {
                _ = try ownedRegularFileMetadata(descriptor, relativePath: relativePath)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openRegularFileIfExists(
        _ relativePath: String,
        rootDescriptor: Int32
    ) throws -> Int32? {
        do {
            return try openRegularFile(
                relativePath,
                rootDescriptor: rootDescriptor,
                missingError: .fileSystemFailure(ENOENT)
            )
        } catch BlobStoreError.fileSystemFailure(let code) where code == ENOENT {
            return nil
        }
    }

    private func secureRegularFileDescriptor(_ descriptor: Int32, relativePath: String) throws -> stat {
        var metadata = try ownedRegularFileMetadata(descriptor, relativePath: relativePath)
        guard fchmod(descriptor, mode_t(Self.filePermissions)) == 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        guard fstat(descriptor, &metadata) == 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        guard isOwnedSingleLinkRegularFile(metadata) else {
            throw BlobStoreError.invalidRelativePath(relativePath)
        }
        guard Int(metadata.st_mode & 0o777) == Self.filePermissions else {
            throw BlobStoreError.invalidPermissions(relativePath)
        }
        return metadata
    }

    private func ownedRegularFileMetadata(_ descriptor: Int32, relativePath: String) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        guard isOwnedSingleLinkRegularFile(metadata) else {
            throw BlobStoreError.invalidRelativePath(relativePath)
        }
        return metadata
    }

    private func entryNames(rootDescriptor: Int32) throws -> [String] {
        let duplicated = dup(rootDescriptor)
        guard duplicated >= 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        guard let stream = fdopendir(duplicated) else {
            let error = errno
            close(duplicated)
            throw BlobStoreError.fileSystemFailure(error)
        }
        defer { closedir(stream) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            var bytes = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: bytes)
            let name = withUnsafePointer(to: &bytes) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                try validate(relativePath: name)
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw BlobStoreError.fileSystemFailure(errno)
        }
        return names
    }

    @discardableResult
    private func unlink(
        _ relativePath: String,
        rootDescriptor: Int32
    ) throws -> Bool {
        try validate(relativePath: relativePath)
        let result = relativePath.withCString { name in
            Darwin.unlinkat(rootDescriptor, name, 0)
        }
        let error = errno
        if result == 0 {
            try synchronizeDirectory(rootDescriptor)
            return true
        }
        if error == ENOENT {
            // A previous unlink may have succeeded while the directory fsync
            // failed. Retrying then observes ENOENT, but the missing entry is
            // not durable evidence until the parent directory synchronizes.
            try synchronizeDirectory(rootDescriptor)
            return false
        }
        throw BlobStoreError.fileSystemFailure(error)
    }

    private func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw BlobStoreError.fileSystemFailure(count < 0 ? errno : EIO)
                }
                written += count
            }
        }
    }

    private func readData(descriptor: Int32, relativePath: String) throws -> Data {
        let metadata = try secureRegularFileDescriptor(descriptor, relativePath: relativePath)
        guard metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(Int.max) else {
            throw BlobStoreError.fileSystemFailure(EFBIG)
        }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var readCount = 0
            while readCount < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: readCount),
                    bytes.count - readCount
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw BlobStoreError.integrityCheckFailed(relativePath)
                }
                readCount += count
            }
        }
        var extraByte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &extraByte, 1)
            if count < 0, errno == EINTR { continue }
            if count == 0 { break }
            if count > 0 { throw BlobStoreError.integrityCheckFailed(relativePath) }
            throw BlobStoreError.fileSystemFailure(errno)
        }
        return data
    }

    private func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw BlobStoreError.fileSystemFailure(errno)
        }
    }

    private func synchronizeDirectory(_ descriptor: Int32) throws {
        try testDirectorySynchronizationHook?()
        try synchronize(descriptor)
    }

    private func sha256(relativePath: String, rootDescriptor: Int32) throws -> String {
        let descriptor = try openRegularFile(
            relativePath,
            rootDescriptor: rootDescriptor,
            missingError: .fileSystemFailure(ENOENT)
        )
        defer { close(descriptor) }
        return sha256(try readData(descriptor: descriptor, relativePath: relativePath))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(relativePath: String) throws {
        guard
            !relativePath.isEmpty,
            relativePath == URL(fileURLWithPath: relativePath).lastPathComponent,
            !relativePath.contains("/"),
            !relativePath.contains("\\")
        else {
            throw BlobStoreError.invalidRelativePath(relativePath)
        }
    }

    private func metadataIfExists(at url: URL) throws -> stat? {
        var metadata = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &metadata)
        }
        guard result != 0 else { return metadata }
        let error = errno
        if error == ENOENT { return nil }
        throw BlobStoreError.fileSystemFailure(error)
    }

    private func isOwnedDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR && metadata.st_uid == geteuid()
    }

    private func isOwnedSingleLinkRegularFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == geteuid()
            && metadata.st_nlink == 1
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}

private struct BlobStoreObjectIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}

private final class BlobStoreDirectoryState {
    let operationLock = NSRecursiveLock()
    var pinnedIdentity: BlobStoreObjectIdentity?
}

private final class BlobStoreOperationLockRegistry: @unchecked Sendable {
    static let shared = BlobStoreOperationLockRegistry()

    private final class WeakState {
        weak var value: BlobStoreDirectoryState?

        init(_ value: BlobStoreDirectoryState) {
            self.value = value
        }
    }

    private let registryLock = NSLock()
    private var statesByDirectory: [String: WeakState] = [:]

    func state(for directory: URL) -> BlobStoreDirectoryState {
        // The literal standardized path is the storage authority. Resolving a
        // mutable symlink here would let replacement choose a different lock
        // and root identity state before BlobStore validates the directory.
        let key = directory.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = statesByDirectory[key]?.value {
            return existing
        }
        statesByDirectory = statesByDirectory.filter { $0.value.value != nil }
        let created = BlobStoreDirectoryState()
        statesByDirectory[key] = WeakState(created)
        return created
    }
}
