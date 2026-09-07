import AppKit
import BlocksCore
import CryptoKit
import Darwin
import Foundation
import SwiftUI

struct AgentCLISettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var cliInstaller =
        BlocksCLIInstallationController()
    @State private var showsUninstallConfirmation = false
    @AppStorage("clipboard.agent.summaryAccess") private var clipboardAgentSummaryAccess = true
    @AppStorage("clipboard.agent.defaultScope") private var clipboardAgentDefaultScope = "single"
    @AppStorage("clipboard.agent.defaultDuration") private var clipboardAgentDefaultDuration = "once"

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        ActionBrokerSettingsSection(manager: appModel.actionBrokerManager)

        SettingsSection(
            title: L10n.string("settings.agentCLI.access")
        ) {
            SettingsSectionNote(
                text: L10n.string("settings.clipboardAgentFullContentGate")
            )

            SettingsRowDivider()

            SettingsToggleRow(
                title: L10n.string("settings.clipboardAgentSummaryAccess"),
                isOn: $clipboardAgentSummaryAccess
            )

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.clipboardAgentDefaultScope")
            ) {
                Picker(L10n.string("settings.clipboardAgentDefaultScope"), selection: $clipboardAgentDefaultScope) {
                    Text(L10n.string("settings.clipboardAgentScope.single")).tag("single")
                    Text(L10n.string("settings.clipboardAgentScope.filtered")).tag("filtered")
                    Text(L10n.string("settings.clipboardAgentScope.manual")).tag("manual")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            SettingsRowDivider()

            SettingsFormRow(
                title: L10n.string("settings.clipboardAgentDefaultDuration")
            ) {
                Picker(L10n.string("settings.clipboardAgentDefaultDuration"), selection: $clipboardAgentDefaultDuration) {
                    Text(L10n.string("settings.clipboardAgentDuration.once")).tag("once")
                    Text("5m").tag("5m")
                    Text("30m").tag("30m")
                    Text(L10n.string("settings.clipboardAgentDuration.session")).tag("session")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }

        SettingsSection(
            title: L10n.string("settings.agentCLI.localCLI")
        ) {
            SettingsStatusRow(
                title: L10n.string("settings.agentCLI.install.title"),
                detail: L10n.string("settings.agentCLI.install.detail"),
                status: cliInstaller.statusPresentation
            ) {
                AgentCLIActionControls(
                    installButtonTitle: cliInstaller.installButtonTitle,
                    canInstall: cliInstaller.canInstall,
                    showsUninstallAction:
                        cliInstaller.canUninstall
                        || cliInstaller.isUninstalling,
                    canUninstall: cliInstaller.canUninstall,
                    isBusy: cliInstaller.isBusy,
                    showsRecoveryAction:
                        cliInstaller.recoveryURL != nil
                        || cliInstaller.legacyDisplayURL != nil,
                    installAction: {
                        cliInstaller.chooseDestinationAndInstall()
                    },
                    uninstallAction: {
                        showsUninstallConfirmation = true
                    },
                    refreshAction: {
                        cliInstaller.refresh()
                    },
                    recoveryAction: {
                        cliInstaller.revealRecovery()
                    }
                )
            }
        }
        .alert(
            L10n.string("settings.agentCLI.uninstall.title"),
            isPresented: $showsUninstallConfirmation
        ) {
            Button(L10n.string("settings.agentCLI.uninstall.confirm"), role: .destructive) {
                cliInstaller.uninstall()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("settings.agentCLI.uninstall.message"))
        }
        .onAppear {
            cliInstaller.refresh()
        }
        .onDisappear {
            cliInstaller.cancelForRouteExit()
        }
    }
}

/// Keeps the primary install/update action directly reachable while placing
/// less frequent lifecycle actions in a width-stable native menu. This keeps
/// the shared settings value column intact at the 820-point window minimum.
struct AgentCLIActionControls: View {
    let installButtonTitle: String
    let canInstall: Bool
    let showsUninstallAction: Bool
    let canUninstall: Bool
    let isBusy: Bool
    let showsRecoveryAction: Bool
    let installAction: () -> Void
    let uninstallAction: () -> Void
    let refreshAction: () -> Void
    let recoveryAction: () -> Void

    var body: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            Button(installButtonTitle, action: installAction)
                .disabled(!canInstall)
                .settingsGeometryProbe("agentCLI.installAction")

            Menu {
                if showsUninstallAction {
                    Button(
                        L10n.string("settings.agentCLI.uninstall.button"),
                        action: uninstallAction
                    )
                    .disabled(!canUninstall)
                }

                Button(
                    L10n.string("settings.agentCLI.install.refresh"),
                    action: refreshAction
                )
                .disabled(isBusy)

                if showsRecoveryAction {
                    Button(
                        L10n.string("settings.agentCLI.recovery.reveal"),
                        action: recoveryAction
                    )
                    .accessibilityHint(
                        L10n.string("settings.agentCLI.recovery.revealHelp")
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(
                        width: BlocksVisualTokens.Control.compactHeight,
                        height: BlocksVisualTokens.Control.compactHeight
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(
                L10n.string("settings.agentCLI.actions.more")
            )
            .help(L10n.string("settings.agentCLI.actions.more"))
            .settingsGeometryProbe("agentCLI.moreActions")
        }
    }
}

enum BlocksCLIInstallationState: Equatable {
    case unavailable
    case notInstalled
    case installing
    case uninstalling
    case installedCurrent
    case installedOutdated
    case updateAvailable
    case changed
    case missing
    case inaccessible
    case destinationConflict
    case recoveryRequired
    case failed
}

private final class BlocksCLIJournalDefaultsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func save(_ data: Data) -> Bool {
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    func load() -> Data? {
        defaults.data(forKey: key)
    }

    func clear() -> Bool {
        defaults.removeObject(forKey: key)
        return defaults.data(forKey: key) == nil
    }
}

private final class BlocksCLIDurableDataFileStore: @unchecked Sendable {
    private let fileURL: URL
    private let legacyDefaults: BlocksCLIJournalDefaultsStore
    private let fileManager = FileManager.default
    private let fileSynchronizer: @Sendable (URL) -> Bool
    private let directorySynchronizer: @Sendable (URL) -> Bool
    private let lock = NSLock()

    init(
        fileURL: URL,
        legacyDefaults: BlocksCLIJournalDefaultsStore,
        fileSynchronizer: (@Sendable (URL) -> Bool)? = nil,
        directorySynchronizer: (@Sendable (URL) -> Bool)? = nil
    ) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        self.fileSynchronizer = fileSynchronizer ?? { url in
            Self.synchronizeFile(url)
        }
        self.directorySynchronizer = directorySynchronizer
            ?? { url in Self.synchronizeDirectory(url) }
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL) { return data }
        guard let legacy = legacyDefaults.load() else { return nil }
        if saveUnlocked(legacy) { _ = legacyDefaults.clear() }
        return legacy
    }

    func loadOperationJournal() -> BlocksCLIOperationJournalLoadResult {
        lock.lock()
        defer { lock.unlock() }

        switch pathPresence(at: fileURL) {
        case .present:
            do {
                return .readable(try Data(contentsOf: fileURL))
            } catch {
                // A journal that exists but cannot be read must block mutation.
                return .unreadable
            }
        case .unknown:
            return .unreadable
        case .absent:
            guard let legacy = legacyDefaults.load() else { return .absent }
            if saveUnlocked(legacy) { _ = legacyDefaults.clear() }
            return .readable(legacy)
        }
    }

    func save(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard saveUnlocked(data) else { return false }
        _ = legacyDefaults.clear()
        return true
    }

    func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let directoryURL = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                return false
            }
            guard directorySynchronizer(directoryURL),
                  !fileManager.fileExists(atPath: fileURL.path) else {
                return false
            }
        }
        return legacyDefaults.clear()
    }

    private func saveUnlocked(_ data: Data) -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var temporaryContainsPreviousValue = false
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary,
               fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
                _ = directorySynchronizer(directoryURL)
            }
        }
        do {
            guard ensureDurableDirectory(directoryURL) else { return false }
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: temporaryURL.path
            )
            guard fileSynchronizer(temporaryURL) else { return false }

            if fileManager.fileExists(atPath: fileURL.path) {
                guard atomicRename(
                    from: temporaryURL,
                    to: fileURL,
                    flags: UInt32(RENAME_SWAP)
                ) == 0 else {
                    return false
                }
                temporaryContainsPreviousValue = true
            } else {
                guard atomicRename(
                    from: temporaryURL,
                    to: fileURL,
                    flags: UInt32(RENAME_EXCL)
                ) == 0 else {
                    return false
                }
            }

            guard directorySynchronizer(directoryURL),
                  (try? Data(contentsOf: fileURL)) == data else {
                if temporaryContainsPreviousValue {
                    let rollbackResult = atomicRename(
                        from: temporaryURL,
                        to: fileURL,
                        flags: UInt32(RENAME_SWAP)
                    )
                    if rollbackResult == 0 {
                        _ = directorySynchronizer(directoryURL)
                    } else {
                        shouldRemoveTemporary = false
                    }
                } else if (try? Data(contentsOf: fileURL)) == data {
                    try? fileManager.removeItem(at: fileURL)
                    _ = directorySynchronizer(directoryURL)
                }
                return false
            }

            if temporaryContainsPreviousValue {
                try? fileManager.removeItem(at: temporaryURL)
                _ = directorySynchronizer(directoryURL)
                temporaryContainsPreviousValue = false
            }
            return true
        } catch {
            return false
        }
    }

    private func ensureDurableDirectory(_ directoryURL: URL) -> Bool {
        var missingDirectories: [URL] = []
        var cursor = directoryURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !fileManager.fileExists(
            atPath: cursor.path,
            isDirectory: &isDirectory
        ) {
            missingDirectories.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { return false }
            cursor = parent
        }
        guard isDirectory.boolValue else { return false }
        for directory in missingDirectories.reversed() {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            } catch {
                var racedDirectory = ObjCBool(false)
                guard fileManager.fileExists(
                    atPath: directory.path,
                    isDirectory: &racedDirectory
                ), racedDirectory.boolValue else {
                    return false
                }
            }
            guard directorySynchronizer(
                directory.deletingLastPathComponent()
            ) else {
                return false
            }
        }
        return true
    }

    private func atomicRename(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) -> Int32 {
        sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
    }

    private static func synchronizeFile(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return fsync(descriptor) == 0
    }

    private static func synchronizeDirectory(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return fsync(descriptor) == 0
    }

    private enum PathPresence {
        case present
        case absent
        case unknown
    }

    private func pathPresence(at url: URL) -> PathPresence {
        var metadata = stat()
        let result = url.path.withCString { path in
            lstat(path, &metadata)
        }
        if result == 0 { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .unknown
    }
}

