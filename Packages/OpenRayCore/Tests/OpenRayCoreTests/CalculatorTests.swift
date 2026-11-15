import Foundation
import Testing

@testable import OpenRayCore

/// The number an input works out to.
private func answer(_ input: String, in locale: Locale = enUS) throws -> Decimal {
    try Calculator.evaluate(input, locale: locale).value.number
}

/// The answer the way the launcher shows it in American English, to 12 digits. For answers
/// that come out of `Double` and are not exact.
private func shownAnswer(_ input: String) throws -> String {
    let result = try Calculator.evaluate(input, locale: enUS)
    return CalcFormatter.displayText(
        for: result.value, isApproximate: result.isApproximate, locale: enUS)
}

@Suite struct CalculatorArithmeticTests {
    // MARK: Operators

    @Test(arguments: [("1 + 2", "3"), ("7 - 10", "-3"), ("6 * 7", "42"), ("1 / 4", "0.25")])
    func plusMinusTimesAndDividedBy(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("2+2", "4"), (" 2\t+ 2 ", "4")])
    func spaceBetweenNumbersAndOperatorsDoesNotMatter(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("0.1 + 0.2", "0.3"), ("1.1 * 1.1", "1.21")])
    func decimalFractionsAreWorkedOutExactly(_ input: String, _ expected: String) throws {
        // In `Double`, 0.1 + 0.2 is 0.30000000000000004.
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("2 + 3 * 4", "14"), ("2 + 7 mod 3", "3")])
    func timesDividedByAndModBindTighterThanPlusAndMinus(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("(2 + 3) * 4", "20"), ("2 * (3 + 4) * 5", "70")])
    func parenthesesAreWorkedOutFirst(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("10 - 4 - 3", "3"), ("100 / 10 / 5", "2")])
    func operatorsOfOneLevelAreWorkedOutFromTheLeft(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        ("2 * -3", "-6"),
        ("2 - -3", "5"),
        ("--5 + 1", "6"),
        ("+5 - 2", "3"),
        ("-(2 + 3)", "-5"),
    ])
    func signCanStandInFrontOfAnyOperand(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("2 × 3 ÷ 4", "1.5"), ("2 · 3", "6"), ("7 − 2", "5")])
    func typographicOperatorsAreReadLikeTheAsciiOnes(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        ("7 mod 3", "1"),
        ("-7 mod 3", "-1"),
        ("7 mod -3", "1"),
        ("5.5 mod 2", "1.5"),
        ("0.3 mod 0.1", "0"),
    ])
    func remainderHasTheSignOfTheDividend(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test func remainderIgnoresTheNoiseInTheLastDigitsOfItsOperands() throws {
        // 1/3 × 3 is 0.999…9 in a `Decimal`, and its remainder by 1 would be all of it.
        #expect(try answer("(1 / 3 * 3) mod 1") == 0)
        #expect(try answer("7 mod (1 / 3 * 3)") == 0)
    }

    @Test func remainderByANumberWithoutAnEndIsRefusedWhereItWouldComeOutAsTheDivisor() {
        // Two thirds go into 6 nine times and leave nothing. In a `Decimal` they are a little
        // more than two thirds, and what is left is not a remainder. It used to be shown as
        // 0.666666666667.
        #expect(throws: CalcError.outOfRange) { try answer("6 mod (2 / 3)") }
    }

    @Test(arguments: ["2^130 mod 1000", "7^46 mod 10", "10^35 mod 1.2345", "10^40 mod 3"])
    func remainderOfANumberTooLargeToHaveOneIsOutOfRange(_ input: String) {
        // The digits a remainder is made of are rounded away in numbers of this size. The
        // first three used to give 800, 0 and 5.755.
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    @Test(arguments: [("7 MOD 3", "1"), ("15% OF 200", "30"), ("SQRT(4)", "2"), ("Max(1, 2)", "2")])
    func keywordsAndFunctionNamesAreReadWithoutRegardToCase(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input) == decimal(expected))
    }

    // MARK: Percent

    @Test(arguments: [("50%", "0.5"), ("200 * 15%", "30"), ("(1 + 2)%", "0.03")])
    func percentIsAHundredth(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        ("200 + 15%", "230"),
        ("200 - 15%", "170"),
        ("100 + 10% + 5%", "115.5"),
        // Parentheses around the percent change nothing.
        ("100 + (5%)", "105"),
    ])
    func percentAddedOrSubtractedIsThatShareOfTheLeftSide(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("100 + -10%", "90"), ("100 - -10%", "110"), ("100 + (5% + 5%)", "110")])
    func signedPercentageOrSumOfPercentagesIsAShareOfTheLeftSideToo(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        ("5% + 10%", "0.15"),
        ("5% + 10% + 10%", "0.25"),
        ("5% - 10%", "-0.05"),
        ("-5% + 10%", "0.05"),
        ("(5% + 10%) + 10%", "0.25"),
    ])
    func percentagesAddUpAsPlainNumbersHoweverLongTheChain(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("100 + 5% * 2", "100.1"), ("50 + 200 * 15%", "80")])
    func productWithAPercentInItIsAPlainNumber(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("15% of 200", "30"), ("2 * 15% of 200", "60")])
    func ofBehindAPercentMultiplies(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    // MARK: Powers

    @Test(arguments: [
        ("2^10", "1024"),
        ("1.5^2", "2.25"),
        ("10^0", "1"),
        ("0^0", "1"),
        ("2^64", "18446744073709551616"),
        ("2^100", "1267650600228229401496703205376"),
    ])
    func wholePowersAreExact(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("2^-3", "0.125"), ("10^-2", "0.01")])
    func negativeExponentGivesTheReciprocal(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("-2^2", "-4"), ("(-2)^2", "4"), ("-2^-2", "-0.25")])
    func signInFrontOfAPowerAppliesToTheWholePower(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("2^3^2", "512"), ("(2^3)^2", "64"), ("2^-1^2", "0.5")])
    func powersAreWorkedOutFromTheRight(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("2 * 3^2", "18"), ("2^3!", "64")])
    func powerBindsTighterThanTimesAndLooserThanAFactorial(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test func exponentCanHaveAFraction() throws {
        #expect(try answer("4^0.5") == 2)
    }

    @Test(arguments: ["(-1)^(10^30 + 1)", "2^(10^30)", "1^(10^30)"])
    func wholeExponentIsOutOfRangeHoweverFarBeyondTheLimitItIs(_ input: String) {
        // Not through `Double` because it no longer fits an `Int`: there the first is 1.
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    @Test(arguments: ["e^-1000.5", "0.5^1000.5"])
    func powerTooSmallToHoldIsOutOfRangeAndNotZero(_ input: String) {
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    // MARK: Factorials

    @Test(arguments: [("0!", "1"), ("1!", "1"), ("5!", "120"), ("20!", "2432902008176640000")])
    func factorialOfAWholeNumber(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("3! + 1", "7"), ("(2 + 1)!", "6"), ("-3!", "-6")])
    func factorialBindsTighterThanSignsAndSums(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test func largestFactorialIsThatOf103() throws {
        #expect(try answer("103!") == 103 * answer("102!"))
        #expect(throws: CalcError.outOfRange) { try answer("104!") }
    }

    // MARK: Functions

    @Test(arguments: [
        ("sqrt(16)", "4"),
        ("sqrt(2.25)", "1.5"),
        ("cbrt(-8)", "-2"),
        ("abs(-3.5)", "3.5"),
        ("abs(3.5)", "3.5"),
    ])
    func rootsAndAbsoluteValues(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        ("round(2.4)", "2"),
        ("round(2.5)", "3"),
        ("round(-2.5)", "-3"),
        ("floor(2.7)", "2"),
        ("floor(-2.5)", "-3"),
        ("ceil(2.1)", "3"),
        ("ceil(-2.5)", "-2"),
    ])
    func roundGoesHalfAwayFromZeroFloorDownAndCeilUp(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        // 1/3 × 3 is 0.999…9 with 38 nines, which nobody means by it.
        ("floor(1 / 3 * 3)", "1"),
        ("ceil(-1 / 3 * 3)", "-1"),
        ("ceil(1 / 3 * 3)", "1"),
        ("round(0.5 / 3 * 3)", "1"),
        ("floor(2 / 3 * 3 km)", "2"),
    ])
    func roundingFunctionsIgnoreTheNoiseInTheLastDigits(_ input: String, _ expected: String) throws
    {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: ["ln(1)", "log(1)", "log2(1)"])
    func logarithmOfOneIsExactlyZero(_ input: String) throws {
        #expect(try answer(input) == 0)
    }

    @Test(arguments: [
        ("sin(0)", "0"),
        ("cos(0)", "1"),
        ("tan(0)", "0"),
        ("asin(0)", "0"),
        ("acos(1)", "0"),
        ("atan(0)", "0"),
    ])
    func trigonometryIsExactWhereDoubleIs(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: ["sin(pi)", "cos(pi / 2)", "tan(pi)", "sin(2 * pi)", "sin(100 * pi)"])
    func trigonometryOfAMultipleOfPiIsExactlyZero(_ input: String) throws {
        // In `Double`, sin(pi) is 1.2e-16.
        #expect(try answer(input) == 0)
    }

    @Test func sineOfATinyAngleIsTheAngleAndNotZero() throws {
        // Small, but not small against its angle, which is what the zeroing goes by.
        #expect(try answer("sin(0.0000000000000005)") == decimal("0.0000000000000005"))
        #expect(try answer("tan(0.00000000000000000001)") == decimal("0.00000000000000000001"))
    }

    @Test(arguments: ["sin(10^30)", "cos(10^15)", "tan(-10^15)"])
    func trigonometryOfAnAngleTooLargeForADoubleToPlaceIsOutOfRange(_ input: String) {
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    @Test func trigonometryOfALargeAngleThatADoubleStillPlacesHasAnAnswer() throws {
        let sine = try answer("sin(10^14)")

        #expect(sine != 0)
        #expect(sine.magnitude <= 1)
    }

    @Test(arguments: [
        ("min(3, 1, 2)", "1"),
        ("max(3, 1, 2)", "3"),
        ("min(5)", "5"),
        ("max(-1, -2)", "-1"),
    ])
    func minAndMaxTakeOneOrMoreArguments(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [("sqrt(abs(-16))", "4"), ("sqrt(2 + 2) * 3", "6")])
    func functionsTakeExpressionsAndStandInExpressions(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: [
        ("sqrt(2)", "1.41421356237"),
        ("cbrt(27)", "3"),
        ("ln(e)", "1"),
        ("ln(10)", "2.30258509299"),
        ("log(1000)", "3"),
        ("log(2)", "0.301029995664"),
        ("log2(8)", "3"),
        ("log2(10)", "3.32192809489"),
    ])
    func rootsAndLogarithmsAreRightToTheDigitsShown(_ input: String, _ shown: String) throws {
        #expect(try shownAnswer(input) == shown)
    }

    @Test(arguments: [
        ("sin(1)", "0.841470984808"),
        ("cos(1)", "0.540302305868"),
        ("tan(1)", "1.55740772465"),
        ("sin(pi / 2)", "1"),
        ("tan(pi / 4)", "1"),
        ("asin(1)", "1.57079632679"),
        ("acos(0)", "1.57079632679"),
        ("atan(1) * 4", "3.14159265359"),
    ])
    func trigonometryIsInRadiansAndRightToTheDigitsShown(_ input: String, _ shown: String) throws {
        #expect(try shownAnswer(input) == shown)
    }

    @Test(arguments: [("2^0.5", "1.41421356237"), ("e^2", "7.38905609893")])
    func powersThroughDoubleAreRightToTheDigitsShown(_ input: String, _ shown: String) throws {
        #expect(try shownAnswer(input) == shown)
    }

    @Test(arguments: [("10 / 3", "3.33333333333"), ("1 / 3 * 3", "1")])
    func quotientWithoutAnEndIsShownToTwelveDigits(_ input: String, _ shown: String) throws {
        #expect(try shownAnswer(input) == shown)
    }

    // MARK: Exact and approximate answers

    @Test(arguments: ["sqrt(16)", "ln(2)", "sin(1)", "2^0.5", "1 + sqrt(2) * 3", "max(1, cbrt(8))"])
    func answerThatCameThroughDoubleIsApproximate(_ input: String) throws {
        #expect(try Calculator.evaluate(input, locale: enUS).isApproximate)
    }

    @Test(arguments: [
        "2^10", "2^-3", "1 / 3", "0.1 + 0.2", "20!", "7 mod 3", "abs(-2)", "5 km to mi",
    ])
    func answerWorkedOutInDecimalIsExact(_ input: String) throws {
        #expect(try !Calculator.evaluate(input, locale: enUS).isApproximate)
    }

    @Test func approximateAnswerIsNotShownWithMoreDigitsThanItHas() throws {
        // `Double` has 316227766016837940000 for the root, and only the first 16 digits of
        // that are digits of the root.
        #expect(try shownAnswer("sqrt(10^41)") == "316,227,766,017,000,000,000")
        #expect(try shownAnswer("10^20 + 1") == "100,000,000,000,000,000,001")
    }

    // MARK: Constants

    @Test func piAndEAreConstants() throws {
        #expect(try answer("pi") == Decimal.pi)
        #expect(try answer("π") == Decimal.pi)
        #expect(try shownAnswer("e") == "2.71828182846")
        #expect(try answer("2 * pi") == 2 * Decimal.pi)
    }

    @Test func constantsAreReadWithoutRegardToCase() throws {
        #expect(try answer("PI") == Decimal.pi)
        #expect(try answer("E") == answer("e"))
    }

    // MARK: What counts as a calculation

    @Test(arguments: ["1 + 1", "5!", "50%", "sqrt(4)", "2^2", "-(1 + 1)", "5 km to m", "7 mod 2"])
    func inputWithAnOperatorAFunctionOrAConversionIsACalculation(_ input: String) throws {
        #expect(try Calculator.evaluate(input, locale: enUS).isCalculation)
    }

    @Test(arguments: ["42", "-42", "+42", "(42)", "((-42))", "1,234.5", "pi", "-e", "10 km"])
    func numberOnItsOwnIsNotACalculation(_ input: String) throws {
        #expect(try !Calculator.evaluate(input, locale: enUS).isCalculation)
    }
}

@Suite struct CalculatorLocaleTests {
    // MARK: Grouping and decimal separators

    @Test(arguments: [
        ("1,234 + 1", "1235"),
        ("1,234,567.5 * 2", "2469135"),
        ("12,345.25 + 0", "12345.25"),
        ("123,456 + 0", "123456"),
    ])
    func englishGroupsWithCommasAndWritesDecimalsWithAPoint(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input, in: enUS) == decimal(expected))
    }

    @Test(arguments: [
        ("1,5 + 1", "2.5"),
        ("1.234,5 * 2", "2469"),
        ("1.234.567 + 1", "1234568"),
    ])
    func germanGroupsWithPointsAndWritesDecimalsWithAComma(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input, in: deDE) == decimal(expected))
    }

    @Test func swissFrench() throws {
        // Read from the locale: its separators have changed between versions of the system.
        let decimalSeparator = try #require(frCH.decimalSeparator)
        let groupingSeparator = try #require(frCH.groupingSeparator)
        let grouped = "1\(groupingSeparator)234\(groupingSeparator)567\(decimalSeparator)5"

        #expect(try answer("\(grouped) * 2", in: frCH) == 2_469_135)
        #expect(
            try answer("0\(decimalSeparator)1 + 0\(decimalSeparator)2", in: frCH) == decimal("0.3"))
        #expect(try answer("max(1\(decimalSeparator)5; 2)", in: frCH) == 2)
        #expect(try answer("max(\(grouped); 2)", in: frCH) == decimal("1234567.5"))
    }

    @Test func eitherApostropheGroupsWhereTheLocaleGroupsWithOne() throws {
        let apostrophes = ["'", "\u{2019}"]
        let groupingSeparator = try #require(frCH.groupingSeparator)
        // Should Swiss French ever group with something else, this rule has nothing to say.
        guard apostrophes.contains(groupingSeparator) else { return }

        for apostrophe in apostrophes {
            #expect(try answer("1\(apostrophe)234 + 1", in: frCH) == 1235)
        }
    }

    @Test func anySpaceGroupsWhereTheLocaleGroupsWithOne() throws {
        let french = Locale(identifier: "fr_FR")
        let spaces = ["\u{A0}", "\u{202F}", "\u{2009}", " "]
        let groupingSeparator = try #require(french.groupingSeparator)
        let decimalSeparator = try #require(french.decimalSeparator)
        guard spaces.contains(groupingSeparator) else { return }

        for space in spaces {
            let input = "1\(space)234\(space)567\(decimalSeparator)5 + 1"
            #expect(try answer(input, in: french) == decimal("1234568.5"))
        }
        // Not a group of three, so two numbers side by side.
        #expect(throws: CalcError.syntax) { try answer("1 23 + 1", in: french) }
    }

    @Test(arguments: [(".5 + 5.", enUS, "5.5"), (",5 * 2", deDE, "1")])
    func numberCanBeginOrEndWithItsDecimalSeparator(
        _ input: String, _ locale: Locale, _ expected: String
    ) throws {
        #expect(try answer(input, in: locale) == decimal(expected))
    }

    @Test func zerosInFrontOfANumberChangeNothing() throws {
        #expect(try answer("007 + 1") == 8)
    }

    @Test(arguments: [
        ("0,125 * 2", enUS),
        ("0,5*2", enUS),
        ("012,345 + 1", enUS),
        ("0.125 * 2", deDE),
    ])
    func groupedNumberDoesNotBeginWithAZero(_ input: String, _ locale: Locale) {
        // Read as grouping, "0,125 * 2" would be 250 for someone who meant a quarter.
        #expect(throws: CalcError.syntax) { try answer(input, in: locale) }
    }

    @Test func zeroInFrontOfTheDecimalSeparatorIsAnOrdinaryNumber() throws {
        #expect(try answer("0.125 * 2", in: enUS) == decimal("0.25"))
        #expect(try answer("0,125 * 2", in: deDE) == decimal("0.25"))
    }

    @Test(arguments: [
        // Groups are of exactly three digits, after a first group of one to three.
        ("1,23 + 1", enUS),
        ("1,2345 + 1", enUS),
        ("1234,567 + 1", enUS),
        ("1,,234 + 1", enUS),
        ("1.2.3 + 1", enUS),
        // No grouping behind the decimal separator.
        ("1.234,567 + 1", enUS),
        (". + 1", enUS),
        // In German a point between other than three digits is nothing at all, and a comma
        // does not separate arguments.
        ("1.5 + 1", deDE),
        ("1.23 + 1", deDE),
        ("max(1, 2)", deDE),
    ])
    func separatorInTheWrongPlaceIsNotANumber(_ input: String, _ locale: Locale) {
        #expect(throws: CalcError.syntax) { try answer(input, in: locale) }
    }

    // MARK: Argument separators

    @Test(arguments: [
        ("max(1; 2)", enUS, "2"),
        ("max(100;200)", deDE, "200"),
        ("max(1,5; 2)", deDE, "2"),
    ])
    func semicolonSeparatesArgumentsInEveryLocale(
        _ input: String, _ locale: Locale, _ expected: String
    ) throws {
        #expect(try answer(input, in: locale) == decimal(expected))
    }

    @Test(arguments: [
        ("max(100,200)", "200"),
        ("max(1,234)", "234"),
        ("max(1,234.5, 2)", "234.5"),
        // The arguments are 1, 000 and 5.
        ("min(1,000; 5)", "0"),
    ])
    func englishCommaDirectlyInsideAFunctionSeparatesArguments(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input, in: enUS) == decimal(expected))
    }

    @Test(arguments: [
        // In parentheses of its own, a number can be grouped again.
        ("max((1,234), 5)", "1234"),
        ("max(2 * (1,000), 5)", "2000"),
        ("sqrt((1,000,000))", "1000"),
        // And so it can after the function's parenthesis has closed.
        ("max(1, 2) + 1,000", "1002"),
    ])
    func englishCommaGroupsAgainOutsideOfTheArgumentList(
        _ input: String, _ expected: String
    ) throws {
        #expect(try answer(input, in: enUS) == decimal(expected))
    }

    @Test func germanPointGroupsInsideAFunctionToo() throws {
        // The point is not an argument separator, so nothing has to give way.
        #expect(try answer("max(1.000; 2)", in: deDE) == 1000)
    }

    // MARK: Digits

    @Test(arguments: [
        ("１２ + ３", "15"),
        ("٣ + ٤", "7"),
        ("५ * २", "10"),
        ("1٢３ + 0", "123"),
    ])
    func digitsOfAnyScriptAreDigits(_ input: String, _ expected: String) throws {
        #expect(try answer(input) == decimal(expected))
    }

    @Test(arguments: ["2² + 1", "½ + 1", "Ⅷ + 1"])
    func otherNumericCharactersAreNotDigits(_ input: String) {
        #expect(throws: CalcError.self) { try answer(input) }
    }
}

