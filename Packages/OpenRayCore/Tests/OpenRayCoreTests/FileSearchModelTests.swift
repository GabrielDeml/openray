import Foundation
import Testing

@testable import OpenRayCore

/// The pause after a keystroke, ended by the test and not by a clock.
@MainActor private final class ManualPause {
    /// While true, a pause does not end. Once false, every pause ends at once, also the
    /// ones that begin later.
    var isHolding = true
    /// How many pauses have begun and not ended. A pause whose task is cancelled ends.
    private(set) var runningCount = 0

    func sleep() async throws {
        runningCount += 1
        defer { runningCount -= 1 }
        while isHolding {
            try Task.checkCancellation()
            await Task.yield()
        }
        try Task.checkCancellation()
    }
}

/// The search behind the screen. It records the texts it is asked for and answers with what
/// the test set for them; while the test holds it, a search does not return.
@MainActor private final class FakeSearch {
    var answers: [String: FileSearch.Answer] = [:]
    /// While true, a search that has begun does not end.
    var isHolding = false
    private(set) var texts: [String] = []

    func search(_ text: String) async -> FileSearch.Answer {
        texts.append(text)
        while isHolding {
            await Task.yield()
        }
        return answers[text] ?? .nothingFound
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FileSearchModelTests {
    private let files = FeatureID(rawValue: "files")
    private let host = FakeFileActionHost()
    private let pause = ManualPause()
    private let search = FakeSearch()
    private let actionContext = FakeActionContext()

    private let report = FileHit(
        path: "/Users/ada/Documents/report.pdf", contentType: "com.adobe.pdf")
    private let reports = FileHit(path: "/Users/ada/Reports", contentType: "public.folder")

    private let hint = "Type to search for files by name"
    private let nothingFound = "No files found"

    private func makeContext(argument: String? = nil) -> FakeScreenContext {
        FakeScreenContext(
            request: ScreenRequest(feature: files, screen: "search", argument: argument))
    }

    @discardableResult
    private func makeModel(_ context: FakeScreenContext) -> FileSearchModel {
        let search = search
        let pause = pause
        let model = FileSearchModel(
            search: { text in await search.search(text) },
            context: context, host: host, homeFolder: "/Users/ada",
            sleep: { _ in try await pause.sleep() })
        context.model = model
        return model
    }

    /// The model answers from tasks of its own, a moment after it was asked.
    private func wait(until condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    /// Gives the model's tasks every chance to do what they should not do.
    private func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    /// A screen that shows `hits` for the text "report", with no pause after a keystroke.
    private func makeModelShowing(
        _ hits: [FileHit]
    ) async -> (model: FileSearchModel, context: FakeScreenContext) {
        pause.isHolding = false
        search.answers["report"] = .found(hits)
        let context = makeContext()
        let model = makeModel(context)
        await context.typeAndWaitForAnswer("report")
        return (model, context)
    }

    /// The action of the first row on screen with this ID.
    private func action(
        _ id: String, in context: FakeScreenContext
    ) throws -> ActionDescriptor {
        let row = try #require(context.answers.last?.sections.first?.rows.first)
        return try #require(row.item.actions.first { $0.id.rawValue == id })
    }

    // MARK: Answers

    @Test func emptyFieldIsAnsweredAtOnceWithTheHint() {
        let context = makeContext()
        makeModel(context)

        // Before anything was awaited: this is what tells the launcher that the screen is a
        // list, so it cannot wait.
        #expect(context.answers.count == 1)
        #expect(context.answers.first?.query == "")
        #expect(context.answers.first?.sections.isEmpty == true)
        #expect(context.answers.first?.emptyMessage == hint)
        #expect(context.screenActions.isEmpty)
    }

    @Test func threeQuickChangesGiveOneSearchForTheLastText() async {
        let context = makeContext()
        makeModel(context)

        context.type("r")
        context.type("re")
        context.type("rep")
        // Nothing is searched while the field has not rested, and every keystroke began the
        // wait anew: only the pause after the last one is still running.
        await settle()
        #expect(search.texts.isEmpty)
        #expect(pause.runningCount == 1)

        pause.isHolding = false
        await wait { context.answers.last?.query == "rep" }

        #expect(search.texts == ["rep"])
        // Only the hint for the empty field and the answer for "rep".
        #expect(context.answers.map(\.query) == ["", "rep"])
    }

    @Test func textTypedDuringASearchIsSearchedOnceTheSearchHasEnded() async {
        pause.isHolding = false
        search.answers["a"] = .found([report])
        let context = makeContext()
        makeModel(context)

        search.isHolding = true
        context.type("a")
        await wait { search.texts == ["a"] }

        context.type("ab")
        context.type("abc")
        // Both have rested long enough, and still nothing starts beside the running search.
        await settle()
        #expect(search.texts == ["a"])

        search.isHolding = false
        await wait { context.answers.last?.query == "abc" }

        // One more search, for the newest text. "ab" was never searched.
        #expect(search.texts == ["a", "abc"])
        // The first search was answered too, for the text it was started with.
        #expect(context.answers.map(\.query) == ["", "a", "abc"])

        await settle()
        #expect(search.texts == ["a", "abc"])
    }

    @Test func textTypedDuringASearchStillWaitsOutItsPause() async {
        pause.isHolding = false
        search.answers["a"] = .found([report])
        let context = makeContext()
        let model = makeModel(context)

        search.isHolding = true
        context.type("a")
        await wait { search.texts == ["a"] }

        pause.isHolding = true
        context.type("ab")
        search.isHolding = false
        await wait { context.answers.last?.query == "a" }
        // The search has ended, and the field has not rested on "ab" yet.
        await settle()
        #expect(search.texts == ["a"])
        // Its answer was for a text the field had left, so the file it found is not what
        // the detail pane describes.
        #expect(context.answers.last?.itemIDs == [report.itemID])
        #expect(model.hit(for: report.itemID) == nil)

        pause.isHolding = false
        await wait { context.answers.last?.query == "ab" }
        #expect(search.texts == ["a", "ab"])
    }

    @Test func emptyTextIsAnsweredAtOnceAndDropsWhatWasWaiting() async {
        let context = makeContext()
        makeModel(context)

        context.type("rep")
        context.type("")
        await wait { context.answers.count == 2 }

        // Answered while the pause after "rep" would still be running.
        #expect(context.answers.last?.query == "")
        #expect(context.answers.last?.emptyMessage == hint)

        pause.isHolding = false
        await settle()
        #expect(search.texts.isEmpty)
        #expect(context.answers.count == 2)
    }

    @Test func textOfNothingButSpacesIsAnsweredLikeTheEmptyText() async {
        pause.isHolding = false
        let context = makeContext()
        makeModel(context)

        await context.typeAndWaitForAnswer("  ")

        #expect(context.answers.last?.emptyMessage == hint)
        #expect(search.texts.isEmpty)
    }

    @Test func textThatComesBackIsAnsweredAgain() async {
        pause.isHolding = false
        search.answers["a"] = .found([report])
        let context = makeContext()
        makeModel(context)

        await context.typeAndWaitForAnswer("a")
        await context.typeAndWaitForAnswer("ab")
        await context.typeAndWaitForAnswer("a")

        #expect(search.texts == ["a", "ab", "a"])
        #expect(context.answers.last?.itemIDs == [report.itemID])
    }

    // MARK: Opened with a text

    @Test func textOfTheFallbackRowIsPutIntoTheFieldOnceTheScreenIsUp() async {
        pause.isHolding = false
        let context = makeContext(argument: "report")
        // The launcher takes no text from a screen that is still being built.
        context.takesSearchText = false

        makeModel(context)
        #expect(context.searchText == "")
        context.takesSearchText = true

        await wait { context.answers.last?.query == "report" }
        #expect(context.searchText == "report")
        #expect(search.texts == ["report"])
    }

    @Test func textOfTheFallbackRowDoesNotReplaceWhatTheUserTyped() async {
        pause.isHolding = false
        let context = makeContext(argument: "report")

        makeModel(context)
        // Typed before the model's task had its turn.
        context.type("mine")

        await wait { context.answers.last?.query == "mine" }
        await settle()
        #expect(context.searchText == "mine")
        #expect(search.texts == ["mine"])
    }

    @Test func screenOpenedByTheCommandLeavesTheFieldEmpty() async {
        pause.isHolding = false
        let context = makeContext()
        makeModel(context)

        await settle()

        #expect(context.searchText == "")
        #expect(search.texts.isEmpty)
    }

    // MARK: What each answer looks like

    @Test func foundFilesAreOneSectionWithoutATitle() async throws {
        let (model, context) = await makeModelShowing([report, reports])

        let answer = try #require(context.answers.last)
        #expect(answer.itemIDs == [report.itemID, reports.itemID])
        #expect(answer.sections.count == 1)
        #expect(answer.sections.first?.title == nil)
        #expect(answer.emptyMessage == nil)
        #expect(model.hit(for: report.itemID) == report)
        #expect(model.hit(for: .file(path: "/Users/ada/other.txt")) == nil)
    }

    @Test func nothingFoundSaysSo() async {
        pause.isHolding = false
        search.answers["report"] = .nothingFound
        let context = makeContext()
        makeModel(context)

        await context.typeAndWaitForAnswer("report")

        #expect(context.answers.last?.sections.isEmpty == true)
        #expect(context.answers.last?.emptyMessage == nothingFound)
    }

    @Test func spotlightThatLooksOffSaysHowToTurnItOn() async throws {
        pause.isHolding = false
        search.answers["report"] = .spotlightLooksOff
        let context = makeContext()
        makeModel(context)

        await context.typeAndWaitForAnswer("report")

        #expect(context.answers.last?.sections.isEmpty == true)
        let message = try #require(context.answers.last?.emptyMessage)
        let lines = message.components(separatedBy: "\n")
        #expect(lines.first == "Spotlight indexing appears to be off.")
        #expect(lines.count == 3)
        #expect(message.contains("sudo mdutil -i on /"))
        #expect(message.contains("Settings › File Search"))
    }

    @Test func filesFoundByWalkingComeUnderAHeadingThatSaysSo() async {
        pause.isHolding = false
        search.answers["report"] = .foundByWalking([report])
        let context = makeContext()
        makeModel(context)

        await context.typeAndWaitForAnswer("report")

        #expect(context.answers.last?.itemIDs == [report.itemID])
        #expect(context.answers.last?.sections.first?.title == "Found without Spotlight")
    }

    @Test func walkThatFoundNothingSaysNoFilesFound() async {
        pause.isHolding = false
        search.answers["report"] = .foundByWalking([])
        let context = makeContext()
        makeModel(context)

        await context.typeAndWaitForAnswer("report")

        #expect(context.answers.last?.sections.isEmpty == true)
        #expect(context.answers.last?.emptyMessage == nothingFound)
    }

    // MARK: Rows

    @Test func rowNamesTheFileItsFolderAndItsKind() async throws {
        let (_, context) = await makeModelShowing([report, reports])

        let rows = try #require(context.answers.last?.sections.first?.rows)
        let file = try #require(rows.first).item
        #expect(file.id.rawValue == "file:/Users/ada/Documents/report.pdf")
        #expect(file.title == "report.pdf")
        #expect(file.subtitle == "~/Documents")
        #expect(file.icon == .file(path: "/Users/ada/Documents/report.pdf"))
        #expect(file.kindLabel == "File")

        let folder = try #require(rows.last).item
        #expect(folder.title == "Reports")
        #expect(folder.subtitle == "~")
        #expect(folder.kindLabel == "Folder")
    }

    @Test(arguments: [
        ("/Users/ada/report.pdf", "~"),
        ("/Users/ada/Documents/Taxes/2026.pdf", "~/Documents/Taxes"),
        ("/Volumes/Backup/report.pdf", "/Volumes/Backup"),
        // Another user's folder that only begins like this one's.
        ("/Users/adam/report.pdf", "/Users/adam"),
        ("/report.pdf", "/"),
    ])
    func folderOfARowIsWrittenWithATildeForTheHomeFolder(_ path: String, _ expected: String) {
        #expect(FileSearchModel.folder(of: path, withHomeAs: "/Users/ada") == expected)
    }

    // MARK: Actions

    @Test func rowHasItsActionsInOrderWithTheirShortcuts() async throws {
        let (_, context) = await makeModelShowing([report])
        let actions = try #require(context.answers.last?.sections.first?.rows.first).item.actions

        #expect(
            actions.map(\.id.rawValue) == [
                "open", "show-in-finder", "open-with", "quick-look", "copy-path", "move-to-trash",
            ])
        #expect(
            actions.map(\.title) == [
                "Open", "Show in Finder", "Open With…", "Quick Look", "Copy Path", "Move to Trash",
            ])

        var shortcuts: [KeyChord?] = []
        for index in actions.indices {
            shortcuts.append(ActionShortcuts.shortcut(ofActionAt: index, in: actions))
        }
        #expect(
            shortcuts == [
                nil,
                // The second action gets ⌘↩ from the launcher.
                KeyChord(keyCode: VirtualKey.returnKey, modifiers: [.command]),
                nil,
                KeyChord(keyCode: VirtualKey.ansiY, modifiers: [.command], characters: "y"),
                KeyChord(
                    keyCode: VirtualKey.ansiC, modifiers: [.command, .shift], characters: "c"),
                KeyChord(keyCode: VirtualKey.ansiX, modifiers: [.control], characters: "x"),
            ])
        // None of them is a key the launcher keeps for itself, or the list above would have
        // a nil in its place.
        for action in actions {
            if let shortcut = action.shortcut {
                #expect(!KeyRouter().reserves(shortcut))
            }
        }
    }

