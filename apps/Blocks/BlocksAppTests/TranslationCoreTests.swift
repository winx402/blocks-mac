import Foundation
import XCTest
@testable import BlocksCore

final class TranslationCoreTests: XCTestCase {
    func testLanguageTagCanonicalizesCommonBCP47FormsAndRejectsSyntheticAuto() throws {
        XCTAssertEqual(TranslationLanguageTag("zh_hans_cn")?.rawValue, "zh-Hans-CN")
        XCTAssertEqual(TranslationLanguageTag("EN-us")?.rawValue, "en-US")
        XCTAssertEqual(TranslationLanguageTag("de-DE-u-co-phonebk")?.rawValue, "de-DE-u-co-phonebk")
        XCTAssertEqual(TranslationLanguageTag("x-blocks-test")?.rawValue, "x-blocks-test")
        XCTAssertNil(TranslationLanguageTag("auto"))
        XCTAssertNil(TranslationLanguageTag("en-"))
        XCTAssertNil(TranslationLanguageTag("zh-中文"))

        let encoded = try JSONEncoder().encode(try XCTUnwrap(TranslationLanguageTag("ja-JP")))
        XCTAssertEqual(
            try JSONDecoder().decode(TranslationLanguageTag.self, from: encoded),
            try XCTUnwrap(TranslationLanguageTag("ja-JP"))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(TranslationLanguageTag.self, from: Data(#""auto""#.utf8))
        )
    }

    func testSessionPreservesConfiguredResultOrderInsteadOfCompletionOrder() throws {
        let target = try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
        let apple = service(id: "apple", name: "Apple", kind: .appleLocal)
        let plugin = service(id: "plugin", name: "Plugin", kind: .plugin)
        let session = TranslationSessionSnapshot(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(target: target),
            results: [
                TranslationResultSnapshot(
                    service: apple,
                    state: .running,
                    startedAt: Date(timeIntervalSince1970: 20)
                ),
                TranslationResultSnapshot(
                    service: plugin,
                    state: .succeeded,
                    translatedText: "你好",
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11)
                ),
            ]
        )

        XCTAssertEqual(session.results.map(\.service.id), ["apple", "plugin"])
        XCTAssertEqual(session.successfulResults.map(\.service.id), ["plugin"])
    }

    func testResultDiagnosticsRoundTripAndRemainOptionalForOlderSnapshots()
        throws
    {
        let result = TranslationResultSnapshot(
            service: service(
                id: "openai",
                name: "OpenAI-compatible",
                kind: .openAICompatible
            ),
            state: .succeeded,
            translatedText: "你好",
            diagnostics: TranslationResultDiagnostics(
                auditID: "tr_runtime_fixture",
                durationMS: 31,
                route: "https://example.test · POST /v1/chat/completions",
                status: "success"
            ),
            detectedSourceLanguage: TranslationLanguageTag("en"),
            sourceMetadata: ["provider": .string("fixture")]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(result)

        XCTAssertEqual(
            try decoder.decode(
                TranslationResultSnapshot.self,
                from: encoded
            ),
            result
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        legacyObject.removeValue(forKey: "diagnostics")
        legacyObject.removeValue(forKey: "detectedSourceLanguage")
        legacyObject.removeValue(forKey: "sourceMetadata")
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject
        )
        XCTAssertNil(
            try decoder.decode(
                TranslationResultSnapshot.self,
                from: legacyData
            ).diagnostics
        )
        let legacy = try decoder.decode(
            TranslationResultSnapshot.self,
            from: legacyData
        )
        XCTAssertNil(legacy.detectedSourceLanguage)
        XCTAssertTrue(legacy.sourceMetadata.isEmpty)
    }

    func testFavoritePersistsOnlySuccessfulServiceSnapshotsAndNoEphemeralInputContext() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationFavoriteRepository(database: fixture.database)
        let session = try makeSession(id: "session-one")

        let stored = try repository.save(
            session: session,
            at: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(stored.sessionID, session.id)
        XCTAssertEqual(stored.sourceText, "hello")
        XCTAssertEqual(stored.inputSource, .screenshotOCR)
        XCTAssertEqual(stored.results.map(\.serviceID), ["apple"])
        XCTAssertEqual(stored.results.map(\.translatedText), ["你好"])
        XCTAssertEqual(try repository.count(), 1)

        let columns = try fixture.database.connection.withStatement(
            "PRAGMA table_info(translation_favorites)"
        ) { statement in
            var result: Set<String> = []
            while try statement.step() {
                if let name = statement.columnString(1) {
                    result.insert(name)
                }
            }
            return result
        }
        XCTAssertFalse(columns.contains("screenshot_data"))
        XCTAssertFalse(columns.contains("anchor_json"))
        XCTAssertFalse(columns.contains("source_application_bundle_id"))
    }

    func testFavoriteForSameSessionIsImmutableAndSearchesSourceOrResultText() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationFavoriteRepository(database: fixture.database)
        let original = try makeSession(id: "stable-session")
        let first = try repository.save(
            session: original,
            at: Date(timeIntervalSince1970: 100)
        )
        let changed = TranslationSessionSnapshot(
            id: original.id,
            input: TranslationInput(source: .manual, text: "changed text"),
            direction: original.direction,
            results: [
                TranslationResultSnapshot(
                    service: service(id: "new", name: "New", kind: .plugin),
                    state: .succeeded,
                    translatedText: "不应覆盖"
                ),
            ]
        )

        let duplicate = try repository.save(
            session: changed,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(try repository.count(), 1)
        XCTAssertEqual(try repository.search(query: "hello").map(\.id), [first.id])
        XCTAssertEqual(try repository.search(query: "你好").map(\.id), [first.id])
        XCTAssertTrue(try repository.search(query: "不应覆盖").isEmpty)
    }

    func testFavoriteDeleteCascadesResults() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationFavoriteRepository(database: fixture.database)
        let stored = try repository.save(session: makeSession(id: "delete-session"))

        XCTAssertTrue(try repository.delete(id: stored.id))
        XCTAssertFalse(try repository.delete(id: stored.id))
        XCTAssertNil(try repository.load(id: stored.id))
        XCTAssertEqual(
            try fixture.database.connection.firstInt(
                "SELECT COUNT(*) FROM translation_favorite_results WHERE favorite_id = ?",
                bindings: [.string(stored.id)]
            ),
            0
        )
    }

    func testLoadAllFavoritesPreservesNewestFirstOrderAndCompleteResults() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationFavoriteRepository(database: fixture.database)
        let older = try repository.save(
            session: makeSession(id: "older-session"),
            at: Date(timeIntervalSince1970: 100)
        )
        let newer = try repository.save(
            session: makeSession(id: "newer-session"),
            at: Date(timeIntervalSince1970: 200)
        )

        let favorites = try repository.loadAll()

        XCTAssertEqual(favorites.map(\.id), [newer.id, older.id])
        XCTAssertEqual(favorites.map { $0.results.map(\.serviceID) }, [
            ["apple"],
            ["apple"],
        ])
        XCTAssertEqual(try repository.loadAll(limit: 1).map(\.id), [newer.id])
        XCTAssertEqual(
            try repository.loadAll(limit: 1, offset: 1).map(\.id),
            [older.id]
        )
    }

