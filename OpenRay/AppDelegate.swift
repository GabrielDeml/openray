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
    // Windows cannot be created before the application has launched.
    private lazy var launcher = LauncherController(
        source: FakeSearchSource(), focusRestorer: focusRestorer)
    private lazy var settings = SettingsWindowController(
        panes: [.general(hotKey: launcherHotKey)], focusRestorer: focusRestorer)

    override init() {
        launcherHotKey = LauncherHotKey(registrar: hotKeys, preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        launcher.onOpenSettings = { [unowned self] in showSettings() }
        hotKeys.onPress = { [unowned self] _, eventTime in launcher.hotKeyPressed(at: eventTime) }

        launcherHotKey.registerAtLaunch()
        if !launcherHotKey.isActive {
            showSettings(pane: SettingsPane.generalID)
        }
        if ProcessInfo.processInfo.arguments.contains(Self.showPanelOnLaunchArgument) {
            launcher.show()
        }
    }

    func showSettings(pane: SettingsPane.ID? = nil) {
        settings.show(pane: pane)
    }
}
