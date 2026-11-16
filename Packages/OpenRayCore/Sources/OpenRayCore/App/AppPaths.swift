import Foundation

/// Where OpenRay keeps its files. Every path derives from the bundle identifier.
public struct AppPaths: Sendable, Equatable {
    /// `<Application Support>/<bundle id>/`: the root of everything OpenRay stores on disk.
    public let applicationSupportDirectory: URL

    /// - Parameter applicationSupportRoot: The user's Application Support directory; tests pass a
    ///   temporary directory.
    public init(
        bundleIdentifier: String = AppInfo.bundleIdentifier,
        applicationSupportRoot: URL = .applicationSupportDirectory
    ) {
        applicationSupportDirectory = applicationSupportRoot.appending(
            path: bundleIdentifier, directoryHint: .isDirectory)
    }

    /// The folder scripts are read from before any the user adds (docs/DESIGN.md §4.10).
    public var scriptsDirectory: URL {
        applicationSupportDirectory.appending(path: "Scripts", directoryHint: .isDirectory)
    }
}
