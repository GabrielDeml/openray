import Foundation

/// A unit of measurement: what it measures, how it is shown behind an answer, and how large
/// it is.
///
/// The size is a fraction of whole numbers and not one decimal number. A kilometre per hour is
/// 1000/3600 of a metre per second and a degree Fahrenheit 5/9 of a kelvin, and neither has a
/// decimal that ends. Kept as fractions, "36 km/h to m/s" is exactly 10.
struct CalcUnit: Sendable, Hashable {
    enum Quantity: Sendable, Hashable {
        case length, mass, volume, area, temperature, speed, duration, dataSize
    }

    var quantity: Quantity
    var symbol: String
    /// A value in this unit is `(value + offset) × numerator ÷ denominator` in the base unit of
    /// its quantity: metres, kilograms, litres, square metres, kelvin, metres per second,
    /// seconds, bits.
    var numerator: Decimal
    var denominator: Decimal
    /// Only temperatures have one: 0 °C is 273.15 K.
    var offset: Decimal

    init(
        _ quantity: Quantity, _ symbol: String, _ numerator: Decimal,
        over denominator: Decimal = 1, offset: Decimal = 0
    ) {
        self.quantity = quantity
        self.symbol = symbol
        self.numerator = numerator
        self.denominator = denominator
        self.offset = offset
    }
}

/// The units the calculator knows: how they are written, and how one is converted into another
/// (docs/DESIGN.md §4.4).
///
/// The sizes are the exact ones the units are defined by, and not Foundation's `Dimension`
/// converters, which round them: there a pound is 0.453592 kg, and 32 °F comes out as
/// 2.2e-12 °C.
enum CalcUnits {
    // 273.15 and 459.67, written so that no `Double` comes between the digits and the `Decimal`.
    private static let celsiusOffset = Decimal(sign: .plus, exponent: -2, significand: 27315)
    private static let fahrenheitOffset = Decimal(sign: .plus, exponent: -2, significand: 45967)

