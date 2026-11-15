import Foundation

/// How a preference value becomes something a store can keep, and back. Both stores code their
/// values here, so the in-memory store reads and rejects exactly what the real one does.
///
/// Preference values are stored as property lists. A property list needs a container at the top
/// level, so a value is coded inside a one-element array. That array never leaves this file.
enum PreferenceCoding {
    static func data<V: Encodable>(from value: V) throws -> Data {
        try PropertyListEncoder().encode([value])
    }

    static func value<V: Decodable>(from data: Data) throws -> V {
        let boxed = try PropertyListDecoder().decode([V].self, from: data)
        guard let value = boxed.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Empty preference container"))
        }
        return value
    }

    /// The value as `UserDefaults` takes it: a plain number, string, array or dictionary rather
    /// than encoded data.
    static func propertyListObject<V: Encodable>(from value: V) throws -> Any? {
        let data = try data(from: value)
        let boxed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (boxed as? [Any])?.first
    }

    /// - Parameter object: What `UserDefaults.object(forKey:)` returned.
    static func value<V: Decodable>(fromPropertyListObject object: Any) throws -> V {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [object], format: .binary, options: 0)
        return try value(from: data)
    }
}
