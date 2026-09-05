import BlocksCore
import Foundation

/// v19 no longer stores binary watermark assets. This narrowly scoped helper
/// exists only to remove files left by v18 signature/image presets after a
/// successful preferences migration.
final class ScreenshotWatermarkAssetStore: @unchecked Sendable {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory.standardizedFileURL
        } else if let environment = try? StorageEnvironment.appSupport(fileManager: fileManager) {
            self.directory = environment.rootDirectory
                .appendingPathComponent("ScreenshotWatermarks", isDirectory: true)
                .standardizedFileURL
        } else {
            self.directory = URL(fileURLWithPath: "/dev/null/Blocks-ScreenshotWatermarks")
        }
    }

    func cleanupOrphans(retaining _: Set<String>, createdBefore: Date? = nil) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if let createdBefore,
               let creationDate = values.creationDate,
               creationDate > createdBefore { continue }
            try fileManager.removeItem(at: entry)
        }
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? fileManager.removeItem(at: directory)
        }
    }
}
