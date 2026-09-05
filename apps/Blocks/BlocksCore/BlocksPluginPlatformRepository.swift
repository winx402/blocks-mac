import Foundation

/// Produces bounded, secret-safe data for plugin diagnostics persisted outside
/// the plugin process. Error text is untrusted plugin-controlled input and is
/// therefore represented only by its bounded structural classification.
public enum BlocksPluginLogRedactor {
    public static let maximumStringLength = 4_096

    /// Summarizes an untrusted plugin value without retaining content,
    /// field names, element structure, or a correlation hash. This is kept
    /// separate from `sanitize`: callers use it at an explicit untrusted
    /// payload persistence boundary, while the debug store continues to
    /// support existing host-produced audit projections.
    public static func structuralSummary(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .string(string):
            return .object([
                "type": .string("string"),
                "utf8_bytes": .int(string.utf8.count),
            ])
        case let .array(values):
            return .object([
                "type": .string("array"),
                "count": .int(values.count),
            ])
        case let .object(object):
            return .object([
                "type": .string("object"),
                "field_count": .int(object.count),
            ])
        case .int, .double:
            return .object(["type": .string("number")])
        case .bool:
            return .object(["type": .string("bool")])
        case .null:
            return .object(["type": .string("null")])
        }
    }

    public static func structuralSummary(
        _ value: [String: JSONValue]
    ) -> JSONValue {
        structuralSummary(.object(value))
    }

    public static func errorSummary(
        _ error: Error,
        category: String,
        code: String
    ) -> [String: JSONValue] {
        let message = error.localizedDescription
        return [
            "error_category": .string(category),
            "error_code": .string(boundedCode(code)),
            "error_message_length": .int(message.utf8.count),
        ]
    }

    public static func sanitize(_ value: [String: JSONValue]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: value.map { key, value in
            let lowered = key.lowercased()
            let normalized = lowered.replacingOccurrences(
                of: "[^a-z0-9]",
                with: "",
                options: .regularExpression
            )
            if [
                "authorization", "cookie", "password", "passwd",
                "secret", "token", "apikey", "accesskey", "credential",
                "bookmark",
            ].contains(where: normalized.contains) {
                return (key, .string("<redacted>"))
            }
            if normalized == "error" || normalized == "errordetail"
                || normalized.hasSuffix("errormessage")
                || normalized.hasSuffix("errortext") {
                return (key, .string("<redacted_error_text>"))
            }
            return (key, sanitize(value))
        })
    }

    public static func sanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object): return .object(sanitize(object))
        case let .array(values): return .array(values.map(sanitize))
        case let .string(string): return .string(sanitizeString(string))
        default: return value
        }
    }

    private static func sanitizeString(_ value: String) -> String {
        var result = value
        for pattern in [
            "(?i)[\\\"']?(?:authorization|cookie|set-cookie|password|passwd|secret|api[ _-]?key|access[ _-]?key|access[ _-]?token|token)[\\\"']?\\s*[:=]\\s*[\\\"']?[^\\\"'&\\s,;}]+[\\\"']?",
            "(?i)\\bbearer\\s+[A-Za-z0-9._~+/-]+=*",
            "(?i)https?://[^\\s?#]+[?#][^\\s]+",
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        return String(result.prefix(maximumStringLength))
    }

    private static func boundedCode(_ value: String) -> String {
        String(value.prefix(128)).replacingOccurrences(
            of: "[^A-Za-z0-9_.-]",
            with: "_",
            options: .regularExpression
        )
    }

}

public struct BlocksPluginHookBinding: Equatable, Sendable, Identifiable {
    public var id: String { "\(pluginID):\(hookID)" }
    public let pluginID: String
    public let hookID: String
    public let event: BlocksPluginEventName
    public let sortOrder: Int
    public let isEnabled: Bool
    public let timeoutMilliseconds: Int
    public let failurePolicy: BlocksPluginFailurePolicy
    public let safetyDisabled: Bool
    public let consecutiveFailureCount: Int

    public init(
        pluginID: String,
        hookID: String,
        event: BlocksPluginEventName,
        sortOrder: Int,
        isEnabled: Bool,
        timeoutMilliseconds: Int,
        failurePolicy: BlocksPluginFailurePolicy,
        safetyDisabled: Bool = false,
        consecutiveFailureCount: Int = 0
    ) {
        self.pluginID = pluginID
        self.hookID = hookID
        self.event = event
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.timeoutMilliseconds = timeoutMilliseconds
        self.failurePolicy = failurePolicy
        self.safetyDisabled = safetyDisabled
        self.consecutiveFailureCount = consecutiveFailureCount
    }
}

public struct BlocksPluginStoredValue: Equatable, Sendable {
    public let value: JSONValue
    public let revision: Int64
    public let updatedAt: Date
}

public struct BlocksPluginQueueResult: Equatable, Sendable {
    public let value: JSONValue?
    public let remainingCount: Int
    public let revision: Int64

    public init(value: JSONValue?, remainingCount: Int, revision: Int64) {
        self.value = value
        self.remainingCount = remainingCount
        self.revision = revision
    }
}

public struct BlocksPluginScheduleBinding: Equatable, Sendable, Identifiable {
    public var id: String { "\(pluginID):\(scheduleID)" }
    public let pluginID: String
    public let scheduleID: String
    public let kind: BlocksPluginScheduleKind
    public let configuration: [String: JSONValue]
    public let isEnabled: Bool
    public let nextFireAt: Date?
    public let lastFiredAt: Date?

    public init(
        pluginID: String,
        scheduleID: String,
        kind: BlocksPluginScheduleKind,
        configuration: [String: JSONValue],
        isEnabled: Bool,
        nextFireAt: Date? = nil,
        lastFiredAt: Date? = nil
    ) {
        self.pluginID = pluginID
        self.scheduleID = scheduleID
        self.kind = kind
        self.configuration = configuration
        self.isEnabled = isEnabled
        self.nextFireAt = nextFireAt
        self.lastFiredAt = lastFiredAt
    }
}

public enum BlocksPluginPlatformRepositoryError: Error, LocalizedError, Equatable {
    case pluginNotFound(String)
    case hookNotFound(String)
    case namespaceAccessDenied(String)
    case storageKindNotDeclared(BlocksPluginStorageKind)
    case revisionConflict(expected: Int64, actual: Int64)
    case storageQuotaExceeded
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case let .pluginNotFound(id): return "Plugin not found: \(id)."
        case let .hookNotFound(id): return "Plugin hook not found: \(id)."
        case let .namespaceAccessDenied(namespace):
            return "Access to shared namespace \(namespace) was denied."
        case let .storageKindNotDeclared(kind):
            return "The plugin did not declare \(kind.rawValue) storage."
        case let .revisionConflict(expected, actual):
            return "Plugin state revision conflict (expected \(expected), actual \(actual))."
        case .storageQuotaExceeded:
            return "The plugin storage quota was exceeded."
        case .invalidStoredValue: return "The stored plugin value is invalid."
        }
    }
}

/// Host-enforced logical plugin-state quotas. Logical bytes are the UTF-8
/// bytes of `namespace`, `key` and canonical `value_json`, not SQLite file use.
enum BlocksPluginStorageQuota {
    static let maximumNamespaceUTF8Bytes = 128
    static let maximumKeyUTF8Bytes = 256
    static let maximumValueJSONUTF8Bytes = 1_048_576
    static let maximumQueueItemJSONUTF8Bytes = 65_536
    static let maximumQueueItems = 256
    static let maximumPluginEntries = 4_096
    static let maximumPluginLogicalUTF8Bytes = 8_388_608
}

public final class BlocksPluginPlatformRepository: @unchecked Sendable {
    private let database: AppDatabase

