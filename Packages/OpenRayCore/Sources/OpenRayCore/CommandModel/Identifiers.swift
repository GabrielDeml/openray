import Foundation

/// Identifies one item across launches. The raw value is `<namespace>:<local>` and is stored in
/// the usage, alias and override tables, so its format never changes.
public struct ItemID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public enum Namespace: String, Sendable, CaseIterable {
        case app, system, command, quicklink, script, file, clip, snippet
    }

    public init(_ namespace: Namespace, _ local: String) {
        rawValue = "\(namespace.rawValue):\(local)"
    }

    /// `nil` when the raw value does not start with a known namespace.
    public var namespace: Namespace? {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        return Namespace(rawValue: String(rawValue[..<colon]))
    }

    /// Everything after the namespace. Local parts may themselves contain colons.
    public var local: String {
        guard let colon = rawValue.firstIndex(of: ":") else { return "" }
        let afterColon = rawValue.index(after: colon)
        return String(rawValue[afterColon...])
    }
}

extension ItemID {
    /// The copy of an app that owns its bundle identifier.
    public static func app(bundleID: String) -> ItemID { ItemID(.app, bundleID) }

    /// An app without a bundle identifier, or a further copy of one that is already indexed.
    public static func app(path: String) -> ItemID { ItemID(.app, "path:\(path)") }

    public static func system(_ name: String) -> ItemID { ItemID(.system, name) }

    /// A feature's entry point or fixed command, such as `command:clipboard.history`.
    public static func command(_ feature: FeatureID, _ name: String) -> ItemID {
        ItemID(.command, "\(feature.rawValue).\(name)")
    }

    public static func quicklink(_ id: UUID) -> ItemID { ItemID(.quicklink, id.uuidString) }

    public static func script(path: String) -> ItemID { ItemID(.script, path) }

    public static func file(path: String) -> ItemID { ItemID(.file, path) }

    /// - Parameter rowID: The row ID in `clip_item`.
    public static func clip(rowID: Int64) -> ItemID { ItemID(.clip, String(rowID)) }

    public static func snippet(_ id: UUID) -> ItemID { ItemID(.snippet, id.uuidString) }
}

/// Identifies an action among the actions of one item or screen.
public struct ActionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct FeatureID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct SourceID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
