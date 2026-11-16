import Testing

import OpenRayCore

/// A block as the tests write it down, without its place in the answer.
private struct Expected: Equatable {
    var kind: MarkdownBlock.Kind
    var text: String

    init(_ kind: MarkdownBlock.Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

private func blocks(of text: String) -> [Expected] {
    MarkdownBlockParser.blocks(of: text).map { Expected($0.kind, $0.text) }
}

/// Answers of the kind the system prompt asks for, and a few that go beyond it.
private let sampleAnswers = [
    "Bern.",
    "The capital is **Bern**.\n\nIt has been the seat of the government since 1848.",
    """
    Three ways to do it:

    - Use `map`
    - Use a `for` loop
      when the body is long
    - Use `reduce`

    The first is the shortest.
    """,
    """
    1. Install it:
       ```bash
       brew install ripgrep
       ```
    2. Search:
       ```bash
       rg "needle" .
       ```
    3) Done.
    """,
    """
    ```swift
    let greeting = "Hello"

    # not a heading
    - not a list
    print(greeting)
    ```
    That prints `Hello`.
    """,
    """
    ## Summary

    > A quote
    > over two lines
    Then a paragraph that follows it directly.

    | a | b |
    |---|---|
    | 1 | 2 |
    """,
    "Windows line endings:\r\n\r\n- one\r\n- two\r\n\r\n```\r\ncode\r\n```\r\n",
    "An accent that arrives late: cafe\u{301} cre\u{300}me.\n\n1. 日本語\n2. 😀 emoji",
    "```python\nprint('never closed')\n",
    "#hashtag and -5 and 3.14 and 2024. A year at the start of a line\n1986.\n",
]

@Suite struct MarkdownBlockParserTests {
    @Test func linesThatFollowEachOtherAreOneParagraph() {
        let text = "First line\nsecond line\n\nAnother paragraph"

        #expect(
            blocks(of: text) == [
                Expected(.paragraph, "First line\nsecond line"),
                Expected(.paragraph, "Another paragraph"),
            ])
    }

    @Test func blankLinesAndSpaceAroundALineAreDropped() {
        #expect(blocks(of: "") == [])
        #expect(blocks(of: "\n \n\t\n") == [])
        #expect(
            blocks(of: "\n\n  indented text  \n\n\n") == [Expected(.paragraph, "indented text")])
    }

