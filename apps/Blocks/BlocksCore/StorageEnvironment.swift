import Foundation

public enum BlocksRuntimeEnvironment {
    public static let unitTestingOverrideEnvironmentKey = "BLOCKS_UNIT_TESTING"
    fileprivate static let unitTestStorageSessionID = UUID().uuidString

    public static var isUnitTestHost: Bool {
        isUnitTestHost(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    public static func isUnitTestHost(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        if environment[unitTestingOverrideEnvironmentKey] == "1" {
            return true
        }
        let xctestEnvironmentKeys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCInjectBundleInto",
        ]
        if xctestEnvironmentKeys.contains(where: { environment[$0]?.isEmpty == false }) {
            return true
        }
        return arguments.contains(where: { $0.localizedCaseInsensitiveContains("xctest") })
    }
}

public struct StorageEnvironment {
    public static let storageRootOverrideEnvironmentKey = "BLOCKS_STORAGE_ROOT"

    public let rootDirectory: URL
    public let databaseURL: URL
    public let blobDirectory: URL

    public init(rootDirectory: URL) {
        let standardizedRoot = rootDirectory.standardizedFileURL
        self.rootDirectory = standardizedRoot
        self.databaseURL = standardizedRoot.appendingPathComponent("Blocks.sqlite", isDirectory: false)
        self.blobDirectory = standardizedRoot.appendingPathComponent("Blobs", isDirectory: true)
    }

    public static func appSupport(fileManager: FileManager = .default) throws -> StorageEnvironment {
        if let overrideRoot = ProcessInfo.processInfo.environment[storageRootOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overrideRoot.isEmpty {
            return StorageEnvironment(rootDirectory: URL(fileURLWithPath: overrideRoot, isDirectory: true))
        }

        if BlocksRuntimeEnvironment.isUnitTestHost {
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("BlocksTests", isDirectory: true)
                .appendingPathComponent(
                    "\(ProcessInfo.processInfo.processIdentifier)-\(BlocksRuntimeEnvironment.unitTestStorageSessionID)",
                    isDirectory: true
                )
                .appendingPathComponent("Data", isDirectory: true)
            return StorageEnvironment(rootDirectory: root)
        }

        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StorageEnvironmentError.applicationSupportDirectoryUnavailable
        }
        let root = appSupport
            .appendingPathComponent(
                BlocksRuntimeIdentity.applicationSupportDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("Data", isDirectory: true)
        return StorageEnvironment(rootDirectory: root)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
    }
}

public enum StorageEnvironmentError: Error, LocalizedError {
    case applicationSupportDirectoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "Application Support directory is unavailable."
        }
    }
}
