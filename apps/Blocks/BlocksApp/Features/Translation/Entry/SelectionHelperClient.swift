import AppKit
import BlocksCore
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import OSLog
import Security

enum SelectionAgentServiceFailure: Error, Equatable {
    case helperNotInstalled
    case helperNotRunning
    case helperInstallationConflict
    case notPaired
    case invalidPairingCode
    case incompatibleVersion
    case connectionFailed
    case timedOut
    case invalidResponse
    case disconnectNotConfirmed
    case bootstrapUnavailable
}

struct SelectionHelperBundleIdentity: Equatable, Sendable {
    let teamID: String
    let signingIdentifier: String
}

protocol SelectionHelperBundleIdentityVerifying: Sendable {
    /// Returns signing identity only when the bundle's code signature is valid.
    func verifiedIdentity(
        for applicationURL: URL
    ) -> SelectionHelperBundleIdentity?
}

struct SelectionHelperBundleIdentityVerifier:
    SelectionHelperBundleIdentityVerifying
{
    func verifiedIdentity(
        for applicationURL: URL
    ) -> SelectionHelperBundleIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
              ) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let teamID = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamID.isEmpty,
              let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
              !signingIdentifier.isEmpty else {
            return nil
        }
        return SelectionHelperBundleIdentity(
            teamID: teamID,
            signingIdentifier: signingIdentifier
        )
    }
}

struct SelectionHelperApplicationLocator {
    private static let launchAdmission = ApplicationOperationAdmissionGate(name: "Selection Helper launch")
    private let candidateURLsProvider: () -> [URL]
    private let runningApplicationURLsProvider: () -> [URL]
    private let openApplication: (URL, Bool) -> Void
    private let allowedApplicationURLsProvider: () -> [URL]
    private let identityVerifier: any SelectionHelperBundleIdentityVerifying
    private let trustedHostTeamIdentifierProvider: () -> String?

    init(
        candidateURLsProvider:
            @escaping () -> [URL] =
                SelectionHelperApplicationLocator.defaultCandidateURLs,
        runningApplicationURLsProvider:
            @escaping () -> [URL] =
                SelectionHelperApplicationLocator.defaultRunningApplicationURLs,
        openApplication: @escaping (URL, Bool) -> Void =
            SelectionHelperApplicationLocator.openApplication,
        allowedApplicationURLsProvider:
            @escaping () -> [URL] =
                SelectionHelperApplicationLocator.defaultAllowedApplicationURLs,
        identityVerifier: any SelectionHelperBundleIdentityVerifying =
            SelectionHelperBundleIdentityVerifier(),
        trustedHostTeamIdentifierProvider: @escaping () -> String? =
            SelectionHelperApplicationLocator.defaultTrustedHostTeamIdentifier
    ) {
        self.candidateURLsProvider = candidateURLsProvider
        self.runningApplicationURLsProvider =
            runningApplicationURLsProvider
        self.openApplication = openApplication
        self.allowedApplicationURLsProvider = allowedApplicationURLsProvider
        self.identityVerifier = identityVerifier
        self.trustedHostTeamIdentifierProvider =
            trustedHostTeamIdentifierProvider
    }

    var resolvedApplicationURL: URL? {
        let candidates = candidateURLsProvider()
            .map(\.standardizedFileURL)
            .reduce(into: [String: URL]()) {
                $0[$1.path] = $1
            }
            .values
            .filter(isTrustedSelectionHelper)
        return candidates.sorted {
            let lhs = Self.preferenceScore(for: $0)
            let rhs = Self.preferenceScore(for: $1)
            if lhs != rhs {
                return lhs < rhs
            }
            return $0.path < $1.path
        }.first
    }

    private static func defaultCandidateURLs() -> [URL] {
        #if BLOCKS_LOCAL_DEVELOPMENT
        return [bundledHelperURL]
        #else
        var candidates: [URL] = [bundledHelperURL]
        candidates.append(
            contentsOf: NSRunningApplication.runningApplications(
                withBundleIdentifier:
                    BlocksSelectionHelperProtocol.bundleIdentifier
            ).compactMap(\.bundleURL)
        )
        let home = loginHomeDirectoryURL()
        candidates.append(
            home
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("BlocksDev", isDirectory: true)
                .appendingPathComponent("Debug", isDirectory: true)
                .appendingPathComponent(
                    "Blocks Selection Helper.app",
                    isDirectory: true
                )
        )
        candidates.append(
            URL(fileURLWithPath: "/Applications")
                .appendingPathComponent(
                    "Blocks Selection Helper.app",
                    isDirectory: true
                )
        )
        guard let schemeURL = URL(
            string:
                "\(BlocksSelectionHelperProtocol.urlScheme)://open"
        ) else {
            return candidates
        }
        candidates.append(
            contentsOf: NSWorkspace.shared.urlsForApplications(
                toOpen: schemeURL
            )
        )
        candidates.append(
            contentsOf: NSWorkspace.shared.urlsForApplications(
                withBundleIdentifier:
                    BlocksSelectionHelperProtocol.bundleIdentifier
            )
        )
        return candidates
        #endif
    }

    private static func defaultRunningApplicationURLs() -> [URL] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier:
                BlocksSelectionHelperProtocol.bundleIdentifier
        ).compactMap(\.bundleURL)
    }

    private static func defaultAllowedApplicationURLs() -> [URL] {
        guard DistributionChannel.current.supportsSelectionHelper else {
            return []
        }
        #if BLOCKS_LOCAL_DEVELOPMENT
        return [bundledHelperURL]
        #else
        var allowed = [
            bundledHelperURL,
            URL(fileURLWithPath: "/Applications/Blocks Selection Helper.app"),
        ]
        if DistributionChannel.current == .development {
            allowed.append(
                loginHomeDirectoryURL()
                    .appendingPathComponent(
                        "Applications/BlocksDev/Debug/Blocks Selection Helper.app"
                    )
            )
        }
        return allowed
        #endif
    }

    private static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Blocks Selection Helper.app")
    }

    private static func loginHomeDirectoryURL() -> URL {
        guard let passwordRecord = getpwuid(getuid()),
              let homeDirectory = passwordRecord.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(
            fileURLWithPath: String(cString: homeDirectory),
            isDirectory: true
        )
    }

    private static func defaultTrustedHostTeamIdentifier() -> String? {
        SelectionHelperBundleIdentityVerifier()
            .verifiedIdentity(for: Bundle.main.bundleURL)?.teamID
    }

    private static func openApplication(
        at applicationURL: URL,
        activates: Bool
    ) {
        guard let lease = launchAdmission.begin() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration,
            completionHandler: { _, _ in lease.release() }
        )
    }

    private func isTrustedSelectionHelper(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard allowedApplicationURLsProvider().contains(where: { $0.standardizedFileURL == standardizedURL }),
              Self.hasExpectedBundleIdentifier(at: standardizedURL),
              let executable = Bundle(url: standardizedURL)?.executableURL,
              let host = Bundle.main.executableURL else { return false }
        return BlocksLocalBuildTrust.accepts(executableURL: executable, role: "helper")
            && BlocksLocalBuildTrust.accepts(executableURL: host, role: "app")
        #else
        guard allowedApplicationURLsProvider().contains(where: {
            $0.standardizedFileURL == standardizedURL
        }),
              Self.hasExpectedBundleIdentifier(at: standardizedURL),
              let trustedHostTeamID = trustedHostTeamIdentifierProvider(),
              let helperIdentity = identityVerifier.verifiedIdentity(
                for: standardizedURL
              ),
              helperIdentity.teamID == trustedHostTeamID,
              helperIdentity.signingIdentifier
                == BlocksSelectionHelperProtocol.bundleIdentifier else {
            return false
        }
        return true
        #endif
    }

    private static func hasExpectedBundleIdentifier(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            && Bundle(url: url)?.bundleIdentifier ==
                BlocksSelectionHelperProtocol.bundleIdentifier
    }

    private static func preferenceScore(for url: URL) -> Int {
        if url.standardizedFileURL == bundledHelperURL.standardizedFileURL { return -1 }
        let path = url.path
        if path == "/Applications/Blocks Selection Helper.app" {
            return 0
        }
        if path.contains("/Applications/BlocksDev/") {
            return 1
        }
        if path.contains("/Applications/") {
            return 2
        }
        if path.contains("/DerivedData/")
            || path.contains("/Build/Products/") {
            return 10
        }
        return 4
    }

    var isInstalled: Bool {
        resolvedApplicationURL != nil
    }

    var isRunning: Bool { !runningApplicationURLsProvider().isEmpty }

    var hasConflictingRunningApplication: Bool {
        let runningURLs = runningApplicationURLsProvider()
            .map(\.standardizedFileURL)
        guard !runningURLs.isEmpty else { return false }
        guard let applicationURL = resolvedApplicationURL else { return true }
        return runningURLs.contains {
            $0 != applicationURL.standardizedFileURL
        }
    }

    @discardableResult
    func open(activates: Bool = true) -> Bool {
        guard let applicationURL = resolvedApplicationURL else {
            return false
        }
        let runningURLs = runningApplicationURLsProvider()
            .map(\.standardizedFileURL)
        if runningURLs.contains(applicationURL.standardizedFileURL) {
            if activates,
               let matching = NSRunningApplication.runningApplications(
                withBundleIdentifier:
                    BlocksSelectionHelperProtocol.bundleIdentifier
               ).first(where: {
                   $0.bundleURL?.standardizedFileURL == applicationURL
                    .standardizedFileURL
               }) {
                matching.activate()
            }
            return true
        }
        // A translation shortcut must never terminate another Helper copy.
        // The user can resolve an installation conflict explicitly from
        // Translation Settings without losing an active pairing or capture.
        guard runningURLs.isEmpty else {
            return false
        }
        openApplication(applicationURL, activates)
        return true
    }
}

