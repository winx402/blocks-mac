import Darwin
import Foundation
import XCTest
@testable import Blocks

@MainActor
final class ActionBrokerZombieProcessTests: XCTestCase {
    private typealias Snapshot = ActionBrokerServiceManager.BrokerProcessSnapshot

    private func snapshot(_ pid: Int32 = 77, start: Int64 = 100, status: Int32 = SZOMB) -> Snapshot {
        Snapshot(processID: pid, startSeconds: start, startMicroseconds: 1, status: status)
    }

    private func scanUnknown(_ read: (Int32) -> Snapshot?) throws -> [Int32] {
        try ActionBrokerServiceManager.brokerProcessIDs(in: [77], policy: .developmentMigration,
            executablePath: { _ in nil }, kernelName: { _ in nil }, hasExited: { _ in false },
            kernelSnapshot: read)
    }

    func testStableZombieLifetimeIsExcluded() throws {
        var reads = 0
        let result = try scanUnknown { _ in reads += 1; return self.snapshot() }
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(reads, 2)
    }

    func testLiveUnknownProcessStillFailsClosed() {
        XCTAssertThrowsError(try scanUnknown { _ in self.snapshot(status: SRUN) })
    }

    func testUnreadableKernelStateStillFailsClosed() {
        XCTAssertThrowsError(try scanUnknown { _ in nil }, "permission denial is not an exit proof")
        var reads = 0
        XCTAssertThrowsError(try scanUnknown { _ in
            reads += 1
            return reads == 1 ? self.snapshot() : nil
        }, "a permission failure or disappearance on revalidation is not a zombie proof")
    }

    func testReusedPIDStillFailsClosed() {
        var reads = 0
        XCTAssertThrowsError(try scanUnknown { _ in
            reads += 1
            return self.snapshot(start: Int64(100 + reads))
        }, "two zombie lifetimes sharing a PID must not be conflated")
    }

    func testWrongPIDStillFailsClosed() {
        XCTAssertThrowsError(try scanUnknown { _ in self.snapshot(78) })
    }

    func testStatusTransitionsStillFailClosed() {
        for states in [[SRUN, SZOMB], [SZOMB, SRUN]] {
            var reads = 0
            XCTAssertThrowsError(try scanUnknown { _ in
                let result = self.snapshot(status: states[reads])
                reads += 1
                return result
            })
        }
    }

    func testMissingInitialSnapshotCannotBeReplacedByLaterZombieProof() {
        var reads = 0
        XCTAssertThrowsError(try scanUnknown { _ in
            reads += 1
            return reads == 1 ? nil : self.snapshot()
        })
    }

    func testMissingPIDUsesExistingExitProof() throws {
        let result = try ActionBrokerServiceManager.brokerProcessIDs(in: [77], policy: .developmentMigration,
            executablePath: { _ in nil }, kernelName: { _ in XCTFail("must not inspect an exited PID"); return nil },
            hasExited: { _ in true }, kernelSnapshot: { _ in nil })
        XCTAssertTrue(result.isEmpty)
    }

    func testKnownMovedBrokerIsIncludedWithoutZombieFallback() throws {
        let result = try ActionBrokerServiceManager.brokerProcessIDs(in: [77], policy: .developmentMigration,
            executablePath: { _ in "/old/moved/Blocks.app/Contents/MacOS/BlocksActionBroker" },
            kernelName: { _ in XCTFail("known path must not use the fallback"); return nil },
            hasExited: { _ in XCTFail("known path must not use the fallback"); return false },
            kernelSnapshot: { _ in XCTFail("known path must not use the fallback"); return nil })
        XCTAssertEqual(result, [77])
    }

    func testOfficialPolicyDoesNotQueryKernelSnapshots() throws {
        let result = try ActionBrokerServiceManager.brokerProcessIDs(in: [77],
            policy: .currentBundle(executablePath: "/Applications/Blocks.app/Contents/MacOS/BlocksActionBroker"),
            executablePath: { _ in nil }, kernelName: { _ in nil }, hasExited: { _ in false },
            kernelSnapshot: { _ in XCTFail("official sandbox policy must not use migration inspection"); return nil })
        XCTAssertTrue(result.isEmpty)
    }

