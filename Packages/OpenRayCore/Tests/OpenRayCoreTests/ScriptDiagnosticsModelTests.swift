import Foundation
import Testing

import OpenRayCore

// The diagnostics are made up: no file is read, and none of the paths exists.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScriptDiagnosticsModelTests {
    private let context = FakeScreenContext(
        request: ScreenRequest(feature: ScriptSource.feature, screen: "diagnostics"))
    private let host = FakeScriptActionHost()
    private let actionContext = FakeActionContext()

    private let brokenPath = "/made-up/Scripts/wifi.sh"
    private let sharedPath = "/made-up/Scripts/Shared/deploy.sh"
    private let missingFolderPath = "/made-up/Extra"

    private var diagnostics: [ScriptDiagnostic] {
        [
            ScriptDiagnostic(path: brokenPath, problem: .parse(.missingKey("mode"))),
            ScriptDiagnostic(
                path: sharedPath,
                problem: .security(.worldWritable(path: sharedPath, isFolder: false))),
            ScriptDiagnostic(path: missingFolderPath, problem: .folderMissing),
        ]
    }

    @discardableResult
    private func makeModel(showing diagnostics: [ScriptDiagnostic]) -> ScriptDiagnosticsModel {
        let model = ScriptDiagnosticsModel(diagnostics: diagnostics, host: host, context: context)
        context.model = model
        return model
    }

    private func titles(of answer: FakeScreenContext.Answer?) -> [String] {
        var titles: [String] = []
        for row in answer?.sections.first?.rows ?? [] {
            titles.append(row.item.title)
        }
        return titles
    }

    private func item(titled title: String) throws -> SearchItem {
        let rows = try #require(context.answers.first?.sections.first?.rows)
        return try #require(rows.first { $0.item.title == title }).item
    }

    // MARK: The list

    @Test func problemsAreListedAtOnceInTheOrderOfTheScan() {
        makeModel(showing: diagnostics)

        // Answered while the model was built: the problems are known already.
        #expect(context.answers.count == 1)
        #expect(context.answers.first?.query == "")
        #expect(titles(of: context.answers.first) == ["wifi.sh", "deploy.sh", "Extra"])
        #expect(context.answers.first?.emptyMessage == nil)
        // Return on a list screen is for its rows.
        #expect(context.screenActions.isEmpty)
        #expect(context.screenActionsSetCount == 0)
    }

    @Test func rowNamesTheFileAndSaysWhatIsWrongWithIt() throws {
        makeModel(showing: diagnostics)

        let file = try item(titled: "wifi.sh")
        // Not the script's own ID: a pick here is no pick of the script the file may become.
        #expect(file.id.rawValue == "command:scripts.diagnostic./made-up/Scripts/wifi.sh")
        #expect(file.subtitle == "@openray.mode is missing.")
        #expect(file.icon == .symbol("exclamationmark.triangle"))
        #expect(file.kindLabel == "File")

        let folder = try item(titled: "Extra")
        #expect(folder.id.rawValue == "command:scripts.diagnostic./made-up/Extra")
        #expect(folder.subtitle == "This folder does not exist.")
        #expect(folder.kindLabel == "Folder")
    }

    @Test func rowLeadsBackToItsProblemForTheViewBesideTheList() throws {
        let model = makeModel(showing: diagnostics)

        let shared = try item(titled: "deploy.sh")
        #expect(model.diagnostic(for: shared.id) == diagnostics[1])
        // The sentence a row cuts off after one line is whole there.
        #expect(
            model.diagnostic(for: shared.id)?.message
                == "Every user of this Mac can change “deploy.sh”, so OpenRay does not run it. To fix that, run chmod o-w on the file."
        )

        let folder = try item(titled: "Extra")
        #expect(model.diagnostic(for: folder.id)?.isFolder == true)
        #expect(model.diagnostic(for: .script(path: sharedPath)) == nil)
    }

    @Test func everyTextIsAnsweredAlsoOneThatComesBack() async {
        makeModel(showing: diagnostics)

        await context.typeAndWaitForAnswer("wifi")
        #expect(titles(of: context.answers.last) == ["wifi.sh"])

        await context.typeAndWaitForAnswer("")
        #expect(titles(of: context.answers.last) == ["wifi.sh", "deploy.sh", "Extra"])

        await context.typeAndWaitForAnswer("wifi")
        #expect(titles(of: context.answers.last) == ["wifi.sh"])
        #expect(context.answers.map(\.query) == ["", "wifi", "", "wifi"])
    }

    @Test func filterLooksAtTheNameAndAtTheProblem() async {
        makeModel(showing: diagnostics)

        await context.typeAndWaitForAnswer("DEPLOY")
        #expect(titles(of: context.answers.last) == ["deploy.sh"])

        // Nothing is called that. It is what is wrong with two of them.
        await context.typeAndWaitForAnswer("does not")
        #expect(titles(of: context.answers.last) == ["deploy.sh", "Extra"])
    }

    @Test func filterThatNothingPassesLeavesTheLaunchersOwnMessage() async {
        makeModel(showing: diagnostics)

        await context.typeAndWaitForAnswer("xyzzy")

        #expect(context.answers.last?.sections.isEmpty == true)
        #expect(context.answers.last?.emptyMessage == nil)
    }

    @Test func listWithoutProblemsSaysSo() async {
        makeModel(showing: [])

        #expect(context.answers.first?.sections.isEmpty == true)
        #expect(context.answers.first?.emptyMessage == "No problems in your script folders.")

        // Whatever is typed, there is still no problem.
        await context.typeAndWaitForAnswer("wifi")
        #expect(context.answers.last?.emptyMessage == "No problems in your script folders.")
    }

    // MARK: Actions

    @Test func fileIsOpenedInTheEditorOnReturn() async throws {
        makeModel(showing: diagnostics)
        let file = try item(titled: "wifi.sh")
        #expect(
            file.actions.map(\.id.rawValue) == ["open-in-editor", "show-in-finder", "copy-path"])

        let outcome = try await #require(file.actions.first).perform(actionContext)

        #expect(outcome == .closeLauncher)
        #expect(actionContext.calls == [.closeLauncher])
        #expect(host.calls == [.openInEditor(URL(filePath: brokenPath))])
    }

    @Test func folderIsShownInFinderOnReturn() async throws {
        makeModel(showing: diagnostics)
        let folder = try item(titled: "Extra")
        // A folder has nothing to edit.
        #expect(folder.actions.map(\.id.rawValue) == ["show-in-finder", "copy-path"])

        let outcome = try await #require(folder.actions.first).perform(actionContext)

        #expect(outcome == .closeLauncher)
        #expect(actionContext.calls == [.closeLauncher])
        #expect(host.calls == [.showInFinder(URL(filePath: missingFolderPath))])
    }

    @Test func pathOfAFileCanBeCopied() async throws {
        makeModel(showing: diagnostics)
        let copyPath = try #require(try item(titled: "deploy.sh").actions.last)

        let outcome = try await copyPath.perform(actionContext)

        #expect(outcome == .copiedToClipboard)
        #expect(actionContext.copied == [.text(sharedPath, cursorOffsetFromEnd: nil)])
    }

    @Test func modelGoesWithItsScreen() {
        weak var weakModel: ScriptDiagnosticsModel?
        do {
            weakModel = makeModel(showing: diagnostics)
        }
        #expect(weakModel != nil)

        context.close()

        #expect(weakModel == nil)
    }
}
