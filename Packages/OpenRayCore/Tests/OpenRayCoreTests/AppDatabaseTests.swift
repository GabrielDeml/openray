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
    }

    // Clipboard and snippet search (milestones 4 and 7) are designed around this tokenizer, and
    // whether SQLite has it depends on the SDK the tests are built with.
    @Test(.timeLimit(.minutes(1)))
    func systemSQLiteHasTheTrigramTokenizer() async throws {
        let database = try AppDatabase.inMemory()

        #expect(try await database.supportsTrigramSearch())
    }
}