protocol SelectionHelperSharedKeyStoring: AnyObject {
    func load() -> Data?
    func save(_ data: Data) throws
    func delete()
    func permitsLocalAssociation() -> Bool
    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool
}

extension SelectionHelperSharedKeyStoring {
    func permitsLocalAssociation() -> Bool { false }
    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool { false }
}

protocol SelectionHelperBootstrapKeyLoading: AnyObject {
    func load() -> Data?
}

protocol SelectionHelperBootstrapKeyCreating:
    SelectionHelperBootstrapKeyLoading
{
    /// Creates this App's bootstrap secret exactly once, or returns the value
    /// installed by a concurrent App process.
    func createOrLoad() -> Data?
}

private enum SelectionHelperSharedKeychainAccessGroup {
    static func current() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              ) as? [String] else {
            return nil
        }
        let matchingGroups = groups.filter {
            $0.hasSuffix(
                BlocksSelectionHelperProtocol
                    .sharedKeychainAccessGroupSuffix
            )
        }
        guard matchingGroups.count == 1 else { return nil }
        return matchingGroups[0]
    }
}

final class SelectionHelperSharedKeyStore:
    @unchecked Sendable
{
    private static let localAssociationLogger = Logger(subsystem: "app.blocks.app", category: "LocalAssociation")
    private let service: String
    private let account: String
    private let accessGroupProvider: () -> String?
    private let itemCopyMatching: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    private let itemUpdate: (CFDictionary, CFDictionary) -> OSStatus
    private let itemAdd: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    private let itemDelete: (CFDictionary) -> OSStatus

    init(
        service: String =
            BlocksSelectionHelperProtocol.keychainService,
        account: String =
            BlocksSelectionHelperProtocol.keychainAccount,
        accessGroupProvider: @escaping () -> String? =
            SelectionHelperSharedKeychainAccessGroup.current,
        itemCopyMatching: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = SecItemCopyMatching,
        itemUpdate: @escaping (CFDictionary, CFDictionary) -> OSStatus =
            SecItemUpdate,
        itemAdd: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = SecItemAdd,
        itemDelete: @escaping (CFDictionary) -> OSStatus = SecItemDelete
    ) {
        self.service = service
        self.account = account
        self.accessGroupProvider = accessGroupProvider
        self.itemCopyMatching = itemCopyMatching
        self.itemUpdate = itemUpdate
        self.itemAdd = itemAdd
        self.itemDelete = itemDelete
    }

    func load() -> Data? {
        var result: CFTypeRef?
        guard var query = keychainQuery(
            service: service,
            account: account
        ) else {
            return nil
        }
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String:
                kSecMatchLimitOne,
        ]) { _, new in new }
        guard itemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            return nil
        }
        return data
    }

    func save(_ data: Data) throws {
        guard data.count == 32 else {
            throw SelectionAgentServiceFailure.invalidResponse
        }
        guard let query = keychainQuery(
            service: service,
            account: account
        ) else {
            throw SelectionAgentServiceFailure.connectionFailed
        }
        let update = [
            kSecValueData as String: data,
        ] as CFDictionary
        let status = itemUpdate(
            query as CFDictionary,
            update
        )
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard itemAdd(
                item as CFDictionary,
                nil
            ) == errSecSuccess else {
                throw SelectionAgentServiceFailure
                    .connectionFailed
            }
        } else if status != errSecSuccess {
            throw SelectionAgentServiceFailure.connectionFailed
        }
        deleteLegacyActiveKey()
    }

    func permitsLocalAssociation() -> Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        let identities = [(service, account),
                          (BlocksSelectionHelperProtocol.legacyKeychainService, BlocksSelectionHelperProtocol.legacyKeychainAccount),
                          ("\(service).disconnect-tombstone", "v1")]
        return identities.enumerated().allSatisfy { index, identity in
            let (service, account) = identity
            guard var query = keychainQuery(service: service, account: account) else { return false }
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = itemCopyMatching(query as CFDictionary, nil)
            if status != errSecItemNotFound {
                Self.localAssociationLogger.notice("stage=app-keychain-absence slot=\(index, privacy: .public) status=\(status, privacy: .public)")
            }
            return status == errSecItemNotFound
        }
        #else
        return false
        #endif
    }

    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool {
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard data.count == 32, var query = keychainQuery(service: service, account: account) else { return false }
        query[kSecValueData as String] = data
        // Deliberately no SecItemUpdate and no deletion of a legacy pairing.
        return itemAdd(query as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    func delete() {
        guard let query = keychainQuery(
            service: service,
            account: account
        ) else {
            return
        }
        _ = itemDelete(query as CFDictionary)
    }

    private func keychainQuery(
        service: String,
        account: String
    ) -> [String: Any]? {
        BlocksKeychainNamespace.helperQuery(
            service: service, account: account, accessGroup: accessGroupProvider()
        )
    }

    private func deleteLegacyActiveKey() {
        guard let query = keychainQuery(
            service: BlocksSelectionHelperProtocol.legacyKeychainService,
            account: BlocksSelectionHelperProtocol.legacyKeychainAccount
        ) else {
            return
        }
        _ = itemDelete(query as CFDictionary)
    }
}

extension SelectionHelperSharedKeyStore: SelectionHelperSharedKeyStoring {}

enum SelectionHelperBootstrapKeyCreationCoordinator {
    static func createOrLoad(
        load: () -> Data?,
        generate: () -> Data?,
        add: (Data) -> OSStatus
    ) -> Data? {
        if let key = load(), key.count == 32 { return key }
        guard let generatedKey = generate(), generatedKey.count == 32 else {
            return nil
        }
        let status = add(generatedKey)
        if status == errSecSuccess { return generatedKey }
        // A duplicate is the only recoverable write failure: another process
        // installed the shared value after our first read.
        guard status == errSecDuplicateItem,
              let key = load(),
              key.count == 32 else {
            return nil
        }
        return key
    }
}

final class SelectionHelperBootstrapKeyStore:
    SelectionHelperBootstrapKeyCreating,
    @unchecked Sendable
{
    func load() -> Data? {
        var result: CFTypeRef?
        guard var query = keychainQuery() else { return nil }
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        guard SecItemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            return nil
        }
        return data
    }

    func createOrLoad() -> Data? {
        SelectionHelperBootstrapKeyCreationCoordinator.createOrLoad(
            load: load,
            generate: randomKey,
            add: { [weak self] key in
                guard let self,
                      var item = self.keychainQuery() else {
                    return errSecAuthFailed
                }
                item[kSecValueData as String] = key
                return SecItemAdd(item as CFDictionary, nil)
            }
        )
    }

    private func randomKey() -> Data? {
        var key = Data(repeating: 0, count: 32)
        let byteCount = key.count
        let status = key.withUnsafeMutableBytes {
            (buffer: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                byteCount,
                baseAddress
            )
        }
        return status == errSecSuccess ? key : nil
    }

    private func keychainQuery() -> [String: Any]? {
        BlocksKeychainNamespace.helperQuery(
            service: BlocksSelectionHelperProtocol.bootstrapKeychainService,
            account: BlocksSelectionHelperProtocol.bootstrapKeychainAccount,
            accessGroup: SelectionHelperSharedKeychainAccessGroup.current()
        )
    }
}

