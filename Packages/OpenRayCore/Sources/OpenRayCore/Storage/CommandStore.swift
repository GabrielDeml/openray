import Foundation
import GRDB

/// The user's changes to the commands: aliases, hidden and disabled items, quicklinks and the
/// order of the fallback list (docs/DESIGN.md §4.3.3). They live in the tables of the migration
/// `m3_commands`.
public struct CommandStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func snapshot() async throws -> CommandOverrides {
        try await database.read("commands.snapshot") { db in
            try Self.fetchOverrides(db)
        }
    }

    /// What `snapshot()` returns now, and again after every change to one of the tables.
    public func changes() -> AsyncThrowingStream<CommandOverrides, Error> {
        // Two writes that leave the tables as they were are not a change.
        let observation = ValueObservation.tracking { db in
            try Self.fetchOverrides(db)
        }.removeDuplicates()
        let writer = database.writer

        return AsyncThrowingStream { continuation in
            let observing = Task {
                do {
                    for try await overrides in observation.values(in: writer) {
                        continuation.yield(overrides)
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

    /// Makes these the aliases of the item: an alias it had and that is not among them goes,
    /// and the others are added. An alias stands for one item, so one that another item had is
    /// taken from it. Aliases are stored folded, as a search query is; one that is empty then
    /// is left out.
    ///
    /// All of it is one transaction. The settings pane sends the whole list for an item, and
    /// two changes made in quick succession cannot undo each other.
    public func setAliases(_ aliases: [String], for id: ItemID) async throws {
        var foldedAliases: [String] = []
        for alias in aliases {
            let folded = Self.storedAlias(for: alias)
            if !folded.isEmpty && !foldedAliases.contains(folded) {
                foldedAliases.append(folded)
            }
        }
        let storedAliases = foldedAliases

        try await database.write("commands.setAliases") { db in
            try db.execute(sql: "DELETE FROM alias WHERE item_id = ?", arguments: [id.rawValue])
            for storedAlias in storedAliases {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO alias (alias, item_id) VALUES (?, ?)",
                    arguments: [storedAlias, id.rawValue])
            }
        }
    }

    /// Changes what is stored about the item: the closure gets the stored override, or one
    /// that says nothing, and what it leaves is written back. An override that neither hides
    /// nor disables removes the row.
    ///
    /// The stored value is read and written in one transaction, so two changes made in quick
    /// succession, such as two switches in Settings, cannot undo each other.
    public func updateOverride(
        for id: ItemID, _ change: @escaping @Sendable (inout ItemOverride) -> Void
    ) async throws {
        try await database.write("commands.updateOverride") { db in
            let stored = try Row.fetchOne(
                db, sql: "SELECT hidden, disabled FROM item_override WHERE item_id = ?",
                arguments: [id.rawValue])

            var override = ItemOverride()
            if let stored {
                override = ItemOverride(hidden: stored["hidden"], disabled: stored["disabled"])
            }
            change(&override)

            if override.isDefault {
                try db.execute(
                    sql: "DELETE FROM item_override WHERE item_id = ?", arguments: [id.rawValue])
            } else {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO item_override (item_id, hidden, disabled)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [id.rawValue, override.hidden, override.disabled])
            }
        }
    }

    /// Adds the quicklink, or replaces the one with the same ID.
    public func saveQuicklink(_ quicklink: Quicklink) async throws {
        try await database.write("commands.saveQuicklink") { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO quicklink (id, name, template, open_with, icon, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    quicklink.id.uuidString, quicklink.name, quicklink.template,
                    quicklink.openWith, quicklink.icon,
                    quicklink.createdAt.timeIntervalSince1970,
                ])
        }
    }

    /// Deletes the quicklink together with what was stored about its item, so that no alias or
    /// fallback row is left pointing at nothing.
    public func deleteQuicklink(_ id: UUID) async throws {
        let itemID = ItemID.quicklink(id).rawValue
        try await database.write("commands.deleteQuicklink") { db in
            try db.execute(sql: "DELETE FROM quicklink WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM alias WHERE item_id = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM item_override WHERE item_id = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM fallback WHERE item_id = ?", arguments: [itemID])
        }
    }

    /// Changes the fallback list: the closure gets the stored order, and what it leaves is
    /// written back. An item named twice keeps its first place.
    ///
    /// Read and written in one transaction, like `updateOverride` and for the same reason.
    public func updateFallbackOrder(
        _ change: @escaping @Sendable (inout [ItemID]) -> Void
    ) async throws {
        try await database.write("commands.updateFallbackOrder") { db in
            var order = try Self.fetchFallbackOrder(db)
            change(&order)

            try db.execute(sql: "DELETE FROM fallback")
            var position = 0
            var seenIDs: Set<ItemID> = []
            for id in order {
                let isNewID = seenIDs.insert(id).inserted
                if !isNewID { continue }
                try db.execute(
                    sql: "INSERT INTO fallback (item_id, position) VALUES (?, ?)",
                    arguments: [id.rawValue, position])
                position += 1
            }
        }
    }

    /// An alias as it is stored and compared: folded like `SearchQuery.normalized`, so that it
    /// equals the query of whoever types it.
    static func storedAlias(for alias: String) -> String {
        SearchQuery(alias).normalized
    }

    // MARK: Reading

    private static func fetchOverrides(_ db: Database) throws -> CommandOverrides {
        CommandOverrides(
            aliases: try fetchAliases(db),
            overrides: try fetchItemOverrides(db),
            quicklinks: try fetchQuicklinks(db),
            fallbackOrder: try fetchFallbackOrder(db))
    }

    private static func fetchAliases(_ db: Database) throws -> [String: ItemID] {
        let rows = try Row.fetchAll(db, sql: "SELECT alias, item_id FROM alias")

        var aliases: [String: ItemID] = [:]
        for row in rows {
            let alias: String = row["alias"]
            aliases[alias] = ItemID(rawValue: row["item_id"])
        }
        return aliases
    }

    private static func fetchItemOverrides(_ db: Database) throws -> [ItemID: ItemOverride] {
        let rows = try Row.fetchAll(db, sql: "SELECT item_id, hidden, disabled FROM item_override")

        var overrides: [ItemID: ItemOverride] = [:]
        for row in rows {
            let id = ItemID(rawValue: row["item_id"])
            overrides[id] = ItemOverride(hidden: row["hidden"], disabled: row["disabled"])
        }
        return overrides
    }

    private static func fetchQuicklinks(_ db: Database) throws -> [Quicklink] {
        // The name breaks a tie between two quicklinks made in the same instant, so that the
        // order is the same on every read.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, template, open_with, icon, created_at FROM quicklink
                ORDER BY created_at, name, id
                """)

        var quicklinks: [Quicklink] = []
        for row in rows {
            let storedID: String = row["id"]
            // Only this store writes the table, and it writes UUIDs.
            guard let id = UUID(uuidString: storedID) else {
                Log.storage.error("Skipped a quicklink whose ID is not a UUID")
                continue
            }
            let quicklink = Quicklink(
                id: id, name: row["name"], template: row["template"],
                openWith: row["open_with"], icon: row["icon"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]))
            quicklinks.append(quicklink)
        }
        return quicklinks
    }

    private static func fetchFallbackOrder(_ db: Database) throws -> [ItemID] {
        let rawIDs = try String.fetchAll(db, sql: "SELECT item_id FROM fallback ORDER BY position")
        return rawIDs.map { ItemID(rawValue: $0) }
    }
}
