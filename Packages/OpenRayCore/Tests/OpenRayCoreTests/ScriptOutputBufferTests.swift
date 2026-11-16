import Foundation
import Testing

@testable import OpenRayCore

@Suite struct ScriptOutputBufferTests {
    /// The buffer after the pieces arrived one by one.
    private func buffer(
        after pieces: [String], capacity: Int = 4 * 1024 * 1024
    ) -> ScriptOutputBuffer {
        var buffer = ScriptOutputBuffer(capacity: capacity)
        for piece in pieces {
            buffer.append(piece)
        }
        return buffer
    }

    private func texts(after pieces: String..., capacity: Int = 4 * 1024 * 1024) -> [String] {
        buffer(after: pieces, capacity: capacity).lines.map(\.text)
    }

    // MARK: Lines

    @Test func nothingPrintedIsEmpty() {
        let buffer = ScriptOutputBuffer()

        #expect(buffer.isEmpty)
        #expect(buffer.lines == [])
        #expect(buffer.text == "")
        #expect(!buffer.hasDroppedOutput)
    }

    @Test func emptyPieceIsNothingPrinted() {
        #expect(buffer(after: ["", ""]).isEmpty)
    }

    @Test func lineFeedsEndLines() {
        #expect(texts(after: "one\ntwo\nthree\n") == ["one", "two", "three"])
    }

    @Test func textWithoutALineEndIsALineThatStillGrows() {
        var buffer = ScriptOutputBuffer()

        buffer.append("Down")
        #expect(buffer.lines.map(\.text) == ["Down"])

        buffer.append("loading")
        #expect(buffer.lines.map(\.text) == ["Downloading"])

        buffer.append("…\ndone")
        #expect(buffer.lines.map(\.text) == ["Downloading…", "done"])
        #expect(!buffer.isEmpty)
    }

    @Test func emptyLinesAreLines() {
        #expect(texts(after: "one\n\n\ntwo") == ["one", "", "", "two"])
        #expect(texts(after: "\n") == [""])
        #expect(texts(after: "\n", "\n") == ["", ""])
    }

    @Test func windowsLineEndsEndOneLine() {
        #expect(texts(after: "one\r\ntwo\r\n\r\nthree") == ["one", "two", "", "three"])
    }

    @Test func loneCarriageReturnStartsTheLineOver() {
        #expect(texts(after: "10%\r50%\r100%\ndone\n") == ["100%", "done"])
    }

    @Test func textBeforeACarriageReturnStaysUntilSomethingWritesOverIt() {
        var buffer = ScriptOutputBuffer()

        buffer.append("50%\r")
        // A progress bar that waits for its next step is still to be seen.
        #expect(buffer.lines.map(\.text) == ["50%"])

        buffer.append("\r")
        #expect(buffer.lines.map(\.text) == ["50%"])

        buffer.append("100%")
        #expect(buffer.lines.map(\.text) == ["100%"])
    }

    @Test func carriageReturnAndLineFeedInSeparatePieces() {
        #expect(texts(after: "one\r", "\ntwo") == ["one", "two"])
        #expect(texts(after: "one", "\r", "\n", "two") == ["one", "two"])
        #expect(texts(after: "one\r", "two") == ["two"])
    }

    // What a terminal layer makes of a CR LF that it is handed: `ssh -tt`, `docker exec -t`.
    @Test func severalCarriageReturnsInARowCountAsOne() {
        #expect(texts(after: "one\r\r\ntwo") == ["one", "two"])
        #expect(texts(after: "one\r", "\r", "\ntwo") == ["one", "two"])
        #expect(texts(after: "one\r\rtwo") == ["two"])
    }

    @Test func carriageReturnAtTheStartOfALineChangesNothing() {
        #expect(texts(after: "one\n\rtwo") == ["one", "two"])
        #expect(texts(after: "\rone") == ["one"])
    }

    @Test func textIsTheLinesJoined() {
        #expect(buffer(after: ["one\ntwo\n\nthree"]).text == "one\ntwo\n\nthree")
        #expect(buffer(after: ["one\r\ntwo\r\n"]).text == "one\ntwo")
    }

    @Test func charactersOfSeveralBytesStayWhole() {
        #expect(texts(after: "Grüße 🙂\n世界\r\n👩‍👩‍👧") == ["Grüße 🙂", "世界", "👩‍👩‍👧"])
    }

    // MARK: IDs

    @Test func linesAreNumberedFromTheFirst() {
        let threeLines = buffer(after: ["one\ntwo\n", "three"])

        #expect(threeLines.lines.map(\.id) == [0, 1, 2])
    }