    private struct PrivateStorageRecord {
        let revision: Int64
        let logicalUTF8Bytes: Int64
        let namespaceUTF8Bytes: Int64
        let keyUTF8Bytes: Int64
        let valueJSONUTF8Bytes: Int64

        var exceedsRowQuota: Bool {
            namespaceUTF8Bytes
                > BlocksPluginStorageQuota.maximumNamespaceUTF8Bytes
                || keyUTF8Bytes
                > BlocksPluginStorageQuota.maximumKeyUTF8Bytes
                || valueJSONUTF8Bytes
                > BlocksPluginStorageQuota.maximumValueJSONUTF8Bytes
        }
    }

    public init(database: AppDatabase) {
        self.database = database
    }

    public func synchronizeManifest(
        pluginID: String,
        platform: BlocksPluginPlatformConfiguration?
    ) throws {
        try database.connection.transaction {
            try validateSharedStateDeclarations(
                pluginID: pluginID,
                platform: platform
            )
            try revokeConsumerACLsNoLongerExported(
                ownerPluginID: pluginID,
                platform: platform
            )
            let hooks = platform?.hooks ?? []
            let existing = try readBindings(
                whereClause: "WHERE binding.plugin_id = ?",
                bindings: [.string(pluginID)],
                runnableOnly: false
            )
            let desiredIDs = Set(hooks.map(\.id))
            for binding in existing where !desiredIDs.contains(binding.hookID) {
                try execute(
                    "DELETE FROM plugin_hook_bindings WHERE plugin_id = ? AND hook_id = ?",
                    [.string(pluginID), .string(binding.hookID)]
                )
            }
            for (index, hook) in hooks.enumerated() {
                try execute(
                    """
                    INSERT INTO plugin_hook_bindings (
                        plugin_id, hook_id, event_name, sort_order,
                        is_enabled, timeout_ms, failure_policy
                    ) VALUES (?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(plugin_id, hook_id) DO UPDATE SET
                        event_name = excluded.event_name,
                        timeout_ms = excluded.timeout_ms,
                        failure_policy = excluded.failure_policy
                    """,
                    [
                        .string(pluginID), .string(hook.id),
                        .string(hook.event.rawValue), .int(index),
                        .int(hook.timeoutMilliseconds),
                        .string(hook.failurePolicy.rawValue),
                    ]
                )
            }

            let schedules = platform?.schedules ?? []
            let desiredScheduleIDs = Set(schedules.map(\.id))
            let existingScheduleIDs = try database.connection.withStatement(
                "SELECT schedule_id FROM plugin_schedules WHERE plugin_id = ?",
                bindings: [.string(pluginID)]
            ) { statement in
                var values: [String] = []
                while try statement.step() {
                    if let value = statement.columnString(0) {
                        values.append(value)
                    }
                }
                return values
            }
            for scheduleID in existingScheduleIDs
                where !desiredScheduleIDs.contains(scheduleID) {
                try execute(
                    "DELETE FROM plugin_schedules WHERE plugin_id = ? AND schedule_id = ?",
                    [.string(pluginID), .string(scheduleID)]
                )
            }
            for schedule in schedules {
                try execute(
                    """
                    INSERT INTO plugin_schedules (
                        plugin_id, schedule_id, kind, configuration_json, is_enabled
                    ) VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(plugin_id, schedule_id) DO UPDATE SET
                        kind = excluded.kind,
                        configuration_json = excluded.configuration_json
                    """,
                    [
                        .string(pluginID), .string(schedule.id),
                        .string(schedule.kind.rawValue),
                        .string(try encode(schedule.configuration)),
                    ]
                )
            }

            try execute(
                "DELETE FROM plugin_shared_state_acl WHERE consumer_plugin_id = ?",
                [.string(pluginID)]
            )
            for declaration in platform?.sharedState ?? [] {
                guard let ownerPluginID = declaration.ownerPluginID,
                      ownerPluginID != pluginID else { continue }
                try grantSharedNamespace(
                    ownerPluginID: ownerPluginID,
                    namespace: declaration.id,
                    consumerPluginID: pluginID,
                    access: declaration.access
                )
            }
        }
    }

    public func hookBindings(for event: BlocksPluginEventName) throws -> [BlocksPluginHookBinding] {
        try readBindings(
            whereClause: "WHERE binding.event_name = ?",
            bindings: [.string(event.rawValue)]
        )
    }

    public func hookBindings(pluginID: String) throws -> [BlocksPluginHookBinding] {
        try readBindings(
            whereClause: "WHERE binding.plugin_id = ?",
            bindings: [.string(pluginID)],
            runnableOnly: false
        )
    }

    public func setHookEnabled(
        _ enabled: Bool,
        pluginID: String,
        hookID: String
    ) throws {
        guard try database.connection.firstInt(
            "SELECT COUNT(*) FROM plugin_hook_bindings WHERE plugin_id = ? AND hook_id = ?",
            bindings: [.string(pluginID), .string(hookID)]
        ) == 1 else {
            throw BlocksPluginPlatformRepositoryError.hookNotFound(hookID)
        }
        if enabled {
            try execute(
                """
                UPDATE plugin_hook_bindings
                SET is_enabled = 1, safety_disabled = 0,
                    consecutive_failure_count = 0
                WHERE plugin_id = ? AND hook_id = ?
                """,
                [.string(pluginID), .string(hookID)]
            )
        } else {
            try execute(
                "UPDATE plugin_hook_bindings SET is_enabled = 0 WHERE plugin_id = ? AND hook_id = ?",
                [.string(pluginID), .string(hookID)]
            )
        }
    }

    public func reorderHooks(
        event: BlocksPluginEventName,
        orderedBindingIDs: [String]
    ) throws {
        let current = try hookBindings(for: event)
        guard Set(current.map(\.id)) == Set(orderedBindingIDs),
              current.count == orderedBindingIDs.count else {
            throw BlocksPluginPlatformRepositoryError.hookNotFound(event.rawValue)
        }
        try database.connection.transaction {
            for (index, bindingID) in orderedBindingIDs.enumerated() {
                guard let binding = current.first(where: { $0.id == bindingID }) else { continue }
                try execute(
                    "UPDATE plugin_hook_bindings SET sort_order = ? WHERE plugin_id = ? AND hook_id = ?",
                    [.int(index), .string(binding.pluginID), .string(binding.hookID)]
                )
            }
        }
    }

    public func setDebugEnabled(_ enabled: Bool, pluginID: String) throws {
        try requirePlugin(pluginID)
        try execute(
            "UPDATE plugin_metadata SET debug_enabled = ?, updated_at = ? WHERE id = ?",
            [.bool(enabled), .double(Date().timeIntervalSince1970), .string(pluginID)]
        )
    }

    public func scheduleBindings(
        pluginID: String? = nil,
        runnableOnly: Bool = true
    ) throws -> [BlocksPluginScheduleBinding] {
        var whereParts: [String] = []
        var bindings: [SQLiteBinding] = []
        if let pluginID {
            whereParts.append("schedule.plugin_id = ?")
            bindings.append(.string(pluginID))
        }
        if runnableOnly {
            whereParts.append("schedule.is_enabled = 1")
            whereParts.append("plugin.is_enabled = 1")
            whereParts.append("plugin.approval_status = 'approved'")
            whereParts.append("plugin.safety_disabled = 0")
        }
        let whereClause = whereParts.isEmpty
            ? ""
            : "WHERE " + whereParts.joined(separator: " AND ")
        return try database.connection.withStatement(
            """
            SELECT schedule.plugin_id, schedule.schedule_id, schedule.kind,
                   schedule.configuration_json, schedule.is_enabled,
                   schedule.next_fire_at, schedule.last_fired_at
            FROM plugin_schedules AS schedule
            JOIN plugin_metadata AS plugin ON plugin.id = schedule.plugin_id
            \(whereClause)
            ORDER BY schedule.plugin_id, schedule.schedule_id
            """,
            bindings: bindings
        ) { statement in
            var result: [BlocksPluginScheduleBinding] = []
            while try statement.step() {
                guard let pluginID = statement.columnString(0),
                      let scheduleID = statement.columnString(1),
                      let rawKind = statement.columnString(2),
                      let kind = BlocksPluginScheduleKind(rawValue: rawKind),
                      let configurationJSON = statement.columnString(3)
                else {
                    throw BlocksPluginPlatformRepositoryError.invalidStoredValue
                }
                result.append(BlocksPluginScheduleBinding(
                    pluginID: pluginID,
                    scheduleID: scheduleID,
                    kind: kind,
                    configuration: try decodeObject(configurationJSON),
                    isEnabled: statement.columnBool(4),
                    nextFireAt: statement.columnString(5)
                        .flatMap(Double.init)
                        .map(Date.init(timeIntervalSince1970:)),
                    lastFiredAt: statement.columnString(6)
                        .flatMap(Double.init)
                        .map(Date.init(timeIntervalSince1970:))
                ))
            }
            return result
        }
    }

