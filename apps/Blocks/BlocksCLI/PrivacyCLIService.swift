import Foundation
import BlocksCore

enum PrivacyCLIService {
    static func run(args: [String]) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        guard !args.contains("--include-sensitive-paths") else {
            return failure(
                command: "privacy",
                code: "unsupported_sensitive_paths",
                message: "--include-sensitive-paths is not supported in this version.",
                result: ["supported": .bool(false), "mutation_performed": .bool(false)],
                exitCode: 2
            )
        }

        guard let area = args.first else {
            return failure(command: "privacy", code: "missing_privacy_command", message: "Usage: blocks privacy subjects|policy|action ...", exitCode: 2)
        }

        switch area {
        case "subjects":
            return runSubjects(args: Array(args.dropFirst()))
        case "policy":
            return runPolicy(args: Array(args.dropFirst()))
        case "action":
            return runAction(args: Array(args.dropFirst()))
        default:
            return failure(command: "privacy", code: "unknown_privacy_command", message: "Unknown privacy command: \(area)", exitCode: 2)
        }
    }

    private static func runSubjects(args: [String]) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        guard let subcommand = args.first else {
            return failure(command: "privacy.subjects", code: "missing_subjects_command", message: "Usage: blocks privacy subjects list|resolve ...", exitCode: 2)
        }
        switch subcommand {
        case "list":
            let type = value(after: "--type", in: args).flatMap(PrivacyPolicySubjectType.init(rawValue:))
            do {
                let rules = try repository().loadRules()
                    .filter { type == nil || $0.subject.type == type }
                    .map { rule in
                        JSONValue.object([
                            "subject_ref": .string(rule.subject.subjectRef),
                            "subject_type": .string(rule.subject.type.rawValue),
                            "identifier": .string(rule.subject.identifier),
                            "display_name": rule.subject.displayName.map(JSONValue.string) ?? .null,
                            "policy": .string(rule.policy.rawValue),
                        ])
                    }
                return success(
                    command: "privacy.subjects.list",
                    result: [
                        "subjects": .array(rules),
                        "includes_full_paths": .bool(false),
                    ]
                )
            } catch {
                return failure(command: "privacy.subjects.list", code: "repository_unavailable", message: "Privacy policy repository is unavailable.", exitCode: 1)
            }
        case "resolve":
            guard let rawType = value(after: "--type", in: args),
                  let type = PrivacyPolicySubjectType(rawValue: rawType),
                  let identifier = value(after: "--identifier", in: args),
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return failure(command: "privacy.subjects.resolve", code: "invalid_subject", message: "Resolve requires --type and --identifier.", exitCode: 2)
            }
            guard let subject = explicitSubject(type: type, identifier: identifier) else {
                return failure(command: "privacy.subjects.resolve", code: "unsupported_subject", message: "Subject type or identifier is unsupported.", exitCode: 2)
            }
            return success(
                command: "privacy.subjects.resolve",
                result: subjectJSON(subject, policy: nil, ambiguous: false)
            )
        default:
            return failure(command: "privacy.subjects", code: "unknown_subjects_command", message: "Unknown subjects command: \(subcommand)", exitCode: 2)
        }
    }

    private static func runPolicy(args: [String]) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        guard let subcommand = args.first else {
            return failure(command: "privacy.policy", code: "missing_policy_command", message: "Usage: blocks privacy policy get|set ...", exitCode: 2)
        }
        switch subcommand {
        case "get":
            guard let subjectRef = value(after: "--subject-ref", in: args) else {
                return failure(command: "privacy.policy.get", code: "missing_subject_ref", message: "Policy get requires --subject-ref.", exitCode: 2)
            }
            do {
                let rule = try repository().rule(subjectRef: subjectRef)
                return success(
                    command: "privacy.policy.get",
                    result: [
                        "subject_ref": .string(subjectRef),
                        "policy": .string(rule?.policy.rawValue ?? PrivacyPolicyStatus.defaultPolicy.rawValue),
                        "matched_rule": .bool(rule != nil),
                    ]
                )
            } catch {
                return failure(command: "privacy.policy.get", code: "repository_unavailable", message: "Privacy policy repository is unavailable.", exitCode: 1)
            }
        case "set":
            guard let subjectRef = value(after: "--subject-ref", in: args),
                  let rawPolicy = value(after: "--policy", in: args),
                  let policy = PrivacyPolicyStatus(rawValue: rawPolicy)
            else {
                return failure(command: "privacy.policy.set", code: "invalid_policy_set", message: "Policy set requires --subject-ref and --policy default|allowed|restricted.", exitCode: 2)
            }
            let dryRun = args.contains("--dry-run")
            let confirmed = args.contains("--confirm")
            guard dryRun || confirmed else {
                return failure(command: "privacy.policy.set", code: "confirmation_required", message: "Policy set requires --dry-run or --confirm.", exitCode: 2)
            }
            do {
                let repository = try repository()
                guard let subject = try subject(from: subjectRef, args: args, repository: repository) else {
                    return failure(command: "privacy.policy.set", code: "invalid_subject_ref", message: "Unsupported subject-ref.", exitCode: 2)
                }
                let result = try repository.applyPolicy(subject: subject, policy: policy, dryRun: dryRun)
                return success(
                    command: "privacy.policy.set",
                    result: [
                        "subject_ref": .string(result.subjectRef),
                        "policy_before": .string(result.policyBefore.rawValue),
                        "policy_after": .string(result.policyAfter.rawValue),
                        "mutation_performed": .bool(result.mutationPerformed),
                        "requires_confirm": .bool(!confirmed),
                        "system_action_unlocked": .bool(result.systemActionUnlocked),
                    ]
                )
            } catch {
                return failure(command: "privacy.policy.set", code: "repository_unavailable", message: "Privacy policy repository is unavailable.", exitCode: 1)
            }
        default:
            return failure(command: "privacy.policy", code: "unknown_policy_command", message: "Unknown policy command: \(subcommand)", exitCode: 2)
        }
    }

    private static func runAction(args: [String]) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        guard args.first == "blocked",
              let capability = value(after: "--capability", in: args)
        else {
            return failure(command: "privacy.action", code: "missing_action_probe", message: "Usage: blocks privacy action blocked --capability <name>", exitCode: 2)
        }
        return success(
            command: "privacy.action.blocked",
            result: [
                "capability": .string(capability),
                "blocked": .bool(true),
                "mutation_performed": .bool(false),
                "command_execution": .bool(false),
                "system_action_unlocked": .bool(false),
                "reason": .string(capability == "tcc_reset" ? "tcc_reset is outside Blocks privacy policy mutation scope." : "System action is outside privacy policy mutation scope."),
            ]
        )
    }

    private static func subject(
        from subjectRef: String,
        args: [String],
        repository: PrivacyPolicyRepository
    ) throws -> PrivacyPolicySubject? {
        if let existing = try repository.rule(subjectRef: subjectRef)?.subject {
            return existing
        }
        if let rawType = value(after: "--type", in: args),
           let type = PrivacyPolicySubjectType(rawValue: rawType),
           let identifier = value(after: "--identifier", in: args),
           let subject = explicitSubject(type: type, identifier: identifier),
           subject.subjectRef == subjectRef {
            return subject
        }
        guard
            let type = PrivacySubjectResolver.type(fromSubjectRef: subjectRef),
            let opaqueIdentifier = opaqueIdentifier(from: subjectRef, type: type)
        else {
            return nil
        }
        return PrivacyPolicySubject(
            subjectRef: subjectRef,
            type: type,
            identifier: opaqueIdentifier,
            displayName: type.rawValue,
            pathHash: type == .appPath || type == .appBundle || type == .commandPath ? opaqueIdentifier : nil,
            pathSummary: nil,
            sourceDirectory: nil
        )
    }

    private static func explicitSubject(type: PrivacyPolicySubjectType, identifier: String) -> PrivacyPolicySubject? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        switch type {
        case .bundleID:
            return PrivacySubjectResolver.bundleSubject(bundleIdentifier: trimmed, displayName: trimmed)
        case .appPath:
            guard trimmed.hasPrefix("/") else {
                return nil
            }
            return PrivacySubjectResolver.appPathSubject(url: URL(fileURLWithPath: trimmed), displayName: URL(fileURLWithPath: trimmed).lastPathComponent)
        case .appBundle:
            guard trimmed.hasPrefix("/") else {
                return nil
            }
            return PrivacySubjectResolver.appBundleSubject(url: URL(fileURLWithPath: trimmed), displayName: URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent)
        case .commandPath:
            guard trimmed.hasPrefix("/") else {
                return nil
            }
            return PrivacySubjectResolver.subject(type: type, identifier: trimmed)
        case .loginItem, .helper, .launchLabel:
            return PrivacySubjectResolver.subject(type: type, identifier: trimmed)
        }
    }

    private static func opaqueIdentifier(from subjectRef: String, type: PrivacyPolicySubjectType) -> String? {
        let prefix = "sub_v1_\(type.rawValue)_"
        guard subjectRef.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(subjectRef.dropFirst(prefix.count))
        guard suffix.count == 20, suffix.range(of: #"^[a-f0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return suffix
    }

    private static func subjectJSON(
        _ subject: PrivacyPolicySubject,
        policy: PrivacyPolicyStatus?,
        ambiguous: Bool
    ) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "subject_ref": .string(subject.subjectRef),
            "subject_type": .string(subject.type.rawValue),
            "identifier_summary": .string(identifierSummary(subject)),
            "ambiguous": .bool(ambiguous),
            "includes_full_paths": .bool(false),
        ]
        if let policy {
            result["policy"] = .string(policy.rawValue)
        }
        return result
    }

    private static func identifierSummary(_ subject: PrivacyPolicySubject) -> String {
        switch subject.type {
        case .bundleID, .loginItem, .helper, .launchLabel:
            return subject.displayName ?? subject.identifier
        case .appPath, .appBundle, .commandPath:
            return subject.pathSummary ?? "<PATH>"
        }
    }

    private static func repository() throws -> PrivacyPolicyRepository {
        try PrivacyPolicyRepository(database: AppDatabase.open())
    }

    private static func success(command: String, result: [String: JSONValue]) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        (
            ActionEnvelope(ok: true, action: command, result: result),
            0
        )
    }

    private static func failure(
        command: String,
        code: String,
        message: String,
        result: [String: JSONValue] = [:],
        exitCode: Int32
    ) -> (ActionEnvelope<[String: JSONValue]>, Int32) {
        (
            ActionEnvelope(
                ok: false,
                action: command,
                result: result,
                error: ActionError(code: code, message: message)
            ),
            exitCode
        )
    }
}
