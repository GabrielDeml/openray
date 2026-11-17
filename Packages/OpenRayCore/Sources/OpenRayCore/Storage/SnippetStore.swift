import Foundation
import GRDB

public enum SnippetStoreError: LocalizedError, Equatable {
    /// Another snippet already has this keyword.
    case keywordTaken(String)

    public var errorDescription: String? {
        switch self {
        case .keywordTaken(let keyword):
            return String(
                localized: "Another snippet already has the keyword “\(keyword)”.",
                bundle: .module,
                comment:
                    "Shown in the snippet editor when the keyword is in use. The placeholder is the keyword."
            )
        }
    }
}

/// The user's snippets (docs/DESIGN.md §4.3.3, §4.9). They live in the table `snippet` of the
/// migration `m7_snippets`, with the index `snippet_fts` beside it for searching their text.
public struct SnippetStore: Sendable {
    /// The trigram tokenizer of `snippet_fts` indexes runs of three characters, so a shorter
    /// query has nothing to look up there.
    private static let shortestIndexedQuery = 3
    /// How many snippets a query too short for the index is compared with, most recently
    /// changed first (§4.3.2).
    private static let scanLimit = 500

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Adds the snippet, or changes the one with the same ID, whose creation date stays as it
    /// is stored. The name is stored without surrounding whitespace, and a blank keyword as
    /// none.
    ///
    /// - Throws: `SnippetStoreError.keywordTaken` when another snippet has the keyword; nothing
    ///   is written then.
    public func save(_ snippet: Snippet) async throws {
        let stored = Self.normalized(snippet)

        try await database.write("snippets.save") { db in
            // Asked here, in the transaction of the write, so that the answer is an error of
            // this store and not a constraint failure whose message would have to be read.
            if let keyword = stored.keyword {
                let otherWithKeyword = try Row.fetchOne(
                    db, sql: "SELECT 1 FROM snippet WHERE keyword = ? AND id <> ?",
                    arguments: [keyword, stored.id.uuidString])
                if otherWithKeyword != nil {
                    throw SnippetStoreError.keywordTaken(keyword)
                }
            }
            try Self.write(stored, to: db)
        }
    }

    /// Deletes the snippet together with what was stored about its item, so that no alias or
    /// hotkey is left pointing at nothing.
    public func delete(_ id: UUID) async throws {
        let itemID = ItemID.snippet(id).rawValue
        try await database.write("snippets.delete") { db in
            try db.execute(sql: "DELETE FROM snippet WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM alias WHERE item_id = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM item_override WHERE item_id = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM command_hotkey WHERE item_id = ?", arguments: [itemID])
        }
    }

