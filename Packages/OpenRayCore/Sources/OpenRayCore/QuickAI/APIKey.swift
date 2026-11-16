/// A provider's API key (docs/DESIGN.md §4.6.5).
///
/// The key is wrapped so that it cannot end up in a log line, an error message or a debugger
/// dump by accident: every way of printing the value prints the same redacted text.
public struct APIKey: Sendable {
    private static let redactedText = "sk-ant-…<redacted>"

    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The key itself, for the request header. Nothing else may read it.
    var headerValue: String { value }

    /// Whether this is an Admin API key. Those manage an organisation and cannot ask a model
    /// anything, so Settings warns about one before it is saved.
    public var isAdminKey: Bool {
        value.hasPrefix("sk-ant-admin")
    }
}

extension APIKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { Self.redactedText }

    public var debugDescription: String { Self.redactedText }

    /// A mirror without children, so that `dump` and the debugger have no stored property to
    /// show.
    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
