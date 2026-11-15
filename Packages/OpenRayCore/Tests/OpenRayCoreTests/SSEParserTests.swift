import Testing

import OpenRayCore

@Suite struct SSEParserTests {
    /// Everything a parser makes of the text when it arrives in one piece.
    private func events(in text: String) -> [ServerSentEvent] {
        var parser = SSEParser()
        return parser.consume(Array(text.utf8))
    }

    @Test func blankLineEndsAnEvent() {
        let events = events(in: "event: greeting\ndata: hello\n\n")

        #expect(events == [ServerSentEvent(event: "greeting", data: "hello")])
    }

    @Test func eventWithoutANameHasNone() {
        #expect(events(in: "data: hello\n\n") == [ServerSentEvent(event: nil, data: "hello")])
        #expect(
            events(in: "event:\ndata: hello\n\n") == [ServerSentEvent(event: nil, data: "hello")])
    }

    @Test func severalDataLinesAreJoinedWithLineFeeds() {
        let events = events(in: "data: one\ndata: two\ndata:\ndata: four\n\n")

        #expect(events == [ServerSentEvent(data: "one\ntwo\n\nfour")])
    }

    @Test func onlyOneSpaceAfterTheColonIsDropped() {
        #expect(events(in: "data:tight\n\n") == [ServerSentEvent(data: "tight")])
        #expect(events(in: "data:  indented\n\n") == [ServerSentEvent(data: " indented")])
        #expect(events(in: "data: a: b\n\n") == [ServerSentEvent(data: "a: b")])
    }

    @Test func commentLinesAreSkipped() {
        let text = ": a comment\nevent: greeting\n: another, between the fields\ndata: hello\n\n"

        #expect(events(in: text) == [ServerSentEvent(event: "greeting", data: "hello")])
    }

    @Test func fieldWithoutAColonHasAnEmptyValue() {
        // "data" alone is a data line without text. "event" alone names nothing.
        #expect(events(in: "data\n\n") == [ServerSentEvent(data: "")])
        #expect(events(in: "event\ndata: hello\n\n") == [ServerSentEvent(data: "hello")])
    }

    @Test func blankLineWithoutDataEndsNothing() {
        #expect(events(in: "\n\n\n").isEmpty)
        #expect(events(in: "event: lonely\n\n").isEmpty)
        // The name of the event that came to nothing does not stick to the next one.
        #expect(events(in: "event: lonely\n\ndata: hello\n\n") == [ServerSentEvent(data: "hello")])
    }

    @Test func idRetryAndUnknownFieldsAreIgnored() {
        let text = "id: 7\nretry: 3000\nmood: fine\ndata: hello\n\n"

        #expect(events(in: text) == [ServerSentEvent(data: "hello")])
    }

    @Test func linesMayEndInCarriageReturnLineFeedOrACarriageReturnAlone() {
        let expected = [
            ServerSentEvent(event: "a", data: "one"), ServerSentEvent(event: "b", data: "two"),
        ]

        #expect(
            events(in: "event: a\r\ndata: one\r\n\r\nevent: b\r\ndata: two\r\n\r\n") == expected)
        #expect(events(in: "event: a\rdata: one\r\revent: b\rdata: two\r\r") == expected)
    }

    @Test func lineFeedThatOpensTheNextChunkBelongsToTheCarriageReturnBeforeIt() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []

        // Were the line feed taken for a line of its own, it would be the blank line that
        // ends the event, and "one" would arrive without "two".
        events += parser.consume(Array("data: one\r".utf8))
        events += parser.consume(Array("\ndata: two\r".utf8))
        events += parser.consume(Array("\n\r".utf8))
        events += parser.consume(Array("\n".utf8))

        #expect(events == [ServerSentEvent(data: "one\ntwo")])
    }

    @Test func leadingByteOrderMarkIsDropped() {
        let withMark: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("data: hello\n\n".utf8)

        var parser = SSEParser()
        #expect(parser.consume(withMark) == [ServerSentEvent(data: "hello")])

        // Also when the three bytes arrive one at a time.
        var slowParser = SSEParser()
        var events: [ServerSentEvent] = []
        for byte in withMark {
            events += slowParser.consume([byte])
        }
        #expect(events == [ServerSentEvent(data: "hello")])
    }

    @Test func byteOrderMarkLaterInTheStreamIsLeftAlone() {
        let text = "data: first\n\n\u{FEFF}data: second\n\n"

        // The second line's field is not called "data" with the mark in front of it, so
        // nothing is collected and the blank line ends nothing.
        #expect(events(in: text) == [ServerSentEvent(data: "first")])
    }

    @Test func characterSplitAcrossChunksIsReadWhole() {
        let bytes = Array("data: Zürich 🇨🇭 東京\n\n".utf8)
        var parser = SSEParser()
        var events: [ServerSentEvent] = []

        for byte in bytes {
            events += parser.consume([byte])
        }

        #expect(events == [ServerSentEvent(data: "Zürich 🇨🇭 東京")])
    }

    @Test func bytesThatAreNotUTF8BecomeReplacementCharacters() {
        let bytes: [UInt8] = Array("data: a".utf8) + [0xFF, 0xC3] + Array("b\n\n".utf8)

        var parser = SSEParser()
        #expect(parser.consume(bytes) == [ServerSentEvent(data: "a\u{FFFD}\u{FFFD}b")])
    }

    @Test func eventWithoutItsBlankLineIsNotDelivered() {
        var parser = SSEParser()

        #expect(parser.consume(Array("data: complete\n\ndata: cut off\n".utf8)).count == 1)
    }

    @Test func finishDropsTheEventThatWasCutOff() {
        var parser = SSEParser()
        _ = parser.consume(Array("event: half\ndata: cut off\n".utf8))

        parser.finish()

        // Neither a blank line nor a new event brings back what the stream ended on.
        #expect(parser.consume(Array("\n".utf8)).isEmpty)
        #expect(parser.consume(Array("data: next\n\n".utf8)) == [ServerSentEvent(data: "next")])
    }

    @Test func consumeTakesAnyCollectionOfBytes() {
        var parser = SSEParser()
        let bytes = Array("xxdata: hello\n\nxx".utf8)

        #expect(parser.consume(bytes[2..<(bytes.count - 2)]) == [ServerSentEvent(data: "hello")])
        #expect(parser.consume("data: again\n\n".utf8) == [ServerSentEvent(data: "again")])
    }
}

