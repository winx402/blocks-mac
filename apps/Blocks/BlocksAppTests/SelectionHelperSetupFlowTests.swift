import AppKit
import BlocksCore
import Combine
import CryptoKit
import XCTest
@testable import Blocks

@MainActor
final class SelectionHelperSetupFlowTests: XCTestCase {
    func testSetupStepsDoNotTreatInstallationOrPairingAsReady() {
        XCTAssertEqual(SelectionHelperSetupStep(state: .notRunning, needsPairing: true), .open)
        XCTAssertEqual(SelectionHelperSetupStep(state: .notPaired, needsPairing: true), .pair)
        XCTAssertEqual(SelectionHelperSetupStep(state: .connectionFailed, needsPairing: true), .pair)
        XCTAssertEqual(SelectionHelperSetupStep(state: .connectionFailed, needsPairing: false), .repair)
        XCTAssertEqual(SelectionHelperSetupStep(state: .missingAccessibilityPermission, needsPairing: false), .permission)
        XCTAssertEqual(SelectionHelperSetupStep(state: .ready(version: "fixture"), needsPairing: false), .ready)
        XCTAssertEqual(SelectionHelperSetupStep(state: .installationConflict, needsPairing: true), .conflict)
    }

    func testBootstrapFailureSurvivesTwoPassiveRefreshesAndOnlyAuthenticatedSuccessClearsIt() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        fixture.bootstrap.available = false
        let controller = fixture.controller()
        controller.pairingCode = "123456"
        controller.pair()
        await waitUntil { !controller.isPairing && controller.lastPairingFailure != nil }
        XCTAssertEqual(controller.lastPairingFailure, .bootstrapUnavailable)
        let originalError = controller.lastError
        XCTAssertNotNil(originalError)
        XCTAssertEqual(fixture.connection.pairCount, 0)

