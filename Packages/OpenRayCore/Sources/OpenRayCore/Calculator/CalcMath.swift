import Foundation

/// The calculator's arithmetic: `Decimal` operations that end in a `CalcError` where `Decimal`
/// itself would hand back something wrong.
///
/// `Decimal` never traps, and that is all it promises. An overflow or a division by zero gives
/// NaN. A product too small for it comes back with its exponent wrapped around, as a huge
/// number. A quotient can be short of digits. Every operation of the evaluator goes through
/// here, so that none of these reaches the user as an answer.
enum CalcMath {
    /// Euler's number to the 38 digits a `Decimal` holds, as `Decimal.pi` is.
    static let e: Decimal = {
        let digits = "2.7182818284590452353602874713526624978"
        // The text is a number, so the fallback is never used.
        return Decimal(string: digits, locale: plainNumberLocale) ?? Decimal(M_E)
    }()

    /// 104! is the first factorial that does not fit a `Decimal`.
    static let maximumFactorial = 103

    /// The largest whole exponent. Nothing a launcher is asked comes near it.
    static let maximumWholeExponent: UInt = 1_000_000

    /// Reads "1234.5" whatever the user's locale is.
    private static let plainNumberLocale = Locale(identifier: "en_US_POSIX")

    // MARK: The four operations

    static func add(_ left: Decimal, _ right: Decimal) throws(CalcError) -> Decimal {
        try finite(left + right)
    }

    static func subtract(_ left: Decimal, _ right: Decimal) throws(CalcError) -> Decimal {
        try finite(left - right)
    }

    static func multiply(_ left: Decimal, _ right: Decimal) throws(CalcError) -> Decimal {
        // Zero first: the exponent of a zero says nothing, and the check below reads exponents.
        if left == 0 || right == 0 { return 0 }

        let product = try finite(left * right)
        // A `Decimal` keeps its exponent in eight bits, and a product too small for that does
        // not become NaN: the exponent wraps around, and 1e-65 × 1e-64 comes out as 1e127.
        // The exponent of a true product is the sum of the factors' exponents, plus the few
        // dozen digits that rounding and trailing zeros can take off. One that wrapped is 256
        // above its true place. Half of that tells the two apart with room on either side.
        let expectedExponent = left.exponent + right.exponent
        let halfAWrap = 128
        if product.exponent - expectedExponent > halfAWrap { throw .outOfRange }
        return product
    }

    static func divide(_ dividend: Decimal, by divisor: Decimal) throws(CalcError) -> Decimal {
        if divisor == 0 { throw .divisionByZero }

        var quotient = try finite(dividend / divisor)
        if try isQuotient(quotient, of: dividend, by: divisor) { return quotient }

        // Foundation lines the two operands up as it would for an addition before it divides,
        // and a divisor with many digits can lose most of them on the way: 0.0000023782
        // divided by a 38-digit number near 8.8e9 comes back with five digits. The missing
        // ones are found from what the quotient leaves over, with a reciprocal from `Double`
        // that is right to 16 digits, so every round makes the error 1e16 times smaller.
        let reciprocal = try decimal(from: 1 / (try double(from: divisor)))
        for _ in 0..<3 {
            let leftOver = try subtract(dividend, try multiply(quotient, divisor))
            quotient = try add(quotient, try multiply(leftOver, reciprocal))
            if try isQuotient(quotient, of: dividend, by: divisor) { return quotient }
        }
        // Only a quotient that Foundation got wildly wrong is still off after three rounds,
        // which it does at the very edge of what a `Decimal` holds.
        throw .outOfRange
    }

    /// How far a quotient times its divisor may be from the dividend, as a share of the
    /// dividend. The launcher shows 12 digits.
    private static let quotientTolerance = Decimal(sign: .plus, exponent: -30, significand: 1)

    private static func isQuotient(
        _ quotient: Decimal, of dividend: Decimal, by divisor: Decimal
    ) throws(CalcError) -> Bool {
        let leftOver = try subtract(dividend, try multiply(quotient, divisor))
        if leftOver == 0 { return true }
        let allowed = try multiply(dividend.magnitude, quotientTolerance)
        return leftOver.magnitude <= allowed
    }

    /// The remainder with the sign of the dividend, as Swift's `%` has it: -7 mod 3 is -1.
    static func remainder(
        _ dividend: Decimal, dividingBy divisor: Decimal
    ) throws(CalcError) -> Decimal {
        // Without the noise in its last digits, because one digit decides which whole number
        // the quotient is cut down to: 6 divided by two thirds is 8.999…9 in a `Decimal`.
        let quotient = try withoutRoundingNoise(try divide(dividend, by: divisor))
        let towardZero: NSDecimalNumber.RoundingMode = quotient < 0 ? .up : .down
        let wholeQuotient = rounded(quotient, towardZero)

        // The whole quotient times the divisor is rounded to the 38 digits of a `Decimal`, and
        // the remainder is what is left of the dividend after it. With a whole quotient of 18
        // digits the remainder is still right to about 20. With more, the digits that make it
        // up are rounded away: 2^130 mod 1000 came out as 800.
        let firstWithTooManyDigits = Decimal(sign: .plus, exponent: 18, significand: 1)
        if wholeQuotient.magnitude >= firstWithTooManyDigits { throw .outOfRange }

        let remainder = try subtract(dividend, try multiply(wholeQuotient, divisor))
        // A remainder is smaller than the divisor and has the sign of the dividend. One that
        // is not has lost its digits all the same, and no answer is better than that one.
        let hasTheSignOfTheDividend = remainder == 0 || (remainder < 0) == (dividend < 0)
        let isSmallerThanTheDivisor = remainder.magnitude < divisor.magnitude
        if !hasTheSignOfTheDividend || !isSmallerThanTheDivisor { throw .outOfRange }
        return remainder
    }

