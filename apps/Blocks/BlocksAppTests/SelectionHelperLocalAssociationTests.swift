import Foundation
import CryptoKit
import Darwin
import Security
import XCTest
#if !SELECTION_HELPER_ASSOCIATION_FIXTURE
@testable import BlocksCore
@testable import Blocks
#endif

#if BLOCKS_LOCAL_DEVELOPMENT
final class SelectionHelperLocalAssociationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func grant(_ authority: inout SelectionHelperLocalAssociation.Authority) throws -> SelectionHelperLocalAssociation.Authorization {
        try XCTUnwrap(authority.issue(requestID: UUID().uuidString,
                                     clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                     generation: 4, isPaired: false, now: now))
    }
    private func request(_ grant: SelectionHelperLocalAssociation.Authorization,
                         requestID: String? = nil, publicKey: Data? = nil) -> SelectionHelperPairRequest {
        .init(requestID: requestID ?? grant.requestID, pairingCode: grant.code,
              clientPublicKey: publicKey ?? grant.clientPublicKey, clientProof: Data())
    }

    func testAuthorizationIsOneUse() throws {
        var authority = SelectionHelperLocalAssociation.Authority()
        let grant = try grant(&authority)
        XCTAssertEqual(grant.bootstrapKey.count, 32)
        XCTAssertEqual(grant.code.count, 6)
        XCTAssertTrue(grant.code.utf8.allSatisfy { (48...57).contains($0) })
        XCTAssertNotNil(authority.consume(request: request(grant), generation: 4, isPaired: false, now: now))
        XCTAssertNil(authority.consume(request: request(grant), generation: 4, isPaired: false, now: now))
    }

    func testAuthorizationCompletesExistingCryptographicPairingContract() throws {
        var authority = SelectionHelperLocalAssociation.Authority()
        let clientPrivateKey = P256.KeyAgreement.PrivateKey()
        let helperPrivateKey = P256.KeyAgreement.PrivateKey()
        let clientPublicKey = clientPrivateKey.publicKey.rawRepresentation
        let helperPublicKey = helperPrivateKey.publicKey.rawRepresentation
        let grant = try XCTUnwrap(authority.issue(requestID: UUID().uuidString, clientPublicKey: clientPublicKey,
                                                 generation: 4, isPaired: false, now: now))
        XCTAssertNil(SelectionHelperPairingAuthentication.clientProof(
            bootstrapKey: grant.bootstrapKey, requestID: grant.requestID,
            pairingCode: UUID().uuidString, clientPublicKey: clientPublicKey
        ), "The existing manual-pairing transcript must not be loosened to accept UUID codes")
        // This is the regression assertion: a UUID code used to make the
        // production clientProof return nil before any pair request was sent.
        let proof = try XCTUnwrap(SelectionHelperPairingAuthentication.clientProof(
            bootstrapKey: grant.bootstrapKey, requestID: grant.requestID,
            pairingCode: grant.code, clientPublicKey: clientPublicKey
        ))
        let pairRequest = SelectionHelperPairRequest(requestID: grant.requestID, pairingCode: grant.code,
                                                     clientPublicKey: clientPublicKey, clientProof: proof)
        let consumed = try XCTUnwrap(authority.consume(request: pairRequest, generation: 4, isPaired: false, now: now))
        XCTAssertTrue(SelectionHelperPairingAuthentication.verifiesClientProof(
            proof, bootstrapKey: consumed.bootstrapKey, request: pairRequest
        ))
        let helperProof = try XCTUnwrap(SelectionHelperPairingAuthentication.helperProof(
            bootstrapKey: consumed.bootstrapKey, request: pairRequest, helperPublicKey: helperPublicKey
        ))
        XCTAssertTrue(SelectionHelperPairingAuthentication.verifiesHelperProof(
            helperProof, bootstrapKey: grant.bootstrapKey, request: pairRequest, helperPublicKey: helperPublicKey
        ))
        let clientKey = try SelectionHelperAuthenticatedCodec.deriveSharedKey(
            privateKey: clientPrivateKey, peerPublicKeyData: helperPublicKey, requestID: grant.requestID
        )
        let helperKey = try SelectionHelperAuthenticatedCodec.deriveSharedKey(
            privateKey: helperPrivateKey, peerPublicKeyData: clientPublicKey, requestID: grant.requestID
        )
        XCTAssertEqual(clientKey, helperKey)
        let sealedHealth = try SelectionHelperAuthenticatedCodec.seal(
            SelectionHelperCommand(kind: .health), requestID: UUID().uuidString,
            expiresAt: now.addingTimeInterval(1), keyData: clientKey
        )
        let healthCommand = try SelectionHelperAuthenticatedCodec.open(
            SelectionHelperCommand.self, from: sealedHealth, keyData: helperKey, now: now
        )
        XCTAssertEqual(healthCommand.kind, .health)
        XCTAssertThrowsError(try SelectionHelperAuthenticatedCodec.open(
            SelectionHelperCommand.self, from: sealedHealth, keyData: Data(repeating: 0, count: 32), now: now
        ))
        XCTAssertNil(authority.consume(request: pairRequest, generation: 4, isPaired: false, now: now))
        // Knowing the short transcript code alone cannot authenticate a peer.
        XCTAssertFalse(SelectionHelperPairingAuthentication.verifiesClientProof(
            proof, bootstrapKey: Data(repeating: 0, count: 32), request: pairRequest
        ))
    }

    func testGrantRejectsDifferentTranscriptAndIsSpent() throws {
        for replaceID in [true, false] {
            var authority = SelectionHelperLocalAssociation.Authority()
            let grant = try grant(&authority)
            let other = request(grant, requestID: replaceID ? UUID().uuidString : nil,
                                publicKey: replaceID ? nil : P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            XCTAssertNil(authority.consume(request: other, generation: 4, isPaired: false, now: now))
            XCTAssertNil(authority.consume(request: request(grant), generation: 4, isPaired: false, now: now))
        }
    }

    func testExpiryGenerationAndExistingPairFailClosed() throws {
        for (generation, paired, time) in [(UInt64(5), false, now), (4, true, now),
                                           (4, false, now.addingTimeInterval(5)),
                                           (4, false, now.addingTimeInterval(-1))] {
            var authority = SelectionHelperLocalAssociation.Authority()
            let grant = try grant(&authority)
            XCTAssertNil(authority.consume(request: request(grant), generation: generation, isPaired: paired, now: time))
        }
    }

    func testCannotIssueForPairedOrMalformedClient() {
        var authority = SelectionHelperLocalAssociation.Authority()
        let publicKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertNil(authority.issue(requestID: UUID().uuidString, clientPublicKey: publicKey,
                                     generation: 0, isPaired: true, now: now))
        XCTAssertNil(authority.issue(requestID: "invalid", clientPublicKey: publicKey,
                                     generation: 0, isPaired: false, now: now))
        XCTAssertNil(authority.issue(requestID: UUID().uuidString, clientPublicKey: Data([0]),
                                     generation: 0, isPaired: false, now: now))
    }

    func testNewGrantInvalidatesPreviousGrant() throws {
        var authority = SelectionHelperLocalAssociation.Authority()
        let first = try grant(&authority)
        _ = try grant(&authority)
        XCTAssertNil(authority.consume(request: request(first), generation: 4, isPaired: false, now: now))
    }

    func testDirectoryRejectsSymlinkAndLoosePermissions() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blocks-association-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try XCTUnwrap(SelectionHelperLocalAssociationTransport.openPrivateDirectory(path: root.path, create: false))
        close(directory)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertNil(SelectionHelperLocalAssociationTransport.openPrivateDirectory(path: root.path, create: false))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertNil(SelectionHelperLocalAssociationTransport.openPrivateDirectory(path: link.path, create: false))
        XCTAssertNil(SelectionHelperLocalAssociationTransport.openPrivateDirectory(path: link.appendingPathComponent("child").path, create: true))
        XCTAssertFalse(BlocksLocalBuildTrust.accepts(connectedSocket: -1, role: "helper"))
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }
        // A same-UID local connection alone does not grant either role.
        XCTAssertFalse(BlocksLocalBuildTrust.accepts(connectedSocket: sockets[0], role: "helper"))
        XCTAssertFalse(BlocksLocalBuildTrust.accepts(connectedSocket: sockets[1], role: "app"))
    }

    #if !SELECTION_HELPER_ASSOCIATION_FIXTURE
    func testUnavailableKeyIsNotReportedAsAnUnpairedInstallation() throws {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecDecode] {
            let store = SelectionHelperSharedKeyStore(itemCopyMatching: { _, _ in status })
            XCTAssertEqual(store.loadForAssociation(), .failure(.keychainUnavailable))
            XCTAssertNil(store.load())
            XCTAssertFalse(store.permitsLocalAssociation())
        }
        let absent = SelectionHelperSharedKeyStore(itemCopyMatching: { _, _ in errSecItemNotFound })
        XCTAssertNil(try absent.loadForAssociation().get())
    }

    func testExistingReadablePairingIsPreserved() throws {
        let key = Data(repeating: 0x37, count: 32)
        var writes = 0
        let store = SelectionHelperSharedKeyStore(itemCopyMatching: { _, result in
            result?.pointee = key as CFData
            return errSecSuccess
        }, itemUpdate: { _, _ in writes += 1; return errSecSuccess },
           itemAdd: { _, _ in writes += 1; return errSecSuccess },
           itemDelete: { _ in writes += 1; return errSecSuccess })
        XCTAssertEqual(try store.loadForAssociation().get(), key)
        XCTAssertFalse(store.permitsLocalAssociation())
        XCTAssertEqual(writes, 0)
    }

    func testKeychainErrorsAreNotTreatedAsAbsence() {
        for status in [errSecSuccess, errSecAuthFailed, errSecInteractionNotAllowed] {
            let store = SelectionHelperSharedKeyStore(itemCopyMatching: { _, _ in status })
            XCTAssertFalse(store.permitsLocalAssociation())
        }
        let absent = SelectionHelperSharedKeyStore(itemCopyMatching: { _, _ in errSecItemNotFound })
        XCTAssertTrue(absent.permitsLocalAssociation())
    }

    func testAutoStorageNeverUpdatesAnExistingEntry() {
        var updates = 0
        var additions = 0
        let store = SelectionHelperSharedKeyStore(itemUpdate: { _, _ in updates += 1; return errSecSuccess },
                                                   itemAdd: { _, _ in additions += 1; return errSecDuplicateItem })
        XCTAssertFalse(store.saveLocalAssociationIfAbsent(Data(repeating: 7, count: 32)))
        XCTAssertEqual(additions, 1)
        XCTAssertEqual(updates, 0)
    }
    #endif
}

