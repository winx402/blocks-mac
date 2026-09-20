import Foundation
import Darwin
import XCTest
#if !SOURCE_UPGRADE_FIXTURE
@testable import BlocksCore
#endif

final class SourceUpgradeProtocolTests: XCTestCase {
    func testResponseRequiresMatchingVersionTokenAndOperation() {
        let token = UUID()
        let request = SourceUpgradeProtocol.Request(token: token, operation: .prepare)
        XCTAssertTrue(SourceUpgradeProtocol.Response(token: token, status: .prepared).matches(request))
        XCTAssertFalse(SourceUpgradeProtocol.Response(token: UUID(), status: .prepared).matches(request))
        XCTAssertFalse(SourceUpgradeProtocol.Response(version: 2, token: token, status: .prepared).matches(request))
        XCTAssertFalse(SourceUpgradeProtocol.Response(token: token, status: .committed).matches(request))
        XCTAssertFalse(SourceUpgradeProtocol.Response(token: token, status: .prepared, errorCode: "busy").matches(request))
        XCTAssertTrue(SourceUpgradeProtocol.Response(token: token, status: .failed, errorCode: "busy").matches(request))
        XCTAssertFalse(SourceUpgradeProtocol.Response(token: token, status: .failed).matches(request))
        XCTAssertFalse(SourceUpgradeProtocol.Response(token: token, status: .failed, errorCode: "/private/path").matches(request))
    }

