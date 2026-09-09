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