@Suite struct CalculatorUnitTests {
    /// The answer with every digit it has and the symbol of its unit: "0.45359237 kg". A plain
    /// number is its digits alone.
    private func exactAnswer(_ input: String) throws -> String {
        let value = try Calculator.evaluate(input, locale: enUS).value
        guard let unit = value.unit else { return "\(value.number)" }
        return "\(value.number) \(unit.symbol)"
    }

    // MARK: Writing a conversion

    @Test(arguments: [
        ("5 km to m", "5000 m"),
        ("5 km in m", "5000 m"),
        ("5 km as m", "5000 m"),
        ("5 km TO m", "5000 m"),
        // The first "in" is inches: a unit is looked for behind a number before a keyword is.
        ("5 ft in in", "60 in"),
    ])
    func conversionIsAskedForWithToInOrAs(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("5km to m", "5000 m"),
        ("5 kilometers to meters", "5000 m"),
        ("1 kilometre to metres", "1000 m"),
        ("10 KM to MM", "10000000 mm"),
    ])
    func unitsCanBeWrittenOutAndWithoutRegardToCase(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [("(1 km + 1 km) to m", "2000 m"), ("2 * 3 km to m", "6000 m")])
    func conversionAppliesToEverythingInFrontOfIt(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    // MARK: Conversions with an answer that ends, which are exact

    @Test(arguments: [
        ("1 in to cm", "2.54 cm"),
        ("1 ft to in", "12 in"),
        ("1 yd to ft", "3 ft"),
        ("1 mi to ft", "5280 ft"),
        ("1 mi to km", "1.609344 km"),
        ("1 nautical mile to m", "1852 m"),
    ])
    func lengths(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("1 lb to kg", "0.45359237 kg"),
        ("1 lb to oz", "16 oz"),
        ("1 st to lb", "14 lb"),
        ("1 oz to g", "28.349523125 g"),
        ("2 t to kg", "2000 kg"),
    ])
    func masses(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("1 l to ml", "1000 mL"),
        ("1 gal to l", "3.785411784 L"),
        ("1 gal to qt", "4 qt"),
        ("1 qt to pt", "2 pt"),
        ("1 pt to cup", "2 cup"),
        ("1 cup to fl oz", "8 fl oz"),
        ("1 cup to ml", "236.5882365 mL"),
        ("1 fl oz to tbsp", "2 tbsp"),
        ("1 tbsp to tsp", "3 tsp"),
    ])
    func volumesInTheUSCustomaryMeasures(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("1 ha to m²", "10000 m²"),
        ("3 sq m to m2", "3 m²"),
        ("1 acre to sq ft", "43560 ft²"),
        ("1 sq mi to acres", "640 ac"),
        ("1 acre to m²", "4046.8564224 m²"),
    ])
    func areas(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("100 C to F", "212 °F"),
        ("32 F to C", "0 °C"),
        ("-40 C to F", "-40 °F"),
        ("-17.5 C to F", "0.5 °F"),
        ("98.6 F to C", "37 °C"),
        ("0 °C to K", "273.15 K"),
        ("0 K to °F", "-459.67 °F"),
    ])
    func temperatures(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("36 km/h to m/s", "10 m/s"),
        ("10 m/s to km/h", "36 km/h"),
        ("100 mph to km/h", "160.9344 km/h"),
        ("1 kn to km/h", "1.852 km/h"),
    ])
    func speeds(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("90 min to h", "1.5 h"),
        ("1 h to min", "60 min"),
        ("1 d to h", "24 h"),
        ("2 weeks to days", "14 d"),
        ("1500 ms to s", "1.5 s"),
    ])
    func durations(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("1 GB to MB", "1000 MB"),
        ("1 GiB to MiB", "1024 MiB"),
        ("1 GiB to MB", "1073.741824 MB"),
        ("8 Mb to MB", "1 MB"),
        ("1 mb to kb", "1000 kB"),
        ("1 B to bits", "8 bit"),
    ])
    func dataSizes(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("5 km to mi", "3.10685596119 mi"),
        ("72 F to C", "22.2222222222 °C"),
        ("1 m to ft", "3.28083989501 ft"),
        ("1 kg to lb", "2.20462262185 lb"),
        ("100 km/h to mph", "62.1371192237 mph"),
    ])
    func conversionWithoutAnEndIsRightToTheDigitsShown(_ input: String, _ shown: String) throws {
        #expect(try shownAnswer(input) == shown)
    }

    // MARK: Arithmetic with units

    @Test(arguments: [
        ("1 km + 500 m", "1.5 km"),
        ("1 km - 500 m", "0.5 km"),
        ("0.1 km + 0.2 km", "0.3 km"),
        ("-5 km + 2 km", "-3 km"),
    ])
    func measurementsOfOneKindAddInTheUnitOfTheFirst(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("2 * 5 kg", "10 kg"),
        ("5 kg * 2", "10 kg"),
        ("10 km / 4", "2.5 km"),
        ("10 km/h * 2", "20 km/h"),
    ])
    func measurementTimesOrDividedByANumberKeepsItsUnit(
        _ input: String, _ expected: String
    ) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [("10 km / 2 km", "5"), ("1 km / 500 m", "2"), ("1 h / 15 min", "4")])
    func twoMeasurementsOfOneKindDivideToAPlainNumber(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("200 km + 10%", "220 km"), ("200 km - 10%", "180 km"), ("50% of 10 km", "5 km"),
    ])
    func percentOfAMeasurementKeepsItsUnit(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("abs(-5 km)", "5 km"),
        ("round(2.6 km)", "3 km"),
        ("floor(2.6 km)", "2 km"),
        ("ceil(2.1 km)", "3 km"),
        // In the unit of the first argument.
        ("max(1 km, 1500 m)", "1.5 km"),
        ("min(1 km, 1500 m)", "1 km"),
    ])
    func roundingAndComparingFunctionsTakeMeasurements(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    // MARK: Finding the unit behind a number

    @Test(arguments: [
        ("5 m", "5 m"),
        ("5m", "5 m"),
        ("3 d", "3 d"),
        ("3d", "3 d"),
        ("2 wk", "2 wk"),
        // Inches, although "in" is also the word that asks for a conversion.
        ("5 in", "5 in"),
    ])
    func unitFollowsItsNumberWithOrWithoutASpace(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("5 ms", "5 ms"),
        ("5 min", "5 min"),
        ("5 m/s", "5 m/s"),
        ("10 km/h", "10 km/h"),
        ("1 fl oz", "1 fl oz"),
        ("1 oz", "1 oz"),
        ("5 sq m", "5 m²"),
        ("5 sq mi", "5 mi²"),
    ])
    func longestSpellingThatIsWrittenWins(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [("10 km/2", "5 km"), ("10 m/sqrt(4)", "5 m")])
    func slashBehindAUnitDividesWhereNoLongerUnitIsWritten(
        _ input: String, _ expected: String
    ) throws {
        // "km/2" is not a unit, and neither is the "m/s" in "m/sqrt": a letter follows it.
        #expect(try exactAnswer(input) == expected)
    }

    @Test func spellingCountsOnlyWhereNoLetterOrDigitFollows() {
        let metres = CalcUnits.unit(in: Array("m/sqrt(4)"), at: 0)
        let nothing = CalcUnits.unit(in: Array("mod 3"), at: 0)
        let squareMetres = CalcUnits.unit(in: Array("m²"), at: 0)

        #expect(metres?.unit.symbol == "m")
        #expect(metres?.length == 1)
        #expect(nothing == nil)
        #expect(squareMetres?.unit.symbol == "m²")
    }

    @Test(arguments: [
        ("10 kph", "10 km/h"),
        ("10 kmh", "10 km/h"),
        ("10 mph", "10 mph"),
        ("5 m²", "5 m²"),
        ("5 m2", "5 m²"),
        ("5 square metres", "5 m²"),
    ])
    func speedsAndAreasHaveSeveralSpellings(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("5 °C", "5 °C"),
        ("5 C", "5 °C"),
        ("5 c", "5 °C"),
        ("5 celsius", "5 °C"),
        ("5 Fahrenheit", "5 °F"),
        ("5 K", "5 K"),
    ])
    func temperaturesNeedNoDegreeSign(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("5 Mb", "5 Mbit"),
        ("5 MB", "5 MB"),
        ("5 Kb", "5 kbit"),
        ("5 kB", "5 kB"),
        ("5 b", "5 bit"),
        ("5 B", "5 B"),
    ])
    func capitalsTellBitsFromBytes(_ input: String, _ expected: String) throws {
        // A spelling is looked for as it is written before case stops counting.
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("5 kb", "5 kB"),
        ("5 mb", "5 MB"),
        ("5 gb", "5 GB"),
        ("5 GIGABYTES", "5 GB"),
    ])
    func dataSizesInOneCaseAreBytes(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: [
        ("1 Tb to Gb", "1000 Gbit"),
        ("1 Pb to Tb", "1000 Tbit"),
        ("1 TB to GB", "1000 GB"),
        ("1 tb to gb", "1000 GB"),
    ])
    func terabitsAndPetabitsAreUnitsOfTheirOwn(_ input: String, _ expected: String) throws {
        // "Tb" used to be read as terabytes, for want of a terabit.
        #expect(try exactAnswer(input) == expected)
    }

    @Test(arguments: ["5k * 12", "5 M", "5 S", "5 H", "10 KM to M", "5 G"])
    func spellingOfOneLetterIsReadInItsOwnCaseOnly(_ input: String) {
        // "5k * 12" used to be 60 kelvin.
        #expect(throws: CalcError.self) { try answer(input) }
    }

    @Test func smallLettersForCelsiusAndFahrenheitAreSpellingsOfTheirOwn() throws {
        #expect(try exactAnswer("212 f to c") == "100 °C")
        #expect(try exactAnswer("5 f") == "5 °F")
    }

    // MARK: Temperatures in two units

    @Test(arguments: ["10 C + 50 F", "50 F - 10 C", "5 K + 5 C", "10 C + 50 F + 1 C"])
    func temperaturesInDifferentUnitsAreNotAddedOrSubtracted(_ input: String) {
        // 50 °F is 10 °C as a point on the scale and 27.8 degrees Celsius as a difference.
        #expect(throws: CalcError.incompatibleUnits) { try answer(input) }
    }

    @Test(arguments: [
        ("20 C + 5 C", "25 °C"),
        ("70 F - 2 F", "68 °F"),
        // Comparing two points is not ambiguous.
        ("min(10 C, 59 F)", "10 °C"),
        ("max(10 C, 59 F)", "15 °C"),
        ("(20 C + 5 C) to F", "77 °F"),
    ])
    func temperaturesInOneUnitAddAndAnyTwoCompare(_ input: String, _ expected: String) throws {
        #expect(try exactAnswer(input) == expected)
    }

    // MARK: The table

    @Test func everyUnitHasASymbolOfItsOwn() {
        var symbols: Set<String> = []
        for entry in CalcUnits.table {
            let isNew = symbols.insert(entry.unit.symbol).inserted
            #expect(isNew, "Two units are shown as “\(entry.unit.symbol)”")
        }
    }

    @Test func everySpellingOfTheTableNamesItsOwnUnit() throws {
        for entry in CalcUnits.table {
            for spelling in entry.spellings {
                let found = try #require(
                    CalcUnits.unit(in: Array(spelling), at: 0), "Nothing found for “\(spelling)”")

                #expect(found.unit == entry.unit, "“\(spelling)” names \(found.unit.symbol)")
                #expect(found.length == spelling.count)
            }
        }
    }

    // MARK: Units that do not go together

    @Test(arguments: ["5 km + 3", "3 + 5 km", "max(1 km, 2)"])
    func measurementAndPlainNumberAreNotAddedOrCompared(_ input: String) {
        #expect(throws: CalcError.incompatibleUnits) { try answer(input) }
    }

    @Test(arguments: ["5 km + 3 kg", "5 km - 1 h", "10 km / 2 kg", "max(1 km, 2 kg)"])
    func measurementsOfTwoKindsDoNotGoTogether(_ input: String) {
        #expect(throws: CalcError.incompatibleUnits) { try answer(input) }
    }

    @Test(arguments: ["5 km * 2 km", "5 / 2 km"])
    func productOrQuotientThatWouldMakeANewUnitIsAnError(_ input: String) {
        // Square kilometres from a product and "per kilometre" are units the calculator does
        // not work out.
        #expect(throws: CalcError.incompatibleUnits) { try answer(input) }
    }

    @Test(arguments: [
        "5 km ^ 2", "2 ^ 5 km", "5 km mod 2", "sqrt(4 m)", "sin(1 m)", "(5 km)!", "(5 km)%",
        "5 + 10 km%",
    ])
    func powersRemaindersPostfixesAndOtherFunctionsTakePlainNumbers(_ input: String) {
        #expect(throws: CalcError.incompatibleUnits) { try answer(input) }
    }

    @Test(arguments: [
        // To a unit of another kind.
        "5 km to kg", "5 C to km",
        // Of a plain number.
        "5 to km", "(2 + 3) to km",
    ])
    func conversionNeedsAMeasurementOfTheSameKind(_ input: String) {
        #expect(throws: CalcError.incompatibleUnits) { try answer(input) }
    }
}

