import Foundation
import OSLog
import Darwin

/// The launcher is a separate, short-lived process with no Blocks model or DB access.
/// READY only confirms parent observation. An explicit COMMIT on owned stdin is
/// required before parent exit may trigger opening the app; EOF aborts instead.
enum PermissionRelaunchScript {
    static func make(
        maxPollCount: Int = 150,
        pollInterval: String = "0.1",
        launchExecutable: String = "/usr/bin/open"
    ) -> String {
        precondition(maxPollCount > 0)
        let launchCommand = launchExecutable == "/usr/bin/open" ? "/usr/bin/open -n" : launchExecutable
        return """
        parent_pid="$1"
        app_path="$2"
        if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
            /usr/bin/logger -t app.blocks.relaunch 'parent liveness check failed'
            exit 2
        fi
        printf 'READY\\n'
        commit=''
        if ! IFS= read -r commit || [ "$commit" != 'COMMIT' ]; then
            /usr/bin/logger -t app.blocks.relaunch 'handoff was not committed'
            exit 4
        fi
        polls=0
        while /bin/kill -0 "$parent_pid" 2>/dev/null; do
            if [ "$polls" -ge "\(maxPollCount)" ]; then
                /usr/bin/logger -t app.blocks.relaunch 'parent quit timed out'
                exit 3
            fi
            polls=$((polls + 1))
            /bin/sleep \(pollInterval)
        done
        \(launchCommand) "$app_path"
        status=$?
        if [ "$status" -ne 0 ]; then
            /usr/bin/logger -t app.blocks.relaunch 'application open failed'
        fi
        exit "$status"
        """
    }
}

@MainActor
enum PermissionRelaunchProcess {
    private static let logger = Logger(subsystem: "app.blocks", category: "PermissionRelaunch")
    private static let ownership = PermissionRelaunchProcessOwnership()

    static func cancelOwnedHandoff(parentProcessID: pid_t) async -> Bool {
        await ownership.cancelOwnedHandoff(parentProcessID: parentProcessID)
    }

    static func commitOwnedHandoff(parentProcessID: pid_t) -> Bool {
        ownership.commitOwnedHandoff(parentProcessID: parentProcessID)
    }

    static func launch(
        bundleURL: URL,
        parentProcessID: pid_t,
        completion: @escaping @Sendable (pid_t?, Error?) -> Void
    ) {
        guard parentProcessID > 0,
              bundleURL.isFileURL,
              bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: bundleURL.path) else {
            logger.error("Relaunch rejected invalid parent or app bundle")
            completion(nil, CocoaError(.fileNoSuchFile))
            return
        }
        guard ownership.canLaunch(parentProcessID: parentProcessID) else {
            logger.error("Relaunch rejected while owned launcher is still running")
            completion(nil, CocoaError(.fileReadUnknown))
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", PermissionRelaunchScript.make(), "blocks-permission-relaunch",
            String(parentProcessID), bundleURL.path,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try? input.fileHandleForReading.close()
            ownership.retainOwnedHandoff(
                process, parentProcessID: parentProcessID,
                commitInput: input.fileHandleForWriting
            )
            logger.info("Relauncher process started; awaiting parent liveness handshake")
            PermissionRelaunchHandshake(
                process: process,
                output: output,
                completion: completion
            ).start()
        } catch {
            logger.error("Relauncher process failed to start")
            completion(nil, error)
        }
    }
}

/// Holds actual child Process objects, never a caller-provided launcher PID.
/// A cancelled handoff must be observed exited before a newer one can launch.
@MainActor
final class PermissionRelaunchProcessOwnership {
    private final class OwnedHandoff {
        let process: Process
        let commitInput: FileHandle?
        var hasCommitted = false
        var inputIsClosed = false

        init(process: Process, commitInput: FileHandle?) {
            self.process = process
            self.commitInput = commitInput
        }

        func closeCommitInput() {
            guard !inputIsClosed else { return }
            inputIsClosed = true
            try? commitInput?.close()
        }
    }

