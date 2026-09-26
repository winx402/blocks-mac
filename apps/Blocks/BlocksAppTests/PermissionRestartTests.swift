import AppKit
import XCTest
@testable import Blocks

@MainActor
final class PermissionRestartTests: XCTestCase {
    func testDuplicateRequestsWaitForOneHandoffAndTerminateOnce() {
        var launchCount = 0
        var terminateCount = 0
        var pending: (@Sendable (pid_t?, Error?) -> Void)?
        var results: [PermissionRestartResult] = []
        let parentPID = getpid()
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, completion in
                launchCount += 1
                pending = completion
            },
            applicationTerminator: { terminateCount += 1 }
        )

        actions.restartForPermissionRefresh { results.append($0) }
        actions.restartForPermissionRefresh { results.append($0) }
        XCTAssertEqual(launchCount, 1)
        XCTAssertTrue(results.isEmpty, "A second tap must not report readiness early")
        XCTAssertEqual(terminateCount, 0)

        pending?(parentPID + 1, nil)
        XCTAssertEqual(results, [.scheduled, .scheduled])
        XCTAssertEqual(terminateCount, 1)

        actions.restartForPermissionRefresh { results.append($0) }
        XCTAssertEqual(results, [.scheduled, .scheduled, .scheduled])
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(terminateCount, 1)
    }

    func testFailedHandoffRetainsOldAppAndCanRetry() {
        var launchCount = 0
        var terminateCount = 0
        var results: [PermissionRestartResult] = []
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, completion in
                launchCount += 1
                completion(nil, CocoaError(.fileReadUnknown))
            },
            applicationTerminator: { terminateCount += 1 }
        )

        actions.restartForPermissionRefresh { results.append($0) }
        actions.restartForPermissionRefresh { results.append($0) }
        XCTAssertEqual(results, [.failed, .failed])
        XCTAssertEqual(launchCount, 2)
        XCTAssertEqual(terminateCount, 0)
    }

    func testLauncherTimesOutWithoutOpeningWhileParentStillLives() throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(
            parentPID: parent.processIdentifier,
            maxPollCount: 3
        )
        launcher.process.waitUntilExit()
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()

        XCTAssertEqual(String(data: output, encoding: .utf8), "READY\n")
        XCTAssertEqual(launcher.process.terminationStatus, 3)
        XCTAssertTrue(parent.isRunning)
    }

    func testLauncherOpensExactlyOnceOnlyAfterParentExits() throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(
            parentPID: parent.processIdentifier,
            maxPollCount: 30
        )
        let ready = launcher.output.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")
        XCTAssertTrue(parent.isRunning)

        parent.terminate()
        parent.waitUntilExit()
        launcher.process.waitUntilExit()
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()

        XCTAssertEqual(String(data: output, encoding: .utf8), "LAUNCHED")
        XCTAssertEqual(launcher.process.terminationStatus, 0)
    }

    private func makeSleepingParent() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func makeScriptProcess(
        parentPID: pid_t,
        maxPollCount: Int
    ) throws -> (process: Process, output: Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            PermissionRelaunchScript.make(
                maxPollCount: maxPollCount,
                launchExecutable: "/usr/bin/printf"
            ),
            "blocks-permission-relaunch-test",
            String(parentPID),
            "LAUNCHED",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, output)
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
