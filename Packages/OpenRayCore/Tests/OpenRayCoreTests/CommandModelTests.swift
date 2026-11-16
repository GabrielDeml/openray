import Testing

import OpenRayCore

@Suite struct SearchQueryTests {
    @Test func headIsTheFirstTokenAndTailTheRest() {
        let query = SearchQuery("  g  swift  concurrency ")
        #expect(query.raw == "  g  swift  concurrency ")
        #expect(query.head == "g")
        #expect(query.tail == "swift  concurrency")
    }

    @Test func singleTokenHasNoTail() {
        let query = SearchQuery("safari")
        #expect(query.head == "safari")
        #expect(query.tail == "")
    }

    @Test func emptyQueryHasNoTokens() {
        let query = SearchQuery("")
        #expect(query.normalized == "")
        #expect(query.head == "")
        #expect(query.tail == "")
    }

    @Test func blankQueryHasNoTokens() {
        let query = SearchQuery("   ")
        #expect(query.normalized == "")
        #expect(query.head == "")
        #expect(query.tail == "")
    }

    @Test func normalizedFoldsCaseDiacriticsAndWidth() {
        #expect(SearchQuery(" Café ").normalized == "cafe")
        #expect(SearchQuery("ＳＡＦ").normalized == "saf")
    }
}

@Suite struct SearchSourceTests {
    private struct BareSource: SearchSource {
        let id = SourceID(rawValue: "bare")
        let latency = SourceLatency.inline
    }

    @Test(.timeLimit(.minutes(1))) func sourceWithoutIndexedItemsYieldsNothingAndFinishes() async {
        var batches = 0
        for await _ in BareSource().indexedItems() {
            batches += 1
        }
        #expect(batches == 0)
    }

    @Test func sourceWithoutQueryResultsAddsNothing() async throws {
        let results = try await BareSource().results(for: SearchQuery("anything"))

        #expect(results == nil)
    }
}

@MainActor @Suite struct ActionTests {
    private final class RecordingContext: ActionContext {
        let previousApp: AppRef? = AppRef(pid: 42, bundleID: "com.example.editor")
        let query = "report"
        var hudTexts: [String] = []
        var copied: [PasteContent] = []

        func closeLauncher() {}
        func showHUD(_ text: String) { hudTexts.append(text) }
        func confirm(_ confirmation: OpenRayCore.Confirmation) async -> Bool { true }
        func copy(_ content: PasteContent) { copied.append(content) }
        func paste(_ content: PasteContent) async -> PasteResult { .copiedOnly(.noAccessibility) }
        func clipboardText() async -> String? { nil }
    }

    @Test func actionReachesTheShellThroughItsContext() async throws {
        let copyQuery = ActionDescriptor(id: ActionID(rawValue: "copy"), title: "Copy") { context in
            context.copy(.text(context.query, cursorOffsetFromEnd: nil))
            context.showHUD("Copied")
            return .keepOpen
        }
        let context = RecordingContext()

        let outcome = try await copyQuery.perform(context)

        #expect(outcome == .keepOpen)
        #expect(context.copied == [.text("report", cursorOffsetFromEnd: nil)])
        #expect(context.hudTexts == ["Copied"])
    }

    @Test func rowTakesItsPrimaryActionAndTabTargetFromTheItem() {
        let chat = ScreenRequest(feature: FeatureID(rawValue: "ai"), screen: "chat")
        let run = ActionDescriptor(id: ActionID(rawValue: "run"), title: "Run") { _ in
            .closeLauncher
        }
        let copy = ActionDescriptor(id: ActionID(rawValue: "copy"), title: "Copy") { _ in
            .closeLauncher
        }
        let item = SearchItem(
            id: .system("sleep"), title: "Sleep", icon: .symbol("moon"), kindLabel: "Command",
            tabTarget: chat, actions: [run, copy])

        let row = LauncherState.Row(item)

        #expect(row.id == .system("sleep"))
        #expect(row.primaryAction == ActionID(rawValue: "run"))
        #expect(row.tabTarget == chat)
    }

    @Test func rowOfAnItemWithoutActionsHasNoPrimaryAction() {
        let item = SearchItem(
            id: .system("label"), title: "Label", icon: .symbol("tag"), kindLabel: "Command")

        #expect(LauncherState.Row(item).primaryAction == nil)
        #expect(LauncherState.Row(item).tabTarget == nil)
    }
}
