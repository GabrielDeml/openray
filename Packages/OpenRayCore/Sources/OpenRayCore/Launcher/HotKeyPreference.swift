extension PreferenceKey where Value == HotKey {
    /// The global hotkey that shows and hides the launcher.
    public static var launcherHotKey: PreferenceKey {
        PreferenceKey(name: "launcher.hotKey", defaultValue: .launcherDefault)
    }
}

extension Preferences {
    public var launcherHotKey: HotKey {
        get { self[.launcherHotKey] }
        set { self[.launcherHotKey] = newValue }
    }
}
