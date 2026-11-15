import Foundation
import Testing

@testable import OpenRayCore

/// SplitMix64, a small random number generator. The tests here need the same inputs on every
/// run, and the system's generator cannot be seeded.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

// MARK: - Against Double

/// An expression made at random, to be written out for the calculator and worked out in
/// `Double` next to it.
private indirect enum RandomExpression {
    /// A number, as the digits it is written with.
    case number(String)
    case negation(RandomExpression)
    case binary(Operator, RandomExpression, RandomExpression)
    case power(RandomExpression, exponent: Int)
    case squareRoot(RandomExpression)
    case absoluteValue(RandomExpression)

    enum Operator: String {
        case plus = "+"
        case minus = "-"
        case times = "*"
        case dividedBy = "/"
    }

    // MARK: Making one

    static func random(depth: Int, using generator: inout SplitMix64) -> RandomExpression {
        let isNumber = depth == 0 || Int.random(in: 0..<5, using: &generator) == 0
        if isNumber {
            return .number(randomDigits(using: &generator))
        }

        let operand = random(depth: depth - 1, using: &generator)
        switch Int.random(in: 0..<8, using: &generator) {
        case 0:
            return .binary(.plus, operand, random(depth: depth - 1, using: &generator))
        case 1:
            return .binary(.minus, operand, random(depth: depth - 1, using: &generator))
        case 2:
            return .binary(.times, operand, random(depth: depth - 1, using: &generator))
        case 3:
            return .binary(.dividedBy, operand, random(depth: depth - 1, using: &generator))
        case 4:
            return .negation(operand)
        case 5:
            return .power(operand, exponent: Int.random(in: -3...4, using: &generator))
        case 6:
            return .squareRoot(operand)
        default:
            return .absoluteValue(operand)
        }
    }

    /// A whole number below 1000, or one with up to three decimals.
    private static func randomDigits(using generator: inout SplitMix64) -> String {
        let whole = Int.random(in: 0..<1000, using: &generator)
        if Bool.random(using: &generator) { return String(whole) }

        let decimalCount = Int.random(in: 1...3, using: &generator)
        var decimals = ""
        for _ in 0..<decimalCount {
            decimals.append(String(Int.random(in: 0...9, using: &generator)))
        }
        return "\(whole).\(decimals)"
    }

    // MARK: Writing it out

    /// How tightly an expression holds together, from the loosest to the tightest. The order is
    /// the calculator's grammar: `arith`, `term`, `unary`, `power`, and what needs no
    /// parentheses anywhere.
    private enum Binding: Comparable {
        case sum, product, signed, power, operand
    }

    private var binding: Binding {
        switch self {
        case .binary(.plus, _, _), .binary(.minus, _, _):
            return .sum
        case .binary(.times, _, _), .binary(.dividedBy, _, _):
            return .product
        case .negation:
            return .signed
        case .power:
            return .power
        case .number, .squareRoot, .absoluteValue:
            return .operand
        }
    }

    /// The text for a place that takes anything from `loosest` upwards without parentheses.
    private func text(whereLoosestIs loosest: Binding) -> String {
        binding >= loosest ? text : "(\(text))"
    }

    /// The expression as an American would type it, with no more parentheses than the grammar
    /// needs, so that the comparison tests precedence and associativity as well.
    var text: String {
        switch self {
        case .number(let digits):
            return digits

        case .negation(let operand):
            // "-2^2" is -(2^2), so a power needs no parentheses behind a sign.
            return "-" + operand.text(whereLoosestIs: .signed)

        case .binary(let symbol, let left, let right):
            // The operators are worked out from the left, so the left side may be of the same
            // level and the right side has to be one tighter: "a - (b - c)".
            let isSum = binding == .sum
            let leftText = left.text(whereLoosestIs: isSum ? .sum : .product)
            let rightText = right.text(whereLoosestIs: isSum ? .product : .signed)
            return "\(leftText) \(symbol.rawValue) \(rightText)"

        case .power(let base, let exponent):
            // A sign or another power as the base would be read differently: "(-2)^2",
            // "(2^3)^2".
            return "\(base.text(whereLoosestIs: .operand))^\(exponent)"

        case .squareRoot(let operand):
            return "sqrt(\(operand.text))"

        case .absoluteValue(let operand):
            return "abs(\(operand.text))"
        }
    }

    // MARK: Working it out in Double

    /// The value in `Double`, or nil where the comparison would not be fair.
    var doubleValue: Double? {
        let value: Double
        switch self {
        case .number(let digits):
            guard let number = Double(digits) else { return nil }
            value = number

        case .negation(let operand):
            guard let operandValue = operand.doubleValue else { return nil }
            value = -operandValue

        case .binary(let symbol, let left, let right):
            guard let leftValue = left.doubleValue, let rightValue = right.doubleValue else {
                return nil
            }
            switch symbol {
            case .plus:
                value = leftValue + rightValue
            case .minus:
                value = leftValue - rightValue
            case .times:
                value = leftValue * rightValue
            case .dividedBy:
                if rightValue == 0 { return nil }
                value = leftValue / rightValue
            }

            // A sum much smaller than its terms has lost the digits the comparison is made
            // with: 0.1 + 0.2 - 0.3 is 5.5e-17 in `Double` and 0 in `Decimal`. A sum that is
            // left in has lost one digit at most.
            let isSum = symbol == .plus || symbol == .minus
            let largerTerm = max(abs(leftValue), abs(rightValue))
            if isSum && abs(value) < largerTerm / 10 { return nil }

        case .power(let base, let exponent):
            guard let baseValue = base.doubleValue else { return nil }
            if baseValue == 0 && exponent < 0 { return nil }
            value = pow(baseValue, Double(exponent))

        case .squareRoot(let operand):
            guard let operandValue = operand.doubleValue, operandValue >= 0 else { return nil }
            value = operandValue.squareRoot()

        case .absoluteValue(let operand):
            guard let operandValue = operand.doubleValue else { return nil }
            value = abs(operandValue)
        }
        return value.isFinite ? value : nil
    }
}