    /// Every unit with the spellings that name it: its symbols, and its English names in the
    /// singular and the plural.
    ///
    /// A spelling is looked for as it is written first, so "Mb" is megabits and "MB" megabytes.
    /// Only when nothing matches that way does case stop counting, and then the unit that
    /// comes first here wins: "mb" is megabytes, because the bytes are listed before the bits.
    /// A spelling of one letter is never read without regard to its case. Where both cases
    /// are meant, both are listed.
    static let table: [(unit: CalcUnit, spellings: [String])] = [
        // Length, in metres. The inch is 25.4 mm by definition, and the foot, the yard and the
        // mile are 12, 36 and 63360 of them.
        (
            CalcUnit(.length, "mm", 1, over: 1000),
            ["mm", "millimeter", "millimeters", "millimetre", "millimetres"]
        ),
        (
            CalcUnit(.length, "cm", 1, over: 100),
            ["cm", "centimeter", "centimeters", "centimetre", "centimetres"]
        ),
        (CalcUnit(.length, "m", 1), ["m", "meter", "meters", "metre", "metres"]),
        (
            CalcUnit(.length, "km", 1000),
            ["km", "kilometer", "kilometers", "kilometre", "kilometres"]
        ),
        (CalcUnit(.length, "in", 254, over: 10_000), ["in", "inch", "inches"]),
        (CalcUnit(.length, "ft", 3048, over: 10_000), ["ft", "foot", "feet"]),
        (CalcUnit(.length, "yd", 9144, over: 10_000), ["yd", "yard", "yards"]),
        (CalcUnit(.length, "mi", 1_609_344, over: 1000), ["mi", "mile", "miles"]),
        // Not "NM": in small letters that is a nanometre.
        (CalcUnit(.length, "nmi", 1852), ["nmi", "nautical mile", "nautical miles"]),

        // Mass, in kilograms. The pound is 0.45359237 kg by definition, the ounce a sixteenth
        // of it and the stone 14 of them.
        (CalcUnit(.mass, "mg", 1, over: 1_000_000), ["mg", "milligram", "milligrams"]),
        (CalcUnit(.mass, "g", 1, over: 1000), ["g", "gram", "grams"]),
        (CalcUnit(.mass, "kg", 1), ["kg", "kilogram", "kilograms"]),
        (CalcUnit(.mass, "t", 1000), ["t", "tonne", "tonnes", "metric ton", "metric tons"]),
        (CalcUnit(.mass, "oz", 45_359_237, over: 1_600_000_000), ["oz", "ounce", "ounces"]),
        (CalcUnit(.mass, "lb", 45_359_237, over: 100_000_000), ["lb", "lbs", "pound", "pounds"]),
        (CalcUnit(.mass, "st", 635_029_318, over: 100_000_000), ["st", "stone", "stones"]),

        // Volume, in litres. From the teaspoon to the gallon these are the US customary
        // measures, not the imperial ones: the gallon is 3.785411784 L by definition, and it
        // has 4 quarts, 8 pints, 16 cups, 128 fluid ounces, 256 tablespoons and 768 teaspoons.
        (
            CalcUnit(.volume, "mL", 1, over: 1000),
            ["ml", "mL", "milliliter", "milliliters", "millilitre", "millilitres"]
        ),
        (CalcUnit(.volume, "L", 1), ["l", "L", "liter", "liters", "litre", "litres"]),
        (
            CalcUnit(.volume, "tsp", 3_785_411_784, over: 768_000_000_000),
            ["tsp", "teaspoon", "teaspoons"]
        ),
        (
            CalcUnit(.volume, "tbsp", 3_785_411_784, over: 256_000_000_000),
            ["tbsp", "tablespoon", "tablespoons"]
        ),
        (
            CalcUnit(.volume, "fl oz", 3_785_411_784, over: 128_000_000_000),
            ["fl oz", "floz", "fluid ounce", "fluid ounces"]
        ),
        (CalcUnit(.volume, "cup", 3_785_411_784, over: 16_000_000_000), ["cup", "cups"]),
        (CalcUnit(.volume, "pt", 3_785_411_784, over: 8_000_000_000), ["pt", "pint", "pints"]),
        (CalcUnit(.volume, "qt", 3_785_411_784, over: 4_000_000_000), ["qt", "quart", "quarts"]),
        (
            CalcUnit(.volume, "gal", 3_785_411_784, over: 1_000_000_000),
            ["gal", "gallon", "gallons"]
        ),

        // Area, in square metres. The square foot and the square mile are the squares of
        // 0.3048 m and 1609.344 m, and the acre is 43560 square feet.
        (
            CalcUnit(.area, "m²", 1),
            [
                "m²", "m2", "sq m", "sqm", "square meter", "square meters", "square metre",
                "square metres",
            ]
        ),
        (
            CalcUnit(.area, "km²", 1_000_000),
            [
                "km²", "km2", "sq km", "square kilometer", "square kilometers", "square kilometre",
                "square kilometres",
            ]
        ),
        (
            CalcUnit(.area, "ft²", 9_290_304, over: 100_000_000),
            ["ft²", "ft2", "sq ft", "sqft", "square foot", "square feet"]
        ),
        (
            CalcUnit(.area, "mi²", 2_589_988_110_336, over: 1_000_000),
            ["mi²", "mi2", "sq mi", "square mile", "square miles"]
        ),
        (CalcUnit(.area, "ac", 40_468_564_224, over: 10_000_000), ["ac", "acre", "acres"]),
        (CalcUnit(.area, "ha", 10_000), ["ha", "hectare", "hectares"]),

        // Temperature, in kelvin. People type "100 f to c", so the small letters are listed.
        // A small "k" is not: "5k" is more often five thousand than five kelvin.
        (
            CalcUnit(.temperature, "°C", 1, offset: celsiusOffset),
            ["°C", "C", "c", "℃", "celsius"]
        ),
        (
            CalcUnit(.temperature, "°F", 5, over: 9, offset: fahrenheitOffset),
            ["°F", "F", "f", "℉", "fahrenheit"]
        ),
        (CalcUnit(.temperature, "K", 1), ["K", "kelvin"]),

        // Speed, in metres per second. An hour has 3600 seconds, and the knot is a nautical
        // mile per hour.
        (CalcUnit(.speed, "m/s", 1), ["m/s"]),
        (CalcUnit(.speed, "km/h", 1000, over: 3600), ["km/h", "kph", "kmh"]),
        (CalcUnit(.speed, "mph", 1_609_344, over: 3_600_000), ["mph", "mi/h"]),
        (CalcUnit(.speed, "kn", 1852, over: 3600), ["kn", "knot", "knots"]),

        // Duration, in seconds.
        (CalcUnit(.duration, "ms", 1, over: 1000), ["ms", "millisecond", "milliseconds"]),
        (CalcUnit(.duration, "s", 1), ["s", "sec", "secs", "second", "seconds"]),
        (CalcUnit(.duration, "min", 60), ["min", "mins", "minute", "minutes"]),
        (CalcUnit(.duration, "h", 3600), ["h", "hr", "hrs", "hour", "hours"]),
        (CalcUnit(.duration, "d", 86_400), ["d", "day", "days"]),
        (CalcUnit(.duration, "wk", 604_800), ["wk", "week", "weeks"]),

        // Data size, in bits. A kilobyte is 1000 bytes and a kibibyte 1024. The bytes come
        // before the bits, which is what makes "kb", "mb" and "gb" in small letters bytes.
        (CalcUnit(.dataSize, "B", 8), ["B", "byte", "bytes"]),
        (CalcUnit(.dataSize, "kB", 8000), ["kB", "KB", "kilobyte", "kilobytes"]),
        (CalcUnit(.dataSize, "MB", 8_000_000), ["MB", "megabyte", "megabytes"]),
        (CalcUnit(.dataSize, "GB", 8_000_000_000), ["GB", "gigabyte", "gigabytes"]),
        (CalcUnit(.dataSize, "TB", 8_000_000_000_000), ["TB", "terabyte", "terabytes"]),
        (CalcUnit(.dataSize, "PB", 8_000_000_000_000_000), ["PB", "petabyte", "petabytes"]),
        (CalcUnit(.dataSize, "KiB", 8192), ["KiB", "kibibyte", "kibibytes"]),
        (CalcUnit(.dataSize, "MiB", 8_388_608), ["MiB", "mebibyte", "mebibytes"]),
        (CalcUnit(.dataSize, "GiB", 8_589_934_592), ["GiB", "gibibyte", "gibibytes"]),
        (CalcUnit(.dataSize, "TiB", 8_796_093_022_208), ["TiB", "tebibyte", "tebibytes"]),
        (CalcUnit(.dataSize, "bit", 1), ["b", "bit", "bits"]),
        (CalcUnit(.dataSize, "kbit", 1000), ["Kb", "kbit", "kilobit", "kilobits"]),
        (CalcUnit(.dataSize, "Mbit", 1_000_000), ["Mb", "Mbit", "megabit", "megabits"]),
        (CalcUnit(.dataSize, "Gbit", 1_000_000_000), ["Gb", "Gbit", "gigabit", "gigabits"]),
        (CalcUnit(.dataSize, "Tbit", 1_000_000_000_000), ["Tb", "Tbit", "terabit", "terabits"]),
        (
            CalcUnit(.dataSize, "Pbit", 1_000_000_000_000_000),
            ["Pb", "Pbit", "petabit", "petabits"]
        ),
    ]