#if SELECTION_HELPER_ASSOCIATION_FIXTURE
@main
struct SelectionHelperLocalAssociationFixtureMain {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: SelectionHelperLocalAssociationTests.self)
        suite.run()
        guard let run = suite.testRun, run.executionCount == 7, run.totalFailureCount == 0 else { exit(1) }
        print("SelectionHelperLocalAssociation fixture: 7 tests passed")
    }
}
#endif
#endif

#if !BLOCKS_LOCAL_DEVELOPMENT && !SELECTION_HELPER_ASSOCIATION_FIXTURE
final class SelectionHelperOfficialAssociationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let peer = Data(repeating: 0x11, count: MemoryLayout<audit_token_t>.size)

    func testOfficialGrantRequiresKernelTokenAndIsBoundToProcessIncarnation() throws {
        var authority = SelectionHelperLocalAssociation.Authority()
        let publicKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertNil(authority.issue(requestID: UUID().uuidString, clientPublicKey: publicKey,
                                     generation: 3, isPaired: false, now: now))
        let grant = try XCTUnwrap(authority.issue(requestID: UUID().uuidString, clientPublicKey: publicKey,
                                                  generation: 3, isPaired: false, now: now, peerToken: peer))
        let request = SelectionHelperPairRequest(requestID: grant.requestID, pairingCode: grant.code,
                                                 clientPublicKey: publicKey, clientProof: Data())
        let reusedPID = Data(repeating: 0x22, count: peer.count)
        XCTAssertNil(authority.consume(request: request, generation: 3, isPaired: false, now: now, peerToken: reusedPID))
        XCTAssertNil(authority.consume(request: request, generation: 3, isPaired: false, now: now, peerToken: peer))
    }

    func testOfficialGrantPreservesECDHProofExpiryGenerationAndOneUseContract() throws {
        for rejection in ["none", "expired", "generation", "paired", "request", "public-key"] {
            var authority = SelectionHelperLocalAssociation.Authority()
            let client = P256.KeyAgreement.PrivateKey()
            let grant = try XCTUnwrap(authority.issue(requestID: UUID().uuidString,
                clientPublicKey: client.publicKey.rawRepresentation, generation: 4, isPaired: false, now: now, peerToken: peer))
            let publicKey = rejection == "public-key" ? P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation : grant.clientPublicKey
            let requestID = rejection == "request" ? UUID().uuidString : grant.requestID
            let proof = try XCTUnwrap(SelectionHelperPairingAuthentication.clientProof(bootstrapKey: grant.bootstrapKey,
                requestID: requestID, pairingCode: grant.code, clientPublicKey: publicKey))
            let request = SelectionHelperPairRequest(requestID: requestID, pairingCode: grant.code,
                                                     clientPublicKey: publicKey, clientProof: proof)
            let consumed = authority.consume(request: request, generation: rejection == "generation" ? 5 : 4,
                isPaired: rejection == "paired", now: rejection == "expired" ? now.addingTimeInterval(5) : now, peerToken: peer)
            if rejection == "none" {
                XCTAssertNotNil(consumed)
                XCTAssertTrue(SelectionHelperPairingAuthentication.verifiesClientProof(proof, bootstrapKey: grant.bootstrapKey, request: request))
                let helper = P256.KeyAgreement.PrivateKey()
                let helperProof = try XCTUnwrap(SelectionHelperPairingAuthentication.helperProof(bootstrapKey: grant.bootstrapKey,
                    request: request, helperPublicKey: helper.publicKey.rawRepresentation))
                XCTAssertTrue(SelectionHelperPairingAuthentication.verifiesHelperProof(helperProof, bootstrapKey: grant.bootstrapKey,
                    request: request, helperPublicKey: helper.publicKey.rawRepresentation))
                XCTAssertEqual(try SelectionHelperAuthenticatedCodec.deriveSharedKey(privateKey: client,
                    peerPublicKeyData: helper.publicKey.rawRepresentation, requestID: requestID),
                    try SelectionHelperAuthenticatedCodec.deriveSharedKey(privateKey: helper,
                    peerPublicKeyData: client.publicKey.rawRepresentation, requestID: requestID))
            } else { XCTAssertNil(consumed, rejection) }
            XCTAssertNil(authority.consume(request: request, generation: 4, isPaired: false, now: now, peerToken: peer))
        }
    }

    func testOfficialIdentityPolicyRejectsEmptyTeamWrongRolePathAndHash() {
        typealias Identity = SelectionHelperOfficialAssociationTrust.Identity
        let expected = Identity(identifier: "app.blocks.selection-helper", team: "ABCDEFGHIJ",
                                path: "/fixture/Blocks.app/Contents/Helpers/blocksHelper.app/Contents/MacOS/blocksHelper",
                                cdHash: String(repeating: "a", count: 40))
        XCTAssertTrue(SelectionHelperOfficialAssociationTrust.matches(expected, expected: expected))
        for other in [
            Identity(identifier: expected.identifier, team: "", path: expected.path, cdHash: expected.cdHash),
            Identity(identifier: "app.blocks.dev.selection-helper", team: expected.team, path: expected.path, cdHash: expected.cdHash),
            Identity(identifier: expected.identifier, team: expected.team, path: "/other/blocksHelper", cdHash: expected.cdHash),
            Identity(identifier: expected.identifier, team: expected.team, path: expected.path, cdHash: String(repeating: "b", count: 40)),
        ] { XCTAssertFalse(SelectionHelperOfficialAssociationTrust.matches(other, expected: expected)) }
    }

    func testOfficialAbsenceRequiresActiveLegacyAndDurableMarkerToBeMissing() {
        let fixture = OfficialAssociationKeychainFixture()
        XCTAssertTrue(fixture.store.permitsLocalAssociation())
        for slot in [fixture.active, fixture.legacy, fixture.disabled] {
            fixture.items[slot] = Data()
            XCTAssertFalse(fixture.store.permitsLocalAssociation(), slot)
            fixture.items.removeValue(forKey: slot)
        }
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecDecode] {
            fixture.copyFailure = status
            XCTAssertFalse(fixture.store.permitsLocalAssociation())
            XCTAssertFalse(fixture.store.prepareExplicitLocalAssociation())
        }
        XCTAssertEqual(fixture.adds, 0)
        XCTAssertEqual(fixture.updates, 0)
        XCTAssertEqual(fixture.deletes, 0)
    }

    func testAppPreflightCannotClearMarkerAndHelperClearPreservesLegacyOrCorruptState() {
        let fixture = OfficialAssociationKeychainFixture()
        fixture.items[fixture.disabled] = SelectionHelperLocalAssociation.disabledMarker
        fixture.items[fixture.tombstone] = Data([7])
        XCTAssertFalse(fixture.store.permitsLocalAssociation())
        XCTAssertTrue(fixture.store.prepareExplicitLocalAssociation())
        XCTAssertFalse(fixture.store.permitsLocalAssociation())
        XCTAssertNotNil(fixture.items[fixture.disabled])
        XCTAssertEqual(fixture.deletes, 0)
        XCTAssertTrue(fixture.clearAsHelper())
        XCTAssertTrue(fixture.store.permitsLocalAssociation())
        XCTAssertEqual(fixture.items[fixture.tombstone], Data([7]))
        XCTAssertEqual(fixture.deletes, 1)
        for slot in [fixture.active, fixture.legacy, fixture.disabled] {
            fixture.items[fixture.disabled] = SelectionHelperLocalAssociation.disabledMarker
            fixture.items[slot] = Data()
            XCTAssertFalse(fixture.store.prepareExplicitLocalAssociation(), slot)
            XCTAssertNotNil(fixture.items[fixture.disabled])
            fixture.items.removeValue(forKey: slot)
        }
        XCTAssertEqual(fixture.deletes, 1)
        XCTAssertEqual(fixture.updates, 0)
    }

    func testPersistentOptOutSurvivesAcknowledgementExpiryAndStoreRestart() {
        let fixture = OfficialAssociationKeychainFixture()
        XCTAssertTrue(fixture.persistAsHelper())
        fixture.items[fixture.tombstone] = Data([7])
        fixture.items.removeValue(forKey: fixture.tombstone)
        XCTAssertFalse(fixture.store.permitsLocalAssociation())
        let restarted = fixture.makeStore()
        XCTAssertFalse(restarted.permitsLocalAssociation())
        XCTAssertTrue(restarted.prepareExplicitLocalAssociation())
        XCTAssertFalse(restarted.permitsLocalAssociation())
        XCTAssertTrue(fixture.clearAsHelper())
        XCTAssertTrue(restarted.permitsLocalAssociation())
    }

    func testMarkerWriteOrDeleteFailureNeverClaimsSuccessfulIntentChange() {
        let fixture = OfficialAssociationKeychainFixture()
        fixture.addFailure = errSecInteractionNotAllowed
        XCTAssertFalse(fixture.persistAsHelper())
        fixture.addFailure = nil
        fixture.items[fixture.disabled] = SelectionHelperLocalAssociation.disabledMarker
        fixture.deleteFailure = errSecAuthFailed
        XCTAssertTrue(fixture.store.prepareExplicitLocalAssociation())
        XCTAssertFalse(fixture.clearAsHelper())
        XCTAssertNotNil(fixture.items[fixture.disabled])
        fixture.items[fixture.disabled] = Data([99])
        XCTAssertFalse(fixture.persistAsHelper())
        XCTAssertFalse(fixture.store.prepareExplicitLocalAssociation())
        XCTAssertEqual(fixture.items[fixture.disabled], Data([99]))
    }

    func testOfficialAppCannotCreateOrResurrectSharedActiveKey() {
        let fixture = OfficialAssociationKeychainFixture()
        let original = Data(repeating: 0x37, count: 32)
        XCTAssertFalse(fixture.store.saveLocalAssociationIfAbsent(original))
        XCTAssertNil(fixture.items[fixture.active])
        fixture.items[fixture.active] = original // Helper-owned shared commit.
        XCTAssertFalse(fixture.store.saveLocalAssociationIfAbsent(Data(repeating: 0x44, count: 32)))
        XCTAssertEqual(fixture.items[fixture.active], original)
        XCTAssertEqual(fixture.updates, 0)
        XCTAssertEqual(fixture.deletes, 0)
        XCTAssertEqual(fixture.adds, 0)
        XCTAssertFalse(fixture.store.persistAutomaticAssociationDisabled())
    }

    func testOfficialResetInvalidatesStatusIntentBeforeItCanClearNewMarker() throws {
        let fixture = OfficialAssociationKeychainFixture()
        var authority = SelectionHelperLocalAssociation.Authority()
        let requestID = UUID().uuidString
        let publicKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let intent = try XCTUnwrap(authority.issueIntent(requestID: requestID, clientPublicKey: publicKey,
            generation: 7, isPaired: false, now: now, peerToken: peer))
        // Exact window B: status has replied; Helper reset writes the newer
        // opt-out and invalidates this process-local intent on the same queue.
        authority.invalidate()
        XCTAssertTrue(fixture.persistAsHelper())
        let accepted = authority.consumeIntent(intent, requestID: requestID, clientPublicKey: publicKey,
            generation: 8, isPaired: false, now: now, peerToken: peer)
        if accepted { _ = fixture.clearAsHelper() }
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.items[fixture.disabled], SelectionHelperLocalAssociation.disabledMarker)
        XCTAssertEqual(fixture.deletes, 0)
    }

    func testOfficialIntentIsPeerKeyGenerationAndOneUseBound() throws {
        for reject in ["none", "peer", "key", "generation", "expired"] {
            var authority = SelectionHelperLocalAssociation.Authority()
            let requestID = UUID().uuidString
            let publicKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            let intent = try XCTUnwrap(authority.issueIntent(requestID: requestID, clientPublicKey: publicKey,
                generation: 2, isPaired: false, now: now, peerToken: peer))
            let accepted = authority.consumeIntent(intent, requestID: requestID,
                clientPublicKey: reject == "key" ? Data(repeating: 9, count: 64) : publicKey,
                generation: reject == "generation" ? 3 : 2, isPaired: false,
                now: reject == "expired" ? now.addingTimeInterval(5) : now,
                peerToken: reject == "peer" ? Data(repeating: 9, count: peer.count) : peer)
            XCTAssertEqual(accepted, reject == "none", reject)
            XCTAssertFalse(authority.consumeIntent(intent, requestID: requestID, clientPublicKey: publicKey,
                generation: 2, isPaired: false, now: now, peerToken: peer))
        }
    }
}

