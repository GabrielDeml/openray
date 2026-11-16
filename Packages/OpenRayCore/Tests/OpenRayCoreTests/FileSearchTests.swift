import Foundation
import Synchronization
import Testing

@testable import OpenRayCore

/// A walk that reads no folder: it records what it was asked and returns what the test set.
private final class FakeWalk: Sendable {
    struct Ask: Equatable {
        var text: String
        var folders: [String]
        var limit: Int
    }

    private let recorded = Mutex<[Ask]>([])
    private let found = Mutex<[FileHit]>([])

    var asks: [Ask] {
        recorded.withLock { $0 }
    }

    func setHits(_ hits: [FileHit]) {
        found.withLock { $0 = hits }
    }

    func hits(matching text: String, in folders: [String], limit: Int) -> [FileHit] {
        recorded.withLock { $0.append(Ask(text: text, folders: folders, limit: limit)) }
        return found.withLock { $0 }
    }
}

@Suite(.timeLimit(.minutes(1))) struct FileSearchTests {
    private let spotlight = FakeFileSearcher()
    private let walk = FakeWalk()
    private let preferences = InMemoryPreferencesStore()
    private let usage = InMemoryUsageStore()
    private let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))

    private let home = "/Users/ada"
    private let canaryScope = FileScope(kind: .folders, folders: ["/System/Applications"])
    private let anApp = FileHit(path: "/System/Applications/Calculator.app")

    private func makeSearch() -> FileSearch {
        let walk = walk
        let clock = clock
        return FileSearch(
            spotlight: spotlight,
            walk: { text, folders, limit in
                walk.hits(matching: text, in: folders, limit: limit)
            },
            preferences: preferences, usage: usage, homeFolder: home, now: { clock.now })
    }

    private func prefixQuery(_ text: String) throws -> String {
        try #require(SpotlightQueryBuilder.build(text, pass: .namePrefix))
    }

    private func substringQuery(_ text: String) throws -> String {
        try #require(SpotlightQueryBuilder.build(text, pass: .nameSubstring))
    }

    /// A Mac whose Spotlight index is on has apps in `/System/Applications` to report.
    private func turnSpotlightOn() async {
        await spotlight.setHits([anApp], for: SpotlightQueryBuilder.canary)
    }

    private func canaryAsks() async -> [FakeFileSearcher.Ask] {
        await spotlight.asks.filter { $0.queryString == SpotlightQueryBuilder.canary }
    }

    // MARK: The two passes

    @Test func textIsAskedAsAPrefixAndAsASubstringEachWithItsLimit() async throws {
        let report = FileHit(path: "/Users/ada/report.pdf")
        let prefixQuery = try prefixQuery("rep")
        let substringQuery = try substringQuery("rep")
        await spotlight.setHits([report], for: prefixQuery)

        let answer = await makeSearch().search("rep")

        #expect(answer == .found([report]))
        let home = FileScope(kind: .home)
        #expect(
            await spotlight.asks == [
                .init(queryString: prefixQuery, scope: home, limit: 100),
                .init(queryString: substringQuery, scope: home, limit: 200),
            ])
    }

    @Test func fileFoundByBothPassesIsListedOnce() async throws {
        let report = FileHit(path: "/Users/ada/report.pdf")
        let preparation = FileHit(path: "/Users/ada/preparation.txt")
        await spotlight.setHits([report], for: try prefixQuery("rep"))
        await spotlight.setHits([preparation, report], for: try substringQuery("rep"))

        let answer = await makeSearch().search("rep")

        // Ranked as well: the name that starts with the text is first.
        #expect(answer == .found([report, preparation]))
    }

    @Test func listIsCutToTheBestSixty() async throws {
        var hits: [FileHit] = []
        for number in 1...150 {
            hits.append(FileHit(path: "/Users/ada/notes/report \(number).txt"))
        }
        // The shortest name, so the one the text covers most of.
        let best = FileHit(path: "/Users/ada/report.txt")
        await spotlight.setHits(hits + [best], for: try substringQuery("report"))

        let answer = await makeSearch().search("report")

        guard case .found(let found) = answer else {
            Issue.record("Expected hits, got \(answer)")
            return
        }
        #expect(found.count == 60)
        #expect(found.first == best)
    }

    @Test func picksOfTheLauncherReachTheRanking() async throws {
        let first = FileHit(path: "/Users/ada/a/plan.txt")
        let second = FileHit(path: "/Users/ada/b/plan.txt")
        await spotlight.setHits([first, second], for: try prefixQuery("plan"))
        let search = makeSearch()
        #expect(await search.search("plan") == .found([first, second]))

        await usage.record(pick: second.itemID, query: "plan", at: clock.now)

        #expect(await search.search("plan") == .found([second, first]))
    }

    @Test func textWithoutAWordAsksNothing() async {
        let answer = await makeSearch().search("   ")

        #expect(answer == .nothingFound)
        #expect(await spotlight.asks.isEmpty)
    }

    // MARK: Scope

    @Test func chosenFoldersReachSpotlight() async throws {
        let scope = FileScope(kind: .folders, folders: ["/Users/ada/Work", "/Volumes/Archive"])
        preferences.set(scope, for: .fileScope)
        await turnSpotlightOn()

        _ = await makeSearch().search("rep")

        let asks = await spotlight.asks
        #expect(asks.prefix(2).map(\.scope) == [scope, scope])
    }

    @Test func everywhereReachesSpotlight() async throws {
        // The folders stay in the preference while another kind is chosen.
        let scope = FileScope(kind: .everywhere, folders: ["/Users/ada/Work"])
        preferences.set(scope, for: .fileScope)
        await turnSpotlightOn()

        _ = await makeSearch().search("rep")

        #expect(await spotlight.asks.first?.scope.kind == .everywhere)
    }

    @Test func chosenFoldersWithoutAFolderSearchTheHomeFolder() async throws {
        preferences.set(FileScope(kind: .folders, folders: []), for: .fileScope)
        await turnSpotlightOn()

        _ = await makeSearch().search("rep")

        #expect(await spotlight.asks.first?.scope == FileScope(kind: .home))
    }

    @Test func scopeIsReadAnewForEverySearch() async throws {
        await turnSpotlightOn()
        let search = makeSearch()
        _ = await search.search("rep")

        preferences.set(FileScope(kind: .everywhere), for: .fileScope)
        _ = await search.search("rep")

        #expect(await spotlight.asks.last?.scope.kind == .everywhere)
    }

    // MARK: Is Spotlight on?

    @Test func noHitsOnAMacWithAnIndexIsNothingFound() async throws {
        await turnSpotlightOn()

        let answer = await makeSearch().search("no such file")

        #expect(answer == .nothingFound)
        #expect(
            await canaryAsks() == [
                .init(queryString: SpotlightQueryBuilder.canary, scope: canaryScope, limit: 1)
            ])
    }

    @Test func noHitsAndNoAppsEitherMeansSpotlightLooksOff() async throws {
        let answer = await makeSearch().search("report")

        #expect(answer == .spotlightLooksOff)
        #expect(walk.asks.isEmpty)
    }

    @Test func searchThatFindsFilesNeverAsksTheCanary() async throws {
        await spotlight.setHits(
            [FileHit(path: "/Users/ada/report.pdf")], for: try prefixQuery("rep"))

        _ = await makeSearch().search("rep")

        #expect(await canaryAsks().isEmpty)
    }

    @Test func canaryIsAskedOnceInFiveMinutesWhenSpotlightIsOn() async throws {
        await turnSpotlightOn()
        let search = makeSearch()

        _ = await search.search("one")
        clock.advance(minutes: 4.9)
        _ = await search.search("two")
        #expect(await canaryAsks().count == 1)

        clock.advance(minutes: 0.2)
        _ = await search.search("three")
        #expect(await canaryAsks().count == 2)
    }

    @Test func canaryIsAskedOnceInFiveMinutesWhenSpotlightIsOff() async throws {
        let search = makeSearch()

        #expect(await search.search("one") == .spotlightLooksOff)
        clock.advance(minutes: 4.9)
        // Indexing was switched on meanwhile. The old answer still stands.
        await turnSpotlightOn()
        #expect(await search.search("two") == .spotlightLooksOff)
        #expect(await canaryAsks().count == 1)

        clock.advance(minutes: 0.2)
        #expect(await search.search("three") == .nothingFound)
        #expect(await canaryAsks().count == 2)
    }

    // Right after login, or after the `mdutil` line of the notice was run, the canary can
    // come back empty once although Spotlight is about to answer.
    @Test func filesFoundAfterSpotlightLookedOffSayThatItIsOn() async throws {
        let search = makeSearch()
        #expect(await search.search("typo") == .spotlightLooksOff)

        let report = FileHit(path: "/Users/ada/report.pdf")
        await spotlight.setHits([report], for: try prefixQuery("rep"))
        #expect(await search.search("rep") == .found([report]))

        // Within the five minutes the first answer would have stood for.
        clock.advance(minutes: 1)
        #expect(await search.search("typo") == .nothingFound)
        #expect(await canaryAsks().count == 1)
    }

    // MARK: The walk

    @Test func walkIsUsedOnlyWhenItIsSwitchedOn() async throws {
        walk.setHits([FileHit(path: "/Users/ada/report.pdf")])

        #expect(await makeSearch().search("report") == .spotlightLooksOff)
        #expect(walk.asks.isEmpty)
    }

    @Test func walkReadsTheHomeFolderAndItsHitsAreRanked() async throws {
        preferences.set(true, for: .fileFallbackWalk)
        let preparation = FileHit(path: "/Users/ada/preparation.txt")
        let report = FileHit(path: "/Users/ada/report.pdf")
        walk.setHits([preparation, report])

        let answer = await makeSearch().search("rep")

        #expect(answer == .foundByWalking([report, preparation]))
        #expect(walk.asks == [.init(text: "rep", folders: [home], limit: 200)])
    }

    @Test func walkReadsTheChosenFolders() async throws {
        preferences.set(true, for: .fileFallbackWalk)
        let folders = ["/Users/ada/Work", "/Volumes/Archive"]
        preferences.set(FileScope(kind: .folders, folders: folders), for: .fileScope)

        _ = await makeSearch().search("rep")

        #expect(walk.asks.map(\.folders) == [folders])
    }

    @Test func walkReadsTheHomeFolderWhenTheScopeIsEverywhere() async throws {
        preferences.set(true, for: .fileFallbackWalk)
        preferences.set(FileScope(kind: .everywhere), for: .fileScope)

        _ = await makeSearch().search("rep")

        #expect(walk.asks.map(\.folders) == [[home]])
    }

    @Test func walkThatFindsNothingSaysSo() async throws {
        preferences.set(true, for: .fileFallbackWalk)

        #expect(await makeSearch().search("report") == .foundByWalking([]))
    }

    @Test func walkIsNotUsedOnAMacWithAnIndex() async throws {
        preferences.set(true, for: .fileFallbackWalk)
        await turnSpotlightOn()

        #expect(await makeSearch().search("report") == .nothingFound)
        #expect(walk.asks.isEmpty)
    }
}

