import Foundation

public final class AppDatabase {
    public let environment: StorageEnvironment
    let connection: SQLiteConnection
    public let ftsEnabled: Bool

    private init(environment: StorageEnvironment, connection: SQLiteConnection, ftsEnabled: Bool) {
        self.environment = environment
        self.connection = connection
        self.ftsEnabled = ftsEnabled
    }

    public static func open(environment: StorageEnvironment? = nil) throws -> AppDatabase {
        let resolvedEnvironment = try environment ?? StorageEnvironment.appSupport()
        try resolvedEnvironment.prepare()
        let connection = try SQLiteConnection(url: resolvedEnvironment.databaseURL)
        let ftsEnabled = try MigrationRunner(connection: connection).migrate()
        return AppDatabase(environment: resolvedEnvironment, connection: connection, ftsEnabled: ftsEnabled)
    }

    public func close() {
        connection.close()
    }

    public func userVersion() throws -> Int {
        try connection.firstInt("PRAGMA user_version") ?? 0
    }

    public func tableExists(_ name: String) throws -> Bool {
        let count = try connection.firstInt(
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type IN ('table', 'virtual table') AND name = ?
            """,
            bindings: [.string(name)]
        ) ?? 0
        return count > 0
    }

    public func pragmaValue(_ name: String) throws -> String {
        guard name.range(of: #"^[A-Za-z_]+$"#, options: .regularExpression) != nil else {
            throw AppDatabaseError.invalidPragmaName(name)
        }
        return try connection.firstString("PRAGMA \(name)") ?? ""
    }
}

public enum AppDatabaseError: Error, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidPragmaName(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported database schema version \(version)."
        case let .invalidPragmaName(name):
            return "Invalid SQLite pragma name \(name)."
        }
    }
}

struct MigrationRunner {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func migrate() throws -> Bool {
        let currentVersion = try connection.firstInt("PRAGMA user_version") ?? 0
        if currentVersion > 17 {
            throw AppDatabaseError.unsupportedSchemaVersion(currentVersion)
        }

        var ftsEnabled = try detectClipboardFTS()
        if currentVersion < 1 {
            ftsEnabled = try migrateV1()
            try connection.execute("PRAGMA user_version = 1")
        }
        if currentVersion < 2 {
            ftsEnabled = try migrateV2()
            try connection.execute("PRAGMA user_version = 2")
        }
        if currentVersion < 3 {
            ftsEnabled = try migrateV3()
            try connection.execute("PRAGMA user_version = 3")
        }
        if currentVersion < 4 {
            ftsEnabled = try migrateV4()
            try connection.execute("PRAGMA user_version = 4")
        }
        if currentVersion < 5 {
            ftsEnabled = try migrateV5()
            try connection.execute("PRAGMA user_version = 5")
        }
        if currentVersion < 6 {
            ftsEnabled = try migrateV6()
            try connection.execute("PRAGMA user_version = 6")
        }
        if currentVersion < 7 {
            ftsEnabled = try migrateV7()
            try connection.execute("PRAGMA user_version = 7")
        }
        if currentVersion < 8 {
            ftsEnabled = try migrateV8()
            try connection.execute("PRAGMA user_version = 8")
        }
        if currentVersion < 9 {
            ftsEnabled = try migrateV9()
        }
        if currentVersion < 10 {
            ftsEnabled = try migrateV10()
        }
        if currentVersion < 11 {
            ftsEnabled = try migrateV11()
        }
        if currentVersion < 12 {
            ftsEnabled = try migrateV12()
        }
        if currentVersion < 13 {
            ftsEnabled = try migrateV13()
        }
        if currentVersion < 14 {
            ftsEnabled = try migrateV14()
        }
        if currentVersion < 15 {
            ftsEnabled = try migrateV15()
        }
        if currentVersion < 16 {
            ftsEnabled = try migrateV16()
        }
        if currentVersion < 17 {
            ftsEnabled = try migrateV17()
        }
        // v15 is still an in-development schema. Keep the migration
        // idempotently self-healing so locally installed development builds
        // created before the final v15 columns do not retain a partial plugin
        // platform schema.
        try repairV15PluginPlatformSchema()
        // v17 remains unreleased. Recheck its idempotent pieces so another
        // pending v17 addition can be safely appended without allocating v18.
        try repairV17ClipboardTagSchema()
        return ftsEnabled
    }

    private func migrateV16() throws -> Bool {
        try connection.transaction {
            try addColumnIfMissing(
                table: "plugin_metadata",
                column: "installation_origin",
                definition: "TEXT NOT NULL DEFAULT 'external'"
            )
            try addColumnIfMissing(
                table: "plugin_metadata",
                column: "built_in_catalog_version",
                definition: "TEXT"
            )
            try connection.execute("PRAGMA user_version = 16")
        }
        return try createClipboardFTSIfAvailable()
    }

    // v17 is an unreleased development schema. Keep related v17 additions in
    // this migration so they can be shipped together without a transient v18.
    private func migrateV17() throws -> Bool {
        try connection.transaction {
            try repairV17ClipboardTagSchema()
            try connection.execute("PRAGMA user_version = 17")
        }
        return try createClipboardFTSIfAvailable()
    }

    private func repairV17ClipboardTagSchema() throws {
        try addColumnIfMissing(
            table: "clipboard_tags",
            column: "content_revision",
            definition: "INTEGER NOT NULL DEFAULT 1"
        )
        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_record_tags_content_revision_insert
            AFTER INSERT ON clipboard_record_tags
            BEGIN
                UPDATE clipboard_tags
                SET content_revision = content_revision + 1
                WHERE id = NEW.tag_id;
            END;
            """
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS clipboard_sidecar_cleanup (
                relative_path TEXT PRIMARY KEY NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_attempt_at REAL,
                last_error_code TEXT
            )
            """
        )
        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_record_tags_content_revision_delete
            AFTER DELETE ON clipboard_record_tags
            BEGIN
                UPDATE clipboard_tags
                SET content_revision = content_revision + 1
                WHERE id = OLD.tag_id;
            END;
            """
        )
    }