    @Test func openClosesTheLauncherAndOpensTheFile() async throws {
        let (_, context) = await makeModelShowing([report])

        let outcome = try await action("open", in: context).perform(actionContext)

        #expect(outcome == .closeLauncher)
        #expect(actionContext.closeLauncherCount == 1)
        #expect(host.calls == [.open(report.url)])
    }

    @Test func showInFinderClosesTheLauncherAndRevealsTheFile() async throws {
        let (_, context) = await makeModelShowing([report])

        let outcome = try await action("show-in-finder", in: context).perform(actionContext)

        #expect(outcome == .closeLauncher)
        #expect(actionContext.closeLauncherCount == 1)
        #expect(host.calls == [.showInFinder(report.url)])
    }

    @Test func openWithPushesTheListOfAppsForTheFile() async throws {
        let (_, context) = await makeModelShowing([report])

        let outcome = try await action("open-with", in: context).perform(actionContext)

        let appList = ScreenRequest(
            feature: files, screen: "openWith", argument: "/Users/ada/Documents/report.pdf")
        #expect(outcome == .push(appList))
        #expect(host.calls.isEmpty)
    }

    @Test func quickLookFlipsThePreviewAndKeepsTheLauncherOpen() async throws {
        let (model, context) = await makeModelShowing([report])
        let quickLook = try action("quick-look", in: context)
        #expect(!model.showsPreview)

        #expect(try await quickLook.perform(actionContext) == .keepOpen)
        #expect(model.showsPreview)

        #expect(try await quickLook.perform(actionContext) == .keepOpen)
        #expect(!model.showsPreview)
        #expect(actionContext.closeLauncherCount == 0)
    }