@Suite(.timeLimit(.minutes(1))) struct SSEParserFuzzTests {
    /// What the parser makes of the bytes when they arrive cut up as `chunking` says.
    private func events(in bytes: [UInt8], _ chunking: Chunking) -> [ServerSentEvent] {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for chunk in chunking.chunks(of: bytes) {
            events += parser.consume(chunk)
        }
        parser.finish()
        return events
    }

    @Test func randomBytesNeitherCrashNorHang() {
        var generator = SeededGenerator(seed: 1)
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<2000 {
            let length = Int.random(in: 0...600, using: &generator)
            var bytes: [UInt8] = []
            for _ in 0..<length {
                bytes.append(UInt8.random(in: .min ... .max, using: &generator))
            }
            _ = events(in: bytes, .whole)
        }

        #expect(clock.now - start < .seconds(10))
    }

    /// The pieces a stream is made of, and some that only look like them. Strung together at
    /// random they are mostly streams no server would send.
    private static let fragments: [String] = [
        "data", "data:", "data: ", "event", "event:", "event: ", "id: 1", "retry: 10", ":",
        ": note",
        "\n", "\n", "\n\n", "\r", "\r\n", "\r\n\r\n", "\n\r", " ", "\u{FEFF}", "\u{0}",
        "{\"type\":\"ping\"}", "message_start", "é", "🙂", "日本", "x",
    ]

    @Test func sameBytesGiveTheSameEventsHoweverTheyAreCut() {
        var generator = SeededGenerator(seed: 2)
        let clock = ContinuousClock()
        let start = clock.now
        var eventCount = 0

        for _ in 0..<500 {
            let fragmentCount = Int.random(in: 0...60, using: &generator)
            var text = ""
            for _ in 0..<fragmentCount {
                text += Self.fragments.randomElement(using: &generator) ?? ""
            }
            let bytes = Array(text.utf8)

            let whole = events(in: bytes, .whole)
            #expect(events(in: bytes, .byteByByte) == whole)
            #expect(events(in: bytes, .random) == whole)
            eventCount += whole.count
        }

        #expect(clock.now - start < .seconds(10))
        // Enough of the inputs have to hold events, or the comparison said nothing.
        #expect(eventCount > 100)
    }

    @Test func lineThatNeverEndsIsReadInLinearTime() {
        let clock = ContinuousClock()
        let start = clock.now

        var parser = SSEParser()
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 4096)
        for _ in 0..<2000 {
            #expect(parser.consume(chunk).isEmpty)
        }

        #expect(clock.now - start < .seconds(10))
    }
}
