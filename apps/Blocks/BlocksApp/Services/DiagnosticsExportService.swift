import Foundation
import Darwin
import OSLog

/// Content-free, bounded breadcrumbs. Memory-only: export before restarting.
/// No arbitrary strings/record IDs are accepted at the instrumentation boundary.
final class ClipboardInteractionTrace: @unchecked Sendable {
    enum Stage: String, Codable, Sendable {
        case openRequested, openSuppressed, presentationStarted, presented, reused, monitorStarted
        case externalDismiss, closeRequested, closeIgnoredPinned, closeIgnoredPending
        case closeStarted, orderedOut, closeCompleted, staleCloseCompletion
        case filterPointer, filterSelection, probeAttached, probeDetached
        case rowHover, favoriteHover, favoriteAction, rowDisappeared
    }
    struct Event: Codable, Sendable {
        let sequence: UInt64
        let time: Date
        let uptime: TimeInterval
        let session: UUID
        let stage: Stage
        let group: String?
        let control: UUID?
        let window: Int?
        let key: Bool?
        let visible: Bool?
        let pinned: Bool?
        let pending: Bool?
        let animated: Bool?
        let hovered: Bool?
        let favorite: Bool?
        let alpha: Double?
        let screenCount: Int?
    }
    struct Snapshot: Codable, Sendable {
        let capacity: Int
        let dropped: UInt64
        let events: [Event]
    }
    static let shared = ClipboardInteractionTrace()
    private let lock = NSLock()
    private let capacity = 256
    private var events: [Event] = []
    private var sequence: UInt64 = 0
    private var session = UUID()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.blocks", category: "clipboard-interaction")

    func record(_ stage: Stage, group: ClipboardFilterGroup? = nil, control: UUID? = nil,
                window: Int? = nil, key: Bool? = nil, visible: Bool? = nil,
                pinned: Bool? = nil, pending: Bool? = nil, animated: Bool? = nil,
                hovered: Bool? = nil, favorite: Bool? = nil, alpha: Double? = nil,
                screenCount: Int? = nil) {
        lock.lock()
        if stage == .openRequested { session = UUID() }
        sequence &+= 1
        let event = Event(sequence: sequence, time: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                          session: session, stage: stage, group: group?.rawValue, control: control,
                          window: window, key: key, visible: visible, pinned: pinned, pending: pending,
                          animated: animated, hovered: hovered, favorite: favorite, alpha: alpha,
                          screenCount: screenCount)
        if events.count == capacity { events.removeFirst() }
        events.append(event)
        lock.unlock()
        // Unified logging is supplementary; export does not depend on debug retention.
        let line = "seq=\(event.sequence) session=\(event.session) stage=\(stage.rawValue)"
            + " group=\(event.group ?? "none") control=\(control?.uuidString ?? "none") window=\(window ?? -1)"
            + " key=\(String(describing: key)) visible=\(String(describing: visible)) pinned=\(String(describing: pinned))"
            + " pending=\(String(describing: pending)) animated=\(String(describing: animated)) alpha=\(String(describing: alpha))"
            + " hover=\(String(describing: hovered)) favorite=\(String(describing: favorite)) screens=\(screenCount ?? -1)"
        if stage == .rowHover || stage == .favoriteHover {
            logger.debug("\(line, privacy: .public)")
        } else {
            logger.info("\(line, privacy: .public)")
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(capacity: capacity, dropped: sequence - UInt64(events.count), events: events)
    }
}

struct BlocksDiagnosticReport: Codable, Sendable {
    struct Application: Codable, Sendable {
        let releaseName: String
        let version: String
        let build: String
        let channel: String
        let bundleIdentifier: String
    }

    struct SystemSummary: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
    }

    struct PermissionSummary: Codable, Sendable {
        let screenRecordingGranted: Bool
        let accessibilityGranted: Bool
        let inputMonitoringGranted: Bool
        let signatureKind: String
        let screenRecordingAction: String
        let accessibilityAction: String
        let inputMonitoringAction: String
    }

    struct RedactedAuditEvent: Codable, Sendable {
        let createdAt: Date
        let kind: String
        let warningCount: Int
    }

    let schemaVersion: Int
    let generatedAt: Date
    let application: Application
    let system: SystemSummary
    let permissions: PermissionSummary
    let redactedAuditEvents: [RedactedAuditEvent]
    let excludedData: [String]
    let clipboardInteractionTrace: ClipboardInteractionTrace.Snapshot?
}

