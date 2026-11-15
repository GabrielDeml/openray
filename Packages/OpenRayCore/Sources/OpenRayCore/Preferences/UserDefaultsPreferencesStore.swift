import Foundation

/// Preferences in `UserDefaults`, each stored as a string of JSON, which `defaults read` shows
/// as it is.
///
/// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe, but the SDK marks its
/// `Sendable` conformance unavailable.
public final class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let observers = PreferenceObservers()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func value<V>(for key: PreferenceKey<V>) -> V {
        guard let object = defaults.object(forKey: key.name) else { return key.defaultValue }
        // Anything but a string was not written by this store.
        guard let json = object as? String else {
            Log.storage.error(
                "Preference \(key.name, privacy: .public) is not stored as JSON, using its default")
            return key.defaultValue
        }
        do {
            return try PreferenceCoding.value(fromJSON: json)
        } catch {
            Log.storage.error(
                "Unreadable preference \(key.name, privacy: .public), using its default: \(error)")
            return key.defaultValue
        }
    }

    public func set<V>(_ value: V, for key: PreferenceKey<V>) {
        do {
            let json = try PreferenceCoding.json(from: value)
            defaults.set(json, forKey: key.name)
        } catch {
            Log.storage.error("Cannot store preference \(key.name, privacy: .public): \(error)")
            return
        }
        observers.notify(key.name)
    }

    public func changes<V>(for key: PreferenceKey<V>) -> AsyncStream<V> {
        observers.stream(name: key.name) { self.value(for: key) }
    }
}
