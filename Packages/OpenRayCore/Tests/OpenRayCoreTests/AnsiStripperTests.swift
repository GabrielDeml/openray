import Foundation
import Testing

import OpenRayCore

@Suite struct AnsiStripperTests {
    private let escape = "\u{1B}"
    private let bell = "\u{07}"

    private func strip(_ text: String) -> String {
        var stripper = AnsiStripper()
        return stripper.strip(text)
    }

    /// Strips the pieces with one stripper, as the pieces of one script's output are.
    private func strip(pieces: [String]) -> String {
        var stripper = AnsiStripper()
        var text = ""
        for piece in pieces {
            text += stripper.strip(piece)
        }
        return text
    }

    @Test func plainTextIsUntouched() {
        let text = "Grüße, 世界 🙂 [31m is not a colour without its ESC; 100% done]"

        #expect(strip(text) == text)
        #expect(strip("") == "")
    }

    @Test func tabsAndLineEndsAreKept() {
        #expect(strip("a\tb\nc\r\nd\re") == "a\tb\nc\r\nd\re")
    }

    @Test func coloursAreTakenOut() {
        #expect(strip("\(escape)[31mred\(escape)[0m plain") == "red plain")
        #expect(strip("\(escape)[1;38;5;208mbold orange\(escape)[m") == "bold orange")
        #expect(strip("\(escape)[38;2;255;100;0mtrue colour\(escape)[39;49m") == "true colour")
    }

    @Test func cursorMovesAndErasingAreTakenOut() {
        #expect(strip("50%\(escape)[2K\(escape)[1G100%") == "50%100%")
        #expect(strip("\(escape)[?25lworking\(escape)[?25h") == "working")
        #expect(strip("\(escape)[10;20Hhere\(escape)[2J") == "here")
    }

    @Test func windowTitleIsTakenOutWhetherEndedByBellOrByStringTerminator() {
        #expect(strip("\(escape)]0;My Title\(bell)text") == "text")
        #expect(strip("\(escape)]2;Tïtle 🙂\(escape)\\text") == "text")
    }

    // A tool that ignores TERM=dumb and draws a picture sends its data in one of these.
    @Test func otherStringsForTheTerminalAreTakenOutWithWhatTheyCarry() {
        // Sixel graphics, in a device control string.
        #expect(strip("a\(escape)Pq#0;2;0;0;0\(escape)\\b") == "ab")
        // The kitty graphics protocol, in an application program command.
        #expect(strip("a\(escape)_Gf=100;iVBORw0KGgo=\(escape)\\b") == "ab")
        // A privacy message and a start of string, which nothing is known to use.
        #expect(strip("a\(escape)^hidden\(escape)\\b\(escape)Xhidden\(bell)c") == "abc")
        #expect(strip("\(escape)Pnever ended\nnext line\n") == "\nnext line\n")
    }

    @Test func linkKeepsItsTextAndLosesItsAddress() {
        let link = "\(escape)]8;;https://example.com\(escape)\\Example\(escape)]8;;\(escape)\\"

        #expect(strip("See \(link).") == "See Example.")
    }

    @Test func titleThatIsNeverEndedStopsAtTheLine() {
        #expect(strip("\(escape)]0;no end\nnext line\n") == "\nnext line\n")
    }

    @Test func anotherCodeInsideATitleEndsTheTitle() {
        #expect(strip("\(escape)]0;title\(escape)[31mred") == "red")
    }

    @Test func twoByteCodesAndCharacterSetsAreTakenOut() {
        #expect(strip("\(escape)7saved\(escape)8") == "saved")
        #expect(strip("\(escape)creset") == "reset")
        #expect(strip("\(escape)(Bascii\(escape))0") == "ascii")
        #expect(strip("\(escape)=keypad\(escape)>") == "keypad")
    }

    @Test func otherControlCharactersAreTakenOut() {
        #expect(
            strip("ding\(bell) back\u{08}space null\u{0} delete\u{7F}.")
                == "ding backspace null delete.")
    }

    @Test func codeBrokenOffByALineEndOrByOtherTextLosesOnlyItself() {
        #expect(strip("\(escape)[31\nnext") == "\nnext")
        #expect(strip("\(escape)[31é") == "é")
        #expect(strip("\(escape)\nnext") == "\nnext")
        #expect(strip("\(escape)\(escape)\(escape)[1mbold") == "bold")
    }

    @Test func codeAtTheVeryEndIsTakenOut() {
        #expect(strip("text\(escape)") == "text")
        #expect(strip("text\(escape)[") == "text")
        #expect(strip("text\(escape)[3") == "text")
    }

    @Test func codeCutAtEveryPositionBetweenTwoPieces() {
        let samples = [
            "before\(escape)[1;31mred\(escape)[0m after",
            "before\(escape)]0;a title\(bell)after",
            "before\(escape)]8;;https://example.com\(escape)\\link\(escape)]8;;\(escape)\\ after",
            "before\(escape)(Bafter\(escape)7\r\n",
        ]

        for sample in samples {
            let whole = strip(sample)
            let scalars = Array(sample.unicodeScalars)
            for cut in 0...scalars.count {
                var first = ""
                first.unicodeScalars.append(contentsOf: scalars[..<cut])
                var second = ""
                second.unicodeScalars.append(contentsOf: scalars[cut...])

                #expect(strip(pieces: [first, second]) == whole, "Cut after \(cut) scalars")
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func anyPiecesGiveTheSameTextAndNeverAnEscape() {
        var generator = SeededGenerator(seed: 27)
        let fragments = [
            escape, "[", "]", "(", ")", "\\", bell, "\n", "\r", "\t", "0", ";", "3", "1", "m",
            "K", "?", " ", "a", "é", "世", "🙂", "\u{0}", "\u{7F}", "\u{9B}",
        ]

        for _ in 0..<3_000 {
            var pieces: [String] = []
            for _ in 0..<Int.random(in: 0...6, using: &generator) {
                var piece = ""
                for _ in 0..<Int.random(in: 0...8, using: &generator) {
                    piece += fragments.randomElement(using: &generator) ?? ""
                }
                pieces.append(piece)
            }
            let whole = pieces.joined()

            let stripped = strip(pieces: pieces)

            #expect(stripped == strip(whole), "Pieces \(pieces.map { Array($0.utf8) })")
            #expect(!stripped.unicodeScalars.contains("\u{1B}"))
            #expect(!stripped.unicodeScalars.contains("\u{07}"))
        }
    }
}
