import Foundation

public enum PrivacyPolicyRepositoryError: Error, LocalizedError {
    case malformedRule(row: Int)

    public var errorDescription: String? {
        switch self {
        case let .malformedRule(row):
            return "Malformed privacy policy rule at row \(row)."
        }
    }
}

public final class PrivacyPolicyRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func snapshot() throws -> PrivacyPolicySnapshot {
        let rules = try loadRules()
        let revision = Int64(
            rules
                .map { Int($0.updatedAt.timeIntervalSince1970) }
                .max() ?? 0
        )
        return PrivacyPolicySnapshot(
            allowedBundleIDs: Set(rules.compactMap { rule in
                rule.subject.type == .bundleID && rule.policy == .allowed ? rule.subject.identifier : nil
            }),
            restrictedBundleIDs: Set(rules.compactMap { rule in
                rule.subject.type == .bundleID && rule.policy == .restricted ? rule.subject.identifier : nil
            }),
            allowedAppPathHashes: Set(rules.compactMap { rule in
                rule.subject.isPathScoped && rule.policy == .allowed ? rule.subject.identifier : nil
            }),
            restrictedAppPathHashes: Set(rules.compactMap { rule in
                rule.subject.isPathScoped && rule.policy == .restricted ? rule.subject.identifier : nil
            }),
            generatedAt: Date(),
            revision: revision
        )
    }

    public func loadRules() throws -> [PrivacyPolicyRule] {
        try database.connection.withStatement(
            """
            SELECT subject_ref, subject_type, identifier, display_name, policy, path_hash, path_summary, source_directory, updated_at
            FROM privacy_policy_rules
            ORDER BY updated_at DESC, subject_ref ASC
            """
        ) { statement in
            var rules: [PrivacyPolicyRule] = []
            var row = 0
            while try statement.step() {
                row += 1
                guard
                    let subjectRef = statement.columnString(0),
                    !subjectRef.isEmpty,
                    let rawType = statement.columnString(1),
                    let subjectType = PrivacyPolicySubjectType(rawValue: rawType),
                    let identifier = statement.columnString(2),
                    !identifier.isEmpty,
                    let rawPolicy = statement.columnString(4),
                    let policy = PrivacyPolicyStatus(rawValue: rawPolicy)
                else {
                    throw PrivacyPolicyRepositoryError.malformedRule(row: row)
                }
                let sourceDirectory: PrivacyAppSourceDirectory?
                if let rawSourceDirectory = statement.columnString(7) {
                    guard let parsed = PrivacyAppSourceDirectory(rawValue: rawSourceDirectory) else {
                        throw PrivacyPolicyRepositoryError.malformedRule(row: row)
                    }
                    sourceDirectory = parsed
                } else {
                    sourceDirectory = nil
                }
                let updatedAtInterval = statement.columnDouble(8)
                guard updatedAtInterval.isFinite else {
                    throw PrivacyPolicyRepositoryError.malformedRule(row: row)
                }
                let subject = PrivacyPolicySubject(
                    subjectRef: subjectRef,
                    type: subjectType,
                    identifier: identifier,
                    displayName: statement.columnString(3),
                    pathHash: statement.columnString(5),
                    pathSummary: statement.columnString(6),
                    sourceDirectory: sourceDirectory
                )
                rules.append(
                    PrivacyPolicyRule(
                        subject: subject,
                        policy: policy,
                        updatedAt: Date(timeIntervalSince1970: updatedAtInterval)
                    )
                )
            }
            return rules
        }
    }

    @discardableResult
    public func migrateLegacyRestrictedBundleIDs(
        _ bundleIdentifiers: [String],
        updatedAt: Date = Date()
    ) throws -> Int {
        let subjects = bundleIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .reduce(into: [String]()) { result, bundleIdentifier in
                if result.last != bundleIdentifier {
                    result.append(bundleIdentifier)
                }
            }
            .map { PrivacySubjectResolver.bundleSubject(bundleIdentifier: $0, displayName: $0) }

        guard !subjects.isEmpty else {
            return 0
        }

        let now = updatedAt.timeIntervalSince1970
        try database.connection.transaction {
            for subject in subjects {
                try database.connection.withStatement(
                    """
                    INSERT INTO privacy_policy_rules (
                        subject_ref,
                        subject_type,
                        identifier,
                        display_name,
                        policy,
                        path_hash,
                        path_summary,
                        source_directory,
                        created_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(subject_ref) DO NOTHING
                    """,
                    bindings: [
                        .string(subject.subjectRef),
                        .string(subject.type.rawValue),
                        .string(subject.identifier),
                        optionalString(subject.displayName),
                        .string(PrivacyPolicyStatus.restricted.rawValue),
                        .null,
                        .null,
                        .null,
                        .double(now),
                        .double(now),
                    ]
                ) { statement in
                    _ = try statement.step()
                }
            }
        }
        return subjects.count
    }

    public func rule(subjectRef: String) throws -> PrivacyPolicyRule? {
        try loadRules().first { $0.subject.subjectRef == subjectRef }
    }

    @discardableResult
    public func applyPolicy(
        subject: PrivacyPolicySubject,
        policy: PrivacyPolicyStatus,
        dryRun: Bool = false
    ) throws -> PrivacyPolicyMutationResult {
        let before = try rule(subjectRef: subject.subjectRef)?.policy ?? .defaultPolicy
        guard !dryRun else {
            return PrivacyPolicyMutationResult(
                subjectRef: subject.subjectRef,
                policyBefore: before,
                policyAfter: policy,
                mutationPerformed: false,
                requiresConfirmation: true
            )
        }
        let now = Date().timeIntervalSince1970
        if policy == .defaultPolicy {
            try database.connection.withStatement(
                "DELETE FROM privacy_policy_rules WHERE subject_ref = ?",
                bindings: [.string(subject.subjectRef)]
            ) { statement in
                _ = try statement.step()
            }
        } else {
            try database.connection.withStatement(
                """
                INSERT INTO privacy_policy_rules (
                    subject_ref,
                    subject_type,
                    identifier,
                    display_name,
                    policy,
                    path_hash,
                    path_summary,
                    source_directory,
                    created_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(subject_ref) DO UPDATE SET
                    display_name = excluded.display_name,
                    policy = excluded.policy,
                    path_hash = excluded.path_hash,
                    path_summary = excluded.path_summary,
                    source_directory = excluded.source_directory,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .string(subject.subjectRef),
                    .string(subject.type.rawValue),
                    .string(subject.identifier),
                    optionalString(subject.displayName),
                    .string(policy.rawValue),
                    optionalString(subject.pathHash),
                    optionalString(subject.pathSummary),
                    optionalString(subject.sourceDirectory?.rawValue),
                    .double(now),
                    .double(now),
                ]
            ) { statement in
                _ = try statement.step()
            }
        }
        return PrivacyPolicyMutationResult(
            subjectRef: subject.subjectRef,
            policyBefore: before,
            policyAfter: policy,
            mutationPerformed: true,
            requiresConfirmation: false
        )
    }

    private func optionalString(_ value: String?) -> SQLiteBinding {
        guard let value else {
            return .null
        }
        return .string(value)
    }
}

private extension PrivacyPolicySubject {
    var isPathScoped: Bool {
        switch type {
        case .appPath, .appBundle:
            return true
        case .bundleID, .commandPath, .loginItem, .helper, .launchLabel:
            return false
        }
    }
}
