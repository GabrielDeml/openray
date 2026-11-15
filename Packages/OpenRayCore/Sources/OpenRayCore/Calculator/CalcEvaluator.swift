import Foundation

/// Works a parsed expression out (docs/DESIGN.md §4.4).
///
/// The four operations, `mod` and whole powers stay in `Decimal`, so 0.1 + 0.2 is 0.3. The
/// functions without a decimal answer, and powers with a fraction in the exponent, go through
/// `Double`.
struct CalcEvaluator {
    /// Whether anything went through `Double` on the way to the answer. Such an answer has
    /// the 15 or 16 digits of a `Double`, whatever a `Decimal` can hold.
    private(set) var wentThroughDouble = false

    mutating func value(of expression: CalcExpression) throws(CalcError) -> CalcValue {
        // Nothing is worked out in here. An expression can be over a hundred levels deep, this
        // method calls itself once for each, and whatever it keeps on the stack it keeps a
        // hundred times.
        switch expression {
        case .number(let value):
            return value
        case .unary(let operation, let operand):
            return try Self.apply(operation, to: try value(of: operand))
        case .binary(let operation, let left, let right):
            return try combine(operation, try value(of: left), try value(of: right))
        case .call(let function, let arguments):
            return try call(function, with: try values(of: arguments))
        }
    }

    private mutating func values(
        of expressions: [CalcExpression]
    ) throws(CalcError) -> [CalcValue] {
        var values: [CalcValue] = []
        for expression in expressions {
            values.append(try value(of: expression))
        }
        return values
    }

    // MARK: Operators

    private static func apply(
        _ operation: CalcExpression.UnaryOperator, to operand: CalcValue
    ) throws(CalcError) -> CalcValue {
        switch operation {
        case .negate:
            return CalcValue(number: -operand.number, unit: operand.unit)
        case .percent:
            let hundredth = try CalcMath.divide(try plainNumber(operand), by: 100)
            return CalcValue(number: hundredth, unit: nil)
        case .factorial:
            let factorial = try CalcMath.factorial(try plainNumber(operand))
            return CalcValue(number: factorial, unit: nil)
        case .convert(let unit):
            // A plain number has nothing to convert from.
            guard let from = operand.unit else { throw .incompatibleUnits }
            let converted = try CalcUnits.convert(operand.number, from: from, to: unit)
            return CalcValue(number: converted, unit: unit)
        }
    }

    private mutating func combine(
        _ operation: CalcExpression.BinaryOperator, _ left: CalcValue, _ right: CalcValue
    ) throws(CalcError) -> CalcValue {
        switch operation {
        case .add:
            let addend = try Self.termOfASum(right, inUnitOf: left)
            return CalcValue(number: try CalcMath.add(left.number, addend), unit: left.unit)

        case .subtract:
            let subtrahend = try Self.termOfASum(right, inUnitOf: left)
            return CalcValue(
                number: try CalcMath.subtract(left.number, subtrahend), unit: left.unit)

        case .multiply:
            // A measurement times a number keeps its unit. Two measurements would make a unit
            // the calculator does not have: metres times metres.
            if left.unit != nil && right.unit != nil { throw .incompatibleUnits }
            let product = try CalcMath.multiply(left.number, right.number)
            return CalcValue(number: product, unit: left.unit ?? right.unit)

        case .divide:
            if right.unit == nil {
                let quotient = try CalcMath.divide(left.number, by: right.number)
                return CalcValue(number: quotient, unit: left.unit)
            }
            // Two measurements of one kind: how many times one goes into the other, which is
            // a plain number. A number divided by a measurement is nothing, and
            // `number(of:inUnitOf:)` throws for it.
            let divisor = try Self.number(of: right, inUnitOf: left)
            return CalcValue(number: try CalcMath.divide(left.number, by: divisor), unit: nil)

        case .modulo:
            // Which whole number the quotient is just above decides the remainder, so the
            // operands are taken without the noise in their last digits: (1/3 × 3) mod 1 is 0.
            let dividend = try CalcMath.withoutRoundingNoise(try Self.plainNumber(left))
            let divisor = try CalcMath.withoutRoundingNoise(try Self.plainNumber(right))
            let remainder = try CalcMath.remainder(dividend, dividingBy: divisor)
            return CalcValue(number: remainder, unit: nil)

        case .power:
            let base = try Self.plainNumber(left)
            let exponent = try Self.plainNumber(right)
            // A whole exponent is worked out in `Decimal`, one with a fraction in `Double`.
            if !CalcMath.isWhole(exponent) {
                wentThroughDouble = true
            }
            return CalcValue(number: try CalcMath.power(base, exponent), unit: nil)

        case .addPercent:
            let share = try Self.share(right, of: left)
            return CalcValue(number: try CalcMath.add(left.number, share), unit: left.unit)

        case .subtractPercent:
            let share = try Self.share(right, of: left)
            return CalcValue(number: try CalcMath.subtract(left.number, share), unit: left.unit)
        }
    }

    /// That share of the number of `whole`: 0.15 and 200 km give 30.
    private static func share(
        _ fraction: CalcValue, of whole: CalcValue
    ) throws(CalcError) -> Decimal {
        try CalcMath.multiply(whole.number, try plainNumber(fraction))
    }

    /// The right side of a sum or a difference as a number in the unit of the left side.
    private static func termOfASum(
        _ term: CalcValue, inUnitOf left: CalcValue
    ) throws(CalcError) -> Decimal {
        // "10 °C + 50 °F" has no one answer. Is 50 °F a point on the scale, which is 10 °C, or
        // a difference of 50 degrees Fahrenheit, which is 27.8 degrees Celsius? Either would
        // be a guess. In one unit the question does not come up.
        if let unit = term.unit, let leftUnit = left.unit {
            let areTemperatures = unit.quantity == .temperature && leftUnit.quantity == .temperature
            if areTemperatures && unit != leftUnit { throw .incompatibleUnits }
        }
        return try number(of: term, inUnitOf: left)
    }