enum DiagnosticsExportService {
    enum ExportError: Error, Equatable {
        case destinationChanged
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
    }
    /// Captures the deliberately redacted report while the caller owns its
    /// application state. Encoding and filesystem I/O remain off MainActor.
    static func makeReport(
        permissionSnapshot: PermissionStateSnapshot,
        providerAuditEvents: [ProviderAuditEvent],
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        now: Date = Date()
    ) -> BlocksDiagnosticReport {
        BlocksDiagnosticReport(
            schemaVersion: 2,
            generatedAt: now,
            application: .init(
                releaseName: BlocksReleaseMetadata.releaseName,
                version: BlocksReleaseMetadata.version,
                build: BlocksReleaseMetadata.build,
                channel: DistributionChannel.current.rawValue,
                bundleIdentifier: bundle.bundleIdentifier ?? "unknown"
            ),
            system: .init(
                operatingSystem: processInfo.operatingSystemVersionString,
                architecture: architecture
            ),
            permissions: .init(
                screenRecordingGranted: permissionSnapshot.screenRecordingGranted,
                accessibilityGranted: permissionSnapshot.accessibilityGranted,
                inputMonitoringGranted: permissionSnapshot.inputMonitoringGranted,
                signatureKind: permissionSnapshot.screenRecording.signatureKind,
                screenRecordingAction:
                    permissionSnapshot.screenRecording.recommendedAction.rawValue,
                accessibilityAction:
                    permissionSnapshot.accessibility.recommendedAction.rawValue,
                inputMonitoringAction:
                    permissionSnapshot.inputMonitoring.recommendedAction.rawValue
            ),
            redactedAuditEvents: providerAuditEvents.prefix(50).map { event in
                .init(
                    createdAt: event.createdAt,
                    kind: event.kind.rawValue,
                    warningCount: event.warnings.count
                )
            },
            excludedData: [
                "clipboard_content",
                "screenshots",
                "api_keys_and_keychain_values",
                "provider_endpoints_and_identifiers",
                "file_paths",
                "team_identifier",
                "raw_application_logs",
            ],
            clipboardInteractionTrace: ClipboardInteractionTrace.shared.snapshot()
        )
    }

    static func makeReportData(
        permissionSnapshot: PermissionStateSnapshot,
        providerAuditEvents: [ProviderAuditEvent],
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        now: Date = Date()
    ) throws -> Data {
        try encode(
            makeReport(
                permissionSnapshot: permissionSnapshot,
                providerAuditEvents: providerAuditEvents,
                bundle: bundle,
                processInfo: processInfo,
                now: now
            )
        )
    }

    static func writeReport(
        _ report: BlocksDiagnosticReport,
        to destinationURL: URL,
        beforeCommit: @escaping @Sendable () -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        let encodingTask: Task<Data, Error> = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try encode(report)
        }
        let data = try await valueForwardingCancellation(of: encodingTask)
        try Task.checkCancellation()
        let writeTask: Task<Void, Error> = Task.detached(priority: .utility) {
            try writeData(
                data,
                to: destinationURL,
                beforeCommit: beforeCommit
            )
        }
        try await valueForwardingCancellation(of: writeTask)
    }

    /// Awaits detached work while forwarding cancellation from the caller.
    /// Detached tasks do not inherit cancellation automatically.
    private static func valueForwardingCancellation<Value: Sendable>(
        of task: Task<Value, Error>
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Writes the private temporary file beside its destination, then commits it
    /// with a single rename. Cancellation is intentionally checked only before
    /// that commit: once rename succeeds, this returns success even if the
    /// caller is cancelled concurrently.
    private static func writeData(
        _ data: Data,
        to destinationURL: URL,
        beforeCommit: @escaping @Sendable () -> Void
    ) throws {
        let fileManager = FileManager.default
        let destinationIdentity = fileIdentity(at: destinationURL)
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).diagnostics-\(UUID().uuidString).tmp"
            )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try Task.checkCancellation()
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try Task.checkCancellation()
        beforeCommit()
        try Task.checkCancellation()
        guard fileIdentity(at: destinationURL) == destinationIdentity else {
            throw ExportError.destinationChanged
        }
        let renameResult: Int32
        if let destinationIdentity {
            guard let temporaryIdentity = fileIdentity(at: temporaryURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
            renameResult = atomicRename(
                from: temporaryURL,
                to: destinationURL,
                flags: UInt32(RENAME_SWAP)
            )
            guard renameResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard fileIdentity(at: destinationURL) == temporaryIdentity,
                  fileIdentity(at: temporaryURL) == destinationIdentity else {
                // The existing destination changed between the identity check
                // and swap. Restore it only while both paths still identify
                // the two objects from this transaction; otherwise a later
                // writer owns the destination and must be preserved.
                if fileIdentity(at: destinationURL) == temporaryIdentity {
                    _ = atomicRename(
                        from: temporaryURL,
                        to: destinationURL,
                        flags: UInt32(RENAME_SWAP)
                    )
                }
                throw ExportError.destinationChanged
            }
        } else {
            renameResult = atomicRename(
                from: temporaryURL,
                to: destinationURL,
                flags: UInt32(RENAME_EXCL)
            )
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func atomicRename(from sourceURL: URL, to destinationURL: URL, flags: UInt32) -> Int32 {
        sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, flags)
            }
        }
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return FileIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            generation: metadata.st_gen
        )
    }

    private static func encode(_ report: BlocksDiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    static var suggestedFilename: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let release = BlocksReleaseMetadata.releaseName.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        return "Blocks-Diagnostics-\(String(release)).json"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
