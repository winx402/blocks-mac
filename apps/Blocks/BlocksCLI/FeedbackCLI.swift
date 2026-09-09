import BlocksCore
import Darwin
import Foundation

let feedbackUsage = """
blocks feedback doctor
blocks feedback list
blocks feedback preview (--latest | --id UUID)
blocks feedback submit (--latest | --id UUID) --confirm
blocks feedback create --title TITLE --body-file PATH (--dry-run | --confirm)
All output is JSON. Preview/dry-run does not transmit content. Issues are public at https://github.com/winx402/blocks-mac and use your existing gh account. No app or broker is required.
"""

enum FeedbackCLI {
    static func run(args: [String], service: FeedbackService = FeedbackService()) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        let action = "feedback.\(args.first ?? "help")"
        do {
            guard let command = args.first else { throw FeedbackFailure("invalid_arguments") }
            let options = try parse(Array(args.dropFirst()))
            let result: [String: JSONValue]
            switch command {
            case "doctor":
                try requireKeys(options, allowed: [])
                result = ["doctor": try json(service.doctor()), "consent": try json(service.store.consent())]
            case "list":
                try requireKeys(options, allowed: [])
                result = ["reports": try json(service.store.list())]
            case "preview":
                try requireKeys(options, allowed: ["--latest", "--id"])
                result = ["preview": try json(service.preview(id: selection(options)))]
            case "submit":
                try requireKeys(options, allowed: ["--latest", "--id", "--confirm"])
                let id = try selection(options)
                guard options["--confirm"] != nil else { throw FeedbackFailure("confirmation_required") }
                result = ["issue_url": .string(try service.submit(id: id)), "repository": .string(FeedbackPolicy.repository)]
            case "create":
                try requireKeys(options, allowed: ["--title", "--body-file", "--dry-run", "--confirm"])
                guard options["--dry-run"] == nil || options["--confirm"] == nil else { throw FeedbackFailure("invalid_arguments") }
                guard options["--dry-run"] != nil || options["--confirm"] != nil else { throw FeedbackFailure("confirmation_required") }
                guard let title = options["--title"], let path = options["--body-file"] else { throw FeedbackFailure("invalid_arguments") }
                let body = try readBody(path)
                try FeedbackCredentialGuard.validate(title: title, body: body)
                if options["--dry-run"] != nil {
                    result = ["preview": try json(service.manualPreview(title: title, body: body)), "dry_run": .bool(true)]
                } else {
                    result = ["issue_url": .string(try service.create(title: title, body: body)), "repository": .string(FeedbackPolicy.repository)]
                }
            default: throw FeedbackFailure("invalid_arguments")
            }
            return (ActionEnvelope(ok: true, action: action, result: result, error: nil), 0)
        } catch let error as FeedbackFailure {
            return (ActionEnvelope(ok: false, action: action, result: [:],
                                   error: ActionError(code: error.code, message: message(error.code))),
                    ["invalid_arguments", "confirmation_required", "credential_detected", "invalid_content"].contains(error.code) ? 2 : 1)
        } catch {
            return (ActionEnvelope(ok: false, action: action, result: [:],
                                   error: ActionError(code: "feedback_unavailable", message: "Feedback is unavailable; no credentials or raw diagnostics are included.")), 1)
        }
    }

    private static func parse(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let key = args[index]
            guard result[key] == nil else { throw FeedbackFailure("invalid_arguments") }
            if ["--latest", "--confirm", "--dry-run"].contains(key) {
                result[key] = "true"
                index += 1
            } else if ["--id", "--title", "--body-file"].contains(key), index + 1 < args.count,
                      !args[index + 1].hasPrefix("--") {
                result[key] = args[index + 1]
                index += 2
            } else { throw FeedbackFailure("invalid_arguments") }
        }
        return result
    }
    private static func requireKeys(_ options: [String: String], allowed: Set<String>) throws {
        guard Set(options.keys).isSubset(of: allowed) else { throw FeedbackFailure("invalid_arguments") }
    }
    private static func selection(_ options: [String: String]) throws -> UUID? {
        guard (options["--latest"] != nil) != (options["--id"] != nil) else { throw FeedbackFailure("invalid_arguments") }
        if let value = options["--id"] {
            guard let id = UUID(uuidString: value) else { throw FeedbackFailure("invalid_arguments") }
            return id
        }
        return nil
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    private static func readBody(_ path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FeedbackFailure("body_file_unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 60_000 else { throw FeedbackFailure("invalid_content") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw FeedbackFailure("body_file_unavailable") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 60_000 else { throw FeedbackFailure("invalid_content") }
        }
        guard let body = String(data: data, encoding: .utf8) else { throw FeedbackFailure("invalid_content") }
        return body
    }
    private static func message(_ code: String) -> String {
        switch code {
        case "confirmation_required": return "This creates a public GitHub issue. Preview first, then supply --confirm."
        case "credential_detected": return "Explicit credential content was detected; remove it before previewing or submitting."
        case "gh_missing": return "Install GitHub CLI yourself if you want to submit; Blocks does not install or log in automatically."
        case "authentication_required": return "An authenticated github.com gh account is required. Run gh auth status yourself."
        case "submission_unknown": return "The previous submission outcome is unknown. Existing issues were checked or will be checked before any retry; no blind resubmission is made."
        case "account_changed": return "The gh account changed. Automatic submission is paused until you consent again."
        default: return "Feedback request could not complete (\(code))."
        }
    }
}
