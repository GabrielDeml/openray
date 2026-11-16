import Observation

/// What views and main-actor code read and write. Reading a preference inside an observation
/// scope (a SwiftUI body) re-runs that scope when a preference is written through this object.
@MainActor @Observable public final class Preferences {
    private let store: any PreferencesStore
    /// Stands in for the stored values in observation: read by every get, bumped by every set.
    private var revision = 0

    public init(store: any PreferencesStore) {
        self.store = store
    }

    public subscript<V>(key: PreferenceKey<V>) -> V {
        get {
            _ = revision
            return store.value(for: key)
        }
        set {
            store.set(newValue, for: key)
            // It only has to change, so it may wrap.
            revision &+= 1
        }
    }
}
