import AppKit
import BlocksScreenshotCore
import OSLog

struct ScreenshotPasteboardArtifactDiagnostic: Equatable, CustomStringConvertible {
    enum Phase: String, Equatable {
        case startupCleanup = "startup"
        case supersededCleanup = "superseded"
        case rollbackCleanup = "rollback"
        case retryCleanup = "retry"
    }

    let phase: Phase
    let errorDomain: String
    let errorCode: Int

    var description: String {
        "phase=\(phase.rawValue) domain=\(errorDomain) code=\(errorCode)"
    }
}

actor ScreenshotPasteboardArtifactStore {
    typealias PermissionSetter = (URL, Int) throws -> Void
    typealias RemoveItem = (URL) throws -> Void
    typealias DiagnosticHandler = (ScreenshotPasteboardArtifactDiagnostic) -> Void

    static let shared = ScreenshotPasteboardArtifactStore()

    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "screenshot-pasteboard-artifact"
    )

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let permissionSetter: PermissionSetter
    private let removeItem: RemoveItem
    private let diagnosticHandler: DiagnosticHandler
    private let retainedArtifactCount: Int
    private let retentionInterval: TimeInterval
    private let now: () -> Date
    private let cleanupRetryDelay: Duration
    private let cleanupRetryLimit: Int
    private var hasPrunedAbandonedArtifacts = false
    private var pendingArtifactURLs: Set<URL> = []
    private var pendingCleanupAttempts: [URL: Int] = [:]
    private var cleanupRetryTask: Task<Void, Never>?
    private var publishedChangeCount: Int?

    private static let artifactPrefix = "blocks-screenshot-"

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        retainedArtifactCount: Int = 8,
        retentionInterval: TimeInterval = 24 * 60 * 60,
        permissionSetter: PermissionSetter? = nil,
        removeItem: RemoveItem? = nil,
        diagnosticHandler: DiagnosticHandler? = nil,
        now: @escaping () -> Date = Date.init,
        cleanupRetryDelay: Duration = .milliseconds(50),
        cleanupRetryLimit: Int = 2
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("app.blocks", isDirectory: true)
                .appendingPathComponent("Pasteboard", isDirectory: true)
                .appendingPathComponent("Screenshots", isDirectory: true)
        self.permissionSetter = permissionSetter ?? { url, permissions in
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
        self.retainedArtifactCount = max(2, retainedArtifactCount)
        self.retentionInterval = max(60, retentionInterval)
        self.now = now
        self.cleanupRetryDelay = cleanupRetryDelay
        self.cleanupRetryLimit = max(1, cleanupRetryLimit)
        self.diagnosticHandler = diagnosticHandler ?? { diagnostic in
            Self.logger.error(
                "cleanup-failed phase=\(diagnostic.phase.rawValue, privacy: .public) domain=\(diagnostic.errorDomain, privacy: .public) code=\(diagnostic.errorCode, privacy: .public)"
            )
        }
    }

    func prepare() {
        prepareIfNeeded()
        retryPendingCleanup()
    }

    func persist(_ pngData: Data) throws -> URL {
        prepareIfNeeded()
        retryPendingCleanup()
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setAndVerifyPermissions(0o700, at: rootDirectory)
        let artifactURL = rootDirectory.appendingPathComponent(
            "\(Self.artifactPrefix)\(UUID().uuidString).png"
        )
        do {
            guard fileManager.createFile(
                atPath: artifactURL.path,
                contents: pngData,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ScreenshotPasteboardArtifactStoreError.fileCreationFailed
            }
            try setAndVerifyPermissions(0o600, at: artifactURL)
            pendingArtifactURLs.insert(artifactURL.standardizedFileURL)
            return artifactURL
        } catch {
            if fileManager.fileExists(atPath: artifactURL.path) {
                remove(artifactURL, phase: .rollbackCleanup)
            }
            throw error
        }
    }

    func didPublish(_ artifactURL: URL, changeCount: Int) {
        retryPendingCleanup()
        let artifactURL = artifactURL.standardizedFileURL
        pendingArtifactURLs.remove(artifactURL)

        if let publishedChangeCount, changeCount < publishedChangeCount {
            remove(artifactURL, phase: .supersededCleanup)
            return
        }

        publishedChangeCount = changeCount
        removeManagedArtifacts(
            phase: .supersededCleanup,
            protecting: pendingArtifactURLs.union([artifactURL])
        )
    }

    func remove(_ artifactURL: URL) {
        let artifactURL = artifactURL.standardizedFileURL
        pendingArtifactURLs.remove(artifactURL)
        remove(artifactURL, phase: .rollbackCleanup)
    }

    func pendingCleanupCount() -> Int {
        pendingCleanupAttempts.count
    }

    private func prepareIfNeeded() {
        guard !hasPrunedAbandonedArtifacts else { return }
        hasPrunedAbandonedArtifacts = true
        pruneAbandonedArtifacts()
    }

    private func setAndVerifyPermissions(_ permissions: Int, at url: URL) throws {
        try permissionSetter(url, permissions)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actual = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard actual.map({ $0 & 0o777 }) == permissions else {
            throw ScreenshotPasteboardArtifactStoreError.invalidPermissions
        }
    }

    private func managedArtifacts() throws -> [(url: URL, modificationDate: Date)] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix(Self.artifactPrefix) && $0.pathExtension == "png"
        }.map { url in
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return (url, date)
        }
    }

    private func pruneAbandonedArtifacts() {
        let artifacts: [(url: URL, modificationDate: Date)]
        do {
            artifacts = try managedArtifacts().sorted { $0.modificationDate > $1.modificationDate }
        } catch {
            reportCleanupFailure(error, phase: .startupCleanup)
            return
        }
        guard let newest = artifacts.first else { return }
        let expirationDate = now().addingTimeInterval(-retentionInterval)
        // The newest handoff survives a normal immediate relaunch, but it is
        // not immortal: an abandoned singleton must age out after retention.
        if newest.modificationDate < expirationDate {
            remove(newest.url, phase: .startupCleanup)
        }
        for (index, artifact) in artifacts.enumerated() where artifact.url != newest.url {
            if artifact.modificationDate < expirationDate || index >= retainedArtifactCount {
                remove(artifact.url, phase: .startupCleanup)
            }
        }
    }

    private func removeManagedArtifacts(
        phase: ScreenshotPasteboardArtifactDiagnostic.Phase,
        protecting protectedURLs: Set<URL> = []
    ) {
        let artifacts: [(url: URL, modificationDate: Date)]
        do {
            artifacts = try managedArtifacts()
        } catch {
            reportCleanupFailure(error, phase: phase)
            return
        }
        let protectedPaths = Set(
            protectedURLs.map(\.standardizedFileURL.path)
        )
        for artifact in artifacts
            where !protectedPaths.contains(
                artifact.url.standardizedFileURL.path
            ) {
            remove(artifact.url, phase: phase)
        }
    }

    private func remove(
        _ url: URL,
        phase: ScreenshotPasteboardArtifactDiagnostic.Phase
    ) {
        do {
            try removeItem(url)
            pendingCleanupAttempts.removeValue(forKey: url.standardizedFileURL)
        } catch {
            reportCleanupFailure(error, phase: phase)
            scheduleCleanupRetry(for: url.standardizedFileURL)
        }
    }

    private func scheduleCleanupRetry(for url: URL) {
        let attempts = pendingCleanupAttempts[url, default: 0] + 1
        pendingCleanupAttempts[url] = attempts
        guard attempts < cleanupRetryLimit, cleanupRetryTask == nil else { return }
        let delay = cleanupRetryDelay
        cleanupRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.retryPendingCleanup()
        }
    }

    private func retryPendingCleanup() {
        cleanupRetryTask = nil
        let urls = Array(pendingCleanupAttempts.keys)
        for url in urls {
            do {
                try removeItem(url)
                pendingCleanupAttempts.removeValue(forKey: url)
            } catch {
                reportCleanupFailure(error, phase: .retryCleanup)
                scheduleCleanupRetry(for: url)
            }
        }
    }

    private func reportCleanupFailure(
        _ error: Error,
        phase: ScreenshotPasteboardArtifactDiagnostic.Phase
    ) {
        let nsError = error as NSError
        diagnosticHandler(ScreenshotPasteboardArtifactDiagnostic(
            phase: phase,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        ))
    }
}

