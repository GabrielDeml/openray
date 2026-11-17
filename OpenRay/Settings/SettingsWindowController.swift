import AppKit
import Observation
import OpenRayCore
import SwiftUI

/// A window of OpenRay that takes the keyboard: Settings and onboarding. OpenRay is an
/// accessory app, so bringing such a window to the front takes more than ordering it front,
/// and closing it has to give the keyboard back to the app the user came from.
class ActivatingWindowController: NSWindowController, NSWindowDelegate {
    private let focusRestorer: FocusRestorer

    init(window: NSWindow, focusRestorer: FocusRestorer) {
        self.focusRestorer = focusRestorer
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Brings the window to the front. OpenRay stays an accessory app.
    func showAndActivate() {
        // Before activating: afterwards OpenRay itself is the frontmost app.
        focusRestorer.recordFrontmostApp()
        activate()
        // `NSApp.activate()` is documented as not guaranteed: try once more a turn later, unless
        // another window of OpenRay, such as the launcher, has taken the keyboard since.
        Task {
            let hasKeyWindow = NSApp.windows.contains(where: \.isKeyWindow)
            if !hasKeyWindow {
                activate()
            }
        }
    }

    private func activate() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the last window leaves OpenRay the active app, with nowhere for typing to go.
        // A turn later, because the window is still on screen now.
        Task { focusRestorer.restoreIfNeeded() }
    }
}

/// The settings window. Hand-built rather than a SwiftUI `Settings` scene, which AppKit code
/// cannot open and which does not activate an accessory app.
final class SettingsWindowController: ActivatingWindowController {
    private let navigation: SettingsNavigation

    init(panes: [SettingsPane], focusRestorer: FocusRestorer) {
        let sortedPanes = panes.sorted { $0.order < $1.order }
        navigation = SettingsNavigation(selection: sortedPanes.first?.id)
        let content = SettingsView(panes: sortedPanes, navigation: navigation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = String(localized: "\(AppInfo.name) Settings")
        // Wide enough for a row of Settings › Commands, which has the most in one line: the
        // title, the alias field, the hotkey recorder and two switches.
        window.setContentSize(NSSize(width: 800, height: 420))
        window.center()
        super.init(window: window, focusRestorer: focusRestorer)
    }

    /// Brings the window to the front, on `pane` if given.
    func show(pane: SettingsPane.ID? = nil) {
        if let pane {
            navigation.selection = pane
        }
        showAndActivate()
    }
}

/// Which pane the settings window shows.
@Observable
final class SettingsNavigation {
    var selection: SettingsPane.ID?

    init(selection: SettingsPane.ID?) {
        self.selection = selection
    }
}