protocol SelectionHelperLoopbackConnecting: AnyObject {
    func send(
        _ packet: SelectionHelperWirePacket,
        timeout: TimeInterval
    ) -> Result<Data, SelectionAgentServiceFailure>
}

final class SelectionHelperLoopbackConnection:
    @unchecked Sendable
{
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port

    init(
        host: NWEndpoint.Host = "127.0.0.1",
        port: NWEndpoint.Port = NWEndpoint.Port(
            rawValue:
                BlocksSelectionHelperProtocol.loopbackPort
        )!
    ) {
        self.host = host
        self.port = port
    }

    func send(
        _ packet: SelectionHelperWirePacket,
        timeout: TimeInterval
    ) -> Result<Data, SelectionAgentServiceFailure> {
        guard let encoded = try? JSONEncoder().encode(packet),
              encoded.count <=
                BlocksSelectionCaptureProtocol
                    .maximumRequestBytes else {
            return .failure(.invalidResponse)
        }
        let waiter = BlockingHelperReply<Data>()
        let connection = NWConnection(
            host: host,
            port: port,
            using: .tcp
        )
        let queue = DispatchQueue(
            label:
                "app.blocks.selection-helper.client"
        )
        var response = Data()
        func receiveNext() {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1_024
            ) { data, _, isComplete, error in
                if let data {
                    response.append(data)
                    if response.count >
                        BlocksSelectionHelperProtocol
                            .maximumWireBytes {
                        waiter.resolve(.failure(.invalidResponse))
                        connection.cancel()
                        return
                    }
                }
                if error != nil {
                    waiter.resolve(.failure(.connectionFailed))
                    connection.cancel()
                } else if isComplete {
                    guard response.last == 0x0A,
                          let newline = response.firstIndex(of: 0x0A),
                          newline == response.index(before: response.endIndex)
                    else {
                        waiter.resolve(.failure(.invalidResponse))
                        connection.cancel()
                        return
                    }
                    waiter.resolve(.success(Data(response[..<newline])))
                    connection.cancel()
                } else {
                    receiveNext()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: encoded + Data([0x0A]),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if error != nil {
                            waiter.resolve(
                                .failure(.connectionFailed)
                            )
                            connection.cancel()
                            return
                        }
                        receiveNext()
                    }
                )
            case .failed, .cancelled:
                waiter.resolve(.failure(.connectionFailed))
            default:
                break
            }
        }
        connection.start(queue: queue)
        let result = waiter.wait(timeout: timeout)
        connection.cancel()
        return result
    }
}

extension SelectionHelperLoopbackConnection:
    SelectionHelperLoopbackConnecting {}

final class SelectionHelperClient: @unchecked Sendable {
    private static let pairingMutationLock = NSLock()
    private let applicationUpdateGate = ApplicationOperationAdmissionGate(name: "Selection Helper client")
    private let updateStateLock = NSLock()
    private var helperWasRunningBeforeUpdate = false
    private var updatePreparationStarted = false
    private var pasteTargetInspectionApplicationLease: ApplicationOperationAdmissionGate.Lease?