private enum ScreenshotPasteboardArtifactStoreError: Error {
    case fileCreationFailed
    case invalidPermissions
}

@MainActor
protocol ScreenshotPasteboardWriting {
    @discardableResult
    func write(_ image: NSImage) async throws -> ClipboardPasteboardWriteLease

    @discardableResult
    func write(
        _ artifact: FinalizedScreenshotArtifact
    ) async throws -> ClipboardPasteboardWriteLease

    @discardableResult
    func write(
        _ artifact: FinalizedScreenshotArtifact,
        operationAllowed: @escaping @MainActor () -> Bool
    ) async throws -> ClipboardPasteboardWriteLease
}

extension ScreenshotPasteboardWriting {
    @discardableResult
    func write(
        _ artifact: FinalizedScreenshotArtifact
    ) async throws -> ClipboardPasteboardWriteLease {
        try await write(artifact.image)
    }

}

@MainActor
struct ScreenshotPasteboardWriter: ScreenshotPasteboardWriting {
    enum WriteError: Error {
        case missingCGImage
        case writeFailed
    }

    private let pasteboardWriter: ClipboardPasteboardWriter
    private let changeSuppressor: ClipboardPasteboardChangeSuppressor
    private let artifactStore: ScreenshotPasteboardArtifactStore

    init(
        broker: (any ClipboardBrokerServing)? = nil,
        changeSuppressor: ClipboardPasteboardChangeSuppressor? = nil,
        artifactStore: ScreenshotPasteboardArtifactStore = .shared
    ) {
        pasteboardWriter = ClipboardPasteboardWriter(
            broker: broker ?? ClipboardBrokerClient.shared
        )
        self.changeSuppressor = changeSuppressor ?? .shared
        self.artifactStore = artifactStore
    }

