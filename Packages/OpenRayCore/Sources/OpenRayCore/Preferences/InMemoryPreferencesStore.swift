import Foundation
import Synchronization

/// A store that forgets everything when it goes away, for tests and previews. It encodes values
/// exactly as `UserDefaultsPreferencesStore` does.
public final class InMemoryPreferencesStore: PreferencesStore {
    private let storage = Mutex<[String: Data]>([:])
    private let observers = PreferenceObservers()

    public init() {}

    public func value<V>(for key: PreferenceKey<V>) -> V {
        let data = storage.withLock { stored in stored[key.name] }
        guard let data else { return key.defaultValue }
        do {
            return try PreferenceCoding.value(from: data)
        } catch {
            // As in the real store, a value that cannot be read gives the default.
            return key.defaultValue
        }
    }

    public func set<V>(_ value: V, for key: PreferenceKey<V>) {
        // A value that cannot be encoded leaves `data` nil, and storing nil removes the entry,
        // so the preference reads as its default again.
        let data = try? PreferenceCoding.data(from: value)
        storage.withLock { stored in stored[key.name] = data }
        observers.notify(key.name)
    }

    public func changes<V>(for key: PreferenceKey<V>) -> AsyncStream<V> {
        observers.stream(name: key.name) { self.value(for: key) }
    }
}