    private func repairV15PluginPlatformSchema() throws {
        guard try tableExists("plugin_hook_bindings") else { return }
        try addColumnIfMissing(
            table: "plugin_hook_bindings",
            column: "safety_disabled",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            table: "plugin_hook_bindings",
            column: "consecutive_failure_count",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
    }

    private func tableExists(_ name: String) throws -> Bool {
        try connection.firstInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            bindings: [.string(name)]
        ) == 1
    }

    private func migrateV15() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS plugin_metadata (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    package_version TEXT NOT NULL,
                    package_hash TEXT NOT NULL,
                    manifest_json TEXT NOT NULL,
                    capabilities_json TEXT NOT NULL,
                    installed_relative_path TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 0,
                    approval_status TEXT NOT NULL DEFAULT 'pending',
                    approved_permissions_json TEXT NOT NULL DEFAULT '[]',
                    approved_domains_json TEXT NOT NULL DEFAULT '[]',
                    debug_enabled INTEGER NOT NULL DEFAULT 0,
                    safety_disabled INTEGER NOT NULL DEFAULT 0,
                    consecutive_failure_count INTEGER NOT NULL DEFAULT 0,
                    installed_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                INSERT OR REPLACE INTO plugin_metadata (
                    id, display_name, package_version, package_hash,
                    manifest_json, capabilities_json, installed_relative_path,
                    is_enabled, approval_status, approved_permissions_json,
                    approved_domains_json, installed_at, updated_at
                )
                SELECT
                    id, display_name, package_version, package_hash,
                    manifest_json, capabilities_json, installed_relative_path,
                    is_enabled, approval_status, approved_permissions_json,
                    approved_domains_json, installed_at, updated_at
                FROM translation_plugin_metadata;

                DROP INDEX IF EXISTS idx_translation_plugin_metadata_enabled;
                DROP TABLE IF EXISTS translation_plugin_metadata;

                CREATE INDEX IF NOT EXISTS idx_plugin_metadata_enabled
                ON plugin_metadata(is_enabled, display_name);

                CREATE TABLE IF NOT EXISTS plugin_hook_bindings (
                    plugin_id TEXT NOT NULL,
                    hook_id TEXT NOT NULL,
                    event_name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    timeout_ms INTEGER NOT NULL DEFAULT 500,
                    failure_policy TEXT NOT NULL DEFAULT 'fail_open',
                    safety_disabled INTEGER NOT NULL DEFAULT 0,
                    consecutive_failure_count INTEGER NOT NULL DEFAULT 0,
                    last_failure_at REAL,
                    PRIMARY KEY(plugin_id, hook_id),
                    FOREIGN KEY(plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_plugin_hook_bindings_event
                ON plugin_hook_bindings(event_name, is_enabled, sort_order, plugin_id);

                CREATE TABLE IF NOT EXISTS plugin_storage (
                    plugin_id TEXT NOT NULL,
                    namespace TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value_json TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(plugin_id, namespace, key),
                    FOREIGN KEY(plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS plugin_shared_state (
                    owner_plugin_id TEXT NOT NULL,
                    namespace TEXT NOT NULL,
                    key TEXT NOT NULL,
                    schema_version INTEGER NOT NULL,
                    value_json TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(owner_plugin_id, namespace, key),
                    FOREIGN KEY(owner_plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS plugin_shared_state_acl (
                    owner_plugin_id TEXT NOT NULL,
                    namespace TEXT NOT NULL,
                    consumer_plugin_id TEXT NOT NULL,
                    access TEXT NOT NULL,
                    PRIMARY KEY(owner_plugin_id, namespace, consumer_plugin_id),
                    FOREIGN KEY(owner_plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE,
                    FOREIGN KEY(consumer_plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS plugin_schedules (
                    plugin_id TEXT NOT NULL,
                    schedule_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    configuration_json TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 0,
                    next_fire_at REAL,
                    last_fired_at REAL,
                    PRIMARY KEY(plugin_id, schedule_id),
                    FOREIGN KEY(plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS plugin_audit_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    plugin_id TEXT NOT NULL,
                    event_id TEXT,
                    request_id TEXT,
                    causation_id TEXT,
                    level TEXT NOT NULL,
                    category TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    duration_ms REAL,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    FOREIGN KEY(plugin_id) REFERENCES plugin_metadata(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_plugin_audit_plugin_created
                ON plugin_audit_events(plugin_id, created_at DESC);

                CREATE INDEX IF NOT EXISTS idx_plugin_audit_created
                ON plugin_audit_events(created_at DESC);

                PRAGMA user_version = 15;
                """
            )
        }
        return try createClipboardFTSIfAvailable()
    }

    private func migrateV14() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS translation_favorites_fts
                USING fts5(
                    favorite_id UNINDEXED,
                    source_text,
                    translated_text,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                CREATE TRIGGER IF NOT EXISTS translation_favorites_fts_insert
                AFTER INSERT ON translation_favorites
                BEGIN
                    INSERT INTO translation_favorites_fts (
                        favorite_id,
                        source_text,
                        translated_text
                    ) VALUES (new.id, new.source_text, '');
                END;

                CREATE TRIGGER IF NOT EXISTS translation_favorites_fts_update
                AFTER UPDATE OF source_text ON translation_favorites
                BEGIN
                    UPDATE translation_favorites_fts
                    SET source_text = new.source_text
                    WHERE favorite_id = new.id;
                END;

                CREATE TRIGGER IF NOT EXISTS translation_favorites_fts_delete
                AFTER DELETE ON translation_favorites
                BEGIN
                    DELETE FROM translation_favorites_fts
                    WHERE favorite_id = old.id;
                END;

                CREATE TRIGGER IF NOT EXISTS translation_favorite_results_fts_insert
                AFTER INSERT ON translation_favorite_results
                BEGIN
                    UPDATE translation_favorites_fts
                    SET translated_text = COALESCE((
                        SELECT GROUP_CONCAT(translated_text, ' ')
                        FROM translation_favorite_results
                        WHERE favorite_id = new.favorite_id
                    ), '')
                    WHERE favorite_id = new.favorite_id;
                END;

                CREATE TRIGGER IF NOT EXISTS translation_favorite_results_fts_update
                AFTER UPDATE OF translated_text ON translation_favorite_results
                BEGIN
                    UPDATE translation_favorites_fts
                    SET translated_text = COALESCE((
                        SELECT GROUP_CONCAT(translated_text, ' ')
                        FROM translation_favorite_results
                        WHERE favorite_id = new.favorite_id
                    ), '')
                    WHERE favorite_id = new.favorite_id;
                END;

                CREATE TRIGGER IF NOT EXISTS translation_favorite_results_fts_delete
                AFTER DELETE ON translation_favorite_results
                BEGIN
                    UPDATE translation_favorites_fts
                    SET translated_text = COALESCE((
                        SELECT GROUP_CONCAT(translated_text, ' ')
                        FROM translation_favorite_results
                        WHERE favorite_id = old.favorite_id
                    ), '')
                    WHERE favorite_id = old.favorite_id;
                END;

                DELETE FROM translation_favorites_fts;

                INSERT INTO translation_favorites_fts (
                    favorite_id,
                    source_text,
                    translated_text
                )
                SELECT
                    translation_favorites.id,
                    translation_favorites.source_text,
                    COALESCE(GROUP_CONCAT(
                        translation_favorite_results.translated_text,
                        ' '
                    ), '')
                FROM translation_favorites
                LEFT JOIN translation_favorite_results
                  ON translation_favorite_results.favorite_id =
                     translation_favorites.id
                GROUP BY translation_favorites.id;

                PRAGMA user_version = 14;
                """
            )
        }
        return try createClipboardFTSIfAvailable()
    }

    private func migrateV13() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS translation_service_profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    template_id TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    schema_version INTEGER NOT NULL,
                    non_sensitive_configuration_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_translation_service_profiles_template
                ON translation_service_profiles(template_id, display_name COLLATE NOCASE, id);

                CREATE INDEX IF NOT EXISTS idx_translation_service_profiles_updated
                ON translation_service_profiles(updated_at DESC, id);

                CREATE UNIQUE INDEX IF NOT EXISTS idx_translation_service_profiles_apple_singleton
                ON translation_service_profiles(template_id)
                WHERE template_id = 'apple-local';

                PRAGMA user_version = 13;
                """
            )
        }
        return try createClipboardFTSIfAvailable()
    }

    private func migrateV12() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS translation_favorites (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL UNIQUE,
                    source_text TEXT NOT NULL,
                    input_source TEXT NOT NULL,
                    source_language_tag TEXT,
                    target_language_tag TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_translation_favorites_created
                ON translation_favorites(created_at DESC, id DESC);

                CREATE INDEX IF NOT EXISTS idx_translation_favorites_direction
                ON translation_favorites(source_language_tag, target_language_tag);

                CREATE TABLE IF NOT EXISTS translation_favorite_results (
                    id TEXT PRIMARY KEY NOT NULL,
                    favorite_id TEXT NOT NULL,
                    service_id TEXT NOT NULL,
                    service_display_name TEXT NOT NULL,
                    service_version TEXT,
                    service_kind TEXT NOT NULL,
                    translated_text TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(favorite_id) REFERENCES translation_favorites(id) ON DELETE CASCADE,
                    UNIQUE(favorite_id, sort_order)
                );

                CREATE INDEX IF NOT EXISTS idx_translation_favorite_results_favorite
                ON translation_favorite_results(favorite_id, sort_order);

                CREATE TABLE IF NOT EXISTS translation_plugin_metadata (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    package_version TEXT NOT NULL,
                    package_hash TEXT NOT NULL,
                    manifest_json TEXT NOT NULL,
                    capabilities_json TEXT NOT NULL,
                    installed_relative_path TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 0,
                    approval_status TEXT NOT NULL DEFAULT 'pending',
                    approved_permissions_json TEXT NOT NULL DEFAULT '[]',
                    approved_domains_json TEXT NOT NULL DEFAULT '[]',
                    installed_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_translation_plugin_metadata_enabled
                ON translation_plugin_metadata(is_enabled, display_name);

                PRAGMA user_version = 12;
                """
            )
        }
        return try createClipboardFTSIfAvailable()
    }

    private func migrateV11() throws -> Bool {
        try connection.transaction {
            if try !columnExists("origin_kind", in: "clipboard_items") {
                try connection.execute(
                    "ALTER TABLE clipboard_items ADD COLUMN origin_kind TEXT NOT NULL DEFAULT 'clipboard'"
                )
            }
            if try !columnExists("is_enabled", in: "clipboard_tags") {
                try connection.execute(
                    "ALTER TABLE clipboard_tags ADD COLUMN is_enabled INTEGER NOT NULL DEFAULT 1"
                )
            }
            try connection.execute(
                """
                UPDATE clipboard_items
                SET origin_kind = 'screenshot'
                WHERE EXISTS (
                    SELECT 1
                    FROM clipboard_record_tags
                    JOIN clipboard_tags ON clipboard_tags.id = clipboard_record_tags.tag_id
                    WHERE clipboard_record_tags.record_id = clipboard_items.id
                      AND clipboard_tags.built_in_kind = 'screenshot'
                )
                """
            )
            try connection.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_clipboard_items_origin_copied
                ON clipboard_items(origin_kind, last_copied_at DESC, created_at DESC)
                """
            )
            try connection.execute("PRAGMA user_version = 11")
        }
        return try createClipboardFTSIfAvailable()
    }

    private func migrateV10() throws -> Bool {
        try connection.transaction {
            if try !columnExists("visual_signature_sha256", in: "clipboard_payloads") {
                try connection.execute(
                    "ALTER TABLE clipboard_payloads ADD COLUMN visual_signature_sha256 TEXT"
                )
            }
            if try !columnExists("png_payload_sha256", in: "clipboard_payloads") {
                try connection.execute(
                    "ALTER TABLE clipboard_payloads ADD COLUMN png_payload_sha256 TEXT"
                )
            }
            try connection.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_clipboard_payloads_visual_signature
                ON clipboard_payloads(visual_signature_sha256)
                """
            )
            try connection.execute("PRAGMA user_version = 10")
        }
        return try createClipboardFTSIfAvailable()
    }

    private func columnExists(_ column: String, in table: String) throws -> Bool {
        try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            while try statement.step() {
                if statement.columnString(1) == column {
                    return true
                }
            }
            return false
        }
    }

    private func migrateV9() throws -> Bool {
        try connection.transaction {
            try connection.execute("PRAGMA user_version = 9")
            let aliases: [(normalized: String, replacement: String)] = [
                ("screenshot", "Screenshot (Custom)"),
                ("截图", "截图（自定义）"),
                ("スクリーンショット", "スクリーンショット（カスタム）"),
            ]
            for alias in aliases {
                let rows = try connection.withStatement(
                    "SELECT id FROM clipboard_tags WHERE built_in_kind = 'none' AND normalized_name = ?",
                    bindings: [.string(alias.normalized)]
                ) { statement in
                    var ids: [String] = []
                    while try statement.step() {
                        if let id = statement.columnString(0) { ids.append(id) }
                    }
                    return ids
                }
                for id in rows {
                    let replacementNormalized = "\(alias.normalized)-custom-\(String(id.suffix(8)))"
                    try connection.withStatement(
                        "UPDATE clipboard_tags SET display_name = ?, normalized_name = ?, updated_at = ? WHERE id = ?",
                        bindings: [
                            .string(alias.replacement),
                            .string(replacementNormalized),
                            .double(Date().timeIntervalSince1970),
                            .string(id),
                        ]
                    ) { statement in _ = try statement.step() }
                }
            }

            let screenshotTagExists = (try connection.firstInt(
                "SELECT COUNT(*) FROM clipboard_tags WHERE built_in_kind = 'screenshot'"
            ) ?? 0) > 0
            if !screenshotTagExists {
                try connection.execute(
                    "UPDATE clipboard_tags SET sort_order = sort_order + 1 WHERE built_in_kind != 'favorite'"
                )
            }
            let now = Date().timeIntervalSince1970
            try connection.withStatement(
                """
                INSERT INTO clipboard_tags
                    (id, display_name, normalized_name, color_token, sort_order, built_in_kind, created_at, updated_at)
                VALUES ('tag.screenshot', 'Screenshot', 'screenshot', 'orange', 1, 'screenshot', ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    normalized_name = excluded.normalized_name,
                    color_token = excluded.color_token,
                    sort_order = CASE
                        WHEN clipboard_tags.built_in_kind = 'screenshot' THEN clipboard_tags.sort_order
                        ELSE excluded.sort_order
                    END,
                    built_in_kind = excluded.built_in_kind,
                    updated_at = excluded.updated_at
                """,
                bindings: [.double(now), .double(now)]
            ) { statement in _ = try statement.step() }
            try connection.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_clipboard_tags_builtin_screenshot
                ON clipboard_tags(built_in_kind)
                WHERE built_in_kind = 'screenshot'
                """
            )
        }
        return try createClipboardFTSIfAvailable()
    }

    private func migrateV1() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS clipboard_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    change_count INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    format_summary_json TEXT NOT NULL,
                    source_app_json TEXT,
                    signature_sha256 TEXT NOT NULL UNIQUE,
                    signature_sha256_12 TEXT NOT NULL,
                    fixture_owned INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    restorable INTEGER NOT NULL DEFAULT 0,
                    excluded INTEGER NOT NULL DEFAULT 0,
                    snapshot_skipped INTEGER NOT NULL DEFAULT 0,
                    summary TEXT NOT NULL,
                    search_text TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_clipboard_items_created_at
                ON clipboard_items(created_at DESC);

                CREATE INDEX IF NOT EXISTS idx_clipboard_items_pinned_created
                ON clipboard_items(pinned, created_at DESC);

                CREATE INDEX IF NOT EXISTS idx_clipboard_items_signature_short
                ON clipboard_items(signature_sha256_12);

                CREATE TABLE IF NOT EXISTS clipboard_payloads (
                    record_id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    text TEXT,
                    rtf_data BLOB,
                    png_data BLOB,
                    png_sidecar_path TEXT,
                    url_string TEXT,
                    payload_byte_count INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(record_id) REFERENCES clipboard_items(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS clipboard_pinboards (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    color_name TEXT NOT NULL,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS clipboard_pinned_metadata (
                    record_id TEXT PRIMARY KEY NOT NULL,
                    pinboard_id TEXT NOT NULL,
                    display_name TEXT,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY(record_id) REFERENCES clipboard_items(id) ON DELETE CASCADE,
                    FOREIGN KEY(pinboard_id) REFERENCES clipboard_pinboards(id) ON DELETE RESTRICT
                );

                CREATE INDEX IF NOT EXISTS idx_clipboard_pinned_metadata_pinboard
                ON clipboard_pinned_metadata(pinboard_id);
                """
            )
            try seedDefaultPinboards()
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV2() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS clipboard_search_documents (
                    record_id TEXT PRIMARY KEY NOT NULL,
                    revision TEXT NOT NULL,
                    preview_title TEXT NOT NULL,
                    preview_body TEXT NOT NULL,
                    preview_badge TEXT NOT NULL,
                    content_kind TEXT NOT NULL,
                    image_state TEXT,
                    ocr_status TEXT NOT NULL,
                    is_truncated INTEGER NOT NULL DEFAULT 0,
                    content_text TEXT,
                    rich_text_plain_text TEXT,
                    url_tokens_json TEXT NOT NULL DEFAULT '[]',
                    file_tokens_json TEXT NOT NULL DEFAULT '[]',
                    source_tokens_json TEXT NOT NULL DEFAULT '[]',
                    type_tokens_json TEXT NOT NULL DEFAULT '[]',
                    time_tokens_json TEXT NOT NULL DEFAULT '[]',
                    ocr_text TEXT,
                    ocr_error_code TEXT,
                    ocr_attempt_count INTEGER NOT NULL DEFAULT 0,
                    ocr_last_attempt_at REAL,
                    ocr_next_retry_after REAL,
                    index_truncated INTEGER NOT NULL DEFAULT 0,
                    payload_derivation_state TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY(record_id) REFERENCES clipboard_items(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_clipboard_search_documents_state
                ON clipboard_search_documents(payload_derivation_state, updated_at DESC);

                CREATE INDEX IF NOT EXISTS idx_clipboard_search_documents_ocr_state
                ON clipboard_search_documents(ocr_status, updated_at DESC);
                """
            )
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV3() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS clipboard_tags (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    normalized_name TEXT NOT NULL UNIQUE,
                    color_token TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    built_in_kind TEXT NOT NULL DEFAULT 'none',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE UNIQUE INDEX IF NOT EXISTS idx_clipboard_tags_builtin_favorite
                ON clipboard_tags(built_in_kind)
                WHERE built_in_kind = 'favorite';

                CREATE INDEX IF NOT EXISTS idx_clipboard_tags_sort
                ON clipboard_tags(sort_order, display_name);

                CREATE TABLE IF NOT EXISTS clipboard_record_tags (
                    record_id TEXT NOT NULL,
                    tag_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(record_id, tag_id),
                    FOREIGN KEY(record_id) REFERENCES clipboard_items(id) ON DELETE CASCADE,
                    FOREIGN KEY(tag_id) REFERENCES clipboard_tags(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_clipboard_record_tags_tag
                ON clipboard_record_tags(tag_id, record_id);
                """
            )
            try addColumnIfMissing(
                table: "clipboard_search_documents",
                column: "tag_tokens_json",
                definition: "TEXT NOT NULL DEFAULT '[]'"
            )
            try seedFavoriteTag()
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV4() throws -> Bool {
        try connection.transaction {
            try addColumnIfMissing(
                table: "clipboard_items",
                column: "content_revision",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )
            try addColumnIfMissing(
                table: "clipboard_items",
                column: "content_updated_at",
                definition: "REAL"
            )
            try connection.execute(
                """
                UPDATE clipboard_items
                SET content_updated_at = COALESCE(content_updated_at, updated_at, created_at)
                """
            )
            try addColumnIfMissing(
                table: "clipboard_search_documents",
                column: "content_revision",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )
            try addColumnIfMissing(
                table: "clipboard_search_documents",
                column: "ocr_text_source",
                definition: "TEXT NOT NULL DEFAULT 'none'"
            )
            try addColumnIfMissing(
                table: "clipboard_search_documents",
                column: "ocr_user_edited_at",
                definition: "REAL"
            )
            try addColumnIfMissing(
                table: "clipboard_search_documents",
                column: "ocr_locked_content_revision",
                definition: "INTEGER"
            )
            try connection.execute(
                """
                UPDATE clipboard_search_documents
                SET content_revision = COALESCE(
                    (SELECT content_revision FROM clipboard_items WHERE clipboard_items.id = clipboard_search_documents.record_id),
                    content_revision,
                    1
                )
                """
            )
            try connection.execute(
                """
                UPDATE clipboard_search_documents
                SET ocr_text_source = 'vision'
                WHERE ocr_status = 'succeeded'
                  AND ocr_text IS NOT NULL
                  AND TRIM(ocr_text) != ''
                  AND ocr_text_source = 'none'
                """
            )
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV5() throws -> Bool {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS privacy_policy_rules (
                    subject_ref TEXT PRIMARY KEY NOT NULL,
                    subject_type TEXT NOT NULL,
                    identifier TEXT NOT NULL,
                    display_name TEXT,
                    policy TEXT NOT NULL,
                    path_hash TEXT,
                    path_summary TEXT,
                    source_directory TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_privacy_policy_rules_type_identifier
                ON privacy_policy_rules(subject_type, identifier);

                CREATE INDEX IF NOT EXISTS idx_privacy_policy_rules_policy
                ON privacy_policy_rules(policy, updated_at DESC);
                """
            )
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV6() throws -> Bool {
        try connection.transaction {
            try addColumnIfMissing(
                table: "clipboard_items",
                column: "last_copied_at",
                definition: "REAL"
            )
            try connection.execute(
                """
                UPDATE clipboard_items
                SET last_copied_at = COALESCE(last_copied_at, created_at)
                """
            )
            try connection.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_clipboard_items_last_copied
                ON clipboard_items(last_copied_at DESC, created_at DESC)
                """
            )
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV7() throws -> Bool {
        try connection.transaction {
            try addColumnIfMissing(
                table: "clipboard_items",
                column: "custom_title",
                definition: "TEXT"
            )
        }

        return try createClipboardFTSIfAvailable()
    }

    private func migrateV8() throws -> Bool {
        struct LegacySkippedRecord {
            let id: String
            let changeCount: Int
            let reason: ClipboardCaptureSkipReason
            let excluded: Bool
        }

        try connection.transaction {
            let records = try connection.withStatement(
                "SELECT id, change_count, summary, excluded FROM clipboard_items WHERE snapshot_skipped = 1"
            ) { statement in
                var records: [LegacySkippedRecord] = []
                while try statement.step() {
                    guard let id = statement.columnString(0),
                          let summary = statement.columnString(2),
                          let reason = legacyCaptureSkipReason(
                              summary: summary,
                              excluded: statement.columnBool(3)
                          ) else {
                        continue
                    }
                    records.append(
                        LegacySkippedRecord(
                            id: id,
                            changeCount: statement.columnInt(1),
                            reason: reason,
                            excluded: statement.columnBool(3)
                        )
                    )
                }
                return records
            }

            let redactedFormatData = try JSONEncoder().encode(
                ClipboardRecorderFormatSummary(itemCount: 1, types: [])
            )
            guard let redactedFormatJSON = String(data: redactedFormatData, encoding: .utf8) else {
                throw AppDatabaseError.unsupportedSchemaVersion(7)
            }
            let now = Date().timeIntervalSince1970
            let ftsExists = try detectClipboardFTS()

            for record in records {
                let signature = ClipboardCapturePolicy.sanitizedSkippedSignature(
                    recordID: record.id,
                    reason: record.reason
                )
                let signature12 = String(signature.prefix(12))
                let revision = "v2:\(record.changeCount):\(signature12)"
                let excluded = record.reason == .excludedSource || record.excluded

                try connection.withStatement(
                    """
                    UPDATE clipboard_items
                    SET kind = ?,
                        format_summary_json = ?,
                        signature_sha256 = ?,
                        signature_sha256_12 = ?,
                        restorable = 0,
                        excluded = ?,
                        snapshot_skipped = 1,
                        summary = ?,
                        search_text = NULL,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        .string(ClipboardRecorderItemKind.unknown.rawValue),
                        .string(redactedFormatJSON),
                        .string(signature),
                        .string(signature12),
                        .bool(excluded),
                        .string(record.reason.summaryCode),
                        .double(now),
                        .string(record.id),
                    ]
                ) { statement in
                    _ = try statement.step()
                }
                try connection.withStatement(
                    "DELETE FROM clipboard_payloads WHERE record_id = ?",
                    bindings: [.string(record.id)]
                ) { statement in
                    _ = try statement.step()
                }
                try connection.withStatement(
                    """
                    UPDATE clipboard_search_documents
                    SET revision = ?,
                        preview_title = ?,
                        preview_body = ?,
                        preview_badge = ?,
                        content_kind = ?,
                        image_state = NULL,
                        ocr_status = ?,
                        is_truncated = 0,
                        content_text = NULL,
                        rich_text_plain_text = NULL,
                        url_tokens_json = '[]',
                        file_tokens_json = '[]',
                        type_tokens_json = '[]',
                        ocr_text = NULL,
                        ocr_error_code = NULL,
                        ocr_attempt_count = 0,
                        ocr_last_attempt_at = NULL,
                        ocr_next_retry_after = NULL,
                        ocr_text_source = ?,
                        ocr_user_edited_at = NULL,
                        ocr_locked_content_revision = NULL,
                        index_truncated = 0,
                        payload_derivation_state = ?,
                        updated_at = ?
                    WHERE record_id = ?
                    """,
                    bindings: [
                        .string(revision),
                        .string("clipboard.capture.skipped"),
                        .string(record.reason.summaryCode),
                        .string(ClipboardRecorderItemKind.unknown.rawValue),
                        .string(ClipboardRecorderItemKind.unknown.rawValue),
                        .string(ClipboardOCRState.notRequired.rawValue),
                        .string(ClipboardOCRTextSource.none.rawValue),
                        .string(ClipboardPayloadDerivationState.redacted.rawValue),
                        .double(now),
                        .string(record.id),
                    ]
                ) { statement in
                    _ = try statement.step()
                }
                if ftsExists {
                    try connection.withStatement(
                        "DELETE FROM clipboard_fts WHERE record_id = ?",
                        bindings: [.string(record.id)]
                    ) { statement in
                        _ = try statement.step()
                    }
                }
            }
        }

        return try createClipboardFTSIfAvailable()
    }

    private func legacyCaptureSkipReason(
        summary: String,
        excluded: Bool
    ) -> ClipboardCaptureSkipReason? {
        switch summary {
        case "Clipboard capture skipped: recorder paused.":
            return .paused
        case "Clipboard capture skipped: excluded source.", "Content skipped by privacy rules.":
            return .excludedSource
        case "Clipboard capture skipped: unsupported content.":
            return .unsupportedContent
        case "Clipboard capture skipped":
            return excluded ? .excludedSource : .unsupportedContent
        default:
            return nil
        }
    }

    private func seedDefaultPinboards() throws {
        let now = Date().timeIntervalSince1970
        let pinboards: [(String, String, String, Int)] = [
            ("pinboard.unfiled", "Unfiled", "gray", 0),
            ("pinboard.work", "Work", "blue", 1),
            ("pinboard.personal", "Personal", "green", 2)
        ]
        for pinboard in pinboards {
            try connection.withStatement(
                """
                INSERT OR IGNORE INTO clipboard_pinboards
                    (id, name, color_name, sort_index, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .string(pinboard.0),
                    .string(pinboard.1),
                    .string(pinboard.2),
                    .int(pinboard.3),
                    .double(now),
                    .double(now)
                ]
            ) { statement in
                _ = try statement.step()
            }
        }
    }

    private func seedFavoriteTag() throws {
        let now = Date().timeIntervalSince1970
        try connection.withStatement(
            """
            INSERT INTO clipboard_tags
                (id, display_name, normalized_name, color_token, sort_order, built_in_kind, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                normalized_name = excluded.normalized_name,
                color_token = excluded.color_token,
                sort_order = excluded.sort_order,
                built_in_kind = excluded.built_in_kind,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .string("tag.favorite"),
                .string("收藏"),
                .string("favorite"),
                .string("favorite"),
                .int(0),
                .string("favorite"),
                .double(now),
                .double(now)
            ]
        ) { statement in
            _ = try statement.step()
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let columns = try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            var names: Set<String> = []
            while try statement.step() {
                if let name = statement.columnString(1) {
                    names.insert(name)
                }
            }
            return names
        }
        guard !columns.contains(column) else {
            return
        }
        try connection.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func detectClipboardFTS() throws -> Bool {
        try connection.tableExists("clipboard_fts")
    }

    private func createClipboardFTSIfAvailable() throws -> Bool {
        do {
            try connection.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts
                USING fts5(record_id UNINDEXED, search_text);
                """
            )
            return true
        } catch {
            return false
        }
    }
}

private extension SQLiteConnection {
    func tableExists(_ name: String) throws -> Bool {
        let count = try firstInt(
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type IN ('table', 'virtual table') AND name = ?
            """,
            bindings: [.string(name)]
        ) ?? 0
        return count > 0
    }
}