/// A process-wide and cross-process lease for the CLI mutation transaction.
/// The journal protects crash recovery; this lease prevents another settings
/// controller from trying to recover or replace that journal while the owning
/// transaction is still alive.
final class BlocksCLIInstallationOperationLease: @unchecked Sendable {
    private static let processLock = NSLock()
    private static var activePaths = Set<String>()

    private let stateLock = NSLock()
    private let path: String
    private var descriptor: Int32?

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    static func acquire(at fileURL: URL) -> BlocksCLIInstallationOperationLease? {
        let standardizedURL = fileURL.standardizedFileURL
        let path = standardizedURL.path
        do {
            try FileManager.default.createDirectory(
                at: standardizedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        processLock.lock()
        guard activePaths.insert(path).inserted else {
            processLock.unlock()
            return nil
        }
        processLock.unlock()

        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            releaseProcessPath(path)
            return nil
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            releaseProcessPath(path)
            return nil
        }
        return BlocksCLIInstallationOperationLease(
            path: path,
            descriptor: descriptor
        )
    }

    func release() {
        stateLock.lock()
        guard let descriptor else {
            stateLock.unlock()
            return
        }
        self.descriptor = nil
        stateLock.unlock()

        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        Self.releaseProcessPath(path)
    }

    deinit {
        release()
    }

    private static func releaseProcessPath(_ path: String) {
        processLock.lock()
        activePaths.remove(path)
        processLock.unlock()
    }
}

struct BlocksCLIOperationLeaseProvider: @unchecked Sendable {
    let acquire: @Sendable () -> BlocksCLIInstallationOperationLease?
    let didRelease: @Sendable () -> Void

    init(
        acquire: @escaping @Sendable () -> BlocksCLIInstallationOperationLease?,
        didRelease: @escaping @Sendable () -> Void = {}
    ) {
        self.acquire = acquire
        self.didRelease = didRelease
    }

    static var live: Self {
        // Keep the advisory lock outside the durable State hierarchy. Creating
        // that hierarchy here would bypass the journal store's parent-directory
        // fsync protocol on the first mutation.
        return file(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "app.blocks.agent-cli-operation-\(getuid()).lock"
            )
        )
    }

    static func file(_ fileURL: URL) -> Self {
        Self(
            acquire: {
                BlocksCLIInstallationOperationLease.acquire(at: fileURL)
            }
        )
    }
}

enum BlocksCLIOperationJournalLoadResult: Equatable {
    case absent
    case readable(Data)
    case unreadable
}

struct BlocksCLIOperationJournalStore: @unchecked Sendable {
    let load: @Sendable () -> BlocksCLIOperationJournalLoadResult
    let save: @Sendable (Data) -> Bool
    let clear: @Sendable () -> Bool

    static func live(defaults: UserDefaults, key: String) -> Self {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return durable(
            fileURL: applicationSupport
                .appendingPathComponent(BlocksRuntimeIdentity.applicationSupportDirectoryName, isDirectory: true)
                .appendingPathComponent("State", isDirectory: true)
                .appendingPathComponent("agent-cli-operation-journal-v1.json"),
            defaults: defaults,
            key: key
        )
    }

    static func durable(
        fileURL: URL,
        defaults: UserDefaults,
        key: String,
        fileSynchronizer: (@Sendable (URL) -> Bool)? = nil,
        directorySynchronizer: (@Sendable (URL) -> Bool)? = nil
    ) -> Self {
        let legacy = BlocksCLIJournalDefaultsStore(
            defaults: defaults,
            key: key
        )
        let file = BlocksCLIDurableDataFileStore(
            fileURL: fileURL,
            legacyDefaults: legacy,
            fileSynchronizer: fileSynchronizer,
            directorySynchronizer: directorySynchronizer
        )
        return Self(
            load: { file.loadOperationJournal() },
            save: { file.save($0) },
            clear: { file.clear() }
        )
    }

    static func defaults(
        _ defaults: UserDefaults,
        key: String,
        saveOverride: (@Sendable (Data) -> Bool)? = nil
    ) -> Self {
        let store = BlocksCLIJournalDefaultsStore(
            defaults: defaults,
            key: key
        )
        return Self(
            load: { store.load().map(BlocksCLIOperationJournalLoadResult.readable) ?? .absent },
            save: saveOverride ?? { store.save($0) },
            clear: { store.clear() }
        )
    }
}

struct BlocksCLIInstallationRecordStore: @unchecked Sendable {
    let load: @Sendable () -> Data?
    let save: @Sendable (Data) -> Bool
    let clear: @Sendable () -> Bool

    static func live(defaults: UserDefaults, key: String) -> Self {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return durable(
            fileURL: applicationSupport
                .appendingPathComponent(BlocksRuntimeIdentity.applicationSupportDirectoryName, isDirectory: true)
                .appendingPathComponent("State", isDirectory: true)
                .appendingPathComponent("agent-cli-installation-record-v1.json"),
            defaults: defaults,
            key: key
        )
    }

    static func durable(
        fileURL: URL,
        defaults: UserDefaults,
        key: String,
        fileSynchronizer: (@Sendable (URL) -> Bool)? = nil,
        directorySynchronizer: (@Sendable (URL) -> Bool)? = nil
    ) -> Self {
        let legacy = BlocksCLIJournalDefaultsStore(
            defaults: defaults,
            key: key
        )
        let file = BlocksCLIDurableDataFileStore(
            fileURL: fileURL,
            legacyDefaults: legacy,
            fileSynchronizer: fileSynchronizer,
            directorySynchronizer: directorySynchronizer
        )
        return Self(
            load: { file.load() },
            save: { file.save($0) },
            clear: { file.clear() }
        )
    }

    static func defaults(
        _ defaults: UserDefaults,
        key: String,
        saveOverride: (@Sendable (Data) -> Bool)? = nil
    ) -> Self {
        let store = BlocksCLIJournalDefaultsStore(
            defaults: defaults,
            key: key
        )
        return Self(
            load: { store.load() },
            save: saveOverride ?? { store.save($0) },
            clear: { store.clear() }
        )
    }
}

struct BlocksCLIInstaller {
    enum InstallationError: Error {
        case sourceUnavailable
        case verificationFailed
        case destinationExists
        case destinationChanged
        case destinationRecoveryRequired(URL)
    }

    @discardableResult
    static func install(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default,
        allowReplacingExistingDestination: Bool = true,
        retainDisplacedDestination: Bool = false,
        validateDestinationBeforeCommit: () -> Bool = { true },
        persistOperationJournal: (URL) -> Bool = { _ in true },
        validateReplacedDestination: (URL) -> Bool = { _ in true },
        verifyTemporaryFile: (URL, URL, FileManager) -> Bool = { sourceURL, temporaryURL, fileManager in
            fileManager.isExecutableFile(atPath: temporaryURL.path)
                && fileManager.contentsEqual(
                    atPath: sourceURL.path,
                    andPath: temporaryURL.path
                )
        }
    ) throws -> URL? {
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw InstallationError.sourceUnavailable
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        guard allowReplacingExistingDestination
                || !fileManager.fileExists(atPath: destinationURL.path) else {
            throw InstallationError.destinationExists
        }
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = parentURL.appendingPathComponent(
            ".blocks-install-\(UUID().uuidString)"
        )
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: temporaryURL.path
        )
        guard verifyTemporaryFile(sourceURL, temporaryURL, fileManager) else {
            throw InstallationError.verificationFailed
        }
        guard let temporaryIdentity = BlocksCLIFileIdentity.resourceIdentifier(
            of: temporaryURL
        ) else {
            throw InstallationError.verificationFailed
        }
        guard validateDestinationBeforeCommit() else {
            throw InstallationError.destinationChanged
        }
        // This is the last durable point before either atomic rename. Refusing
        // the commit here is deliberate: an unjournaled rename is unrecoverable.
        guard persistOperationJournal(temporaryURL) else {
            throw InstallationError.verificationFailed
        }
        if allowReplacingExistingDestination,
           fileManager.fileExists(atPath: destinationURL.path) {
            guard atomicRename(
                from: temporaryURL,
                to: destinationURL,
                flags: UInt32(RENAME_SWAP)
            ) == 0 else {
                throw InstallationError.destinationChanged
            }
            guard BlocksCLIFileIdentity.resourceIdentifier(of: destinationURL)
                    == temporaryIdentity else {
                // The destination changed again after the swap. A path-based
                // rollback could move another process's file, so preserve the
                // displaced object at the unique recovery URL instead.
                shouldRemoveTemporary = false
                throw InstallationError.destinationRecoveryRequired(temporaryURL)
            }
            guard validateReplacedDestination(temporaryURL) else {
                // The object displaced by the swap is not the managed CLI we
                // validated before commit. Restore it only while both swap
                // participants still have the identities observed here.
                guard let displacedIdentity =
                        BlocksCLIFileIdentity.resourceIdentifier(of: temporaryURL),
                      atomicRename(
                          from: temporaryURL,
                          to: destinationURL,
                          flags: UInt32(RENAME_SWAP)
                      ) == 0,
                      BlocksCLIFileIdentity.resourceIdentifier(of: destinationURL)
                        == displacedIdentity,
                      BlocksCLIFileIdentity.resourceIdentifier(of: temporaryURL)
                        == temporaryIdentity else {
                    shouldRemoveTemporary = false
                    throw InstallationError.destinationRecoveryRequired(temporaryURL)
                }
                throw InstallationError.destinationChanged
            }
            if retainDisplacedDestination {
                shouldRemoveTemporary = false
                return temporaryURL
            }
        } else {
            guard atomicRename(
                from: temporaryURL,
                to: destinationURL,
                flags: UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == EEXIST {
                    throw InstallationError.destinationExists
                }
                throw InstallationError.destinationChanged
            }
        }
        return nil
    }

    private static func atomicRename(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) -> Int32 {
        sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
    }

    static func isCurrentInstallation(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.isExecutableFile(atPath: destinationURL.path)
            && fileManager.contentsEqual(
                atPath: sourceURL.path,
                andPath: destinationURL.path
            )
    }

    static func installationState(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) -> BlocksCLIInstallationState {
        guard fileManager.isExecutableFile(
            atPath: destinationURL.path
        ) else {
            return .notInstalled
        }
        return fileManager.contentsEqual(
            atPath: sourceURL.path,
            andPath: destinationURL.path
        ) ? .installedCurrent : .installedOutdated
    }
}