    @MainActor
    func prepareForApplicationUpdate() async throws {
        try await Task.detached { [self] in
            try applicationUpdateGate.pauseIfIdle()
            guard !applicationLocator.hasConflictingRunningApplication else {
                throw SelectionAgentServiceFailure.helperInstallationConflict
            }
            guard applicationLocator.isRunning else { return }
            updateStateLock.withLock {
                helperWasRunningBeforeUpdate = true
            }
            guard let key = keyStore.load() else { throw SelectionAgentServiceFailure.notPaired }
            guard case let .success(healthResponse) = sendAuthenticated(
                .init(kind: .health), keyData: key, timeout: 0.5, lifecycleControl: true
            ), healthResponse.health?.capabilities.contains(BlocksSelectionHelperProtocol.updateLifecycleCapability) == true else {
                throw SelectionAgentServiceFailure.incompatibleVersion
            }
            updateStateLock.withLock { updatePreparationStarted = true }
            guard case let .success(preparation) = sendAuthenticated(
                .init(kind: .prepareForApplicationUpdate), keyData: key, timeout: 0.5, lifecycleControl: true
            ), preparation.booleanValue == true else {
                throw ApplicationOperationAdmissionGate.AdmissionError.busy("Selection Helper")
            }
            guard case let .success(termination) = sendAuthenticated(
                .init(kind: .terminateForApplicationUpdate), keyData: key, timeout: 0.5, lifecycleControl: true
            ), termination.booleanValue == true else {
                throw SelectionAgentServiceFailure.connectionFailed
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while applicationLocator.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard !applicationLocator.isRunning else { throw SelectionAgentServiceFailure.timedOut }
        }.value
    }

    @MainActor
    func resumeAfterCancelledApplicationUpdate() async {
        await Task.detached { [self] in
            let needsRestore = updateStateLock.withLock { updatePreparationStarted && helperWasRunningBeforeUpdate }
            var restored = !needsRestore
            if needsRestore {
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var launchRequested = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if applicationLocator.isRunning, let key = keyStore.load(),
                       case let .success(response) = sendAuthenticated(
                           .init(kind: .resumeAfterCancelledApplicationUpdate), keyData: key,
                           timeout: 0.25, lifecycleControl: true
                       ), response.booleanValue == true {
                        restored = true
                        break
                    }
                    if !applicationLocator.isRunning, !launchRequested {
                        launchRequested = applicationLocator.open(activates: false)
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            updateStateLock.withLock {
                if restored {
                    updatePreparationStarted = false
                    helperWasRunningBeforeUpdate = false
                }
            }
            if !restored { Self.logger.error("update cancellation could not confirm Helper recovery; pairing was preserved") }
            applicationUpdateGate.resume()
        }.value
    }

    var hasPendingApplicationUpdateRecovery: Bool {
        updateStateLock.withLock { updatePreparationStarted && helperWasRunningBeforeUpdate }
    }

    func beginApplicationOperation() -> ApplicationOperationAdmissionGate.Lease? { applicationUpdateGate.begin() }
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "SelectionHelper"
    )

    private let keyStore: any SelectionHelperSharedKeyStoring
    private let bootstrapKeyStore: any SelectionHelperBootstrapKeyCreating
    private let connection: any SelectionHelperLoopbackConnecting
    private let applicationLocator: SelectionHelperApplicationLocator
    /// Synchronous loopback IPC is intentionally isolated from UI/MainActor
    /// work. This gate rejects a concurrent hint instead of accumulating a
    /// queue of stale paste targets.
    private let pasteTargetInspectionQueue = DispatchQueue(
        label: "app.blocks.selection-helper.paste-target-inspection",
        qos: .userInitiated
    )
    private let pasteTargetInspectionTimeoutQueue = DispatchQueue(
        label: "app.blocks.selection-helper.paste-target-inspection-timeout",
        qos: .userInitiated
    )
    private let pasteTargetInspectionLock = NSLock()
    private var pasteTargetInspectionInFlight = false

    init(
        keyStore: any SelectionHelperSharedKeyStoring =
            SelectionHelperSharedKeyStore(),
        bootstrapKeyStore: any SelectionHelperBootstrapKeyCreating =
            SelectionHelperBootstrapKeyStore(),
        connection: any SelectionHelperLoopbackConnecting =
            SelectionHelperLoopbackConnection(),
        applicationLocator: SelectionHelperApplicationLocator =
            SelectionHelperApplicationLocator()
    ) {
        self.keyStore = keyStore
        self.bootstrapKeyStore = bootstrapKeyStore
        self.connection = connection
        self.applicationLocator = applicationLocator
    }

    var isInstalled: Bool {
        applicationLocator.isInstalled
    }

    var trustedApplicationURL: URL? {
        guard !hasInstallationConflict else { return nil }
        return applicationLocator.resolvedApplicationURL
    }

    var isPaired: Bool {
        keyStore.load() != nil
    }

    var hasInstallationConflict: Bool {
        applicationLocator.hasConflictingRunningApplication
    }

    @discardableResult
    func openHelper(activates: Bool = true) -> Bool {
        guard let lease = applicationUpdateGate.begin() else { return false }
        defer { lease.release() }
        if let url = applicationLocator.resolvedApplicationURL {
            Self.logger.info(
                "helper launch path=\(url.path, privacy: .public) activates=\(activates, privacy: .public)"
            )
        }
        return applicationLocator.open(activates: activates)
    }

    func disconnect(
        timeout: TimeInterval = 0.4
    ) -> Result<Void, SelectionAgentServiceFailure> {
        Self.pairingMutationLock.lock()
        defer { Self.pairingMutationLock.unlock() }
        guard let lease = applicationUpdateGate.begin() else { return .failure(.connectionFailed) }
        defer { lease.release() }
        guard keyStore.load() != nil else {
            return .success(())
        }
        switch booleanCommand(.disconnect, timeout: timeout) {
        case .success(true):
            // The Helper has authenticated the request and confirmed that its
            // key was removed, so it is now safe to remove this App's key.
            keyStore.delete()
            return .success(())
        case .success(false):
            return .failure(.disconnectNotConfirmed)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    func pair(
        code: String,
        timeout: TimeInterval = 1
    ) -> Result<SelectionHelperHealth, SelectionAgentServiceFailure> {
        Self.pairingMutationLock.lock()
        defer { Self.pairingMutationLock.unlock() }
        guard let lease = applicationUpdateGate.begin() else { return .failure(.connectionFailed) }
        defer { lease.release() }
        guard !hasInstallationConflict else {
            return .failure(.helperInstallationConflict)
        }
        let normalized = code.filter(\.isNumber)
        guard normalized.count == 6 else {
            return .failure(.invalidPairingCode)
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let requestID = UUID().uuidString
        guard let bootstrapKey = bootstrapKeyStore.createOrLoad() else {
            return .failure(.bootstrapUnavailable)
        }
        let clientPublicKey = privateKey.publicKey.rawRepresentation
        guard let clientProof =
                SelectionHelperPairingAuthentication.clientProof(
                    bootstrapKey: bootstrapKey,
                    requestID: requestID,
                    pairingCode: normalized,
                    clientPublicKey: clientPublicKey
                ) else {
            return .failure(.invalidResponse)
        }
        let request = SelectionHelperPairRequest(
            requestID: requestID,
            pairingCode: normalized,
            clientPublicKey: clientPublicKey,
            clientProof: clientProof
        )
        guard let payload = try? JSONEncoder().encode(request) else {
            return .failure(.invalidResponse)
        }
        let packet = SelectionHelperWirePacket(
            kind: .pair,
            payload: payload
        )
        var result = connection.send(packet, timeout: timeout)
        if case let .failure(failure) = result,
           failure == .timedOut || failure == .connectionFailed {
            // Retry only a transport failure and reuse every byte of the
            // pairing transcript. The Helper can safely replay a recent,
            // exact successful request without consuming its pairing code.
            result = connection.send(packet, timeout: timeout)
        }
        guard case let .success(data) = result,
              let packet = try? JSONDecoder().decode(
                SelectionHelperWirePacket.self,
                from: data
              ),
              packet.kind == .pair,
              let response = try? JSONDecoder().decode(
                SelectionHelperPairResponse.self,
                from: packet.payload
              ),
              response.requestID == requestID else {
            if case let .failure(failure) = result {
                return .failure(failure)
            }
            return .failure(.invalidResponse)
        }
        if response.protocolVersion !=
            BlocksSelectionHelperProtocol.version {
            return .failure(.incompatibleVersion)
        }
        if response.failureCode == "invalid_pairing_code" {
            return .failure(.invalidPairingCode)
        }
        if response.failureCode == "bootstrap_unavailable" {
            return .failure(.bootstrapUnavailable)
        }
        guard let helperPublicKey = response.helperPublicKey,
              let helperProof = response.helperProof,
              let key = try? SelectionHelperAuthenticatedCodec
                .deriveSharedKey(
                    privateKey: privateKey,
                    peerPublicKeyData: helperPublicKey,
                    requestID: requestID
                ),
              SelectionHelperPairingAuthentication.verifiesHelperProof(
                helperProof,
                bootstrapKey: bootstrapKey,
                request: request,
                helperPublicKey: helperPublicKey
              ) else {
            return .failure(.invalidResponse)
        }
        do {
            try keyStore.save(key)
        } catch {
            return .failure(.connectionFailed)
        }
        return health(timeout: timeout)
    }

    /// Call from a background queue after the trusted installed Helper is
    /// running. Existing pairing always wins: an authentication failure never
    /// triggers reset, replacement, installation, or an upgrade. Older Helpers
    /// without this optional socket retain the manual pairing workflow.
    func associateLocallyIfNeeded(
        timeout: TimeInterval = 0.5
    ) -> Result<SelectionHelperHealth, SelectionAgentServiceFailure> {
        Self.pairingMutationLock.lock()
        defer { Self.pairingMutationLock.unlock() }
        if keyStore.load() != nil { return health(timeout: timeout) }
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard let lease = applicationUpdateGate.begin() else { return .failure(.connectionFailed) }
        defer { lease.release() }
        guard !hasInstallationConflict else { return .failure(.helperInstallationConflict) }
        guard applicationLocator.isInstalled else { return .failure(.helperNotInstalled) }
        guard applicationLocator.isRunning else { return .failure(.helperNotRunning) }
        guard keyStore.permitsLocalAssociation() else { return .failure(.notPaired) }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let requestID = UUID().uuidString
        guard let authorization = SelectionHelperLocalAssociationTransport.send(
            .init(kind: .authorize, requestID: requestID, clientPublicKey: publicKey), timeout: timeout
        )?.authorization else {
            Self.logger.notice("local-association stage=authorization-unavailable")
            return .failure(.notPaired)
        }
        guard authorization.requestID == requestID, authorization.clientPublicKey == publicKey,
              authorization.bootstrapKey.count == 32, !authorization.code.isEmpty,
              Date() < authorization.expiresAt,
              authorization.expiresAt.timeIntervalSinceNow <= 5 else {
            Self.logger.notice("local-association stage=authorization-invalid")
            return .failure(.notPaired)
        }
        guard let proof = SelectionHelperPairingAuthentication.clientProof(
                bootstrapKey: authorization.bootstrapKey, requestID: requestID,
                pairingCode: authorization.code, clientPublicKey: publicKey
              ) else {
            Self.logger.error("local-association stage=client-proof-invalid")
            return .failure(.notPaired)
        }
        let request = SelectionHelperPairRequest(requestID: requestID, pairingCode: authorization.code,
                                                 clientPublicKey: publicKey, clientProof: proof)
        guard let data = SelectionHelperLocalAssociationTransport.send(
            .init(kind: .pair, requestID: requestID, pairRequest: request), timeout: timeout
        )?.pairPacket,
              let packet = try? JSONDecoder().decode(SelectionHelperWirePacket.self, from: data),
              packet.kind == .pair,
              let response = try? JSONDecoder().decode(SelectionHelperPairResponse.self, from: packet.payload),
              response.requestID == requestID,
              response.protocolVersion == BlocksSelectionHelperProtocol.version,
              response.failureCode == nil,
              let helperPublicKey = response.helperPublicKey, let helperProof = response.helperProof,
              SelectionHelperPairingAuthentication.verifiesHelperProof(
                helperProof, bootstrapKey: authorization.bootstrapKey, request: request,
                helperPublicKey: helperPublicKey
              ),
              let key = try? SelectionHelperAuthenticatedCodec.deriveSharedKey(
                privateKey: privateKey, peerPublicKeyData: helperPublicKey, requestID: requestID
              ) else { return .failure(.notPaired) }
        // The login-keychain backend may already expose the same entry saved
        // by the Helper. Never update it, even if a conflicting key appeared
        // while this request was in flight.
        if let existing = keyStore.load() {
            guard existing == key else { return .failure(.notPaired) }
        } else if !keyStore.saveLocalAssociationIfAbsent(key) {
            guard keyStore.load() == key else { return .failure(.connectionFailed) }
        }
        return health(timeout: timeout)
        #else
        return .failure(.notPaired)
        #endif
    }

    func health(
        timeout: TimeInterval = 0.5
    ) -> Result<SelectionHelperHealth, SelectionAgentServiceFailure> {
        guard !hasInstallationConflict else {
            return .failure(.helperInstallationConflict)
        }
        guard let key = keyStore.load() else {
            return .failure(.notPaired)
        }
        return sendAuthenticated(
            SelectionHelperCommand(kind: .health),
            keyData: key,
            timeout: timeout
        ).flatMap { response in
            guard let health = response.health else {
                return .failure(.invalidResponse)
            }
            guard health.protocolVersion >=
                    BlocksSelectionHelperProtocol
                        .minimumCompatibleVersion,
                  health.protocolVersion <=
                    BlocksSelectionHelperProtocol.version else {
                return .failure(.incompatibleVersion)
            }
            return .success(health)
        }
    }

    /// Best-effort optional enhancement for paste admission. It never launches
    /// or pairs the Helper; callers must treat nil and unknown as the regular
    /// paste path.
    func inspectPasteTargetIfAvailable(
        request: SelectionHelperPasteTargetRequest,
        timeout: TimeInterval = 0.15
    ) async -> SelectionHelperPasteTargetInspection? {
        guard request.isValid,
              beginPasteTargetInspection() else {
            return nil
        }
        let deadline = SelectionHelperPasteTargetInspectionDeadline(
            timeout: timeout
        )
        return await withCheckedContinuation { continuation in
            let completion = SelectionHelperPasteTargetInspectionCompletion(
                continuation: continuation
            )
            pasteTargetInspectionTimeoutQueue.asyncAfter(
                deadline: .now() + deadline.remainingDuration
            ) {
                completion.resolve(nil)
            }
            pasteTargetInspectionQueue.async { [weak self] in
                guard let self else {
                    completion.resolve(nil)
                    return
                }
                defer {
                    self.endPasteTargetInspection()
                }
                guard deadline.hasRemainingTime,
                      let key = self.keyStore.load(),
                      deadline.hasRemainingTime,
                      !self.hasInstallationConflict,
                      deadline.hasRemainingTime else {
                    completion.resolve(nil)
                    return
                }
                guard let health = self.optionalHealth(
                    keyData: key,
                    timeout: deadline.remainingTimeInterval
                ), health.capabilities.contains(
                    BlocksSelectionHelperProtocol
                        .pasteTargetInspectionCapability
                ), deadline.hasRemainingTime else {
                    completion.resolve(nil)
                    return
                }
                let remaining = deadline.remainingTimeInterval
                guard remaining > 0,
                      case let .success(response) = self.sendAuthenticated(
                        SelectionHelperCommand(
                            kind: .inspectPasteTarget,
                            pasteTargetRequest: request
                        ),
                        keyData: key,
                        timeout: remaining
                      ),
                      let inspection = response.pasteTargetInspection,
                      inspection.requestID == request.requestID,
                      inspection.targetPID == request.targetPID,
                      inspection.targetBundleIdentifier
                        == request.targetBundleIdentifier,
                      deadline.hasRemainingTime else {
                    completion.resolve(nil)
                    return
                }
                completion.resolve(inspection)
            }
        }
    }

    func capture(
        target: AXSelectionTarget,
        requestID: String,
        timeout: TimeInterval = 1.4,
        maximumCharacters: Int =
            BlocksSelectionCaptureProtocol.maximumSelectionCharacters
    ) -> AXSelectionElementReadResult {
        guard let lease = applicationUpdateGate.begin() else { return .failure(.cancelled) }
        defer { lease.release() }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let timeout =
            timeout.isFinite && timeout > 0
            ? timeout
            : 0.01
        var deadline = Date().addingTimeInterval(timeout)
        guard !hasInstallationConflict else {
            Self.logger.error(
                "capture unavailable request=\(requestID, privacy: .public) stage=helper reason=installation_conflict"
            )
            return .failure(.agentInstallationConflict)
        }
        guard let key = keyStore.load() else {
            Self.logger.error(
                "capture unavailable request=\(requestID, privacy: .public) stage=keychain reason=not_paired"
            )
            return .failure(.agentUnavailable)
        }
        let healthResult = health(timeout: 0.15)
        if case .failure(.incompatibleVersion) = healthResult {
            Self.logger.error(
                "capture unavailable request=\(requestID, privacy: .public) stage=health reason=incompatible_version"
            )
            return .failure(.agentVersionOutdated)
        }
        let shouldAutolaunch: Bool
        switch healthResult {
        case .failure(.connectionFailed),
             .failure(.timedOut),
             .failure(.helperNotRunning):
            shouldAutolaunch = true
        default:
            shouldAutolaunch = false
        }
        if shouldAutolaunch,
           applicationLocator.isInstalled,
           applicationLocator.open(activates: false) {
            Self.logger.info(
                "capture autolaunch request=\(requestID, privacy: .public)"
            )
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.1)
                if case .success = health(timeout: 0.12) {
                    deadline = Date().addingTimeInterval(timeout)
                    break
                }
            }
        }
        guard Date() < deadline else {
            return .failure(.timedOut)
        }

        let request = SelectionAgentCaptureRequest(
            requestID: requestID,
            targetProcessIdentifier:
                target.processIdentifier,
            targetBundleIdentifier:
                target.bundleIdentifier,
            mouseScreenPoint:
                target.accessibilityMouseLocation.map {
                    SelectionAgentPoint(
                        x: $0.x,
                        y: $0.y
                    )
                },
            deadline: deadline,
            maximumCharacters: min(
                max(maximumCharacters, 1),
                BlocksSelectionCaptureProtocol
                    .maximumSelectionCharacters
            )
        )
        let result = sendAuthenticated(
            SelectionHelperCommand(
                kind: .capture,
                captureRequest: request
            ),
            keyData: key,
            timeout: max(
                deadline.timeIntervalSinceNow,
                0.01
            )
        )
        guard case let .success(commandResponse) = result,
              let response = commandResponse.captureResponse,
              response.requestID == requestID,
              SelectionAgentPayloadValidator
                .isValid(response) else {
            cancel(requestID: requestID)
            if case .failure(
                SelectionAgentServiceFailure.timedOut
            ) = result {
                Self.logger.error(
                    "capture failed request=\(requestID, privacy: .public) stage=transport reason=timeout duration_ms=\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000), privacy: .public)"
                )
                return .failure(.timedOut)
            }
            Self.logger.error(
                "capture failed request=\(requestID, privacy: .public) stage=transport reason=invalid_response duration_ms=\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000), privacy: .public)"
            )
            return .failure(.agentConnectionFailed)
        }
        if let code = response.failureCode {
            Self.logger.info(
                "capture unavailable request=\(requestID, privacy: .public) code=\(code.rawValue, privacy: .public) duration_ms=\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000), privacy: .public)"
            )
            return .failure(Self.readFailure(for: code))
        }
        guard let selection = response.selection else {
            return .failure(.agentConnectionFailed)
        }
        let snapshot = AXSelectionElementSnapshot(
            role: selection.role,
            subrole: selection.subrole,
            identifier: selection.identifier,
            domIdentifier: selection.domIdentifier,
            chromeNodeIdentifier:
                selection.chromeNodeIdentifier,
            selectedText: selection.text,
            selectedRange: selection.range.map {
                NSRange(
                    location: $0.location,
                    length: $0.length
                )
            },
            captureStrategy: selection.captureStrategy,
            candidateDepth: selection.candidateDepth,
            accessibilityScreenBounds:
                selection.accessibilityScreenBounds.map {
                    CGRect(
                        x: $0.x,
                        y: $0.y,
                        width: $0.width,
                        height: $0.height
                    )
                }
        )
        Self.logger.info(
            "capture succeeded request=\(requestID, privacy: .public) strategy=\(selection.captureStrategy.rawValue, privacy: .public) depth=\(selection.candidateDepth, privacy: .public) chars=\(selection.text.count, privacy: .public) duration_ms=\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000), privacy: .public)"
        )
        return .element(snapshot)
    }

    func permissionStatus(
        timeout: TimeInterval = 0.5
    ) -> Result<Bool, SelectionAgentServiceFailure> {
        booleanCommand(.permissionStatus, timeout: timeout)
    }

    func requestPermission(
        timeout: TimeInterval = 0.8
    ) -> Result<Bool, SelectionAgentServiceFailure> {
        booleanCommand(.requestPermission, timeout: timeout)
    }

    func cancel(
        requestID: String,
        timeout: TimeInterval = 0.2
    ) {
        guard let key = keyStore.load() else { return }
        _ = sendAuthenticated(
            SelectionHelperCommand(
                kind: .cancel,
                cancellationRequestID: requestID
            ),
            keyData: key,
            timeout: timeout
        )
    }

    private func booleanCommand(
        _ kind: SelectionHelperCommandKind,
        timeout: TimeInterval
    ) -> Result<Bool, SelectionAgentServiceFailure> {
        guard let key = keyStore.load() else {
            return .failure(.notPaired)
        }
        return sendAuthenticated(
            SelectionHelperCommand(kind: kind),
            keyData: key,
            timeout: timeout
        ).flatMap { response in
            guard let value = response.booleanValue else {
                return .failure(.invalidResponse)
            }
            return .success(value)
        }
    }

    private func optionalHealth(
        keyData: Data,
        timeout: TimeInterval
    ) -> SelectionHelperHealth? {
        guard timeout > 0,
              case let .success(response) = sendAuthenticated(
                SelectionHelperCommand(kind: .health),
                keyData: keyData,
                timeout: timeout
              ),
              let health = response.health,
              health.protocolVersion >=
                BlocksSelectionHelperProtocol.minimumCompatibleVersion,
              health.protocolVersion <=
                BlocksSelectionHelperProtocol.version else {
            return nil
        }
        return health
    }

    private func beginPasteTargetInspection() -> Bool {
        guard let lease = applicationUpdateGate.begin() else { return false }
        return pasteTargetInspectionLock.withLock {
            guard !pasteTargetInspectionInFlight else { return false }
            pasteTargetInspectionInFlight = true
            pasteTargetInspectionApplicationLease = lease
            return true
        }
    }

    private func endPasteTargetInspection() {
        pasteTargetInspectionLock.withLock {
            pasteTargetInspectionInFlight = false
            pasteTargetInspectionApplicationLease?.release()
            pasteTargetInspectionApplicationLease = nil
        }
    }

    private func sendAuthenticated(
        _ command: SelectionHelperCommand,
        keyData: Data,
        timeout: TimeInterval,
        lifecycleControl: Bool = false
    ) -> Result<
        SelectionHelperCommandResponse,
        SelectionAgentServiceFailure
    > {
        let lease = lifecycleControl ? nil : applicationUpdateGate.begin()
        guard lifecycleControl || lease != nil else { return .failure(.connectionFailed) }
        defer { lease?.release() }
        let requestID =
            command.captureRequest?.requestID
            ?? command.pasteTargetRequest?.requestID
            ?? command.cancellationRequestID
            ?? UUID().uuidString
        do {
            let sealed = try SelectionHelperAuthenticatedCodec
                .seal(
                    command,
                    requestID: requestID,
                    expiresAt: Date().addingTimeInterval(
                        max(timeout, 0.1) + 1
                    ),
                    keyData: keyData
                )
            let payload = try JSONEncoder().encode(sealed)
            let result = connection.send(
                SelectionHelperWirePacket(
                    kind: .authenticated,
                    payload: payload
                ),
                timeout: timeout
            )
            guard case let .success(data) = result,
                  let packet = try? JSONDecoder().decode(
                    SelectionHelperWirePacket.self,
                    from: data
                  ),
                  packet.kind == .authenticated,
                  let responseEnvelope =
                    try? JSONDecoder().decode(
                        SelectionHelperSealedMessage.self,
                        from: packet.payload
                    ),
                  responseEnvelope.requestID == requestID,
                  let response = try?
                    SelectionHelperAuthenticatedCodec.open(
                        SelectionHelperCommandResponse.self,
                        from: responseEnvelope,
                        keyData: keyData
                    ) else {
                return result.map { _ in
                    SelectionHelperCommandResponse(
                        failureCode: "invalid_response"
                    )
                }
            }
            return .success(response)
        } catch {
            Self.logger.error(
                "helper request failed request=\(requestID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return .failure(.invalidResponse)
        }
    }

    private static func readFailure(
        for code: SelectionAgentFailureCode
    ) -> AXSelectionReadFailureReason {
        switch code {
        case .accessibilityPermissionDenied:
            .accessibilityPermissionDenied
        case .targetUnavailable, .targetIdentityChanged:
            .targetExited
        case .focusedElementUnavailable:
            .focusedElementUnavailable
        case .passwordField:
            .passwordField
        case .selectionUnavailable:
            .selectionUnavailable
        case .emptySelection:
            .emptySelection
        case .selectionTooLarge:
            .selectionTooLarge
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        case .invalidRequest, .unauthorizedClient,
             .internalFailure:
            .agentConnectionFailed
        }
    }
}

/// One-shot continuation gate. The timeout path may return the caller while a
/// legacy Keychain/locator/connection implementation is still blocked on the
/// inspection queue, so only the first terminal result is observable.
private final class SelectionHelperPasteTargetInspectionCompletion:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<SelectionHelperPasteTargetInspection?, Never>?

    init(
        continuation: CheckedContinuation<
            SelectionHelperPasteTargetInspection?,
            Never
        >
    ) {
        self.continuation = continuation
    }

    func resolve(_ value: SelectionHelperPasteTargetInspection?) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

private struct SelectionHelperPasteTargetInspectionDeadline {
    private static let maximumTimeout: TimeInterval = 0.15
    private let deadlineUptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let normalized: TimeInterval
        if timeout.isFinite, timeout > 0 {
            normalized = min(timeout, Self.maximumTimeout)
        } else {
            normalized = Self.maximumTimeout
        }
        let durationNanoseconds = UInt64(
            (normalized * 1_000_000_000).rounded(.up)
        )
        deadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ durationNanoseconds
    }

    var hasRemainingTime: Bool {
        DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds
    }

    var remainingTimeInterval: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineUptimeNanoseconds else { return 0 }
        return TimeInterval(deadlineUptimeNanoseconds - now) / 1_000_000_000
    }

    var remainingDuration: DispatchTimeInterval {
        .nanoseconds(Int(remainingTimeInterval * 1_000_000_000))
    }
}

enum SelectionHelperConnectionState: Equatable {
    case checking
    case notInstalled
    case notRunning
    case installationConflict
    case notPaired
    case connecting
    case missingAccessibilityPermission
    case ready(version: String)
    case versionOutdated
    case connectionFailed
}

protocol SelectionHelperDisconnectRecoveryStoring: AnyObject {
    func loadDeadline() -> Date?
    func save(deadline: Date)
    func clear()
}

final class SelectionHelperDisconnectRecoveryStore:
    SelectionHelperDisconnectRecoveryStoring
{
    private let defaults: UserDefaults
    private let key =
        "app.blocks.selectionHelper.disconnectRecoveryDeadline"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDeadline() -> Date? {
        guard let interval = defaults.object(forKey: key) as? TimeInterval,
              interval.isFinite else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func save(deadline: Date) {
        defaults.set(
            deadline.timeIntervalSince1970,
            forKey: key
        )
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
final class SelectionHelperSettingsController:
    ObservableObject
{
    func prepareForApplicationUpdate() async throws { try await client.prepareForApplicationUpdate() }
    func resumeAfterCancelledApplicationUpdate() async {
        await client.resumeAfterCancelledApplicationUpdate()
        if client.hasPendingApplicationUpdateRecovery {
            lastError = helperFailureMessage(.connectionFailed)
        }
    }

    @Published private(set) var state:
        SelectionHelperConnectionState = .checking
    @Published var pairingCode = ""
    @Published private(set) var lastError: String?

    private let client: SelectionHelperClient
    private let disconnectRecoveryStore:
        any SelectionHelperDisconnectRecoveryStoring
    private var generation: UInt64 = 0
    private var pendingDisconnectRecovery = false
    private var disconnectRecoveryExpired = false
    private var disconnectRecoveryDeadline: Date?
    private let permissionAssistPresenter = PermissionAssistPanelPresenter()
    private var permissionMonitorTask: Task<Void, Never>?
    private var permissionHealthCheckInFlight = false
    init(
        client: SelectionHelperClient =
            SelectionHelperClient(),
        disconnectRecoveryStore:
            any SelectionHelperDisconnectRecoveryStoring =
                SelectionHelperDisconnectRecoveryStore()
    ) {
        self.client = client
        self.disconnectRecoveryStore = disconnectRecoveryStore
        if let deadline = disconnectRecoveryStore.loadDeadline() {
            if deadline > Date() {
                pendingDisconnectRecovery = true
                disconnectRecoveryDeadline = deadline
            } else {
                disconnectRecoveryExpired = true
                disconnectRecoveryStore.clear()
            }
        }
    }

    var downloadURL: URL? {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey:
                "BLOCKS_SELECTION_HELPER_DOWNLOAD_URL"
        ) as? String,
              let url = URL(string: raw),
              url.scheme == "https"
                || (
                    url.scheme == "http"
                        && (
                            url.host == "127.0.0.1"
                                || url.host == "localhost"
                        )
                ) else {
            return nil
        }
        return url
    }

    func refresh() {
        guard let lease = client.beginApplicationOperation() else { return }
        generation &+= 1
        let currentGeneration = generation
        lastError = nil
        guard client.isInstalled else {
            state = .notInstalled
            return
        }
        if pendingDisconnectRecovery {
            guard let disconnectRecoveryDeadline,
                  Date() < disconnectRecoveryDeadline else {
                pendingDisconnectRecovery = false
                self.disconnectRecoveryDeadline = nil
                disconnectRecoveryStore.clear()
                state = .notPaired
                lastError = L10n.string(
                    "translation.selectionHelper.error.disconnectRepairRequired"
                )
                return
            }
            state = .checking
            performDisconnect(
                currentGeneration: currentGeneration,
                isRecoveryAttempt: true
            )
            return
        }
        if disconnectRecoveryExpired {
            disconnectRecoveryExpired = false
            state = .notPaired
            lastError = L10n.string(
                "translation.selectionHelper.error.disconnectRepairRequired"
            )
            return
        }
        // A pending disconnect above is authenticated with the existing key
        // and is the only command a Helper's short-lived tombstone accepts.
        // Surface an installation conflict only after those recovery paths,
        // for ordinary health, pairing, and launch work.
        guard !client.hasInstallationConflict else {
            state = .installationConflict
            lastError = helperFailureMessage(.helperInstallationConflict)
            return
        }
        #if !BLOCKS_LOCAL_DEVELOPMENT
        guard client.isPaired else {
            state = .notPaired
            return
        }
        #endif
        state = .checking
        let client = client
        Task.detached(priority: .userInitiated) {
            #if BLOCKS_LOCAL_DEVELOPMENT
            client.associateLocallyIfNeeded(timeout: 0.6)
            #else
            client.health(timeout: 0.6)
            #endif
        }.valueTask(holding: lease) { [weak self] result in
            guard let self,
                  generation == currentGeneration else {
                return
            }
            applyHealthResult(result)
        }
    }

    func openDownloadPage() {
        guard let downloadURL else {
            lastError = L10n.string(
                "translation.selectionHelper.downloadUnavailable"
            )
            return
        }
        NSWorkspace.shared.open(downloadURL)
    }

    func openHelper() {
        guard let lease = client.beginApplicationOperation() else { return }
        guard !client.hasInstallationConflict else {
            state = .installationConflict
            lastError = helperFailureMessage(.helperInstallationConflict)
            return
        }
        guard client.openHelper() else {
            lastError = L10n.string(
                "translation.selectionHelper.openFailed"
            )
            return
        }
        state = client.isPaired ? .connecting : .notPaired
        Task { [weak self] in
            defer { lease.release() }
            try? await Task.sleep(for: .milliseconds(350))
            self?.refresh()
        }
    }

    func pair() {
        guard let lease = client.beginApplicationOperation() else { return }
        let code = pairingCode.filter(\.isNumber)
        guard code.count == 6 else {
            lastError = L10n.string(
                "translation.selectionHelper.codeInvalid"
            )
            return
        }
        generation &+= 1
        let currentGeneration = generation
        state = .connecting
        lastError = nil
        let client = client
        Task.detached(priority: .userInitiated) {
            client.pair(code: code, timeout: 1.2)
        }.valueTask(holding: lease) { [weak self] result in
            guard let self,
                  generation == currentGeneration else {
                return
            }
            if case .success = result {
                pairingCode = ""
            }
            applyHealthResult(result)
        }
    }

    func requestAccessibilityPermission() {
        guard let lease = client.beginApplicationOperation() else { return }
        generation &+= 1
        let currentGeneration = generation
        let client = client
        Task.detached(priority: .userInitiated) {
            client.requestPermission(timeout: 1)
        }.valueTask(holding: lease) { [weak self] _ in
            guard let self,
                  generation == currentGeneration else {
                return
            }
            refresh()
        }
    }

    func openAccessibilitySettings() {
        guard let helperURL = client.trustedApplicationURL else {
            lastError = helperFailureMessage(client.hasInstallationConflict ? .helperInstallationConflict : .helperNotInstalled)
            return
        }
        permissionAssistPresenter.present(
            kind: .accessibility,
            appURL: helperURL,
            targetPermissionGranted: { [weak self] in
                guard let self, case .ready = self.state else { return false }
                return true
            },
            onFlowEnded: { [weak self] in
                self?.permissionMonitorTask?.cancel()
                self?.permissionMonitorTask = nil
                self?.refresh()
            }
        )
        permissionMonitorTask?.cancel()
        permissionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollHelperPermission()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func pollHelperPermission() {
        guard !permissionHealthCheckInFlight,
              let lease = client.beginApplicationOperation() else { return }
        permissionHealthCheckInFlight = true
        let currentGeneration = generation
        let client = client
        Task.detached(priority: .utility) {
            // Read-only authenticated health; never the main App's AX state,
            // and never an implicit auto-pair or accessibility request.
            client.health(timeout: 0.6)
        }.valueTask(holding: lease) { [weak self] result in
            guard let self else { return }
            permissionHealthCheckInFlight = false
            guard generation == currentGeneration else { return }
            applyHealthResult(result)
        }
    }

    deinit { permissionMonitorTask?.cancel() }

    func disconnect() {
        guard let lease = client.beginApplicationOperation() else { return }
        defer { lease.release() }
        generation &+= 1
        let currentGeneration = generation
        pendingDisconnectRecovery = true
        disconnectRecoveryExpired = false
        let deadline = Date().addingTimeInterval(
            BlocksSelectionHelperProtocol
                .disconnectAcknowledgementLifetime
        )
        disconnectRecoveryDeadline = deadline
        disconnectRecoveryStore.save(deadline: deadline)
        state = .checking
        lastError = nil
        performDisconnect(
            currentGeneration: currentGeneration,
            isRecoveryAttempt: false
        )
    }

    private func performDisconnect(
        currentGeneration: UInt64,
        isRecoveryAttempt: Bool
    ) {
        guard let lease = client.beginApplicationOperation() else { return }
        let client = client
        Task.detached(priority: .utility) {
            client.disconnect()
        }.valueTask(holding: lease) { [weak self] result in
            guard let self,
                  generation == currentGeneration else {
                return
            }
            switch result {
            case .success:
                pendingDisconnectRecovery = false
                disconnectRecoveryDeadline = nil
                disconnectRecoveryStore.clear()
                state = client.isInstalled ? .notPaired : .notInstalled
                pairingCode = ""
                lastError = nil
            case .failure:
                // Never infer a remote deletion from a transport failure. A
                // Recheck retries this exact authenticated disconnect while
                // the Helper's short-lived acknowledgement is still valid.
                if isRecoveryAttempt,
                   let disconnectRecoveryDeadline,
                   Date() >= disconnectRecoveryDeadline {
                    pendingDisconnectRecovery = false
                    self.disconnectRecoveryDeadline = nil
                    disconnectRecoveryStore.clear()
                    state = .notPaired
                    lastError = L10n.string(
                        "translation.selectionHelper.error.disconnectRepairRequired"
                    )
                } else {
                    state = .connectionFailed
                    lastError = L10n.string(
                        "translation.selectionHelper.error.disconnectFailed"
                    )
                }
            }
        }
    }

    private func applyHealthResult(
        _ result: Result<
            SelectionHelperHealth,
            SelectionAgentServiceFailure
        >
    ) {
        switch result {
        case let .success(health):
            if health.protocolVersion <
                BlocksSelectionHelperProtocol
                    .minimumCompatibleVersion
                || health.protocolVersion >
                BlocksSelectionHelperProtocol.version {
                state = .versionOutdated
            } else if !health.accessibilityTrusted {
                state = .missingAccessibilityPermission
            } else {
                state = .ready(version: health.helperVersion)
            }
        case let .failure(failure):
            switch failure {
            case .helperNotInstalled:
                state = .notInstalled
            case .helperNotRunning, .connectionFailed,
                 .timedOut:
                state = .notRunning
            case .helperInstallationConflict:
                state = .installationConflict
            case .notPaired, .invalidPairingCode:
                state = .notPaired
            case .incompatibleVersion:
                state = .versionOutdated
            case .invalidResponse, .disconnectNotConfirmed,
                 .bootstrapUnavailable:
                state = .connectionFailed
            }
            lastError = helperFailureMessage(failure)
        }
    }

    private func helperFailureMessage(
        _ failure: SelectionAgentServiceFailure
    ) -> String {
        let suffix: String
        switch failure {
        case .helperNotInstalled:
            suffix = "notInstalled"
        case .helperNotRunning:
            suffix = "notRunning"
        case .helperInstallationConflict:
            suffix = "installationConflict"
        case .notPaired:
            suffix = "notPaired"
        case .invalidPairingCode:
            suffix = "invalidCode"
        case .incompatibleVersion:
            suffix = "outdated"
        case .connectionFailed, .timedOut,
             .invalidResponse, .bootstrapUnavailable:
            suffix = "connectionFailed"
        case .disconnectNotConfirmed:
            suffix = "disconnectFailed"
        }
        return L10n.string(
            "translation.selectionHelper.error.\(suffix)"
        )
    }
}

private extension Task where Success: Sendable, Failure == Never {
    func valueTask(
        holding lease: ApplicationOperationAdmissionGate.Lease? = nil,
        _ completion:
            @escaping @MainActor (Success) -> Void
    ) {
        _Concurrency.Task<Void, Never> { @MainActor in
            defer { lease?.release() }
            completion(await value)
        }
    }
}

protocol SelectionHelperCaptureTransport: Sendable {
    func capture(
        target: AXSelectionTarget,
        requestID: String,
        timeout: TimeInterval,
        maximumCharacters: Int
    ) -> AXSelectionElementReadResult

    func cancel(
        requestID: String,
        timeout: TimeInterval
    )

    func requestPermission(
        timeout: TimeInterval
    ) -> Result<Bool, SelectionAgentServiceFailure>
}

extension SelectionHelperClient:
    SelectionHelperCaptureTransport
{}

/// Starts the Helper request at freeze time and caches exactly one result.
/// Cancellation resolves local readers first, then notifies the Helper from
/// a detached task so UI callers never wait for the local transport.
private final class SelectionHelperCaptureOperation:
    @unchecked Sendable
{
    private let applicationUpdateGate = ApplicationOperationAdmissionGate(name: "Selection Helper capture operation")
    private enum State {
        case pending
        case resolved(AXSelectionElementReadResult)
    }

    private let condition = NSCondition()
    private var state: State = .pending
    private var didStart = false

    func start(
        timeout: TimeInterval,
        capture: @escaping @Sendable ()
            -> AXSelectionElementReadResult,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        let shouldStart = condition.withLock {
            guard !didStart else { return false }
            didStart = true
            return true
        }
        guard shouldStart else { return }
        guard let lease = applicationUpdateGate.begin() else {
            _ = resolve(.failure(.cancelled))
            return
        }
        let boundedTimeout =
            timeout.isFinite && timeout > 0
            ? timeout
            : 0.01
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + boundedTimeout
        ) { [self] in
            guard resolve(.failure(.timedOut)) else {
                return
            }
            let timeoutLease = applicationUpdateGate.begin()
            Task.detached(priority: .utility) {
                defer { timeoutLease?.release() }
                onTimeout()
            }
        }
        Task.detached(priority: .userInitiated) { [self] in
            defer { lease.release() }
            guard isPending else { return }
            let result = capture()
            _ = resolve(result)
        }
    }

    func read() -> AXSelectionElementReadResult {
        condition.lock()
        defer { condition.unlock() }
        while case .pending = state {
            condition.wait()
        }
        guard case let .resolved(result) = state else {
            return .failure(.agentConnectionFailed)
        }
        return result
    }

    func cancel(
        notifyHelper: @escaping @Sendable () -> Void
    ) {
        let shouldNotify = condition.withLock {
            guard case .pending = state else {
                return false
            }
            state = .resolved(.failure(.cancelled))
            condition.broadcast()
            return true
        }
        guard shouldNotify else { return }
        guard let lease = applicationUpdateGate.begin() else { return }
        Task.detached(priority: .utility) {
            defer { lease.release() }
            notifyHelper()
        }
    }

    @discardableResult
    private func resolve(
        _ result: AXSelectionElementReadResult
    ) -> Bool {
        condition.withLock {
            guard case .pending = state else {
                return false
            }
            state = .resolved(result)
            condition.broadcast()
            return true
        }
    }

    private var isPending: Bool {
        condition.withLock {
            guard case .pending = state else {
                return false
            }
            return true
        }
    }
}

private final class BlockingHelperReply<Value>:
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var result:
        Result<Value, SelectionAgentServiceFailure>?

    func resolve(
        _ result: Result<
            Value,
            SelectionAgentServiceFailure
        >
    ) {
        condition.withLock {
            guard self.result == nil else { return }
            self.result = result
            condition.broadcast()
        }
    }

    func wait(
        timeout: TimeInterval
    ) -> Result<Value, SelectionAgentServiceFailure> {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil {
            guard condition.wait(until: deadline) else {
                return .failure(.timedOut)
            }
        }
        return result!
    }
}

struct SelectionHelperAXSelectionSystemClient:
    AXSelectionSystemClient
{
    private let client: any SelectionHelperCaptureTransport
    private let captureTimeout: TimeInterval

    init(
        client: any SelectionHelperCaptureTransport =
            SelectionHelperClient(),
        captureTimeout: TimeInterval = 1.4
    ) {
        self.client = client
        self.captureTimeout =
            captureTimeout.isFinite && captureTimeout > 0
            ? captureTimeout
            : 1.4
    }

    var accessibilityTrusted: Bool {
        false
    }

    var defersAccessibilityTrustEvaluation: Bool {
        true
    }

    func requestAccessibilityPermission() {
        Task.detached(priority: .userInitiated) {
            _ = client.requestPermission(timeout: 0.8)
        }
    }

    func readSelection(
        from target: AXSelectionTarget
    ) -> AXSelectionElementReadResult {
        return client.capture(
            target: target,
            requestID: UUID().uuidString,
            timeout: captureTimeout,
            maximumCharacters:
                BlocksSelectionCaptureProtocol
                    .maximumSelectionCharacters
        )
    }

    func freezeSelection(
        from target: AXSelectionTarget,
        requestID: String
    ) -> AXSelectionElementReadToken? {
        let operation = SelectionHelperCaptureOperation()
        operation.start(
            timeout: captureTimeout,
            capture: {
                client.capture(
                    target: target,
                    requestID: requestID,
                    timeout: captureTimeout,
                    maximumCharacters:
                        BlocksSelectionCaptureProtocol
                            .maximumSelectionCharacters
                )
            },
            onTimeout: {
                client.cancel(
                    requestID: requestID,
                    timeout: min(captureTimeout, 0.2)
                )
            }
        )
        return AXSelectionElementReadToken(
            reader: {
                operation.read()
            },
            canceller: {
                operation.cancel {
                    client.cancel(
                        requestID: requestID,
                        timeout: 0.2
                    )
                }
            }
        )
    }
}