    // MARK: Functions

    private mutating func call(
        _ function: CalcFunction, with arguments: [CalcValue]
    ) throws(CalcError) -> CalcValue {
        switch function {
        case .min:
            return try Self.extreme(of: arguments, takingSmallest: true)
        case .max:
            return try Self.extreme(of: arguments, takingSmallest: false)

        // These four stay in `Decimal`, and a measurement keeps its unit through them.
        case .abs:
            let argument = try Self.onlyArgument(of: arguments)
            return CalcValue(number: argument.number.magnitude, unit: argument.unit)
        case .round:
            return try Self.rounded(arguments, .plain)
        case .floor:
            return try Self.rounded(arguments, .down)
        case .ceil:
            return try Self.rounded(arguments, .up)

        // NaN is how a function says that it has no value there.
        case .sqrt:
            return try throughDouble(arguments) { x in x.squareRoot() }
        case .cbrt:
            return try throughDouble(arguments) { x in cbrt(x) }
        // The logarithm of zero is minus infinity in `Double`, which would read as a number
        // out of range. It is as undefined as that of a negative number, so both are NaN.
        case .ln:
            return try throughDouble(arguments) { x in x > 0 ? log(x) : .nan }
        case .log:
            return try throughDouble(arguments) { x in x > 0 ? log10(x) : .nan }
        case .log2:
            return try throughDouble(arguments) { x in x > 0 ? log2(x) : .nan }
        case .sin:
            return try throughDouble(arguments) { x in Self.trigonometric(sin(x), of: x) }
        case .cos:
            return try throughDouble(arguments) { x in Self.trigonometric(cos(x), of: x) }
        case .tan:
            return try throughDouble(arguments) { x in Self.trigonometric(tan(x), of: x) }
        case .asin:
            return try throughDouble(arguments) { x in asin(x) }
        case .acos:
            return try throughDouble(arguments) { x in acos(x) }
        case .atan:
            return try throughDouble(arguments) { x in atan(x) }
        }
    }

    /// `round`, `floor` and `ceil` of the only argument.
    private static func rounded(
        _ arguments: [CalcValue], _ mode: NSDecimalNumber.RoundingMode
    ) throws(CalcError) -> CalcValue {
        let argument = try onlyArgument(of: arguments)
        // One digit decides which whole number it is, so the noise in the last digits comes
        // off first: floor(1/3 × 3) is 1.
        let number = try CalcMath.withoutRoundingNoise(argument.number)
        return CalcValue(number: CalcMath.rounded(number, mode), unit: argument.unit)
    }

    /// A function of one plain number that is worked out in `Double`. Angles are in radians.
    private mutating func throughDouble(
        _ arguments: [CalcValue], _ function: (Double) -> Double
    ) throws(CalcError) -> CalcValue {
        let argument = try Self.plainNumber(try Self.onlyArgument(of: arguments))
        let result = function(try CalcMath.double(from: argument))
        wentThroughDouble = true
        return CalcValue(number: try CalcMath.decimal(from: result), unit: nil)
    }

    /// A sine, cosine or tangent as it is worth showing, given the angle it is of.
    private static func trigonometric(_ value: Double, of angle: Double) -> Double {
        // A `Double` this large has no digits behind the point, so it does not say where on
        // the circle the angle is: sin(10^30) is noise. Infinity is how that is said here,
        // as NaN is for a value that does not exist; it ends as `.outOfRange`.
        if abs(angle) >= 1e15 { return .infinity }

        // `Double` has no exact pi, so sin(pi) comes out as 1.2e-16 where 0 is meant. What is
        // that small against its angle is lost in the rounding of the angle. The sine of a
        // small angle is as small as the angle, and stays.
        if abs(value) < 1e-15 * abs(angle) { return 0 }
        return value
    }

    /// The smallest or the largest of the arguments. Measurements are compared in the unit of
    /// the first, which is also the unit of the answer.
    private static func extreme(
        of arguments: [CalcValue], takingSmallest: Bool
    ) throws(CalcError) -> CalcValue {
        guard let first = arguments.first else { throw .syntax }

        var chosen = first.number
        for argument in arguments.dropFirst() {
            let candidate = try number(of: argument, inUnitOf: first)
            let isBetter = takingSmallest ? candidate < chosen : candidate > chosen
            if isBetter {
                chosen = candidate
            }
        }
        return CalcValue(number: chosen, unit: first.unit)
    }

    private static func onlyArgument(of arguments: [CalcValue]) throws(CalcError) -> CalcValue {
        guard arguments.count == 1, let argument = arguments.first else { throw .syntax }
        return argument
    }

    // MARK: Units

    /// The number of a value that must not have a unit.
    private static func plainNumber(_ value: CalcValue) throws(CalcError) -> Decimal {
        if value.unit != nil { throw .incompatibleUnits }
        return value.number
    }

    /// The number of `value` in the unit of `reference`, so that the two can be added or
    /// compared. Two plain numbers go together as they are; a plain number and a measurement
    /// do not go together at all.
    private static func number(
        of value: CalcValue, inUnitOf reference: CalcValue
    ) throws(CalcError) -> Decimal {
        switch (value.unit, reference.unit) {
        case (nil, nil):
            return value.number
        case (let unit?, let referenceUnit?):
            return try CalcUnits.convert(value.number, from: unit, to: referenceUnit)
        default:
            throw .incompatibleUnits
        }
    }
}
