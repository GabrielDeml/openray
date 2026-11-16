import Foundation
import Testing

@testable import OpenRayCore

/// Records what it was asked to open and opens nothing.
@MainActor private final class FakeQuicklinkOpener: QuicklinkOpening {
    struct Opened: Equatable {
        var url: String
        var bundleID: String?
    }

    private(set) var opened: [Opened] = []

    func open(_ url: URL, withAppBundleID bundleID: String?) async throws {
        opened.append(Opened(url: url.absoluteString, bundleID: bundleID))
    }
}

private let created = Date(timeIntervalSince1970: 1_780_000_000)

private func quicklink(
    _ name: String, _ template: String, openWith: String? = nil, icon: String? = nil
) -> Quicklink {
    Quicklink(name: name, template: template, openWith: openWith, icon: icon, createdAt: created)
}

@Suite struct QuicklinkTemplateTests {
    private let search = "https://example.com/search?q={query}"

    @Test(arguments: [
        ("giraffe", "https://example.com/search?q=giraffe"),
        ("tall giraffes", "https://example.com/search?q=tall%20giraffes"),
        ("salt & pepper", "https://example.com/search?q=salt%20%26%20pepper"),
        ("c++ = fun?", "https://example.com/search?q=c%2B%2B%20%3D%20fun%3F"),
        ("#swift", "https://example.com/search?q=%23swift"),
        ("🦒", "https://example.com/search?q=%F0%9F%A6%92"),
        ("größe", "https://example.com/search?q=gr%C3%B6%C3%9Fe"),
        ("", "https://example.com/search?q="),
    ])
    func argumentIsPercentEncodedIntoThePlaceholder(_ argument: String, _ expected: String) {
        #expect(QuicklinkTemplate.expand(search, argument: argument) == expected)
    }

