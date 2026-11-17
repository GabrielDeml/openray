import Foundation
import GRDB

/// `OpenRay.sqlite`, the database for user content and anything that grows (docs/DESIGN.md
/// §4.3). The stores are built on it. GRDB is not part of any public interface here, so the app
/// target never imports it.
public struct AppDatabase: Sendable {
    static let fileName = "OpenRay.sqlite"

    let writer: any DatabaseWriter
    /// Whether the file that was there could not be used and this is a new database in its
    /// place. The app tells the user once, because what the launcher had learned and the
    /// user's aliases and quicklinks are gone from it (§4.3.8). The snippets and the hotkeys
    /// of commands are not, if the old file could still be read that far.
    public let wasReplaced: Bool

    /// Opens the database in `directory` and brings its schema up to date. The directory and the
    /// file are created when they are missing.
    ///
    /// A database that cannot be opened or migrated is renamed to `OpenRay.sqlite.corrupt-<date>`
    /// and replaced by a new one: a broken file costs what the launcher has learned, but not
    /// the launcher. The error is thrown only when the new one cannot be opened either.
    ///
    /// This works on the disk and blocks until it is done. Callers on the main actor go through
    /// a `@concurrent` function.
    public static func openOnDisk(at directory: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: fileName, directoryHint: .notDirectory)

        do {
            let writer = try open(file)
            return AppDatabase(writer: writer, wasReplaced: false)
        } catch {
            Log.storage.error("Cannot open the database, moving it aside: \(error)")
        }

