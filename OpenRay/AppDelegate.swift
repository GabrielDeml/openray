import AppKit
import OpenRayCore

/// The composition root: builds every long-lived object and connects them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shows the launcher as soon as the app has launched, without the hotkey. For UI tests.
    private static let showPanelOnLaunchArgument = "-OpenRayShowPanelOnLaunch"

    let launcherHotKey: LauncherHotKey

    private let hotKeys = HotKeyCenter()
    private let preferencesStore = UserDefaultsPreferencesStore(defaults: .standard)
    private let preferences: Preferences
    private let loginItem: LoginItemModel
    /// Shared, so that the launcher returns to the app Settings was opened over.
    private let focusRestorer = FocusRestorer()

    // Everything below is built a moment after launch, in `compose`, once the database is
    // open: search ranks by the usage in it and the commands read their overrides from it.
    // Until then a hotkey press does nothing, and a request for Settings is remembered.
    private var features: [any Feature] = []
    private var registry: CommandRegistry?
    private var launcher: LauncherController?
    private var settings: SettingsWindowController?
    private var commandsSettings: CommandsSettingsModel?
    /// Only while the onboarding window is open.
    private var onboarding: OnboardingWindowController?
    private var onboardingModel: OnboardingModel?

    /// Whether Settings was asked for before it existed, and on which pane.
    private var wantsSettingsOnceComposed = false
    private var paneWantedOnceComposed: SettingsPane.ID?

    #if DEBUG
        /// Only in a run that was started for the pasteboard privacy experiment.
        private var pasteboardProbe: PasteboardProbeWindowController?
    #endif

    override init() {
        preferences = Preferences(store: preferencesStore)
        launcherHotKey = LauncherHotKey(registrar: hotKeys, preferences: preferences)
        // A Debug build's login item would point into the build folder, so its switch is
        // shown but does nothing (docs/DESIGN.md §4.3.6).
        #if DEBUG
            let canChangeLoginItem = false
        #else
            let canChangeLoginItem = true
        #endif
        loginItem = LoginItemModel(
            controller: SMAppServiceLoginItem(), canChange: canChangeLoginItem)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(appDelegate: self)

        #if DEBUG
            // The pasteboard privacy experiment (docs/DESIGN.md §4.5). Such a run is the probe
            // window and nothing else: no hotkey, no database and no launcher, so that it
            // neither gets in the way of a copy of OpenRay that is in use nor touches the
            // pasteboard by any other path than the probe's buttons.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(PasteboardProbeWindowController.launchArgument) {
                let probe = PasteboardProbeWindowController()
                pasteboardProbe = probe
                probe.show()
                return
            }
        #endif

        hotKeys.onPress = { [unowned self] _, eventTime in hotKeyPressed(at: eventTime) }
        launcherHotKey.registerAtLaunch()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Opening the database works on the disk, so that happens off the main actor and the
        // rest is built when it is done.
        Task {
            let storage = await openStorage()
            compose(with: storage)
            showFirstWindows()
        }
    }

    // MARK: Composition

    private func compose(with storage: Storage) {
        let commands = CommandStore(database: storage.database)
        let permissions = PermissionCenter()
        let workspace = WorkspaceActions()
        let hud = HUDController()

        // Read through `self`, because the features get the closure before the registry exists.
        let currentItems: @MainActor @Sendable () -> [SearchItem] = { [weak self] in
            self?.registry?.items ?? []
        }

        let features = BuiltInFeatures.make()
        let env = FeatureEnvironment(
            database: storage.database,
            usage: storage.usage,
            commands: commands,
            preferences: preferences,
            preferencesStore: preferencesStore,
            permissions: permissions,
            secrets: KeychainSecretStore(),
            system: MacSystemControl(appleEvents: AppleEventSender()),
            workspace: workspace,
            currentItems: currentItems,
            showSettings: { [weak self] pane in self?.showSettings(pane: pane) })

        // The features are all the launcher knows about commands: their sources feed search,
        // and their screens and panes are found through them.
        var sources: [any SearchSource] = []
        for feature in features {
            sources.append(contentsOf: feature.makeSources(env))
        }
        let registry = CommandRegistry(sources: sources, commands: commands)
        let search = SearchSession(registry: registry, usage: storage.usage, now: { Date() })
        let pasteHost = MacPasteHost(focusRestorer: focusRestorer, hud: hud)
        let pasteService = PasteService(
            host: pasteHost, permissions: permissions, preferences: preferences)
        // The first feature that has one decides what Tab opens for a query.
        var tabFallback: ScreenRequest?
        for feature in features {
            if let request = feature.tabFallback {
                tabFallback = request
                break
            }
        }
        let model = LauncherModel(
            search: search, usage: storage.usage,
            screenRegistry: ScreenRegistry(features: features, env: env),
            permissions: permissions, hud: hud, pasteService: pasteService,
            tabFallback: tabFallback)
        let launcher = LauncherController(model: model, focusRestorer: focusRestorer)
        launcher.onOpenSettings = { [unowned self] in showSettings() }
        pasteHost.launcher = launcher

        let commandsSettings = CommandsSettingsModel(
            commands: commands, currentItems: currentItems)
        let permissionList = PermissionListModel(checker: permissions, currentItems: currentItems)
        var panes: [SettingsPane] = [
            .general(hotKey: launcherHotKey, loginItem: loginItem, permissions: permissionList),
            .commands(model: commandsSettings),
        ]
        for feature in features {
            if let pane = feature.settingsPane(env) {
                panes.append(pane)
            }
        }
        workspace.onShowAliasSettings = { [unowned self] item in showAliasSettings(for: item) }

        self.features = features
        self.registry = registry
        self.launcher = launcher
        self.commandsSettings = commandsSettings
        settings = SettingsWindowController(panes: panes, focusRestorer: focusRestorer)

        if let notice = storage.notice {
            hud.show(notice)
        }
    }

    /// What the user has to see right after launch: onboarding the first time, or Settings
    /// when the hotkey needs attention.
    private func showFirstWindows() {
        let needsOnboarding = OnboardingModel.isNeeded(
            completedVersion: preferences.onboardingCompletedVersion)
        if needsOnboarding {
            // Onboarding has the hotkey recorder too, so a hotkey that failed is dealt with
            // there.
            showOnboarding()
        } else if !launcherHotKey.isActive || launcherHotKey.usesFallback {
            // The fallback works, but nobody would guess it: the General pane says which chord
            // opens the launcher and why.
            showSettings(pane: SettingsPane.generalID)
        }

        if wantsSettingsOnceComposed {
            showSettings(pane: paneWantedOnceComposed)
        }
        if ProcessInfo.processInfo.arguments.contains(Self.showPanelOnLaunchArgument) {
            launcher?.show()
        }
    }

    // MARK: Windows

    func showSettings(pane: SettingsPane.ID? = nil) {
        guard let settings else {
            // Asked for in the moment before the database was open.
            wantsSettingsOnceComposed = true
            paneWantedOnceComposed = pane
            return
        }
        settings.show(pane: pane)
    }

    /// "Add Alias…" in the launcher: Settings › Commands, on that item.
    private func showAliasSettings(for item: ItemID) {
        commandsSettings?.focus(on: item)
        showSettings(pane: SettingsPane.commandsID)
    }

    private func showOnboarding() {
        let model = OnboardingModel(preferences: preferences, loginItem: loginItem)
        let window = OnboardingWindowController(
            model: model, hotKey: launcherHotKey, loginItem: loginItem,
            focusRestorer: focusRestorer)
        onboardingModel = model
        onboarding = window
        window.showAndActivate()
    }

    private func hotKeyPressed(at eventTime: TimeInterval) {
        // While onboarding asks the user to try the hotkey, the press is the answer to that
        // and does not open the launcher.
        if let onboardingModel, onboardingModel.hotKeyPressed() { return }
        launcher?.hotKeyPressed(at: eventTime)
    }

    @objc private func didWake() {
        for feature in features {
            feature.systemDidWake()
        }
    }
}

