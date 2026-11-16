/// Takes the terminal's control codes out of what a script prints, so that the output screen
/// shows text and not `[31m` (docs/DESIGN.md §4.10).
///
/// Scripts are told not to use colours (`NO_COLOR`, `TERM=dumb`), and many tools do it anyway.
/// The text arrives in pieces, and a control code can be cut by the end of one, so the
/// stripper remembers where it is between calls. It goes over the UTF-8 bytes, because it
/// runs for everything a script prints, and everything it looks for is ASCII.
public struct AnsiStripper: Sendable {
    private enum State {
        case text
        /// After ESC.
        case escape
        /// After ESC and a byte such as `(` that announces more: `ESC ( B` chooses a
        /// character set. The next byte that is not of that kind ends it.
        case escapeWithArgument
        /// After `ESC [`: colours and cursor movements, up to their final byte.
        case controlSequence
        /// After `ESC ]`, a window title or a link, and after `ESC P`, `ESC X`, `ESC ^` and
        /// `ESC _`, which carry pictures and messages for the terminal: a string of any
        /// length, up to BEL or `ESC \`.
        case controlString
        /// After ESC inside a control string. A `\` ends the string.
        case escapeInControlString
    }

    private var state = State.text

    public init() {}

    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let delete: UInt8 = 0x7F

    public mutating func strip(_ text: String) -> String {
        var kept: [UInt8] = []
        kept.reserveCapacity(text.utf8.count)

        for byte in text.utf8 {
            let isKept = keeps(byte)
            if isKept {
                kept.append(byte)
            }
        }
        // Still UTF-8: bytes of a character are only ever dropped all together, inside a
        // control string.
        return String(decoding: kept, as: UTF8.self)
    }

    /// Moves on by one byte and says whether it is text.
    private mutating func keeps(_ byte: UInt8) -> Bool {
        switch state {
        case .text:
            return keepsAsText(byte)

        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                state = .controlSequence
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"),
                UInt8(ascii: "_"):
                state = .controlString
            case 0x20...0x2F:
                state = .escapeWithArgument
            case 0x30...0x7E:
                // A code of two bytes, such as `ESC c` or `ESC 7`.
                state = .text
            case Self.escape:
                break
            default:
                return leavesCodeAsText(byte)
            }
            return false

        case .escapeWithArgument:
            switch byte {
            case 0x20...0x2F:
                break
            case 0x30...0x7E:
                state = .text
            case Self.escape:
                state = .escape
            default:
                return leavesCodeAsText(byte)
            }
            return false

        case .controlSequence:
            switch byte {
            case 0x20...0x3F:
                // Parameters, such as the `1;31` of a colour.
                break
            case 0x40...0x7E:
                state = .text
            case Self.escape:
                state = .escape
            default:
                return leavesCodeAsText(byte)
            }
            return false

        case .controlString:
            switch byte {
            case Self.bell:
                state = .text
            case Self.escape:
                state = .escapeInControlString
            case UInt8(ascii: "\n"):
                // No string goes over a line. One that was never ended must not take the
                // rest of the output with it.
                return leavesCodeAsText(byte)
            default:
                break
            }
            return false

        case .escapeInControlString:
            if byte == UInt8(ascii: "\\") {
                state = .text
                return false
            }
            // The ESC began another code and ended the string with that.
            state = .escape
            return keeps(byte)
        }
    }

    /// A byte that cannot be part of the code it arrived in. The code ends there, unfinished,
    /// and the byte is looked at as text.
    private mutating func leavesCodeAsText(_ byte: UInt8) -> Bool {
        state = .text
        return keepsAsText(byte)
    }

    private mutating func keepsAsText(_ byte: UInt8) -> Bool {
        if byte == Self.escape {
            state = .escape
            return false
        }
        // The other control characters do nothing useful in a text view: a bell, a
        // backspace. Line ends and tabs stay; the output buffer knows what a lone CR means.
        let isControl = byte < 0x20 || byte == Self.delete
        if isControl {
            return byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\r")
        }
        return true
    }
}
