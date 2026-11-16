/// Turns the bytes a script prints into text, piece by piece as they are read from its pipe
/// (docs/DESIGN.md §4.10).
///
/// A read can end in the middle of a character. The bytes of a character that is not whole
/// yet are held back until the rest arrives, so the pieces put together are exactly the text
/// that decoding all the bytes at once would give. Bytes that are not UTF-8 become
/// replacement characters, as they do there.
public struct Utf8ChunkDecoder: Sendable {
    /// The first bytes of a character whose other bytes have not been read yet. Never more
    /// than three.
    private var heldBack: [UInt8] = []

    public init() {}

    public mutating func decode(_ bytes: some Collection<UInt8>) -> String {
        var buffer = heldBack
        buffer.append(contentsOf: bytes)

        let incompleteLength = Self.lengthOfIncompleteCharacter(atEndOf: buffer)
        heldBack = Array(buffer.suffix(incompleteLength))
        return String(decoding: buffer.dropLast(incompleteLength), as: UTF8.self)
    }

    /// What is left when the script has closed its pipe: a character that was never
    /// finished, as a replacement character, or nothing.
    public mutating func finish() -> String {
        let rest = String(decoding: heldBack, as: UTF8.self)
        heldBack = []
        return rest
    }

    /// How many bytes at the end begin a character and wait for more: a lead byte with fewer
    /// continuation bytes behind it than it announces.
    ///
    /// Only the place of the cut matters, not whether the bytes are valid. A lead byte always
    /// begins something new for a decoder, whatever came before it, so cutting right before
    /// one never changes what either side decodes to.
    private static func lengthOfIncompleteCharacter(atEndOf bytes: [UInt8]) -> Int {
        // The longest character has four bytes, so a lead byte that still waits is one of
        // the last three.
        var length = 1
        while length <= 3 && length <= bytes.count {
            let byte = bytes[bytes.count - length]

            let isContinuation = byte & 0b1100_0000 == 0b1000_0000
            if isContinuation {
                length += 1
                continue
            }

            let announcedLength: Int
            if byte >= 0b1111_0000 {
                announcedLength = 4
            } else if byte >= 0b1110_0000 {
                announcedLength = 3
            } else if byte >= 0b1100_0000 {
                announcedLength = 2
            } else {
                announcedLength = 1
            }
            return length < announcedLength ? length : 0
        }
        return 0
    }
}
