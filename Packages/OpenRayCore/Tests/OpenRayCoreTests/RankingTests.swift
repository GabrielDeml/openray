import Foundation
import Testing

@testable import OpenRayCore

@Suite struct RankingTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// An app whose ID is its title, unless the test needs to choose it.
    private func app(
        _ title: String, id: String? = nil, alternateNames: [NameVariant] = []
    ) -> SearchItem {
        SearchItem(
            id: .app(bundleID: id ?? title), title: title, alternateNames: alternateNames,
            icon: .symbol("app"), kindLabel: "Application")
    }

    private func rank(
        _ query: String, in snapshot: IndexSnapshot, usage: UsageSnapshot = UsageSnapshot(),
        candidates: [Int]? = nil
    ) async throws -> RankedResults {
        let results = await snapshot.rank(
            query: SearchQuery(query), usage: usage, now: now, candidates: candidates)
        return try #require(results)
    }

    private func titles(of results: RankedResults) -> [String] {
        var titles: [String] = []
        for row in results.rows {
            titles.append(row.scored.item.title)
        }
        return titles
    }

    // MARK: Learning

    @Test func picksWithALongerQueryFlipTheOrderForItsFirstLetter() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("Safari"), app("Slack")])

        // Both are prefix matches, and the shorter name is covered a little more.
        let before = try await rank("s", in: snapshot)
        #expect(titles(of: before) == ["Slack", "Safari"])

        var usage = UsageSnapshot()
        for _ in 0..<3 {
            usage.record(pick: .app(bundleID: "Safari"), query: "saf", at: now)
        }
        let after = try await rank("s", in: snapshot, usage: usage)
        #expect(titles(of: after) == ["Safari", "Slack"])
    }

    @Test func frecencyAloneCannotLiftALooseMatchOverAPrefixMatch() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("Safari"), app("Arc")])
        // Twenty picks from the empty field: more frecency than counts, and no query affinity.
        var usage = UsageSnapshot()
        for _ in 0..<20 {
            usage.record(pick: .app(bundleID: "Safari"), query: "", at: now)
        }

        let results = try await rank("a", in: snapshot, usage: usage)

        #expect(titles(of: results) == ["Arc", "Safari"])
        let safari = try #require(results.rows.last)
        // One letter inside a word.
        #expect(safari.scored.quality == 0.7 * 16.0 / 36.0)
        #expect(safari.rank == safari.scored.quality + 0.15)
    }

    @Test func finalRankAddsBoundedSharesForFrecencyAndAffinity() {
        let unused = RankedRow.finalRank(quality: 0.5, frecency: 0, affinity: 0)
        let fullFrecency = RankedRow.finalRank(quality: 0.5, frecency: 16, affinity: 0)
        let moreThanFull = RankedRow.finalRank(quality: 0.5, frecency: 1_000, affinity: 100)
        let halfAffinity = RankedRow.finalRank(quality: 0.5, frecency: 0, affinity: 1.5)

        #expect(unused == 0.5)
        #expect(fullFrecency == 0.5 + 0.15)
        #expect(moreThanFull == 0.5 + 0.15 + 0.25)
        #expect(halfAffinity == 0.5 + 0.25 * 0.5)
    }

    // MARK: Order

    @Test func tiesBreakOnShorterTitleThenLocalisedOrderThenID() async throws {
        // Every item is an exact match through the same alternate name, so all rank alike.
        let tie = [NameVariant(text: "tie", weight: 1)]
        let snapshot = await IndexSnapshot.build(from: [
            app("Notes", id: "example.b", alternateNames: tie),
            app("Bravo", alternateNames: tie),
            app("Notes", id: "example.a", alternateNames: tie),
            app("alpha", alternateNames: tie),
            app("Maps", alternateNames: tie),
        ])

        let results = try await rank("tie", in: snapshot)

        var ids: [String] = []
        for row in results.rows {
            ids.append(row.scored.item.id.local)
        }
        // "Maps" is the shortest. By code points "Bravo" would come before "alpha".
        #expect(ids == ["Maps", "alpha", "Bravo", "example.a", "example.b"])
    }

    @Test func rowsCarryTheQualityAndTheFinalRank() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("Safari")])
        var usage = UsageSnapshot()
        usage.record(pick: .app(bundleID: "Safari"), query: "saf", at: now)

        let results = try await rank("saf", in: snapshot, usage: usage)
        let row = try #require(results.rows.first)

        let quality = 0.9 + 0.1 * (3.0 / 6.0)
        #expect(row.scored.quality == quality)
        #expect(row.rank == RankedRow.finalRank(quality: quality, frecency: 1, affinity: 1))
        #expect(row.rank > quality)
    }

    // MARK: Highlights

    @Test func highlightsAreRangesOfNeighbouringTitleCharacters() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("Visual Studio Code")])

        let prefix = try await rank("vis", in: snapshot)
        let acronym = try await rank("vsc", in: snapshot)

        #expect(prefix.rows.first?.scored.highlights == [0..<3])
        #expect(acronym.rows.first?.scored.highlights == [0..<1, 7..<8, 14..<15])
    }

    @Test func highlightsComeFromTheTitleEvenWhenAnotherNameMatchesBetter() async throws {
        let code = app(
            "Visual Studio Code", alternateNames: [NameVariant(text: "Code", weight: 1)])
        let snapshot = await IndexSnapshot.build(from: [code])

        let results = try await rank("code", in: snapshot)
        let row = try #require(results.rows.first)

        // The alternate name matches exactly; in the title "Code" is the third word.
        #expect(row.scored.quality == 1.0)
        #expect(row.scored.highlights == [14..<18])
    }

    @Test func itemFoundOnlyByAnAlternateNameHasNoHighlights() async throws {
        let terminal = app(
            "Terminal", alternateNames: [NameVariant(text: "shell", weight: 0.95)])
        let snapshot = await IndexSnapshot.build(from: [terminal])

        let results = try await rank("shell", in: snapshot)
        let row = try #require(results.rows.first)

        #expect(row.scored.quality == 0.95)
        #expect(row.scored.highlights == [])
    }

    // MARK: Empty query

    @Test func emptyQuerySuggestsTheEightMostUsedItems() async throws {
        var items: [SearchItem] = []
        var usage = UsageSnapshot()
        // App 1 is picked once, App 2 twice, and so on. Apps 11 and 12 are never picked.
        for number in 1...12 {
            items.append(app("App \(number)"))
            if number > 10 { continue }
            for _ in 0..<number {
                usage.record(pick: .app(bundleID: "App \(number)"), query: "app", at: now)
            }
        }
        let snapshot = await IndexSnapshot.build(from: items)

        let results = try await rank("  ", in: snapshot, usage: usage)

        #expect(
            titles(of: results) == [
                "App 10", "App 9", "App 8", "App 7", "App 6", "App 5", "App 4", "App 3",
            ])
        #expect(results.survivors.isEmpty)
        for row in results.rows {
            #expect(row.scored.quality == 0)
            #expect(row.scored.highlights == [])
        }
    }

    @Test func emptyQuerySuggestsOnlyItemsThatWereEverPicked() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("Safari"), app("Notes"), app("Maps")])
        var usage = UsageSnapshot()
        usage.record(pick: .app(bundleID: "Notes"), query: "", at: now)

        let onAFreshInstall = try await rank("", in: snapshot)
        let afterOnePick = try await rank("", in: snapshot, usage: usage)

        #expect(onAFreshInstall.rows.isEmpty)
        #expect(titles(of: afterOnePick) == ["Notes"])
    }

    // MARK: Survivors

    @Test func rankingTheSurvivorsOfAShorterQueryEqualsAFullScan() async throws {
        let snapshot = await IndexSnapshot.build(from: [
            app("Safari"), app("Slack"), app("Salesforce"), app("Notes"), app("Sandbox Fixer"),
            app("System Information"), app("Disk Utility"), app("Visual Studio Code"),
        ])
        var usage = UsageSnapshot()
        usage.record(pick: .app(bundleID: "Salesforce"), query: "saf", at: now)

        let shorter = try await rank("sa", in: snapshot, usage: usage)
        let fullScan = try await rank("saf", in: snapshot, usage: usage)
        let survivorsOnly = try await rank(
            "saf", in: snapshot, usage: usage, candidates: shorter.survivors)

        #expect(shorter.survivors.count < snapshot.entries.count)
        #expect(titles(of: survivorsOnly) == titles(of: fullScan))
        for (fromSurvivors, fromFullScan) in zip(survivorsOnly.rows, fullScan.rows) {
            #expect(fromSurvivors.rank == fromFullScan.rank)
            #expect(fromSurvivors.scored.quality == fromFullScan.scored.quality)
            #expect(fromSurvivors.scored.highlights == fromFullScan.scored.highlights)
        }
        #expect(survivorsOnly.survivors == fullScan.survivors)
    }

    @Test func matchTooLooseToShowIsStillASurvivor() async throws {
        let snapshot = await IndexSnapshot.build(from: [
            app("Notes"), app("Activity Monitor Preferences"),
        ])

        // Too loose for "cc", but a longer query can find its letters closer together.
        let results = try await rank("cc", in: snapshot)

        #expect(results.rows.isEmpty)
        #expect(results.survivors == [1])
    }

    // MARK: Cancellation

    @Test(.timeLimit(.minutes(1))) func cancelledTaskGetsNoRanking() async {
        var items: [SearchItem] = []
        for number in 0..<5_000 {
            items.append(app("Synthetic App \(number)"))
        }
        let snapshot = await IndexSnapshot.build(from: items)

        let task = Task {
            // Cancelled before the ranking starts, so the outcome does not depend on timing.
            withUnsafeCurrentTask { current in
                current?.cancel()
            }
            return await snapshot.rank(
                query: SearchQuery("app"), usage: UsageSnapshot(), now: now)
        }
        let results = await task.value

        #expect(results == nil)
    }
}
