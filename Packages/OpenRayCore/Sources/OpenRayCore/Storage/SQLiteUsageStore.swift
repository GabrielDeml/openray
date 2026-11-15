import Foundation
import GRDB

/// The usage store of the running app (docs/DESIGN.md §4.2.7). Picks are counted in memory,
/// where ranking reads them without waiting, and each one is also written to the `usage` and
/// `query_usage` tables, which the next launch loads.
public actor SQLiteUsageStore: UsageStore {
    /// An item whose score has faded below this is forgotten at launch.
    static let lowestKeptScore = 0.01
    /// `query_usage` is cut back to this many rows at launch. The highest scores stay.
    static let queryRowLimit = 5_000

    private struct ItemRow: Sendable {
        var id: ItemID
        var usage: UsageSnapshot.ItemUsage
    }

    private struct QueryRow: Sendable {
        var id: ItemID
        var query: String
        var usage: UsageSnapshot.QueryUsage
    }

    private let database: AppDatabase
    private var usage: UsageSnapshot

    /// Loads what earlier launches stored and deletes what has faded since.
    ///
    /// - Parameter now: The time the stored scores are judged at. Tests pass their own.
    public init(database: AppDatabase, now: Date = Date()) async throws {
        self.database = database

        let (itemRows, queryRows) = try await database.read("usage.load") { db in
            (try Self.fetchItemRows(db), try Self.fetchQueryRows(db))
        }

        var itemUsage: [ItemID: UsageSnapshot.ItemUsage] = [:]
        var fadedItems: [ItemID] = []
        for row in itemRows {
            let score = Frecency.decayed(row.usage.score, from: row.usage.referenceTime, to: now)
            if score < Self.lowestKeptScore {
                fadedItems.append(row.id)
            } else {
                itemUsage[row.id] = row.usage
            }
        }

        // The rows are stored with the score they had when they were last written. Which of them
        // count least today depends on how long ago that was, so they are compared as of now.
        var scoredQueryRows: [(row: QueryRow, score: Double)] = []
        for row in queryRows {
            let score = Frecency.decayed(row.usage.score, from: row.usage.referenceTime, to: now)
            scoredQueryRows.append((row: row, score: score))
        }
        scoredQueryRows.sort { first, second in first.score > second.score }

        var queryUsage: [ItemID: [String: UsageSnapshot.QueryUsage]] = [:]
        var surplusQueryRows: [QueryRow] = []
        for (position, scored) in scoredQueryRows.enumerated() {
            let row = scored.row
            if position < Self.queryRowLimit {
                queryUsage[row.id, default: [:]][row.query] = row.usage
            } else {
                surplusQueryRows.append(row)
            }
        }

        usage = UsageSnapshot(itemUsage: itemUsage, queryUsage: queryUsage)

        if fadedItems.isEmpty && surplusQueryRows.isEmpty { return }
        do {
            try await Self.delete(
                fadedItems: fadedItems, surplusQueryRows: surplusQueryRows, from: database)
        } catch {
            // The usage was read, and that is what the launcher needs. Rows that could not be
            // deleted, on a full disk for one, are dropped again at the next launch.
            Log.storage.error("Cannot delete faded usage rows: \(error)")
        }
    }

    public func snapshot() -> UsageSnapshot {
        usage
    }

    /// Counts the pick in memory first, so ranking sees it at once, and then writes it to the
    /// database. When the write fails the pick still counts until the app quits.
    public func record(pick id: ItemID, query: String, at time: Date) async throws {
        usage.record(pick: id, query: query, at: time)

        // What is written is what the snapshot now holds. The scores are not computed a second
        // time here, so the tables cannot drift from what ranking uses.
        guard let item = usage.itemUsage[id] else { return }
        let storedQuery = UsageSnapshot.storedQuery(for: query)
        // A pick from the empty field has no query row.
        let queryEntry = usage.queryUsage[id]?[storedQuery]

        try await database.write("usage.recordPick") { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO usage (item_id, score, ref_time, use_count)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    id.rawValue, item.score, item.referenceTime.timeIntervalSince1970,
                    item.useCount,
                ])

            guard let queryEntry else { return }
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO query_usage (query, item_id, score, ref_time)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    storedQuery, id.rawValue, queryEntry.score,
                    queryEntry.referenceTime.timeIntervalSince1970,
                ])
        }
    }

    private static func delete(
        fadedItems: [ItemID], surplusQueryRows: [QueryRow], from database: AppDatabase
    ) async throws {
        try await database.write("usage.deleteFaded") { db in
            for id in fadedItems {
                try db.execute(
                    sql: "DELETE FROM usage WHERE item_id = ?", arguments: [id.rawValue])
            }
            for row in surplusQueryRows {
                try db.execute(
                    sql: "DELETE FROM query_usage WHERE query = ? AND item_id = ?",
                    arguments: [row.query, row.id.rawValue])
            }
        }
    }

    private static func fetchItemRows(_ db: Database) throws -> [ItemRow] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT item_id, score, ref_time, use_count FROM usage")

        var itemRows: [ItemRow] = []
        for row in rows {
            let id = ItemID(rawValue: row["item_id"])
            let usage = UsageSnapshot.ItemUsage(
                score: row["score"],
                referenceTime: Date(timeIntervalSince1970: row["ref_time"]),
                useCount: row["use_count"])
            itemRows.append(ItemRow(id: id, usage: usage))
        }
        return itemRows
    }

    private static func fetchQueryRows(_ db: Database) throws -> [QueryRow] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT query, item_id, score, ref_time FROM query_usage")

        var queryRows: [QueryRow] = []
        for row in rows {
            let id = ItemID(rawValue: row["item_id"])
            let usage = UsageSnapshot.QueryUsage(
                score: row["score"],
                referenceTime: Date(timeIntervalSince1970: row["ref_time"]))
            queryRows.append(QueryRow(id: id, query: row["query"], usage: usage))
        }
        return queryRows
    }
}
