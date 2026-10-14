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
    var pairCount: Int { lock.withLock { pairs } }
    var healthCount: Int { lock.withLock { healths } }
    var healthKey: Data { lock.withLock { key } }
    var hasConsumedPairingCode: Bool { lock.withLock { consumedPairingCode } }
    var accessibilityTrusted: Bool {
        get { lock.withLock { trusted } }
        set { lock.withLock { trusted = newValue } }
    }
    init(bootstrapKey: Data) { self.bootstrapKey = bootstrapKey }

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
                    guard command.kind == .health else { return .failure(.invalidResponse) }
                    healths += 1
                    let response = SelectionHelperCommandResponse(
                        health: .init(helperVersion: "fixture", accessibilityTrusted: trusted)
                    )
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
        return SelectionHelperSettingsController(
            client: client, disconnectRecoveryStore: SetupRecoveryStore(), permissionGuideOverride: permissionGuide
        )
    }
}