        for _ in 0..<2 {
            await passiveRefresh(controller, expected: .notPaired)
            XCTAssertEqual(controller.lastPairingFailure, .bootstrapUnavailable)
            XCTAssertEqual(controller.lastError, originalError)
        }
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.store.deleteCount, 0)

        // Merely possessing a key is not success. It must authenticate health.
        try fixture.store.save(fixture.connection.healthKey)
        XCTAssertEqual(controller.lastPairingFailure, .bootstrapUnavailable)
        await passiveRefresh(controller, expected: .ready(version: "fixture"))
        XCTAssertNil(controller.lastPairingFailure)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(fixture.connection.healthCount, 1)
    }

    func testActiveKeySaveFailureSurvivesTwoRefreshesAndConsumedCodeCannotRecover() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        fixture.store.rejectSaves = true
        let controller = fixture.controller()
        controller.pairingCode = "123456"
        controller.pair()
        await waitUntil { !controller.isPairing && controller.lastPairingFailure != nil }
        XCTAssertEqual(controller.lastPairingFailure, .keychainUnavailable)
        XCTAssertNil(fixture.store.load())
        XCTAssertEqual(fixture.connection.healthCount, 0)
        XCTAssertTrue(fixture.connection.hasConsumedPairingCode)
        let committedHelperKey = fixture.connection.healthKey
        let originalError = controller.lastError
        for _ in 0..<2 {
            await passiveRefresh(controller, expected: .notPaired)
            XCTAssertEqual(controller.lastPairingFailure, .keychainUnavailable)
            XCTAssertEqual(controller.lastError, originalError)
        }

        fixture.store.rejectSaves = false
        // The Helper already committed its side and consumed the code. Fixing
        // local Keychain access does not make a new transcript with that old
        // code valid, and must not silently reset either side.
        controller.pair()
        XCTAssertNil(controller.lastPairingFailure)
        controller.refresh(allowLaunch: false)
        await waitUntil { !controller.isPairing && controller.lastPairingFailure == .invalidPairingCode }
        XCTAssertEqual(controller.state, .notPaired)
        XCTAssertNotNil(controller.lastError)
        let invalidCodeError = controller.lastError
        for _ in 0..<2 {
            await passiveRefresh(controller, expected: .notPaired)
            XCTAssertEqual(controller.lastPairingFailure, .invalidPairingCode)
            XCTAssertEqual(controller.lastError, invalidCodeError)
        }
        XCTAssertEqual(fixture.connection.pairCount, 2)
        XCTAssertEqual(fixture.connection.healthCount, 0)
        XCTAssertEqual(fixture.connection.healthKey, committedHelperKey)
        XCTAssertNil(fixture.store.load())
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.store.deleteCount, 0)
    }

    func testFreshPairAuthenticatesThenGuidesPermissionAndRestoresAfterControllerRestart() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        fixture.connection.accessibilityTrusted = false
        let controller = fixture.controller()
        controller.pairingCode = "123456"
        controller.pair()
        // The same two-second poll must not invalidate the manual operation's
        // generation or discard its completion while pairing is in flight.
        controller.refresh(allowLaunch: false)
        await waitUntil { !controller.isPairing && controller.state == .missingAccessibilityPermission }
        XCTAssertNil(controller.lastError)
        XCTAssertNil(controller.lastPairingFailure)
        XCTAssertEqual(controller.pairingCode, "")
        XCTAssertNotNil(fixture.store.load())
        XCTAssertTrue(fixture.connection.hasConsumedPairingCode)
        XCTAssertEqual(fixture.connection.pairCount, 1)

        var guideTargets: [URL] = []
        let permissionController = fixture.controller { guideTargets.append($0) }
        permissionController.requestAccessibilityPermission()
        XCTAssertEqual(guideTargets, [fixture.helperURL])

        fixture.connection.accessibilityTrusted = true
        await passiveRefresh(controller, expected: .ready(version: "fixture"))
        // Recreating the controller preserves the paired key; it still checks
        // authenticated health before exposing ready.
        let restarted = fixture.controller()
        XCTAssertEqual(restarted.state, .checking)
        await passiveRefresh(restarted, expected: .ready(version: "fixture"))
        XCTAssertEqual(fixture.connection.pairCount, 1)
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.store.deleteCount, 0)
    }

    func testNewManualPairReplacesTheRetainedFailureWithoutLaunchingHelper() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        fixture.bootstrap.available = false
        let controller = fixture.controller()
        controller.pairingCode = "123456"
        controller.pair()
        await waitUntil { controller.lastPairingFailure == .bootstrapUnavailable }
        controller.pairingCode = "12"
        controller.pair()
        XCTAssertEqual(controller.lastPairingFailure, .invalidPairingCode)
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.connection.pairCount, 0)
    }

    #if DEBUG && !BLOCKS_LOCAL_DEVELOPMENT
    func testOfficialPassiveRefreshAndColdStartNeverRequestFirstAssociation() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        let controller = fixture.controllerWithAssociation(configureClient: { client in
            client.setLocalAssociationSendForTesting(peer.send)
        })
        controller.startApplicationLaunchRecovery(runtimeServicesEnabled: true)
        await waitUntil { controller.state == .notPaired }
        await passiveRefresh(controller, expected: .notPaired)
        await passiveRefresh(controller, expected: .notPaired)
        XCTAssertTrue(peer.requestKinds.isEmpty)
        XCTAssertEqual(fixture.store.explicitOptInCount, 0)
        XCTAssertEqual(fixture.store.automaticSaveCount, 0)
        XCTAssertEqual(fixture.launchCount, 0)
    }

    func testOfficialExplicitOptInUsesExistingCryptoWithoutManualCodeAndKeepsAXSeparate() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        fixture.connection.accessibilityTrusted = false
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        let controller = fixture.controllerWithAssociation(configureClient: { client in
            client.setLocalAssociationSendForTesting(peer.send)
        })
        controller.connectAfterExplicitOptIn()
        controller.refresh(allowLaunch: false)
        await waitUntil { !controller.isPairing && controller.state == .missingAccessibilityPermission }
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(fixture.connection.pairCount, 0)
        XCTAssertEqual(fixture.store.explicitOptInCount, 1)
        XCTAssertEqual(fixture.store.automaticSaveCount, 0)
        XCTAssertEqual(fixture.store.helperCommitCount, 1)
        XCTAssertEqual(peer.requestKinds.filter { $0 == .authorize }.count, 1)
        XCTAssertEqual(peer.requestKinds.filter { $0 == .pair }.count, 1)
        let originalKey = fixture.store.load()
        let originalRequestCount = peer.requestKinds.count
        fixture.connection.accessibilityTrusted = true
        await passiveRefresh(controller, expected: .ready(version: "fixture"))
        let restarted = fixture.controllerWithAssociation(configureClient: { client in client.setLocalAssociationSendForTesting(peer.send) })
        await passiveRefresh(restarted, expected: .ready(version: "fixture"))
        XCTAssertEqual(peer.requestKinds.count, originalRequestCount)
        XCTAssertEqual(fixture.store.load(), originalKey)
        XCTAssertEqual(fixture.store.deleteCount, 0)
    }

    func testOfficialExistingKeyOnlyAuthenticatesHealthEvenOnExplicitConnect() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        try fixture.store.save(fixture.connection.healthKey)
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        let controller = fixture.controllerWithAssociation(configureClient: { client in client.setLocalAssociationSendForTesting(peer.send) })
        controller.connectAfterExplicitOptIn()
        await waitUntil { !controller.isPairing && controller.state == .ready(version: "fixture") }
        XCTAssertTrue(peer.requestKinds.isEmpty)
        XCTAssertEqual(fixture.store.explicitOptInCount, 0)
        XCTAssertEqual(fixture.store.automaticSaveCount, 0)
        XCTAssertEqual(fixture.store.deleteCount, 0)
    }

    func testOfficialDisconnectMarkerFailurePreservesPairingAndReportsFailure() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        let original = fixture.connection.healthKey
        try fixture.store.save(original)
        fixture.store.rejectMarkerWrites = true
        let controller = fixture.controller()
        controller.disconnect()
        await waitUntil { controller.state == .connectionFailed }
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(fixture.store.load(), original)
        XCTAssertEqual(fixture.store.deleteCount, 0)
    }

    func testOfficialPersistentOptOutNeedsANewExplicitActionAfterControllerRestart() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        XCTAssertTrue(fixture.store.persistAutomaticAssociationDisabled())
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        let restarted = fixture.controllerWithAssociation(configureClient: { client in client.setLocalAssociationSendForTesting(peer.send) })
        await passiveRefresh(restarted, expected: .notPaired)
        XCTAssertTrue(peer.requestKinds.isEmpty)
        XCTAssertTrue(fixture.store.isAutomaticAssociationDisabled)
        restarted.connectAfterExplicitOptIn()
        await waitUntil { !restarted.isPairing && restarted.state == .ready(version: "fixture") }
        XCTAssertFalse(fixture.store.isAutomaticAssociationDisabled)
        XCTAssertEqual(fixture.store.explicitOptInCount, 1)
    }

    func testOfficialDelayedPairReplyCannotResurrectKeyAfterHelperReset() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        peer.resetBeforePairReply = true
        let controller = fixture.controllerWithAssociation(configureClient: { $0.setLocalAssociationSendForTesting(peer.send) })
        controller.connectAfterExplicitOptIn()
        await waitUntil { !controller.isPairing && controller.lastPairingFailure != nil }
        XCTAssertEqual(controller.lastPairingFailure, .notPaired)
        XCTAssertNil(fixture.store.load())
        XCTAssertTrue(fixture.store.isAutomaticAssociationDisabled)
        XCTAssertEqual(fixture.store.helperCommitCount, 1)
        XCTAssertEqual(fixture.store.automaticSaveCount, 0)
    }

    func testOfficialResetAfterStatusRejectsOldIntentWithoutClearingMarker() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        peer.resetAfterIntentStatus = true
        let controller = fixture.controllerWithAssociation(configureClient: { $0.setLocalAssociationSendForTesting(peer.send) })
        controller.connectAfterExplicitOptIn()
        await waitUntil { !controller.isPairing && controller.lastPairingFailure != nil }
        XCTAssertEqual(controller.lastPairingFailure, .bootstrapUnavailable)
        XCTAssertNil(fixture.store.load())
        XCTAssertTrue(fixture.store.isAutomaticAssociationDisabled)
        XCTAssertEqual(fixture.store.explicitOptInCount, 0)
        XCTAssertEqual(fixture.store.helperCommitCount, 0)
        XCTAssertFalse(peer.requestKinds.contains(.pair))
    }

    func testOfficialDisconnectDuringConnectReadinessCannotBeUndoneByOlderConnect() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        let peer = AutomaticSetupAssociationPeer(connection: fixture.connection)
        let entered = expectation(description: "connect entered read-only readiness")
        let release = DispatchSemaphore(value: 0)
        peer.onReadinessStatus = { entered.fulfill(); _ = release.wait(timeout: .now() + 2) }
        var captured: SelectionHelperClient?
        _ = fixture.controllerWithAssociation(configureClient: { client in
            captured = client
            client.setLocalAssociationSendForTesting(peer.send)
        })
        let client = try XCTUnwrap(captured)
        let connecting = Task.detached { client.connectAfterExplicitOptIn() }
        await fulfillment(of: [entered], timeout: 1)
        let disconnectStarted = expectation(description: "disconnect task started")
        let disconnectFinished = SetupThreadFlag()
        let disconnecting = Task.detached {
            disconnectStarted.fulfill()
            let result = client.disconnect()
            disconnectFinished.set()
            return result
        }
        await fulfillment(of: [disconnectStarted], timeout: 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(disconnectFinished.value)
        release.signal()
        _ = await connecting.value
        let disconnectResult = await disconnecting.value
        XCTAssertNoThrow(try disconnectResult.get())
        XCTAssertNil(fixture.store.load())
        XCTAssertTrue(fixture.store.isAutomaticAssociationDisabled)
        XCTAssertEqual(fixture.store.automaticSaveCount, 0)
    }

    func testOfficialLateDisconnectAcknowledgementCannotDeleteNewHelperPairing() async throws {
        let fixture = try SetupFixture()
        defer { fixture.remove() }
        try fixture.store.save(fixture.connection.healthKey)
        let store = fixture.store
        let replacement = Data(repeating: 0x72, count: 32)
        fixture.connection.onDisconnectResponse = {
            _ = store.helperPrepareExplicitAssociation()
            _ = store.helperCommit(replacement)
        }
        var captured: SelectionHelperClient?
        _ = fixture.controllerWithAssociation(configureClient: { captured = $0 })
        XCTAssertNoThrow(try XCTUnwrap(captured).disconnect().get())
        XCTAssertEqual(store.load(), replacement)
        XCTAssertEqual(store.deleteCount, 0)
    }
    #endif

    private func passiveRefresh(_ controller: SelectionHelperSettingsController,
                                expected: SelectionHelperConnectionState) async {
        var didReceiveResult = false
        let observation = controller.$state.dropFirst().sink { state in
            if state == expected { didReceiveResult = true }
        }
        controller.refresh(allowLaunch: false)
        await waitUntil { didReceiveResult }
        withExtendedLifetime(observation) {}
        XCTAssertEqual(controller.state, expected)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for setup operation")
    }
}