    /// The snippets whose name, keyword or text contains the query, whatever its case. An
    /// empty query finds them all, ordered by name.
    ///
    /// The matches are ordered by where the query was found: in the name first, then in the
    /// keyword, then in the text. A query of three characters or more is looked up in the
    /// index; a shorter one is compared with the snippets that were changed last.
    public func search(_ query: String) async throws -> [Snippet] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            return try await database.read("snippets.all") { db in
                try Self.fetchAll(db)
            }
        }
        if text.unicodeScalars.count >= Self.shortestIndexedQuery {
            return try await database.read("snippets.search") { db in
                try Self.fetchIndexed(containing: text, db)
            }
        }
        return try await database.read("snippets.searchShort") { db in
            try Self.fetchScanned(containing: text, db)
        }
    }

    /// Every snippet, ordered by name, now and again after every change to the table.
    public func observeAll() -> AsyncThrowingStream<[Snippet], Error> {
        // A write that leaves the table as it was is not a change.
        let observation = ValueObservation.tracking { db in
            try Self.fetchAll(db)
        }.removeDuplicates()
        let writer = database.writer

        return AsyncThrowingStream { continuation in
            let observing = Task {
                do {
                    for try await snippets in observation.values(in: writer) {
                        continuation.yield(snippets)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                observing.cancel()
            }
        }
    }

    // MARK: Writing

    /// The snippet as it is stored. A blank keyword becomes none: the column is UNIQUE, which
    /// any number of rows without a keyword satisfy and two empty keywords would not.
    private static func normalized(_ snippet: Snippet) -> Snippet {
        var stored = snippet
        stored.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let keyword = snippet.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stored.keyword = keyword.isEmpty ? nil : keyword
        return stored
    }

    /// Inserts the snippet, or updates the row with its ID.
    ///
    /// Never `INSERT OR REPLACE`: that deletes the old row without firing the delete trigger,
    /// and its text would stay in `snippet_fts` (see the migration).
    static func write(_ snippet: Snippet, to db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO snippet (id, name, keyword, body, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name, keyword = excluded.keyword, body = excluded.body,
                  updated_at = excluded.updated_at
                """,
            arguments: [
                snippet.id.uuidString, snippet.name, snippet.keyword, snippet.body,
                snippet.createdAt.timeIntervalSince1970, snippet.updatedAt.timeIntervalSince1970,
            ])
    }

    // MARK: Reading

    private static let columns = "id, name, keyword, body, created_at, updated_at"

    static func fetchAll(_ db: Database) throws -> [Snippet] {
        let rows = try Row.fetchAll(db, sql: "SELECT \(columns) FROM snippet")
        return sortedByName(snippets(from: rows))
    }

    private static func fetchIndexed(containing text: String, _ db: Database) throws -> [Snippet] {
        // The whole query as one quoted phrase. With trigrams a phrase matches wherever the
        // text occurs, also in the middle of a word, and inside the quotes nothing the user
        // types is query syntax: not *, :, -, ^ or parentheses, and not AND, OR or NOT.
        let phrase = "\"" + text.replacing("\"", with: "\"\"") + "\""

        // The index says which snippets match and not in what order to show them. Its bm25
        // counts how often the text occurs and how long the snippet is, so a short snippet
        // with the text twice in its body would come before one that has it as its name.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT snippet.id, snippet.name, snippet.keyword, snippet.body,
                       snippet.created_at, snippet.updated_at
                FROM snippet_fts
                JOIN snippet ON snippet.row_id = snippet_fts.rowid
                WHERE snippet_fts MATCH ?
                """,
            arguments: [phrase])
        return sortedByPlaceOfMatch(snippets(from: rows), text: text)
    }

    private static func fetchScanned(containing text: String, _ db: Database) throws -> [Snippet] {
        // Compared here and not with LIKE, which ignores case for ASCII letters only: "är"
        // has to find "Ärger", as "ärg" does through the index.
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT \(columns) FROM snippet ORDER BY updated_at DESC LIMIT \(scanLimit)")

        var matches: [Snippet] = []
        for snippet in snippets(from: rows) {
            if placeOfMatch(of: text, in: snippet) != nil {
                matches.append(snippet)
            }
        }
        return sortedByPlaceOfMatch(matches, text: text)
    }

    private static func snippets(from rows: [Row]) -> [Snippet] {
        var snippets: [Snippet] = []
        for row in rows {
            let storedID: String = row["id"]
            // Only this store writes the table, and it writes UUIDs.
            guard let id = UUID(uuidString: storedID) else {
                Log.storage.error("Skipped a snippet whose ID is not a UUID")
                continue
            }
            let snippet = Snippet(
                id: id, name: row["name"], keyword: row["keyword"], body: row["body"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            snippets.append(snippet)
        }
        return snippets
    }

    /// Where a snippet has the text of a search.
    private enum PlaceOfMatch {
        case name, keyword, body
    }

    private static func placeOfMatch(of text: String, in snippet: Snippet) -> PlaceOfMatch? {
        if snippet.name.range(of: text, options: .caseInsensitive) != nil {
            return .name
        }
        let keyword = snippet.keyword ?? ""
        if keyword.range(of: text, options: .caseInsensitive) != nil {
            return .keyword
        }
        if snippet.body.range(of: text, options: .caseInsensitive) != nil {
            return .body
        }
        return nil
    }

    /// A match in the name first, then one in the keyword, then one in the text, and by name
    /// within each.
    private static func sortedByPlaceOfMatch(_ snippets: [Snippet], text: String) -> [Snippet] {
        var matchesInName: [Snippet] = []
        var matchesInKeyword: [Snippet] = []
        var matchesInBody: [Snippet] = []

        for snippet in snippets {
            switch placeOfMatch(of: text, in: snippet) {
            case .name:
                matchesInName.append(snippet)
            case .keyword:
                matchesInKeyword.append(snippet)
            case .body, nil:
                // The index folds case in its own way. Should it find a match that the
                // comparison here does not see, the snippet goes with the matches in the text.
                matchesInBody.append(snippet)
            }
        }
        return sortedByName(matchesInName) + sortedByName(matchesInKeyword)
            + sortedByName(matchesInBody)
    }

    /// By name, numbers in them counted as numbers, so that "Reply 2" comes before
    /// "Reply 10". The ID breaks a tie between two snippets of one name, so that the order is
    /// the same on every read.
    private static func sortedByName(_ snippets: [Snippet]) -> [Snippet] {
        snippets.sorted { first, second in
            let order = first.name.localizedStandardCompare(second.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return first.id.uuidString < second.id.uuidString
        }
    }
}
