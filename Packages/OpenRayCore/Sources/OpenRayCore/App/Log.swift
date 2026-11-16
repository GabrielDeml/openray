import os

/// One `Logger` per subsystem category. Interpolated values are private unless marked otherwise.
public enum Log {
    public static let launcher = Logger(subsystem: AppInfo.bundleIdentifier, category: "launcher")
    public static let search = Logger(subsystem: AppInfo.bundleIdentifier, category: "search")
    public static let storage = Logger(subsystem: AppInfo.bundleIdentifier, category: "storage")
    public static let permissions = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "permissions")
    /// Quick AI. A request's ID and how it ended are logged; keys, questions and replies never
    /// are.
    public static let ai = Logger(subsystem: AppInfo.bundleIdentifier, category: "ai")
    /// The updater. Sparkle logs its own work under its own subsystem; this is what OpenRay
    /// has to say about it.
    public static let updates = Logger(subsystem: AppInfo.bundleIdentifier, category: "updates")
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
    /// Building one `IndexSnapshot` from the items of every source.
    public static let indexBuild: StaticString = "indexBuild"
    /// One read or write of a database, from the request to its answer. The interval's message
    /// names the query.
    public static let dbQuery: StaticString = "dbQuery"
}
