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

    /// The running bundle's version as people say it, such as "0.1.0"
    /// (`CFBundleShortVersionString`). nil for a process that has none.
    public static let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// The running bundle's build number (`CFBundleVersion`), which goes up with every release
    /// and is what the updater compares.
    public static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    /// The version as Settings › About shows it: "0.1.0 (123)".
    public static func versionLine(version: String?, build: String?) -> String {
        guard let version else {
            return String(
                localized: "Unknown version", bundle: .module,
                comment: "Shown in place of the version number when the app has none.")
        }
        guard let build else { return version }
        return "\(version) (\(build))"
    }
}
