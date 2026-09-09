import AppKit
import Darwin
import Foundation

private struct FixtureReport: Codable {
    let parentPID: Int32
    let registeredPID: Int32
    let registeredExecutablePath: String
    let registrationSucceeded: Bool
    let observedExecutablePath: String
    let outsideExecutableRejected: Bool
    let unregisteredPID: Int32
    let unregisteredExecutablePath: String
}

private final class WatchdogTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let resultURL: URL
    private var requestUptimeNanoseconds: UInt64?

    init(resultURL: URL) {
        self.resultURL = resultURL
    }

    func markRequest() {
        lock.lock()
        requestUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func recordForce() {
        let forcedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let requestUptimeNanoseconds = requestUptimeNanoseconds
        lock.unlock()
        guard let requestUptimeNanoseconds else { return }
        let delayNanoseconds = forcedUptimeNanoseconds - requestUptimeNanoseconds
        let result = "{\"requestUptimeNanoseconds\":\(requestUptimeNanoseconds),\"forcedUptimeNanoseconds\":\(forcedUptimeNanoseconds),\"forceDelayNanoseconds\":\(delayNanoseconds)}\n"
        writeRaw(result, to: resultURL)
        writeRaw("WATCHDOG_FORCE delayNanoseconds=\(delayNanoseconds)\n", toFileDescriptor: STDOUT_FILENO)
    }

    private func writeRaw(_ text: String, to url: URL) {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        writeRaw(text, toFileDescriptor: descriptor)
    }

    private func writeRaw(_ text: String, toFileDescriptor descriptor: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

@main
struct QuitWatchdogProcessFixture {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            _exit(64)
        }

        let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let forceResultURL = reportURL.deletingLastPathComponent()
            .appendingPathComponent("watchdog-force-result.json")
        let brokerURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/BlocksClipboardBroker")
            .standardizedFileURL
        let sleepURL = URL(fileURLWithPath: "/bin/sleep")
        // Use the exact expected leaf for the negative boundary, not a different
        // filename. Canonicalizing that expected leaf would wrongly accept this
        // external executable. It must remain alive after the real watchdog.
        try FileManager.default.createSymbolicLink(at: brokerURL, withDestinationURL: sleepURL)
        let unregistered = try launch(executableURL: brokerURL)
        let outsideExecutableRejected = !ShutdownPrivateProcesses.registerClipboardChild(
            pid: unregistered.processIdentifier, executableURL: brokerURL
        )
        try FileManager.default.removeItem(at: brokerURL)
        try FileManager.default.copyItem(at: sleepURL, to: brokerURL)

        let registered = try launch(executableURL: brokerURL)
        let registrationSucceeded = ShutdownPrivateProcesses.registerClipboardChild(
            pid: registered.processIdentifier,
            executableURL: brokerURL
        )

        let report = FixtureReport(
            parentPID: getpid(),
            registeredPID: registered.processIdentifier,
            registeredExecutablePath: brokerURL.path,
            registrationSucceeded: registrationSucceeded,
            observedExecutablePath: executablePath(of: registered.processIdentifier),
            outsideExecutableRejected: outsideExecutableRejected,
            unregisteredPID: unregistered.processIdentifier,
            unregisteredExecutablePath: sleepURL.path
        )
        try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)

        let timing = WatchdogTiming(resultURL: forceResultURL)
        let coordinator = AppTerminationCoordinator(
            dispatcher: { @MainActor in
                // This intentionally blocks the MainActor far longer than the
                // production deadline. The watchdog must remain independent.
                blockMainActorForTwentySeconds()
            },
            forceExit: {
                timing.recordForce()
                ShutdownPrivateProcesses.terminateRegisteredProcesses()
                _exit(77)
            },
            replyHandler: { _ in }
        )
        timing.markRequest()
        guard coordinator.requestTermination() == .terminateLater else {
            _exit(65)
        }

        // Give the MainActor-inheriting dispatcher task a chance to begin its
        // deliberate block. The process must instead leave through forceExit.
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000_000)
        _exit(66)
    }

    private static func executablePath(of pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "unavailable" }
        return String(cString: path)
    }

    private static func launch(executableURL: URL) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["60"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @MainActor
    private static func blockMainActorForTwentySeconds() {
        let neverSignaled = DispatchSemaphore(value: 0)
        _ = neverSignaled.wait(timeout: .now() + 20)
    }
}
