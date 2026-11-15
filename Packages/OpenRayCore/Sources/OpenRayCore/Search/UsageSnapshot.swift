import Foundation

/// What the user has picked so far, as ranking reads it (docs/DESIGN.md §4.2.7). A value in
/// memory: reading it never touches the disk.
public struct UsageSnapshot: Sendable {
    /// How much one item was picked: a row of the `usage` table.
    struct ItemUsage: Sendable, Equatable {
        /// The decayed score as of `referenceTime`.
        var score: Double
        var referenceTime: Date
        var useCount: Int
    }

    /// How much one item was picked for one query: a row of the `query_usage` table.
    struct QueryUsage: Sendable, Equatable {
        /// The decayed score as of `referenceTime`.
        var score: Double
        var referenceTime: Date
    }

    /// Stored queries are cut to this many unicode scalars.
    static let maximumQueryLength = 32

    private(set) var itemUsage: [ItemID: ItemUsage]
    /// By item and then by stored query, so that `affinity` only walks the queries of one item.
    private(set) var queryUsage: [ItemID: [String: QueryUsage]]

    /// A snapshot of no usage at all: a fresh install, or a database that could not be opened.
    public init() {
        itemUsage = [:]
        queryUsage = [:]
    }

    /// A snapshot of rows loaded from the database.
    init(itemUsage: [ItemID: ItemUsage], queryUsage: [ItemID: [String: QueryUsage]]) {
        self.itemUsage = itemUsage
        self.queryUsage = queryUsage
    }

    /// How often and how recently the item was picked, whatever the query was. One pick just
    /// now is 1.
    public func frecency(of id: ItemID, at now: Date) -> Double {
        guard let usage = itemUsage[id] else { return 0 }
        return Frecency.decayed(usage.score, from: usage.referenceTime, to: now)
    }

    /// How strongly earlier picks tie the item to a query that starts like this one. A pick of
    /// Safari after typing "saf" counts a third for "s", two thirds for "sa" and fully for "saf".
    ///
    /// - Parameter query: The query as `SearchQuery.normalized` gives it. Ranking asks once for
    ///   every matching item on every keystroke, so the folding is left to the caller, who does
    ///   it once.
    public func affinity(of id: ItemID, query: String, at now: Date) -> Double {
        guard let storedQueries = queryUsage[id] else { return 0 }

        // Cut like the stored queries, so that a longer query still finds the one it was
        // stored as.
        let typed = Array(query.unicodeScalars.prefix(Self.maximumQueryLength))
        if typed.isEmpty { return 0 }

        var affinity = 0.0
        for (storedQuery, usage) in storedQueries {
            let stored = storedQuery.unicodeScalars
            guard stored.starts(with: typed) else { continue }
            let score = Frecency.decayed(usage.score, from: usage.referenceTime, to: now)
            let typedShare = Double(typed.count) / Double(stored.count)
            affinity += score * typedShare
        }
        return affinity
    }

    /// Counts one pick of the item, made at `time` with `query` in the search field.
    ///
    /// - Parameter query: The query as typed. It is folded here.
    public mutating func record(pick id: ItemID, query: String, at time: Date) {
        var item = itemUsage[id] ?? ItemUsage(score: 0, referenceTime: time, useCount: 0)
        item.score = Frecency.decayed(item.score, from: item.referenceTime, to: time) + 1
        item.referenceTime = time
        item.useCount += 1
        itemUsage[id] = item

        // A pick from the empty field says nothing about any query.
        let storedQuery = Self.storedQuery(for: query)
        if storedQuery.isEmpty { return }

        var entry = queryUsage[id]?[storedQuery] ?? QueryUsage(score: 0, referenceTime: time)
        entry.score = Frecency.decayed(entry.score, from: entry.referenceTime, to: time) + 1
        entry.referenceTime = time
        queryUsage[id, default: [:]][storedQuery] = entry
    }

    /// The form a query is stored in: folded, and cut to `maximumQueryLength` scalars.
    static func storedQuery(for query: String) -> String {
        let normalized = SearchQuery(query).normalized
        var stored = String.UnicodeScalarView()
        stored.append(contentsOf: normalized.unicodeScalars.prefix(maximumQueryLength))
        return String(stored)
    }
}