    @Test func headingLosesItsHashes() {
        #expect(blocks(of: "# Title") == [Expected(.heading, "Title")])
        #expect(blocks(of: "###### Deep") == [Expected(.heading, "Deep")])
        // No blank line is needed around a heading.
        #expect(
            blocks(of: "Before\n## Middle\nAfter") == [
                Expected(.paragraph, "Before"),
                Expected(.heading, "Middle"),
                Expected(.paragraph, "After"),
            ])
    }

    @Test func hashWithoutASpaceIsText() {
        #expect(blocks(of: "#hashtag") == [Expected(.paragraph, "#hashtag")])
        #expect(blocks(of: "#") == [Expected(.paragraph, "#")])
        #expect(blocks(of: "####### seven") == [Expected(.paragraph, "####### seven")])
    }

    @Test func bulletsAreListItemsWithoutANumber() {
        let text = "- dash\n* star\n+ plus"

        #expect(
            blocks(of: text) == [
                Expected(.listItem(number: nil), "dash"),
                Expected(.listItem(number: nil), "star"),
                Expected(.listItem(number: nil), "plus"),
            ])
    }

    @Test func orderedItemsKeepTheNumberThatWasWritten() {
        let text = "3. three\n4) four\n10. ten"

        #expect(
            blocks(of: text) == [
                Expected(.listItem(number: 3), "three"),
                Expected(.listItem(number: 4), "four"),
                Expected(.listItem(number: 10), "ten"),
            ])
    }

    @Test func markWithoutASpaceIsText() {
        #expect(blocks(of: "-5 degrees") == [Expected(.paragraph, "-5 degrees")])
        #expect(blocks(of: "**bold** start") == [Expected(.paragraph, "**bold** start")])
        #expect(blocks(of: "3.14 is pi") == [Expected(.paragraph, "3.14 is pi")])
        #expect(blocks(of: "---") == [Expected(.paragraph, "---")])
    }

    @Test func numberTooLongForAListIsText() {
        let text = "12345678901234567890123. not an item"

        #expect(blocks(of: text) == [Expected(.paragraph, text)])
    }

    @Test func listFollowsAParagraphWithoutABlankLine() {
        let text = "Two options:\n- first\n- second\nAnd more of the second.\n\nAfter the list."

        #expect(
            blocks(of: text) == [
                Expected(.paragraph, "Two options:"),
                Expected(.listItem(number: nil), "first"),
                Expected(.listItem(number: nil), "second\nAnd more of the second."),
                Expected(.paragraph, "After the list."),
            ])
    }

    @Test func itemInsideAnItemIsOneMoreItem() {
        let text = "- outer\n  - inner\n    1. innermost"

        #expect(
            blocks(of: text) == [
                Expected(.listItem(number: nil), "outer"),
                Expected(.listItem(number: nil), "inner"),
                Expected(.listItem(number: 1), "innermost"),
            ])
    }

    @Test func quoteLinesAreOneQuote() {
        let text = "> first\n>second\n>\n> fourth\nnot quoted"

        #expect(
            blocks(of: text) == [
                Expected(.quote, "first\nsecond\n\nfourth"),
                Expected(.paragraph, "not quoted"),
            ])
    }

    @Test func fencedCodeKeepsItsLinesAsTheyAre() {
        let text = "```swift\nfunc f() {\n    return  1\n}\n\n# comment\n```"

        #expect(
            blocks(of: text) == [
                Expected(.code(language: "swift"), "func f() {\n    return  1\n}\n\n# comment")
            ])
    }

    @Test func fenceWithoutALanguageHasNone() {
        #expect(blocks(of: "```\nplain\n```") == [Expected(.code(language: nil), "plain")])
        #expect(blocks(of: "```   \nplain\n```") == [Expected(.code(language: nil), "plain")])
    }

    @Test func languageIsTheFirstWordAfterTheFence() {
        let text = "``` js title=\"app.js\"\nlet a\n```"

        #expect(blocks(of: text) == [Expected(.code(language: "js"), "let a")])
    }

    @Test func longerFenceIsNotClosedByAShorterOne() {
        let text = "````markdown\n```\ninner\n```\n````\nafter"

        #expect(
            blocks(of: text) == [
                Expected(.code(language: "markdown"), "```\ninner\n```"),
                Expected(.paragraph, "after"),
            ])
    }

    @Test func fenceThatIsNeverClosedHoldsTheRest() {
        let text = "Here:\n```python\nprint(1)\n\n- still code"

        #expect(
            blocks(of: text) == [
                Expected(.paragraph, "Here:"),
                Expected(.code(language: "python"), "print(1)\n\n- still code"),
            ])
    }

    @Test func codeInsideAListItemLosesTheItemsIndentation() {
        let text = "1. Run:\n   ```sh\n   make\n     install\n   ```\n2. Done"

        #expect(
            blocks(of: text) == [
                Expected(.listItem(number: 1), "Run:"),
                Expected(.code(language: "sh"), "make\n  install"),
                Expected(.listItem(number: 2), "Done"),
            ])
    }

    @Test func tablesAndImagesAreParagraphs() {
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        let image = "![alt](https://example.com/a.png)"

        #expect(blocks(of: table) == [Expected(.paragraph, table)])
        #expect(blocks(of: image) == [Expected(.paragraph, image)])
    }

    @Test func everyKindOfLineEndingSeparatesLines() {
        let expected = [
            Expected(.paragraph, "one\ntwo"), Expected(.listItem(number: nil), "three"),
        ]

        #expect(blocks(of: "one\ntwo\n\n- three") == expected)
        #expect(blocks(of: "one\r\ntwo\r\n\r\n- three") == expected)
        #expect(blocks(of: "one\rtwo\r\r- three") == expected)
    }

    @Test func blocksAreNumberedInOrder() {
        let blocks = MarkdownBlockParser.blocks(of: "# One\n\ntwo\n\n- three")

        #expect(blocks.map(\.id) == [0, 1, 2])
    }
}

