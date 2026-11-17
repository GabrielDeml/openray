import GRDB

/// The global hotkeys the user has given to commands (docs/DESIGN.md §4.3.3). They live in the
/// table `command_hotkey` of the migration `m9_command_hotkeys`, which holds one row for an
/// item and no chord twice.
///
/// `CommandHotKeys` is the only one that writes here while OpenRay runs, apart from the two
/// deletes that take an item's row with it (`CommandStore.deleteQuicklink`,
/// `SnippetStore.delete`).
public struct CommandHotKeyStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() async throws -> [ItemID: HotKey] {
        try await database.read("hotkeys.all") { db in
            try Self.fetchAll(db)
        }
    }

    /// Makes `key` the hotkey of the item, in place of the one it had. A chord belongs to one
    /// item, so the row of another item that has it is deleted in the same transaction.
    ///
    /// The caller decides whether the other item may lose it: `CommandHotKeys` refuses the
    /// chord of an item that exists, and lets one that is gone give it up this way.
    public func set(_ key: HotKey, for id: ItemID) async throws {
        try await database.write("hotkeys.set") { db in
            try Self.write(key, for: id, to: db)
        }
    }

    public func remove(_ id: ItemID) async throws {
        try await database.write("hotkeys.remove") { db in
            try db.execute(
                sql: "DELETE FROM command_hotkey WHERE item_id = ?", arguments: [id.rawValue])
        }
    }

    /// The two integers stored for the item, or nil when it has no row.
    ///
    /// Nothing in the app calls this. It exists for the test that pins the stored format,
    /// because the tests do not link GRDB.
    func storedValues(for id: ItemID) async throws -> (keyCode: Int64, modifiers: Int64)? {
        try await database.read("hotkeys.storedValues") { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT key_code, modifiers FROM command_hotkey WHERE item_id = ?",
                arguments: [id.rawValue])
            guard let row else { return nil }
            return (keyCode: row["key_code"], modifiers: row["modifiers"])
        }
    }

    // The two below are also what `AppDatabase.replaceDatabase` reads the old file and fills
    // the new one with.

    static func fetchAll(_ db: Database) throws -> [ItemID: HotKey] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT item_id, key_code, modifiers FROM command_hotkey")

        var hotKeys: [ItemID: HotKey] = [:]
        for row in rows {
            let storedKeyCode: Int64 = row["key_code"]
            let storedModifiers: Int64 = row["modifiers"]
            // Only this store writes the table, and it writes what a `HotKey` holds.
            guard
                let keyCode = UInt32(exactly: storedKeyCode),
                let modifiers = UInt8(exactly: storedModifiers)
            else {
                Log.storage.error("Skipped a command hotkey whose stored values are out of range")
                continue
            }
            let id = ItemID(rawValue: row["item_id"])
            hotKeys[id] = HotKey(keyCode: keyCode, modifiers: HotKey.Modifiers(rawValue: modifiers))
        }
        return hotKeys
    }

    static func write(_ key: HotKey, for id: ItemID, to db: Database) throws {
        let keyCode = Int64(key.keyCode)
        let modifiers = Int64(key.modifiers.rawValue)

        try db.execute(
            sql: """
                DELETE FROM command_hotkey
                WHERE key_code = ? AND modifiers = ? AND item_id <> ?
                """,
            arguments: [keyCode, modifiers, id.rawValue])
        try db.execute(
            sql: """
                INSERT INTO command_hotkey (item_id, key_code, modifiers) VALUES (?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                  key_code = excluded.key_code, modifiers = excluded.modifiers
                """,
            arguments: [id.rawValue, keyCode, modifiers])
    }
}