@Suite(.timeLimit(.minutes(1))) struct CalculatorPropertyTests {
    private static let seed: UInt64 = 2026
    /// How deep the expressions are, and so how many sums can stand inside one another.
    private static let depth = 4

    /// How far the calculator may be from `Double`, as a share of the value: they agree to 11
    /// digits. A `Double` has close to 16. Every sum inside another can cost one, which with
    /// a depth of four leaves 12, and one more goes to the rounding of everything else.
    private static let tolerance = 1e-11

    @Test func randomExpressionsAgreeWithDouble() throws {
        var generator = SplitMix64(seed: Self.seed)
        var comparedCount = 0

        for _ in 0..<5000 {
            let expression = RandomExpression.random(depth: Self.depth, using: &generator)
            guard let expected = expression.doubleValue else { continue }

            // An error on the calculator's side is no disagreement either: `Decimal` runs
            // out of range sooner than `Double` does.
            guard let result = try? Calculator.evaluate(expression.text, locale: enUS) else {
                continue
            }
            let actual = try CalcMath.double(from: result.value.number)

            #expect(
                abs(actual - expected) <= abs(expected) * Self.tolerance,
                "Seed \(Self.seed): \(expression.text) is \(actual), and \(expected) in Double")
            comparedCount += 1
        }

        // Most expressions have to get this far, or the test says nothing.
        #expect(comparedCount > 3000)
    }
}

// MARK: - Fuzzing

