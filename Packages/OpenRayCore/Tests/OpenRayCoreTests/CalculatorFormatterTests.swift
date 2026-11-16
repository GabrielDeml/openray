import Foundation
import Testing

@testable import OpenRayCore

/// A plain number from its digits.
private func value(_ digits: String) throws -> CalcValue {
    CalcValue(number: try decimal(digits), unit: nil)
}

@Suite struct CalculatorFormatterTests {
    // MARK: Exact answers

    @Test(arguments: [
        ("0", "0", "0"),
        ("42", "42", "42"),
        ("-42", "-42", "-42"),
        ("0.3", "0.3", "0.3"),
        ("1234.5", "1,234.5", "1234.5"),
        ("-1234.5", "-1,234.5", "-1234.5"),
        ("1000000", "1,000,000", "1000000"),
        // 12 significant digits, the last one rounded.
        ("3.3333333333333333333333333333333333333", "3.33333333333", "3.33333333333"),
        ("0.66666666666666666666666666666666666667", "0.666666666667", "0.666666666667"),
        ("12345678901.25", "12,345,678,901.3", "12345678901.3"),
        ("0.000001234567890123456", "0.00000123456789012", "0.00000123456789012"),
        ("0.99999999999999", "1", "1"),
        ("211.99999999999454", "212", "212"),
        // Whole digits are never rounded away, however many there are.
        ("999999999999.6", "1,000,000,000,000", "1000000000000"),
        ("1234567890123.456", "1,234,567,890,123", "1234567890123"),
        ("18446744073709551616", "18,446,744,073,709,551,616", "18446744073709551616"),
        ("123456789012345678901", "123,456,789,012,345,678,901", "123456789012345678901"),
        ("-123456789012345678901", "-123,456,789,012,345,678,901", "-123456789012345678901"),
        // From 1e21 on, and below 1e-9, the digits are no longer counted by eye.
        ("1e21", "1E21", "1E21"),
        ("1234567890123456789012345", "1.23456789012E24", "1.23456789012E24"),
        ("-1e30", "-1E30", "-1E30"),
        ("0.000000001", "0.000000001", "0.000000001"),
        ("0.000000000999", "9.99E-10", "9.99E-10"),
        ("-0.00000000000025", "-2.5E-13", "-2.5E-13"),
    ])
    func americanEnglish(_ digits: String, _ shown: String, _ copied: String) throws {
        let number = try value(digits)

        #expect(CalcFormatter.displayText(for: number, isApproximate: false, locale: enUS) == shown)
        #expect(CalcFormatter.copyText(for: number, isApproximate: false, locale: enUS) == copied)
    }

    @Test(arguments: [
        ("0.3", "0,3", "0,3"),
        ("1234.5", "1.234,5", "1234,5"),
        ("-1234567.891", "-1.234.567,891", "-1234567,891"),
        ("3.3333333333333333333333333333333333333", "3,33333333333", "3,33333333333"),
        ("18446744073709551616", "18.446.744.073.709.551.616", "18446744073709551616"),
        ("1e21", "1E21", "1E21"),
        ("0.000000000999", "9,99E-10", "9,99E-10"),
    ])
    func german(_ digits: String, _ shown: String, _ copied: String) throws {
        let number = try value(digits)

        #expect(CalcFormatter.displayText(for: number, isApproximate: false, locale: deDE) == shown)
        #expect(CalcFormatter.copyText(for: number, isApproximate: false, locale: deDE) == copied)
    }

    @Test func swissFrench() throws {
        // Read from the locale: its separators have changed between versions of the system.
        let decimalSeparator = try #require(frCH.decimalSeparator)
        let groupingSeparator = try #require(frCH.groupingSeparator)
        let number = try value("1234567.5")

        let shown = CalcFormatter.displayText(for: number, isApproximate: false, locale: frCH)
        let copied = CalcFormatter.copyText(for: number, isApproximate: false, locale: frCH)

        #expect(shown == "1\(groupingSeparator)234\(groupingSeparator)567\(decimalSeparator)5")
        #expect(copied == "1234567\(decimalSeparator)5")
    }

    @Test func unitIsShownAndNotCopied() throws {
        let distance = CalcValue(number: 5000, unit: CalcUnit(.length, "m", 1))
        let days = CalcValue(number: 14, unit: CalcUnit(.duration, "d", 86_400))

        #expect(
            CalcFormatter.displayText(for: distance, isApproximate: false, locale: enUS)
                == "5,000 m")
        #expect(CalcFormatter.copyText(for: distance, isApproximate: false, locale: enUS) == "5000")
        #expect(CalcFormatter.displayText(for: days, isApproximate: false, locale: deDE) == "14 d")
    }

    @Test(arguments: [enUS, deDE, frCH])
    func whatIsShownAndWhatIsCopiedReadBackAsTheSameNumber(_ locale: Locale) throws {
        let numbers = try [value("1234567.891"), value("-0.000123"), value("987654321098")]

        for number in numbers {
            let shown = CalcFormatter.displayText(for: number, isApproximate: false, locale: locale)
            let copied = CalcFormatter.copyText(for: number, isApproximate: false, locale: locale)

            // An answer pasted back into the launcher has to be a number again.
            #expect(try Calculator.evaluate(shown, locale: locale).value == number)
            #expect(try Calculator.evaluate(copied, locale: locale).value == number)
        }
    }

    // MARK: Answers that came through Double

    @Test(arguments: [
        // The square root of 10^41 as `Double` has it. The digits behind the twelfth mean
        // nothing, and an exact answer of this size would be shown with all 21.
        ("316227766016837940000", "316,227,766,017,000,000,000", "316227766017000000000"),
        ("1234567890123.456", "1,234,567,890,120", "1234567890120"),
        // Up to twelve whole digits there is nothing to cut.
        ("123456789012", "123,456,789,012", "123456789012"),
        ("1.4142135623730951", "1.41421356237", "1.41421356237"),
        ("1e21", "1E21", "1E21"),
    ])
    func approximateAnswerIsShownToTwelveDigitsHoweverLargeItIs(
        _ digits: String, _ shown: String, _ copied: String
    ) throws {
        let number = try value(digits)

        #expect(CalcFormatter.displayText(for: number, isApproximate: true, locale: enUS) == shown)
        #expect(CalcFormatter.copyText(for: number, isApproximate: true, locale: enUS) == copied)
    }

    // MARK: The copy text is plain

    @Test(arguments: [
        // Swedish writes the minus as U+2212 and an exponent as "×10^".
        ("sv_SE", "-1234.5", "-1234,5"),
        ("sv_SE", "1.5e25", "1,5E25"),
        // Arabic as written in Egypt has digits of its own and a decimal separator that is
        // not a comma, and puts a direction mark in front of a minus. So does Hebrew.
        ("ar_EG", "-1234.5", "-1234.5"),
        ("he_IL", "-1234.5", "-1234.5"),
        ("de_DE", "-0.00000000000025", "-2,5E-13"),
        ("en_US", "1234567.891", "1234567.891"),
    ])
    func copyTextIsAsciiWithTheLocalesDecimalCommaAndNothingElseOfTheLocale(
        _ localeIdentifier: String, _ digits: String, _ copied: String
    ) throws {
        let locale = Locale(identifier: localeIdentifier)

        let text = CalcFormatter.copyText(
            for: try value(digits), isApproximate: false, locale: locale)

        #expect(text == copied)
        let isAllASCII = text.allSatisfy { character in character.isASCII }
        #expect(isAllASCII, "“\(text)” has something in it that is not ASCII")
    }
}