    func testFavoriteRejectsSessionWithoutSuccessfulResults() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let target = try XCTUnwrap(TranslationLanguageTag("fr"))
        let session = TranslationSessionSnapshot(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(target: target),
            results: [
                TranslationResultSnapshot(
                    service: service(id: "failed", name: "Failed", kind: .plugin),
                    state: .failed,
                    errorCode: "fixture_failure",
                    errorMessage: "Fixture failure details"
                ),
            ]
        )

        XCTAssertThrowsError(try TranslationFavoriteRepository(database: fixture.database).save(session: session)) {
            XCTAssertEqual($0 as? TranslationFavoriteRepositoryError, .noSuccessfulResults)
        }
    }

    func testV11ToV17MigrationPreservesExistingDataAndCreatesPluginTables() throws {
        let fixture = try makeFixture()
        let root = fixture.root
        try fixture.database.connection.execute(
            """
            INSERT INTO privacy_policy_rules (
                subject_ref, subject_type, identifier, display_name, policy,
                path_hash, path_summary, source_directory, created_at, updated_at
            ) VALUES (
                'bundle:app.blocks.fixture', 'bundle_id', 'app.blocks.fixture',
                'Fixture', 'allowed', NULL, NULL, NULL, 1, 1
            )
            """
        )
        try fixture.database.connection.execute(
            """
            DROP TABLE translation_favorite_results;
            DROP TABLE translation_favorites;
            DROP TABLE plugin_metadata;
            PRAGMA user_version = 11;
            """
        )
        fixture.database.close()

        let migrated = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        defer {
            migrated.close()
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(try migrated.userVersion(), 17)
        XCTAssertTrue(try migrated.tableExists("translation_favorites"))
        XCTAssertTrue(try migrated.tableExists("translation_favorite_results"))
        XCTAssertTrue(try migrated.tableExists("plugin_metadata"))
        XCTAssertTrue(try migrated.tableExists("plugin_hook_bindings"))
        XCTAssertTrue(try migrated.tableExists("plugin_storage"))
        XCTAssertTrue(try migrated.tableExists("plugin_shared_state"))
        XCTAssertTrue(try migrated.tableExists("plugin_schedules"))
        XCTAssertTrue(try migrated.tableExists("plugin_audit_events"))
        let pluginColumns = try migrated.connection.withStatement(
            "PRAGMA table_info(plugin_metadata)"
        ) { statement in
            var names: Set<String> = []
            while try statement.step() {
                if let name = statement.columnString(1) {
                    names.insert(name)
                }
            }
            return names
        }
        XCTAssertTrue(pluginColumns.contains("installation_origin"))
        XCTAssertTrue(pluginColumns.contains("built_in_catalog_version"))
        XCTAssertTrue(
            try migrated.tableExists("translation_service_profiles")
        )
        XCTAssertTrue(
            try migrated.tableExists("translation_favorites_fts")
        )
        XCTAssertEqual(
            try migrated.connection.firstInt(
                "SELECT COUNT(*) FROM privacy_policy_rules WHERE subject_ref = 'bundle:app.blocks.fixture'"
            ),
            1
        )
    }

    func testV13ToV14MigrationIndexesExistingTranslationFavoritesWithUnicode61()
        throws
    {
        let fixture = try makeFixture()
        let root = fixture.root
        let repository = TranslationFavoriteRepository(
            database: fixture.database
        )
        let stored = try repository.save(
            session: makeSession(id: "fts-migration-session"),
            at: Date(timeIntervalSince1970: 100)
        )
        try fixture.database.connection.execute(
            """
            DROP TRIGGER IF EXISTS translation_favorites_fts_insert;
            DROP TRIGGER IF EXISTS translation_favorites_fts_update;
            DROP TRIGGER IF EXISTS translation_favorites_fts_delete;
            DROP TRIGGER IF EXISTS translation_favorite_results_fts_insert;
            DROP TRIGGER IF EXISTS translation_favorite_results_fts_update;
            DROP TRIGGER IF EXISTS translation_favorite_results_fts_delete;
            DROP TABLE translation_favorites_fts;
            CREATE TABLE translation_plugin_metadata AS
            SELECT
                id, display_name, package_version, package_hash,
                manifest_json, capabilities_json, installed_relative_path,
                is_enabled, approval_status, approved_permissions_json,
                approved_domains_json, installed_at, updated_at
            FROM plugin_metadata;
            PRAGMA user_version = 13;
            """
        )
        fixture.database.close()

        let migrated = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            migrated.close()
            try? FileManager.default.removeItem(at: root)
        }
        let migratedRepository = TranslationFavoriteRepository(
            database: migrated
        )

        XCTAssertEqual(try migrated.userVersion(), 17)
        XCTAssertEqual(
            try migratedRepository.search(query: "hello").map(\.id),
            [stored.id]
        )
        XCTAssertEqual(
            try migratedRepository.search(query: "你好").map(\.id),
            [stored.id]
        )
        let createSQL = try migrated.connection.firstString(
            """
            SELECT sql
            FROM sqlite_master
            WHERE name = 'translation_favorites_fts'
            """
        )
        XCTAssertTrue(createSQL?.contains("unicode61") == true)
    }

    func testTranslationFavoriteFTSSearchUsesUnicodeAndDiacriticFolding()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationFavoriteRepository(
            database: fixture.database
        )
        let session = TranslationSessionSnapshot(
            id: "unicode-search-session",
            input: TranslationInput(
                source: .manual,
                text: "Résumé café"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            results: [
                TranslationResultSnapshot(
                    service: service(
                        id: "unicode",
                        name: "Unicode",
                        kind: .plugin
                    ),
                    state: .succeeded,
                    translatedText: "世界翻译"
                ),
            ]
        )
        let stored = try repository.save(session: session)

        XCTAssertEqual(
            try repository.search(query: "resume caf").map(\.id),
            [stored.id]
        )
        XCTAssertEqual(
            try repository.search(query: "世界").map(\.id),
            [stored.id]
        )
    }

    func testTranslationServiceProfileRepositoryPersistsMultipleProfilesAndStableIDs()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        let first = TranslationServiceProfile(
            id: "deepl-primary",
            templateID: .deepLFree,
            displayName: "DeepL Primary",
            configuration: [:],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let second = TranslationServiceProfile(
            id: "deepl-secondary",
            templateID: .deepLFree,
            displayName: "DeepL Secondary",
            configuration: [:],
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let storedFirst = try repository.save(
            first,
            now: Date(timeIntervalSince1970: 30)
        )
        let storedSecond = try repository.save(
            second,
            now: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(storedFirst.serviceID, "profile:deepl-primary")
        XCTAssertEqual(storedSecond.serviceID, "profile:deepl-secondary")
        XCTAssertEqual(
            try repository.list().map(\.id),
            ["deepl-primary", "deepl-secondary"]
        )
        XCTAssertEqual(
            try repository.profile(id: "deepl-secondary").configuration,
            [:]
        )
    }

    func testTranslationServiceProfileRepositoryIsolatesInvalidStoredRows()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        _ = try repository.save(
            TranslationServiceProfile(
                id: "deepl-healthy",
                templateID: .deepLFree,
                displayName: "Healthy DeepL",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        try fixture.database.connection.execute(
            """
            INSERT INTO translation_service_profiles (
                id,
                template_id,
                display_name,
                schema_version,
                non_sensitive_configuration_json,
                created_at,
                updated_at
            ) VALUES (
                'broken-future-profile',
                'deepl-free',
                'Broken Future Profile',
                99,
                '{}',
                20,
                20
            )
            """
        )

        let result = try repository.listRecoveringInvalidRows()

        XCTAssertEqual(result.profiles.map(\.id), ["deepl-healthy"])
        XCTAssertEqual(
            result.issues.map(\.profileID),
            ["broken-future-profile"]
        )
        XCTAssertTrue(
            result.issues[0].message.contains(
                "Unsupported translation service profile schema version"
            )
        )
        XCTAssertThrowsError(try repository.list())
    }

    func testTranslationServiceProfileRepositoryRejectsSensitiveConfiguration()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        let profile = TranslationServiceProfile(
            id: "unsafe-profile",
            templateID: .googleCloudBasic,
            displayName: "Unsafe",
            configuration: [
                "api_key": .string("must-not-enter-sqlite"),
            ]
        )

        XCTAssertThrowsError(try repository.save(profile)) { error in
            XCTAssertEqual(
                error as? TranslationServiceProfileRepositoryError,
                .sensitiveConfigurationKey("api_key")
            )
        }
        XCTAssertEqual(
            try fixture.database.connection.firstInt(
                "SELECT COUNT(*) FROM translation_service_profiles"
            ),
            0
        )
    }

    func testTranslationServiceProfileRepositoryRejectsSensitiveLibreURLComponentsBeforePersistence()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        let unsafeBaseURLs = [
            "https://user:password@libre.example.test/api",
            "https://libre.example.test/api?api_key=secret",
            "https://libre.example.test/api#token=secret",
            "http://libre.example.test/api",
            "https://192.168.1.20/api",
            "https://libre.example.test:0/api",
            "https://libre.example.test:65536/api",
            "https://libre.example.test:/api",
            "https://libre.example.test:999999999999999999999/api",
        ]

        for (index, baseURL) in unsafeBaseURLs.enumerated() {
            let profile = TranslationServiceProfile(
                id: "unsafe-libre-\(index)",
                templateID: .libreTranslate,
                displayName: "Unsafe Libre \(index)",
                configuration: [
                    "base_url": .string(baseURL),
                ]
            )
            XCTAssertThrowsError(try repository.save(profile)) {
                error in
                XCTAssertEqual(
                    error as? TranslationServiceProfileRepositoryError,
                    .invalidConfiguration
                )
            }
        }

        XCTAssertEqual(
            try fixture.database.connection.firstInt(
                "SELECT COUNT(*) FROM translation_service_profiles"
            ),
            0
        )
    }

    func testTranslationServiceProfileRepositoryNormalizesSafeLibreURLBeforePersistence()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        let saved = try repository.save(
            TranslationServiceProfile(
                id: "safe-libre",
                templateID: .libreTranslate,
                displayName: "Safe Libre",
                configuration: [
                    "base_url": .string(
                        "  HTTPS://LIBRE.EXAMPLE.TEST:8443/api/  "
                    ),
                ]
            )
        )

        XCTAssertEqual(
            saved.configuration["base_url"],
            .string("https://libre.example.test:8443/api/")
        )
    }

    func testTranslationServiceProfileRepositoryRejectsUnknownAndUnsafeTypedFields()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        let candidates = [
            TranslationServiceProfile(
                id: "unknown-field",
                templateID: .deepLFree,
                displayName: "Unknown",
                configuration: ["region": .string("eu")]
            ),
            TranslationServiceProfile(
                id: "wrong-type",
                templateID: .microsoftTranslator,
                displayName: "Wrong Type",
                configuration: ["region": .bool(true)]
            ),
            TranslationServiceProfile(
                id: "header-injection",
                templateID: .microsoftTranslator,
                displayName: "Header Injection",
                configuration: [
                    "region": .string("westus\r\nInjected: value"),
                ]
            ),
            TranslationServiceProfile(
                id: "unknown-alibaba-region",
                templateID: .alibabaMachineTranslation,
                displayName: "Unknown Region",
                configuration: [
                    "region": .string("xx-moon-1"),
                ]
            ),
        ]

        for candidate in candidates {
            XCTAssertThrowsError(try repository.save(candidate)) { error in
                XCTAssertEqual(
                    error as? TranslationServiceProfileRepositoryError,
                    .invalidConfiguration
                )
            }
        }
    }

    func testTranslationServiceProfileRepositoryEnforcesAppleSingleton()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = TranslationServiceProfileRepository(
            database: fixture.database
        )
        _ = try repository.save(
            TranslationServiceProfile(
                id: "apple-local",
                templateID: .appleLocal,
                displayName: "Apple"
            )
        )

        XCTAssertThrowsError(
            try repository.save(
                TranslationServiceProfile(
                    id: "apple-local-secondary",
                    templateID: .appleLocal,
                    displayName: "Apple Secondary"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TranslationServiceProfileRepositoryError,
                .appleLocalMustBeSingleton
            )
        }
    }

    func testClipboardBoundedTextReadDoesNotOpenImageSidecar() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let repository = ClipboardRepository(database: fixture.database)
        let recordID = "translation-text-only"
        let text = "需要翻译的文本"
        let signature = String(repeating: "a", count: 64)
        _ = try repository.insert(
            record: ClipboardRecorderRecord(
                id: recordID,
                createdAt: Date(timeIntervalSince1970: 100),
                changeCount: 1,
                kind: .text,
                formatSummary: ClipboardRecorderFormatSummary(
                    itemCount: 1,
                    types: ["public.utf8-plain-text"],
                    textLength: text.count,
                    byteCount: text.utf8.count
                ),
                sourceApp: nil,
                signatureSHA256: signature,
                signatureSHA256_12: String(signature.prefix(12)),
                fixtureOwned: true,
                restorable: true,
                summary: text
            ),
            payload: ClipboardRecorderPayload(
                recordID: recordID,
                kind: .text,
                text: text
            )
        )
        try fixture.database.connection.execute(
            """
            UPDATE clipboard_payloads
            SET png_sidecar_path = 'missing/translation-test.png'
            WHERE record_id = 'translation-text-only'
            """
        )

        XCTAssertThrowsError(try repository.readPayload(recordID: recordID))
        XCTAssertEqual(
            try repository.readBoundedText(
                recordID: recordID,
                maximumCharacterCount: 4
            ),
            "需要翻译"
        )
    }

    func testOCRDefaultServiceLocalizationDoesNotPromiseSilentFallback()
        throws
    {
        let expected = [
            "en": "If the selected plugin is unavailable",
            "ja": "選択したプラグインが利用できない場合はエラー",
            "zh-Hans": "所选插件不可用时会显示错误",
        ]

        for (language, phrase) in expected {
            let localizationURL = try XCTUnwrap(
                Bundle.main.url(
                    forResource: language,
                    withExtension: "lproj"
                )
            )
            let localizationBundle = try XCTUnwrap(
                Bundle(url: localizationURL)
            )
            let value = localizationBundle.localizedString(
                forKey: "translation.ocr.defaultService.detail",
                value: nil,
                table: "TranslationLocalizable"
            )
            XCTAssertTrue(value.contains(phrase), "\(language): \(value)")
            XCTAssertFalse(
                value.localizedCaseInsensitiveContains(
                    "without changing this selection"
                )
            )
            XCTAssertFalse(value.contains("安全回退"))
            XCTAssertFalse(value.contains("選択を変更せず"))
        }
    }

    func testNoEnabledTranslationServiceWarningIsLocalized() throws {
        let expected = [
            "en":
                "Translation is currently unavailable. Enable at least one service.",
            "ja":
                "現在は翻訳できません。少なくとも1つのサービスを有効にしてください。",
            "zh-Hans": "当前无法翻译，请至少启用一个服务。",
        ]

        for (language, localizedValue) in expected {
            let localizationURL = try XCTUnwrap(
                Bundle.main.url(
                    forResource: language,
                    withExtension: "lproj"
                )
            )
            let localizationBundle = try XCTUnwrap(
                Bundle(url: localizationURL)
            )
            XCTAssertEqual(
                localizationBundle.localizedString(
                    forKey: "translation.services.noneEnabledDetail",
                    value: nil,
                    table: "TranslationLocalizable"
                ),
                localizedValue,
                language
            )
        }
    }

    private func makeSession(id: String) throws -> TranslationSessionSnapshot {
        let source = try XCTUnwrap(TranslationLanguageTag("en-US"))
        let target = try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
        return TranslationSessionSnapshot(
            id: id,
            input: TranslationInput(
                source: .screenshotOCR,
                text: "hello",
                context: TranslationInputContext(
                    sourceApplicationBundleID: "app.blocks.fixture",
                    sourceApplicationName: "Fixture",
                    displayIdentifier: "display-1",
                    anchor: TranslationInputAnchor(x: 10, y: 20, width: 30, height: 40)
                )
            ),
            direction: TranslationLanguageDirection(source: source, target: target),
            results: [
                TranslationResultSnapshot(
                    service: service(id: "apple", name: "Apple", kind: .appleLocal),
                    state: .succeeded,
                    translatedText: "你好"
                ),
                TranslationResultSnapshot(
                    service: service(id: "failed", name: "Failed", kind: .plugin),
                    state: .failed,
                    errorCode: "fixture_failure",
                    errorMessage: "Response body must not be persisted"
                ),
            ]
        )
    }

    func testTranslationSourcePackageSnapshotRejectsTraversalAndOversizePayloads() throws {
        XCTAssertThrowsError(
            try TranslationSourcePackageSnapshot(files: [
                "manifest.json": Data("{}".utf8),
                "../escape.js": Data(),
            ])
        )

        XCTAssertThrowsError(
            try TranslationSourcePackageSnapshot(files: [
                "manifest.json": Data("{}".utf8),
                "payload.bin": Data(
                    count:
                        TranslationSourcePackageSnapshot
                            .maximumTotalBytes
                ),
            ])
        )
    }

    func testTranslationSourceActionRoundTripPreservesInMemoryTestText() throws {
        let input = TranslationSourceManagementActionInput(
            operation: .test,
            sourceID: "plugin:fixture",
            testText: "Low sensitivity fixture",
            capability: .translation
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(
            TranslationSourceManagementActionInput.self,
            from: data
        )

        XCTAssertEqual(decoded, input)
        XCTAssertEqual(decoded.testText, "Low sensitivity fixture")
    }

    func testTranslationSourceManagementActionIsRegistered() {
        XCTAssertEqual(
            ActionRegistry.actions.first {
                $0.actionID
                    == BlocksAction.translationSourceManage.actionID
            }?.requestType,
            String(
                describing:
                    TranslationSourceManagementActionInput.self
            )
        )
    }

    func testGenericPluginManagementActionIsRegisteredSeparately() {
        XCTAssertEqual(
            ActionRegistry.actions.first {
                $0.actionID == BlocksAction.pluginManage.actionID
            }?.requestType,
            String(describing: PluginDevelopmentActionInput.self)
        )
        XCTAssertNotEqual(
            BlocksAction.pluginManage.actionID,
            BlocksAction.translationSourceManage.actionID
        )
    }

    private func service(
        id: String,
        name: String,
        kind: TranslationServiceKind
    ) -> TranslationServiceDescriptor {
        TranslationServiceDescriptor(id: id, displayName: name, kind: kind)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslationCoreTests.\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        return Fixture(root: root, database: database)
    }

    private struct Fixture {
        let root: URL
        let database: AppDatabase

        func close() {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