struct BlocksCLIPreservedCleanupArtifact: Codable, Equatable {
    let securityScopedBookmark: Data
    let expectedSHA256: String
    let expectedFileIdentity: Data
    let displayPath: String
}

struct BlocksCLIInstallationRecord: Codable, Equatable {
    let securityScopedBookmark: Data
    let directorySecurityScopedBookmark: Data?
    let installedSHA256: String
    let installedFileIdentity: Data?
    let appVersion: String
    let displayPath: String
    /// A verified pre-update executable that could not be identity-conditionally
    /// unlinked. Keeping this in the fsync-backed installation record makes the
    /// reveal hint durable and prevents later updates from orphaning it.
    let preservedCleanupArtifacts: [BlocksCLIPreservedCleanupArtifact]?

    init(
        securityScopedBookmark: Data,
        directorySecurityScopedBookmark: Data? = nil,
        installedSHA256: String,
        installedFileIdentity: Data? = nil,
        appVersion: String,
        displayPath: String,
        preservedCleanupArtifacts: [BlocksCLIPreservedCleanupArtifact]? = nil
    ) {
        self.securityScopedBookmark = securityScopedBookmark
        self.directorySecurityScopedBookmark = directorySecurityScopedBookmark
        self.installedSHA256 = installedSHA256
        self.installedFileIdentity = installedFileIdentity
        self.appVersion = appVersion
        self.displayPath = displayPath
        self.preservedCleanupArtifacts = preservedCleanupArtifacts
    }
}

/// A deliberately small, non-sensitive journal for the narrow window between
/// an atomic rename and the corresponding defaults update. It never contains
/// the command bytes or source command text.
struct BlocksCLIOperationJournal: Codable, Equatable {
    enum Kind: String, Codable { case install, uninstall }

    let kind: Kind
    let destinationBookmark: Data
    let destinationDirectoryBookmark: Data?
    let recoveryBookmark: Data?
    let recoveryPath: String?
    let displayPath: String
    let expectedOldIdentity: Data?
    let expectedOldDigest: String?
    let expectedNewIdentity: Data?
    let expectedNewDigest: String?
    let targetRecord: Data?
    let previousRecord: Data?

    init(
        kind: Kind,
        destinationBookmark: Data,
        destinationDirectoryBookmark: Data? = nil,
        recoveryBookmark: Data?,
        recoveryPath: String?,
        displayPath: String,
        expectedOldIdentity: Data?,
        expectedOldDigest: String?,
        expectedNewIdentity: Data?,
        expectedNewDigest: String?,
        targetRecord: Data?,
        previousRecord: Data? = nil
    ) {
        self.kind = kind
        self.destinationBookmark = destinationBookmark
        self.destinationDirectoryBookmark = destinationDirectoryBookmark
        self.recoveryBookmark = recoveryBookmark
        self.recoveryPath = recoveryPath
        self.displayPath = displayPath
        self.expectedOldIdentity = expectedOldIdentity
        self.expectedOldDigest = expectedOldDigest
        self.expectedNewIdentity = expectedNewIdentity
        self.expectedNewDigest = expectedNewDigest
        self.targetRecord = targetRecord
        self.previousRecord = previousRecord
    }
}

enum BlocksCLIFileDigest {
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum BlocksCLIFileIdentity {
    static func resourceIdentifier(of url: URL) -> Data? {
        var metadata = stat()
        let result = url.path.withCString { path in
            lstat(path, &metadata)
        }
        guard result == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        var device = UInt64(metadata.st_dev).littleEndian
        var inode = UInt64(metadata.st_ino).littleEndian
        var generation = UInt64(metadata.st_gen).littleEndian
        var identity = Data()
        withUnsafeBytes(of: &device) { identity.append(contentsOf: $0) }
        withUnsafeBytes(of: &inode) { identity.append(contentsOf: $0) }
        withUnsafeBytes(of: &generation) { identity.append(contentsOf: $0) }
        return identity
    }
}

struct BlocksCLIInstallationBookmarkAccess {
    let make: (URL) throws -> Data
    let resolve: (Data) -> URL?
    let start: (URL) -> Bool
    let stop: (URL) -> Void