@Suite struct CalculatorRejectionTests {
    // MARK: What is not an expression

    @Test(arguments: ["", "   "])
    func emptyInputIsNotAnExpression(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["2+", "+", "*2", "2^", "2 +* 3", "2 ^ ^ 3"])
    func operatorWithoutAnOperandIsASyntaxError(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["(", ")", "()", "(2", "2)"])
    func parenthesesThatAreEmptyOrDoNotMatchAreASyntaxError(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["#", "2 & 3", "$5", "2 = 2"])
    func characterTheCalculatorDoesNotKnowIsASyntaxError(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["sqrt(", "sqrt()", "sqrt(4", "sqrt 4", "sqrt", "max(1,)", "max(;1)"])
    func functionNeedsParenthesesWithAnArgumentInEveryPlace(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["sqrt(1, 2)", "abs(1; 2)"])
    func functionOfOneNumberTakesNoSecondArgument(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    // The next four are decisions about the grammar and not typing mistakes: each could have
    // gone the other way.

    @Test(arguments: ["2 3", "2 (3)", "(2)(3)", "2 pi"])
    func thereIsNoMultiplicationWithoutAnOperator(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["3!!", "5%%"])
    func operandHasAtMostOnePostfixOperator(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: [
        // "of" belongs directly behind a percent sign.
        "of 200", "200 of 15%", "(15%) of 200",
    ])
    func ofStandsOnlyDirectlyBehindAPercent(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: [
        // The unit is missing or unknown.
        "5 km to", "5 km to xyz",
        // Something follows the unit.
        "5 km to m 3", "5 km to m + 1",
    ])
    func conversionEndsTheInputAndNamesAUnit(_ input: String) {
        #expect(throws: CalcError.syntax) { try answer(input) }
    }

    @Test(arguments: ["foo(2)", "2 + x", "sqr(4)", "log3(8)", "pie"])
    func wordThatIsNoFunctionConstantOrKeywordIsAnUnknownName(_ input: String) {
        #expect(throws: CalcError.unknownName) { try answer(input) }
    }

    @Test(arguments: ["1e5", "2e3", "2 + e3"])
    func thereIsNoScientificNotation(_ input: String) {
        // Also a decision: "e" is the constant, so "e5" is a name nobody knows.
        #expect(throws: CalcError.unknownName) { try answer(input) }
    }

    // MARK: What has no answer

    @Test(arguments: ["1 / 0", "1 / (2 - 2)", "5 mod 0", "0^-1", "10 km / 0 km"])
    func divisionByZero(_ input: String) {
        #expect(throws: CalcError.divisionByZero) { try answer(input) }
    }

    @Test(arguments: ["sqrt(-1)", "ln(0)", "ln(-1)", "log(0)", "log2(-8)", "(-8)^0.5"])
    func rootOrLogarithmOutsideOfWhereItIsDefined(_ input: String) {
        #expect(throws: CalcError.undefined) { try answer(input) }
    }

    @Test(arguments: ["asin(2)", "acos(-2)"])
    func inverseSineOrCosineOfMoreThanOne(_ input: String) {
        #expect(throws: CalcError.undefined) { try answer(input) }
    }

    @Test(arguments: ["5.5!", "(-1)!"])
    func factorialOfAFractionOrANegativeNumber(_ input: String) {
        #expect(throws: CalcError.undefined) { try answer(input) }
    }

    // MARK: What is out of range

    @Test(arguments: ["9^9^9", "2^1000000", "1.0000001^999999999", "10^200", "10^100 * 10^100"])
    func whatIsTooLargeForADecimal(_ input: String) {
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    @Test(arguments: ["10^-200", "10^-100 * 10^-100", "0.5^2000"])
    func whatIsTooSmallForADecimal(_ input: String) {
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    @Test(arguments: ["171!", "1000!"])
    func factorialBeyondThatOf103(_ input: String) {
        #expect(throws: CalcError.outOfRange) { try answer(input) }
    }

    @Test func numberWithMoreDigitsThanADecimalHasPlacesIsOutOfRange() {
        let digits = String(repeating: "9", count: 200)

        #expect(throws: CalcError.outOfRange) { try answer("\(digits) + 1") }
    }

    // MARK: Limits on the input

    @Test func parenthesesNestSixtyFourDeep() throws {
        let deepest = String(repeating: "(", count: 64) + "1" + String(repeating: ")", count: 64)
        let tooDeep = "(" + deepest + ")"

        #expect(try answer(deepest) == 1)
        #expect(throws: CalcError.tooDeep) { try answer(tooDeep) }
    }

    @Test func signsNestSixtyFourDeep() throws {
        let deepest = String(repeating: "-", count: 64) + "1"

        #expect(try answer(deepest) == 1)
        #expect(throws: CalcError.tooDeep) { try answer("-" + deepest) }
    }

    @Test func exponentsAndMixturesCountAsNestingToo() throws {
        let exponents = String(repeating: "1^", count: 64) + "1"
        // A sign and a parenthesis are two levels.
        let signedParentheses =
            String(repeating: "-(", count: 32) + "1" + String(repeating: ")", count: 32)

        #expect(try answer(exponents) == 1)
        #expect(try answer(signedParentheses) == 1)
        #expect(throws: CalcError.tooDeep) { try answer("1^" + exponents) }
        #expect(throws: CalcError.tooDeep) { try answer("-" + signedParentheses) }
    }

    /// Expressions as deep as 256 characters can make them, each with its answer.
    private static let deepestExpressions: [(String, Decimal)] = {
        let longestSum = "1" + String(repeating: "+1", count: 127)
        let nestedSums =
            String(repeating: "1+(", count: 63) + "1" + String(repeating: ")", count: 63)
        let nestedCalls =
            String(repeating: "abs(", count: 50) + "-1" + String(repeating: ")", count: 50)
        let exponents = String(repeating: "1^", count: 64) + "1"
        let everythingAtOnce =
            String(repeating: "abs(1+0*", count: 21) + "1" + String(repeating: ")!^1", count: 21)
        return [
            (longestSum, 128), (nestedSums, 64), (nestedCalls, 1), (exponents, 1),
            (everythingAtOnce, 1),
        ]
    }()

    @Test(arguments: deepestExpressions)
    func deepestExpressionsAreWorkedOutWithoutRunningOutOfStack(
        _ input: String, _ expected: Decimal
    ) throws {
        // Tests run on threads with 512 KB of stack, and a debug build has the largest frames.
        #expect(try answer(input) == expected)
    }

    @Test func inputIsReadUpTo256Characters() throws {
        // 255 characters and a space.
        let longest = "1" + String(repeating: "+1", count: 127) + " "
        let tooLong = longest + " "

        #expect(longest.count == 256)
        #expect(try answer(longest) == 128)
        #expect(throws: CalcError.tooLong) { try answer(tooLong) }
        #expect(throws: CalcError.tooLong) { try answer(String(repeating: "(", count: 100_000)) }
    }

    @Test func lengthIsCountedInUnicodeScalars() throws {
        // An "é" written as a letter and an accent is one character and two scalars.
        let accented = String(repeating: "e\u{301}", count: 129)
        let fullWidth = "１" + String(repeating: "+１", count: 127)

        #expect(accented.count == 129)
        #expect(Calculator.isTooLong(accented))
        // 255 scalars of three bytes each.
        #expect(!Calculator.isTooLong(fullWidth))
        #expect(try answer(fullWidth) == 128)
    }

    @Test func inputOfAnySizeIsRefusedWithoutBeingWalked() {
        // Combining marks, all of them one character: counting characters took 0.8 s for this.
        let pasted = String(repeating: "\u{301}", count: 10_000_000)
        let clock = ContinuousClock()
        let start = clock.now

        #expect(Calculator.isTooLong(pasted))
        #expect(throws: CalcError.tooLong) { try answer(pasted) }

        #expect(clock.now - start < .milliseconds(100))
    }
}