    public func setScheduleEnabled(
        _ enabled: Bool,
        pluginID: String,
        scheduleID: String
    ) throws {
        guard try database.connection.firstInt(
            "SELECT COUNT(*) FROM plugin_schedules WHERE plugin_id = ? AND schedule_id = ?",
            bindings: [.string(pluginID), .string(scheduleID)]
        ) == 1 else {
            throw BlocksPluginPlatformRepositoryError.hookNotFound(scheduleID)
        }
        try execute(
            "UPDATE plugin_schedules SET is_enabled = ?, next_fire_at = NULL WHERE plugin_id = ? AND schedule_id = ?",
            [.bool(enabled), .string(pluginID), .string(scheduleID)]
        )
    }

    public func updateScheduleTiming(
        pluginID: String,
        scheduleID: String,
        nextFireAt: Date?,
        lastFiredAt: Date?
    ) throws {
        try execute(
            """
            UPDATE plugin_schedules
            SET next_fire_at = CASE
                    WHEN is_enabled = 1 THEN ?
                    ELSE NULL
                END,
                last_fired_at = COALESCE(?, last_fired_at)
            WHERE plugin_id = ? AND schedule_id = ?
            """,
            [
                nextFireAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                lastFiredAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .string(pluginID), .string(scheduleID),
            ]
        )
    }

    public func hasApprovedPermission(
        pluginID: String,
        token: String
    ) throws -> Bool {
        try requirePlugin(pluginID)
        guard let raw = try database.connection.firstString(
            "SELECT approved_permissions_json FROM plugin_metadata WHERE id = ?",
            bindings: [.string(pluginID)]
        ), let data = raw.data(using: .utf8) else {
            throw BlocksPluginPlatformRepositoryError.invalidStoredValue
        }
        let permissions = try JSONDecoder().decode(
            [String].self,
            from: data
        )
        return permissions.contains(token)
    }

    @discardableResult
    public func recordExecutionOutcome(
        pluginID: String,
        succeeded: Bool,
        disableThreshold: Int = 3
    ) throws -> Bool {
        try requirePlugin(pluginID)
        if succeeded {
            try execute(
                "UPDATE plugin_metadata SET consecutive_failure_count = 0 WHERE id = ?",
                [.string(pluginID)]
            )
            return false
        }
        try execute(
            """
            UPDATE plugin_metadata
            SET consecutive_failure_count = consecutive_failure_count + 1,
                safety_disabled = CASE
                    WHEN consecutive_failure_count + 1 >= ? THEN 1 ELSE safety_disabled
                END,
                updated_at = ?
            WHERE id = ?
            """,
            [.int(max(1, disableThreshold)), .double(Date().timeIntervalSince1970), .string(pluginID)]
        )
        return try database.connection.firstInt(
            "SELECT safety_disabled FROM plugin_metadata WHERE id = ?",
            bindings: [.string(pluginID)]
        ) == 1
    }

    public func clearSafetyDisable(pluginID: String) throws {
        try requirePlugin(pluginID)
        try execute(
            "UPDATE plugin_metadata SET safety_disabled = 0, consecutive_failure_count = 0 WHERE id = ?",
            [.string(pluginID)]
        )
    }

    /// Keeps the durable safety counter and its audit projection indivisible.
    /// Callers use the returned cutoff to publish the matching MainActor gate.
    public func recordExecutionOutcomeAndAppendAudit(
        pluginID: String, succeeded: Bool, disableThreshold: Int = 3,
        eventID: UUID? = nil, requestID: UUID? = nil, causationID: UUID? = nil,
        level: BlocksPluginDiagnosticLevel, category: String, outcome: String,
        durationMilliseconds: Double? = nil, metadata: [String: JSONValue] = [:]
    ) throws -> Bool {
        try database.connection.transaction {
            let disabled = try recordExecutionOutcome(
                pluginID: pluginID, succeeded: succeeded,
                disableThreshold: disableThreshold
            )
            try appendAuditUnchecked(pluginID: pluginID, eventID: eventID,
                                     requestID: requestID, causationID: causationID,
                                     level: level, category: category, outcome: outcome,
                                     durationMilliseconds: durationMilliseconds,
                                     metadata: metadata)
            return disabled
        }
    }

    /// Records failures at Hook granularity. A repeatedly failing Hook is
    /// disabled without taking unrelated actions, UI or schedules from the
    /// same plugin offline.
    @discardableResult
    public func recordHookExecutionOutcome(
        pluginID: String,
        hookID: String,
        succeeded: Bool,
        disableThreshold: Int = 3,
        now: Date = Date()
    ) throws -> Bool {
        try requirePlugin(pluginID)
        guard try database.connection.firstInt(
            "SELECT COUNT(*) FROM plugin_hook_bindings WHERE plugin_id = ? AND hook_id = ?",
            bindings: [.string(pluginID), .string(hookID)]
        ) == 1 else {
            throw BlocksPluginPlatformRepositoryError.hookNotFound(hookID)
        }
        if succeeded {
            try execute(
                """
                UPDATE plugin_hook_bindings
                SET consecutive_failure_count = 0
                WHERE plugin_id = ? AND hook_id = ?
                """,
                [.string(pluginID), .string(hookID)]
            )
            return false
        }
        try execute(
            """
            UPDATE plugin_hook_bindings
            SET consecutive_failure_count = consecutive_failure_count + 1,
                safety_disabled = CASE
                    WHEN consecutive_failure_count + 1 >= ? THEN 1
                    ELSE safety_disabled
                END,
                is_enabled = CASE
                    WHEN consecutive_failure_count + 1 >= ? THEN 0
                    ELSE is_enabled
                END,
                last_failure_at = ?
            WHERE plugin_id = ? AND hook_id = ?
            """,
            [
                .int(max(1, disableThreshold)),
                .int(max(1, disableThreshold)),
                .double(now.timeIntervalSince1970),
                .string(pluginID), .string(hookID),
            ]
        )
        return try database.connection.firstInt(
            "SELECT safety_disabled FROM plugin_hook_bindings WHERE plugin_id = ? AND hook_id = ?",
            bindings: [.string(pluginID), .string(hookID)]
        ) == 1
    }

    public func recordHookExecutionOutcomeAndAppendAudit(
        pluginID: String, hookID: String, succeeded: Bool,
        disableThreshold: Int = 3, eventID: UUID? = nil,
        requestID: UUID? = nil, causationID: UUID? = nil,
        level: BlocksPluginDiagnosticLevel, category: String, outcome: String,
        durationMilliseconds: Double? = nil, metadata: [String: JSONValue] = [:]
    ) throws -> Bool {
        try database.connection.transaction {
            let disabled = try recordHookExecutionOutcome(
                pluginID: pluginID, hookID: hookID, succeeded: succeeded,
                disableThreshold: disableThreshold
            )
            try appendAuditUnchecked(pluginID: pluginID, eventID: eventID,
                                     requestID: requestID, causationID: causationID,
                                     level: level, category: category, outcome: outcome,
                                     durationMilliseconds: durationMilliseconds,
                                     metadata: metadata)
            return disabled
        }
    }