private final class OfficialAssociationKeychainFixture {
    var items: [String: Data] = [:]
    var copyFailure: OSStatus?
    var addFailure: OSStatus?
    var deleteFailure: OSStatus?
    var adds = 0
    var updates = 0
    var deletes = 0
    let active = BlocksSelectionHelperProtocol.keychainService + "/" + BlocksSelectionHelperProtocol.keychainAccount
    let legacy = BlocksSelectionHelperProtocol.legacyKeychainService + "/" + BlocksSelectionHelperProtocol.legacyKeychainAccount
    let disabled = SelectionHelperLocalAssociation.disabledKeychainService + "/" + SelectionHelperLocalAssociation.disabledKeychainAccount
    let tombstone = BlocksSelectionHelperProtocol.keychainService + ".disconnect-tombstone/v1"
    lazy var store = makeStore()
    private func slot(_ query: CFDictionary) -> String {
        let values = query as! [String: Any]
        return (values[kSecAttrService as String] as! String) + "/" + (values[kSecAttrAccount as String] as! String)
    }
    private var markerQuery: [String: Any] {
        [kSecAttrService as String: SelectionHelperLocalAssociation.disabledKeychainService,
         kSecAttrAccount as String: SelectionHelperLocalAssociation.disabledKeychainAccount]
    }
    func persistAsHelper() -> Bool {
        SelectionHelperLocalAssociation.persistDisabledMarker(query: markerQuery, copy: copy, add: add)
    }
    func clearAsHelper() -> Bool {
        SelectionHelperLocalAssociation.clearDisabledMarkerForExplicitOptIn(query: markerQuery, copy: copy, delete: delete)
    }
    private func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        if let failure = copyFailure { return failure }
        guard let value = items[slot(query)] else { return errSecItemNotFound }
        result?.pointee = value as CFData
        return errSecSuccess
    }
    private func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        adds += 1
        if let failure = addFailure { return failure }
        let key = slot(query)
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = (query as! [String: Any])[kSecValueData as String] as? Data
        return errSecSuccess
    }
    private func delete(_ query: CFDictionary) -> OSStatus {
        deletes += 1
        if let failure = deleteFailure { return failure }
        return items.removeValue(forKey: slot(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
    func makeStore() -> SelectionHelperSharedKeyStore {
        SelectionHelperSharedKeyStore(accessGroupProvider: { "ABCDEFGHIJ.app.blocks.selection-helper.shared" },
            itemCopyMatching: copy, itemUpdate: { [unowned self] _, _ in
                self.updates += 1
                return errSecAuthFailed
            }, itemAdd: add, itemDelete: delete)
    }
}
#endif
