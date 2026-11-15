import os

/// One `Logger` per subsystem category. Interpolated values are private unless marked otherwise.
public enum Log {
    public static let launcher = Logger(subsystem: AppInfo.bundleIdentifier, category: "launcher")
    public static let storage = Logger(subsystem: AppInfo.bundleIdentifier, category: "storage")
}

/// The app's single signposter and the names of its intervals, viewed in Instruments against the
/// latency budget.
public enum Signposts {
    public static let signposter = OSSignposter(
        subsystem: AppInfo.bundleIdentifier, category: .pointsOfInterest)

    /// From the hotkey event to the first frame of the panel on screen.
    public static let hotkeyToFirstFrame: StaticString = "hotkeyToFirstFrame"
    /// From a keystroke in the search field to its results being drawn.
    public static let keystrokeToResults: StaticString = "keystrokeToResults"
}
