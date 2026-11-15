import Foundation

/// An input as the parser understood it.
///
/// The cases are few on purpose. The evaluator has one for each in the method that calls
/// itself for every level of an expression, and that method has to stay small on the stack.
indirect enum CalcExpression {
    /// A number as typed, with its unit if one follows it. "pi" and "e" are numbers too.
    case number(CalcValue)
    case unary(UnaryOperator, CalcExpression)
    case binary(BinaryOperator, CalcExpression, CalcExpression)
    case call(CalcFunction, arguments: [CalcExpression])

    enum UnaryOperator {
        case negate
        /// `x%`: a hundredth of x.
        case percent
        /// `x!`.
        case factorial
        /// `x to unit`.
        case convert(to: CalcUnit)
    }

    enum BinaryOperator {
        case add, subtract, multiply, divide, modulo, power
        /// `x + y%` and `x - y%`: x with that share of itself added or taken off. The right
        /// operand is the percentage, whose value is the share: 0.15 for 15%.
        case addPercent, subtractPercent
    }

    /// Whether the expression is a percentage: `x%`, the negation of a percentage, or the sum
    /// or difference of two percentages. Nothing else is. A product with a percent in it is a
    /// plain number, so that "50 + 200 * 15%" is 50 + 30.
    var isPercentage: Bool {
        switch self {
        case .unary(.percent, _):
            return true
        case .unary(.negate, let operand):
            return operand.isPercentage
        case .binary(.add, let left, let right), .binary(.subtract, let left, let right):
            return left.isPercentage && right.isPercentage
        case .number, .unary, .binary, .call:
            return false
        }
    }

    /// Whether there is anything to work out: an operator, a function or a conversion. A number
    /// is not a calculation, with or without a sign, a unit or parentheses around it.
    var isCalculation: Bool {
        switch self {
        case .number:
            return false
        case .unary(.negate, let operand):
            return operand.isCalculation
        case .unary, .binary, .call:
            return true
        }
    }
}

/// A recursive-descent parser for the calculator's grammar (docs/DESIGN.md §4.4):
///
///     input    := arith [ ("to"|"in"|"as") unit ]
///     arith    := term  { ("+"|"-") term }
///     term     := unary { ("*"|"×"|"·"|"/"|"÷"|"mod"|"of") unary }
///     unary    := ("-"|"+") unary | power
///     power    := postfix [ "^" unary ]
///     postfix  := primary [ "%" | "!" ]
///     primary  := number [unit] | "pi" | "e" | func "(" arith { argsep arith } ")" | "(" arith ")"
///
/// There is one method for each rule.
struct CalcParser {
    /// How deep parentheses, signs and exponents may nest. Each level of the input is several
    /// calls deep here, and the stack is not endless.
    static let maximumDepth = 64

    private var lexer: CalcLexer
    /// The token the rules are looking at.
    private var current: CalcToken
    /// The one before it. `nil` at the start.
    private var previous: CalcToken?
    private var depth = 0

    init(_ input: String, locale: Locale) throws(CalcError) {
        lexer = CalcLexer(input, locale: locale)
        current = try lexer.nextToken()
    }

    private mutating func advance() throws(CalcError) {
        previous = current
        current = try lexer.nextToken()
    }

    /// Steps over `token`, which has to be the current one.
    private mutating func expect(_ token: CalcToken) throws(CalcError) {
        if current != token { throw .syntax }
        try advance()
    }

    // MARK: The rules

    mutating func parseInput() throws(CalcError) -> CalcExpression {
        var expression = try parseArithmetic()

        if current == .convert {
            // Before the next token is read: only here can the lexer be told that what follows
            // is a unit.
            guard let unit = lexer.takeUnit() else { throw .syntax }
            try advance()
            expression = .unary(.convert(to: unit), expression)
        }

        if current != .end { throw .syntax }
        return expression
    }

    private mutating func parseArithmetic() throws(CalcError) -> CalcExpression {
        var left = try parseTerm()
        while current == .plus || current == .minus {
            let isAddition = current == .plus
            try advance()
            let right = try parseTerm()

            // "200 + 15%" is 15% more than 200, as on a pocket calculator, and "100 + -10%"
            // is 10% less than 100. Between two percentages the sign is a plain sum, however
            // long the chain: "5% + 10% + 10%" is 0.25.
            if right.isPercentage && !left.isPercentage {
                left = .binary(isAddition ? .addPercent : .subtractPercent, left, right)
            } else {
                left = .binary(isAddition ? .add : .subtract, left, right)
            }
        }
        return left
    }

    private mutating func parseTerm() throws(CalcError) -> CalcExpression {
        var left = try parseUnary()
        while true {
            let operation: CalcExpression.BinaryOperator
            switch current {
            case .times:
                operation = .multiply
            case .dividedBy:
                operation = .divide
            case .mod:
                operation = .modulo
            case .of:
                // "15% of 200". Anywhere else "of" is a word the calculator does not know.
                if previous != .percent { throw .syntax }
                operation = .multiply
            default:
                return left
            }
            try advance()
            let right = try parseUnary()
            left = .binary(operation, left, right)
        }
    }

    private mutating func parseUnary() throws(CalcError) -> CalcExpression {
        // Counted here because every way the grammar has of nesting comes through this rule:
        // a parenthesis, an argument, an exponent, a sign.
        // The outermost call is level 0: it is not nested in anything.
        if depth > Self.maximumDepth { throw .tooDeep }
        depth += 1
        defer { depth -= 1 }

        if current == .minus {
            try advance()
            return .unary(.negate, try parseUnary())
        }
        if current == .plus {
            try advance()
            return try parseUnary()
        }
        return try parsePower()
    }

    private mutating func parsePower() throws(CalcError) -> CalcExpression {
        let base = try parsePostfix()
        if current != .power { return base }

        try advance()
        // A unary and not a postfix: that makes "^" bind to the right, so 2^3^2 is 2^9, and
        // lets the exponent have a sign, as in 2^-3. A sign in front of the base stays
        // outside the power: -2^2 is -4.
        let exponent = try parseUnary()
        return .binary(.power, base, exponent)
    }

    private mutating func parsePostfix() throws(CalcError) -> CalcExpression {
        let operand = try parsePrimary()
        if current == .percent {
            try advance()
            return .unary(.percent, operand)
        }
        if current == .factorial {
            try advance()
            return .unary(.factorial, operand)
        }
        return operand
    }

    private mutating func parsePrimary() throws(CalcError) -> CalcExpression {
        switch current {
        case .number(let number):
            // Before the next token is read, as in `parseInput`.
            let unit = lexer.takeUnit()
            try advance()
            return .number(CalcValue(number: number, unit: unit))

        case .constant(let value):
            try advance()
            return .number(CalcValue(number: value, unit: nil))

        case .function(let function):
            try advance()
            try expect(.openParenthesis)
            var arguments = [try parseArithmetic()]
            while current == .argumentSeparator {
                try advance()
                arguments.append(try parseArithmetic())
            }
            try expect(.closeParenthesis)
            return .call(function, arguments: arguments)

        case .openParenthesis:
            try advance()
            let inner = try parseArithmetic()
            try expect(.closeParenthesis)
            return inner

        default:
            throw .syntax
        }
    }
}