    @discardableResult
    public func putPrivateValue(
        pluginID: String,
        namespace: String = "default",
        key: String,
        value: JSONValue,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginStoredValue {
        try database.connection.transaction {
            try requirePlugin(pluginID)
            let current = try privateStorageRecord(
                pluginID: pluginID,
                namespace: namespace,
                key: key
            )
            if let expectedRevision,
               (current?.revision ?? 0) != expectedRevision {
                throw BlocksPluginPlatformRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: current?.revision ?? 0
                )
            }
            let encodedValue = try encode(value)
            try requirePrivateStorageQuota(
                pluginID: pluginID,
                namespace: namespace,
                key: key,
                encodedValue: encodedValue,
                current: current
            )
            let nextRevision: Int64
            if let expectedRevision {
                let sql: String
                let bindings: [SQLiteBinding]
                if expectedRevision == 0 {
                    sql = """
                    INSERT INTO plugin_storage (
                        plugin_id, namespace, key, value_json, revision, updated_at
                    ) VALUES (?, ?, ?, ?, 1, ?)
                    ON CONFLICT(plugin_id, namespace, key) DO NOTHING
                    RETURNING revision
                    """
                    bindings = [
                        .string(pluginID), .string(namespace), .string(key),
                        .string(encodedValue), .double(now.timeIntervalSince1970),
                    ]
                } else {
                    sql = """
                    UPDATE plugin_storage
                    SET value_json = ?, revision = revision + 1, updated_at = ?
                    WHERE plugin_id = ? AND namespace = ? AND key = ?
                        AND revision = ?
                    RETURNING revision
                    """
                    bindings = [
                        .string(encodedValue), .double(now.timeIntervalSince1970),
                        .string(pluginID), .string(namespace), .string(key),
                        .int64(expectedRevision),
                    ]
                }
                nextRevision = try database.connection.withStatement(
                    sql,
                    bindings: bindings
                ) { statement in
                    guard try statement.step() else {
                        let actual = try privateValue(
                            pluginID: pluginID,
                            namespace: namespace,
                            key: key
                        )?.revision ?? 0
                        throw BlocksPluginPlatformRepositoryError.revisionConflict(
                            expected: expectedRevision,
                            actual: actual
                        )
                    }
                    return statement.columnInt64(0)
                }
            } else {
                nextRevision = try database.connection.withStatement(
                    """
                    INSERT INTO plugin_storage (
                        plugin_id, namespace, key, value_json, revision, updated_at
                    ) VALUES (?, ?, ?, ?, 1, ?)
                    ON CONFLICT(plugin_id, namespace, key) DO UPDATE SET
                        value_json = excluded.value_json,
                        revision = plugin_storage.revision + 1,
                        updated_at = excluded.updated_at
                    RETURNING revision
                    """,
                    bindings: [
                        .string(pluginID), .string(namespace), .string(key),
                        .string(encodedValue), .double(now.timeIntervalSince1970),
                    ]
                ) { statement in
                    guard try statement.step() else {
                        throw BlocksPluginPlatformRepositoryError.invalidStoredValue
                    }
                    return statement.columnInt64(0)
                }
            }
            return BlocksPluginStoredValue(
                value: value,
                revision: nextRevision,
                updatedAt: now
            )
        }
    }

    /// Runtime-only write entry point.  Unlike the storage API above, this
    /// rechecks the actor's lifecycle and granted token in the very same
    /// SQLite transaction as the CAS write, so a stale XPC handler cannot
    /// pass a permission read and commit after disable/revocation.
    @discardableResult
    public func putPrivateValueForRuntime(
        pluginID: String,
        namespace: String = "default",
        key: String,
        value: JSONValue,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginStoredValue {
        try database.connection.transaction {
            try requireRunnableApprovedStorageKind(
                pluginID: pluginID,
                kind: .keyValue
            )
            return try putPrivateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key,
                value: value,
                expectedRevision: expectedRevision,
                now: now
            )
        }
    }

    public func privateValue(
        pluginID: String,
        namespace: String = "default",
        key: String
    ) throws -> BlocksPluginStoredValue? {
        try database.connection.withStatement(
            """
            SELECT value_json, revision, updated_at FROM plugin_storage
            WHERE plugin_id = ? AND namespace = ? AND key = ?
            """,
            bindings: [.string(pluginID), .string(namespace), .string(key)]
        ) { statement in
            guard try statement.step(), let json = statement.columnString(0) else { return nil }
            return BlocksPluginStoredValue(
                value: try decodeValue(json),
                revision: statement.columnInt64(1),
                updatedAt: Date(timeIntervalSince1970: statement.columnDouble(2))
            )
        }
    }

