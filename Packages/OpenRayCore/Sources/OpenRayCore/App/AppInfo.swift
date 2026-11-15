import Foundation

/// Facts about the app that both the UI and the core logic need.
public enum AppInfo {
    public static let name = "OpenRay"

    /// The running bundle's identifier. Debug and Release builds have different identifiers, so
    /// everything derived from this value (data directory, defaults domain, log subsystem) is
    /// separate per build configuration. A process without a bundle identifier, such as a
    /// `swift test` run, falls back to its process name.
    public static let bundleIdentifier =
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
}