    @Test func copyPathCopiesThePath() async throws {
        let (_, context) = await makeModelShowing([report])

        let outcome = try await action("copy-path", in: context).perform(actionContext)

        #expect(outcome == .copiedToClipboard)
        #expect(
            actionContext.copied == [
                .text("/Users/ada/Documents/report.pdf", cursorOffsetFromEnd: nil)
            ])
    }

    @Test func moveToTrashAsksFirstAndNamesTheFile() async throws {
        let (_, context) = await makeModelShowing([report])

        let moveToTrash = try action("move-to-trash", in: context)

        #expect(moveToTrash.isDestructive)
        #expect(
            moveToTrash.confirmation
                == Confirmation(
                    title: "Move “report.pdf” to the Trash?", confirmTitle: "Move to Trash"))
    }

    @Test func moveToTrashTakesTheRowOffTheListAndAnswersTheTextAgain() async throws {
        let (model, context) = await makeModelShowing([report, reports])
        let answersBefore = context.answers.count

        let outcome = try await action("move-to-trash", in: context).perform(actionContext)

        #expect(outcome == .keepOpen)
        #expect(host.calls == [.moveToTrash(report.url)])
        // Without asking Spotlight again, whose index still has the file.
        #expect(search.texts == ["report"])
        #expect(context.answers.count == answersBefore + 1)
        #expect(context.answers.last?.query == "report")
        #expect(context.answers.last?.itemIDs == [reports.itemID])
        #expect(model.hit(for: report.itemID) == nil)
        #expect(model.hit(for: reports.itemID) == reports)
    }

    @Test func lastRowMovedToTheTrashLeavesAListThatSaysNoFilesFound() async throws {
        let (_, context) = await makeModelShowing([report])

        _ = try await action("move-to-trash", in: context).perform(actionContext)

        #expect(context.answers.last?.sections.isEmpty == true)
        #expect(context.answers.last?.emptyMessage == nothingFound)
    }

    @Test func fileThatCannotBeTrashedStaysOnTheListAndTheErrorIsThrown() async throws {
        let (model, context) = await makeModelShowing([report])
        let answersBefore = context.answers.count
        host.refusesEverything = true

        let moveToTrash = try action("move-to-trash", in: context)
        await #expect(throws: FakeFileActionHost.Refused.self) {
            try await moveToTrash.perform(actionContext)
        }

        #expect(context.answers.count == answersBefore)
        #expect(model.hit(for: report.itemID) == report)
    }

    @Test func fileThatCannotBeOpenedThrowsTheHostsError() async throws {
        let (_, context) = await makeModelShowing([report])
        host.refusesEverything = true

        let open = try action("open", in: context)
        await #expect(throws: FakeFileActionHost.Refused.self) {
            try await open.perform(actionContext)
        }
    }

    // MARK: Lifetime

    @Test func modelGoesAwayWithItsScreen() async {
        weak var releasedModel: FileSearchModel?
        do {
            let (model, context) = await makeModelShowing([report])
            releasedModel = model
            // The screen was popped: the launcher drops the spec that held the model, and
            // the stream of the search text ends.
            context.close()
        }

        await wait { releasedModel == nil }
    }
}