    public func privateValueForRuntime(
        pluginID: String,
        namespace: String = "default",
        key: String
    ) throws -> BlocksPluginStoredValue? {
        try database.connection.transaction {
            try requireRunnableApprovedStorageKind(
                pluginID: pluginID,
                kind: .keyValue
            )
            return try privateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key
            )
        }
    }

    /// Appends an item to a host-managed FIFO queue. The queue is stored in the
    /// plugin's private namespace and updated atomically with its CAS revision.
    @discardableResult
    public func enqueuePrivateValue(
        pluginID: String,
        namespace: String = "default",
        key: String,
        value: JSONValue,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginQueueResult {
        try database.connection.transaction {
            let currentRecord = try privateStorageRecord(
                pluginID: pluginID,
                namespace: namespace,
                key: key
            )
            if let expectedRevision,
               (currentRecord?.revision ?? 0) != expectedRevision {
                throw BlocksPluginPlatformRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: currentRecord?.revision ?? 0
                )
            }
            let encodedItem = try encode(value)
            guard encodedItem.utf8.count
                <= BlocksPluginStorageQuota.maximumQueueItemJSONUTF8Bytes else {
                throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
            }
            let current = try privateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key
            )
            let values: [JSONValue]
            if let current {
                guard case let .array(existing) = current.value else {
                    throw BlocksPluginPlatformRepositoryError.invalidStoredValue
                }
                try requireValidPrivateQueue(existing)
                guard existing.count
                    < BlocksPluginStorageQuota.maximumQueueItems else {
                    throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
                }
                values = existing + [value]
            } else {
                values = [value]
            }
            let stored = try putPrivateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key,
                value: .array(values),
                expectedRevision: expectedRevision,
                now: now
            )
            return BlocksPluginQueueResult(
                value: value,
                remainingCount: values.count,
                revision: stored.revision
            )
        }
    }

    @discardableResult
    public func enqueuePrivateValueForRuntime(
        pluginID: String,
        namespace: String = "default",
        key: String,
        value: JSONValue,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginQueueResult {
        try database.connection.transaction {
            try requireRunnableApprovedStorageKind(
                pluginID: pluginID,
                kind: .queue
            )
            return try enqueuePrivateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key,
                value: value,
                expectedRevision: expectedRevision,
                now: now
            )
        }
    }

    /// Removes and returns the oldest queue item. Empty queues are preserved so
    /// consumers can continue using the returned revision for CAS operations.
    @discardableResult
    public func dequeuePrivateValue(
        pluginID: String,
        namespace: String = "default",
        key: String,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginQueueResult {
        try database.connection.transaction {
            let current = try privateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key
            )
            if let expectedRevision,
               (current?.revision ?? 0) != expectedRevision {
                throw BlocksPluginPlatformRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: current?.revision ?? 0
                )
            }
            guard let current else {
                return BlocksPluginQueueResult(
                    value: nil,
                    remainingCount: 0,
                    revision: 0
                )
            }
            guard case var .array(values) = current.value else {
                throw BlocksPluginPlatformRepositoryError.invalidStoredValue
            }
            try requireValidPrivateQueue(values)
            let first = values.isEmpty ? nil : values.removeFirst()
            let stored = try putPrivateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key,
                value: .array(values),
                expectedRevision: current.revision,
                now: now
            )
            return BlocksPluginQueueResult(
                value: first,
                remainingCount: values.count,
                revision: stored.revision
            )
        }
    }

    @discardableResult
    public func dequeuePrivateValueForRuntime(
        pluginID: String,
        namespace: String = "default",
        key: String,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginQueueResult {
        try database.connection.transaction {
            try requireRunnableApprovedStorageKind(
                pluginID: pluginID,
                kind: .queue
            )
            return try dequeuePrivateValue(
                pluginID: pluginID,
                namespace: namespace,
                key: key,
                expectedRevision: expectedRevision,
                now: now
            )
        }
    }

    public func grantSharedNamespace(
        ownerPluginID: String,
        namespace: String,
        consumerPluginID: String,
        access: BlocksPluginSharedStateAccess
    ) throws {
        try requirePlugin(ownerPluginID)
        try requirePlugin(consumerPluginID)
        try requireExportedSharedNamespace(
            ownerPluginID: ownerPluginID,
            namespace: namespace,
            requestedAccess: access
        )
        try execute(
            """
            INSERT INTO plugin_shared_state_acl (
                owner_plugin_id, namespace, consumer_plugin_id, access
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(owner_plugin_id, namespace, consumer_plugin_id)
            DO UPDATE SET access = excluded.access
            """,
            [
                .string(ownerPluginID), .string(namespace),
                .string(consumerPluginID), .string(access.rawValue),
            ]
        )
    }

    @discardableResult
    public func putSharedValue(
        actorPluginID: String,
        ownerPluginID: String,
        namespace: String,
        key: String,
        schemaVersion: Int,
        value: JSONValue,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginStoredValue {
        return try database.connection.transaction {
            try requireSharedAccess(
                actorPluginID: actorPluginID,
                ownerPluginID: ownerPluginID,
                namespace: namespace,
                write: true
            )
            let current = try sharedStorageRecord(
                ownerPluginID: ownerPluginID,
                namespace: namespace,
                key: key
            )
            if let expectedRevision,
               (current?.revision ?? 0) != expectedRevision {
                throw BlocksPluginPlatformRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: current?.revision ?? 0
                )
            }
            let encodedValue = try encode(value)
            try requireSharedStorageQuota(
                ownerPluginID: ownerPluginID,
                namespace: namespace,
                key: key,
                encodedValue: encodedValue,
                current: current
            )
            let nextRevision: Int64
            if let expectedRevision {
                let sql: String
                let bindings: [SQLiteBinding]
                if expectedRevision == 0 {
                    sql = """
                    INSERT INTO plugin_shared_state (
                        owner_plugin_id, namespace, key, schema_version,
                        value_json, revision, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(owner_plugin_id, namespace, key) DO NOTHING
                    RETURNING revision
                    """
                    bindings = [
                        .string(ownerPluginID), .string(namespace), .string(key),
                        .int(schemaVersion), .string(encodedValue),
                        .double(now.timeIntervalSince1970),
                    ]
                } else {
                    sql = """
                    UPDATE plugin_shared_state
                    SET schema_version = ?, value_json = ?, revision = revision + 1,
                        updated_at = ?
                    WHERE owner_plugin_id = ? AND namespace = ? AND key = ?
                        AND revision = ?
                    RETURNING revision
                    """
                    bindings = [
                        .int(schemaVersion), .string(encodedValue),
                        .double(now.timeIntervalSince1970), .string(ownerPluginID),
                        .string(namespace), .string(key), .int64(expectedRevision),
                    ]
                }
                nextRevision = try database.connection.withStatement(
                    sql,
                    bindings: bindings
                ) { statement in
                    guard try statement.step() else {
                        let actual = try sharedValue(
                            actorPluginID: actorPluginID,
                            ownerPluginID: ownerPluginID,
                            namespace: namespace,
                            key: key
                        )?.revision ?? 0
                        throw BlocksPluginPlatformRepositoryError.revisionConflict(
                            expected: expectedRevision,
                            actual: actual
                        )
                    }
                    return statement.columnInt64(0)
                }
            } else {
                nextRevision = try database.connection.withStatement(
                    """
                    INSERT INTO plugin_shared_state (
                        owner_plugin_id, namespace, key, schema_version,
                        value_json, revision, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(owner_plugin_id, namespace, key) DO UPDATE SET
                        schema_version = excluded.schema_version,
                        value_json = excluded.value_json,
                        revision = plugin_shared_state.revision + 1,
                        updated_at = excluded.updated_at
                    RETURNING revision
                    """,
                    bindings: [
                        .string(ownerPluginID), .string(namespace), .string(key),
                        .int(schemaVersion), .string(encodedValue),
                        .double(now.timeIntervalSince1970),
                    ]
                ) { statement in
                    guard try statement.step() else {
                        throw BlocksPluginPlatformRepositoryError.invalidStoredValue
                    }
                    return statement.columnInt64(0)
                }
            }
            return BlocksPluginStoredValue(
                value: value,
                revision: nextRevision,
                updatedAt: now
            )
        }
    }

    /// The owner retains the existing shared-state ownership semantics.  Only
    /// the acting plugin must be runnable and currently approved; ACL and CAS
    /// checks remain the established `putSharedValue` contract.
    @discardableResult
    public func putSharedValueForRuntime(
        actorPluginID: String,
        ownerPluginID: String,
        namespace: String,
        key: String,
        schemaVersion: Int,
        value: JSONValue,
        expectedRevision: Int64? = nil,
        now: Date = Date()
    ) throws -> BlocksPluginStoredValue {
        try database.connection.transaction {
            try requireRunnableApprovedPermission(
                pluginID: actorPluginID,
                acceptedTokens: [
                    "shared:\(ownerPluginID):\(namespace):write",
                    "shared:\(ownerPluginID):\(namespace):read_write",
                ]
            )
            return try putSharedValue(
                actorPluginID: actorPluginID,
                ownerPluginID: ownerPluginID,
                namespace: namespace,
                key: key,
                schemaVersion: schemaVersion,
                value: value,
                expectedRevision: expectedRevision,
                now: now
            )
        }
    }

    public func sharedValue(
        actorPluginID: String,
        ownerPluginID: String,
        namespace: String,
        key: String
    ) throws -> BlocksPluginStoredValue? {
        try database.connection.transaction {
            try requireSharedAccess(
                actorPluginID: actorPluginID,
                ownerPluginID: ownerPluginID,
                namespace: namespace,
                write: false
            )
            return try database.connection.withStatement(
                """
                SELECT value_json, revision, updated_at FROM plugin_shared_state
                WHERE owner_plugin_id = ? AND namespace = ? AND key = ?
                """,
                bindings: [.string(ownerPluginID), .string(namespace), .string(key)]
            ) { statement in
                guard try statement.step(), let json = statement.columnString(0) else {
                    return nil
                }
                return BlocksPluginStoredValue(
                    value: try decodeValue(json),
                    revision: statement.columnInt64(1),
                    updatedAt: Date(timeIntervalSince1970: statement.columnDouble(2))
                )
            }
        }
    }

    public func sharedValueForRuntime(
        actorPluginID: String,
        ownerPluginID: String,
        namespace: String,
        key: String
    ) throws -> BlocksPluginStoredValue? {
        try database.connection.transaction {
            try requireRunnableApprovedPermission(
                pluginID: actorPluginID,
                acceptedTokens: [
                    "shared:\(ownerPluginID):\(namespace):read",
                    "shared:\(ownerPluginID):\(namespace):read_write",
                ]
            )
            return try sharedValue(
                actorPluginID: actorPluginID,
                ownerPluginID: ownerPluginID,
                namespace: namespace,
                key: key
            )
        }
    }

    /// Resource authorization is maintained by the in-memory broker, but the
    /// requesting plugin must still be runnable at the moment a runtime read
    /// begins.
    public func requireRunnableForRuntime(pluginID: String) throws {
        try database.connection.transaction {
            try requireRunnableApprovedPermission(
                pluginID: pluginID,
                acceptedTokens: []
            )
        }
    }

    public func appendAudit(
        pluginID: String,
        eventID: UUID? = nil,
        requestID: UUID? = nil,
        causationID: UUID? = nil,
        level: BlocksPluginDiagnosticLevel,
        category: String,
        outcome: String,
        durationMilliseconds: Double? = nil,
        metadata: [String: JSONValue] = [:],
        now: Date = Date()
    ) throws {
        try appendAuditUnchecked(
            pluginID: pluginID, eventID: eventID, requestID: requestID,
            causationID: causationID, level: level, category: category,
            outcome: outcome, durationMilliseconds: durationMilliseconds,
            metadata: metadata, now: now
        )
    }

    private func appendAuditUnchecked(
        pluginID: String, eventID: UUID? = nil, requestID: UUID? = nil,
        causationID: UUID? = nil, level: BlocksPluginDiagnosticLevel,
        category: String, outcome: String, durationMilliseconds: Double? = nil,
        metadata: [String: JSONValue] = [:], now: Date = Date()
    ) throws {
        try requirePlugin(pluginID)
        try execute(
            """
            INSERT INTO plugin_audit_events (
                id, plugin_id, event_id, request_id, causation_id,
                level, category, outcome, duration_ms, metadata_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .string(UUID().uuidString), .string(pluginID),
                eventID.map { .string($0.uuidString) } ?? .null,
                requestID.map { .string($0.uuidString) } ?? .null,
                causationID.map { .string($0.uuidString) } ?? .null,
                .string(level.rawValue), .string(category), .string(outcome),
                durationMilliseconds.map(SQLiteBinding.double) ?? .null,
                .string(try encode(BlocksPluginLogRedactor.sanitize(metadata))),
                .double(now.timeIntervalSince1970),
            ]
        )
    }

    private func readBindings(
        whereClause: String,
        bindings: [SQLiteBinding],
        runnableOnly: Bool = true
    ) throws -> [BlocksPluginHookBinding] {
        try database.connection.withStatement(
            """
            SELECT binding.plugin_id, binding.hook_id, binding.event_name,
                   binding.sort_order, binding.is_enabled,
                   binding.timeout_ms, binding.failure_policy,
                   binding.safety_disabled,
                   binding.consecutive_failure_count
            FROM plugin_hook_bindings AS binding
            JOIN plugin_metadata AS plugin ON plugin.id = binding.plugin_id
            \(whereClause)
              \(runnableOnly ? "AND plugin.is_enabled = 1 AND plugin.approval_status = 'approved' AND plugin.safety_disabled = 0 AND binding.safety_disabled = 0" : "")
            ORDER BY binding.sort_order, binding.plugin_id, binding.hook_id
            """,
            bindings: bindings
        ) { statement in
            var result: [BlocksPluginHookBinding] = []
            while try statement.step() {
                guard let pluginID = statement.columnString(0),
                      let hookID = statement.columnString(1),
                      let rawEvent = statement.columnString(2),
                      let event = BlocksPluginEventName(rawValue: rawEvent),
                      let rawPolicy = statement.columnString(6),
                      let policy = BlocksPluginFailurePolicy(rawValue: rawPolicy) else {
                    throw BlocksPluginPlatformRepositoryError.invalidStoredValue
                }
                result.append(
                    BlocksPluginHookBinding(
                        pluginID: pluginID,
                        hookID: hookID,
                        event: event,
                        sortOrder: statement.columnInt(3),
                        isEnabled: statement.columnBool(4),
                        timeoutMilliseconds: statement.columnInt(5),
                        failurePolicy: policy,
                        safetyDisabled: statement.columnBool(7),
                        consecutiveFailureCount: statement.columnInt(8)
                    )
                )
            }
            return runnableOnly ? result.filter(\.isEnabled) : result
        }
    }

    private func requirePlugin(_ pluginID: String) throws {
        guard try database.connection.firstInt(
            "SELECT COUNT(*) FROM plugin_metadata WHERE id = ?",
            bindings: [.string(pluginID)]
        ) == 1 else {
            throw BlocksPluginPlatformRepositoryError.pluginNotFound(pluginID)
        }
    }

    private func requireRunnableApprovedPermission(
        pluginID: String,
        acceptedTokens: [String]
    ) throws {
        guard let rawPermissions = try database.connection.firstString(
            """
            SELECT approved_permissions_json FROM plugin_metadata
            WHERE id = ?
              AND is_enabled = 1
              AND approval_status = 'approved'
              AND safety_disabled = 0
            """,
            bindings: [.string(pluginID)]
        ) else {
            throw BlocksPluginPlatformRepositoryError.pluginNotFound(pluginID)
        }
        let permissions = try JSONDecoder().decode(
            [String].self,
            from: Data(rawPermissions.utf8)
        )
        guard acceptedTokens.isEmpty
            || acceptedTokens.contains(where: permissions.contains) else {
            throw BlocksPluginPlatformRepositoryError.namespaceAccessDenied(
                "runtime_permission"
            )
        }
    }

    private func requireRunnableApprovedStorageKind(
        pluginID: String,
        kind: BlocksPluginStorageKind
    ) throws {
        try requireRunnableApprovedPermission(
            pluginID: pluginID,
            acceptedTokens: [BlocksPluginPermissionToken.privateStorage]
        )
        guard let rawManifest = try database.connection.firstString(
            "SELECT manifest_json FROM plugin_metadata WHERE id = ?",
            bindings: [.string(pluginID)]
        ), let manifest = try? JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: Data(rawManifest.utf8)
        ) else {
            throw BlocksPluginPlatformRepositoryError.invalidStoredValue
        }
        guard manifest.platform?.storage?.kinds.contains(kind) == true else {
            throw BlocksPluginPlatformRepositoryError
                .storageKindNotDeclared(kind)
        }
    }

    private func requireSharedAccess(
        actorPluginID: String,
        ownerPluginID: String,
        namespace: String,
        write: Bool
    ) throws {
        if actorPluginID == ownerPluginID { return }
        guard try database.connection.firstInt(
            """
            SELECT COUNT(*) FROM plugin_metadata
            WHERE id = ?
              AND is_enabled = 1
              AND approval_status = 'approved'
              AND safety_disabled = 0
            """,
            bindings: [.string(ownerPluginID)]
        ) == 1 else {
            throw BlocksPluginPlatformRepositoryError.namespaceAccessDenied(namespace)
        }
        let access = try database.connection.firstString(
            """
            SELECT access FROM plugin_shared_state_acl
            WHERE owner_plugin_id = ? AND namespace = ? AND consumer_plugin_id = ?
            """,
            bindings: [
                .string(ownerPluginID), .string(namespace), .string(actorPluginID),
            ]
        )
        let permitted = write
            ? access == BlocksPluginSharedStateAccess.write.rawValue
                || access == BlocksPluginSharedStateAccess.readWrite.rawValue
            : access != nil
        guard permitted else {
            throw BlocksPluginPlatformRepositoryError.namespaceAccessDenied(namespace)
        }
        try requireExportedSharedNamespace(
            ownerPluginID: ownerPluginID,
            namespace: namespace,
            requestedAccess: write ? .write : .read
        )
    }

    /// A consumer declaration is a request, never an authority grant.  The
    /// owner package must currently export the exact namespace and authorize
    /// the requested read/write contract before an ACL row can be created.
    public func validateSharedStateDeclarations(
        pluginID: String,
        platform: BlocksPluginPlatformConfiguration?
    ) throws {
        for declaration in platform?.sharedState ?? [] {
            guard let ownerPluginID = declaration.ownerPluginID,
                  ownerPluginID != pluginID else { continue }
            try requirePlugin(ownerPluginID)
            try requireExportedSharedNamespace(
                ownerPluginID: ownerPluginID,
                namespace: declaration.id,
                requestedAccess: declaration.access
            )
        }
    }

    private func revokeConsumerACLsNoLongerExported(
        ownerPluginID: String,
        platform: BlocksPluginPlatformConfiguration?
    ) throws {
        let existing = try database.connection.withStatement(
            """
            SELECT namespace, consumer_plugin_id, access
            FROM plugin_shared_state_acl
            WHERE owner_plugin_id = ?
            """,
            bindings: [.string(ownerPluginID)]
        ) { statement in
            var rows: [(String, String, BlocksPluginSharedStateAccess)] = []
            while try statement.step() {
                guard let namespace = statement.columnString(0),
                      let consumerPluginID = statement.columnString(1),
                      let rawAccess = statement.columnString(2),
                      let access = BlocksPluginSharedStateAccess(
                        rawValue: rawAccess
                      ) else { continue }
                rows.append((namespace, consumerPluginID, access))
            }
            return rows
        }
        for (namespace, consumerPluginID, access) in existing {
            let export = platform?.sharedState.first {
                $0.id == namespace && $0.ownerPluginID == nil
            }
            guard let export, sharedAccess(export.access, permits: access) else {
                try execute(
                    """
                    DELETE FROM plugin_shared_state_acl
                    WHERE owner_plugin_id = ?
                      AND namespace = ?
                      AND consumer_plugin_id = ?
                    """,
                    [
                        .string(ownerPluginID), .string(namespace),
                        .string(consumerPluginID),
                    ]
                )
                continue
            }
        }
    }

    private func requireExportedSharedNamespace(
        ownerPluginID: String,
        namespace: String,
        requestedAccess: BlocksPluginSharedStateAccess
    ) throws {
        guard let rawManifest = try database.connection.firstString(
            "SELECT manifest_json FROM plugin_metadata WHERE id = ?",
            bindings: [.string(ownerPluginID)]
        ), let ownerManifest = try? JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: Data(rawManifest.utf8)
        ), let exported = ownerManifest.platform?.sharedState.first(where: {
            $0.id == namespace && $0.ownerPluginID == nil
        }), sharedAccess(exported.access, permits: requestedAccess) else {
            throw BlocksPluginPlatformRepositoryError.namespaceAccessDenied(namespace)
        }
    }

    private func sharedAccess(
        _ exported: BlocksPluginSharedStateAccess,
        permits requested: BlocksPluginSharedStateAccess
    ) -> Bool {
        switch (exported, requested) {
        case (.readWrite, _), (.read, .read), (.write, .write):
            true
        default:
            false
        }
    }

    private func privateStorageRecord(
        pluginID: String,
        namespace: String,
        key: String
    ) throws -> PrivateStorageRecord? {
        try database.connection.withStatement(
            """
            SELECT
                revision,
                length(CAST(namespace AS BLOB)),
                length(CAST(key AS BLOB)),
                length(CAST(value_json AS BLOB))
            FROM plugin_storage
            WHERE plugin_id = ? AND namespace = ? AND key = ?
            """,
            bindings: [.string(pluginID), .string(namespace), .string(key)]
        ) { statement in
            guard try statement.step() else { return nil }
            let namespaceUTF8Bytes = statement.columnInt64(1)
            let keyUTF8Bytes = statement.columnInt64(2)
            let valueJSONUTF8Bytes = statement.columnInt64(3)
            return PrivateStorageRecord(
                revision: statement.columnInt64(0),
                logicalUTF8Bytes: namespaceUTF8Bytes
                    + keyUTF8Bytes
                    + valueJSONUTF8Bytes,
                namespaceUTF8Bytes: namespaceUTF8Bytes,
                keyUTF8Bytes: keyUTF8Bytes,
                valueJSONUTF8Bytes: valueJSONUTF8Bytes
            )
        }
    }

    private func privateStorageLogicalUTF8Bytes(
        pluginID: String
    ) throws -> Int64 {
        try database.connection.withStatement(
            """
            SELECT COALESCE(SUM(
                length(CAST(namespace AS BLOB))
                + length(CAST(key AS BLOB))
                + length(CAST(value_json AS BLOB))
            ), 0)
            FROM plugin_storage
            WHERE plugin_id = ?
            """,
            bindings: [.string(pluginID)]
        ) { statement in
            guard try statement.step() else { return 0 }
            return statement.columnInt64(0)
        }
    }

    private func privateStorageEntryCount(
        pluginID: String
    ) throws -> Int64 {
        try database.connection.withStatement(
            "SELECT COUNT(*) FROM plugin_storage WHERE plugin_id = ?",
            bindings: [.string(pluginID)]
        ) { statement in
            guard try statement.step() else { return 0 }
            return statement.columnInt64(0)
        }
    }

    private func requirePrivateStorageQuota(
        pluginID: String,
        namespace: String,
        key: String,
        encodedValue: String,
        current: PrivateStorageRecord?
    ) throws {
        let namespaceUTF8Bytes = Int64(namespace.utf8.count)
        let keyUTF8Bytes = Int64(key.utf8.count)
        let valueJSONUTF8Bytes = Int64(encodedValue.utf8.count)
        let candidateLogicalUTF8Bytes = namespaceUTF8Bytes
            + keyUTF8Bytes
            + valueJSONUTF8Bytes
        let totalBefore = try privateStorageLogicalUTF8Bytes(pluginID: pluginID)
        let entryCountBefore = try privateStorageEntryCount(pluginID: pluginID)
        let totalAfter = totalBefore - (current?.logicalUTF8Bytes ?? 0)
            + candidateLogicalUTF8Bytes
        let candidateExceedsRowQuota = namespaceUTF8Bytes
            > BlocksPluginStorageQuota.maximumNamespaceUTF8Bytes
            || keyUTF8Bytes
            > BlocksPluginStorageQuota.maximumKeyUTF8Bytes
            || valueJSONUTF8Bytes
            > BlocksPluginStorageQuota.maximumValueJSONUTF8Bytes
        let legacyQuotaAlreadyExceeded = current?.exceedsRowQuota == true
            || totalBefore
                > BlocksPluginStorageQuota.maximumPluginLogicalUTF8Bytes
            || entryCountBefore
                > BlocksPluginStorageQuota.maximumPluginEntries

        if legacyQuotaAlreadyExceeded {
            guard let current,
                  candidateLogicalUTF8Bytes <= current.logicalUTF8Bytes,
                  namespaceUTF8Bytes <= current.namespaceUTF8Bytes,
                  keyUTF8Bytes <= current.keyUTF8Bytes,
                  valueJSONUTF8Bytes <= current.valueJSONUTF8Bytes,
                  totalAfter <= totalBefore else {
                throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
            }
            return
        }

        guard !candidateExceedsRowQuota,
              current != nil
                || entryCountBefore
                    < BlocksPluginStorageQuota.maximumPluginEntries,
              totalAfter
                <= BlocksPluginStorageQuota.maximumPluginLogicalUTF8Bytes else {
            throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
        }
    }

    private func requireValidPrivateQueue(
        _ values: [JSONValue]
    ) throws {
        guard values.count <= BlocksPluginStorageQuota.maximumQueueItems,
              try values.allSatisfy({
                  try encode($0).utf8.count
                      <= BlocksPluginStorageQuota
                          .maximumQueueItemJSONUTF8Bytes
              }) else {
            throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
        }
    }

    private func sharedStorageRecord(
        ownerPluginID: String,
        namespace: String,
        key: String
    ) throws -> PrivateStorageRecord? {
        try database.connection.withStatement(
            """
            SELECT
                revision,
                length(CAST(namespace AS BLOB)),
                length(CAST(key AS BLOB)),
                length(CAST(value_json AS BLOB))
            FROM plugin_shared_state
            WHERE owner_plugin_id = ? AND namespace = ? AND key = ?
            """,
            bindings: [.string(ownerPluginID), .string(namespace), .string(key)]
        ) { statement in
            guard try statement.step() else { return nil }
            let namespaceUTF8Bytes = statement.columnInt64(1)
            let keyUTF8Bytes = statement.columnInt64(2)
            let valueJSONUTF8Bytes = statement.columnInt64(3)
            return PrivateStorageRecord(
                revision: statement.columnInt64(0),
                logicalUTF8Bytes: namespaceUTF8Bytes
                    + keyUTF8Bytes
                    + valueJSONUTF8Bytes,
                namespaceUTF8Bytes: namespaceUTF8Bytes,
                keyUTF8Bytes: keyUTF8Bytes,
                valueJSONUTF8Bytes: valueJSONUTF8Bytes
            )
        }
    }

    private func sharedStorageLogicalUTF8Bytes(
        ownerPluginID: String
    ) throws -> Int64 {
        try database.connection.withStatement(
            """
            SELECT COALESCE(SUM(
                length(CAST(namespace AS BLOB))
                + length(CAST(key AS BLOB))
                + length(CAST(value_json AS BLOB))
            ), 0)
            FROM plugin_shared_state
            WHERE owner_plugin_id = ?
            """,
            bindings: [.string(ownerPluginID)]
        ) { statement in
            guard try statement.step() else { return 0 }
            return statement.columnInt64(0)
        }
    }

    private func sharedStorageEntryCount(
        ownerPluginID: String
    ) throws -> Int64 {
        try database.connection.withStatement(
            """
            SELECT COUNT(*) FROM plugin_shared_state
            WHERE owner_plugin_id = ?
            """,
            bindings: [.string(ownerPluginID)]
        ) { statement in
            guard try statement.step() else { return 0 }
            return statement.columnInt64(0)
        }
    }

    private func requireSharedStorageQuota(
        ownerPluginID: String,
        namespace: String,
        key: String,
        encodedValue: String,
        current: PrivateStorageRecord?
    ) throws {
        let namespaceUTF8Bytes = Int64(namespace.utf8.count)
        let keyUTF8Bytes = Int64(key.utf8.count)
        let valueJSONUTF8Bytes = Int64(encodedValue.utf8.count)
        let candidateLogicalUTF8Bytes = namespaceUTF8Bytes
            + keyUTF8Bytes
            + valueJSONUTF8Bytes
        let totalBefore = try sharedStorageLogicalUTF8Bytes(
            ownerPluginID: ownerPluginID
        )
        let entryCountBefore = try sharedStorageEntryCount(
            ownerPluginID: ownerPluginID
        )
        let totalAfter = totalBefore - (current?.logicalUTF8Bytes ?? 0)
            + candidateLogicalUTF8Bytes
        let candidateExceedsRowQuota = namespaceUTF8Bytes
            > BlocksPluginStorageQuota.maximumNamespaceUTF8Bytes
            || keyUTF8Bytes > BlocksPluginStorageQuota.maximumKeyUTF8Bytes
            || valueJSONUTF8Bytes
                > BlocksPluginStorageQuota.maximumValueJSONUTF8Bytes
        let legacyQuotaAlreadyExceeded = current?.exceedsRowQuota == true
            || totalBefore > BlocksPluginStorageQuota.maximumPluginLogicalUTF8Bytes
            || entryCountBefore > BlocksPluginStorageQuota.maximumPluginEntries

        if legacyQuotaAlreadyExceeded {
            guard let current,
                  candidateLogicalUTF8Bytes <= current.logicalUTF8Bytes,
                  namespaceUTF8Bytes <= current.namespaceUTF8Bytes,
                  keyUTF8Bytes <= current.keyUTF8Bytes,
                  valueJSONUTF8Bytes <= current.valueJSONUTF8Bytes,
                  totalAfter <= totalBefore else {
                throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
            }
            return
        }

        guard !candidateExceedsRowQuota,
              current != nil
                || entryCountBefore
                    < BlocksPluginStorageQuota.maximumPluginEntries,
              totalAfter <= BlocksPluginStorageQuota.maximumPluginLogicalUTF8Bytes else {
            throw BlocksPluginPlatformRepositoryError.storageQuotaExceeded
        }
    }

    private func execute(_ sql: String, _ bindings: [SQLiteBinding]) throws {
        try database.connection.withStatement(sql, bindings: bindings) { statement in
            _ = try statement.step()
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decodeValue(_ value: String) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
        } catch {
            throw BlocksPluginPlatformRepositoryError.invalidStoredValue
        }
    }

    private func decodeObject(
        _ value: String
    ) throws -> [String: JSONValue] {
        do {
            return try JSONDecoder().decode(
                [String: JSONValue].self,
                from: Data(value.utf8)
            )
        } catch {
            throw BlocksPluginPlatformRepositoryError.invalidStoredValue
        }
    }
}

public final class BlocksPluginDebugLogStore: @unchecked Sendable {
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumBytesPerPlugin: Int64 = 100 * 1_048_576

    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(environment: StorageEnvironment, fileManager: FileManager = .default) {
        root = environment.rootDirectory.appendingPathComponent("PluginLogs", isDirectory: true)
        self.fileManager = fileManager
    }

    public func append(
        pluginID: String,
        entry: [String: JSONValue],
        now: Date = Date()
    ) throws {
        try lock.withLock {
            let directory = try pluginDirectory(pluginID)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let file = directory.appendingPathComponent("\(formatter.string(from: now)).jsonl")
            var sanitized = BlocksPluginLogRedactor.sanitize(entry)
            sanitized["logged_at"] = .double(now.timeIntervalSince1970)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(sanitized)
            data.append(0x0A)
            if !fileManager.fileExists(atPath: file.path) {
                try data.write(to: file, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            try prune(directory: directory, now: now)
        }
    }

    public func clear(pluginID: String) throws {
        try lock.withLock {
            let directory = root.appendingPathComponent(Self.safeDirectoryName(pluginID), isDirectory: true)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    public func logFiles(pluginID: String) throws -> [URL] {
        try lock.withLock {
            let directory = root.appendingPathComponent(
                Self.safeDirectoryName(pluginID),
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: directory.path) else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return left > right
            }
        }
    }

    private func pluginDirectory(_ pluginID: String) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let directory = root.appendingPathComponent(Self.safeDirectoryName(pluginID), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func prune(directory: URL, now: Date) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }
        var retained: [(URL, Date, Int64)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > Self.retentionInterval {
                try? fileManager.removeItem(at: file)
            } else {
                retained.append((file, date, Int64(values.fileSize ?? 0)))
            }
        }
        var total = retained.reduce(Int64(0)) { $0 + $1.2 }
        for file in retained.sorted(by: { $0.1 < $1.1 })
            where total > Self.maximumBytesPerPlugin {
            try? fileManager.removeItem(at: file.0)
            total -= file.2
        }
    }

    private static func safeDirectoryName(_ pluginID: String) -> String {
        pluginID.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? String(character)
                : "_"
        }.joined()
    }
}