        return try replaceDatabase(at: file)
    }

    /// Moves the database at `file` aside and opens a new one in its place. Two things are
    /// carried over when the old file still gives them up (§4.3.8): the snippets, which of
    /// everything in it are the most work to write again, and the hotkeys of commands, because
    /// a global hotkey that has silently stopped working is the loss that is hardest to notice.
    ///
    /// Internal for the tests, which call it on a file that is in good order. A file that
    /// fails to migrate cannot be made for a test, because in Debug builds the migrator
    /// erases such a file instead of failing.
    static func replaceDatabase(at file: URL) throws -> AppDatabase {
        // Read before the files are renamed. In WAL mode the newest rows can still be in the
        // `-wal` file, which SQLite no longer finds under its new name.
        let carriedOver = readCarriedOverRows(ofUnusableDatabase: file)
        moveAside(file)

        let writer = try open(file)
        if !carriedOver.snippets.isEmpty {
            store(carriedOver.snippets, in: writer)
        }
        if !carriedOver.hotKeys.isEmpty {
            store(carriedOver.hotKeys, in: writer)
        }
        return AppDatabase(writer: writer, wasReplaced: true)
    }

    /// What a new database takes from the one it replaces.
    private struct CarriedOverRows {
        var snippets: [Snippet] = []
        var hotKeys: [ItemID: HotKey] = [:]
    }

    /// The snippets and the command hotkeys in a database that could not be opened; of each,
    /// none when they cannot be read either. The file is opened read-only and without the
    /// migrations: whatever is wrong with it, this must not change it.
    private static func readCarriedOverRows(ofUnusableDatabase file: URL) -> CarriedOverRows {
        var carriedOver = CarriedOverRows()
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(
                path: file.path(percentEncoded: false), configuration: configuration)

            // Each table is read on its own, so that one that cannot be read does not cost
            // the other.
            do {
                carriedOver.snippets = try queue.read { db in
                    try SnippetStore.fetchAll(db)
                }
            } catch {
                Log.storage.error("Cannot read the snippets of the old database: \(error)")
            }
            do {
                carriedOver.hotKeys = try queue.read { db in
                    // A file from before `m9_command_hotkeys` has no such table and no hotkeys.
                    guard try db.tableExists("command_hotkey") else { return [:] }
                    return try CommandHotKeyStore.fetchAll(db)
                }
            } catch {
                Log.storage.error("Cannot read the command hotkeys of the old database: \(error)")
            }

            // Closed here and not whenever the value goes away: the file is renamed next.
            try queue.close()
        } catch {
            Log.storage.error("Cannot read the old database: \(error)")
        }
        return carriedOver
    }

    /// Puts the snippets of the old database into the new one, with the IDs and dates they
    /// had. All of them or none.
    private static func store(_ snippets: [Snippet], in writer: any DatabaseWriter) {
        do {
            try writer.write { db in
                for snippet in snippets {
                    try SnippetStore.write(snippet, to: db)
                }
            }
            Log.storage.notice(
                "Carried \(snippets.count, privacy: .public) snippets over to the new database")
        } catch {
            // The old file is kept, so they are not lost, only not here.
            Log.storage.error("Cannot carry the snippets over to the new database: \(error)")
        }
    }

    /// Puts the command hotkeys of the old database into the new one. All of them or none.
    ///
    /// They still name their items: the ID of an app, a system or window command, a script and
    /// a seeded quicklink is the same in every database, and the snippets were just carried
    /// over with theirs. The hotkey of a quicklink the user made waits for an item that does
    /// not come back, and gives its chord to whatever is assigned it next.
    private static func store(_ hotKeys: [ItemID: HotKey], in writer: any DatabaseWriter) {
        do {
            try writer.write { db in
                for (id, hotKey) in hotKeys {
                    try CommandHotKeyStore.write(hotKey, for: id, to: db)
                }
            }
            let count = hotKeys.count
            Log.storage.notice(
                "Carried \(count, privacy: .public) command hotkeys over to the new database")
        } catch {
            Log.storage.error("Cannot carry the command hotkeys over to the new database: \(error)")
        }
    }

    /// A database that is gone when the last copy of the value is, for tests.
    public static func inMemory() throws -> AppDatabase {
        // A pool needs a file. A queue is a single connection, which is all a test needs.
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return AppDatabase(writer: queue, wasReplaced: false)
    }

    private static func open(_ file: URL) throws -> any DatabaseWriter {
        // No pragmas are set by hand: a pool always runs in WAL mode, and GRDB turns foreign
        // keys on for every connection it opens.
        let pool = try DatabasePool(path: file.path(percentEncoded: false))
        try migrator.migrate(pool)
        return pool
    }

    /// Renames the database together with the two files SQLite keeps beside it in WAL mode. Left
    /// behind, they would be taken for the log of the new database.
    private static func moveAside(_ file: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = ".corrupt-" + formatter.string(from: Date())

        let databasePath = file.path(percentEncoded: false)
        for path in [databasePath, databasePath + "-wal", databasePath + "-shm"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.moveItem(atPath: path, toPath: path + suffix)
            } catch {
                Log.storage.error("Cannot move a database file aside: \(error)")
            }
        }
    }

    /// Migration names carry the milestone that added them. A migration that has shipped is
    /// never edited; a schema change is a new migration.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            // While a migration is being written its text changes between runs. Starting over
            // is then better than a database in a state no release ever had.
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("m2_usage") { db in
            try db.execute(
                sql: """
                    CREATE TABLE usage (
                      item_id   TEXT PRIMARY KEY,
                      score     REAL NOT NULL,
                      ref_time  REAL NOT NULL,
                      use_count INTEGER NOT NULL
                    );
                    CREATE TABLE query_usage (
                      query     TEXT NOT NULL,
                      item_id   TEXT NOT NULL,
                      score     REAL NOT NULL,
                      ref_time  REAL NOT NULL,
                      PRIMARY KEY (query, item_id)
                    );
                    """)
        }

        migrator.registerMigration("m3_commands") { db in
            try db.execute(
                sql: """
                    CREATE TABLE alias (alias TEXT PRIMARY KEY, item_id TEXT NOT NULL);
                    CREATE TABLE item_override (
                      item_id  TEXT PRIMARY KEY,
                      hidden   INTEGER NOT NULL DEFAULT 0,
                      disabled INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE quicklink (
                      id TEXT PRIMARY KEY,
                      name TEXT NOT NULL, template TEXT NOT NULL,
                      open_with TEXT,
                      icon TEXT, created_at REAL NOT NULL
                    );
                    CREATE TABLE fallback (item_id TEXT PRIMARY KEY, position INTEGER NOT NULL);
                    """)

            for quicklink in CommandSeeds.quicklinks {
                try db.execute(
                    sql: """
                        INSERT INTO quicklink (id, name, template, open_with, icon, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        quicklink.id.uuidString, quicklink.name, quicklink.template,
                        quicklink.openWith, quicklink.icon,
                        quicklink.createdAt.timeIntervalSince1970,
                    ])
            }
            for (position, id) in CommandSeeds.fallbackOrder.enumerated() {
                try db.execute(
                    sql: "INSERT INTO fallback (item_id, position) VALUES (?, ?)",
                    arguments: [id.rawValue, position])
            }
        }

        // What is permanent here, once a release has run this migration:
        //
        // - `row_id` is the key `snippet_fts` hangs on. It is a column of its own because the
        //   implicit rowid of a table with a text primary key may be renumbered by VACUUM,
        //   which would leave every row of the index pointing at another snippet.
        // - `id`, the UUID, is the snippet's identity everywhere outside this table: in its
        //   `ItemID` (`snippet:<uuid>`), and through that in the usage and alias tables.
        //   `row_id` never leaves `SnippetStore`, because the integers are handed out anew
        //   when the rows are carried over into a new database (`replaceDatabase`).
        // - The table is never written with `INSERT OR REPLACE`. That deletes the old row
        //   without firing the delete trigger, and its text would stay in the index.
        // - `snippet_fts` is an index and holds nothing of its own: a later migration may
        //   drop it and build it again, with another tokenizer if need be. The `snippet`
        //   table may not change shape, because a database that cannot be migrated is still
        //   read for its snippets.
        migrator.registerMigration("m7_snippets") { db in
            try db.execute(
                sql: """
                    CREATE TABLE snippet (
                      row_id     INTEGER PRIMARY KEY,
                      id         TEXT NOT NULL UNIQUE,
                      name       TEXT NOT NULL,
                      keyword    TEXT UNIQUE,
                      body       TEXT NOT NULL,
                      created_at REAL NOT NULL,
                      updated_at REAL NOT NULL
                    );
                    CREATE VIRTUAL TABLE snippet_fts USING fts5(
                      name, keyword, body,
                      content='snippet', content_rowid='row_id', tokenize='trigram'
                    );

                    CREATE TRIGGER snippet_after_insert AFTER INSERT ON snippet BEGIN
                      INSERT INTO snippet_fts (rowid, name, keyword, body)
                      VALUES (new.row_id, new.name, new.keyword, new.body);
                    END;
                    CREATE TRIGGER snippet_after_delete AFTER DELETE ON snippet BEGIN
                      INSERT INTO snippet_fts (snippet_fts, rowid, name, keyword, body)
                      VALUES ('delete', old.row_id, old.name, old.keyword, old.body);
                    END;
                    CREATE TRIGGER snippet_after_update AFTER UPDATE ON snippet BEGIN
                      INSERT INTO snippet_fts (snippet_fts, rowid, name, keyword, body)
                      VALUES ('delete', old.row_id, old.name, old.keyword, old.body);
                      INSERT INTO snippet_fts (rowid, name, keyword, body)
                      VALUES (new.row_id, new.name, new.keyword, new.body);
                    END;
                    """)
        }

        // What is permanent here, once a release has run this migration:
        //
        // - The table may not change shape, because a database that cannot be migrated is
        //   still read for its hotkeys (`replaceDatabase`).
        // - `key_code` is `HotKey.keyCode` and `modifiers` is `HotKey.Modifiers.rawValue`,
        //   whose bit assignments never change.
        // - The two constraints are the rule itself: one chord for an item, and one item for
        //   a chord.
        migrator.registerMigration("m9_command_hotkeys") { db in
            try db.execute(
                sql: """
                    CREATE TABLE command_hotkey (
                      item_id   TEXT PRIMARY KEY,
                      key_code  INTEGER NOT NULL,
                      modifiers INTEGER NOT NULL,
                      UNIQUE (key_code, modifiers)
                    );
                    """)
        }

        return migrator
    }
}

extension AppDatabase {
    /// Reads from the database inside a `dbQuery` signpost interval (docs/DESIGN.md §5.3). The
    /// stores read and write through these two, so that every query shows up in Instruments
    /// under the name its store gives it.
    func read<T: Sendable>(
        _ name: String, _ query: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let signposter = Signposts.signposter
        // An ID of its own for every query, because queries overlap.
        let interval = signposter.beginInterval(
            Signposts.dbQuery, id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        defer { signposter.endInterval(Signposts.dbQuery, interval) }
        return try await writer.read(query)
    }

    /// Runs the updates in one transaction, inside a `dbQuery` signpost interval.
    func write<T: Sendable>(
        _ name: String, _ updates: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(
            Signposts.dbQuery, id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        defer { signposter.endInterval(Signposts.dbQuery, interval) }
        return try await writer.write(updates)
    }

    /// Whether this SQLite finds text from the middle of a word in an FTS5 table with the
    /// trigram tokenizer, which clipboard and snippet search are designed around (§4.3.1).
    ///
    /// Nothing in the app calls this. It exists for the test that guards the assumption on
    /// every SDK the project is built with, because the tests do not link GRDB.
    func supportsTrigramSearch() async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE temp.trigram_probe USING fts5(body, tokenize='trigram');
                    INSERT INTO trigram_probe (body) VALUES ('Activity Monitor');
                    """)
            let matchCount = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM trigram_probe WHERE trigram_probe MATCH 'tivi'")
            try db.execute(sql: "DROP TABLE temp.trigram_probe")
            return matchCount == 1
        }
    }
}
