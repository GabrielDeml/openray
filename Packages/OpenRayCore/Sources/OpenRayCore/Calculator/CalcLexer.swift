import Foundation

/// The functions the calculator knows, by the name they are called with.
enum CalcFunction: String, Sendable {
    case sqrt, cbrt, abs, round, floor, ceil
    case ln, log, log2
    case sin, cos, tan, asin, acos, atan
    case min, max
}

enum CalcToken: Equatable {
    case number(Decimal)
    /// "pi" or "e", as its value.
    case constant(Decimal)
    case function(CalcFunction)
    case plus, minus, times, dividedBy, power
    case mod
    /// The "of" in "15% of 200".
    case of
    case percent, factorial
    case openParenthesis, closeParenthesis
    case argumentSeparator
    /// "to", "in" or "as": the unit to convert to follows.
    case convert
    case end
}

/// Cuts an input into tokens, one at a time as the parser asks for them (docs/DESIGN.md §4.4).
///
/// On request, because a unit is not a token like the others. "in" is inches after a number and
/// a keyword elsewhere, and "m/s" would be three tokens. Only the parser knows where a unit may
/// stand, so it asks for one there with `takeUnit()`.
struct CalcLexer {
    private let characters: [Character]
    private var position = 0

    private let decimalSeparator: Character
    /// What may stand between groups of three digits. Empty when the locale has no grouping.
    private let groupingSeparators: [Character]
    private let argumentSeparators: [Character]
    /// Whether the comma is both, as it is in English: grouping in "1,234" and the separator
    /// in "max(1, 2)".
    private let groupingSeparatesArguments: Bool

    /// For each parenthesis that is open, whether it holds the arguments of a function.
    private var openParenthesesHoldArguments: [Bool] = []
    private var previousTokenWasFunction = false

    init(_ input: String, locale: Locale) {
        characters = Array(input)

        let decimalSeparator = locale.decimalSeparator?.first ?? "."
        self.decimalSeparator = decimalSeparator

        var groupingSeparators: [Character] = []
        if let separator = locale.groupingSeparator?.first, separator != decimalSeparator {
            groupingSeparators = Self.charactersTyped(for: separator)
        }
        self.groupingSeparators = groupingSeparators

        // A comma separates arguments wherever it is not needed for the decimals.
        let commaSeparatesArguments = decimalSeparator != ","
        argumentSeparators = commaSeparatesArguments ? [";", ","] : [";"]
        groupingSeparatesArguments = commaSeparatesArguments && groupingSeparators.contains(",")
    }

    /// What people type for a grouping separator. The locale names one character, and for
    /// French that is a narrow no-break space, which is on no keyboard.
    private static func charactersTyped(for groupingSeparator: Character) -> [Character] {
        let spaces: [Character] = ["\u{A0}", "\u{202F}", "\u{2009}", " "]
        // Which of the two a locale has depends on the version of the system.
        let apostrophes: [Character] = ["\u{2019}", "'"]

        if spaces.contains(groupingSeparator) { return spaces }
        if apostrophes.contains(groupingSeparator) { return apostrophes }
        return [groupingSeparator]
    }

    // MARK: Tokens

    mutating func nextToken() throws(CalcError) -> CalcToken {
        skipWhitespace()
        guard position < characters.count else { return .end }
        let character = characters[position]

        let followsFunction = previousTokenWasFunction
        previousTokenWasFunction = false

        if Self.isDigit(character) || character == decimalSeparator {
            return .number(try scanNumber())
        }
        if character.isLetter {
            return try scanName()
        }

        position += 1
        switch character {
        case "+":
            return .plus
        case "-", "−":
            return .minus
        case "*", "×", "·":
            return .times
        case "/", "÷":
            return .dividedBy
        case "^":
            return .power
        case "%":
            return .percent
        case "!":
            return .factorial
        case "(":
            openParenthesesHoldArguments.append(followsFunction)
            return .openParenthesis
        case ")":
            _ = openParenthesesHoldArguments.popLast()
            return .closeParenthesis
        default:
            if argumentSeparators.contains(character) { return .argumentSeparator }
            throw .syntax
        }
    }

