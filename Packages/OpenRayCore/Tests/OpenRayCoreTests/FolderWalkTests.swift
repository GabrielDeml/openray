import Foundation
import Testing

import OpenRayCore

// Every test builds its own folder of empty files under the temporary directory and walks
// nothing else. The suite is a class so that `deinit` can remove the folder whichever way the
// test ends.
@Suite(.timeLimit(.minutes(1))) final class FolderWalkTests: Sendable {
    /// Without a slash at the end, like the paths of the hits.
    private let rootPath: String

    init() throws {
        rootPath = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: rootPath, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    // MARK: Fixtures

    private func path(_ relativePath: String) -> String {
        "\(rootPath)/\(relativePath)"
    }

    private func makeFolder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relativePath), withIntermediateDirectories: true)
    }

    /// Creates an empty file, and the folders above it if they are not there yet.
    private func makeFile(_ relativePath: String) throws {
        let folder = (relativePath as NSString).deletingLastPathComponent
        try makeFolder(folder)
        let wasCreated = FileManager.default.createFile(atPath: path(relativePath), contents: nil)
        #expect(wasCreated)
    }

    /// What a walk of the test's folder finds, as paths below it, sorted.
    private func found(
        _ text: String, by walk: FolderWalk = FolderWalk(), limit: Int = 100
    ) async -> [String] {
        let hits = await walk.hits(matching: text, in: [rootPath], limit: limit)
        var relativePaths: [String] = []
        for hit in hits {
            relativePaths.append(String(hit.path.dropFirst(rootPath.count + 1)))
        }
        return relativePaths.sorted()
    }

    // MARK: Matching

    @Test func everyWordHasToBeSomewhereInTheName() async throws {
        try makeFile("annual-report.pdf")
        try makeFile("report.pdf")
        try makeFile("Reports/2026 annual.txt")
        try makeFile("Reports/annual report 2026.txt")

        #expect(
            await found("report") == [
                "Reports", "Reports/annual report 2026.txt", "annual-report.pdf", "report.pdf",
            ])
        // Not the file whose folder has the other word: only the name counts.
        #expect(
            await found("port annual") == ["Reports/annual report 2026.txt", "annual-report.pdf"])
        #expect(await found("budget") == [])
    }

    @Test func caseAndAccentsDoNotCount() async throws {
        try makeFile("Résumé.pdf")
        try makeFile("NOTES.TXT")

        #expect(await found("resume") == ["Résumé.pdf"])
        #expect(await found("RÉSUMÉ") == ["Résumé.pdf"])
        #expect(await found("notes") == ["NOTES.TXT"])
    }

    @Test func textWithoutAWordFindsNothing() async throws {
        try makeFile("report.pdf")

        #expect(await found("  ") == [])
    }

    @Test func hitsCarryThePathAndSayWhichAreFolders() async throws {
        try makeFile("Plans/plan.txt")

        let hits = await FolderWalk().hits(matching: "plan", in: [rootPath], limit: 10)

        let folder = try #require(hits.first { $0.path == path("Plans") })
        #expect(folder.contentType == "public.folder")
        let file = try #require(hits.first { $0.path == path("Plans/plan.txt") })
        #expect(file.contentType == nil)
        // The date a file was last opened is Spotlight's to know.
        #expect(hits.allSatisfy { $0.lastUsed == nil })
    }

    @Test func folderGivenWithASlashAtItsEndGivesTheSamePaths() async throws {
        try makeFile("plan.txt")

        let hits = await FolderWalk().hits(matching: "plan", in: [rootPath + "/"], limit: 10)

        #expect(hits.map(\.path) == [path("plan.txt")])
    }

    @Test func fileBelowTwoOfTheFoldersIsFoundOnce() async throws {
        try makeFile("Documents/Work/plan.txt")
        // As Settings stores them: one folder inside the other, each with its slash.
        let folders = [path("Documents") + "/", path("Documents/Work") + "/"]

        let hits = await FolderWalk().hits(matching: "plan", in: folders, limit: 10)

        #expect(hits.map(\.path) == [path("Documents/Work/plan.txt")])
    }

    @Test func folderListedTwiceIsReadOnce() async throws {
        try makeFile("plan.txt")

        let hits = await FolderWalk().hits(
            matching: "plan", in: [rootPath, rootPath + "/"], limit: 10)

        #expect(hits.map(\.path) == [path("plan.txt")])
    }

    @Test func folderThatDoesNotExistHasNoHits() async {
        let hits = await FolderWalk().hits(
            matching: "plan", in: [path("no-such-folder")], limit: 10)

        #expect(hits.isEmpty)
    }

    // MARK: What is skipped

    @Test func hiddenFilesAndFoldersAreSkipped() async throws {
        try makeFile(".plan-hidden.txt")
        try makeFile(".cache/plan.txt")
        try makeFile("plan.txt")

        #expect(await found("plan") == ["plan.txt"])
    }

    @Test func packageIsFoundAndWhatIsInsideItIsNot() async throws {
        try makeFile("Plan.rtfd/plan-inside.rtf")
        try makeFile("Plans.bundle/Contents/plan.txt")

        // Each is one file to the user, and not a folder.
        let hits = await FolderWalk().hits(matching: "plan", in: [rootPath], limit: 10)
        #expect(hits.map(\.path).sorted() == [path("Plan.rtfd"), path("Plans.bundle")])
        #expect(hits.allSatisfy { $0.contentType == nil })
    }

    @Test func applicationsAreNeitherListedNorOpened() async throws {
        try makeFile("Planner.app/Contents/Resources/plan.txt")
        try makeFile("Tools/Planner Helper.app/Contents/Info.plist")
        try makeFile("Tools/plan.txt")

        #expect(await found("plan") == ["Tools/plan.txt"])
    }

    @Test func linkToAFolderIsNotFollowed() async throws {
        try makeFile("Real/plan.txt")
        try FileManager.default.createSymbolicLink(
            atPath: path("Link"), withDestinationPath: path("Real"))
        // A link back to the top would otherwise send the walk round in circles.
        try FileManager.default.createSymbolicLink(
            atPath: path("Real/Loop"), withDestinationPath: rootPath)

        #expect(await found("plan") == ["Real/plan.txt"])
    }

    // MARK: Limits

    @Test func nothingBelowTheSixthLevelIsFound() async throws {
        // The file `plan-6.txt` is the sixth name below the folder the walk starts from.
        try makeFile("1/2/3/4/5/plan-6.txt")
        try makeFile("1/2/3/4/5/6/plan-7.txt")

        #expect(await found("plan") == ["1/2/3/4/5/plan-6.txt"])
        #expect(FolderWalk().maximumDepth == 6)
    }

    @Test func depthCanBeSetLower() async throws {
        try makeFile("plan-1.txt")
        try makeFile("1/plan-2.txt")
        try makeFile("1/2/plan-3.txt")
        var walk = FolderWalk()
        walk.maximumDepth = 2

        #expect(await found("plan", by: walk) == ["1/plan-2.txt", "plan-1.txt"])
    }

    @Test func walkGivesUpAfterItsShareOfEntries() async throws {
        for number in 1...30 {
            try makeFile("plan-\(number).txt")
        }
        var walk = FolderWalk()
        walk.maximumEntries = 12

        #expect(await found("plan", by: walk).count == 12)
        #expect(FolderWalk().maximumEntries == 20_000)
    }

    @Test func entriesThatDoNotMatchCountTowardsTheCapToo() async throws {
        for number in 1...30 {
            try makeFile("other-\(number).txt")
        }
        try makeFile("Deep/plan.txt")
        var walk = FolderWalk()
        // The top folder alone has 31 entries, which leaves none for what is in `Deep`.
        walk.maximumEntries = 31

        #expect(await found("plan", by: walk) == [])

        walk.maximumEntries = 32
        #expect(await found("plan", by: walk) == ["Deep/plan.txt"])
    }

    @Test func walkEndsOnceItHasEnoughHits() async throws {
        for number in 1...30 {
            try makeFile("plan-\(number).txt")
        }

        #expect(await found("plan", limit: 7).count == 7)
    }

    @Test func filesNearTheTopAreFoundBeforeTheOnesFurtherDown() async throws {
        try makeFile("A/B/C/plan-deep.txt")
        try makeFile("Z/plan-near.txt")
        try makeFile("plan-top.txt")

        // Whatever order the folders are read in, a level is finished before the next begins.
        #expect(await found("plan", limit: 1) == ["plan-top.txt"])
        #expect(await found("plan", limit: 2) == ["Z/plan-near.txt", "plan-top.txt"])
    }

    @Test func cancelledWalkStops() async throws {
        try makeFile("plan.txt")
        let rootPath = rootPath

        let walking = Task { () -> [FileHit] in
            await FolderWalk().hits(matching: "plan", in: [rootPath], limit: 10)
        }
        walking.cancel()

        // Cancelled before it read its first folder, or just after: either way it returns.
        let hits = await walking.value
        #expect(hits.count <= 1)
    }
}
