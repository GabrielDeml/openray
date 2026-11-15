import AppKit
import OpenRayCore

/// The composition root: builds every long-lived object and connects them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shows the launcher as soon as the app has launched, without the hotkey. For UI tests.
    private static let showPanelOnLaunchArgument = "-OpenRayShowPanelOnLaunch"

    let launcherHotKey: LauncherHotKey

    private let hotKeys = HotKeyCenter()
    private let preferences = Preferences(store: UserDefaultsPreferencesStore(defaults: .standard))
    /// Shared, so that the launcher returns to the app Settings was opened over.
    private let focusRestorer = FocusRestorer()
    /// Built a moment after launch, when the usage store is open. A hotkey pressed before that
    /// does nothing.
    private var launcher: LauncherController?
    /// Kept so that it can be told to read the app folders again.
    private var appIndex: AppIndexSource?
    // Windows cannot be created before the application has launched.
    private lazy var settings = SettingsWindowController(
        panes: [.general(hotKey: launcherHotKey)], focusRestorer: focusRestorer)

    override init() {
        launcherHotKey = LauncherHotKey(registrar: hotKeys, preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(appDelegate: self)
        hotKeys.onPress = { [unowned self] _, eventTime in launcher?.hotKeyPressed(at: eventTime) }

        launcherHotKey.registerAtLaunch()
        // The fallback works, but nobody would guess it: the General pane says which chord opens
        // the launcher and why.
        if !launcherHotKey.isActive || launcherHotKey.usesFallback {
            showSettings(pane: SettingsPane.generalID)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Search ranks by usage, and the usage is in the database. Opening it works on the disk,
        // so that happens off the main actor and the launcher is built when it is done.
        Task {
            let usage = await openUsageStore()
            makeLauncher(usage: usage)
            if ProcessInfo.processInfo.arguments.contains(Self.showPanelOnLaunchArgument) {
                launcher?.show()
            }
        }
    }

    func showSettings(pane: SettingsPane.ID? = nil) {
        settings.show(pane: pane)
    }

    private func makeLauncher(usage: any UsageStore) {
        // The apps are the only source so far. Milestone 3 puts the sources of the built-in
        // features here.
        let appIndex = AppIndexSource(openApp: openApp(at:))
        let registry = CommandRegistry(sources: [appIndex])
        let search = SearchSession(registry: registry, usage: usage, now: { Date() })

        let launcher = LauncherController(
            search: search, usage: usage, focusRestorer: focusRestorer)
        launcher.onOpenSettings = { [unowned self] in showSettings() }

        self.appIndex = appIndex
        self.launcher = launcher
    }

    @objc private func didWake() {
        // Nothing reports what changed in the app folders while the Mac was asleep. Before the
        // launcher is built there is no index yet, and its first scan is still to come.
        appIndex?.rescan()
    }
}

/// Opens the usage store on the app's database. When the database cannot be opened, picks are
/// counted in memory for this run only, and search works all the same (docs/DESIGN.md §4.2.11).
@concurrent
private func openUsageStore() async -> any UsageStore {
    do {
        let database = try AppDatabase.openOnDisk(at: AppPaths().applicationSupportDirectory)
        return try await SQLiteUsageStore(database: database)
    } catch {
        Log.storage.error("The database did not open, so usage is not stored: \(error)")
        return InMemoryUsageStore()
    }
}

/// Opens the app at `url`, or brings it to the front when it is already running. This is what
/// the app index calls for its Open action; Core cannot use `NSWorkspace` itself.
private func openApp(at url: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
}
