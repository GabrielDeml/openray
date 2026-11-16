import Foundation
import Testing

@testable import OpenRayCore

// Shared by the calculator's test files.

// The calculator is tested in these locales and never in the machine's own.
let enUS = Locale(identifier: "en_US")
let deDE = Locale(identifier: "de_DE")
let frCH = Locale(identifier: "fr_CH")

/// A number from its digits, for expectations that a `Double` literal would not hold exactly.
/// The digits are written the plain way whatever the locale under test, with a point, and may
/// have an exponent: "0.3", "1e-64".
func decimal(_ digits: String) throws -> Decimal {
    try #require(Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")))
}