    @discardableResult
    func write(
        _ image: NSImage
    ) async throws -> ClipboardPasteboardWriteLease {
        try await write(image, writer: pasteboardWriter)
    }

    @discardableResult
    func write(
        _ artifact: FinalizedScreenshotArtifact
    ) async throws -> ClipboardPasteboardWriteLease {
        try await write(artifact, operationAllowed: { true })
    }

    @discardableResult
    func write(
        _ artifact: FinalizedScreenshotArtifact,
        operationAllowed: @escaping @MainActor () -> Bool
    ) async throws -> ClipboardPasteboardWriteLease {
        try await write(
            pngData: artifact.pngData,
            writer: pasteboardWriter,
            operationAllowed: operationAllowed
        )
    }

    @discardableResult
    func write(
        _ image: NSImage,
        pasteboard: any ClipboardPasteboardWriting
    ) async throws -> ClipboardPasteboardWriteLease {
        try await write(
            image,
            writer: ClipboardPasteboardWriter(
                pasteboard: pasteboard,
                changeSuppressor: changeSuppressor
            )
        )
    }

    private func write(
        _ image: NSImage,
        writer: ClipboardPasteboardWriter
    ) async throws -> ClipboardPasteboardWriteLease {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WriteError.missingCGImage
        }
        let pngData = try await Task.detached(priority: .userInitiated) {
            try ScreenshotImageEncoder().pngData(cgImage)
        }.value
        return try await write(pngData: pngData, writer: writer)
    }

    private func write(
        pngData: Data,
        writer: ClipboardPasteboardWriter,
        operationAllowed: @escaping @MainActor () -> Bool = { true }
    ) async throws -> ClipboardPasteboardWriteLease {
        guard operationAllowed() else {
            throw ClipboardAutoPasteError.featureDisabled
        }
        let artifactURL = try await artifactStore.persist(pngData)
        let representations: [NSPasteboard.PasteboardType: ClipboardPasteboardRepresentation] = [
            NSPasteboard.PasteboardType.png: .data(pngData),
            .fileURL: .string(artifactURL.absoluteString),
        ]
        let replacement = ClipboardPasteboardWriteItem(representations: representations)
        let lease: ClipboardPasteboardWriteLease
        do {
            guard operationAllowed() else {
                await artifactStore.remove(artifactURL)
                throw ClipboardAutoPasteError.featureDisabled
            }
            lease = try await writer.writePreparedItems(
                [replacement],
                operationAllowed: operationAllowed,
                requiresPreparedAuthorization: true
            )
        } catch {
            await artifactStore.remove(artifactURL)
            throw WriteError.writeFailed
        }
        await artifactStore.didPublish(
            artifactURL,
            changeCount: lease.changeCount
        )
        return lease
    }
}
