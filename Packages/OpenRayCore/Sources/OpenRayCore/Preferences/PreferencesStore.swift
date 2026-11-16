/// Names one preference and gives its value when nothing is stored.
public struct PreferenceKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(name: String, defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Where preferences are kept. Safe to use from any thread.
public protocol PreferencesStore: Sendable {
    /// The stored value, or the key's default when nothing readable is stored.
    func value<V>(for key: PreferenceKey<V>) -> V
    func set<V>(_ value: V, for key: PreferenceKey<V>)
    /// The current value, then the new value after every `set` on this store. For code off the
    /// main actor; views read `Preferences`.
    func changes<V>(for key: PreferenceKey<V>) -> AsyncStream<V>
}
