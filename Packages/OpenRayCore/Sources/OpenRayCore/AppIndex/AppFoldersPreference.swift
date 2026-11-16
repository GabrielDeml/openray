extension PreferenceKey where Value == [String] {
    /// Folders the user has added to the ones apps are searched in, as absolute paths.
    public static var appFolders: PreferenceKey {
        PreferenceKey(name: "apps.folders", defaultValue: [])
    }
}

extension Preferences {
    public var appFolders: [String] {
        get { self[.appFolders] }
        set { self[.appFolders] = newValue }
    }
}