    private static func finite(_ value: Decimal) throws(CalcError) -> Decimal {
        if value.isNaN { throw .outOfRange }
        return value
    }

    // MARK: Powers and factorials

    static func power(_ base: Decimal, _ exponent: Decimal) throws(CalcError) -> Decimal {
        if isWhole(exponent) {
            // Too large is too large whether or not it fits an `Int`. In `Double`, where an
            // exponent with a fraction goes, (-1)^(10^30 + 1) would come out as 1.
            guard let wholeExponent = int(from: exponent),
                wholeExponent.magnitude <= maximumWholeExponent
            else { throw .outOfRange }

            let positivePower = try power(base, toWhole: wholeExponent.magnitude)
            if wholeExponent < 0 {
                return try divide(1, by: positivePower)
            }
            return positivePower
        }

        // An exponent with a fraction has no exact answer.
        let result = pow(try double(from: base), try double(from: exponent))
        // `Double` rounds a power that is too small for it to zero: e^-1000.5. Only a base of
        // zero has a power that is zero.
        if result == 0 && base != 0 { throw .outOfRange }
        return try decimal(from: result)
    }

    /// By repeated squaring: the multiplications grow with the number of bits of the exponent
    /// and not with the exponent, so 2^1000000 overflows after ten of them.
    private static func power(
        _ base: Decimal, toWhole exponent: UInt
    ) throws(CalcError) -> Decimal {
        var result: Decimal = 1
        var square = base
        var remainingBits = exponent
        while remainingBits > 0 {
            if remainingBits % 2 == 1 {
                result = try multiply(result, square)
            }
            remainingBits /= 2
            // Not after the last bit: that square is not used, and it may be the one that
            // overflows.
            if remainingBits > 0 {
                square = try multiply(square, square)
            }
        }
        return result
    }

    static func factorial(_ value: Decimal) throws(CalcError) -> Decimal {
        if !isWhole(value) || value < 0 { throw .undefined }
        // A whole number that does not even fit an `Int` is too large here as well.
        guard let count = int(from: value), count <= maximumFactorial else { throw .outOfRange }

        var product: Decimal = 1
        var factor = 2
        while factor <= count {
            product = try multiply(product, Decimal(factor))
            factor += 1
        }
        return product
    }

    // MARK: Rounding

    /// - Parameter mode: `.plain` rounds halves away from zero, `.down` is the floor and `.up`
    ///   the ceiling.
    static func rounded(_ value: Decimal, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var unrounded = value
        var result = Decimal()
        NSDecimalRound(&result, &unrounded, 0, mode)
        return result
    }

    static func isWhole(_ value: Decimal) -> Bool {
        rounded(value, .down) == value
    }

    /// How many digits of a value are taken at their word. A `Decimal` has 38.
    private static let trustedDigits = 30

    /// The value without the last digits of a `Decimal`, which are where rounding shows:
    /// 1/3 × 3 is 0.999…9 with 38 nines, and its floor would be 0. Rounded to 30 digits, halves
    /// away from zero, it is the 1 that was meant.
    ///
    /// Only for where one digit decides the answer: `floor`, `ceil`, `round` and `mod`.
    static func withoutRoundingNoise(_ value: Decimal) throws(CalcError) -> Decimal {
        // The significand is the digits as a whole number, and the exponent says where the
        // last of them stands.
        let digitCount = value.significand.description.count
        if digitCount <= trustedDigits { return value }

        let placeOfFirstDigit = value.exponent + digitCount - 1
        let decimalPlaces = trustedDigits - 1 - placeOfFirstDigit
        var unrounded = value
        var result = Decimal()
        NSDecimalRound(&result, &unrounded, decimalPlaces, .plain)
        return try finite(result)
    }

    // MARK: To and from other numbers

    /// The value as an `Int`: nil when it has a fraction, or does not fit.
    static func int(from value: Decimal) -> Int? {
        // The description of a `Decimal` is its digits, never with an exponent, and reading
        // them back checks for both at once.
        Int(value.description)
    }

    static func double(from value: Decimal) throws(CalcError) -> Double {
        // Through the digits. `NSDecimalNumber.doubleValue` is off in the last place: 1e-7
        // comes out as 1.0000000000000002e-07.
        guard let double = Double(value.description) else { throw .outOfRange }
        return double
    }

    static func decimal(from value: Double) throws(CalcError) -> Decimal {
        if value.isNaN { throw .undefined }
        if value.isInfinite { throw .outOfRange }
        // The description is the shortest text that reads back as the same `Double`: 0.1 for
        // 0.1, where `Decimal(0.1)` would carry the binary noise behind it.
        guard let decimal = Decimal(string: value.description, locale: plainNumberLocale),
            !decimal.isNaN
        else { throw .outOfRange }
        return decimal
    }

    /// The digits of a number literal as a value.
    ///
    /// - Parameter plainText: ASCII digits with at most one "." among them.
    static func decimal(fromPlainText plainText: String) throws(CalcError) -> Decimal {
        guard let decimal = Decimal(string: plainText, locale: plainNumberLocale), !decimal.isNaN
        else { throw .outOfRange }
        return decimal
    }
}