@MainActor @Suite struct FileSearchPreferencesTests {
    private let store = InMemoryPreferencesStore()

    @Test func searchLooksInTheHomeFolderAndNeverWalksUnlessToldOtherwise() {
        let preferences = Preferences(store: store)

        #expect(preferences.fileScope == FileScope(kind: .home, folders: []))
        #expect(!preferences.fileFallbackWalk)
        #expect(PreferenceKey<FileScope>.fileScope.name == "files.scope")
        #expect(PreferenceKey<Bool>.fileFallbackWalk.name == "files.fallbackWalk")
    }

    @Test func scopeAndSwitchRoundTrip() {
        let preferences = Preferences(store: store)
        let scope = FileScope(kind: .folders, folders: ["/Users/ada/Work", "/Volumes/Archive"])

        preferences.fileScope = scope
        preferences.fileFallbackWalk = true

        #expect(Preferences(store: store).fileScope == scope)
        #expect(Preferences(store: store).fileFallbackWalk)
    }

    // What the pane relies on: choosing another kind does not empty the list of folders.
    @Test func foldersStayWhileAnotherKindIsChosen() {
        let preferences = Preferences(store: store)
        preferences.fileScope = FileScope(kind: .folders, folders: ["/Users/ada/Work"])

        preferences.fileScope.kind = .everywhere

        #expect(preferences.fileScope.folders == ["/Users/ada/Work"])
    }

    @Test func scopeASearchUsesIsTheChosenOneUnlessItNamesNoFolder() {
        let work = FileScope(kind: .folders, folders: ["/Users/ada/Work"])

        #expect(work.searched == work)
        #expect(FileScope(kind: .folders, folders: []).searched == FileScope(kind: .home))
        #expect(FileScope(kind: .home).searched == FileScope(kind: .home))
        #expect(FileScope(kind: .everywhere).searched == FileScope(kind: .everywhere))
        // The folders a user chose earlier do not turn "everywhere" into something smaller.
        let everywhere = FileScope(kind: .everywhere, folders: ["/Users/ada/Work"])
        #expect(everywhere.searched.kind == .everywhere)
    }

    // `defaults read` shows the kind by name, and a name is what a later version will find.
    @Test func kindIsStoredByName() throws {
        store.set(FileScope(kind: .everywhere, folders: ["/a"]), for: .fileScope)

        struct StoredScope: Codable {
            var kind: String
            var folders: [String]
        }
        let asStored = PreferenceKey(
            name: "files.scope", defaultValue: StoredScope(kind: "", folders: []))
        #expect(store.value(for: asStored).kind == "everywhere")
        #expect(store.value(for: asStored).folders == ["/a"])
    }
}