@Suite struct StreamingMarkdownTests {
    /// The text cut into pieces of a random length, the same pieces on every run.
    private func randomPieces(of text: String, seed: UInt64) -> [String] {
        var generator = SeededGenerator(seed: seed)
        var pieces: [String] = []
        // Cut between Unicode scalars, as a provider's text deltas are, so that a cut can
        // fall inside a CR LF and between a letter and its accent.
        var remaining = text.unicodeScalars[...]
        while !remaining.isEmpty {
            let length = Int.random(in: 1...12, using: &generator)
            pieces.append(String(String.UnicodeScalarView(remaining.prefix(length))))
            remaining = remaining.dropFirst(length)
        }
        return pieces
    }

    @Test func textInOnePieceGivesTheBlocksOfTheParser() {
        for answer in sampleAnswers {
            var streaming = StreamingMarkdown()
            streaming.update(to: answer)

            #expect(streaming.text == answer)
            #expect(streaming.blocks == MarkdownBlockParser.blocks(of: answer))
        }
    }

    @Test func blocksEqualAFullParseAfterEveryPrefix() {
        for answer in sampleAnswers {
            var streaming = StreamingMarkdown()
            var prefix = ""
            for scalar in answer.unicodeScalars {
                prefix.unicodeScalars.append(scalar)
                streaming.update(to: prefix)

                #expect(
                    streaming.blocks == MarkdownBlockParser.blocks(of: prefix),
                    "after \(prefix.debugDescription)")
            }
        }
    }

    @Test func blocksEqualAFullParseForRandomPieces() {
        for (index, answer) in sampleAnswers.enumerated() {
            for seed in 1...20 {
                var streaming = StreamingMarkdown()
                var textSoFar = ""
                for piece in randomPieces(of: answer, seed: UInt64(index * 100 + seed)) {
                    textSoFar += piece
                    streaming.update(to: textSoFar)

                    #expect(
                        streaming.blocks == MarkdownBlockParser.blocks(of: textSoFar),
                        "after \(textSoFar.debugDescription)")
                }
            }
        }
    }

    @Test func finishedBlocksKeepTheirIDsAndText() {
        var streaming = StreamingMarkdown()

        streaming.update(to: "# Title\n\nFirst para")
        let heading = streaming.blocks[0]
        #expect(streaming.blocks.map(\.id) == [0, 1])

        streaming.update(to: "# Title\n\nFirst paragraph.\n\n- item")
        let paragraph = streaming.blocks[1]
        #expect(streaming.blocks.map(\.id) == [0, 1, 2])
        #expect(streaming.blocks[0] == heading)
        #expect(paragraph.text == "First paragraph.")

        streaming.update(to: "# Title\n\nFirst paragraph.\n\n- item one\n- item two\n```\ncode")
        #expect(streaming.blocks.map(\.id) == [0, 1, 2, 3, 4])
        #expect(streaming.blocks[0] == heading)
        #expect(streaming.blocks[1] == paragraph)
    }

    @Test func lastBlockCanTurnIntoAnotherKind() {
        var streaming = StreamingMarkdown()

        streaming.update(to: "Steps:\n1")
        #expect(streaming.blocks.map(\.kind) == [.paragraph])

        streaming.update(to: "Steps:\n1. First")
        #expect(streaming.blocks.map(\.kind) == [.paragraph, .listItem(number: 1)])
        #expect(streaming.blocks.map(\.text) == ["Steps:", "First"])
    }

    @Test func openFenceShowsTheCodeWrittenSoFar() {
        var streaming = StreamingMarkdown()

        streaming.update(to: "```swift\nlet a = 1\nlet b")
        #expect(
            streaming.blocks == [
                MarkdownBlock(id: 0, kind: .code(language: "swift"), text: "let a = 1\nlet b")
            ])

        streaming.update(to: "```swift\nlet a = 1\nlet b = 2\n```\nDone")
        #expect(streaming.blocks.map(\.kind) == [.code(language: "swift"), .paragraph])
        #expect(streaming.blocks[0].text == "let a = 1\nlet b = 2")
    }

    @Test func textThatDoesNotGoOnFromTheTextBeforeIsReadFromItsStart() {
        var streaming = StreamingMarkdown()
        streaming.update(to: "# First attempt\n\nSome text\n\n- and a list")

        streaming.update(to: "Second attempt")
        #expect(
            streaming.blocks == [MarkdownBlock(id: 0, kind: .paragraph, text: "Second attempt")])

        streaming.update(to: "")
        #expect(streaming.blocks.isEmpty)
        #expect(streaming.text == "")
    }
}