private final class SetupKeyStore: SelectionHelperSharedKeyStoring {
    private let lock = NSLock()
    private var key: Data?
    private var rejects = false
    private var deletes = 0
    private var disabled = false
    private var optedIn = false
    private var optIns = 0
    private var automaticSaves = 0
    private var helperCommits = 0
    private var markerRejects = false
    var rejectMarkerWrites: Bool {
        get { lock.withLock { markerRejects } }
        set { lock.withLock { markerRejects = newValue } }
    }
    var explicitOptInCount: Int { lock.withLock { optIns } }
    var automaticSaveCount: Int { lock.withLock { automaticSaves } }
    var helperCommitCount: Int { lock.withLock { helperCommits } }
    var isAutomaticAssociationDisabled: Bool { lock.withLock { disabled } }
    var rejectSaves: Bool {
        get { lock.withLock { rejects } }
        set { lock.withLock { rejects = newValue } }
    }
    var deleteCount: Int { lock.withLock { deletes } }
    func load() -> Data? { lock.withLock { key } }
    func save(_ data: Data) throws {
        try lock.withLock {
            if rejects { throw SelectionAgentServiceFailure.keychainUnavailable }
            key = data
        }
    }
    func delete() { lock.withLock { key = nil; deletes += 1 } }
    func permitsLocalAssociation() -> Bool { lock.withLock { optedIn && key == nil && !disabled } }
    func prepareExplicitLocalAssociation() -> Bool {
        lock.withLock { key == nil }
    }
    func helperPrepareExplicitAssociation() -> Bool {
        lock.withLock {
            guard key == nil else { return false }
            optIns += 1
            optedIn = true
            disabled = false
            return true
        }
    }
    func helperCommit(_ data: Data) -> Bool {
        lock.withLock {
            guard key == nil, !disabled, !rejects else { return false }
            key = data
            helperCommits += 1
            return true
        }
    }
    func helperReset() {
        lock.withLock { disabled = true; optedIn = false; key = nil }
    }
    func persistAutomaticAssociationDisabled() -> Bool {
        lock.withLock {
            guard !markerRejects else { return false }
            disabled = true
            optedIn = false
            return true
        }
    }
    func saveLocalAssociationIfAbsent(_ data: Data) -> Bool {
        lock.withLock {
            guard !rejects, key == nil, data.count == 32 else { return false }
            key = data
            automaticSaves += 1
            return true
        }
    }
}