    // MARK: Finding a unit in the input

    private struct Spelling {
        var characters: [Character]
        var unit: CalcUnit
        /// Where the spelling stands among all spellings of the table.
        var tableOrder: Int
    }

    /// Every spelling of the table under the character it begins with, without regard to case.
    /// Most numbers are followed by an operator, which begins no spelling at all, and the rest
    /// by a letter that begins a handful.
    ///
    /// Each list has its longest spellings first, so that the first one found in the input is
    /// the longest one there. Spellings of one length are in the order of the table.
    private static let spellingsByFirstCharacter: [String: [Spelling]] = {
        var spellings: [Spelling] = []
        for entry in table {
            for text in entry.spellings {
                let spelling = Spelling(
                    characters: Array(text), unit: entry.unit, tableOrder: spellings.count)
                spellings.append(spelling)
            }
        }
        spellings.sort { first, second in
            if first.characters.count != second.characters.count {
                return first.characters.count > second.characters.count
            }
            return first.tableOrder < second.tableOrder
        }

        var byFirstCharacter: [String: [Spelling]] = [:]
        for spelling in spellings {
            guard let firstCharacter = spelling.characters.first else { continue }
            byFirstCharacter[firstCharacter.lowercased(), default: []].append(spelling)
        }
        return byFirstCharacter
    }()

