/// An app that is running, as the Quit commands list it.
public struct RunningApp: Sendable, Hashable {
    public var bundleID: String
    /// The name the app shows in the Dock and the app switcher.
    public var name: String
    /// Where the app's bundle is, for its icon. nil when the system does not say.
    public var bundlePath: String?

    public init(bundleID: String, name: String, bundlePath: String?) {
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// What the system commands do to the Mac, one method per command (docs/DESIGN.md §4.2.10).
/// The app target implements it with IOKit, Apple events and `NSRunningApplication`; tests put
/// a fake in its place, so that no test ever puts the Mac to sleep.
@MainActor public protocol SystemControl: AnyObject, Sendable {
    func sleep() throws
    func restart() async throws
    func shutDown() async throws
    func logOut() async throws
    func emptyTrash() async throws
    /// Switches between the light and the dark appearance.
    func toggleAppearance() async throws

    /// The regular apps that are running: the list as it is now, and again after every launch
    /// and every quit. OpenRay itself is not among them.
    func runningApps() -> AsyncStream<[RunningApp]>
    /// Asks every running copy of the app to quit. The app may refuse, to ask about unsaved
    /// changes for one.
    func quit(_ app: RunningApp)
    func forceQuit(_ app: RunningApp)
    /// Asks every regular app to quit, except Finder and OpenRay.
    func quitAllApps()
}