private final class SetupBootstrapStore: SelectionHelperBootstrapKeyCreating {
    let key = Data(repeating: 0x37, count: 32)
    private let lock = NSLock()
    private var isAvailable = true
    var available: Bool {
        get { lock.withLock { isAvailable } }
        set { lock.withLock { isAvailable = newValue } }
    }
    func load() -> Data? { available ? key : nil }
    func createOrLoad() -> Data? { load() }
}

private final class SetupConnection: SelectionHelperLoopbackConnecting {
    private let lock = NSLock()
    private let bootstrapKey: Data
    private var key = Data(repeating: 0x54, count: 32)
    private var pairs = 0
    private var healths = 0
    private var trusted = true
    private var consumedPairingCode = false
    weak var sharedStore: SetupKeyStore?
    var onDisconnectResponse: (() -> Void)?
    var pairCount: Int { lock.withLock { pairs } }
    var healthCount: Int { lock.withLock { healths } }
    var healthKey: Data { lock.withLock { key } }
    var hasConsumedPairingCode: Bool { lock.withLock { consumedPairingCode } }
    var accessibilityTrusted: Bool {
        get { lock.withLock { trusted } }
        set { lock.withLock { trusted = newValue } }
    }
    init(bootstrapKey: Data) { self.bootstrapKey = bootstrapKey }
    func adoptAssociationKey(_ value: Data) { lock.withLock { key = value } }