    /// The unit written next, if there is one. For the places where the grammar allows a unit:
    /// right after a number, and after "to", "in" or "as".
    mutating func takeUnit() -> CalcUnit? {
        skipWhitespace()
        guard let found = CalcUnits.unit(in: characters, at: position) else { return nil }
        position += found.length
        return found.unit
    }

    private mutating func skipWhitespace() {
        while position < characters.count, characters[position].isWhitespace {
            position += 1
        }
    }

    // MARK: Numbers

    /// Whether the character is a decimal digit of any script: "7", "７", "٧". A superscript or
    /// a fraction such as "½" is a number to Unicode, but not a digit.
    static func isDigit(_ character: Character) -> Bool {
        digitValue(of: character) != nil
    }

    private static func digitValue(of character: Character) -> Int? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        guard scalar.properties.numericType == .decimal,
            let value = scalar.properties.numericValue
        else { return nil }
        return Int(exactly: value)
    }

    /// Reads digits, an optional fraction, and grouping separators between groups of three.
    private mutating func scanNumber() throws(CalcError) -> Decimal {
        // The number as `Decimal` reads it: ASCII digits and a point.
        var plainText = ""

        let leadingDigitCount = scanDigits(into: &plainText)
        var digitCount = leadingDigitCount
        // A first group has one to three digits: "1,234" and "123,456", but not "1234,567".
        // And it does not begin with a zero: nobody writes 125 as "0,125", and somebody used
        // to a decimal comma means an eighth by it. That input is an error, not 125.
        let beginsWithZero = plainText.first == "0"
        let canBeFirstGroup = (1...3).contains(leadingDigitCount) && !beginsWithZero
        if isGroupingAllowed && canBeFirstGroup {
            while isGroupOfThree(at: position) {
                position += 1
                digitCount += scanDigits(into: &plainText)
            }
        }

        if position < characters.count, characters[position] == decimalSeparator {
            position += 1
            plainText.append(".")
            digitCount += scanDigits(into: &plainText)
        }

        // A decimal separator on its own is not a number. "5." and ".5" are.
        if digitCount == 0 { throw .syntax }
        return try CalcMath.decimal(fromPlainText: plainText)
    }

    /// Consumes the digits at the current position.
    ///
    /// - Returns: How many there were.
    private mutating func scanDigits(into plainText: inout String) -> Int {
        var count = 0
        while position < characters.count, let digit = Self.digitValue(of: characters[position]) {
            plainText.append(String(digit))
            position += 1
            count += 1
        }
        return count
    }

    /// Where a character is both the grouping and an argument separator, the arguments win:
    /// "max(100,200)" has two. A number in parentheses of its own can still be grouped:
    /// "max((1,234), 5)".
    private var isGroupingAllowed: Bool {
        let isDirectlyInArgumentList = openParenthesesHoldArguments.last ?? false
        return !(groupingSeparatesArguments && isDirectlyInArgumentList)
    }

    /// Whether a grouping separator stands at `index` with exactly three digits behind it.
    /// Anything else is not grouping: in "1,23" the comma separates two numbers.
    private func isGroupOfThree(at index: Int) -> Bool {
        guard index < characters.count, groupingSeparators.contains(characters[index]) else {
            return false
        }
        let afterGroup = index + 4
        if afterGroup > characters.count { return false }
        for digitIndex in (index + 1)..<afterGroup {
            if !Self.isDigit(characters[digitIndex]) { return false }
        }
        let fourthDigitFollows =
            afterGroup < characters.count && Self.isDigit(characters[afterGroup])
        return !fourthDigitFollows
    }

    // MARK: Names

    /// Reads a word: letters, and digits after them for "log2". Case does not count.
    private mutating func scanName() throws(CalcError) -> CalcToken {
        var name = ""
        while position < characters.count {
            let character = characters[position]
            guard character.isLetter || Self.isDigit(character) else { break }
            name.append(character)
            position += 1
        }
        name = name.lowercased()

        switch name {
        case "pi", "π":
            return .constant(.pi)
        case "e":
            return .constant(CalcMath.e)
        case "mod":
            return .mod
        case "of":
            return .of
        case "to", "in", "as":
            return .convert
        default:
            break
        }

        guard let function = CalcFunction(rawValue: name) else { throw .unknownName }
        previousTokenWasFunction = true
        return .function(function)
    }
}
