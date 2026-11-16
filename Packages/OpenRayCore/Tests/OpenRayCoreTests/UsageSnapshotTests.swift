import Foundation
import Testing

@testable import OpenRayCore

@Suite struct UsageSnapshotTests {
    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: Frecency

    @Test func itemThatWasNeverPickedHasNoFrecency() {
        let usage = UsageSnapshot()

        #expect(usage.frecency(of: safari, at: start) == 0)
    }

    @Test func frecencyHalvesEverySevenDays() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "", at: start)

        #expect(usage.frecency(of: safari, at: start) == 1)
        #expect(usage.frecency(of: safari, at: start + 7 * day) == 0.5)
        #expect(usage.frecency(of: safari, at: start + 14 * day) == 0.25)
    }

    @Test func laterPickAddsToWhatIsLeftOfTheEarlierOne() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "", at: start)
        usage.record(pick: safari, query: "", at: start + 7 * day)

        #expect(usage.frecency(of: safari, at: start + 7 * day) == 1.5)
        #expect(usage.frecency(of: safari, at: start + 14 * day) == 0.75)
        #expect(usage.itemUsage[safari]?.useCount == 2)
    }

    @Test func clockSetBackDoesNotRaiseAScore() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "saf", at: start)

        // Read from before the pick was made.
        #expect(usage.frecency(of: safari, at: start - 30 * day) == 1)
        #expect(usage.affinity(of: safari, query: "saf", at: start - 30 * day) == 1)

        // A pick from before the first one adds its 1 and nothing else.
        usage.record(pick: safari, query: "saf", at: start - 30 * day)
        #expect(usage.frecency(of: safari, at: start - 30 * day) == 2)
    }

    // MARK: Query affinity

    @Test func affinityCountsTheShareOfTheStoredQueryThatWasTyped() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "saf", at: start)

        #expect(usage.affinity(of: safari, query: "s", at: start) == 1.0 / 3.0)
        #expect(usage.affinity(of: safari, query: "sa", at: start) == 2.0 / 3.0)
        #expect(usage.affinity(of: safari, query: "saf", at: start) == 1)
    }

    @Test func affinityIsZeroForOtherQueriesAndOtherItems() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "saf", at: start)
        let slack = ItemID.app(bundleID: "com.tinyspeck.slackmacgap")

        #expect(usage.affinity(of: safari, query: "x", at: start) == 0)
        #expect(usage.affinity(of: safari, query: "safa", at: start) == 0)
        #expect(usage.affinity(of: safari, query: "", at: start) == 0)
        #expect(usage.affinity(of: slack, query: "s", at: start) == 0)
    }

    @Test func affinityAddsUpOverStoredQueriesAndDecays() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "sa", at: start)
        usage.record(pick: safari, query: "saf", at: start)

        // Half of "sa" and a third of "saf".
        let now = usage.affinity(of: safari, query: "s", at: start)
        let aWeekLater = usage.affinity(of: safari, query: "s", at: start + 7 * day)

        #expect(abs(now - (1.0 / 2.0 + 1.0 / 3.0)) < 1e-12)
        #expect(abs(aWeekLater - now / 2) < 1e-12)
    }

    @Test func queryIsFoldedBeforeItIsStored() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "  SÁF ", at: start)

        #expect(usage.queryUsage[safari]?.keys.sorted() == ["saf"])
        #expect(usage.affinity(of: safari, query: "saf", at: start) == 1)
    }

    // The stored queries are dictionary keys, and to a dictionary a composed and a decomposed
    // spelling are one key. `affinity` and the database compare them scalar by scalar, so both
    // spellings have to be stored as the same scalars.
    @Test func composedAndDecomposedQueryAreStoredAsOne() {
        var usage = UsageSnapshot()
        let composed = "카카".precomposedStringWithCanonicalMapping
        let decomposed = "카카".decomposedStringWithCanonicalMapping
        usage.record(pick: safari, query: composed, at: start)
        usage.record(pick: safari, query: decomposed, at: start)

        let storedScalars = Array(UsageSnapshot.storedQuery(for: decomposed).unicodeScalars)
        #expect(storedScalars == Array(composed.unicodeScalars))
        let typedDecomposed = SearchQuery(decomposed).normalized
        #expect(usage.affinity(of: safari, query: typedDecomposed, at: start) == 2)
        #expect(usage.affinity(of: safari, query: composed, at: start) == 2)
    }

    @Test func storedAndTypedQueriesAreCutTo32Scalars() {
        var usage = UsageSnapshot()
        let fortyLetters = String(repeating: "a", count: 40)
        let thirtyTwoLetters = String(repeating: "a", count: 32)
        usage.record(pick: safari, query: fortyLetters, at: start)

        #expect(usage.queryUsage[safari]?.keys.sorted() == [thirtyTwoLetters])
        // The longer query still finds what it was stored as.
        #expect(usage.affinity(of: safari, query: fortyLetters, at: start) == 1)
        #expect(usage.affinity(of: safari, query: thirtyTwoLetters, at: start) == 1)
    }

    @Test func pickFromTheEmptyFieldOnlyCountsForFrecency() {
        var usage = UsageSnapshot()
        usage.record(pick: safari, query: "", at: start)
        usage.record(pick: safari, query: "   ", at: start)

        #expect(usage.frecency(of: safari, at: start) == 2)
        #expect(usage.queryUsage[safari] == nil)
    }

    // MARK: Stores

    @Test func snapshotBuiltFromRowsReadsLikeTheOneThatRecordedThem() {
        var recorded = UsageSnapshot()
        recorded.record(pick: safari, query: "saf", at: start)
        recorded.record(pick: safari, query: "sa", at: start + day)

        let loaded = UsageSnapshot(
            itemUsage: recorded.itemUsage, queryUsage: recorded.queryUsage)

        let later = start + 3 * day
        #expect(loaded.frecency(of: safari, at: later) == recorded.frecency(of: safari, at: later))
        #expect(
            loaded.affinity(of: safari, query: "s", at: later)
                == recorded.affinity(of: safari, query: "s", at: later))
    }

    @Test func inMemoryStoreGivesBackWhatWasRecorded() async {
        let store = InMemoryUsageStore()

        await store.record(pick: safari, query: "saf", at: start)
        let usage = await store.snapshot()

        #expect(usage.frecency(of: safari, at: start) == 1)
        #expect(usage.affinity(of: safari, query: "sa", at: start) == 2.0 / 3.0)
    }
}