    func send(_ packet: SelectionHelperWirePacket, timeout: TimeInterval) -> Result<Data, SelectionAgentServiceFailure> {
        lock.withLock {
            do {
                let responsePacket: SelectionHelperWirePacket
                if packet.kind == .pair {
                    pairs += 1
                    let request = try JSONDecoder().decode(SelectionHelperPairRequest.self, from: packet.payload)
                    guard !consumedPairingCode, request.pairingCode == "123456" else {
                        let response = SelectionHelperPairResponse(
                            requestID: request.requestID, helperPublicKey: nil, helperProof: nil,
                            failureCode: "invalid_pairing_code"
                        )
                        let rejection = SelectionHelperWirePacket(
                            kind: .pair, payload: try JSONEncoder().encode(response)
                        )
                        return .success(try JSONEncoder().encode(rejection))
                    }
                    let privateKey = P256.KeyAgreement.PrivateKey()
                    let publicKey = privateKey.publicKey.rawRepresentation
                    key = try SelectionHelperAuthenticatedCodec.deriveSharedKey(
                        privateKey: privateKey, peerPublicKeyData: request.clientPublicKey,
                        requestID: request.requestID
                    )
                    let proof = SelectionHelperPairingAuthentication.helperProof(
                        bootstrapKey: bootstrapKey, request: request, helperPublicKey: publicKey
                    )
                    let response = SelectionHelperPairResponse(
                        requestID: request.requestID, helperPublicKey: publicKey, helperProof: proof,
                        failureCode: nil
                    )
                    responsePacket = .init(kind: .pair, payload: try JSONEncoder().encode(response))
                    // Model the server-side commit independently of whether
                    // the main App subsequently saves its active key.
                    consumedPairingCode = true
                } else if packet.kind == .authenticated {
                    let envelope = try JSONDecoder().decode(SelectionHelperSealedMessage.self, from: packet.payload)
                    let command = try SelectionHelperAuthenticatedCodec.open(
                        SelectionHelperCommand.self, from: envelope, keyData: key
                    )
                    let response: SelectionHelperCommandResponse
                    if command.kind == .disconnect, let store = sharedStore {
                        let disabled = store.persistAutomaticAssociationDisabled()
                        if disabled { store.helperReset(); onDisconnectResponse?() }
                        response = .init(booleanValue: disabled)
                    } else {
                        guard command.kind == .health, sharedStore?.isAutomaticAssociationDisabled != true else { return .failure(.invalidResponse) }
                        healths += 1
                        response = .init(health: .init(helperVersion: "fixture", accessibilityTrusted: trusted))
                    }
                    let sealed = try SelectionHelperAuthenticatedCodec.seal(
                        response, requestID: envelope.requestID,
                        expiresAt: Date().addingTimeInterval(1), keyData: key
                    )
                    responsePacket = .init(kind: .authenticated, payload: try JSONEncoder().encode(sealed))
                } else { return .failure(.invalidResponse) }
                return .success(try JSONEncoder().encode(responsePacket))
            } catch { return .failure(.invalidResponse) }
        }
    }
}