@Suite(.timeLimit(.minutes(1))) struct CalculatorFuzzTests {
    private static let locales = [enUS, deDE, frCH]

    /// Everything the calculator does with one input, in every locale. What comes out is of no
    /// interest: the test is that this returns.
    private func exercise(_ input: String) {
        for locale in Self.locales {
            guard let result = try? Calculator.evaluate(input, locale: locale) else { continue }
            let isApproximate = result.isApproximate
            _ = CalcFormatter.displayText(
                for: result.value, isApproximate: isApproximate, locale: locale)
            _ = CalcFormatter.copyText(
                for: result.value, isApproximate: isApproximate, locale: locale)
        }
    }

    @Test func randomBytesNeitherCrashNorHang() {
        var generator = SplitMix64(seed: 1)
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<5000 {
            // Some longer than the calculator reads.
            let length = Int.random(in: 0...300, using: &generator)
            var bytes: [UInt8] = []
            for _ in 0..<length {
                // Half of them printable ASCII, so that more gets past the lexer.
                if Bool.random(using: &generator) {
                    bytes.append(UInt8.random(in: 0x20...0x7E, using: &generator))
                } else {
                    bytes.append(UInt8.random(in: .min ... .max, using: &generator))
                }
            }
            exercise(String(decoding: bytes, as: UTF8.self))
        }

        #expect(clock.now - start < .seconds(10))
    }

    /// The calculator's own alphabet. Strung together at random these are mostly not
    /// expressions, which is the point: the lexer and the parser see what no user would type.
    private static let fragments: [String] = [
        "0", "1", "2", "7", "9", "10", "42", "999", "１", "٣", "५", "²", "½",
        ".", ",", "'", "\u{2019}", " ", "\u{A0}", "\u{202F}", ";",
        "+", "-", "−", "*", "×", "·", "/", "÷", "^", "%", "!", "(", ")",
        "pi", "π", "e", "E", "mod", "of", "to", "in", "as",
        "sqrt", "cbrt", "abs", "round", "floor", "ceil", "ln", "log", "log2", "sin", "cos", "tan",
        "asin", "acos", "atan", "min", "max", "MAX",
        "km", "m", "m/s", "km/h", "°C", "F", "K", "fl oz", "m²", "sq m", "GB", "Mb", "kb", "min",
        "d", "weeks", "in", "ft", "kg", "lb", "L",
        "x", "@", "\n", "🙂", "e\u{301}",
    ]

    @Test func randomStringsOverTheCalculatorsAlphabetNeitherCrashNorHang() {
        var generator = SplitMix64(seed: 2)
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<5000 {
            let fragmentCount = Int.random(in: 0...16, using: &generator)
            var input = ""
            for _ in 0..<fragmentCount {
                input += Self.fragments.randomElement(using: &generator) ?? ""
                if Bool.random(using: &generator) {
                    input += " "
                }
            }
            exercise(input)
        }

        #expect(clock.now - start < .seconds(10))
    }

    // What follows writes inputs that are expressions most of the time, so that the fuzzing
    // gets past the parser and into the arithmetic: units, percentages, factorials, powers.

    private static let numbers = [
        "0", "1", "2", "3", "10", "100", "103", "170", "999", "0.5", "0.001", "1,000", "12,345.678",
        "１２", "٣", "99999999999999999999", "0.00000000000000000001",
    ]
    private static let units = [
        "km", "m", "mi", "in", "kg", "lb", "L", "gal", "m²", "ac", "°C", "F", "K", "km/h", "mph",
        "s", "min", "h", "d", "weeks", "B", "kb", "Mb", "GiB",
    ]
    private static let functions = [
        "sqrt", "cbrt", "abs", "round", "floor", "ceil", "ln", "log", "log2", "sin", "cos", "tan",
        "asin", "acos", "atan", "min", "max",
    ]
    private static let operators = ["+", "-", "*", "/", "^", "mod", "of", "×", "÷"]

    private static func pick(_ choices: [String], using generator: inout SplitMix64) -> String {
        choices.randomElement(using: &generator) ?? ""
    }

    private static func randomOperand(depth: Int, using generator: inout SplitMix64) -> String {
        let number = pick(numbers, using: &generator)
        if depth == 0 { return number }

        switch Int.random(in: 0..<12, using: &generator) {
        case 0...2:
            return number
        case 3, 4:
            return "\(number) \(pick(units, using: &generator))"
        case 5:
            return pick(["pi", "e", "π"], using: &generator)
        case 6:
            let argument = randomExpression(depth: depth - 1, using: &generator)
            return "\(pick(functions, using: &generator))(\(argument))"
        case 7:
            let first = randomExpression(depth: depth - 1, using: &generator)
            let second = randomExpression(depth: depth - 1, using: &generator)
            return "\(pick(["min", "max", "sqrt"], using: &generator))(\(first), \(second))"
        case 8:
            return "(\(randomExpression(depth: depth - 1, using: &generator)))"
        case 9:
            return randomOperand(depth: depth - 1, using: &generator) + "%"
        case 10:
            return randomOperand(depth: depth - 1, using: &generator) + "!"
        default:
            return "-" + randomOperand(depth: depth - 1, using: &generator)
        }
    }

    private static func randomExpression(depth: Int, using generator: inout SplitMix64) -> String {
        var expression = randomOperand(depth: depth, using: &generator)
        let operatorCount = Int.random(in: 0...3, using: &generator)
        for _ in 0..<operatorCount {
            let symbol = pick(operators, using: &generator)
            let operand = randomOperand(depth: depth, using: &generator)
            expression += " \(symbol) \(operand)"
        }
        return expression
    }

    @Test func randomExpressionsNeitherCrashNorHang() {
        var generator = SplitMix64(seed: 3)
        let clock = ContinuousClock()
        let start = clock.now
        var answeredCount = 0

        for _ in 0..<5000 {
            var input = Self.randomExpression(depth: 3, using: &generator)
            if Int.random(in: 0..<4, using: &generator) == 0 {
                input += " to \(Self.pick(Self.units, using: &generator))"
            }
            exercise(input)

            if (try? Calculator.evaluate(input, locale: enUS)) != nil {
                answeredCount += 1
            }
        }

        #expect(clock.now - start < .seconds(10))
        // Enough of them have to be expressions, or the arithmetic was not fuzzed at all.
        #expect(answeredCount > 500)
    }

    /// Inputs made to cost as much as an input can: as deep, as long and as large as the limits
    /// allow, and just beyond.
    private static let hostileInputs: [String] = {
        let nines = String(repeating: "9", count: 100)
        let zeros = String(repeating: "0", count: 200)
        return [
            String(repeating: "(", count: 256),
            String(repeating: "-", count: 256),
            String(repeating: "2^", count: 128),
            String(repeating: "9", count: 256),
            String(repeating: "9^", count: 127) + "9",
            String(repeating: "9!", count: 128),
            String(repeating: "sqrt(", count: 51),
            String(repeating: "1,", count: 128),
            String(repeating: "1e", count: 128),
            String(repeating: "5 km to ", count: 32),
            "9\(zeros)!",
            "0.\(zeros)1 * 2",
            "(\(nines))^(\(nines))",
            "2^-\(nines)",
            "2^0.\(nines)",
            "10^165 * 10^165 / 10^-128",
            "1 / 3 / 3 / 3 mod 0.0000000000000000000000000000000000001",
            "tan(pi / 2) ^ 20",
            "\u{0}1+1\u{0}",
        ]
    }()

    @Test(arguments: hostileInputs)
    func hostileInputNeitherCrashesNorHangs(_ input: String) {
        let clock = ContinuousClock()
        let start = clock.now

        exercise(input)

        #expect(clock.now - start < .seconds(1))
    }
}
