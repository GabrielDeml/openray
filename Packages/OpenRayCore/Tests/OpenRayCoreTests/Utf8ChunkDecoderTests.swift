import Foundation
import Testing

import OpenRayCore

@Suite struct Utf8ChunkDecoderTests {
    /// Decodes the pieces one after the other and joins what comes out, the last of it from
    /// `finish`.
    private func decode(_ pieces: [[UInt8]]) -> String {
        var decoder = Utf8ChunkDecoder()
        var text = ""
        for piece in pieces {
            text += decoder.decode(piece)
        }
        return text + decoder.finish()
    }

    @Test func wholeTextInOnePiece() {
        var decoder = Utf8ChunkDecoder()

        #expect(decoder.decode(Array("Grüße, 世界 🙂\n".utf8)) == "Grüße, 世界 🙂\n")
        #expect(decoder.finish() == "")
    }

    @Test(arguments: ["é", "世", "🙂"])
    func characterCutAtEveryPosition(character: String) {
        let bytes = Array("a\(character)b".utf8)

        for cut in 0...bytes.count {
            let pieces = [Array(bytes[..<cut]), Array(bytes[cut...])]
            #expect(decode(pieces) == "a\(character)b", "Cut after \(cut) bytes")
        }
    }

    @Test func characterIsHeldBackUntilItIsWhole() {
        let smiley = Array("🙂".utf8)
        var decoder = Utf8ChunkDecoder()

        #expect(decoder.decode([UInt8(ascii: "a"), smiley[0]]) == "a")
        #expect(decoder.decode([smiley[1]]) == "")
        #expect(decoder.decode([smiley[2]]) == "")
        #expect(decoder.decode([smiley[3], UInt8(ascii: "b")]) == "🙂b")
        #expect(decoder.finish() == "")
    }

    @Test func textByteByByte() {
        let text = "naïve café 日本語 👩‍👩‍👧 done"
        var pieces: [[UInt8]] = []
        for byte in text.utf8 {
            pieces.append([byte])
        }

        #expect(decode(pieces) == text)
    }

    @Test func emptyPiecesChangeNothing() {
        let euro = Array("€".utf8)

        #expect(decode([[], [euro[0]], [], [euro[1]], [], [euro[2]], []]) == "€")
    }

    @Test func bytesThatAreNotUTF8BecomeReplacementCharacters() {
        var decoder = Utf8ChunkDecoder()

        // A continuation byte without a lead byte, and a byte that is never valid.
        #expect(decoder.decode([0x61, 0x80, 0x62, 0xFF, 0x63]) == "a\u{FFFD}b\u{FFFD}c")
        #expect(decoder.finish() == "")
    }

    @Test func characterThatIsNeverFinishedComesOutOfFinish() {
        let smiley = Array("🙂".utf8)
        var decoder = Utf8ChunkDecoder()

        #expect(decoder.decode([0x61] + smiley[..<3]) == "a")
        #expect(decoder.finish() == "\u{FFFD}")
        // And only once.
        #expect(decoder.finish() == "")
    }

    @Test func leadByteFollowedByTextIsNotWaitedFor() {
        var decoder = Utf8ChunkDecoder()

        // The lead byte of a three-byte character, then ASCII: nothing can complete it.
        #expect(decoder.decode([0xE4, 0x61, 0x62]) == "\u{FFFD}ab")
    }

    @Test(.timeLimit(.minutes(1))) func anyCutsGiveTheTextOfTheWholeBytes() {
        var generator = SeededGenerator(seed: 41)
        // Lead bytes, continuation bytes and ASCII in a mix that makes valid characters,
        // broken ones and the edges between them all likely.
        let interestingBytes: [UInt8] = [
            0x41, 0x0A, 0x80, 0xBF, 0xC2, 0xC3, 0xE0, 0xE2, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF,
            0x9F, 0xA0, 0x82, 0xAC,
        ]

        for _ in 0..<3_000 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...40, using: &generator) {
                if Int.random(in: 0..<4, using: &generator) == 0 {
                    bytes.append(UInt8.random(in: 0...255, using: &generator))
                } else {
                    bytes.append(interestingBytes.randomElement(using: &generator) ?? 0x41)
                }
            }

            var pieces: [[UInt8]] = []
            var remaining = bytes[...]
            while !remaining.isEmpty {
                let length = Int.random(in: 0...5, using: &generator)
                pieces.append(Array(remaining.prefix(length)))
                remaining = remaining.dropFirst(length)
            }

            #expect(
                decode(pieces) == String(decoding: bytes, as: UTF8.self),
                "Bytes \(bytes) in pieces \(pieces)")
        }
    }
}