    @Test func lineKeepsItsNumberWhileItGrowsAndWhenItStartsOver() {
        var buffer = ScriptOutputBuffer()
        buffer.append("one\n10%")
        #expect(buffer.lines.last?.id == 1)

        buffer.append(" and more")
        #expect(buffer.lines.last?.id == 1)
        #expect(buffer.lines.last?.text == "10% and more")

        buffer.append("\r20%")
        #expect(buffer.lines.last?.id == 1)
        #expect(buffer.lines.last?.text == "20%")

        buffer.append("\nnext")
        #expect(buffer.lines.last?.id == 2)
    }

    // MARK: Long lines

    @Test func lineLongerThanOneLineHoldsIsKeptAsSeveral() {
        let longLine = String(repeating: "x", count: 10_000) + "END"
        var buffer = ScriptOutputBuffer()

        buffer.append("first\n" + longLine + "\nlast")

        let texts = buffer.lines.map(\.text)
        #expect(
            texts == [
                "first", String(repeating: "x", count: 4_096), String(repeating: "x", count: 4_096),
                String(repeating: "x", count: 1_808) + "END", "last",
            ])
        #expect(buffer.lines.map(\.continuesLine) == [false, false, true, true, false])
        #expect(buffer.lines.map(\.id) == [0, 1, 2, 3, 4])
        // What is copied has the line ends the script printed, and no others.
        #expect(buffer.text == "first\n" + longLine + "\nlast")
    }

    @Test func longLineThatArrivesInPiecesIsCutInTheSamePlaces() {
        var inPieces = ScriptOutputBuffer()
        var whole = ""
        for number in 0..<1_500 {
            inPieces.append("piece \(number) ")
            whole += "piece \(number) "
        }
        var inOne = ScriptOutputBuffer()
        inOne.append(whole)

        #expect(inPieces.lines.count > 1)
        #expect(inPieces.lines == inOne.lines)
        #expect(inPieces.text == whole)
        for line in inPieces.lines {
            #expect(line.text.utf8.count <= ScriptOutputBuffer.maximumLineLength)
        }
    }

    @Test func longLineIsNotCutInsideACharacter() {
        var buffer = ScriptOutputBuffer()

        // Three bytes each, so a line holds 1,365 of them and one byte stays free.
        buffer.append(String(repeating: "世", count: 3_000))

        #expect(buffer.lines.map(\.text.count) == [1_365, 1_365, 270])
        #expect(!buffer.text.unicodeScalars.contains("\u{FFFD}"))
        #expect(buffer.text == String(repeating: "世", count: 3_000))
    }

    @Test func letterAndItsAccentStayOnOneLine() {
        var buffer = ScriptOutputBuffer()
        let almostFull = String(repeating: "x", count: ScriptOutputBuffer.maximumLineLength - 1)

        // An "e" and a combining accent: one character of two scalars, and only the "e"
        // would fit.
        buffer.append(almostFull + "e\u{301}")

        #expect(buffer.lines.map(\.text) == [almostFull, "e\u{301}"])
    }

    // A read can end between the scalars of one character.
    @Test func characterThatArrivesInTwoPiecesIsCutAsIfItCameInOne() {
        let almostFull = String(repeating: "x", count: ScriptOutputBuffer.maximumLineLength - 1)

        var accent = ScriptOutputBuffer()
        accent.append(almostFull + "e")
        accent.append("\u{301}rest")
        #expect(accent.lines.map(\.text) == [almostFull, "e\u{301}rest"])
        #expect(accent.text == almostFull + "e\u{301}rest")

        // A flag is two letters of a kind, and a third begins the next flag.
        let roomForOneLetter = String(
            repeating: "x", count: ScriptOutputBuffer.maximumLineLength - 4)
        var flag = ScriptOutputBuffer()
        flag.append(roomForOneLetter + "\u{1F1E9}")
        flag.append("\u{1F1EA}\u{1F1EB}")
        #expect(flag.lines.map(\.text) == [roomForOneLetter, "\u{1F1E9}\u{1F1EA}\u{1F1EB}"])
    }

    @Test func carriageReturnStartsALongLineOverFromItsBeginning() {
        var buffer = ScriptOutputBuffer(capacity: 16 * 1024)

        for _ in 0..<5 {
            buffer.append(String(repeating: "x", count: 10_000) + "\r")
        }
        buffer.append("done")

        #expect(buffer.lines.map(\.text) == ["done"])
        #expect(buffer.lines.first?.id == 0)
        // Each round gave back what it had taken, or the five would have been too much.
        #expect(!buffer.hasDroppedOutput)
    }

    // MARK: The limit

    /// A line that counts for 100 bytes: its text and what every line counts for besides.
    private func hundredByteLine(_ number: Int) -> String {
        let length = 100 - ScriptOutputBuffer.lineOverhead
        return "line \(number)".padding(toLength: length, withPad: ".", startingAt: 0)
    }

    @Test func oldestLinesGoWhenThereIsTooMuch() {
        var buffer = ScriptOutputBuffer(capacity: 1_000)
        for number in 0..<10 {
            buffer.append(hundredByteLine(number) + "\n")
        }
        #expect(!buffer.hasDroppedOutput)
        #expect(buffer.lines.count == 10)

        buffer.append(hundredByteLine(10) + "\n")

        #expect(buffer.hasDroppedOutput)
        // Down to three quarters of the limit, so that not every further line drops one.
        #expect(buffer.lines.first?.text == hundredByteLine(4))
        #expect(buffer.lines.last?.text == hundredByteLine(10))
        #expect(buffer.lines.map(\.id) == [4, 5, 6, 7, 8, 9, 10])
    }

    @Test func numbersGoOnAfterLinesWereDropped() {
        var buffer = ScriptOutputBuffer(capacity: 1_000)
        for number in 0..<200 {
            buffer.append("line \(number)\n")
        }

        #expect(buffer.lines.last?.id == 199)
        #expect(buffer.lines.last?.text == "line 199")
        let ids = buffer.lines.map(\.id)
        #expect(ids == Array((200 - ids.count)..<200))
    }

    @Test func neverMoreIsKeptThanTheLimit() {
        var generator = SeededGenerator(seed: 19)
        let fragments = ["a", "bc", "é", "🙂", "\n", "\n", "\r", "\r\n", "some longer text"]
        // Room for a few lines of the greatest length, as the smallest buffer in use has.
        let capacity = 16 * 1024
        var buffer = ScriptOutputBuffer(capacity: capacity)

        for round in 0..<2_000 {
            var piece = ""
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                piece += fragments.randomElement(using: &generator) ?? ""
            }
            // Now and then a line of many kilobytes.
            if round % 100 == 99 {
                piece += String(repeating: "long ", count: 3_000)
            }
            buffer.append(piece)

            var keptBytes = 0
            for line in buffer.lines {
                keptBytes += line.text.utf8.count + ScriptOutputBuffer.lineOverhead
            }
            #expect(keptBytes <= capacity)
        }
        #expect(buffer.hasDroppedOutput)
    }

    @Test func shortLinesAreBoundedInNumber() {
        // A script that prints nothing but line ends, or "y" and a line end as `yes` does,
        // must not leave millions of rows.
        let capacity = 100 * ScriptOutputBuffer.lineOverhead
        var emptyLines = ScriptOutputBuffer(capacity: capacity)
        var shortLines = ScriptOutputBuffer(capacity: capacity)

        emptyLines.append(String(repeating: "\n", count: 10_000))
        shortLines.append(String(repeating: "y\n", count: 10_000))

        #expect(emptyLines.hasDroppedOutput)
        #expect(emptyLines.lines.count <= 100)
        #expect(emptyLines.lines.last?.id == 9_999)
        #expect(shortLines.lines.count <= 100)
        #expect(shortLines.lines.last?.id == 9_999)
    }

    @Test func bufferOfTheUsualSizeKeepsNoMoreThanSomeTenThousandLines() {
        var buffer = ScriptOutputBuffer()

        // What `yes` prints, in pieces as large as the runner reads: 262,144 lines in all.
        let piece = String(repeating: "y\n", count: 32 * 1024)
        for _ in 0..<8 {
            buffer.append(piece)
        }

        #expect(buffer.lines.count <= 65_536)
        #expect(buffer.lines.last?.text == "y")
    }

    @Test func oldestPartOfOneLongLineGoesLikeOldLines() {
        var buffer = ScriptOutputBuffer(capacity: 16 * 1024)

        buffer.append(String(repeating: "x", count: 40_000))

        #expect(buffer.hasDroppedOutput)
        // Ten lines were made. The seven oldest had to go to get below three quarters.
        #expect(buffer.lines.map(\.id) == [7, 8, 9])
        #expect(buffer.lines.first?.continuesLine == true)
        #expect(buffer.text == String(repeating: "x", count: 4_096 + 4_096 + 3_136))
    }

    // MARK: Pieces

    @Test(.timeLimit(.minutes(1))) func anyPiecesGiveTheSameLines() {
        var generator = SeededGenerator(seed: 5)
        let fragments = [
            "a", "word ", "é", "🙂", "\n", "\n", "\r", "\r", "\r\n", "100%", "", "世界",
        ]

        for _ in 0..<2_000 {
            var pieces: [String] = []
            for _ in 0..<Int.random(in: 0...8, using: &generator) {
                var piece = ""
                for _ in 0..<Int.random(in: 0...6, using: &generator) {
                    piece += fragments.randomElement(using: &generator) ?? ""
                }
                pieces.append(piece)
            }

            let inPieces = buffer(after: pieces)
            let inOne = buffer(after: [pieces.joined()])

            #expect(inPieces.lines == inOne.lines, "Pieces \(pieces.map { Array($0.utf8) })")
            #expect(inPieces.text == inOne.text)
        }
    }
}
