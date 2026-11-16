extension PreferenceKey where Value == Double {
    /// The space the window commands leave around a window and between two of them, in
    /// points. 0 puts windows edge to edge.
    public static var windowGap: PreferenceKey {
        PreferenceKey(name: "windows.gap", defaultValue: 0)
    }

    /// How much of a display's width the window commands leave free for Stage Manager's strip
    /// of recent apps, in points. It counts only while Stage Manager is on.
    public static var windowStageStripInset: PreferenceKey {
        PreferenceKey(name: "windows.stageStripInset", defaultValue: 0)
    }
}

extension Preferences {
    public var windowGap: Double {
        get { self[.windowGap] }
        set { self[.windowGap] = newValue }
    }

    public var windowStageStripInset: Double {
        get { self[.windowStageStripInset] }
        set { self[.windowStageStripInset] = newValue }
    }
}
