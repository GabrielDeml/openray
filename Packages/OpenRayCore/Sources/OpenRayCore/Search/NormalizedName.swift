import Foundation

/// Why a position in a name starts a word. The matcher gives each reason its own bonus.
enum WordStart: Sendable {
    /// The first character of the name, or the first after whitespace.
    case afterWhitespace
    /// The first character after one of `-_./()[]:,&+`.
    case afterDelimiter
    /// A Chinese, Japanese or Korean character. Those scripts do not put spaces between words,
    /// so every character counts as the start of one.
    case cjk
    /// A capital after a small letter ("gitHub"), or a change between letters and digits ("mp3").
    case caseOrDigitChange
}

/// A name folded for matching (docs/DESIGN.md §4.2.6): without case, diacritics or width, one
/// element per unicode scalar. The three arrays have the same length.
struct NormalizedName: Sendable {
    /// Longer names are cut off here. The matcher's table grows with the name's length, and no
    /// name people search for comes close.
    static let maximumLength = 256

    let scalars: [Unicode.Scalar]
    /// For each scalar, the offset of the character of the original name it was folded from.
    /// Folding can change the length ("Größe" becomes "grosse"), so highlights go back through
    /// this.
    let characterOffsets: [Int]
    /// For each scalar, why a word starts there, or nil where none does.
    let wordStarts: [WordStart?]

    init(_ name: String) {
        var scalars: [Unicode.Scalar] = []
        var characterOffsets: [Int] = []
        var wordStarts: [WordStart?] = []
        // The start of a name counts as following whitespace.
        var previousClass = CharacterClass.whitespace

        for (offset, character) in name.enumerated() {
            if scalars.count >= Self.maximumLength { break }

            let folded = Self.folded(character)
            // A soft hyphen folds to nothing. It is as if it were not there.
            if folded.isEmpty { continue }

            let characterClass = Self.characterClass(of: character)
            let wordStart = Self.wordStart(of: characterClass, after: previousClass)
            previousClass = characterClass

            // When one character folds to several scalars ("ß" to "ss"), a word can only start
            // at the first of them.
            var isFirstScalar = true
            for scalar in folded.unicodeScalars {
                if scalars.count >= Self.maximumLength { break }
                scalars.append(scalar)
                characterOffsets.append(offset)
                wordStarts.append(isFirstScalar ? wordStart : nil)
                isFirstScalar = false
            }
        }

        self.scalars = scalars
        self.characterOffsets = characterOffsets
        self.wordStarts = wordStarts
    }

    func isWordStart(at position: Int) -> Bool {
        wordStarts[position] != nil
    }

    private static func folded(_ character: Character) -> String {
        // Most names are plain ASCII, where folding is lowercasing. Foundation's `folding` would
        // bridge a string for every character.
        if character.isASCII { return character.lowercased() }
        // A soft hyphen is invisible and only says where a long word may be broken. macOS has
        // them in its German app names ("System\u{AD}einstellungen"), and nobody types one.
        if character == "\u{AD}" { return "" }
        // Composed first, as the query is. A file name comes from the disk decomposed, and
        // folding leaves Hangul and voiced kana in whichever of the two forms it finds them.
        let composed = String(character).precomposedStringWithCanonicalMapping
        return composed.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Word starts

    /// The classes come from the original character, not the folded one: folding removes the
    /// capitals that camel case is recognised by.
    private enum CharacterClass {
        case whitespace, delimiter, upper, lower, digit, cjk, other
    }

    private static let delimiters: Set<Character> = [
        "-", "_", ".", "/", "(", ")", "[", "]", ":", ",", "&", "+",
    ]

    private static func characterClass(of character: Character) -> CharacterClass {
        if character.isWhitespace { return .whitespace }
        if delimiters.contains(character) { return .delimiter }
        // Before the digits: Han numerals such as "三" count as numbers too.
        if isCJK(character) { return .cjk }
        if character.isNumber { return .digit }
        if character.isUppercase { return .upper }
        if character.isLowercase { return .lower }
        return .other
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            // Hiragana and Katakana, with the phonetic extensions and the half-width forms.
            return true
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            // Hangul Jamo, compatibility Jamo and syllables.
            return true
        default:
            return false
        }
    }

    private static func wordStart(
        of current: CharacterClass, after previous: CharacterClass
    ) -> WordStart? {
        // Whitespace and delimiters sit between words and never start one.
        if current == .whitespace || current == .delimiter { return nil }

        if previous == .whitespace { return .afterWhitespace }
        if previous == .delimiter { return .afterDelimiter }
        if current == .cjk { return .cjk }

        let previousIsLetter = previous == .upper || previous == .lower
        let currentIsLetter = current == .upper || current == .lower
        let isCamelCase = previous == .lower && current == .upper
        let isLetterToDigit = previousIsLetter && current == .digit
        let isDigitToLetter = previous == .digit && currentIsLetter
        if isCamelCase || isLetterToDigit || isDigitToLetter { return .caseOrDigitChange }
        return nil
    }
}
