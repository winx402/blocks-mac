import Foundation

public struct TranslationFavoriteResult: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let serviceID: String
    public let serviceDisplayName: String
    public let serviceVersion: String?
    public let serviceKind: TranslationServiceKind
    public let translatedText: String
    public let sortOrder: Int
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        serviceID: String,
        serviceDisplayName: String,
        serviceVersion: String? = nil,
        serviceKind: TranslationServiceKind,
        translatedText: String,
        sortOrder: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serviceID = serviceID
        self.serviceDisplayName = serviceDisplayName
        self.serviceVersion = serviceVersion
        self.serviceKind = serviceKind
        self.translatedText = translatedText
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// An immutable translation-session snapshot.
///
/// Source application metadata, screen anchors, screenshot pixels, and failed
/// service responses are deliberately absent.
public struct TranslationFavorite: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let sourceText: String
    public let inputSource: TranslationInputSource
    public let sourceLanguage: TranslationLanguageTag?
    public let targetLanguage: TranslationLanguageTag
    public let results: [TranslationFavoriteResult]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        sessionID: String,
        sourceText: String,
        inputSource: TranslationInputSource,
        sourceLanguage: TranslationLanguageTag?,
        targetLanguage: TranslationLanguageTag,
        results: [TranslationFavoriteResult],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceText = sourceText
        self.inputSource = inputSource
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.results = results.sorted { $0.sortOrder < $1.sortOrder }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TranslationFavoriteSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let sourceText: String
    public let inputSource: TranslationInputSource
    public let sourceLanguage: TranslationLanguageTag?
    public let targetLanguage: TranslationLanguageTag
    public let resultCount: Int
    public let firstTranslatedText: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        sessionID: String,
        sourceText: String,
        inputSource: TranslationInputSource,
        sourceLanguage: TranslationLanguageTag?,
        targetLanguage: TranslationLanguageTag,
        resultCount: Int,
        firstTranslatedText: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceText = sourceText
        self.inputSource = inputSource
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.resultCount = resultCount
        self.firstTranslatedText = firstTranslatedText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TranslationFavoriteRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case noSuccessfulResults
    case favoriteNotFound(String)
    case invalidPersistedValue(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .noSuccessfulResults:
            return "A translation session must contain at least one successful result before it can be favorited."
        case let .favoriteNotFound(id):
            return "Translation favorite \(id) was not found."
        case let .invalidPersistedValue(field, value):
            return "Invalid persisted translation value for \(field): \(value)."
        }
    }
}

