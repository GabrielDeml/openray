import Foundation
import Testing

@testable import OpenRayCore

@Suite struct SnippetRendererTests {
    /// 15 November 2026, 09:41 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_735_660)
    private let american = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")
    private let utc = TimeZone(identifier: "UTC")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func render(
        _ body: String, locale: Locale? = nil, timeZone: TimeZone? = nil, clipboard: String? = nil
    ) -> SnippetRenderer.Rendered {
        SnippetRenderer.render(
            body, now: now, locale: locale ?? american, timeZone: timeZone ?? utc,
            clipboard: clipboard)
    }

    // MARK: Date and time

    @Test func dateIsWrittenTheWayOfTheLocale() {
        #expect(render("{date}", locale: american).text == "11/15/2026")
        #expect(render("{date}", locale: german).text == "15.11.2026")
    }

    @Test func timeIsWrittenTheWayOfTheLocale() {
        let americanTime = render("{time}", locale: american).text
        // Between the minutes and "AM" is a space that differs between versions of macOS.
        #expect(americanTime.hasPrefix("9:41"))
        #expect(americanTime.hasSuffix("AM"))
        #expect(render("{time}", locale: german).text == "09:41")
    }

    @Test func dateTimeHasBoth() {
        let americanDateTime = render("{datetime}", locale: american).text
        #expect(americanDateTime.hasPrefix("11/15/2026, 9:41"))
        #expect(render("{datetime}", locale: german).text == "15.11.2026, 09:41")
    }

    @Test func dateAndTimeAreThoseOfTheTimeZone() {
        // 18:41 in Tokyo, nine hours ahead; in Honolulu, ten hours behind, it is still the 14th.
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!

        #expect(render("{time}", locale: german, timeZone: tokyo).text == "18:41")
        #expect(render("{date}", locale: german, timeZone: honolulu).text == "14.11.2026")
    }

    @Test func formatIsAPatternForTheDate() {
        #expect(render("{date format=\"yyyy-MM-dd\"}").text == "2026-11-15")
        #expect(render("{date format=\"HH:mm\"}", timeZone: tokyo).text == "18:41")
        #expect(render("{time format=\"HH:mm\"}").text == "09:41")
        #expect(render("{datetime   format=\"yyyyMMdd'T'HHmm\"}").text == "20261115T0941")
    }

    @Test func patternNamesMonthsInTheLocale() {
        let french = Locale(identifier: "fr_FR")

        #expect(render("{date format=\"d MMMM\"}", locale: american).text == "15 November")
        #expect(render("{date format=\"d MMMM\"}", locale: french).text == "15 novembre")
    }

    @Test func placeholdersStandInTheMiddleOfText() {
        let rendered = render("Sent on {date format=\"yyyy-MM-dd\"} at {time format=\"HH:mm\"}.")

        #expect(rendered.text == "Sent on 2026-11-15 at 09:41.")
        #expect(rendered.cursorOffsetFromEnd == nil)
    }

    // MARK: Cursor

    @Test func cursorVanishesAndLeavesItsDistanceFromTheEnd() {
        let rendered = render("Hi {cursor}, thanks")

        #expect(rendered.text == "Hi , thanks")
        #expect(rendered.cursorOffsetFromEnd == 8)
    }

    @Test func cursorAtTheEndIsNoDistance() {
        let rendered = render("Dear {cursor}")

        #expect(rendered.text == "Dear ")
        #expect(rendered.cursorOffsetFromEnd == 0)
    }

    @Test func distanceIsCountedInCharactersNotInScalars() {
        // A family of four people is seven scalars, and a line break of CR LF is two. The
        // caret passes each with one press of the arrow.
        let rendered = render("{cursor}👨‍👩‍👧‍👦\r\nz")

        #expect(rendered.text == "👨‍👩‍👧‍👦\r\nz")
        #expect(rendered.cursorOffsetFromEnd == 3)
    }

    @Test func distanceCountsWhatLaterPlaceholdersBecome() {
        let rendered = render("{cursor} {date format=\"yyyy\"}")

        #expect(rendered.text == " 2026")
        #expect(rendered.cursorOffsetFromEnd == 5)
    }

    @Test func ofTwoCursorsTheFirstCountsAndTheSecondVanishes() {
        let rendered = render("a{cursor}bc{cursor}d")

        #expect(rendered.text == "abcd")
        #expect(rendered.cursorOffsetFromEnd == 3)
        #expect(SnippetRenderer.cursorCount(in: "a{cursor}bc{cursor}d") == 2)
        #expect(SnippetRenderer.cursorCount(in: "a{{cursor}}b{cursor}") == 1)
    }

