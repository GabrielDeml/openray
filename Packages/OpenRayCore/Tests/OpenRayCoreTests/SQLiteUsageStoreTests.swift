import Foundation
import Testing

@testable import OpenRayCore

// A store keeps its snapshot in memory, so its own answers do not show what reached the
// database. Where that matters, a second store is made over the same database and asked.
@Suite(.timeLimit(.minutes(1)))
struct SQLiteUsageStoreTests {
    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let slack = ItemID.app(bundleID: "com.tinyspeck.slackmacgap")
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test func recordedPickIsInTheSnapshotAndInTheDatabase() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)

        try await store.record(pick: safari, query: "saf", at: start)

        let usage = await store.snapshot()
        #expect(usage.frecency(of: safari, at: start) == 1)
        #expect(usage.affinity(of: safari, query: "sa", at: start) == 2.0 / 3.0)

        let reloaded = try await SQLiteUsageStore(database: database, now: start).snapshot()
        #expect(reloaded.frecency(of: safari, at: start) == 1)
        #expect(reloaded.affinity(of: safari, query: "sa", at: start) == 2.0 / 3.0)
    }

    @Test func freshDatabaseHasNoUsage() async throws {
        let database = try AppDatabase.inMemory()

        let usage = try await SQLiteUsageStore(database: database, now: start).snapshot()

        #expect(usage.itemUsage.isEmpty)
        #expect(usage.queryUsage.isEmpty)
    }

    @Test func secondPickUpdatesTheStoredRow() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)
        let aWeekLater = start + 7 * day

        try await store.record(pick: safari, query: "saf", at: start)
        try await store.record(pick: safari, query: "saf", at: aWeekLater)

        let reloaded = try await SQLiteUsageStore(database: database, now: aWeekLater).snapshot()
        #expect(reloaded.frecency(of: safari, at: aWeekLater) == 1.5)
        #expect(reloaded.affinity(of: safari, query: "saf", at: aWeekLater) == 1.5)
        #expect(reloaded.itemUsage[safari]?.useCount == 2)
        #expect(reloaded.itemUsage[safari]?.referenceTime == aWeekLater)
    }

    @Test func queryIsStoredFoldedAndCutTo32Scalars() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)
        let fortyLetters = String(repeating: "a", count: 40)
        let thirtyTwoLetters = String(repeating: "a", count: 32)

        try await store.record(pick: safari, query: "  SÁF ", at: start)
        try await store.record(pick: slack, query: fortyLetters, at: start)

        let reloaded = try await SQLiteUsageStore(database: database, now: start).snapshot()
        #expect(reloaded.queryUsage[safari]?.keys.sorted() == ["saf"])
        #expect(reloaded.affinity(of: safari, query: "s", at: start) == 1.0 / 3.0)
        #expect(reloaded.queryUsage[slack]?.keys.sorted() == [thirtyTwoLetters])
    }

    @Test func pickFromTheEmptyFieldStoresNoQueryRow() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)

        try await store.record(pick: safari, query: "", at: start)
        try await store.record(pick: safari, query: "   ", at: start)

        let reloaded = try await SQLiteUsageStore(database: database, now: start).snapshot()
        #expect(reloaded.frecency(of: safari, at: start) == 2)
        #expect(reloaded.queryUsage.isEmpty)
    }

    @Test func itemsThatHaveFadedAreDeletedAtLaunch() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)
        try await store.record(pick: safari, query: "", at: start)
        try await store.record(pick: slack, query: "", at: start + 40 * day)

        // 50 days are a little over seven half-lives: one pick is then worth 0.007, which is
        // below the 0.01 an item needs to be kept. Slack's pick is 10 days old and worth 0.37.
        let launch = start + 50 * day
        let afterLaunch = try await SQLiteUsageStore(database: database, now: launch).snapshot()
        #expect(afterLaunch.itemUsage[safari] == nil)
        #expect(afterLaunch.frecency(of: slack, at: launch) > 0.3)

        // A store that judges the scores at the time of the first pick would keep Safari if its
        // row were still there.
        let onDisk = try await SQLiteUsageStore(database: database, now: start).snapshot()
        #expect(onDisk.itemUsage[safari] == nil)
        #expect(onDisk.itemUsage[slack] != nil)
    }

    @Test func queryRowsOverTheLimitAreDeletedAtLaunchLowestScoresFirst() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)
        func app(_ number: Int) -> ItemID { .app(bundleID: "com.example.app\(number)") }
        func query(_ number: Int) -> String { "app \(number)" }

        // Ten apps are picked twice on the first day. Ten days later as many apps as the table
        // may hold are picked once each, a second apart. Every app has one query row.
        let earlyApps = 0..<10
        for number in earlyApps {
            try await store.record(pick: app(number), query: query(number), at: start)
            try await store.record(pick: app(number), query: query(number), at: start)
        }
        let lateApps = 10..<(10 + SQLiteUsageStore.queryRowLimit)
        let lateStart = start + 10 * day
        for number in lateApps {
            let time = lateStart + TimeInterval(number)
            try await store.record(pick: app(number), query: query(number), at: time)
        }

        // By now the early rows have faded from 2 to 0.74, and every late row is still worth
        // more than 0.99. The early rows are the ten over the limit.
        let launch = lateStart + TimeInterval(lateApps.upperBound)
        let afterLaunch = try await SQLiteUsageStore(database: database, now: launch).snapshot()
        for number in earlyApps {
            #expect(afterLaunch.affinity(of: app(number), query: query(number), at: launch) == 0)
            // Only the query row is gone. The app's own usage is not limited in number.
            #expect(afterLaunch.frecency(of: app(number), at: launch) > 0.7)
        }
        let firstAndLastLateApp = [lateApps.lowerBound, lateApps.upperBound - 1]
        for number in firstAndLastLateApp {
            #expect(afterLaunch.affinity(of: app(number), query: query(number), at: launch) > 0.99)
        }

        // Judged on the first day, the early rows are worth 2 and every late row 1. A store
        // would keep them before any other row if they were still in the table.
        let onDisk = try await SQLiteUsageStore(database: database, now: start).snapshot()
        for number in earlyApps {
            #expect(onDisk.queryUsage[app(number)] == nil)
        }
        #expect(onDisk.queryUsage.count == SQLiteUsageStore.queryRowLimit)
        #expect(onDisk.itemUsage.count == earlyApps.count + lateApps.count)
    }

    @Test func countsPicksExactlyAsTheInMemoryStoreDoes() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await SQLiteUsageStore(database: database, now: start)
        let inMemory = InMemoryUsageStore()

        let picks: [(item: ItemID, query: String, time: Date)] = [
            (safari, "saf", start),
            (slack, "s", start + 60),
            (safari, "sa", start + day),
            (safari, "", start + 2 * day),
            (slack, "Släck", start + 9 * day),
            (safari, "saf", start + 9 * day),
        ]
        for pick in picks {
            try await store.record(pick: pick.item, query: pick.query, at: pick.time)
            await inMemory.record(pick: pick.item, query: pick.query, at: pick.time)
        }

        let expected = await inMemory.snapshot()
        let live = await store.snapshot()
        #expect(live.itemUsage == expected.itemUsage)
        #expect(live.queryUsage == expected.queryUsage)

        let end = start + 9 * day
        let reloaded = try await SQLiteUsageStore(database: database, now: end).snapshot()
        #expect(reloaded.itemUsage == expected.itemUsage)
        #expect(reloaded.queryUsage == expected.queryUsage)
    }
}