public final class TranslationFavoriteRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Saves the successful result cards as one immutable favorite snapshot.
    ///
    /// Repeating the operation for the same session returns the original
    /// snapshot instead of silently rewriting it.
    @discardableResult
    public func save(
        session: TranslationSessionSnapshot,
        at date: Date = Date()
    ) throws -> TranslationFavorite {
        try Task.checkCancellation()
        if let existing = try load(sessionID: session.id) {
            return existing
        }

        let successfulResults = session.successfulResults
        guard !successfulResults.isEmpty else {
            throw TranslationFavoriteRepositoryError.noSuccessfulResults
        }

        let favoriteID = UUID().uuidString
        let storedFavoriteID = try database.connection.transaction {
            if let existingID = try database.connection.firstString(
                "SELECT id FROM translation_favorites WHERE session_id = ? LIMIT 1",
                bindings: [.string(session.id)]
            ) {
                return existingID
            }
            try database.connection.withStatement(
                """
                INSERT INTO translation_favorites (
                    id, session_id, source_text, input_source,
                    source_language_tag, target_language_tag,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .string(favoriteID),
                    .string(session.id),
                    .string(session.input.text),
                    .string(session.input.source.rawValue),
                    optionalString(session.direction.source?.rawValue),
                    .string(session.direction.target.rawValue),
                    .double(date.timeIntervalSince1970),
                    .double(date.timeIntervalSince1970),
                ]
            ) { statement in
                _ = try statement.step()
            }

            for (sortOrder, result) in successfulResults.enumerated() {
                try Task.checkCancellation()
                try database.connection.withStatement(
                    """
                    INSERT INTO translation_favorite_results (
                        id, favorite_id, service_id, service_display_name,
                        service_version, service_kind, translated_text,
                        sort_order, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .string(UUID().uuidString),
                        .string(favoriteID),
                        .string(result.service.id),
                        .string(result.service.displayName),
                        optionalString(result.service.version),
                        .string(result.service.kind.rawValue),
                        .string(result.translatedText),
                        .int(sortOrder),
                        .double(date.timeIntervalSince1970),
                    ]
                ) { statement in
                    _ = try statement.step()
                }
            }
            return favoriteID
        }

        guard let stored = try load(id: storedFavoriteID) else {
            throw TranslationFavoriteRepositoryError.favoriteNotFound(storedFavoriteID)
        }
        return stored
    }

    public func load(id: String) throws -> TranslationFavorite? {
        try Task.checkCancellation()
        guard let favorite = try loadFavoriteRow(
            whereClause: "translation_favorites.id = ?",
            binding: .string(id)
        ) else {
            return nil
        }
        return try favoriteWithResults(favorite)
    }

    public func load(sessionID: String) throws -> TranslationFavorite? {
        try Task.checkCancellation()
        guard let favorite = try loadFavoriteRow(
            whereClause: "translation_favorites.session_id = ?",
            binding: .string(sessionID)
        ) else {
            return nil
        }
        return try favoriteWithResults(favorite)
    }

    public func loadRecent(limit: Int = 100, offset: Int = 0) throws -> [TranslationFavoriteSummary] {
        try Task.checkCancellation()
        return try loadSummaries(query: nil, limit: limit, offset: offset)
    }

    public func search(
        query: String,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [TranslationFavoriteSummary] {
        try Task.checkCancellation()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return try loadRecent(limit: limit, offset: offset)
        }
        return try loadSummaries(query: normalized, limit: limit, offset: offset)
    }

    /// Loads complete immutable favorites with their service results in one
    /// joined query. This is intentionally separate from the lightweight
    /// summary query used by the list UI.
    public func loadAll(
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [TranslationFavorite] {
        try Task.checkCancellation()
        return try loadFavorites(limit: limit, offset: offset)
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        try Task.checkCancellation()
        return try database.connection.transaction {
            let exists = (try database.connection.firstInt(
                "SELECT COUNT(*) FROM translation_favorites WHERE id = ?",
                bindings: [.string(id)]
            ) ?? 0) > 0
            guard exists else {
                return false
            }
            try database.connection.withStatement(
                "DELETE FROM translation_favorites WHERE id = ?",
                bindings: [.string(id)]
            ) { statement in
                _ = try statement.step()
            }
            return true
        }
    }

    public func count() throws -> Int {
        try Task.checkCancellation()
        return try database.connection.firstInt(
            "SELECT COUNT(*) FROM translation_favorites"
        ) ?? 0
    }
}

private extension TranslationFavoriteRepository {
    struct FavoriteRow {
        let id: String
        let sessionID: String
        let sourceText: String
        let inputSource: TranslationInputSource
        let sourceLanguage: TranslationLanguageTag?
        let targetLanguage: TranslationLanguageTag
        let createdAt: Date
        let updatedAt: Date
    }

    func loadFavoriteRow(
        whereClause: String,
        binding: SQLiteBinding
    ) throws -> FavoriteRow? {
        try database.connection.withStatement(
            """
            SELECT id, session_id, source_text, input_source,
                   source_language_tag, target_language_tag,
                   created_at, updated_at
            FROM translation_favorites
            WHERE \(whereClause)
            LIMIT 1
            """,
            bindings: [binding]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            return try decodeFavoriteRow(statement)
        }
    }

