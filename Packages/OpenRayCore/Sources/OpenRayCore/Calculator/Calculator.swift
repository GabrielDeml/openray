import Foundation

/// A number and the unit it is in, if it has one.
struct CalcValue: Sendable, Equatable {
    var number: Decimal
    var unit: CalcUnit?
}

/// What an input works out to.
struct CalcResult: Sendable {
    var value: CalcValue
    /// Whether the input asked for anything to be worked out: an operator, a function or a
    /// conversion. "42", "-42", "(42)", "pi" and "10 km" are expressions too, but the launcher
    /// has nothing to tell the user about them.
    var isCalculation: Bool
    /// Whether the answer came through `Double` on the way, and so has 15 or 16 digits that
    /// mean something and not the 38 of a `Decimal`. It is shown with no more digits than it
    /// has.
    var isApproximate: Bool
}

/// Why an input has no answer. The launcher shows none of these: an input without an answer
/// gets no row (docs/DESIGN.md §4.4). The error still says which it was, so that a test can
/// tell a typing mistake from an overflow.
enum CalcError: Error, Equatable {
    /// Longer than `Calculator.maximumInputLength`.
    case tooLong
    /// Parentheses, signs or exponents nested deeper than `CalcParser.maximumDepth`.
    case tooDeep
    /// Not an expression: it ends early, or something stands where it cannot.
    case syntax
    /// A word that is neither a function, a constant nor a keyword.
    case unknownName
    case divisionByZero
    /// A number too large or too small for a `Decimal`, or beyond one of the calculator's
    /// own limits.
    case outOfRange
    /// A function asked for a value it does not have: sqrt(-1), ln(0), 5.5!.
    case undefined
    /// Units that do not go together: 5 km + 3 kg, 5 km × 2 km, 5 to km.
    case incompatibleUnits
}

/// The calculator behind the launcher's inline answers (docs/DESIGN.md §4.4): a hand-written
/// lexer, parser and evaluator, because every keystroke of every query comes through here and
/// none of them may crash the launcher.
enum Calculator {
    /// In Unicode scalars. The evaluator calls itself once for every level of an expression,
    /// and the length of the input is what bounds that: a sum of 128 terms is 128 levels deep.
    /// Raising this means looking at the stack again.
    static let maximumInputLength = 256

    /// Whether an input is too long to be looked at. Cheap for an input of any size, so that
    /// a file pasted into the search field costs nothing.
    static func isTooLong(_ input: String) -> Bool {
        // The number of bytes is known without walking the text, and a scalar has four at
        // most. Counting characters instead would walk all of it: 20 MB of combining marks
        // are one character and took most of a second.
        if input.utf8.count > 4 * maximumInputLength { return true }
        return input.unicodeScalars.count > maximumInputLength
    }

    /// - Parameter locale: Decides how numbers are written: the decimal separator, the grouping
    ///   separator and what separates the arguments of a function.
    static func evaluate(_ input: String, locale: Locale) throws(CalcError) -> CalcResult {
        if isTooLong(input) { throw .tooLong }

        var parser = try CalcParser(input, locale: locale)
        let expression = try parser.parseInput()
        var evaluator = CalcEvaluator()
        let value = try evaluator.value(of: expression)
        return CalcResult(
            value: value, isCalculation: expression.isCalculation,
            isApproximate: evaluator.wentThroughDouble)
    }
}