    @Test func everyPlaceholderIsFilled() {
        let template = "https://{query}.example.com/{query}"

        #expect(
            QuicklinkTemplate.expand(template, argument: "docs") == "https://docs.example.com/docs")
    }

    @Test func templateWithoutAPlaceholderTakesNoArgument() {
        #expect(QuicklinkTemplate.takesArgument(search))
        #expect(!QuicklinkTemplate.takesArgument("https://example.com/inbox"))
        #expect(
            QuicklinkTemplate.expand("https://example.com/inbox", argument: "ignored")
                == "https://example.com/inbox")
    }

    @Test func anySchemeIsAllowed() throws {
        let link = quicklink("Notes", "x-notes://search/{query}")

        let url = try QuicklinkTemplate.url(for: link, argument: "to do")

        #expect(url.absoluteString == "x-notes://search/to%20do")
    }

    @Test(arguments: ["not a url", "", "example.com/no-scheme", "https://exa mple.com/{query}"])
    func templateThatMakesNoURLIsAnErrorThatNamesTheQuicklink(_ template: String) {
        let link = quicklink("Broken", template)

        #expect(throws: QuicklinkError.invalidURL(quicklinkName: "Broken")) {
            _ = try QuicklinkTemplate.url(for: link, argument: "x")
        }
    }

    @Test func errorSaysWhichQuicklinkIsWrong() {
        let error = QuicklinkError.invalidURL(quicklinkName: "Broken")

        #expect(error.localizedDescription == "“Broken” does not lead to a valid URL.")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct QuicklinkSourceTests {
    private let opener = FakeQuicklinkOpener()
    private let context = FakeActionContext()

    /// A store with these quicklinks and without the seeded ones.
    private func makeStore(_ quicklinks: [Quicklink]) async throws -> CommandStore {
        let store = CommandStore(database: try AppDatabase.inMemory())
        for seeded in try await store.snapshot().quicklinks {
            try await store.deleteQuicklink(seeded.id)
        }
        for quicklink in quicklinks {
            try await store.saveQuicklink(quicklink)
        }
        return store
    }

    /// A source that has read the store, with the items it indexed.
    private func makeSource(
        _ store: CommandStore
    ) async throws -> (source: QuicklinkSource, items: [SearchItem]) {
        let source = QuicklinkSource(commands: store, opener: opener)
        var itemSets = source.indexedItems().makeAsyncIterator()
        let items = try #require(await itemSets.next())
        return (source, items)
    }

    private func rows(
        _ placement: Placement, for query: String, from source: QuicklinkSource
    ) async throws -> [ScoredItem] {
        let rows = try await source.results(for: SearchQuery(query)) ?? []
        return rows.filter { $0.placement == placement }
    }

    // MARK: Indexed items

    @Test func quicklinksAreIndexedByName() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}", icon: "sf:globe")
        let inbox = quicklink("Inbox", "https://mail.example.com/inbox", icon: "📬")
        let (_, items) = try await makeSource(try await makeStore([google, inbox]))

        #expect(items.map(\.title) == ["Google", "Inbox"])
        #expect(items.map(\.id) == [google.itemID, inbox.itemID])
        #expect(items.map(\.icon) == [.symbol("globe"), .emoji("📬")])
        #expect(items.allSatisfy { $0.kindLabel == "Quicklink" })
    }

    @Test func quicklinkWithoutAnIconGetsTheLinkSymbol() {
        #expect(
            QuicklinkSource.icon(of: quicklink("Plain", "https://example.com")) == .symbol("link"))
        #expect(
            QuicklinkSource.icon(of: quicklink("Plain", "https://example.com", icon: ""))
                == .symbol("link"))
    }

    @Test func quicklinkThatTakesAnArgumentAsksForItOnReturnAndOnTab() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}")
        let (_, items) = try await makeSource(try await makeStore([google]))
        let item = try #require(items.first)
        let argumentScreen = ScreenRequest(
            feature: FeatureID(rawValue: "quicklinks"), screen: "argument",
            argument: google.id.uuidString)

        #expect(item.tabTarget == argumentScreen)
        #expect(try await item.actions[0].perform(context) == .push(argumentScreen))
        #expect(opener.opened.isEmpty)
    }

    @Test func quicklinkWithoutAPlaceholderOpensAtOnce() async throws {
        let inbox = quicklink(
            "Inbox", "https://mail.example.com/inbox", openWith: "com.apple.Safari")
        let (_, items) = try await makeSource(try await makeStore([inbox]))
        let item = try #require(items.first)

        #expect(item.tabTarget == nil)
        #expect(try await item.actions[0].perform(context) == .closeLauncher)
        #expect(context.closeLauncherCount == 1)
        #expect(
            opener.opened == [
                .init(url: "https://mail.example.com/inbox", bundleID: "com.apple.Safari")
            ])
    }

    @Test func indexFollowsTheStore() async throws {
        let store = try await makeStore([])
        let source = QuicklinkSource(commands: store, opener: opener)
        var itemSets = source.indexedItems().makeAsyncIterator()
        let initial = try #require(await itemSets.next())
        #expect(initial.isEmpty)

        let wiki = quicklink("Wikipedia", "https://en.wikipedia.org/wiki/{query}")
        try await store.saveQuicklink(wiki)

        let items = try #require(await itemSets.next())
        #expect(items.map(\.title) == ["Wikipedia"])
        #expect(source.quicklink(withID: wiki.id) == wiki)
        #expect(source.quicklink(withID: UUID()) == nil)
    }

    // MARK: Pinned by the first word

    @Test func firstWordThatNamesAQuicklinkPinsItWithTheRestAsArgument() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}")
        let (source, _) = try await makeSource(try await makeStore([google]))

        let pinned = try await rows(.pinnedTop, for: "google  tall giraffes ", from: source)

        let row = try #require(pinned.first)
        #expect(pinned.count == 1)
        #expect(row.item.id == google.itemID)
        #expect(row.item.subtitle == "tall giraffes")
        #expect(try await row.item.actions[0].perform(context) == .closeLauncher)
        #expect(
            opener.opened == [
                .init(url: "https://google.com/search?q=tall%20giraffes", bundleID: nil)
            ])
    }

    @Test func aliasAddressesAQuicklinkLikeItsName() async throws {
        let google = quicklink("Google Search", "https://google.com/search?q={query}")
        let store = try await makeStore([google])
        try await store.setAliases(["g"], for: google.itemID)
        let (source, _) = try await makeSource(store)

        let pinned = try await rows(.pinnedTop, for: "G giraffes", from: source)

        #expect(pinned.map(\.item.id) == [google.itemID])
        #expect(pinned.first?.item.subtitle == "giraffes")
    }

    @Test func nameAloneWithoutMoreWordsPinsNothing() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}")
        let (source, _) = try await makeSource(try await makeStore([google]))

        #expect(try await rows(.pinnedTop, for: "google", from: source).isEmpty)
        #expect(try await rows(.pinnedTop, for: "google ", from: source).isEmpty)
    }

    @Test func quicklinkWithoutAPlaceholderIsNeverPinnedWithAnArgument() async throws {
        let inbox = quicklink("Inbox", "https://mail.example.com/inbox")
        let (source, _) = try await makeSource(try await makeStore([inbox]))

        #expect(try await rows(.pinnedTop, for: "inbox zero", from: source).isEmpty)
    }

    @Test func aliasOfAnotherKindOfItemPinsNoQuicklink() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}")
        let store = try await makeStore([google])
        try await store.setAliases(["s"], for: .app(bundleID: "com.apple.Safari"))
        let (source, _) = try await makeSource(store)

        #expect(try await rows(.pinnedTop, for: "s giraffes", from: source).isEmpty)
    }

    // MARK: Fallback

    @Test func everyQuicklinkThatTakesAnArgumentOffersTheWholeQueryAsAFallback() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}")
        let inbox = quicklink("Inbox", "https://mail.example.com/inbox")
        let (source, _) = try await makeSource(try await makeStore([google, inbox]))

        let fallback = try await rows(.fallback, for: " how tall is a giraffe ", from: source)

        #expect(fallback.map(\.item.id) == [google.itemID])
        _ = try await fallback[0].item.actions[0].perform(context)
        #expect(
            opener.opened == [
                .init(
                    url: "https://google.com/search?q=how%20tall%20is%20a%20giraffe", bundleID: nil)
            ])
    }

    @Test func emptyQueryGetsNoRows() async throws {
        let google = quicklink("Google", "https://google.com/search?q={query}")
        let (source, _) = try await makeSource(try await makeStore([google]))

        #expect(try await source.results(for: SearchQuery("   ")) == nil)
    }

    @Test func invalidTemplateThrowsWithTheLauncherStillOpen() async throws {
        let broken = quicklink("Broken", "no scheme {query}")
        let (source, _) = try await makeSource(try await makeStore([broken]))
        let fallback = try await rows(.fallback, for: "giraffe", from: source)
        let open = try #require(fallback.first?.item.actions.first)

        await #expect(throws: QuicklinkError.invalidURL(quicklinkName: "Broken")) {
            _ = try await open.perform(context)
        }
        #expect(context.closeLauncherCount == 0)
        #expect(opener.opened.isEmpty)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct QuicklinkArgumentModelTests {
    private let opener = FakeQuicklinkOpener()
    private let google = quicklink(
        "Google", "https://google.com/search?q={query}", openWith: "com.apple.Safari")

    private func makeContext() -> FakeScreenContext {
        FakeScreenContext(request: QuicklinkSource.argumentScreenRequest(for: google))
    }

    @Test func screenTurnsTheSearchFieldIntoItsInputLine() {
        let context = makeContext()

        let model = QuicklinkArgumentModel(quicklink: google, opener: opener, context: context)

        #expect(model.searchBarMode == .input(placeholder: "Type the text for Google"))
        #expect(context.screenActions.map(\.title) == ["Open"])
        #expect(model.argument == "")
    }

    @Test func returnOpensTheQuicklinkWithWhatTheFieldHoldsThen() async throws {
        let context = makeContext()
        // The action lives in the context and reads the field itself; it does not need the
        // model that set it.
        _ = QuicklinkArgumentModel(quicklink: google, opener: opener, context: context)
        let open = try #require(context.screenActions.first)

        context.type("  tall giraffes ")
        let outcome = try await open.perform(context.fakeActionContext)

        #expect(outcome == .closeLauncher)
        #expect(context.fakeActionContext.closeLauncherCount == 1)
        #expect(
            opener.opened == [
                .init(
                    url: "https://google.com/search?q=tall%20giraffes", bundleID: "com.apple.Safari"
                )
            ])
    }

    @Test func previewShowsTheURLForTheTextTyped() async throws {
        let context = makeContext()
        let model = QuicklinkArgumentModel(quicklink: google, opener: opener, context: context)
        #expect(model.preview == "https://google.com/search?q=")

        // The model follows the field through a stream; wait for it to have caught up.
        context.type("giraffe")
        while model.argument != "giraffe" {
            await Task.yield()
        }

        #expect(model.preview == "https://google.com/search?q=giraffe")
    }

    @Test func previewIsMissingWhileTheTemplateMakesNoURL() {
        let broken = quicklink("Broken", "no scheme {query}")
        let context = FakeScreenContext(request: QuicklinkSource.argumentScreenRequest(for: broken))

        let model = QuicklinkArgumentModel(quicklink: broken, opener: opener, context: context)

        #expect(model.preview == nil)
    }
}