private struct SetupIdentityVerifier: SelectionHelperBundleIdentityVerifying {
    func verifiedIdentity(for applicationURL: URL) -> SelectionHelperBundleIdentity? {
        .init(teamID: "SETUPTEST", signingIdentifier: BlocksSelectionHelperProtocol.bundleIdentifier)
    }
}

private final class SetupRecoveryStore: SelectionHelperDisconnectRecoveryStoring {
    func loadDeadline() -> Date? { nil }
    func save(deadline: Date) {}
    func clear() {}
}

@MainActor
private final class SetupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SetupKeyStore()
    let bootstrap = SetupBootstrapStore()
    let connection: SetupConnection
    private let launchLock = NSLock()
    private var launches = 0
    var launchCount: Int { launchLock.withLock { launches } }
    var helperURL: URL { root.appendingPathComponent("Blocks Selection Helper.app") }

    init() throws {
        connection = SetupConnection(bootstrapKey: bootstrap.key)
        connection.sharedStore = store
        let contents = helperURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": BlocksSelectionHelperProtocol.bundleIdentifier,
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Blocks Selection Helper"
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func controller(permissionGuide: ((URL) -> Void)? = nil) -> SelectionHelperSettingsController {
        controllerWithAssociation(permissionGuide: permissionGuide)
    }
    func controllerWithAssociation(permissionGuide: ((URL) -> Void)? = nil,
                                   configureClient: ((SelectionHelperClient) -> Void)? = nil) -> SelectionHelperSettingsController {
        let helper = helperURL
        let client = SelectionHelperClient(
            keyStore: store, bootstrapKeyStore: bootstrap, connection: connection,
            applicationLocator: SelectionHelperApplicationLocator(
                candidateURLsProvider: { [helper] }, runningApplicationURLsProvider: { [helper] },
                openApplication: { [weak self] _, _ in self?.launchLock.withLock { self?.launches += 1 } },
                allowedApplicationURLsProvider: { [helper] }, identityVerifier: SetupIdentityVerifier(),
                trustedHostTeamIdentifierProvider: { "SETUPTEST" }
            )
        )
        configureClient?(client)
        return SelectionHelperSettingsController(
            client: client, disconnectRecoveryStore: SetupRecoveryStore(), permissionGuideOverride: permissionGuide
        )
    }
}

