import Foundation
import Testing

@testable import OpenRayCore

// The databases on disk live in a directory of their own under the temporary directory, never
// in Application Support, and are removed when the test ends.
@Suite struct AppDatabaseTests {
    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "OpenRayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func fileExists(_ name: String, in directory: URL) -> Bool {
        let file = directory.appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    @Test(.timeLimit(.minutes(1)))
    func inMemoryDatabaseHasTheUsageTables() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)

        try await store.record(pick: safari, query: "saf", at: start)

        let usage = await store.snapshot()
        #expect(usage.frecency(of: safari, at: start) == 1)
    }

    @Test func openingOnDiskCreatesAPrivateDirectoryAndTheDatabaseFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try AppDatabase.openOnDisk(at: directory)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.path(percentEncoded: false))
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        #expect(fileExists("OpenRay.sqlite", in: directory))
    }

    @Test func existingDirectoryKeepsItsPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o750])

        _ = try AppDatabase.openOnDisk(at: directory)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.path(percentEncoded: false))
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o750)
    }

    @Test(.timeLimit(.minutes(1)))
    func databaseOnDiskRunsInWALMode() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.openOnDisk(at: directory)
        let store = try await SQLiteUsageStore(database: database, now: start)

        try await store.record(pick: safari, query: "saf", at: start)

        // SQLite deletes the log when the last connection closes, so this is checked while the
        // database is still open.
        #expect(fileExists("OpenRay.sqlite-wal", in: directory))
        withExtendedLifetime(database) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func reopeningTheDirectoryKeepsWhatWasStored() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let database = try AppDatabase.openOnDisk(at: directory)
            let store = try await SQLiteUsageStore(database: database, now: start)
            try await store.record(pick: safari, query: "saf", at: start)
        }

        let reopened = try AppDatabase.openOnDisk(at: directory)
        let store = try await SQLiteUsageStore(database: reopened, now: start)
        let usage = await store.snapshot()
        #expect(usage.frecency(of: safari, at: start) == 1)
        #expect(usage.affinity(of: safari, query: "saf", at: start) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func unreadableDatabaseIsMovedAsideAndReplacedByAnEmptyOne() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x5A, count: 4096)
        try garbage.write(to: directory.appending(path: "OpenRay.sqlite"))

        let database = try AppDatabase.openOnDisk(at: directory)

        let fileNames = try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))
        let movedAside = fileNames.filter { name in name.hasPrefix("OpenRay.sqlite.corrupt-") }
        #expect(movedAside.count == 1)
        if let name = movedAside.first {
            let kept = try Data(contentsOf: directory.appending(path: name))
            #expect(kept == garbage)
        }

        // The file that took its place is a working database.
        let store = try await SQLiteUsageStore(database: database, now: start)
        try await store.record(pick: safari, query: "saf", at: start)
        let reloaded = try await SQLiteUsageStore(database: database, now: start)
        #expect(await reloaded.snapshot().frecency(of: safari, at: start) == 1)

        // The app is told, so that it can tell the user; the next launch finds a good file.
        #expect(database.wasReplaced)
        #expect(try AppDatabase.openOnDisk(at: directory).wasReplaced == false)
    }

    @Test func databaseThatOpensWasNotReplaced() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try AppDatabase.openOnDisk(at: directory).wasReplaced == false)
        #expect(try AppDatabase.inMemory().wasReplaced == false)
    }

    // The fixture is the database of a milestone 2 build that had counted three picks. It was
    // written by that build's code, not by today's migrations.
    @Test(.timeLimit(.minutes(1)))
    func databaseOfMilestone2KeepsItsUsageAndGainsTheLaterTables() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try #require(
            Bundle.module.url(
                forResource: "m2", withExtension: "sqlite", subdirectory: "Fixtures/databases"))
        try FileManager.default.copyItem(
            at: fixture, to: directory.appending(path: "OpenRay.sqlite"))

        let database = try AppDatabase.openOnDisk(at: directory)

        #expect(!database.wasReplaced)
        let pickedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let usage = await (try SQLiteUsageStore(database: database, now: pickedAt)).snapshot()
        #expect(usage.frecency(of: safari, at: pickedAt) == 2)
        #expect(usage.affinity(of: safari, query: "saf", at: pickedAt) == 1)

        let commands = try await CommandStore(database: database).snapshot()
        #expect(commands.quicklinks.map(\.name) == ["Google", "DuckDuckGo"])
        #expect(commands.fallbackOrder.count == 3)

        #expect(try await SnippetStore(database: database).search("").isEmpty)
    }

    // The fixture is a database as milestone 6 left it: one pick, one alias and a third
    // quicklink, written by the code as it was before the snippet tables existed.
    @Test(.timeLimit(.minutes(1)))
    func databaseOfMilestone6KeepsWhatItHadAndGainsTheSnippetTables() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try #require(
            Bundle.module.url(
                forResource: "m6", withExtension: "sqlite", subdirectory: "Fixtures/databases"))
        try FileManager.default.copyItem(
            at: fixture, to: directory.appending(path: "OpenRay.sqlite"))

        let database = try AppDatabase.openOnDisk(at: directory)

        #expect(!database.wasReplaced)
        let pickedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let usage = await (try SQLiteUsageStore(database: database, now: pickedAt)).snapshot()
        #expect(usage.frecency(of: safari, at: pickedAt) == 1)
        #expect(usage.affinity(of: safari, query: "saf", at: pickedAt) == 1)

        let commands = try await CommandStore(database: database).snapshot()
        #expect(commands.aliases == ["term": .app(bundleID: "com.apple.Terminal")])
        #expect(commands.quicklinks.map(\.name) == ["Google", "DuckDuckGo", "Wikipedia"])
        #expect(commands.fallbackOrder.count == 3)

        let snippets = SnippetStore(database: database)
        let signature = Snippet(
            name: "Signature", keyword: "sig", body: "Kind regards", createdAt: pickedAt,
            updatedAt: pickedAt)
        try await snippets.save(signature)
        #expect(try await snippets.search("regards") == [signature])
    }

    // A file that fails to migrate cannot be made here: in a Debug build, which is what the
    // tests are, the migrator erases such a file instead of failing. So the recovery is run
    // on a file that is in good order, which is the case where there is something to carry.
    @Test(.timeLimit(.minutes(1)))
    func replacedDatabaseGetsTheSnippetsOfTheOldOne() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let edited = Date(timeIntervalSince1970: 1_790_000_600)
        let signature = Snippet(
            name: "Signature", keyword: "sig", body: "Kind regards\nAda", createdAt: created,
            updatedAt: edited)
        let address = Snippet(
            name: "Address", body: "1 Main St", createdAt: created, updatedAt: created)

        do {
            let database = try AppDatabase.openOnDisk(at: directory)
            let snippets = SnippetStore(database: database)
            try await snippets.save(signature)
            try await snippets.save(address)
            try await CommandStore(database: database).setAliases(["s"], for: signature.itemID)
        }

        let file = directory.appending(path: "OpenRay.sqlite", directoryHint: .notDirectory)
        let replacement = try AppDatabase.replaceDatabase(at: file)

        #expect(replacement.wasReplaced)
        let fileNames = try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))
        #expect(fileNames.contains { name in name.hasPrefix("OpenRay.sqlite.corrupt-") })

        // The snippets are there as they were, dates and IDs included, and can be searched.
        let snippets = SnippetStore(database: replacement)
        #expect(try await snippets.search("") == [address, signature])
        #expect(try await snippets.search("regards") == [signature])
        // Nothing else is carried over.
        #expect(try await CommandStore(database: replacement).snapshot().aliases.isEmpty)
    }

    // Clipboard and snippet search (milestones 4 and 7) are designed around this tokenizer, and
    // whether SQLite has it depends on the SDK the tests are built with.
    @Test(.timeLimit(.minutes(1)))
    func systemSQLiteHasTheTrigramTokenizer() async throws {
        let database = try AppDatabase.inMemory()

        #expect(try await database.supportsTrigramSearch())
    }
}