    func testWireVocabularyIsFixedAndCarriesNoContent() throws {
        let token = UUID()
        for operation in [SourceUpgradeProtocol.Request.Operation.probe, .prepare, .commit, .cancel] {
            let data = try JSONEncoder().encode(SourceUpgradeProtocol.Request(token: token, operation: operation))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["version", "token", "operation"])
            XCTAssertEqual(object["version"] as? Int, 1)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SourceUpgradeProtocol.Request.self,
            from: Data("{\"version\":1,\"token\":\"\(token)\",\"operation\":\"run\"}".utf8)))
    }

    func testBuildCapabilityIsCompileTimeOnly() {
        #if BLOCKS_LOCAL_DEVELOPMENT
        XCTAssertTrue(SourceUpgradeProtocol.isAvailable)
        #else
        XCTAssertFalse(SourceUpgradeProtocol.isAvailable)
        #endif
    }

    #if BLOCKS_LOCAL_DEVELOPMENT
    private func sockets() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        XCTAssertTrue(SourceUpgradeTransport.configure(descriptors[0]))
        XCTAssertTrue(SourceUpgradeTransport.configure(descriptors[1]))
        return descriptors
    }
    private var deadline: TimeInterval { ProcessInfo.processInfo.systemUptime + 0.25 }

    func testFrameRoundTripAndTruncatedEOF() throws {
        let pair = try sockets()
        defer { pair.forEach { close($0) } }
        let payload = Data("{\"version\":1}".utf8)
        XCTAssertTrue(SourceUpgradeTransport.writeFrame(payload, descriptor: pair[0], deadline: deadline))
        XCTAssertEqual(SourceUpgradeTransport.readFrame(descriptor: pair[1], deadline: deadline), payload)
        let partial = Array("{\"version\":".utf8)
        XCTAssertEqual(partial.withUnsafeBytes { write(pair[0], $0.baseAddress, $0.count) }, partial.count)
        shutdown(pair[0], SHUT_WR)
        XCTAssertNil(SourceUpgradeTransport.readFrame(descriptor: pair[1], deadline: deadline))
    }

    func testFrameLimitsAndBoundedRead() throws {
        let pair = try sockets()
        defer { pair.forEach { close($0) } }
        XCTAssertFalse(SourceUpgradeTransport.writeFrame(Data(), descriptor: pair[0], deadline: deadline))
        XCTAssertFalse(SourceUpgradeTransport.writeFrame(Data("bad\nframe".utf8), descriptor: pair[0], deadline: deadline))
        XCTAssertFalse(SourceUpgradeTransport.writeFrame(Data(repeating: 65, count: 4_097), descriptor: pair[0], deadline: deadline))
        let oversized = Data(repeating: 65, count: 4_097) + Data([0x0A])
        XCTAssertEqual(oversized.withUnsafeBytes { write(pair[0], $0.baseAddress, $0.count) }, oversized.count)
        XCTAssertNil(SourceUpgradeTransport.readFrame(descriptor: pair[1], deadline: deadline))
        // The rejected oversized frame leaves one newline, which is also rejected.
        XCTAssertNil(SourceUpgradeTransport.readFrame(descriptor: pair[1], deadline: deadline))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(SourceUpgradeTransport.readFrame(descriptor: pair[1], deadline: start + 0.03))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testPollSliceExpiryDoesNotShortenTransactionDeadline() throws {
        let pair = try sockets()
        defer { pair.forEach { close($0) } }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(SourceUpgradeTransport.wait(pair[1], event: Int16(POLLIN),
            deadline: start + 0.05, maximumPollMilliseconds: 5))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.045)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testNoSIGPIPEAndSameUIDIsNotAuthentication() throws {
        let pair = try sockets()
        defer { pair.forEach { close($0) } }
        XCTAssertFalse(BlocksLocalBuildTrust.accepts(connectedSocket: pair[0], role: "app"))
        XCTAssertFalse(BlocksLocalBuildTrust.accepts(connectedSocket: pair[1], role: "cli"))
        shutdown(pair[1], SHUT_RDWR)
        XCTAssertFalse(SourceUpgradeTransport.writeFrame(Data("x".utf8), descriptor: pair[0], deadline: deadline))
        XCTAssertNotEqual(fcntl(pair[0], F_GETFD) & FD_CLOEXEC, 0)
    }

    func testDirectoryRejectsSymlinksAndPublicPermissions() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blocks-upgrade-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try XCTUnwrap(SourceUpgradeTransport.openPrivateDirectory(path: root.path, create: false))
        close(directory)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertNil(SourceUpgradeTransport.openPrivateDirectory(path: root.path, create: false))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertNil(SourceUpgradeTransport.openPrivateDirectory(path: link.path, create: false))
        XCTAssertNil(SourceUpgradeTransport.openPrivateDirectory(path: link.appendingPathComponent("child").path, create: true))
    }

    #if SOURCE_UPGRADE_FIXTURE
    func testServerBindsPrivateEndpointAndReleasesLockAfterStop() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blocks-upgrade-server-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SourceUpgradeTransport.Server(directoryPathForTesting: root.path)
        let second = SourceUpgradeTransport.Server(directoryPathForTesting: root.path)
        let handler: SourceUpgradeTransport.Server.Handler = { _, _, _ in XCTFail("Untrusted peers must not call handler") }
        XCTAssertTrue(first.start(handler: handler, didCommit: { _, _ in }, disconnected: { _ in }))
        XCTAssertFalse(first.start(handler: handler, didCommit: { _, _ in }, disconnected: { _ in }))
        XCTAssertFalse(second.start(handler: handler, didCommit: { _, _ in }, disconnected: { _ in }))
        var info = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("upgrade.sock").path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(root.appendingPathComponent("listener.lock").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let before = ProcessInfo.processInfo.systemUptime
        first.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 0.1)
        let timeout = ProcessInfo.processInfo.systemUptime + 1
        while FileManager.default.fileExists(atPath: root.appendingPathComponent("upgrade.sock").path),
              ProcessInfo.processInfo.systemUptime < timeout { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("upgrade.sock").path))
        XCTAssertTrue(second.start(handler: handler, didCommit: { _, _ in }, disconnected: { _ in }))
        second.stop()
    }
    #endif
    #endif
}

#if SOURCE_UPGRADE_FIXTURE
@main
struct SourceUpgradeFixtureMain {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: SourceUpgradeProtocolTests.self)
        suite.run()
        guard let run = suite.testRun, run.executionCount >= 3, run.totalFailureCount == 0 else { exit(1) }
    }
}
#endif