    func favoriteWithResults(_ row: FavoriteRow) throws -> TranslationFavorite {
        let results = try database.connection.withStatement(
            """
            SELECT id, service_id, service_display_name, service_version,
                   service_kind, translated_text, sort_order, created_at
            FROM translation_favorite_results
            WHERE favorite_id = ?
            ORDER BY sort_order ASC, id ASC
            """,
            bindings: [.string(row.id)]
        ) { statement in
            var results: [TranslationFavoriteResult] = []
            while try statement.step() {
                try Task.checkCancellation()
                let kindValue = statement.columnString(4) ?? ""
                guard let kind = TranslationServiceKind(rawValue: kindValue) else {
                    throw TranslationFavoriteRepositoryError.invalidPersistedValue(
                        field: "service_kind",
                        value: kindValue
                    )
                }
                results.append(
                    TranslationFavoriteResult(
                        id: statement.columnString(0) ?? "",
                        serviceID: statement.columnString(1) ?? "",
                        serviceDisplayName: statement.columnString(2) ?? "",
                        serviceVersion: statement.columnString(3),
                        serviceKind: kind,
                        translatedText: statement.columnString(5) ?? "",
                        sortOrder: statement.columnInt(6),
                        createdAt: Date(timeIntervalSince1970: statement.columnDouble(7))
                    )
                )
            }
            return results
        }

        return TranslationFavorite(
            id: row.id,
            sessionID: row.sessionID,
            sourceText: row.sourceText,
            inputSource: row.inputSource,
            sourceLanguage: row.sourceLanguage,
            targetLanguage: row.targetLanguage,
            results: results,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    func loadSummaries(
        query: String?,
        limit: Int,
        offset: Int
    ) throws -> [TranslationFavoriteSummary] {
        let boundedLimit = min(max(1, limit), 500)
        let boundedOffset = max(0, offset)
        let queryClause: String
        var bindings: [SQLiteBinding] = []
        if let query {
            if try database.tableExists(
                "translation_favorites_fts"
            ) {
                queryClause =
                    """
                    WHERE translation_favorites.id IN (
                        SELECT favorite_id
                        FROM translation_favorites_fts
                        WHERE translation_favorites_fts MATCH ?
                    )
                    """
                bindings.append(
                    .string(Self.ftsMatchQuery(query))
                )
            } else {
                queryClause =
                    """
                    WHERE INSTR(LOWER(translation_favorites.source_text), LOWER(?)) > 0
                       OR EXISTS (
                           SELECT 1
                           FROM translation_favorite_results AS matching_results
                           WHERE matching_results.favorite_id = translation_favorites.id
                             AND INSTR(LOWER(matching_results.translated_text), LOWER(?)) > 0
                       )
                    """
                bindings.append(.string(query))
                bindings.append(.string(query))
            }
        } else {
            queryClause = ""
        }
        bindings.append(.int(boundedLimit))
        bindings.append(.int(boundedOffset))

        return try database.connection.withStatement(
            """
            SELECT
                translation_favorites.id,
                translation_favorites.session_id,
                translation_favorites.source_text,
                translation_favorites.input_source,
                translation_favorites.source_language_tag,
                translation_favorites.target_language_tag,
                COUNT(translation_favorite_results.id),
                (
                    SELECT first_result.translated_text
                    FROM translation_favorite_results AS first_result
                    WHERE first_result.favorite_id = translation_favorites.id
                    ORDER BY first_result.sort_order ASC, first_result.id ASC
                    LIMIT 1
                ),
                translation_favorites.created_at,
                translation_favorites.updated_at
            FROM translation_favorites
            LEFT JOIN translation_favorite_results
              ON translation_favorite_results.favorite_id = translation_favorites.id
            \(queryClause)
            GROUP BY translation_favorites.id
            ORDER BY translation_favorites.created_at DESC,
                     translation_favorites.id DESC
            LIMIT ? OFFSET ?
            """,
            bindings: bindings
        ) { statement in
            var summaries: [TranslationFavoriteSummary] = []
            while try statement.step() {
                try Task.checkCancellation()
                let sourceValue = statement.columnString(3) ?? ""
                guard let inputSource = TranslationInputSource(rawValue: sourceValue) else {
                    throw TranslationFavoriteRepositoryError.invalidPersistedValue(
                        field: "input_source",
                        value: sourceValue
                    )
                }
                let sourceLanguage = try decodeLanguageTag(
                    statement.columnString(4),
                    field: "source_language_tag"
                )
                let targetValue = statement.columnString(5) ?? ""
                guard let targetLanguage = TranslationLanguageTag(targetValue) else {
                    throw TranslationFavoriteRepositoryError.invalidPersistedValue(
                        field: "target_language_tag",
                        value: targetValue
                    )
                }
                summaries.append(
                    TranslationFavoriteSummary(
                        id: statement.columnString(0) ?? "",
                        sessionID: statement.columnString(1) ?? "",
                        sourceText: statement.columnString(2) ?? "",
                        inputSource: inputSource,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        resultCount: statement.columnInt(6),
                        firstTranslatedText: statement.columnString(7),
                        createdAt: Date(timeIntervalSince1970: statement.columnDouble(8)),
                        updatedAt: Date(timeIntervalSince1970: statement.columnDouble(9))
                    )
                )
            }
            return summaries
        }
    }

    func loadFavorites(limit: Int, offset: Int) throws -> [TranslationFavorite] {
        let boundedLimit = min(max(1, limit), 500)
        let boundedOffset = max(0, offset)
        return try database.connection.withStatement(
            """
            WITH selected_favorites AS (
                SELECT id, session_id, source_text, input_source,
                       source_language_tag, target_language_tag,
                       created_at, updated_at
                FROM translation_favorites
                ORDER BY created_at DESC, id DESC
                LIMIT ? OFFSET ?
            )
            SELECT
                selected_favorites.id,
                selected_favorites.session_id,
                selected_favorites.source_text,
                selected_favorites.input_source,
                selected_favorites.source_language_tag,
                selected_favorites.target_language_tag,
                selected_favorites.created_at,
                selected_favorites.updated_at,
                translation_favorite_results.id,
                translation_favorite_results.service_id,
                translation_favorite_results.service_display_name,
                translation_favorite_results.service_version,
                translation_favorite_results.service_kind,
                translation_favorite_results.translated_text,
                translation_favorite_results.sort_order,
                translation_favorite_results.created_at
            FROM selected_favorites
            LEFT JOIN translation_favorite_results
              ON translation_favorite_results.favorite_id = selected_favorites.id
            ORDER BY selected_favorites.created_at DESC,
                     selected_favorites.id DESC,
                     translation_favorite_results.sort_order ASC,
                     translation_favorite_results.id ASC
            """,
            bindings: [.int(boundedLimit), .int(boundedOffset)]
        ) { statement in
            var favorites: [TranslationFavorite] = []
            var currentRow: FavoriteRow?
            var currentResults: [TranslationFavoriteResult] = []

            func appendCurrentFavorite() {
                guard let row = currentRow else { return }
                favorites.append(
                    TranslationFavorite(
                        id: row.id,
                        sessionID: row.sessionID,
                        sourceText: row.sourceText,
                        inputSource: row.inputSource,
                        sourceLanguage: row.sourceLanguage,
                        targetLanguage: row.targetLanguage,
                        results: currentResults,
                        createdAt: row.createdAt,
                        updatedAt: row.updatedAt
                    )
                )
            }

            while try statement.step() {
                try Task.checkCancellation()
                let row = try decodeFavoriteRow(statement)
                if currentRow?.id != row.id {
                    appendCurrentFavorite()
                    currentRow = row
                    currentResults = []
                }

                guard let resultID = statement.columnString(8) else {
                    continue
                }
                let kindValue = statement.columnString(12) ?? ""
                guard let kind = TranslationServiceKind(rawValue: kindValue) else {
                    throw TranslationFavoriteRepositoryError.invalidPersistedValue(
                        field: "service_kind",
                        value: kindValue
                    )
                }
                currentResults.append(
                    TranslationFavoriteResult(
                        id: resultID,
                        serviceID: statement.columnString(9) ?? "",
                        serviceDisplayName: statement.columnString(10) ?? "",
                        serviceVersion: statement.columnString(11),
                        serviceKind: kind,
                        translatedText: statement.columnString(13) ?? "",
                        sortOrder: statement.columnInt(14),
                        createdAt: Date(
                            timeIntervalSince1970: statement.columnDouble(15)
                        )
                    )
                )
            }
            appendCurrentFavorite()
            return favorites
        }
    }

    func decodeFavoriteRow(_ statement: SQLiteStatement) throws -> FavoriteRow {
        let sourceValue = statement.columnString(3) ?? ""
        guard let inputSource = TranslationInputSource(rawValue: sourceValue) else {
            throw TranslationFavoriteRepositoryError.invalidPersistedValue(
                field: "input_source",
                value: sourceValue
            )
        }
        let sourceLanguage = try decodeLanguageTag(
            statement.columnString(4),
            field: "source_language_tag"
        )
        let targetValue = statement.columnString(5) ?? ""
        guard let targetLanguage = TranslationLanguageTag(targetValue) else {
            throw TranslationFavoriteRepositoryError.invalidPersistedValue(
                field: "target_language_tag",
                value: targetValue
            )
        }
        return FavoriteRow(
            id: statement.columnString(0) ?? "",
            sessionID: statement.columnString(1) ?? "",
            sourceText: statement.columnString(2) ?? "",
            inputSource: inputSource,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            createdAt: Date(timeIntervalSince1970: statement.columnDouble(6)),
            updatedAt: Date(timeIntervalSince1970: statement.columnDouble(7))
        )
    }

    func decodeLanguageTag(_ value: String?, field: String) throws -> TranslationLanguageTag? {
        guard let value else {
            return nil
        }
        guard let language = TranslationLanguageTag(value) else {
            throw TranslationFavoriteRepositoryError.invalidPersistedValue(field: field, value: value)
        }
        return language
    }

    func optionalString(_ value: String?) -> SQLiteBinding {
        value.map(SQLiteBinding.string) ?? .null
    }

    static func ftsMatchQuery(_ query: String) -> String {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.map {
            let escaped = $0.replacingOccurrences(
                of: "\"",
                with: "\"\""
            )
            return "\"\(escaped)\"*"
        }
        .joined(separator: " AND ")
    }
}
