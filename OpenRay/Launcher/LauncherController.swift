import AppKit
import Carbon.HIToolbox
import OpenRayCore

/// Shows and hides the launcher panel, and connects the search field, the key monitor and the
/// model.
final class LauncherController: NSObject, NSWindowDelegate, LauncherShell, HotKeyPressHost {
    var onOpenSettings: (() -> Void)?

    private let panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: LauncherPanel.size))
    private let searchBar = SearchBarView()
    private let model: LauncherModel
    private let keyMonitor: LauncherKeyMonitor
    private let latency: FrameLatencyProbe
    private let focusRestorer: FocusRestorer
    private var displays = NSScreen.screens.map { $0.geometry }
    /// Counts every `show()`. A command's hotkey whose action ends late tells by it whether
    /// the launcher on screen is still the one that was there at the press.
    private(set) var launcherShowCount = 0

    init(model: LauncherModel, focusRestorer: FocusRestorer) {
        self.focusRestorer = focusRestorer
        self.model = model
        keyMonitor = LauncherKeyMonitor(panel: panel, searchField: searchBar.field, model: model)

        let glass = NSGlassEffectView()
        glass.cornerRadius = LauncherPanel.cornerRadius
        let bodyView = LauncherBodyHostingView(rootView: LauncherBody(model: model))
        glass.contentView = LauncherRootView(searchBar: searchBar, body: bodyView)
        panel.contentView = glass
        latency = FrameLatencyProbe(view: glass)
        super.init()

        model.shell = self
        searchBar.apply(model.searchBar)
        panel.delegate = self
        searchBar.onTextChange = { [unowned self] text in queryChanged(to: text) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Laid out now, so the first show does not pay for it.
        panel.layoutIfNeeded()
    }

    // MARK: Showing and hiding

    /// What the hotkey toggles on. A panel that is visible but no longer key cannot be typed
    /// into, so the hotkey shows it again and does not hide it.
    private var isVisibleAndKey: Bool { panel.isVisible && panel.isKeyWindow }

    /// - Parameter eventTime: When the hotkey was pressed, on the clock of
    ///   `GetCurrentEventTime()`.
    func hotKeyPressed(at eventTime: TimeInterval) {
        if !isVisibleAndKey {
            latency.begin(.hotkeyToFirstFrame, eventAge: GetCurrentEventTime() - eventTime)
        }
        toggle()
    }

    func toggle() {
        if isVisibleAndKey {
            hide()
        } else {
            show()
        }
    }

    func show() {
        launcherShowCount += 1
        focusRestorer.recordFrontmostApp()
        // `FocusRestorer` may have hidden OpenRay, which keeps its windows off screen.
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        placePanel()
        model.apply(.willShow)
        panel.makeKeyAndOrderFront(nil)
        latency.endAtNextFrame(.hotkeyToFirstFrame)
    }

    func hide() {
        // Ordering the key panel out makes it resign key, which calls this again; by then the
        // panel is no longer visible.
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        latency.cancel()
        // A Return still waiting for its results must not run an action once the panel is gone.
        model.apply(.didHide)
        // After the panel has gone: while it is key, OpenRay counts as active even though the
        // app behind it is still frontmost.
        focusRestorer.restoreIfNeeded()
    }

    private func placePanel() {
        let frame = PanelPlacement.frame(
            displays: displays, mouse: NSEvent.mouseLocation, size: LauncherPanel.size)
        panel.setFrame(frame, display: false)
    }

    @objc private func screenParametersDidChange() {
        displays = NSScreen.screens.map { $0.geometry }
        if panel.isVisible {
            placePanel()
        }
    }

    // MARK: Input

    private func queryChanged(to text: String) {
        // `NSEvent.timestamp` is on the `systemUptime` clock. An edit that no event caused is
        // measured from now.
        let now = ProcessInfo.processInfo.systemUptime
        let eventTime = NSApp.currentEvent?.timestamp ?? now
        latency.begin(.keystrokeToResults, eventAge: now - eventTime)
        model.apply(.queryChanged(text))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        keyMonitor.start()
    }

    func windowDidResignKey(_ notification: Notification) {
        keyMonitor.stop()
        hide()
    }

    // MARK: LauncherShell
    // `hide()` is part of it too; it is above, next to `show()`.

    var isLauncherVisible: Bool {
        panel.isVisible
    }

    func focusSearchField() {
        // `selectText` also makes the field first responder. With the previous query selected,
        // typing replaces it.
        searchBar.field.selectText(nil)
    }

    func setSearchFieldText(_ text: String) {
        searchBar.text = text
    }

    func setSearchBar(_ appearance: SearchBarAppearance) {
        searchBar.apply(appearance)
    }

    func openSettings() {
        // Settings is shown before the launcher goes, so that hiding finds a window to leave
        // the keyboard with and does not hand it to the previous app.
        onOpenSettings?()
        hide()
    }

    func resultsDidCommit() {
        latency.endAtNextFrame(.keystrokeToResults)
    }

    var previousApp: AppRef? {
        guard let app = focusRestorer.previousApp else { return nil }
        // Only what Core can hold: `NSRunningApplication` stays in the app target.
        return AppRef(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    // MARK: HotKeyPressHost
    // `isLauncherVisible` is the shell's, above, and `launcherShowCount` is with the
    // properties.

    var screenOnTop: ScreenRequest? {
        model.state.top.screen
    }

    func showLauncher() {
        show()
    }

    func showLauncher(on screen: ScreenRequest) {
        // `show()` starts over at root search, also when the panel was already up, so the
        // screen is the only one on the stack.
        show()
        model.apply(.push(screen))
    }

    func showLauncher(replacingQueryWith text: String) {
        show()
        model.apply(.queryChanged(text))
    }

    func hideLauncher() {
        hide()
    }

    func showHUD(_ text: String) {
        model.showHUD(text)
    }

    func makeActionContext() -> any ActionContext {
        // The context takes its `previousApp` from here, and a hotkey can be pressed when the
        // launcher was never shown over the app that is in front now. So that app is recorded
        // first: it is the one a window command moves and a snippet is pasted into. With a
        // window of OpenRay in front, such as Settings, the app recorded before it is kept.
        focusRestorer.recordFrontmostApp()
        return model.makeHotKeyActionContext()
    }
}