/// What `openStorage` hands to the composition.
private struct Storage {
    let database: AppDatabase
    let usage: any UsageStore
    /// What to tell the user about the database, when it is not the one they had.
    let notice: String?
}

/// Opens the app's database and the usage store on it (docs/DESIGN.md §3.2, §4.3.8).
///
/// A database that cannot be used at all is replaced by one in memory for this run, so that
/// search, quicklinks and the settings still work; nothing is kept when OpenRay quits.
@concurrent
private func openStorage() async -> Storage {
    var notice: String?
    var database: AppDatabase
    do {
        database = try AppDatabase.openOnDisk(at: AppPaths().applicationSupportDirectory)
        if database.wasReplaced {
            notice = String(
                localized: "OpenRay's data could not be read and was reset. The old file was kept.")
        }
    } catch {
        Log.storage.error("The database did not open, so nothing is stored: \(error)")
        notice = String(localized: "OpenRay cannot store its data. Changes last until it quits.")
        database = temporaryDatabase()
    }

    do {
        let usage = try await SQLiteUsageStore(database: database)
        return Storage(database: database, usage: usage, notice: notice)
    } catch {
        // The commands still have their tables; only the picks are counted in memory.
        Log.storage.error("The usage did not load, so picks are not stored: \(error)")
        return Storage(database: database, usage: InMemoryUsageStore(), notice: notice)
    }
}

private nonisolated func temporaryDatabase() -> AppDatabase {
    do {
        return try AppDatabase.inMemory()
    } catch {
        // SQLite cannot even work in memory. Nothing in OpenRay runs without it.
        fatalError("Cannot open a database in memory: \(error)")
    }
}
