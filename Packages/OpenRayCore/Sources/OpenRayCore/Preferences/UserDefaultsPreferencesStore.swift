import Foundation

/// Preferences in `UserDefaults`, each stored as a native property-list value so that
/// `defaults read` shows it.
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
        do {
            return try PreferenceCoding.value(fromPropertyListObject: object)
        } catch {
            Log.storage.error(
                "Unreadable preference \(key.name, privacy: .public), using its default: \(error)")
            return key.defaultValue
        }
    }

    public func set<V>(_ value: V, for key: PreferenceKey<V>) {
        do {
            let object = try PreferenceCoding.propertyListObject(from: value)
            defaults.set(object, forKey: key.name)
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
