import Synchronization

/// A store that forgets everything when it goes away, for tests and previews. It encodes values
/// exactly as `UserDefaultsPreferencesStore` does.
public final class InMemoryPreferencesStore: PreferencesStore {
    private let storage = Mutex<[String: String]>([:])
    private let observers = PreferenceObservers()

    public init() {}

    public func value<V>(for key: PreferenceKey<V>) -> V {
        let json = storage.withLock { stored in stored[key.name] }
        guard let json else { return key.defaultValue }
        do {
            return try PreferenceCoding.value(fromJSON: json)
        } catch {
            // As in the real store, a value that cannot be read gives the default.
            return key.defaultValue
        }
    }

    public func set<V>(_ value: V, for key: PreferenceKey<V>) {
        // A value that cannot be encoded leaves `json` nil, and storing nil removes the entry,
        // so the preference reads as its default again.
        let json = try? PreferenceCoding.json(from: value)
        storage.withLock { stored in stored[key.name] = json }
        observers.notify(key.name)
    }

    public func changes<V>(for key: PreferenceKey<V>) -> AsyncStream<V> {
        observers.stream(name: key.name) { self.value(for: key) }
    }
}