@Suite(.timeLimit(.minutes(1))) struct MarkdownBlockParserFuzzTests {
    /// The pieces Markdown's blocks are made of, and text that is none of them. Put together
    /// at random they are mostly answers no model would write.
    private static let fragments = [
        "\n", "\n", "\n\n", "\r\n", "\r", " ", "  ", "\t", "#", "# ", "## ", "-", "- ", "* ", "+ ",
        "1", "1.", "1. ", "2) ", "12345678901", ">", "> ", "`", "``", "```", "````", "```swift",
        "word", "two words", "é", "e\u{301}", "😀", "|", "---", "**bold**", "\u{2028}", "\u{0}",
    ]

    private func randomText(using generator: inout SeededGenerator) -> String {
        var text = ""
        let fragmentCount = Int.random(in: 0...40, using: &generator)
        for _ in 0..<fragmentCount {
            text += Self.fragments.randomElement(using: &generator) ?? ""
        }
        return text
    }

    @Test func blocksEqualAFullParseForRandomText() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<1_500 {
            let text = randomText(using: &generator)

            var streaming = StreamingMarkdown()
            var textSoFar = ""
            var remaining = text.unicodeScalars[...]
            while !remaining.isEmpty {
                let length = Int.random(in: 1...6, using: &generator)
                textSoFar.unicodeScalars.append(contentsOf: remaining.prefix(length))
                remaining = remaining.dropFirst(length)
                streaming.update(to: textSoFar)

                #expect(
                    streaming.blocks == MarkdownBlockParser.blocks(of: textSoFar),
                    "after \(textSoFar.debugDescription)")
            }
        }
    }

    @Test func randomCharactersNeitherCrashNorHang() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<300 {
            var text = ""
            let length = Int.random(in: 0...400, using: &generator)
            for _ in 0..<length {
                // Mostly ASCII, where the marks are, with some of everything else.
                let upperBound: UInt32 = Bool.random(using: &generator) ? 0x7F : 0x2FFF
                let value = UInt32.random(in: 0...upperBound, using: &generator)
                if let scalar = Unicode.Scalar(value) {
                    text.unicodeScalars.append(scalar)
                }
            }

            let blocks = MarkdownBlockParser.blocks(of: text)

            #expect(blocks.map(\.id) == Array(blocks.indices))
        }
    }

    @Test func longAnswerIsReadInLinearTime() {
        // Far more than a reply can hold: the output limit is some tens of kilobytes.
        let line = "- an item with `code` and **bold** text in it\n"
        let text =
            String(repeating: line, count: 20_000) + "```\n"
            + String(repeating: "x\n", count: 20_000)
        let clock = ContinuousClock()
        let start = clock.now

        let blocks = MarkdownBlockParser.blocks(of: text)

        #expect(blocks.count == 20_001)
        #expect(clock.now - start < .seconds(10))
    }
}
