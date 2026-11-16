import Foundation
import Testing

import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct OpenWithModelTests {
    private let files = FeatureID(rawValue: "files")
    private let filePath = "/Users/ada/Documents/report.pdf"
    private let host = FakeFileActionHost()
    private let context: FakeScreenContext
    private let actionContext = FakeActionContext()

    // As `NSWorkspace` gives them: folders, so their URLs end in a slash.
    private let preview = OpenWithApp(
        url: URL(filePath: "/System/Applications/Preview.app", directoryHint: .isDirectory),
        name: "Preview", isDefault: true)
    private let safari = OpenWithApp(
        url: URL(filePath: "/Applications/Safari.app", directoryHint: .isDirectory),
        name: "Safari", isDefault: false)
    private let acrobat = OpenWithApp(
        url: URL(filePath: "/Applications/Acrobat Reader.app", directoryHint: .isDirectory),
        name: "Acrobat Reader", isDefault: false)

    init() {
        context = FakeScreenContext(
            request: ScreenRequest(feature: files, screen: "openWith", argument: filePath))
    }

    @discardableResult
    private func makeModel() -> OpenWithModel {
        let model = OpenWithModel(filePath: filePath, host: host, context: context)
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

    @Test func defaultAppIsFirstAndTheOthersFollowByName() {
        host.apps = [safari, acrobat, preview]

        makeModel()

        // Answered while the model was built: the apps are known at once.
        #expect(context.answers.count == 1)
        #expect(context.answers.first?.query == "")
        #expect(titles(of: context.answers.first) == ["Preview", "Acrobat Reader", "Safari"])
        #expect(context.answers.first?.emptyMessage == nil)
        #expect(context.screenActions.isEmpty)
    }

    @Test func appsWithOneNameAreOrderedByPath() {
        let otherSafari = OpenWithApp(
            url: URL(filePath: "/Applications/Old/Safari.app", directoryHint: .isDirectory),
            name: "Safari", isDefault: false)
        host.apps = [otherSafari, safari]

        makeModel()

        let rows = context.answers.first?.sections.first?.rows ?? []
        #expect(
            rows.map(\.item.id.rawValue) == [
                "command:files.openWith./Applications/Old/Safari.app",
                "command:files.openWith./Applications/Safari.app",
            ])
    }

    @Test func rowIsACommandOfFileSearchAndNotTheAppsOwnItem() throws {
        host.apps = [preview, safari]

        makeModel()

        let rows = try #require(context.answers.first?.sections.first?.rows)
        let first = try #require(rows.first).item
        // A pick here must not count as a pick of Preview in root search.
        #expect(first.id.rawValue == "command:files.openWith./System/Applications/Preview.app")
        #expect(first.id.namespace == .command)
        #expect(first.icon == .file(path: "/System/Applications/Preview.app"))
        #expect(first.kindLabel == "Application")
        #expect(first.accessories == ["Default"])
        #expect(first.actions.map(\.id.rawValue) == ["open"])

        let second = try #require(rows.last).item
        #expect(second.accessories.isEmpty)
    }

    @Test func typingNarrowsTheListAndKeepsItsOrder() async {
        host.apps = [safari, acrobat, preview]
        makeModel()

        await context.typeAndWaitForAnswer("re")
        #expect(context.answers.last?.query == "re")
        // Preview has the two letters inside its name and Acrobat Reader at the start of a
        // word. The better match does not go first: the list keeps its order.
        #expect(titles(of: context.answers.last) == ["Preview", "Acrobat Reader"])

        await context.typeAndWaitForAnswer("SAF")
        #expect(titles(of: context.answers.last) == ["Safari"])

        await context.typeAndWaitForAnswer("")
        #expect(titles(of: context.answers.last) == ["Preview", "Acrobat Reader", "Safari"])
    }

    @Test func filterThatNoAppPassesLeavesTheLaunchersOwnMessage() async {
        host.apps = [preview]
        makeModel()

        await context.typeAndWaitForAnswer("xyz")

        #expect(context.answers.last?.sections.isEmpty == true)
        #expect(context.answers.last?.emptyMessage == nil)
    }

    @Test func fileThatNoAppOpensSaysSo() async {
        makeModel()

        #expect(context.answers.first?.sections.isEmpty == true)
        #expect(context.answers.first?.emptyMessage == "No app can open this file")

        // Whatever is typed, there is still no app.
        await context.typeAndWaitForAnswer("pre")
        #expect(context.answers.last?.emptyMessage == "No app can open this file")
    }

    @Test func openClosesTheLauncherAndOpensTheFileWithThatApp() async throws {
        host.apps = [preview, safari]
        makeModel()
        let row = try #require(context.answers.first?.sections.first?.rows.last)
        let open = try #require(row.item.actions.first)

        let outcome = try await open.perform(actionContext)

        #expect(outcome == .closeLauncher)
        #expect(actionContext.closeLauncherCount == 1)
        #expect(host.calls == [.openWithApp(URL(filePath: filePath), appURL: safari.url)])
    }

    @Test func appThatCannotOpenTheFileThrowsTheHostsError() async throws {
        host.apps = [preview]
        host.refusesEverything = true
        makeModel()
        let row = try #require(context.answers.first?.sections.first?.rows.first)
        let open = try #require(row.item.actions.first)

        await #expect(throws: FakeFileActionHost.Refused.self) {
            try await open.perform(actionContext)
        }
    }

    @Test func modelGoesAwayWithItsScreen() async {
        host.apps = [preview]
        weak var releasedModel: OpenWithModel?
        do {
            let model = makeModel()
            releasedModel = model
        }
        context.close()

        while releasedModel != nil {
            await Task.yield()
        }
    }
}
