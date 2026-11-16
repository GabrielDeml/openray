import Foundation

/// How a preference value becomes something a store can keep, and back. Both stores code their
/// values here, so the in-memory store reads and rejects exactly what the real one does.
///
/// Preference values are stored as JSON text. JSON has a null of its own, so an optional
/// preference set to nil is stored as `null` and no string can be mistaken for it. Property
/// lists have no null: `PropertyListEncoder` writes the string "$null" in its place, and
/// `PropertyListDecoder` then refuses to read a `String` whose value is "$null".
enum PreferenceCoding {
    // JSON has no numbers for infinity and NaN. The coders write them as these strings, and
    // read them back as numbers only where the preference's type asks for a number.
    private static let positiveInfinity = "Infinity"
    private static let negativeInfinity = "-Infinity"
    private static let nan = "NaN"

    static func json<V: Encodable>(from value: V) throws -> String {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: positiveInfinity, negativeInfinity: negativeInfinity, nan: nan)
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func value<V: Decodable>(fromJSON json: String) throws -> V {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: positiveInfinity, negativeInfinity: negativeInfinity, nan: nan)
        return try decoder.decode(V.self, from: Data(json.utf8))
    }
}