#if DEBUG && !BLOCKS_LOCAL_DEVELOPMENT
private final class SetupThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class AutomaticSetupAssociationPeer {
    private let lock = NSLock()
    private let connection: SetupConnection
    private let store: SetupKeyStore
    private var authority = SelectionHelperLocalAssociation.Authority()
    private var kinds: [SelectionHelperLocalAssociation.Request.Kind] = []
    private var committed = false
    private var generation: UInt64 = 0
    var resetBeforePairReply = false
    var resetAfterIntentStatus = false
    var onReadinessStatus: (() -> Void)?
    private let token = Data(repeating: 0x11, count: 32)
    var requestKinds: [SelectionHelperLocalAssociation.Request.Kind] { lock.withLock { kinds } }
    init(connection: SetupConnection) { self.connection = connection; store = connection.sharedStore! }
    private func resetOnHelperQueue() {
        authority.invalidate()
        generation &+= 1
        store.helperReset()
        committed = false
    }
    func send(_ request: SelectionHelperLocalAssociation.Request, _ timeout: TimeInterval) -> SelectionHelperLocalAssociation.Response? {
        if request.kind == .status, request.clientPublicKey == nil { onReadinessStatus?() }
        return lock.withLock {
            kinds.append(request.kind)
            switch request.kind {
            case .status:
                guard let publicKey = request.clientPublicKey else { return .init(isPaired: committed) }
                let intent = authority.issueIntent(requestID: request.requestID, clientPublicKey: publicKey,
                    generation: generation, isPaired: committed, now: Date(), peerToken: token)
                if resetAfterIntentStatus { resetOnHelperQueue() }
                return .init(isPaired: false, intent: intent)
            case .authorize:
                guard let publicKey = request.clientPublicKey, let intent = request.intent,
                      authority.consumeIntent(intent, requestID: request.requestID, clientPublicKey: publicKey,
                        generation: generation, isPaired: committed, now: Date(), peerToken: token),
                      store.helperPrepareExplicitAssociation(),
                      let grant = authority.issue(requestID: request.requestID, clientPublicKey: publicKey,
                        generation: generation, isPaired: committed, now: Date(), peerToken: token) else { return nil }
                return .init(isPaired: false, authorization: grant)
            case .pair:
                guard let pair = request.pairRequest,
                      let grant = authority.consume(request: pair, generation: generation, isPaired: committed, now: Date(), peerToken: token),
                      SelectionHelperPairingAuthentication.verifiesClientProof(pair.clientProof, bootstrapKey: grant.bootstrapKey, request: pair) else { return nil }
                let helper = P256.KeyAgreement.PrivateKey()
                guard let key = try? SelectionHelperAuthenticatedCodec.deriveSharedKey(privateKey: helper,
                    peerPublicKeyData: pair.clientPublicKey, requestID: pair.requestID),
                    let proof = SelectionHelperPairingAuthentication.helperProof(bootstrapKey: grant.bootstrapKey,
                        request: pair, helperPublicKey: helper.publicKey.rawRepresentation),
                    let payload = try? JSONEncoder().encode(SelectionHelperPairResponse(requestID: pair.requestID,
                        helperPublicKey: helper.publicKey.rawRepresentation, helperProof: proof, failureCode: nil)),
                    let packet = try? JSONEncoder().encode(SelectionHelperWirePacket(kind: .pair, payload: payload)) else { return nil }
                guard store.helperCommit(key) else { return nil }
                committed = true
                connection.adoptAssociationKey(key)
                if resetBeforePairReply { resetOnHelperQueue() }
                return .init(isPaired: true, pairPacket: packet)
            case .disable:
                authority.invalidate()
                generation &+= 1
                let disabled = store.persistAutomaticAssociationDisabled()
                return .init(isPaired: store.load() != nil, automaticAssociationDisabled: disabled)
            }
        }
    }
}
#endif
