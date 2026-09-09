import Darwin
import Foundation

public protocol FeedbackGitHubServing: Sendable {
    func doctor() -> FeedbackDoctor
    func create(title: String, body: String) throws -> String
    func create(title: String, body: String, authorize: @escaping @Sendable () throws -> Void) throws -> String
    func find(marker: String, account: String) throws -> String?
}

public extension FeedbackGitHubServing {
    func create(title: String, body: String, authorize: @escaping @Sendable () throws -> Void) throws -> String {
        try authorize()
        return try create(title: title, body: body)
    }
}

public final class FeedbackGitHubClient: FeedbackGitHubServing, @unchecked Sendable {
    private let executable: URL?
    private let stopGate: FeedbackStopGate
    public init(stopGate: FeedbackStopGate = FeedbackStopGate()) {
        self.stopGate = stopGate
        executable = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    public static func validAccount(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil
    }

    public func doctor() -> FeedbackDoctor {
        guard !stopGate.isStopped else { return FeedbackDoctor(ghAvailable: false, account: nil, code: "feedback_stopped") }
        guard executable != nil else { return FeedbackDoctor(repository: FeedbackPolicy.repository, ghAvailable: false, account: nil, code: "gh_missing") }
        do {
            let data = try run(["api", "--hostname", "github.com", "user", "--jq", ".login"])
            let account = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validAccount(account) else { throw FeedbackFailure("authentication_required") }
            return FeedbackDoctor(repository: FeedbackPolicy.repository, ghAvailable: true, account: account, code: "ready")
        } catch let error as FeedbackFailure {
            return FeedbackDoctor(repository: FeedbackPolicy.repository, ghAvailable: true, account: nil,
                                  code: error.code == "gh_timeout" ? "gh_timeout" : "authentication_required")
        } catch { return FeedbackDoctor(repository: FeedbackPolicy.repository, ghAvailable: true, account: nil, code: "authentication_required") }
    }

    public func create(title: String, body: String) throws -> String {
        try create(title: title, body: body, authorize: {})
    }

    public func create(title: String, body: String, authorize: @escaping @Sendable () throws -> Void) throws -> String {
        try FeedbackCredentialGuard.validate(title: title, body: body)
        let data = try JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        let result = try run(["api", "--hostname", "github.com", "--method", "POST",
                              "repos/\(FeedbackPolicy.repository)/issues", "--input", "-"], input: data, authorize: authorize)
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let url = object["html_url"] as? String, Self.validIssueURL(url) else { throw FeedbackFailure("submission_unknown") }
        return url
    }

    public func find(marker: String, account: String) throws -> String? {
        guard Self.validAccount(account), UUID(uuidString: marker) != nil else { throw FeedbackFailure("invalid_arguments") }
        let query = "repo:\(FeedbackPolicy.repository) is:issue author:\(account) in:body \"blocks-feedback:\(marker.lowercased())\""
        let data = try run(["api", "--hostname", "github.com", "--method", "GET", "search/issues",
                            "-f", "q=\(query)", "-f", "per_page=10"])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["incomplete_results"] as? Bool == false,
              let items = object["items"] as? [[String: Any]] else { throw FeedbackFailure("reconciliation_unavailable") }
        for item in items {
            if let body = item["body"] as? String,
               body.contains("<!-- blocks-feedback:\(marker.lowercased()) -->"),
               let url = item["html_url"] as? String, Self.validIssueURL(url) { return url }
        }
        return nil
    }

    public static func validIssueURL(_ value: String) -> Bool {
        value.range(of: "^https://github\\.com/winx402/blocks-mac/issues/[1-9][0-9]*$", options: .regularExpression) != nil
    }

    private func run(_ arguments: [String], input: Data? = nil,
                     authorize: @escaping @Sendable () throws -> Void = {}) throws -> Data {
        try stopGate.check()
        guard let executable else { throw FeedbackFailure("gh_missing") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Do not inherit token overrides, debug logging, browser hooks, or alternate hosts.
        // gh alone accesses its existing authentication; Blocks never asks it for a token.
        var safeEnvironment = [String: String]()
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = getenv(key) { safeEnvironment[key] = String(cString: value) }
        }
        safeEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        safeEnvironment["GH_HOST"] = "github.com"
        safeEnvironment["GH_PROMPT_DISABLED"] = "1"
        safeEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        safeEnvironment["GH_PAGER"] = "cat"
        process.environment = safeEnvironment
        let output = Pipe()
        let stdin = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        let ownership = FeedbackOwnedProcess(process)
        let registration = try stopGate.register {
            completed.signal()
            ownership.cancel()
        }
        defer { stopGate.unregister(registration) }
        try authorize()
        try stopGate.check()
        do { try ownership.start(stopGate: stopGate) }
        catch let error as FeedbackFailure { throw error }
        catch { throw FeedbackFailure("gh_unavailable") }
        let capture = FeedbackProcessCapture()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let bytes = output.fileHandleForReading.readData(ofLength: 8192)
                if bytes.isEmpty { break }
                capture.append(bytes)
            }
            drained.signal()
        }
        // Keep stdin writes away from the caller's deadline path as well.
        DispatchQueue.global(qos: .utility).async { [stopGate] in
            if let input, (try? stopGate.check()) != nil, (try? authorize()) != nil {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
            }
            try? stdin.fileHandleForWriting.close()
        }
        guard completed.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw FeedbackFailure("gh_timeout")
        }
        try stopGate.check()
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { throw FeedbackFailure("gh_failed") }
        return try capture.result()
    }
}

/// Cancellation is scoped to this exact owned Process. The gate dispatches this
/// work off the quit caller; no process scans or global gh termination are used.
private final class FeedbackOwnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    init(_ process: Process) { self.process = process }
    func start(stopGate: FeedbackStopGate) throws {
        lock.lock(); defer { lock.unlock() }
        try stopGate.check()
        if cancelled { throw FeedbackFailure("feedback_stopped") }
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class FeedbackProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + value.count <= 1_000_000 { data.append(value) } else { overflow = true }
    }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if overflow { throw FeedbackFailure("gh_response_too_large") }
        return data
    }
}