    static let live = Self(
        make: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
        resolve: { bookmark in
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        },
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

extension BlocksCLIInstallationBookmarkAccess: @unchecked Sendable {}

private struct BlocksCLIResolvedDestination {
    let scopeURL: URL
    let destinationURL: URL
    let usesDirectoryBookmark: Bool
}

private func resolveCLIRecordDestination(
    _ record: BlocksCLIInstallationRecord,
    using bookmarkAccess: BlocksCLIInstallationBookmarkAccess
) -> BlocksCLIResolvedDestination? {
    if let directoryBookmark = record.directorySecurityScopedBookmark,
       let directoryURL = bookmarkAccess.resolve(directoryBookmark) {
        return BlocksCLIResolvedDestination(
            scopeURL: directoryURL,
            destinationURL: directoryURL.appendingPathComponent(
                URL(fileURLWithPath: record.displayPath).lastPathComponent
            ),
            usesDirectoryBookmark: true
        )
    }
    guard let destinationURL = bookmarkAccess.resolve(
        record.securityScopedBookmark
    ) else {
        return nil
    }
    return BlocksCLIResolvedDestination(
        scopeURL: destinationURL,
        destinationURL: destinationURL,
        usesDirectoryBookmark: false
    )
}

private func resolveCLIJournalDestination(
    _ journal: BlocksCLIOperationJournal,
    using bookmarkAccess: BlocksCLIInstallationBookmarkAccess
) -> BlocksCLIResolvedDestination? {
    if let directoryBookmark = journal.destinationDirectoryBookmark,
       let directoryURL = bookmarkAccess.resolve(directoryBookmark) {
        return BlocksCLIResolvedDestination(
            scopeURL: directoryURL,
            destinationURL: directoryURL.appendingPathComponent(
                URL(fileURLWithPath: journal.displayPath).lastPathComponent
            ),
            usesDirectoryBookmark: true
        )
    }
    guard let scopeURL = bookmarkAccess.resolve(journal.destinationBookmark) else {
        return nil
    }
    return BlocksCLIResolvedDestination(
        scopeURL: scopeURL,
        destinationURL: URL(fileURLWithPath: journal.displayPath),
        usesDirectoryBookmark: false
    )
}

private actor BlocksCLIInstallationWorker {
    private struct DestinationSnapshot: Equatable {
        let identity: Data
        let digest: String
    }

    enum RefreshResult {
        case state(BlocksCLIInstallationState)
        case migratedRecord(Data)
    }

    enum JournalRecoveryResult {
        case installed(Data)
        case previousInstallationRestored(Data?)
        case firstInstallationNotCommitted
        case uninstalled
        case recovery(URL?)
    }

    enum InstallResult {
        case installed(
            record: Data,
            recordValue: BlocksCLIInstallationRecord,
            directoryBookmark: Data,
            displacedOriginalURL: URL?,
            originalIdentity: Data?,
            originalDigest: String?,
            installedIdentity: Data,
            installedDigest: String
        )
        case destinationConflict
        case recovery(URL)
        case failedRestored
        case failed
    }

    enum RestoreResult {
        case restored
        case recovery(URL)
        case failed
    }

    enum DisplacedCleanupResult {
        case removed
        case recovery(URL)
        /// The new installation is already verified and authoritative, but the
        /// old inode is intentionally preserved because pathname deletion
        /// cannot be made identity-conditional. This is a non-blocking cleanup
        /// artifact, not a failed installation transaction.
        case preserved(URL)
    }

    enum UninstallResult {
        case removed
        case recovery(URL)
        case cancelled
        case refresh
        case failed
    }

    private let digest: (URL) -> String?
    private let fileIdentity: (URL) -> Data?
    private let bookmarkAccess: BlocksCLIInstallationBookmarkAccess
    private let recordEncoder: (BlocksCLIInstallationRecord) throws -> Data
    private let appVersion: String
    private let beforeInstallCommit: @Sendable () -> Void
    private let beforeRestoreCommit: @Sendable () -> Void
    private let afterRestoreSwap: @Sendable (URL) -> Void
    private let beforeUninstallCommit: @Sendable () async -> Void
    private let beforeUninstallRename: @Sendable () -> Void
    private let persistJournal: @Sendable (BlocksCLIOperationJournal) -> Bool
    private let installationRecordStore: BlocksCLIInstallationRecordStore
    private let operationJournalStore: BlocksCLIOperationJournalStore
    private let operationLeaseProvider: BlocksCLIOperationLeaseProvider
    private let fileManager = FileManager.default

    init(
        digest: @escaping (URL) -> String?,
        fileIdentity: @escaping (URL) -> Data?,
        bookmarkAccess: BlocksCLIInstallationBookmarkAccess,
        recordEncoder: @escaping (BlocksCLIInstallationRecord) throws -> Data,
        appVersion: String,
        beforeInstallCommit: @escaping @Sendable () -> Void,
        beforeRestoreCommit: @escaping @Sendable () -> Void,
        afterRestoreSwap: @escaping @Sendable (URL) -> Void,
        beforeUninstallCommit: @escaping @Sendable () async -> Void,
        beforeUninstallRename: @escaping @Sendable () -> Void,
        persistJournal: @escaping @Sendable (BlocksCLIOperationJournal) -> Bool,
        installationRecordStore: BlocksCLIInstallationRecordStore,
        operationJournalStore: BlocksCLIOperationJournalStore,
        operationLeaseProvider: BlocksCLIOperationLeaseProvider
    ) {
        self.digest = digest
        self.fileIdentity = fileIdentity
        self.bookmarkAccess = bookmarkAccess
        self.recordEncoder = recordEncoder
        self.appVersion = appVersion
        self.beforeInstallCommit = beforeInstallCommit
        self.beforeRestoreCommit = beforeRestoreCommit
        self.afterRestoreSwap = afterRestoreSwap
        self.beforeUninstallCommit = beforeUninstallCommit
        self.beforeUninstallRename = beforeUninstallRename
        self.persistJournal = persistJournal
        self.installationRecordStore = installationRecordStore
        self.operationJournalStore = operationJournalStore
        self.operationLeaseProvider = operationLeaseProvider
    }

    // Durable store calls may fsync and must never run on the settings actor.
    func loadInstallationRecord() -> Data? { installationRecordStore.load() }
    func saveInstallationRecord(_ data: Data) -> Bool { installationRecordStore.save(data) }
    func clearInstallationRecord() -> Bool { installationRecordStore.clear() }
    func loadOperationJournal() -> BlocksCLIOperationJournalLoadResult {
        operationJournalStore.load()
    }
    func clearOperationJournal() -> Bool { operationJournalStore.clear() }

    /// Keeps both advisory-lock acquisition and release on the worker actor
    /// while allowing the MainActor controller to coordinate the transaction.
    func withOperationLease(
        _ operation: @Sendable () async -> Void
    ) async -> Bool {
        guard !Task.isCancelled,
              let lease = operationLeaseProvider.acquire() else {
            return false
        }
        defer {
            lease.release()
            operationLeaseProvider.didRelease()
        }
        await operation()
        return true
    }

    func refresh(
        sourceURL: URL?,
        recordData: Data?,
        legacyBookmark: Data?
    ) -> RefreshResult {
        guard let sourceURL, let sourceDigest = digest(sourceURL) else {
            return .state(.unavailable)
        }
        guard !Task.isCancelled else { return .state(.notInstalled) }

        if let recordData,
           let record = try? JSONDecoder().decode(BlocksCLIInstallationRecord.self, from: recordData) {
            return .state(installationState(
                sourceDigest: sourceDigest,
                record: record
            ))
        }
        guard let legacyBookmark,
              let legacyURL = bookmarkAccess.resolve(legacyBookmark) else {
            return .state(.notInstalled)
        }
        guard bookmarkAccess.start(legacyURL) else { return .state(.inaccessible) }
        defer { bookmarkAccess.stop(legacyURL) }
        guard fileManager.fileExists(atPath: legacyURL.path) else { return .state(.missing) }
        // Legacy bookmarks record a location but no historical file identity.
        // Matching bytes alone cannot prove this is still Blocks-managed.
        return .state(.changed)
    }

    func recover(_ journal: BlocksCLIOperationJournal) -> JournalRecoveryResult {
        let resolvedDestination = resolveCLIJournalDestination(
            journal,
            using: bookmarkAccess
        )
        let destinationURL = resolvedDestination?.destinationURL
        let recoveryURL = resolveJournalRecoveryURL(
            journal,
            resolvedDestination: resolvedDestination
        )
        switch journal.kind {
        case .install:
            guard let resolvedDestination, let destinationURL else {
                return .recovery(recoveryURL)
            }
            guard bookmarkAccess.start(resolvedDestination.scopeURL) else {
                return .recovery(recoveryURL ?? destinationURL)
            }
            defer { bookmarkAccess.stop(resolvedDestination.scopeURL) }
            guard let newIdentity = journal.expectedNewIdentity,
                  let newDigest = journal.expectedNewDigest else {
                return .recovery(recoveryURL ?? destinationURL)
            }
            let destinationIsNew = fileIdentity(destinationURL) == newIdentity
                && self.digest(destinationURL) == newDigest
            if destinationIsNew {
                guard let record = journal.targetRecord else {
                    return .recovery(recoveryURL ?? destinationURL)
                }
                if let recoveryURL {
                    switch pathPresence(at: recoveryURL) {
                    case .absent:
                        break
                    case .unknown:
                        return .recovery(recoveryURL)
                    case .present:
                        guard let oldIdentity = journal.expectedOldIdentity,
                              let oldDigest = journal.expectedOldDigest,
                              fileIdentity(recoveryURL) == oldIdentity,
                              self.digest(recoveryURL) == oldDigest else {
                            return .recovery(recoveryURL)
                        }
                        // Path verification cannot make a later unlink atomic.
                        // Preserve the object for explicit user recovery.
                        return .recovery(recoveryURL)
                    }
                }
                return .installed(record)
            }

            if journal.expectedOldIdentity == nil,
               journal.expectedOldDigest == nil {
                switch pathPresence(at: destinationURL) {
                case .present:
                    return .recovery(recoveryURL ?? destinationURL)
                case .unknown:
                    return .recovery(destinationURL)
                case .absent:
                    break
                }
                if let recoveryURL {
                    switch pathPresence(at: recoveryURL) {
                    case .absent:
                        break
                    case .unknown:
                        return .recovery(recoveryURL)
                    case .present:
                        guard fileIdentity(recoveryURL) == newIdentity,
                              self.digest(recoveryURL) == newDigest else {
                            return .recovery(recoveryURL)
                        }
                        return .recovery(recoveryURL)
                    }
                }
                return .firstInstallationNotCommitted
            }

            let destinationIsOld = journal.expectedOldIdentity.map {
                fileIdentity(destinationURL) == $0
            } == true && journal.expectedOldDigest.map {
                self.digest(destinationURL) == $0
            } == true
            guard destinationIsOld else {
                return .recovery(recoveryURL ?? destinationURL)
            }
            if let recoveryURL {
                switch pathPresence(at: recoveryURL) {
                case .absent:
                    break
                case .unknown:
                    return .recovery(recoveryURL)
                case .present:
                    guard fileIdentity(recoveryURL) == newIdentity,
                          self.digest(recoveryURL) == newDigest else {
                        return .recovery(recoveryURL)
                    }
                    return .recovery(recoveryURL)
                }
            }
            return .previousInstallationRestored(journal.previousRecord)
        case .uninstall:
            guard let resolvedDestination, let destinationURL else {
                return .recovery(recoveryURL)
            }
            guard bookmarkAccess.start(resolvedDestination.scopeURL) else {
                return .recovery(recoveryURL ?? destinationURL)
            }
            defer { bookmarkAccess.stop(resolvedDestination.scopeURL) }
            guard let recoveryURL,
                  let identity = journal.expectedOldIdentity,
                  let digest = journal.expectedOldDigest else {
                return .recovery(recoveryURL ?? destinationURL)
            }

            switch pathPresence(at: recoveryURL) {
            case .present:
                guard fileIdentity(recoveryURL) == identity,
                      self.digest(recoveryURL) == digest else {
                    return .recovery(recoveryURL)
                }
                return .recovery(recoveryURL)
            case .unknown:
                return .recovery(recoveryURL)
            case .absent:
                break
            }

            switch pathPresence(at: destinationURL) {
            case .absent:
                return .uninstalled
            case .unknown:
                return .recovery(destinationURL)
            case .present:
                guard fileIdentity(destinationURL) == identity,
                      self.digest(destinationURL) == digest,
                      let record = journal.targetRecord else {
                    return .recovery(destinationURL)
                }
                // The journal was durable, but the atomic rename never
                // committed. Restore the managed record and resume normal
                // refresh instead of stranding an otherwise valid install.
                return .installed(record)
            }
        }
    }

    func install(
        sourceURL: URL,
        destinationURL: URL,
        recordData: Data?
    ) -> InstallResult {
        guard let sourceDigest = digest(sourceURL), !Task.isCancelled else { return .failed }
        var recordedLocation: BlocksCLIResolvedDestination?
        var preservedCleanupArtifacts: [BlocksCLIPreservedCleanupArtifact] = []
        if let recordData {
            guard let record = try? JSONDecoder().decode(
                BlocksCLIInstallationRecord.self,
                from: recordData
            ), let resolvedRecord = resolveCLIRecordDestination(
                record,
                using: bookmarkAccess
            ) else {
                return .destinationConflict
            }
            recordedLocation = resolvedRecord
            preservedCleanupArtifacts = record.preservedCleanupArtifacts ?? []
            let recordedURL = resolvedRecord.destinationURL
            if recordedURL.standardizedFileURL != destinationURL.standardizedFileURL {
                guard bookmarkAccess.start(resolvedRecord.scopeURL) else {
                    return .destinationConflict
                }
                let recordedPresence = pathPresence(at: recordedURL)
                bookmarkAccess.stop(resolvedRecord.scopeURL)
                guard case .absent = recordedPresence else {
                    return .destinationConflict
                }
            }
        }
        let accessURL: URL
        if let recordedLocation,
           recordedLocation.destinationURL.standardizedFileURL
            == destinationURL.standardizedFileURL {
            accessURL = recordedLocation.scopeURL
        } else {
            accessURL = destinationURL
        }
        let accessed = bookmarkAccess.start(accessURL)
        defer {
            if accessed {
                bookmarkAccess.stop(accessURL)
            }
        }

        let destinationInitiallyExists = fileManager.fileExists(
            atPath: destinationURL.path
        )
        let expectedDestinationSnapshot: DestinationSnapshot?
        if destinationInitiallyExists {
            guard let snapshot = managedDestinationSnapshot(
                at: destinationURL,
                recordData: recordData
            ) else {
                return .destinationConflict
            }
            expectedDestinationSnapshot = snapshot
        } else {
            expectedDestinationSnapshot = nil
        }
        do {
            let preCommitDestinationBookmark = try bookmarkAccess.make(
                destinationURL
            )
            let directoryBookmark = try bookmarkAccess.make(
                destinationURL.deletingLastPathComponent()
            )
            guard !Task.isCancelled else { return .failed }
            let displacedOriginalURL = try BlocksCLIInstaller.install(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                allowReplacingExistingDestination:
                    expectedDestinationSnapshot != nil,
                retainDisplacedDestination:
                    expectedDestinationSnapshot != nil,
                validateDestinationBeforeCommit: {
                    beforeInstallCommit()
                    guard !Task.isCancelled else { return false }
                    if let expectedDestinationSnapshot {
                        return destinationSnapshot(at: destinationURL)
                            == expectedDestinationSnapshot
                    }
                    return !fileManager.fileExists(
                        atPath: destinationURL.path
                    )
                },
                persistOperationJournal: { temporaryURL in
                    guard let temporaryIdentity = fileIdentity(temporaryURL),
                          let temporaryDigest = digest(temporaryURL),
                          temporaryDigest == sourceDigest,
                          let encodedRecord = try? recordEncoder(BlocksCLIInstallationRecord(
                              securityScopedBookmark:
                                preCommitDestinationBookmark,
                              directorySecurityScopedBookmark:
                                directoryBookmark,
                              installedSHA256: sourceDigest,
                              installedFileIdentity: temporaryIdentity,
                              appVersion: appVersion,
                              displayPath: destinationURL.path
                          )),
                          let recoveryBookmark = try? bookmarkAccess.make(temporaryURL) else {
                        return false
                    }
                    return persistJournal(BlocksCLIOperationJournal(
                        kind: .install,
                        destinationBookmark: preCommitDestinationBookmark,
                        destinationDirectoryBookmark: directoryBookmark,
                        recoveryBookmark: recoveryBookmark,
                        recoveryPath: temporaryURL.path,
                        displayPath: destinationURL.path,
                        expectedOldIdentity: expectedDestinationSnapshot?.identity,
                        expectedOldDigest: expectedDestinationSnapshot?.digest,
                        expectedNewIdentity: temporaryIdentity,
                        expectedNewDigest: sourceDigest,
                        targetRecord: encodedRecord,
                        previousRecord: recordData
                    ))
                },
                validateReplacedDestination: { replacedURL in
                    guard let expectedDestinationSnapshot else {
                        return false
                    }
                    return destinationSnapshot(at: replacedURL)
                        == expectedDestinationSnapshot
                },
                verifyTemporaryFile: { _, temporaryURL, fileManager in
                    fileManager.isExecutableFile(atPath: temporaryURL.path)
                        && digest(temporaryURL) == sourceDigest
                }
            )
            guard let installedIdentity = fileIdentity(destinationURL),
                  digest(destinationURL) == sourceDigest else {
                return .failed
            }
            let installedBookmark =
                (try? bookmarkAccess.make(destinationURL))
                ?? preCommitDestinationBookmark
            let record = BlocksCLIInstallationRecord(
                securityScopedBookmark: installedBookmark,
                directorySecurityScopedBookmark: directoryBookmark,
                installedSHA256: sourceDigest,
                installedFileIdentity: installedIdentity,
                appVersion: appVersion,
                displayPath: destinationURL.path,
                preservedCleanupArtifacts:
                    preservedCleanupArtifacts.isEmpty
                        ? nil : preservedCleanupArtifacts
            )
            let encodedRecord: Data
            do {
                encodedRecord = try recordEncoder(record)
            } catch {
                let restoreResult = restoreDestination(
                    destinationURL,
                    directoryBookmark: directoryBookmark,
                    displacedOriginalURL: displacedOriginalURL,
                    expectedOriginalIdentity:
                        expectedDestinationSnapshot?.identity,
                    expectedOriginalDigest:
                        expectedDestinationSnapshot?.digest,
                    expectedInstalledIdentity: installedIdentity,
                    expectedInstalledDigest: sourceDigest
                )
                switch restoreResult {
                case let .recovery(url):
                    return .recovery(url)
                case .restored:
                    return .failedRestored
                case .failed:
                    return .failed
                }
            }
            return .installed(
                record: encodedRecord,
                recordValue: record,
                directoryBookmark: directoryBookmark,
                displacedOriginalURL: displacedOriginalURL,
                originalIdentity: expectedDestinationSnapshot?.identity,
                originalDigest: expectedDestinationSnapshot?.digest,
                installedIdentity: installedIdentity,
                installedDigest: sourceDigest
            )
        } catch let BlocksCLIInstaller.InstallationError.destinationRecoveryRequired(
            recoveryURL
        ) {
            return .recovery(recoveryURL)
        } catch BlocksCLIInstaller.InstallationError.destinationExists,
                BlocksCLIInstaller.InstallationError.destinationChanged {
            return Task.isCancelled ? .failed : .destinationConflict
        } catch {
            return .failed
        }
    }

    func restoreDestination(
        _ destinationURL: URL,
        directoryBookmark: Data?,
        displacedOriginalURL: URL?,
        expectedOriginalIdentity: Data?,
        expectedOriginalDigest: String?,
        expectedInstalledIdentity: Data,
        expectedInstalledDigest: String
    ) -> RestoreResult {
        let scopeURL = directoryBookmark.flatMap(bookmarkAccess.resolve)
            ?? destinationURL
        let accessed = bookmarkAccess.start(scopeURL)
        defer {
            if accessed {
                bookmarkAccess.stop(scopeURL)
            }
        }
        if let displacedOriginalURL {
            guard let expectedOriginalIdentity,
                  let expectedOriginalDigest,
                  fileIdentity(displacedOriginalURL) == expectedOriginalIdentity,
                  digest(displacedOriginalURL) == expectedOriginalDigest else {
                return .recovery(displacedOriginalURL)
            }
            beforeRestoreCommit()
            guard atomicRename(
                from: displacedOriginalURL,
                to: destinationURL,
                flags: UInt32(RENAME_SWAP)
            ) == 0 else {
                return .recovery(displacedOriginalURL)
            }
            afterRestoreSwap(destinationURL)
            guard fileIdentity(destinationURL) == expectedOriginalIdentity,
                  digest(destinationURL) == expectedOriginalDigest,
                  fileIdentity(displacedOriginalURL) == expectedInstalledIdentity,
                  digest(displacedOriginalURL) == expectedInstalledDigest else {
                // Do not swap again: destination may now be a later file.
                return .recovery(displacedOriginalURL)
            }
            // The displaced path can be replaced after validation, so leave
            // the installed object for explicit recovery instead of unlinking.
            return .recovery(displacedOriginalURL)
        }

        let recoveryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".blocks-restore-\(UUID().uuidString)"
            )
        beforeRestoreCommit()
        guard atomicRename(
            from: destinationURL,
            to: recoveryURL,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else {
            return .failed
        }
        guard fileIdentity(recoveryURL) == expectedInstalledIdentity,
              digest(recoveryURL) == expectedInstalledDigest else {
            return .recovery(recoveryURL)
        }
        return .recovery(recoveryURL)
    }

    func discardDisplacedDestination(
        _ url: URL?,
        directoryBookmark: Data?,
        expectedIdentity: Data?,
        expectedDigest: String?
    ) -> DisplacedCleanupResult {
        guard let url else { return .removed }
        let scopeURL = directoryBookmark.flatMap(bookmarkAccess.resolve) ?? url
        let accessed = bookmarkAccess.start(scopeURL)
        defer {
            if accessed {
                bookmarkAccess.stop(scopeURL)
            }
        }
        guard let expectedIdentity,
              let expectedDigest,
              fileIdentity(url) == expectedIdentity,
              digest(url) == expectedDigest else {
            return .recovery(url)
        }
        // Identity and digest checks do not close the path replacement race.
        // The destination already contains the verified new command, so retain
        // this old object as a revealable cleanup artifact without rolling the
        // successful install back into recoveryRequired.
        return .preserved(url)
    }

    func uninstall(recordData: Data?) async -> UninstallResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let recordData,
              let record = try? JSONDecoder().decode(BlocksCLIInstallationRecord.self, from: recordData),
              let resolvedRecord = resolveCLIRecordDestination(
                record,
                using: bookmarkAccess
              ) else {
            return .failed
        }
        let destinationURL = resolvedRecord.destinationURL
        guard isRecordedDestination(resolvedRecord, for: record) else { return .refresh }
        guard bookmarkAccess.start(resolvedRecord.scopeURL) else { return .failed }
        defer { bookmarkAccess.stop(resolvedRecord.scopeURL) }
        guard managedFileIdentity(at: destinationURL, record: record) != nil else {
            return .refresh
        }
        await beforeUninstallCommit()
        guard !Task.isCancelled else { return .cancelled }
        guard let revalidatedRecord = resolveCLIRecordDestination(
            record,
            using: bookmarkAccess
        ) else {
            return .refresh
        }
        let revalidatedDestinationURL = revalidatedRecord.destinationURL
        guard revalidatedDestinationURL.standardizedFileURL.path
                == destinationURL.standardizedFileURL.path,
              revalidatedRecord.scopeURL.standardizedFileURL.path
                == resolvedRecord.scopeURL.standardizedFileURL.path,
              isRecordedDestination(revalidatedRecord, for: record),
              managedFileIdentity(at: revalidatedDestinationURL, record: record) != nil else {
            return .refresh
        }
        beforeUninstallRename()
        let quarantineURL = revalidatedDestinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".blocks-uninstall-\(UUID().uuidString)"
            )
        guard let expectedIdentity = record.installedFileIdentity,
              persistJournal(BlocksCLIOperationJournal(
                  kind: .uninstall,
                  destinationBookmark: record.securityScopedBookmark,
                  destinationDirectoryBookmark:
                    record.directorySecurityScopedBookmark,
                  recoveryBookmark: nil,
                  recoveryPath: quarantineURL.path,
                  displayPath: revalidatedDestinationURL.path,
                  expectedOldIdentity: expectedIdentity,
                  expectedOldDigest: record.installedSHA256,
                  expectedNewIdentity: nil,
                  expectedNewDigest: nil,
                  targetRecord: recordData
              )) else {
            return .failed
        }
        guard atomicRename(
            from: revalidatedDestinationURL,
            to: quarantineURL,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else {
            return .refresh
        }
        guard managedFileIdentity(at: quarantineURL, record: record) != nil else {
            // The final check and rename are not linearizable. Restore only
            // while the original path is still empty; otherwise retain the
            // moved object as recovery and keep the managed record.
            guard atomicRename(
                from: quarantineURL,
                to: revalidatedDestinationURL,
                flags: UInt32(RENAME_EXCL)
            ) == 0 else {
                return .recovery(quarantineURL)
            }
            return .refresh
        }
        // A pathname-based unlink after this validation has a replacement
        // race. Keep quarantine as recovery rather than deleting unknown data.
        return .recovery(quarantineURL)
    }

    private func installationState(
        sourceDigest: String,
        record: BlocksCLIInstallationRecord
    ) -> BlocksCLIInstallationState {
        guard let resolvedRecord = resolveCLIRecordDestination(
            record,
            using: bookmarkAccess
        ) else {
            return .inaccessible
        }
        let destinationURL = resolvedRecord.destinationURL
        guard bookmarkAccess.start(resolvedRecord.scopeURL) else {
            return .inaccessible
        }
        defer { bookmarkAccess.stop(resolvedRecord.scopeURL) }
        guard fileManager.fileExists(atPath: destinationURL.path) else { return .missing }
        guard let expectedIdentity = record.installedFileIdentity,
              fileIdentity(destinationURL) == expectedIdentity else {
            return .changed
        }
        guard let installedDigest = digest(destinationURL) else { return .inaccessible }
        if installedDigest != record.installedSHA256 { return .changed }
        return sourceDigest == record.installedSHA256 ? .installedCurrent : .updateAvailable
    }

    private func managedDestinationSnapshot(
        at url: URL,
        recordData: Data?
    ) -> DestinationSnapshot? {
        guard let recordData,
              let record = try? JSONDecoder().decode(BlocksCLIInstallationRecord.self, from: recordData),
              let resolvedRecord = resolveCLIRecordDestination(
                record,
                using: bookmarkAccess
              ) else {
            return nil
        }
        let recordedURL = resolvedRecord.destinationURL
        guard recordedURL.standardizedFileURL == url.standardizedFileURL,
              bookmarkAccess.start(resolvedRecord.scopeURL) else {
            return nil
        }
        defer { bookmarkAccess.stop(resolvedRecord.scopeURL) }
        guard let expectedIdentity = record.installedFileIdentity,
              let snapshot = destinationSnapshot(at: recordedURL),
              snapshot.identity == expectedIdentity,
              snapshot.digest == record.installedSHA256 else {
            return nil
        }
        return snapshot
    }

    private func destinationSnapshot(at url: URL) -> DestinationSnapshot? {
        guard fileManager.fileExists(atPath: url.path),
              let identity = fileIdentity(url),
              let digest = digest(url) else {
            return nil
        }
        return DestinationSnapshot(identity: identity, digest: digest)
    }

    private func isRecordedDestination(
        _ resolvedRecord: BlocksCLIResolvedDestination,
        for record: BlocksCLIInstallationRecord
    ) -> Bool {
        if resolvedRecord.usesDirectoryBookmark {
            return true
        }
        return resolvedRecord.destinationURL.standardizedFileURL.path
            == URL(fileURLWithPath: record.displayPath).standardizedFileURL.path
    }

    private func managedFileIdentity(
        at destinationURL: URL,
        record: BlocksCLIInstallationRecord
    ) -> Data? {
        guard fileManager.fileExists(atPath: destinationURL.path),
              let expectedIdentity = record.installedFileIdentity,
              fileIdentity(destinationURL) == expectedIdentity,
              digest(destinationURL) == record.installedSHA256 else {
            return nil
        }
        return expectedIdentity
    }

    private func atomicRename(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) -> Int32 {
        sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
    }

    private enum PathPresence {
        case present
        case absent
        case unknown
    }

    private func pathPresence(at url: URL) -> PathPresence {
        var metadata = stat()
        let result = url.path.withCString { path in
            lstat(path, &metadata)
        }
        if result == 0 { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .unknown
    }

    private func resolveJournalRecoveryURL(
        _ journal: BlocksCLIOperationJournal,
        resolvedDestination: BlocksCLIResolvedDestination?
    ) -> URL? {
        guard let recoveryPath = journal.recoveryPath else {
            return journal.recoveryBookmark.flatMap(bookmarkAccess.resolve)
        }
        let persistedURL = URL(fileURLWithPath: recoveryPath)
        guard let resolvedDestination,
              resolvedDestination.usesDirectoryBookmark else {
            return persistedURL
        }

        let relocatedURL = resolvedDestination.destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(persistedURL.lastPathComponent)
        // A resolved directory bookmark follows a user-moved target directory.
        // Only fall back to the persisted absolute path when that relocated
        // sibling is confirmed absent; unknown access must remain fail-closed.
        switch pathPresence(at: relocatedURL) {
        case .absent:
            return persistedURL
        case .present, .unknown:
            return relocatedURL
        }
    }
}

@MainActor
final class BlocksCLIInstallationController: ObservableObject {
    static let bookmarkKey =
        "agentCLI.installedExecutableBookmark.v1"
    static let recordKey = "agentCLI.installationRecord.v2"
    static let recoveryBookmarkKey =
        "agentCLI.installationRecoveryBookmark.v1"
    static let operationJournalKey = "agentCLI.operationJournal.v1"

    @Published private(set) var state:
        BlocksCLIInstallationState = .notInstalled
    @Published private(set) var recoveryURL: URL?
    @Published private(set) var legacyDisplayURL: URL?
    @Published private(set) var isRecovering = false

    private let defaults: UserDefaults
    private let sourceURLProvider: () -> URL?
    private let installationRecordStore: BlocksCLIInstallationRecordStore
    private let operationJournalStore: BlocksCLIOperationJournalStore
    private let bookmarkAccess: BlocksCLIInstallationBookmarkAccess
    private let worker: BlocksCLIInstallationWorker
    private let beforeJournalRecovery: @Sendable () async -> Void
    private var operationGeneration = 0
    private var operationTask: Task<Void, Never>?
    private var operationFallbackState: BlocksCLIInstallationState = .notInstalled
    // This is the only record source used by synchronous UI presentation.
    // Disk reads and writes are owned by the worker actor.
    private var cachedInstallationRecordData: Data?

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        digest: @escaping (URL) -> String? = BlocksCLIFileDigest.sha256,
        bookmarkAccess: BlocksCLIInstallationBookmarkAccess = .live,
        sourceURLProvider: (() -> URL?)? = nil,
        recordEncoder: @escaping (BlocksCLIInstallationRecord) throws -> Data = { try JSONEncoder().encode($0) },
        installationRecordStore: BlocksCLIInstallationRecordStore? = nil,
        operationJournalStore: BlocksCLIOperationJournalStore? = nil,
        operationLeaseProvider: BlocksCLIOperationLeaseProvider = .live,
        beforeJournalRecovery: @escaping @Sendable () async -> Void = {},
        beforeInstallCommit: @escaping @Sendable () -> Void = {},
        beforeRestoreCommit: @escaping @Sendable () -> Void = {},
        afterRestoreSwap: @escaping @Sendable (URL) -> Void = { _ in },
        beforeUninstallCommit: @escaping @Sendable () async -> Void = {},
        beforeUninstallRename: @escaping @Sendable () -> Void = {}
    ) {
        self.defaults = defaults
        self.bookmarkAccess = bookmarkAccess
        self.installationRecordStore = installationRecordStore
            ?? BlocksCLIInstallationRecordStore.live(
                defaults: defaults,
                key: Self.recordKey
            )
        let journalStore = operationJournalStore
            ?? BlocksCLIOperationJournalStore.live(
                defaults: defaults,
                key: Self.operationJournalKey
            )
        self.operationJournalStore = journalStore
        let journalPersistence: @Sendable (Data) -> Bool = {
            journalStore.save($0)
        }
        self.beforeJournalRecovery = beforeJournalRecovery
        self.sourceURLProvider = sourceURLProvider ?? {
            guard let resourcesDirectory = bundle.resourceURL else { return nil }
            return resourcesDirectory.appendingPathComponent("CLI", isDirectory: true)
                .appendingPathComponent(BlocksRuntimeIdentity.isLocalDevelopment ? "blocks-dev" : "blocks")
        }
        self.worker = BlocksCLIInstallationWorker(
            digest: digest,
            fileIdentity: BlocksCLIFileIdentity.resourceIdentifier,
            bookmarkAccess: bookmarkAccess,
            recordEncoder: recordEncoder,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            beforeInstallCommit: beforeInstallCommit,
            beforeRestoreCommit: beforeRestoreCommit,
            afterRestoreSwap: afterRestoreSwap,
            beforeUninstallCommit: beforeUninstallCommit,
            beforeUninstallRename: beforeUninstallRename,
            persistJournal: { journal in
                guard let data = try? JSONEncoder().encode(journal) else { return false }
                return journalPersistence(data)
            },
            installationRecordStore: self.installationRecordStore,
            operationJournalStore: journalStore,
            operationLeaseProvider: operationLeaseProvider
        )
    }

    var canInstall: Bool {
        !isBusy && state != .recoveryRequired
    }

    var isInstalled: Bool {
        state == .installedCurrent || state == .updateAvailable
    }

    var isInstalling: Bool { state == .installing }

    var isUninstalling: Bool { state == .uninstalling }

    var isBusy: Bool { isInstalling || isUninstalling || isRecovering }

    var canUninstall: Bool {
        !isBusy && (state == .installedCurrent || state == .updateAvailable)
    }

    var installButtonTitle: String {
        switch state {
        case .installedCurrent, .updateAvailable:
            L10n.string("settings.agentCLI.install.update")
        case .installing:
            L10n.string("settings.agentCLI.install.installing")
        case .uninstalling:
            L10n.string("settings.agentCLI.install.button")
        case .unavailable, .notInstalled, .changed, .missing, .inaccessible,
                .destinationConflict, .recoveryRequired, .failed, .installedOutdated:
            L10n.string("settings.agentCLI.install.button")
        }
    }

    var statusDetail: String {
        switch state {
        case .unavailable:
            L10n.string("settings.agentCLI.install.unavailable")
        case .notInstalled:
            L10n.string("settings.agentCLI.install.detail")
        case .installing:
            L10n.string("settings.agentCLI.install.installing")
        case .uninstalling:
            L10n.string("settings.agentCLI.uninstall.removing")
        case .installedCurrent:
            statusWithPath("settings.agentCLI.install.current")
        case .updateAvailable:
            statusWithPath("settings.agentCLI.install.updateAvailable")
        case .changed:
            statusWithPath("settings.agentCLI.install.changed")
        case .missing:
            statusWithPath("settings.agentCLI.install.missing")
        case .inaccessible:
            L10n.string("settings.agentCLI.install.inaccessible")
        case .destinationConflict:
            L10n.string("settings.agentCLI.install.destinationConflict")
        case .recoveryRequired:
            L10n.string("settings.agentCLI.recovery.required")
        case .installedOutdated:
            L10n.string("settings.agentCLI.install.outdated")
        case .failed:
            L10n.string("settings.agentCLI.install.failed")
        }
    }

    var statusPresentation: SettingsRowStatus? {
        switch state {
        case .notInstalled:
            nil
        case .installing, .uninstalling:
            SettingsRowStatus(
                kind: .information,
                message: statusDetail
            )
        case .installedCurrent:
            SettingsRowStatus(
                kind: .success,
                message: statusDetail
            )
        case .updateAvailable, .changed, .missing, .destinationConflict, .installedOutdated:
            SettingsRowStatus(
                kind: .warning,
                message: statusDetail
            )
        case .unavailable, .failed, .inaccessible, .recoveryRequired:
            SettingsRowStatus(
                kind: .error,
                message: statusDetail
            )
        }
    }

    func refresh() {
        guard !isBusy else { return }
        recoveryURL = nil
        legacyDisplayURL = nil
        let generation = beginOperation()
        let sourceURL = sourceURLProvider()
        let legacyBookmark = defaults.data(forKey: Self.bookmarkKey)
        operationTask = Task { [weak self, worker, beforeJournalRecovery] in
            guard let self else { return }
            defer { self.finishOperationTask(generation: generation) }
            let journalLoad = await worker.loadOperationJournal()
            guard !Task.isCancelled, self.operationGeneration == generation else { return }
            switch journalLoad {
            case .unreadable:
                state = .recoveryRequired
                return
            case let .readable(data):
                guard let journal = try? JSONDecoder().decode(
                    BlocksCLIOperationJournal.self,
                    from: data
                ) else {
                    state = .recoveryRequired
                    return
                }
                isRecovering = true
                let acquired = await worker.withOperationLease { [weak self] in
                    await self?.performJournalRecovery(
                        journal,
                        generation: generation,
                        beforeJournalRecovery: beforeJournalRecovery
                    )
                }
                guard !Task.isCancelled,
                      self.operationGeneration == generation else {
                    return
                }
                if !acquired {
                    isRecovering = false
                    state = .recoveryRequired
                }
                return
            case .absent:
                break
            }
            // A journal is the durable authority for an unfinished mutation.
            // A standalone recovery bookmark can also describe a deliberately
            // preserved pre-update executable after the new installation and
            // record have committed. Keep that object revealable, but do not
            // let the hint hide a verified, current installation.
            let recordData = await worker.loadInstallationRecord()
            guard !Task.isCancelled,
                  self.operationGeneration == generation else {
                return
            }
            self.cachedInstallationRecordData = recordData
            let residualRecoveryURL = resolvedRecoveryURL(
                recordData: recordData
            )
            self.recoveryURL = residualRecoveryURL
            let result = await worker.refresh(
                sourceURL: sourceURL,
                recordData: recordData,
                legacyBookmark: legacyBookmark
            )
            guard !Task.isCancelled, self.operationGeneration == generation else { return }
            switch result {
            case let .state(state):
                // With no durable journal, the worker's verified destination
                // state remains authoritative. A standalone bookmark is only
                // a reveal hint for a preserved cleanup object; it must not
                // obscure changed, missing, or inaccessible installation
                // truth, and it cannot authorize a mutation on its own.
                self.state = state
                if state == .changed,
                   let legacyBookmark,
                   let legacyURL = self.bookmarkAccess.resolve(legacyBookmark) {
                    self.legacyDisplayURL = legacyURL
                }
            case let .migratedRecord(data):
                self.state = await self.saveInstallationRecord(data) ? .installedCurrent : .failed
            }
        }
    }

    private func performJournalRecovery(
        _ journal: BlocksCLIOperationJournal,
        generation: Int,
        beforeJournalRecovery: @Sendable () async -> Void
    ) async {
        await beforeJournalRecovery()
        guard !Task.isCancelled,
              operationGeneration == generation else {
            return
        }
        let result = await worker.recover(journal)
        guard !Task.isCancelled,
              operationGeneration == generation else {
            return
        }
        isRecovering = false
        switch result {
        case let .installed(record):
            guard await saveInstallationRecord(record),
                  await clearJournal() else {
                state = .recoveryRequired
                return
            }
            clearRecovery()
            refresh()
        case let .previousInstallationRestored(previousRecord):
            guard await restoreInstallationRecord(previousRecord),
                  await clearJournal() else {
                state = .recoveryRequired
                return
            }
            clearRecovery()
            refresh()
        case .firstInstallationNotCommitted, .uninstalled:
            guard await clearInstallationRecord(),
                  await clearJournal() else {
                state = .recoveryRequired
                return
            }
            clearRecovery()
            state = .notInstalled
        case let .recovery(url):
            if let url { saveRecovery(url) }
            state = .recoveryRequired
        }
    }

    func uninstall() {
        guard !isBusy else { return }
        let generation = beginOperation()
        state = .uninstalling
        recoveryURL = nil
        operationTask = Task { [weak self, worker] in
            guard let self else { return }
            defer { self.finishOperationTask(generation: generation) }
            let acquired = await worker.withOperationLease { [weak self] in
                await self?.performUninstall(generation: generation)
            }
            guard !Task.isCancelled,
                  self.operationGeneration == generation else {
                return
            }
            if !acquired {
                self.state = .recoveryRequired
            }
        }
    }

    private func journalBlocksMutation(
        _ result: BlocksCLIOperationJournalLoadResult
    ) -> Bool {
        if case .absent = result { return false }
        return true
    }

    private func performUninstall(generation: Int) async {
        guard !journalBlocksMutation(await worker.loadOperationJournal()) else {
            guard !Task.isCancelled,
                  operationGeneration == generation else {
                return
            }
            state = .recoveryRequired
            return
        }
        guard !Task.isCancelled,
              operationGeneration == generation else {
            return
        }
        let recordData: Data?
        if let cachedInstallationRecordData {
            recordData = cachedInstallationRecordData
        } else {
            recordData = await worker.loadInstallationRecord()
        }
        cachedInstallationRecordData = recordData
        let result = await worker.uninstall(recordData: recordData)
        if case .removed = result {
            guard await clearInstallationRecord(),
                  await clearJournal() else {
                state = .recoveryRequired
                return
            }
            clearRecovery()
            state = .notInstalled
            return
        }
        guard operationGeneration == generation else { return }
        switch result {
        case let .recovery(url):
            saveRecovery(url)
            state = .recoveryRequired
        case .cancelled, .refresh:
            guard await clearJournal() else {
                state = .recoveryRequired
                return
            }
            refreshAfterUncommittedUninstall()
        case .failed:
            state = journalBlocksMutation(await worker.loadOperationJournal())
                ? .recoveryRequired : .failed
        case .removed:
            assertionFailure(
                "Committed uninstall result must be handled before generation checks"
            )
        }
    }

    func chooseDestinationAndInstall() {
        guard let sourceURL = sourceURLProvider() else {
            state = .unavailable
            return
        }
        if isInstalled {
            guard let record = installationRecord(),
                  let resolvedRecord = resolveCLIRecordDestination(
                    record,
                    using: bookmarkAccess
                  ) else {
                state = .inaccessible
                return
            }
            startInstall(sourceURL: sourceURL, destinationURL: resolvedRecord.destinationURL)
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.string("settings.agentCLI.install.panelTitle")
        panel.prompt = L10n.string("settings.agentCLI.install.button")
        panel.nameFieldStringValue = BlocksRuntimeIdentity.isLocalDevelopment ? "blocks-dev" : "blocks"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        panel.directoryURL = defaultDirectory
        panel.begin { [weak self] response in
            guard response == .OK, let destinationURL = panel.url else {
                return
            }
            self?.startInstall(sourceURL: sourceURL, destinationURL: destinationURL)
        }
    }

    private func startInstall(sourceURL: URL, destinationURL: URL) {
        guard !isBusy else { return }
        let generation = beginOperation()
        state = .installing
        recoveryURL = nil
        legacyDisplayURL = nil
        operationTask = Task { [weak self, worker] in
            guard let self else { return }
            defer { self.finishOperationTask(generation: generation) }
            let acquired = await worker.withOperationLease { [weak self] in
                await self?.performInstallWithLease(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    generation: generation
                )
            }
            guard !Task.isCancelled,
                  self.operationGeneration == generation else {
                return
            }
            if !acquired {
                self.state = .recoveryRequired
            }
        }
    }

    func startInstallForTesting(
        sourceURL: URL,
        destinationURL: URL
    ) {
        startInstall(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
    }

    func install(
        sourceURL: URL,
        destinationURL: URL
    ) async {
        guard !isBusy else { return }
        let generation = beginOperation()
        state = .installing
        recoveryURL = nil
        legacyDisplayURL = nil
        let acquired = await worker.withOperationLease { [weak self] in
            await self?.performInstallWithLease(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                generation: generation
            )
        }
        guard !Task.isCancelled,
              operationGeneration == generation else {
            return
        }
        if !acquired {
            state = .recoveryRequired
        }
    }

    private func performInstallWithLease(
        sourceURL: URL,
        destinationURL: URL,
        generation: Int
    ) async {
        guard !journalBlocksMutation(await worker.loadOperationJournal()) else {
            guard !Task.isCancelled,
                  operationGeneration == generation else {
                return
            }
            state = .recoveryRequired
            return
        }
        let previousRecordData = await worker.loadInstallationRecord()
        guard !Task.isCancelled, operationGeneration == generation else { return }
        cachedInstallationRecordData = previousRecordData
        let result = await worker.install(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            recordData: previousRecordData
        )
        guard !Task.isCancelled, operationGeneration == generation else {
            if journalBlocksMutation(await worker.loadOperationJournal()) {
                state = .recoveryRequired
            }
            return
        }
        switch result {
        case .destinationConflict:
            state = journalBlocksMutation(await worker.loadOperationJournal())
                ? .recoveryRequired : .destinationConflict
        case let .recovery(url):
            _ = saveRecovery(url)
            state = .recoveryRequired
        case .failedRestored:
            let restored = await restoreInstallationRecord(previousRecordData)
            let journalCleared = await clearJournal()
            state = restored && journalCleared ? .failed : .recoveryRequired
        case .failed:
            state = journalBlocksMutation(await worker.loadOperationJournal())
                ? .recoveryRequired : .failed
        case let .installed(
            record,
            recordValue,
            directoryBookmark,
            displacedOriginalURL,
            originalIdentity,
            originalDigest,
            installedIdentity,
            installedDigest
        ):
            guard await saveInstallationRecord(record) else {
                let restoreResult = await worker.restoreDestination(
                    destinationURL,
                    directoryBookmark: directoryBookmark,
                    displacedOriginalURL: displacedOriginalURL,
                    expectedOriginalIdentity: originalIdentity,
                    expectedOriginalDigest: originalDigest,
                    expectedInstalledIdentity: installedIdentity,
                    expectedInstalledDigest: installedDigest
                )
                guard !Task.isCancelled, operationGeneration == generation else {
                    if journalBlocksMutation(await worker.loadOperationJournal()) {
                        state = .recoveryRequired
                    }
                    return
                }
                if case let .recovery(url) = restoreResult {
                    _ = saveRecovery(url)
                    state = .recoveryRequired
                    return
                }
                if case .restored = restoreResult,
                   await restoreInstallationRecord(previousRecordData),
                   await clearJournal() {
                    state = .failed
                } else {
                    state = .recoveryRequired
                }
                return
            }
            let cleanupResult = await worker.discardDisplacedDestination(
                displacedOriginalURL,
                directoryBookmark: directoryBookmark,
                expectedIdentity: originalIdentity,
                expectedDigest: originalDigest
            )
            guard !Task.isCancelled,
                  operationGeneration == generation else {
                if journalBlocksMutation(await worker.loadOperationJournal()) {
                    state = .recoveryRequired
                }
                return
            }
            switch cleanupResult {
            case .removed:
                break
            case let .recovery(url):
                _ = saveRecovery(url)
                state = .recoveryRequired
                return
            case let .preserved(url):
                guard let originalIdentity,
                      let originalDigest,
                      let artifactBookmark = try? bookmarkAccess.make(url) else {
                    state = .recoveryRequired
                    return
                }
                let artifact = BlocksCLIPreservedCleanupArtifact(
                    securityScopedBookmark: artifactBookmark,
                    expectedSHA256: originalDigest,
                    expectedFileIdentity: originalIdentity,
                    displayPath: url.path
                )
                let durableRecord = BlocksCLIInstallationRecord(
                    securityScopedBookmark: recordValue.securityScopedBookmark,
                    directorySecurityScopedBookmark:
                        recordValue.directorySecurityScopedBookmark,
                    installedSHA256: recordValue.installedSHA256,
                    installedFileIdentity: recordValue.installedFileIdentity,
                    appVersion: recordValue.appVersion,
                    displayPath: recordValue.displayPath,
                    preservedCleanupArtifacts:
                        (recordValue.preservedCleanupArtifacts ?? []) + [artifact]
                )
                guard let durableRecordData = try? JSONEncoder().encode(durableRecord),
                      await saveInstallationRecord(durableRecordData) else {
                    state = .recoveryRequired
                    return
                }
                self.recoveryURL = url
            }
            guard await clearJournal() else {
                state = .recoveryRequired
                return
            }
            state = .installedCurrent
        }
    }

    private func installationRecord() -> BlocksCLIInstallationRecord? {
        guard let data = cachedInstallationRecordData else { return nil }
        return try? JSONDecoder().decode(BlocksCLIInstallationRecord.self, from: data)
    }

    private func saveInstallationRecord(_ data: Data) async -> Bool {
        guard await worker.saveInstallationRecord(data) else { return false }
        cachedInstallationRecordData = data
        defaults.removeObject(forKey: Self.bookmarkKey)
        return true
    }

    private func clearInstallationRecord() async -> Bool {
        guard await worker.clearInstallationRecord() else { return false }
        cachedInstallationRecordData = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        return defaults.data(forKey: Self.bookmarkKey) == nil
    }

    private func restoreInstallationRecord(_ previousRecord: Data?) async -> Bool {
        if let previousRecord {
            if cachedInstallationRecordData == previousRecord { return true }
            return await saveInstallationRecord(previousRecord)
        }
        if cachedInstallationRecordData == nil { return true }
        return await clearInstallationRecord()
    }

    private func clearJournal() async -> Bool {
        await worker.clearOperationJournal()
    }

    private func clearRecovery() {
        defaults.removeObject(forKey: Self.recoveryBookmarkKey)
        recoveryURL = nil
    }

    @discardableResult
    private func saveRecovery(_ url: URL) -> Bool {
        guard let bookmark = try? bookmarkAccess.make(url) else {
            recoveryURL = url
            return false
        }
        defaults.set(bookmark, forKey: Self.recoveryBookmarkKey)
        recoveryURL = url
        return defaults.data(forKey: Self.recoveryBookmarkKey) == bookmark
    }

    private func resolvedRecoveryURL(recordData: Data? = nil) -> URL? {
        if let recordData,
           let record = try? JSONDecoder().decode(
               BlocksCLIInstallationRecord.self,
               from: recordData
           ),
           let artifacts = record.preservedCleanupArtifacts {
            for artifact in artifacts.reversed() {
                guard let url = bookmarkAccess.resolve(
                    artifact.securityScopedBookmark
                ), bookmarkAccess.start(url) else {
                    continue
                }
                defer { bookmarkAccess.stop(url) }
                guard FileManager.default.fileExists(atPath: url.path),
                      BlocksCLIFileIdentity.resourceIdentifier(of: url)
                        == artifact.expectedFileIdentity,
                      BlocksCLIFileDigest.sha256(of: url)
                        == artifact.expectedSHA256 else {
                    continue
                }
                return url
            }
        }
        guard let bookmark = defaults.data(forKey: Self.recoveryBookmarkKey),
              let url = bookmarkAccess.resolve(bookmark),
              bookmarkAccess.start(url) else {
            defaults.removeObject(forKey: Self.recoveryBookmarkKey)
            return nil
        }
        defer { bookmarkAccess.stop(url) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            defaults.removeObject(forKey: Self.recoveryBookmarkKey)
            return nil
        }
        return url
    }

    private func beginOperation() -> Int {
        operationFallbackState = state
        operationGeneration += 1
        operationTask?.cancel()
        operationTask = nil
        return operationGeneration
    }

    private func finishOperationTask(generation: Int) {
        guard operationGeneration == generation else { return }
        operationTask = nil
    }

    func cancelForRouteExit() {
        operationGeneration += 1
        operationTask?.cancel()
        operationTask = nil
        isRecovering = false
        switch state {
        case .installing, .uninstalling:
            state = operationFallbackState
        default:
            break
        }
    }

    deinit {
        operationTask?.cancel()
    }

    private func refreshAfterUncommittedUninstall() {
        state = .notInstalled
        refresh()
    }

    func revealRecovery() {
        if let recoveryURL = resolvedRecoveryURL(
            recordData: cachedInstallationRecordData
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
            return
        }
        guard let legacyBookmark = defaults.data(forKey: Self.bookmarkKey),
              let legacyURL = bookmarkAccess.resolve(legacyBookmark),
              bookmarkAccess.start(legacyURL) else { return }
        defer { bookmarkAccess.stop(legacyURL) }
        NSWorkspace.shared.activateFileViewerSelecting([legacyURL])
    }

    private func statusWithPath(_ key: String) -> String {
        let path = installationRecord()?.displayPath
            ?? legacyDisplayURL?.path
        guard let path else { return L10n.string(key) }
        return L10n.format(key, path)
    }

}

private struct ActionBrokerSettingsSection: View {
    @ObservedObject var manager: ActionBrokerServiceManager

    var body: some View {
        SettingsSection(title: L10n.string("settings.agentCLI.actionBroker")) {
            SettingsStatusRow(
                title: L10n.string("settings.agentCLI.actionBroker.enable"),
                detail: L10n.string("settings.agentCLI.actionBroker.detail"),
                status: SettingsRowStatus(
                    kind: ActionBrokerSettingsStatePresentation.feedbackKind(for: manager.state),
                    message: ActionBrokerSettingsStatePresentation.detail(for: manager.state)
                )
            ) {
                SettingsBooleanSwitch(L10n.string("settings.agentCLI.actionBroker.enable"), isOn: Binding(
                    get: { manager.isEnabled },
                    set: manager.setEnabled
                ))
            }
        }
        .onAppear { manager.refresh() }
    }

}

enum ActionBrokerSettingsStatePresentation {
    static func detail(for state: ActionBrokerServiceManager.State) -> String {
        switch state {
        case .disabled:
            L10n.string("settings.agentCLI.actionBroker.disabled")
        case .requiresApproval:
            L10n.string("settings.agentCLI.actionBroker.requiresApproval")
        case .connecting:
            L10n.string("settings.agentCLI.actionBroker.connecting")
        case .reconnecting:
            L10n.string("settings.agentCLI.actionBroker.reconnecting")
        case .recovering:
            L10n.string("settings.agentCLI.actionBroker.recovering")
        case .enabled:
            L10n.string("settings.agentCLI.actionBroker.enabled")
        case .unavailable:
            L10n.string("settings.agentCLI.actionBroker.unavailable")
        case let .failed(message):
            L10n.format("settings.agentCLI.actionBroker.failed", message)
        }
    }

    static func feedbackKind(
        for state: ActionBrokerServiceManager.State
    ) -> SettingsInlineFeedbackKind {
        switch state {
        case .enabled:
            .success
        case .requiresApproval, .connecting, .reconnecting, .recovering:
            .warning
        case .failed, .unavailable:
            .error
        case .disabled:
            .information
        }
    }
}
