import Foundation
import Testing

@testable import OpenRayCore

@Suite(.timeLimit(.minutes(1))) struct CalculatorMathTests {
    // MARK: What `Decimal` does on its own

    @Test func decimalGivesNaNAndDoesNotTrapWhereItHasNoAnswer() {
        let largest = Decimal.greatestFiniteMagnitude
        let zero = Decimal(0)

        #expect((largest * 10).isNaN)
        #expect((largest + largest).isNaN)
        #expect((Decimal(1) / zero).isNaN)
        #expect((zero / zero).isNaN)
        // And NaN stays NaN, so one check at the end of an operation is enough.
        #expect((Decimal.nan + 1).isNaN)
        #expect((Decimal.nan * 0).isNaN)
    }

    // MARK: The four operations

    @Test func overflowIsAnError() throws {
        let largest = Decimal.greatestFiniteMagnitude

        #expect(throws: CalcError.outOfRange) { try CalcMath.add(largest, largest) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.subtract(-largest, largest) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.multiply(largest, 10) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.divide(largest, by: decimal("0.1")) }
    }

    @Test func productTooSmallForADecimalIsAnError() throws {
        // Without the check these come back as 1e127 and 1.5e128: the exponent wraps.
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.multiply(decimal("1e-65"), decimal("1e-64"))
        }
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.multiply(decimal("1.5e-127"), decimal("0.1"))
        }
        // A large factor does not help when the other has many digits.
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.multiply(
                decimal("721039500.635063336853563592609940447"), decimal("2.9830997258858068e-101")
            )
        }
    }

    @Test func smallProductThatFitsIsNotAnError() throws {
        #expect(try CalcMath.multiply(decimal("1e-64"), decimal("1e-64")) == decimal("1e-128"))
        #expect(try CalcMath.multiply(decimal("1e-100"), decimal("1e100")) == 1)
        #expect(try CalcMath.multiply(0, decimal("1e-128")) == 0)
        #expect(try CalcMath.multiply(decimal("0.000"), decimal("1e-128")) == 0)
    }

    @Test(arguments: [
        ("6", "3", "2"),
        ("1", "4", "0.25"),
        ("-1", "8", "-0.125"),
        ("0", "7", "0"),
        ("0.3", "0.1", "3"),
        ("1e-100", "1e-100", "1"),
    ])
    func quotientThatHasAnEndIsExact(
        _ dividend: String, _ divisor: String, _ quotient: String
    ) throws {
        #expect(try CalcMath.divide(decimal(dividend), by: decimal(divisor)) == decimal(quotient))
    }

    @Test(arguments: [
        // Foundation's own quotients for these have 5 and 20 digits.
        ("0.0000023782", "8828599284.3402126418197230299554802312"),
        ("1", "94766.172937345988"),
        // And this one it gets wrong by a factor of two.
        ("343421194941093303.89", "0.000000000000000198534634496"),
        ("1", "3"),
        ("22", "7"),
    ])
    func quotientIsRightToThirtyDigits(_ dividendDigits: String, _ divisorDigits: String) throws {
        let dividend = try decimal(dividendDigits)
        let divisor = try decimal(divisorDigits)

        let quotient = try CalcMath.divide(dividend, by: divisor)

        let leftOver = (dividend - quotient * divisor).magnitude
        let allowed = dividend.magnitude * (try decimal("1e-30"))
        #expect(leftOver <= allowed)
    }

    @Test func divisionByZeroIsAnError() {
        #expect(throws: CalcError.divisionByZero) { try CalcMath.divide(1, by: 0) }
        #expect(throws: CalcError.divisionByZero) { try CalcMath.divide(0, by: 0) }
        #expect(throws: CalcError.divisionByZero) { try CalcMath.remainder(1, dividingBy: 0) }
    }

    @Test(arguments: [
        ("7", "3", "1"),
        ("-7", "3", "-1"),
        ("7", "-3", "1"),
        ("-7", "-3", "-1"),
        ("5.5", "2", "1.5"),
        ("6", "3", "0"),
        ("2", "5", "2"),
        ("1e17", "7", "5"),
    ])
    func remainderHasTheSignOfTheDividend(
        _ dividend: String, _ divisor: String, _ remainder: String
    ) throws {
        let result = try CalcMath.remainder(decimal(dividend), dividingBy: decimal(divisor))

        #expect(try result == decimal(remainder))
    }

    @Test func remainderIsWorkedOutUpToAWholeQuotientOfEighteenDigits() throws {
        let eighteenNines = try decimal("999999999999999999")

        // The whole quotients are 499999999999999999 and 333333333333333333.
        #expect(try CalcMath.remainder(eighteenNines, dividingBy: 2) == 1)
        #expect(try CalcMath.remainder(decimal("1e18"), dividingBy: 3) == 1)
    }

    @Test func remainderIsRefusedWhereTheWholeQuotientHasMoreDigits() throws {
        // Each of these used to come out wrong: 800, 0 and 5.755.
        let twoToThe130th = try CalcMath.power(2, 130)
        let sevenToThe46th = try CalcMath.power(7, 46)

        #expect(throws: CalcError.outOfRange) {
            try CalcMath.remainder(twoToThe130th, dividingBy: 1000)
        }
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.remainder(sevenToThe46th, dividingBy: 10)
        }
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.remainder(decimal("1e35"), dividingBy: decimal("1.2345"))
        }
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.remainder(decimal("1e19"), dividingBy: 3)
        }
    }

    // MARK: Powers and factorials

    @Test func wholePowersAreExact() throws {
        #expect(try CalcMath.power(2, 10) == 1024)
        #expect(try CalcMath.power(decimal("0.1"), 3) == decimal("0.001"))
        #expect(try CalcMath.power(-2, 3) == -8)
        #expect(try CalcMath.power(7, 0) == 1)
        #expect(try CalcMath.power(2, -2) == decimal("0.25"))
        #expect(try CalcMath.power(3, 70) == decimal("2503155504993241601315571986085849"))
    }

    @Test func powerNeedsNoSquareBeyondItsAnswer() throws {
        // The next square after 10^64 is 10^128, which a `Decimal` does not hold.
        #expect(try CalcMath.power(10, 100) == decimal("1e100"))
        #expect(try CalcMath.power(10, 127) == decimal("1e127"))
    }

    @Test func powerWithAHugeExponentGivesUpAtOnce() throws {
        let clock = ContinuousClock()
        let start = clock.now

        #expect(throws: CalcError.outOfRange) { try CalcMath.power(2, 1_000_000) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.power(9, 387_420_489) }
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.power(decimal("1.0000001"), 999_999_999)
        }
        #expect(throws: CalcError.outOfRange) { try CalcMath.power(decimal("0.5"), 1_000_000) }
        // One stays one, so this is the power that goes through every squaring.
        #expect(try CalcMath.power(1, 1_000_000) == 1)

        #expect(clock.now - start < .seconds(1))
    }

    @Test func wholeExponentTooLargeForAnIntIsOutOfRangeLikeAnyOtherThatIsTooLarge() throws {
        // In `Double` these are 1 and infinity: 10^30 + 1 is even there.
        let odd = try decimal("1000000000000000000000000000001")

        #expect(throws: CalcError.outOfRange) { try CalcMath.power(-1, odd) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.power(2, decimal("1e30")) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.power(1, decimal("-1e30")) }
    }

    @Test func powerWithAFractionGoesThroughDouble() throws {
        #expect(try CalcMath.power(4, decimal("0.5")) == 2)
        #expect(try CalcMath.power(decimal("2.25"), decimal("0.5")) == decimal("1.5"))
        #expect(try CalcMath.power(0, decimal("0.5")) == 0)
        #expect(throws: CalcError.undefined) { try CalcMath.power(-8, decimal("0.5")) }
    }

    @Test func powerTooSmallForADoubleOrADecimalIsNotZero() throws {
        // `Double` makes 0 of the first and 1e-301 of the second.
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.power(CalcMath.e, decimal("-1000.5"))
        }
        #expect(throws: CalcError.outOfRange) {
            try CalcMath.power(decimal("0.5"), decimal("1000.5"))
        }
    }

    @Test func factorialsAreOfWholeNumbersFromZeroTo103() throws {
        #expect(try CalcMath.factorial(0) == 1)
        #expect(try CalcMath.factorial(10) == 3_628_800)
        #expect(try !CalcMath.factorial(103).isNaN)
        #expect(throws: CalcError.outOfRange) { try CalcMath.factorial(104) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.factorial(decimal("1e50")) }
        #expect(throws: CalcError.undefined) { try CalcMath.factorial(-1) }
        #expect(throws: CalcError.undefined) { try CalcMath.factorial(decimal("2.5")) }
    }

    // MARK: Rounding noise

    @Test func noiseInTheLastDigitsOfADecimalIsRoundedOff() throws {
        let almostOne = Decimal(1) / 3 * 3
        let twoThirds = Decimal(2) / 3

        #expect(almostOne != 1)
        #expect(try CalcMath.withoutRoundingNoise(almostOne) == 1)
        #expect(try CalcMath.withoutRoundingNoise(-almostOne) == -1)
        // To 30 digits, halves away from zero.
        #expect(
            try CalcMath.withoutRoundingNoise(twoThirds)
                == decimal("0.666666666666666666666666666667"))
        #expect(
            try CalcMath.withoutRoundingNoise(decimal("1234567890123456789012345678905"))
                == decimal("1234567890123456789012345678910"))
    }

    @Test(arguments: ["0", "0.1", "-42.5", "1e-100", "123456789012345678901234567890"])
    func numberOfUpToThirtyDigitsHasNoNoiseToRoundOff(_ digits: String) throws {
        let number = try decimal(digits)

        #expect(try CalcMath.withoutRoundingNoise(number) == number)
    }

    // MARK: Other numbers

    @Test func doubleComesBackAsTheNumberItPrints() throws {
        #expect(try CalcMath.decimal(from: 0.1) == decimal("0.1"))
        #expect(try CalcMath.decimal(from: 1e-7) == decimal("0.0000001"))
        #expect(try CalcMath.decimal(from: 1e16) == decimal("10000000000000000"))
        #expect(try CalcMath.decimal(from: -0.0) == 0)
        #expect(throws: CalcError.undefined) { try CalcMath.decimal(from: .nan) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.decimal(from: .infinity) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.decimal(from: 1e300) }
        #expect(throws: CalcError.outOfRange) { try CalcMath.decimal(from: 1e-300) }
    }

    @Test func decimalBecomesTheNearestDouble() throws {
        #expect(try CalcMath.double(from: decimal("0.1")) == 0.1)
        #expect(try CalcMath.double(from: decimal("0.0000001")) == 1e-7)
        #expect(try CalcMath.double(from: Decimal.pi) == Double.pi)
        #expect(try CalcMath.double(from: decimal("-1e100")) == -1e100)
    }

    @Test func intIsOnlyForWholeNumbersThatFit() throws {
        #expect(CalcMath.int(from: 42) == 42)
        #expect(CalcMath.int(from: -42) == -42)
        #expect(try CalcMath.int(from: decimal("42.0")) == 42)
        #expect(try CalcMath.int(from: decimal("42.5")) == nil)
        #expect(try CalcMath.int(from: decimal("1e30")) == nil)
        #expect(CalcMath.int(from: .nan) == nil)
    }

    @Test func eulersNumberHasAllItsDigits() throws {
        #expect(CalcMath.e == (try decimal("2.7182818284590452353602874713526624978")))
    }
}
