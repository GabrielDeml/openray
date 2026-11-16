import Foundation
import Testing

@testable import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct CalculatorSourceTests {
    private let context = FakeActionContext()

    /// What a calculator source answers a query with.
    private func results(
        for query: String, in locale: Locale = enUS
    ) async throws -> [ScoredItem]? {
        try await CalculatorSource(locale: locale).results(for: SearchQuery(query))
    }

    /// The row for a query that is a calculation.
    private func answerRow(for query: String, in locale: Locale = enUS) async throws -> ScoredItem {
        try #require(try await results(for: query, in: locale)?.first)
    }

    private func action(_ id: String, of item: SearchItem) throws -> ActionDescriptor {
        try #require(item.actions.first { $0.id.rawValue == id })
    }

    // MARK: When it answers

    @Test func sourceIsInlineAndIndexesNothing() async {
        let source = CalculatorSource(locale: enUS)

        #expect(source.id == SourceID(rawValue: "calculator"))
        #expect(source.latency == .inline)

        var indexed = source.indexedItems().makeAsyncIterator()
        #expect(await indexed.next() == nil)
    }

    @Test(arguments: ["2+2", "sqrt(16)", "15% of 200", "5!", "5 km to m", "１ + １"])
    func calculationIsAnsweredWithOneRowPinnedToTheTop(_ query: String) async throws {
        let rows = try #require(try await results(for: query))

        #expect(rows.count == 1)
        #expect(rows.first?.placement == .pinnedTop)
    }

    @Test func answerIsAFullMatch() async throws {
        #expect(try await answerRow(for: "2+2").quality == 1)
    }

    @Test(arguments: [
        // Not a calculation.
        "42", "-42", "(42)", "3.14", "10 km", "1,234",
        // No digit.
        "", "   ", "safari", "pi * e", "sqrt(pi)",
        // Names that happen to have digits in them.
        "1password", "7-zip", "mp3 player", "word 2 pdf", "catch-22", "3d viewer",
        // Not finished, or not an expression.
        "2+", "(2+3", "2 +* 3", "sqrt(", "5 km to", "2 pi",
        // No answer.
        "1/0", "9^9^9", "171!", "sqrt(-1)", "5 km + 3 kg",
    ])
    func everythingElseGetsNoRow(_ query: String) async throws {
        #expect(try await results(for: query) == nil)
    }

    @Test func inputLongerThanTheCalculatorReadsGetsNoRow() async throws {
        let query = "1" + String(repeating: "+1", count: 128)

        #expect(try await results(for: query) == nil)
    }

    @Test func inputOfAnySizeGetsNoRowAndCostsTheSourceNothing() async throws {
        // Made before the clock starts: `SearchQuery` folds the whole text, which is not
        // the calculator's doing.
        let pasted = SearchQuery(String(repeating: "\u{301}", count: 10_000_000) + "2+2")
        let source = CalculatorSource(locale: enUS)
        let clock = ContinuousClock()
        let start = clock.now

        let rows = try await source.results(for: pasted)

        #expect(clock.now - start < .milliseconds(100))
        #expect(rows == nil)
    }

    // MARK: The row

    @Test func rowIsTheCalculatorsAnswer() async throws {
        let item = try await answerRow(for: "2+2").item

        // The ID is stored with every pick in the usage table, so it must not change.
        #expect(item.id == ItemID(rawValue: "command:calculator.answer"))
        #expect(item.icon == .symbol("equal.square"))
        #expect(item.kindLabel == "Calculator")
    }

    @Test(arguments: [
        ("2+2", "4"),
        ("1,234.5 * 2", "2,469"),
        ("10 / 3", "3.33333333333"),
        ("2^64", "18,446,744,073,709,551,616"),
        ("sqrt(16)", "4"),
        ("15% of 200", "30"),
        ("5!", "120"),
        ("１ + １", "2"),
        // With the symbol of the unit behind it.
        ("5 km to m", "5,000 m"),
        ("1 km + 500 m", "1.5 km"),
    ])
    func titleIsTheAnswer(_ query: String, _ title: String) async throws {
        #expect(try await answerRow(for: query).item.title == title)
    }

    @Test func subtitleIsTheExpressionAsTypedWithoutTheSpaceAroundIt() async throws {
        let row = try await answerRow(for: "  1,234.5  *  2 \n")

        #expect(row.item.title == "2,469")
        #expect(row.item.subtitle == "1,234.5  *  2")
    }

    @Test func numbersAreReadAndWrittenInTheSourcesLocale() async throws {
        let row = try await answerRow(for: "1.234,5 * 3", in: deDE)

        #expect(row.item.title == "3.703,5")
        // The same number as an American writes it is not a number in German.
        #expect(try await results(for: "1,234.5 * 3", in: deDE) == nil)
    }

    @Test func rowOffersToCopyToPasteAndToCopyTheExpression() async throws {
        let row = try await answerRow(for: "2+2")
        let actions = row.item.actions

        #expect(actions.map(\.id.rawValue) == ["copy-answer", "paste-answer", "copy-expression"])
        #expect(actions.map(\.title) == ["Copy Answer", "Paste Answer", "Copy Expression"])
        // The launcher gives Return to the first and ⌘Return to the second.
        #expect(actions.allSatisfy { $0.shortcut == nil })
        #expect(actions.allSatisfy { $0.confirmation == nil && !$0.isDestructive })
        #expect(actions.allSatisfy { $0.requiredPermissions.isEmpty })
    }

    // MARK: The actions

    @Test func copyAnswerCopiesTheNumberAloneAndSaysSo() async throws {
        let row = try await answerRow(for: "1,234.5 * 2 km")
        let copyAnswer = try action("copy-answer", of: row.item)

        let outcome = try await copyAnswer.perform(context)

        // The row shows "2,469 km". Neither the unit nor the grouping separator is copied.
        #expect(context.copied == [.text("2469", cursorOffsetFromEnd: nil)])
        #expect(context.pasted.isEmpty)
        #expect(outcome == .copiedToClipboard)
    }

    @Test func pasteAnswerPastesTheNumberAloneAndClosesTheLauncher() async throws {
        let row = try await answerRow(for: "1,234.5 * 2 km")
        let pasteAnswer = try action("paste-answer", of: row.item)

        let outcome = try await pasteAnswer.perform(context)

        #expect(context.pasted == [.text("2469", cursorOffsetFromEnd: nil)])
        #expect(context.copied.isEmpty)
        #expect(outcome == .closeLauncher)
    }

    @Test func pasteAnswerLeavesItToThePasteServiceToSayThatItOnlyCopied() async throws {
        context.pasteResult = .copiedOnly(.noAccessibility)
        let row = try await answerRow(for: "2+2")
        let pasteAnswer = try action("paste-answer", of: row.item)

        let outcome = try await pasteAnswer.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.hudMessages.isEmpty)
    }

    @Test func copyExpressionCopiesWhatWasTypedWithoutTheSpacesAroundIt() async throws {
        let row = try await answerRow(for: " 1,234.5 * 2 km ")
        let copyExpression = try action("copy-expression", of: row.item)

        let outcome = try await copyExpression.perform(context)

        #expect(context.copied == [.text("1,234.5 * 2 km", cursorOffsetFromEnd: nil)])
        #expect(outcome == .copiedToClipboard)
    }

    @Test(arguments: [
        ("10000 / 8", "1.250", "1250"),
        ("3 / 2", "1,5", "1,5"),
    ])
    func answerIsCopiedInTheSourcesLocale(
        _ query: String, _ shown: String, _ copied: String
    ) async throws {
        let row = try await answerRow(for: query, in: deDE)
        let copyAnswer = try action("copy-answer", of: row.item)

        _ = try await copyAnswer.perform(context)

        #expect(row.item.title == shown)
        #expect(context.copied == [.text(copied, cursorOffsetFromEnd: nil)])
    }
}
