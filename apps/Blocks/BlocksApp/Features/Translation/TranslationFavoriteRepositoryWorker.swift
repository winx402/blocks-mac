import BlocksCore
import Foundation

/// Serializes translation-favorite database work away from the main actor.
///
/// Callers keep ownership of their `Task`; cancellation therefore propagates
/// into queued actor work instead of leaving detached SQLite searches behind.
actor TranslationFavoriteRepositoryWorker {
    private let repository: TranslationFavoriteRepository

    init(repository: TranslationFavoriteRepository) {
        self.repository = repository
    }

    func save(
        session: TranslationSessionSnapshot
    ) throws -> TranslationFavorite {
        try Task.checkCancellation()
        let favorite = try repository.save(session: session)
        try Task.checkCancellation()
        return favorite
    }

    func loadSummaries(
        query: String,
        limit: Int,
        offset: Int = 0
    ) throws -> [TranslationFavoriteSummary] {
        try Task.checkCancellation()
        let summaries = query.isEmpty
            ? try repository.loadRecent(limit: limit, offset: offset)
            : try repository.search(
                query: query,
                limit: limit,
                offset: offset
            )
        try Task.checkCancellation()
        return summaries
    }

    func load(id: String) throws -> TranslationFavorite? {
        try Task.checkCancellation()
        let favorite = try repository.load(id: id)
        try Task.checkCancellation()
        return favorite
    }

    func count() throws -> Int {
        try Task.checkCancellation()
        let count = try repository.count()
        try Task.checkCancellation()
        return count
    }

    func delete(id: String) throws -> Bool {
        try Task.checkCancellation()
        let deleted = try repository.delete(id: id)
        try Task.checkCancellation()
        return deleted
    }

    func exportJSON() throws -> Data {
        let favorites = try loadAllFavorites()
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(favorites)
    }

    func exportMarkdown() throws -> Data {
        let favorites = try loadAllFavorites()
        try Task.checkCancellation()
        let body = favorites.map { favorite in
            let results = favorite.results.map {
                "### \($0.serviceDisplayName)\n\n\($0.translatedText)"
            }.joined(separator: "\n\n")
            return """
            ## \(favorite.sourceText)

            `\(favorite.sourceLanguage?.rawValue ?? "auto") → \(favorite.targetLanguage.rawValue)`

            \(results)
            """
        }
        .joined(separator: "\n\n---\n\n")
        return Data(body.utf8)
    }

    private func loadAllFavorites() throws -> [TranslationFavorite] {
        let batchSize = 500
        var offset = 0
        var favorites: [TranslationFavorite] = []
        while true {
            try Task.checkCancellation()
            let batch = try repository.loadAll(
                limit: batchSize,
                offset: offset
            )
            favorites.append(contentsOf: batch)
            guard batch.count == batchSize else {
                return favorites
            }
            offset += batch.count
        }
    }
}