    func testRealUnreapedZombieIsExcludedDespiteSuccessfulSignalZero() async throws {
        // Foundation Process automatically reaps children. Spawn directly and
        // deliberately defer waitpid so this is a real kernel zombie, not a mock.
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(arguments[0]) }
        let result = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, "/usr/bin/true", nil, nil, $0.baseAddress!, nil)
        }
        XCTAssertEqual(result, 0)
        guard result == 0 else { return }
        defer {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ActionBrokerServiceManager.kernelProcessSnapshot(pid)?.isZombie != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let zombie = try XCTUnwrap(ActionBrokerServiceManager.kernelProcessSnapshot(pid))
        XCTAssertTrue(zombie.isZombie)
        XCTAssertEqual(kill(pid, 0), 0, "an unreaped zombie still occupies its PID")
        XCTAssertNil(ActionBrokerServiceManager.processExecutablePath(pid))
        XCTAssertNil(ActionBrokerServiceManager.kernelProcessName(pid))
        let detected = try ActionBrokerServiceManager.brokerProcessIDs(in: [pid], policy: .developmentMigration,
            executablePath: ActionBrokerServiceManager.processExecutablePath,
            kernelName: ActionBrokerServiceManager.kernelProcessName,
            hasExited: { kill($0, 0) != 0 && errno == ESRCH },
            kernelSnapshot: ActionBrokerServiceManager.kernelProcessSnapshot)
        XCTAssertTrue(detected.isEmpty)
        XCTAssertEqual(ActionBrokerServiceManager.kernelProcessSnapshot(pid), zombie,
                       "the scan must not kill or reap the fixture")
    }

    func testRealLiveProcessWithUnavailableIdentityStillFailsClosed() throws {
        let pid = getpid()
        let live = try XCTUnwrap(ActionBrokerServiceManager.kernelProcessSnapshot(pid))
        XCTAssertFalse(live.isZombie)
        XCTAssertThrowsError(try ActionBrokerServiceManager.brokerProcessIDs(in: [pid], policy: .developmentMigration,
            executablePath: { _ in nil }, kernelName: { _ in nil },
            hasExited: { kill($0, 0) != 0 && errno == ESRCH },
            kernelSnapshot: ActionBrokerServiceManager.kernelProcessSnapshot))
        XCTAssertEqual(kill(pid, 0), 0)
    }

    func testRealReapedPIDUsesExistingExitProof() throws {
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(arguments[0]) }
        let result = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, "/usr/bin/true", nil, nil, $0.baseAddress!, nil)
        }
        XCTAssertEqual(result, 0)
        guard result == 0 else { return }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        XCTAssertEqual(waited, pid)
        XCTAssertNil(ActionBrokerServiceManager.kernelProcessSnapshot(pid))
        XCTAssertNotEqual(kill(pid, 0), 0)
        XCTAssertEqual(errno, ESRCH)
        let detected = try ActionBrokerServiceManager.brokerProcessIDs(in: [pid], policy: .developmentMigration,
            executablePath: ActionBrokerServiceManager.processExecutablePath,
            kernelName: ActionBrokerServiceManager.kernelProcessName,
            hasExited: { kill($0, 0) != 0 && errno == ESRCH },
            kernelSnapshot: ActionBrokerServiceManager.kernelProcessSnapshot)
        XCTAssertTrue(detected.isEmpty)
    }

    func testRealMovedBrokerExecutableIsStillIncluded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrokerZombieTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("moved/Blocks.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = directory.appendingPathComponent("BlocksActionBroker")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ActionBrokerServiceManager.processExecutablePath(process.processIdentifier)?
                .hasSuffix("/Contents/MacOS/BlocksActionBroker") != true,
              process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let detected = try ActionBrokerServiceManager.brokerProcessIDs(in: [process.processIdentifier],
            policy: .developmentMigration, executablePath: ActionBrokerServiceManager.processExecutablePath,
            kernelName: ActionBrokerServiceManager.kernelProcessName,
            hasExited: { kill($0, 0) != 0 && errno == ESRCH },
            kernelSnapshot: ActionBrokerServiceManager.kernelProcessSnapshot)
        XCTAssertEqual(detected, [process.processIdentifier])
        XCTAssertTrue(process.isRunning, "only the fixture cleanup may terminate this child")
    }
}
