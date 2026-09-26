import Foundation
import OSLog

/// The launcher is a separate, short-lived process with no Blocks model or DB access.
/// It positively observes the parent before acknowledging handoff, then waits
/// for that PID to disappear. A stalled or cancelled quit never starts another app.
enum PermissionRelaunchScript {
    static func make(
        maxPollCount: Int = 150,
        pollInterval: String = "0.1",
        launchExecutable: String = "/usr/bin/open"
    ) -> String {
        precondition(maxPollCount > 0)
        return """
        parent_pid="$1"
        app_path="$2"
        if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
            /usr/bin/logger -t app.blocks.relaunch 'parent liveness check failed'
            exit 2
        fi
        printf 'READY\\n'
        polls=0
        while /bin/kill -0 "$parent_pid" 2>/dev/null; do
            if [ "$polls" -ge "\(maxPollCount)" ]; then
                /usr/bin/logger -t app.blocks.relaunch 'parent quit timed out'
                exit 3
            fi
            polls=$((polls + 1))
            /bin/sleep \(pollInterval)
        done
        \(launchExecutable) "$app_path"
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

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", PermissionRelaunchScript.make(), "blocks-permission-relaunch",
            String(parentProcessID), bundleURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            logger.info("Relauncher process started; awaiting parent liveness handshake")
            PermissionRelaunchHandshake(
                process: process,
                output: output,
                completion: completion
            ).start()
        } catch {
            logger.error("Relauncher process failed to start: \(error.localizedDescription, privacy: .public)")
            completion(nil, error)
        }
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
            Self.logger.info("Relauncher ready; old app can begin orderly quit")
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
