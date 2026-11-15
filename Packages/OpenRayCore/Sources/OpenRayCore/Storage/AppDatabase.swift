import Foundation
import GRDB

/// `OpenRay.sqlite`, the database for user content and anything that grows (docs/DESIGN.md
/// §4.3). The stores are built on it. GRDB is not part of any public interface here, so the app
/// target never imports it.
public struct AppDatabase: Sendable {
    static let fileName = "OpenRay.sqlite"

    let writer: any DatabaseWriter
    /// Whether the file that was there could not be used and this is an empty database in its
    /// place. The app tells the user once, because what the launcher had learned and the
    /// user's aliases and quicklinks are gone from it (§4.3.8).
    public let wasReplaced: Bool

    /// Opens the database in `directory` and brings its schema up to date. The directory and the
    /// file are created when they are missing.
    ///
    /// A database that cannot be opened or migrated is renamed to `OpenRay.sqlite.corrupt-<date>`
    /// and replaced by an empty one: a broken file costs what the launcher has learned, but not
    /// the launcher. The error is thrown only when the empty one cannot be opened either.
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

        moveAside(file)
        let writer = try open(file)
        return AppDatabase(writer: writer, wasReplaced: true)
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

        return migrator
    }
}

extension AppDatabase {
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
