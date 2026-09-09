import CryptoKit
import Foundation

public enum FeedbackPolicy {
    public static let repository = "winx402/blocks-mac"
    public static let repositoryURL = "https://github.com/winx402/blocks-mac"
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public static let reportLimit = 20
    public static let dailyAutomaticLimit = 3
}

public struct FeedbackFailure: Error, Codable, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// Only allowlisted machine values can enter a stored or public automatic report.
public struct FeedbackShutdownEvent: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let phase: String
    public let participant: String
    public let code: String
    public let elapsedMS: Int
    public let forced: Bool
    public let activeOperations: Int

    public init(attemptID: UUID, phase: String, participant: String, code: String,
                elapsedMS: Int, forced: Bool, activeOperations: Int) {
        self.attemptID = attemptID
        self.phase = Self.allowed(phase, ["requested", "preparing", "participant_started", "participant_completed", "failed", "graceful", "forced_timeout", "forced_failure", "incomplete_previous_attempt"])
        self.participant = Self.allowed(participant, ["app", "shortcuts", "helper", "actionBroker", "clipboard", "translation", "provider", "screenshot", "plugins", "database"])
        self.code = Self.allowed(code, ["none", "busy", "configuration_missing", "preparation_failed", "timeout", "incomplete_shutdown"])
        self.elapsedMS = min(max(elapsedMS, 0), 86_400_000)
        self.forced = forced
        self.activeOperations = min(max(activeOperations, -1), 1_000_000)
    }

    public var isAbnormal: Bool {
        phase == "failed" || phase == "forced_timeout" || phase == "forced_failure" || phase == "incomplete_previous_attempt"
    }

    private static func allowed(_ value: String, _ values: Set<String>) -> String {
        values.contains(value) ? value : "unknown"
    }

    // Decode through the same sanitizer; local files are not trusted input.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(attemptID: try c.decode(UUID.self, forKey: .attemptID),
                  phase: try c.decode(String.self, forKey: .phase),
                  participant: try c.decode(String.self, forKey: .participant),
                  code: try c.decode(String.self, forKey: .code),
                  elapsedMS: try c.decode(Int.self, forKey: .elapsedMS),
                  forced: try c.decode(Bool.self, forKey: .forced),
                  activeOperations: try c.decode(Int.self, forKey: .activeOperations))
    }
}

public struct FeedbackReport: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let appVersion: String
    public let osVersion: String
    public let architecture: String
    public var events: [FeedbackShutdownEvent]
    public var status: String
    public var issueURL: String?
    public var lastCode: String?

    public var isAbnormal: Bool { events.contains(where: \.isAbnormal) }
    public var fingerprint: String {
        let signature = events.filter(\.isAbnormal).map {
            "\($0.phase):\($0.participant):\($0.code):\($0.forced)"
        }.sorted().joined(separator: "|")
        return SHA256.hash(data: Data("\(safeVersion(appVersion))|\(signature)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public var publicTitle: String { "[Blocks shutdown] \(safeVersion(appVersion)) \(events.last(where: \.isAbnormal)?.code ?? "none")" }
    public var publicBody: String {
        struct Payload: Encodable {
            let appVersion: String
            let osVersion: String
            let architecture: String
            let events: [FeedbackShutdownEvent]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(appVersion: safeVersion(appVersion), osVersion: safeVersion(osVersion),
                              architecture: ["arm64", "x86_64"].contains(architecture) ? architecture : "unknown", events: events)
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let incompleteNote = events.contains { $0.phase == "incomplete_previous_attempt" }
            ? "\nThe previous shutdown record has no terminal event. This does not establish whether the process was forced to exit or whether its final log was simply not persisted.\n" : ""
        return "Blocks shutdown diagnostics (allowlisted metadata only). activeOperations = -1 means not sampled / unknown.\n\(incompleteNote)\n```json\n\(json)\n```\n\n<!-- blocks-feedback:\(id.uuidString.lowercased()) -->"
    }
}

private func safeVersion(_ value: String) -> String {
    value.range(of: "^[0-9][0-9A-Za-z.+-]{0,39}$", options: .regularExpression) != nil ? value : "unknown"
}

public struct FeedbackConsent: Codable, Equatable, Sendable {
    public var enabled = false
    public var account: String?
    public var pausedCode: String?
    public var acceptedAt: Date?
    public init() {}
}

public struct FeedbackDoctor: Codable, Sendable {
    public let repository: String
    public let ghAvailable: Bool
    public let account: String?
    public let code: String
    public init(repository: String = FeedbackPolicy.repository, ghAvailable: Bool, account: String?, code: String) {
        self.repository = repository
        self.ghAvailable = ghAvailable
        self.account = account
        self.code = code
    }
}

public struct FeedbackPreview: Codable, Sendable {
    public let repository: String
    public let title: String
    public let body: String
    public let externalTransmission: Bool
    public init(title: String, body: String) {
        repository = FeedbackPolicy.repository
        self.title = title
        self.body = body
        externalTransmission = false
    }
}

/// This deliberately catches explicit credential formats, not arbitrary prose.
public enum FeedbackCredentialGuard {
    public static func validate(title: String, body: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, body.utf8.count <= 60_000 else { throw FeedbackFailure("invalid_content") }
        let input = title + "\n" + body
        let patterns = [
            "(?i)\\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{16,})",
            "-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----",
            "(?i)(?:authorization\\s*:\\s*bearer|(?:api[_-]?key|access[_-]?token|password|cookie)\\s*[:=])\\s*[^\\s]{4,}",
            "\\bAKIA[A-Z0-9]{16}\\b"
        ]
        guard !patterns.contains(where: { input.range(of: $0, options: .regularExpression) != nil }) else {
            throw FeedbackFailure("credential_detected")
        }
    }
}