    /// The unit written at `position`, and how many characters its spelling takes.
    ///
    /// The longest spelling wins, so "km/h" is a speed and not kilometres. A spelling counts
    /// only where no letter or digit follows it: "10 m/sqrt(4)" is metres divided by a root,
    /// not metres per second.
    static func unit(in text: [Character], at position: Int) -> (unit: CalcUnit, length: Int)? {
        guard position < text.count else { return nil }
        let firstCharacter = text[position].lowercased()
        guard let spellings = spellingsByFirstCharacter[firstCharacter] else { return nil }

        // As it is written first, and only then without regard to case.
        for ignoringCase in [false, true] {
            for spelling in spellings {
                // One letter is too little to go by without its case: the "k" of "5k * 12"
                // is not kelvin, and "M" is not a metre.
                if ignoringCase && spelling.characters.count == 1 { continue }

                let isHere = isWritten(
                    spelling.characters, in: text, at: position, ignoringCase: ignoringCase)
                if isHere {
                    return (spelling.unit, spelling.characters.count)
                }
            }
        }
        return nil
    }

    private static func isWritten(
        _ spelling: [Character], in text: [Character], at position: Int, ignoringCase: Bool
    ) -> Bool {
        let end = position + spelling.count
        if end > text.count { return false }

        for (offset, expected) in spelling.enumerated() {
            let written = text[position + offset]
            if ignoringCase {
                if written.lowercased() != expected.lowercased() { return false }
            } else if written != expected {
                return false
            }
        }

        if end < text.count {
            let next = text[end]
            // "²" is a number too, which keeps the "m" of "m²" from being taken for metres.
            if next.isLetter || next.isNumber { return false }
        }
        return true
    }

    // MARK: Converting

    /// `number` of one unit in another unit of the same quantity.
    static func convert(
        _ number: Decimal, from: CalcUnit, to: CalcUnit
    ) throws(CalcError) -> Decimal {
        // Nothing to convert, and nothing to round.
        if from == to { return number }
        if from.quantity != to.quantity { throw .incompatibleUnits }

        // To the base unit and on to the other one, with every multiplication done before the
        // one division. A division is where digits are rounded off, and with a single one a
        // conversion that has an exact answer gets it: 36 km/h is 10 m/s, 1 gal is 4 qt.
        let shifted = try CalcMath.add(number, from.offset)
        let scaledUp = try CalcMath.multiply(
            try CalcMath.multiply(shifted, from.numerator), to.denominator)
        let scaleDown = try CalcMath.multiply(from.denominator, to.numerator)
        let converted = try CalcMath.divide(scaledUp, by: scaleDown)
        return try CalcMath.subtract(converted, to.offset)
    }
}