    // MARK: Clipboard

    @Test func clipboardIsPutInAsItIs() {
        #expect(render("> {clipboard}", clipboard: "copied text").text == "> copied text")
    }

    @Test func clipboardWithoutTextIsNothing() {
        #expect(render("[{clipboard}]", clipboard: nil).text == "[]")
    }

    @Test func placeholdersInWhatWasCopiedAreNotTheSnippets() {
        let rendered = render("{clipboard}!", clipboard: "{date} {cursor} {{time}}")

        #expect(rendered.text == "{date} {cursor} {{time}}!")
        #expect(rendered.cursorOffsetFromEnd == nil)
    }

    @Test func onlyAPlaceholderForTheClipboardUsesIt() {
        #expect(SnippetRenderer.usesClipboard("Re: {clipboard}"))
        #expect(!SnippetRenderer.usesClipboard("Type {{clipboard}} for the clipboard"))
        #expect(!SnippetRenderer.usesClipboard("{clipboard"))
        #expect(!SnippetRenderer.usesClipboard("{Clipboard}"))
        #expect(!SnippetRenderer.usesClipboard("{date}"))
    }

    // MARK: Braces

    @Test func placeholderInDoubledBracesIsWrittenOut() {
        #expect(render("{{date}}").text == "{date}")
        #expect(render("{{clipboard}}", clipboard: "x").text == "{clipboard}")
        #expect(render("{{cursor}}").cursorOffsetFromEnd == nil)
        #expect(render("{{date format=\"yyyy\"}}").text == "{date format=\"yyyy\"}")
        #expect(render("{{time}} gives {time format=\"HH:mm\"}").text == "{time} gives 09:41")
    }

    @Test(arguments: [
        "{name}",
        "{Date}",
        "{ date }",
        "{date",
        "{date }",
        "{date format=yyyy}",
        "{date format=\"\"}",
        "{date format=\"yyyy\" }",
        "{date format=\"yyyy",
        "{datetimes}",
        "{clipboard format=\"x\"}",
        "{",
        "}",
        "{}",
        "{{",
        "}}",
        "a { b } c",
        "{\"total\": {\"net\": 12}}",
        "token: ${{ secrets.TOKEN }}",
        "{{#each items}}{{name}}{{/each}}",
        "if (x) { return {}; }",
        "",
    ])
    func whatIsNoPlaceholderStaysAsItWasTyped(_ body: String) {
        let rendered = render(body, clipboard: "copied")

        #expect(rendered.text == body)
        #expect(rendered.cursorOffsetFromEnd == nil)
    }

    @Test func patternMayBeAHundredCharactersAndNoLonger() {
        let hundred = String(repeating: "'x'", count: 33) + "y"
        let tooLong = "{date format=\"" + hundred + "y\"}"

        #expect(hundred.count == 100)
        #expect(render("{date format=\"" + hundred + "\"}").text.hasSuffix("2026"))
        #expect(render(tooLong).text == tooLong)
    }

    @Test func braceBesideAPlaceholderStaysABrace() {
        #expect(render("{{date format=\"yyyy\"}").text == "{2026")
        #expect(render("{date format=\"yyyy\"}}").text == "2026}")
        #expect(render("{{{date format=\"yyyy\"}}}").text == "{{date format=\"yyyy\"}}")
    }

    // MARK: Anything at all

    @Test(.timeLimit(.minutes(1)))
    func randomTextNeitherTrapsNorTakesLong() {
        // Pieces that placeholders are made of, so that near misses are common.
        let pieces = [
            "{", "}", "{{", "}}", "date", "time", "datetime", "clipboard", "cursor", " ",
            "format=", "\"", "yyyy", "\n", "é", "👨‍👩‍👧‍👦", "\u{301}", "x",
        ]
        var generator = SeededGenerator(seed: 49)

        for _ in 0..<2_000 {
            var body = ""
            for _ in 0..<Int.random(in: 0..<40, using: &generator) {
                body += pieces.randomElement(using: &generator) ?? ""
            }

            let rendered = render(body, clipboard: "{cursor}")
            if let offset = rendered.cursorOffsetFromEnd {
                #expect(offset >= 0 && offset <= rendered.text.count)
            }
            _ = SnippetRenderer.usesClipboard(body)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func longTextOfBracesIsReadInOnePass() {
        // Every one of these looks like the start of a placeholder and is none.
        let body = String(repeating: "{date format=\"", count: 20_000)

        #expect(render(body).text == body)
    }
}
