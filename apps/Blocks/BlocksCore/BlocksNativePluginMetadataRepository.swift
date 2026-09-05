import Foundation

public enum BlocksNativePluginMetadataRepositoryError: Error, LocalizedError, Equatable {
    case invalidInstalledRelativePath
    case invalidManifestEncoding
    case pluginNotFound(String)
    case packageChanged
    case approvalRequired
    case approvalExceedsManifest
    case invalidStoredMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInstalledRelativePath:
            return "The installed plugin path must be relative to the managed plugin directory."
        case .invalidManifestEncoding:
            return "The plugin manifest could not be encoded."
        case let .pluginNotFound(pluginID):
            return "The plugin was not found: \(pluginID)."
        case .packageChanged:
            return "The plugin package changed and must be reviewed again."
        case .approvalRequired:
            return "The plugin must be approved before it can be enabled."
        case .approvalExceedsManifest:
            return "The requested plugin permissions exceed the validated manifest."
        case let .invalidStoredMetadata(pluginID):
            return "The stored plugin metadata is invalid: \(pluginID)."
        }
    }
}

public final class BlocksNativePluginMetadataRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func installPending(
        package: BlocksNativePluginValidatedPackage,
        installedRelativePath: String,
        now: Date = Date()
    ) throws -> BlocksNativePluginMetadata {
        guard Self.isSafeManagedRelativePath(installedRelativePath) else {
            throw BlocksNativePluginMetadataRepositoryError.invalidInstalledRelativePath
        }
        guard let manifestJSON = String(data: package.manifestData, encoding: .utf8) else {
            throw BlocksNativePluginMetadataRepositoryError.invalidManifestEncoding
        }
        let capabilitiesJSON = try encode(package.manifest.capabilities)
        let timestamp = now.timeIntervalSince1970
        try execute(
            """
            INSERT INTO plugin_metadata (
                id,
                display_name,
                package_version,
                package_hash,
                manifest_json,
                capabilities_json,
                installed_relative_path,
                is_enabled,
                approval_status,
                approved_permissions_json,
                approved_domains_json,
                installed_at,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'pending', '[]', '[]', ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                package_version = excluded.package_version,
                manifest_json = excluded.manifest_json,
                capabilities_json = excluded.capabilities_json,
                installed_relative_path = excluded.installed_relative_path,
                is_enabled = CASE
                    WHEN plugin_metadata.package_hash = excluded.package_hash
                    THEN plugin_metadata.is_enabled
                    ELSE 0
                END,
                approval_status = CASE
                    WHEN plugin_metadata.package_hash = excluded.package_hash
                    THEN plugin_metadata.approval_status
                    ELSE 'pending'
                END,
                approved_permissions_json = CASE
                    WHEN plugin_metadata.package_hash = excluded.package_hash
                    THEN plugin_metadata.approved_permissions_json
                    ELSE '[]'
                END,
                approved_domains_json = CASE
                    WHEN plugin_metadata.package_hash = excluded.package_hash
                    THEN plugin_metadata.approved_domains_json
                    ELSE '[]'
                END,
                package_hash = excluded.package_hash,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .string(package.manifest.id),
                .string(package.manifest.displayName),
                .string(package.manifest.version),
                .string(package.packageSHA256),
                .string(manifestJSON),
                .string(capabilitiesJSON),
                .string(installedRelativePath),
                .double(timestamp),
                .double(timestamp),
            ]
        )
        return try metadata(id: package.manifest.id)
    }

    /// Installs and approves one exact validated package as a single database
    /// transaction. A failed approval must not leave metadata pointing at a
    /// package that the user never successfully approved.
    @discardableResult
    public func installApproved(
        package: BlocksNativePluginValidatedPackage,
        installedRelativePath: String,
        permissions: [String],
        domains: [String],
        installationOrigin: BlocksNativePluginInstallationOrigin = .external,
        builtInCatalogVersion: String? = nil,
        now: Date = Date()
    ) throws -> BlocksNativePluginMetadata {
        try database.connection.transaction {
            _ = try installPending(
                package: package,
                installedRelativePath: installedRelativePath,
                now: now
            )
            let approved = try approve(
                pluginID: package.manifest.id,
                expectedPackageHash: package.packageSHA256,
                permissions: permissions,
                domains: domains,
                now: now
            )
            try execute(
                """
                UPDATE plugin_metadata
                SET installation_origin = ?,
                    built_in_catalog_version = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .string(installationOrigin.rawValue),
                    builtInCatalogVersion.map(SQLiteBinding.string) ?? .null,
                    .double(now.timeIntervalSince1970),
                    .string(package.manifest.id),
                ]
            )
            return try metadata(id: approved.id)
        }
    }

    @discardableResult
    public func approve(
        pluginID: String,
        expectedPackageHash: String,
        permissions: [String],
        domains: [String],
        now: Date = Date()
    ) throws -> BlocksNativePluginMetadata {
        let current = try metadata(id: pluginID)
        guard current.packageHash == expectedPackageHash else {
            throw BlocksNativePluginMetadataRepositoryError.packageChanged
        }
        let manifest: BlocksNativePluginManifest
        do {
            manifest = try JSONDecoder().decode(
                BlocksNativePluginManifest.self,
                from: Data(current.manifestJSON.utf8)
            )
            try BlocksNativePluginPackageValidator().validate(manifest: manifest)
        } catch {
            throw BlocksNativePluginMetadataRepositoryError.invalidStoredMetadata(
                pluginID
            )
        }
        let requestedPermissions = Set(permissions)
        let requestedDomains = Set(domains.map { $0.lowercased() })
        let allowedPermissions = Self.permissionTokens(for: manifest)
        let allowedDomains = Set(
            manifest.permissions.network?.domains.map { $0.lowercased() } ?? []
        )
        guard requestedPermissions.isSubset(of: allowedPermissions),
              requestedDomains.isSubset(of: allowedDomains) else {
            throw BlocksNativePluginMetadataRepositoryError.approvalExceedsManifest
        }
        let permissionsJSON = try encode(requestedPermissions.sorted())
        let domainsJSON = try encode(requestedDomains.sorted())
        try execute(
            """
            UPDATE plugin_metadata
            SET approval_status = 'approved',
                approved_permissions_json = ?,
                approved_domains_json = ?,
                updated_at = ?
            WHERE id = ? AND package_hash = ?
            """,
            bindings: [
                .string(permissionsJSON),
                .string(domainsJSON),
                .double(now.timeIntervalSince1970),
                .string(pluginID),
                .string(expectedPackageHash),
            ]
        )
        return try metadata(id: pluginID)
    }

    @discardableResult
    public func reject(
        pluginID: String,
        expectedPackageHash: String,
        now: Date = Date()
    ) throws -> BlocksNativePluginMetadata {
        let current = try metadata(id: pluginID)
        guard current.packageHash == expectedPackageHash else {
            throw BlocksNativePluginMetadataRepositoryError.packageChanged
        }
        try execute(
            """
            UPDATE plugin_metadata
            SET approval_status = 'rejected',
                is_enabled = 0,
                approved_permissions_json = '[]',
                approved_domains_json = '[]',
                updated_at = ?
            WHERE id = ? AND package_hash = ?
            """,
            bindings: [
                .double(now.timeIntervalSince1970),
                .string(pluginID),
                .string(expectedPackageHash),
            ]
        )
        return try metadata(id: pluginID)
    }

    @discardableResult
    public func setEnabled(
        _ isEnabled: Bool,
        pluginID: String,
        now: Date = Date()
    ) throws -> BlocksNativePluginMetadata {
        let current = try metadata(id: pluginID)
        if isEnabled, current.approvalStatus != .approved {
            throw BlocksNativePluginMetadataRepositoryError.approvalRequired
        }
        try execute(
            """
            UPDATE plugin_metadata
            SET is_enabled = ?, updated_at = ?
            WHERE id = ?
              AND (? = 0 OR approval_status = 'approved')
            """,
            bindings: [
                .bool(isEnabled),
                .double(now.timeIntervalSince1970),
                .string(pluginID),
                .bool(isEnabled),
            ]
        )
        let updated = try metadata(id: pluginID)
        if isEnabled, !updated.isEnabled {
            throw BlocksNativePluginMetadataRepositoryError.approvalRequired
        }
        return updated
    }

    public func metadata(id: String) throws -> BlocksNativePluginMetadata {
        let rows = try read(
            whereClause: "WHERE id = ?",
            bindings: [.string(id)]
        )
        guard let metadata = rows.first else {
            throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(id)
        }
        return metadata
    }

    public func list() throws -> [BlocksNativePluginMetadata] {
        try read(whereClause: "", bindings: [])
    }

    public func remove(pluginID: String) throws {
        _ = try metadata(id: pluginID)
        try execute(
            "DELETE FROM plugin_metadata WHERE id = ?",
            bindings: [.string(pluginID)]
        )
    }

    private func read(
        whereClause: String,
        bindings: [SQLiteBinding]
    ) throws -> [BlocksNativePluginMetadata] {
        try database.connection.withStatement(
            """
            SELECT
                id,
                display_name,
                package_version,
                package_hash,
                manifest_json,
                capabilities_json,
                installed_relative_path,
                installation_origin,
                built_in_catalog_version,
                is_enabled,
                approval_status,
                approved_permissions_json,
                approved_domains_json,
                debug_enabled,
                safety_disabled,
                consecutive_failure_count,
                installed_at,
                updated_at
            FROM plugin_metadata
            \(whereClause)
            ORDER BY display_name COLLATE NOCASE, id
            """,
            bindings: bindings
        ) { statement in
            var results: [BlocksNativePluginMetadata] = []
            while try statement.step() {
                guard let pluginID = statement.columnString(0),
                      let displayName = statement.columnString(1),
                      let packageVersion = statement.columnString(2),
                      let packageHash = statement.columnString(3),
                      let manifestJSON = statement.columnString(4),
                      let capabilitiesJSON = statement.columnString(5),
                      let installedRelativePath = statement.columnString(6),
                      let rawInstallationOrigin = statement.columnString(7),
                      let installationOrigin = BlocksNativePluginInstallationOrigin(
                          rawValue: rawInstallationOrigin
                      ),
                      let rawApprovalStatus = statement.columnString(10),
                      let approvalStatus = BlocksNativePluginApprovalStatus(
                          rawValue: rawApprovalStatus
                      ),
                      let permissionsJSON = statement.columnString(11),
                      let domainsJSON = statement.columnString(12) else {
                    throw BlocksNativePluginMetadataRepositoryError.invalidStoredMetadata(
                        statement.columnString(0) ?? "unknown"
                    )
                }
                do {
                    results.append(
                        BlocksNativePluginMetadata(
                            id: pluginID,
                            displayName: displayName,
                            packageVersion: packageVersion,
                            packageHash: packageHash,
                            manifestJSON: manifestJSON,
                            capabilities: try decode(
                                [BlocksNativePluginCapability].self,
                                from: capabilitiesJSON
                            ),
                            installedRelativePath: installedRelativePath,
                            installationOrigin: installationOrigin,
                            builtInCatalogVersion: statement.columnString(8),
                            isEnabled: statement.columnBool(9),
                            approvalStatus: approvalStatus,
                            approvedPermissions: try decode(
                                [String].self,
                                from: permissionsJSON
                            ),
                            approvedDomains: try decode(
                                [String].self,
                                from: domainsJSON
                            ),
                            debugEnabled: statement.columnBool(13),
                            safetyDisabled: statement.columnBool(14),
                            consecutiveFailureCount: statement.columnInt(15),
                            installedAt: Date(timeIntervalSince1970: statement.columnDouble(16)),
                            updatedAt: Date(timeIntervalSince1970: statement.columnDouble(17))
                        )
                    )
                } catch {
                    throw BlocksNativePluginMetadataRepositoryError.invalidStoredMetadata(
                        pluginID
                    )
                }
            }
            return results
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding]) throws {
        try database.connection.withStatement(sql, bindings: bindings) { statement in
            _ = try statement.step()
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: String
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }

    private static func permissionTokens(
        for manifest: BlocksNativePluginManifest
    ) -> Set<String> {
        Set(manifest.declaredPermissionTokens)
    }

    private static func isSafeManagedRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