    private static let logger = Logger(subsystem: "app.blocks", category: "PermissionRelaunch")
    private var ownedProcesses: [pid_t: OwnedHandoff] = [:]

    func canLaunch(parentProcessID: pid_t) -> Bool {
        guard let owned = ownedProcesses[parentProcessID] else { return true }
        guard !owned.process.isRunning else { return false }
        owned.closeCommitInput()
        ownedProcesses.removeValue(forKey: parentProcessID)
        return true
    }

    func retainOwnedHandoff(
        _ process: Process,
        parentProcessID: pid_t,
        commitInput: FileHandle? = nil
    ) {
        precondition(ownedProcesses[parentProcessID]?.process.isRunning != true)
        ownedProcesses[parentProcessID] = OwnedHandoff(process: process, commitInput: commitInput)
    }

    func commitOwnedHandoff(parentProcessID: pid_t) -> Bool {
        guard let owned = ownedProcesses[parentProcessID], owned.process.isRunning else { return false }
        if owned.hasCommitted { return true }
        guard !owned.inputIsClosed, let input = owned.commitInput else { return false }
        let descriptor = input.fileDescriptor
        // A launcher may have exited after its READY callback was queued.
        // Per-descriptor suppression avoids changing SIGPIPE process-wide.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else { return false }
        let command = Data("COMMIT\n".utf8)
        let written = command.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == command.count else {
            Self.logger.error("Owned launcher commit failed; parent_pid=\(parentProcessID, privacy: .public)")
            return false
        }
        owned.hasCommitted = true
        owned.closeCommitInput()
        Self.logger.info("Owned launcher handoff committed; parent_pid=\(parentProcessID, privacy: .public)")
        return true
    }

    func cancelOwnedHandoff(
        parentProcessID: pid_t,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        guard let owned = ownedProcesses[parentProcessID] else { return true }
        let process = owned.process
        owned.closeCommitInput()
        if process.isRunning { process.terminate() }
        let wait = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(min(timeoutNanoseconds, 2_000_000_000))))
            while process.isRunning, ContinuousClock.now < deadline {
                // An unstructured recovery task does not inherit caller
                // cancellation or release an unproven launcher ownership.
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return !process.isRunning
        }
        guard await wait.value else {
            Self.logger.error("Owned launcher cancellation deadline expired; parent_pid=\(parentProcessID, privacy: .public)")
            return false
        }
        if ownedProcesses[parentProcessID] === owned {
            ownedProcesses.removeValue(forKey: parentProcessID)
        }
        Self.logger.info("Owned launcher cancellation confirmed; parent_pid=\(parentProcessID, privacy: .public)")
        return true
    }
}

@MainActor
private final class PermissionRelaunchHandshake {
    private static let logger = Logger(subsystem: "app.blocks", category: "PermissionRelaunch")
    private let process: Process
    private let output: Pipe
    private let completion: @Sendable (pid_t?, Error?) -> Void
    private var received = Data()
    private var finished = false

    init(
        process: Process,
        output: Pipe,
        completion: @escaping @Sendable (pid_t?, Error?) -> Void
    ) {
        self.process = process
        self.output = output
        self.completion = completion
    }

    func start() {
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            Task { @MainActor in receive(data) }
        }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(2))
            failIfPending()
        }
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        received.append(data)
        if received == Data("READY\n".utf8), process.isRunning {
            finished = true
            output.fileHandleForReading.readabilityHandler = nil
            Self.logger.info("Relauncher observed parent; awaiting explicit commit")
            completion(process.processIdentifier, nil)
        } else if received.count > 16 || data.isEmpty || received.contains(0x0A) {
            failIfPending()
        }
    }

    private func failIfPending() {
        guard !finished else { return }
        finished = true
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        Self.logger.error("Relauncher readiness failed or timed out; keeping old app running")
        completion(nil, CocoaError(.fileReadUnknown))
    }
}
