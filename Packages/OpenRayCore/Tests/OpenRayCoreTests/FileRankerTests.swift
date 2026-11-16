import Foundation
import Testing

@testable import OpenRayCore

@Suite struct FileRankerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func hit(_ path: String, usedDaysAgo days: Double? = nil) -> FileHit {
        var lastUsed: Date?
        if let days {
            lastUsed = now.addingTimeInterval(-days * 24 * 60 * 60)
        }
        return FileHit(path: path, lastUsed: lastUsed)
    }

    /// The paths of the hits, best first.
    private func ranked(
        _ hits: [FileHit], for query: String, usage: UsageSnapshot = UsageSnapshot()
    ) -> [String] {
        FileRanker.rank(hits, query: query, usage: usage, now: now).map(\.path)
    }

    // MARK: The name

    @Test func nameThatStartsWithTheQueryBeatsALooseMatchThatWasUsedToday() {
        let report = hit("/Users/ada/Documents/report.pdf")
        let preparation = hit("/Users/ada/Documents/quarterly-prep.txt", usedDaysAgo: 0)

        #expect(ranked([preparation, report], for: "rep") == [report.path, preparation.path])
    }

    @Test func everyWordIsLookedForOnItsOwnWhereverItIsInTheName() {
        let annualReport = hit("/Users/ada/annual-report.pdf")
        let reportAnnual = hit("/Users/ada/report-annual.pdf")
        let annualLeave = hit("/Users/ada/annual-leaves.pdf")

        // The first two have both words at the start of a word and tie; the path decides.
        // The third has only one of the words.
        let expected = [annualReport.path, reportAnnual.path, annualLeave.path]
        #expect(
            ranked([annualLeave, reportAnnual, annualReport], for: "annual report") == expected)
        #expect(
            ranked([annualLeave, reportAnnual, annualReport], for: "report annual") == expected)
    }

    @Test func caseAndAccentsOfTheQueryDoNotCount() {
        let resume = hit("/Users/ada/Résumé.pdf")
        let other = hit("/Users/ada/presume.txt")

        #expect(ranked([other, resume], for: "RESUME") == [resume.path, other.path])
    }

    // MARK: Recency

    @Test func ofTwoEqualNamesTheMoreRecentlyUsedWins() {
        let old = hit("/Users/ada/Desktop/notes.txt", usedDaysAgo: 200)
        let recent = hit("/Users/ada/Documents/notes.txt", usedDaysAgo: 1)

        #expect(ranked([old, recent], for: "notes") == [recent.path, old.path])
    }

    @Test func fileThatWasNeverOpenedRanksBelowOneThatWas() {
        let neverOpened = hit("/Users/ada/a/notes.txt")
        let opened = hit("/Users/ada/b/notes.txt", usedDaysAgo: 400)

        #expect(ranked([neverOpened, opened], for: "notes") == [opened.path, neverOpened.path])
        #expect(ranked([neverOpened], for: "notes") == [neverOpened.path])
    }

    @Test func dateInTheFutureCountsAsNow() {
        let today = hit("/Users/ada/a/notes.txt", usedDaysAgo: 0)
        let fromTheFuture = hit("/Users/ada/b/notes.txt", usedDaysAgo: -30)

        // Equal ranks, so the path decides. A date in the future that counted for more than
        // today would put the second file first.
        #expect(ranked([fromTheFuture, today], for: "notes") == [today.path, fromTheFuture.path])
    }

    // MARK: Picks in the launcher

    @Test func filePickedInTheLauncherRisesAndOnePickedForThisQueryRisesFurther() {
        let first = hit("/Users/ada/a/plan.txt")
        let second = hit("/Users/ada/b/plan.txt")
        let third = hit("/Users/ada/c/plan.txt")
        let hits = [first, second, third]

        #expect(ranked(hits, for: "plan") == [first.path, second.path, third.path])

        // Picked, with nothing typed that would tie it to a query.
        var usage = UsageSnapshot()
        usage.record(pick: second.itemID, query: "", at: now)
        #expect(ranked(hits, for: "plan", usage: usage) == [second.path, first.path, third.path])

        // Picked for this very query.
        usage.record(pick: third.itemID, query: "Plan", at: now)
        #expect(ranked(hits, for: "plan", usage: usage) == [third.path, second.path, first.path])
        // And for what the query began with.
        #expect(ranked(hits, for: "pl", usage: usage) == [third.path, second.path, first.path])
    }

    // MARK: Where the file lies

    @Test(arguments: [
        "/Users/ada/Library/Caches/report.pdf",
        "/Users/ada/code/node_modules/report.pdf",
        "/Users/ada/code/.git/report.pdf",
        "/Users/ada/.Trash/report.pdf",
    ])
    func fileInANoisyFolderLosesToTheSameNameElsewhere(_ noisyPath: String) {
        // Deeper and with a longer path, so that it does not win a tie.
        let elsewhere = hit("/Users/ada/Documents/Work/Archive/2026/report.pdf")
        let noisy = hit(noisyPath, usedDaysAgo: 0)

        #expect(ranked([noisy, elsewhere], for: "report") == [elsewhere.path, noisy.path])
    }

    @Test(arguments: [
        "/Users/ada/Library/Mobile Documents/com~apple~CloudDocs/Budget.xlsx",
        "/Users/ada/Library/CloudStorage/Dropbox/Budget.xlsx",
    ])
    func documentInACloudDriveDoesNotPayForTheLibraryItLiesIn(_ cloudPath: String) {
        let inTheCloud = hit(cloudPath)
        // A looser match: the word begins in the middle of the name.
        let elsewhere = hit("/Users/ada/Downloads/old-budget-draft.txt")

        #expect(
            ranked([elsewhere, inTheCloud], for: "budget") == [inTheCloud.path, elsewhere.path])
    }

    @Test func whatWasThrownAwayInACloudDriveIsStillNoise() {
        let elsewhere = hit("/Users/ada/Documents/Work/Archive/2026/report.pdf")
        let thrownAway = hit(
            "/Users/ada/Library/Mobile Documents/com~apple~CloudDocs/.Trash/report.pdf",
            usedDaysAgo: 0)

        #expect(
            ranked([thrownAway, elsewhere], for: "report") == [elsewhere.path, thrownAway.path])
    }

    @Test func folderWithANoisyNameIsItselfAFairResult() {
        let library = hit("/Users/ada/Library")
        let notes = hit("/Users/ada/Library notes.txt")

        // The folder's name is the whole query. It would come second if lying in the home
        // folder cost it what lying in a Library costs.
        #expect(ranked([notes, library], for: "library") == [library.path, notes.path])
    }

    @Test func deeperOfTwoEqualNamesLoses() {
        let deep = hit("/Users/ada/a/b/c/d/e/notes.txt")
        // Fewer folders and more characters: it is the depth that counts, not the length.
        let shallow = hit("/Users/ada/a-folder-with-quite-a-long-name/notes.txt")

        #expect(ranked([deep, shallow], for: "notes") == [shallow.path, deep.path])
    }

    // MARK: Order

    @Test func equalRanksGoByTheShorterPathAndThenByThePath() {
        let short = hit("/Users/ada/b/notes.txt")
        let long = hit("/Users/ada/aa/notes.txt")
        let alsoShort = hit("/Users/ada/a/notes.txt")

        #expect(
            ranked([long, short, alsoShort], for: "notes")
                == [alsoShort.path, short.path, long.path])
    }

    @Test func orderDoesNotDependOnTheOrderOfTheHits() {
        var hits = [
            hit("/Users/ada/Documents/report.pdf", usedDaysAgo: 3),
            hit("/Users/ada/Desktop/report.pdf"),
            hit("/Users/ada/Library/report.pdf", usedDaysAgo: 1),
            hit("/Users/ada/Documents/report-draft.pdf"),
            hit("/Users/ada/a/report.pdf"),
            hit("/Users/ada/b/report.pdf"),
        ]
        let expected = ranked(hits, for: "report")

        for _ in 0..<6 {
            // Every hit is at the front once.
            hits.append(hits.removeFirst())
            #expect(ranked(hits, for: "report") == expected)
            #expect(ranked(hits.reversed(), for: "report") == expected)
        }
    }

    @Test func queryWithoutAWordLeavesTheOrderToUsageAndPath() {
        let first = hit("/Users/ada/a.txt")
        let second = hit("/Users/ada/b.txt", usedDaysAgo: 1)

        #expect(ranked([first, second], for: "  ") == [second.path, first.path])
    }
}
