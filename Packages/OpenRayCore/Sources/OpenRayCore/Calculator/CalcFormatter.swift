import Foundation

/// An answer as text: for the row that shows it, and for the clipboard (docs/DESIGN.md §4.4).
enum CalcFormatter {
    /// How many digits of an answer are shown. Whole digits of an exact answer are never cut,
    /// so a whole number can have more.
    static let significantDigits = 12

    /// The answer as the row shows it: with grouping separators, and with the symbol of its
    /// unit behind it.
    ///
    /// - Parameter isApproximate: Whether the answer came through `Double`
    ///   (`CalcResult.isApproximate`).
    static func displayText(for value: CalcValue, isApproximate: Bool, locale: Locale) -> String {
        let number = text(
            for: value.number, isApproximate: isApproximate, locale: locale, grouping: .automatic)
        guard let unit = value.unit else { return number }
        return "\(number) \(unit.symbol)"
    }

    /// The answer as it is copied and pasted: the number alone and as plain as a number gets,
    /// so that it can go straight into a spreadsheet or another calculation.
    static func copyText(for value: CalcValue, isApproximate: Bool, locale: Locale) -> String {
        // Not in the locale's own format. That brings invisible direction marks in Hebrew and
        // Arabic, U+2212 for the minus sign in Swedish, native digits in Egypt and "1×10^25"
        // for an exponent, and whatever the text is pasted into reads none of them.
        let plainLocale = Locale(identifier: "en_US_POSIX")
        let plain = text(
            for: value.number, isApproximate: isApproximate, locale: plainLocale, grouping: .never)

        // The one thing taken from the locale: a spreadsheet set to German reads "1,5".
        if locale.decimalSeparator == "," {
            return plain.replacingOccurrences(of: ".", with: ",")
        }
        return plain
    }

    private static func text(
        for number: Decimal, isApproximate: Bool, locale: Locale,
        grouping: NumberFormatStyleConfiguration.Grouping
    ) -> String {
        // Halves away from zero, as `round` does it.
        let style = Decimal.FormatStyle(locale: locale)
            .grouping(grouping)
            .rounded(rule: .toNearestOrAwayFromZero)
        let significant = NumberFormatStyleConfiguration.Precision.significantDigits(
            1...significantDigits)
        let magnitude = number.magnitude

        // Too many digits to read, before or behind the separator.
        let largestInFull = Decimal(sign: .plus, exponent: 21, significand: 1)
        let smallestInFull = Decimal(sign: .plus, exponent: -9, significand: 1)
        let isOutOfSight = magnitude >= largestInFull || magnitude < smallestInFull
        if isOutOfSight && number != 0 {
            return number.formatted(style.notation(.scientific).precision(significant))
        }

        // With more whole digits than are shown, significant digits would round whole digits
        // away. They are shown in full, and the fraction not at all. But only when they are
        // all there: an answer that came through `Double` has 16 digits at most, and the
        // square root of 10^41 would be shown with five that mean nothing. It is rounded like
        // any other and ends in zeros.
        let firstWithMoreWholeDigitsThanShown = Decimal(
            sign: .plus, exponent: significantDigits, significand: 1)
        if magnitude >= firstWithMoreWholeDigitsThanShown && !isApproximate {
            return number.formatted(style.precision(.fractionLength(0)))
        }
        return number.formatted(style.precision(significant))
    }
}
