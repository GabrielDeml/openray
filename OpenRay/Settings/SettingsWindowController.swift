import AppKit
import Observation
import OpenRayCore
import SwiftUI

/// The settings window. Hand-built rather than a SwiftUI `Settings` scene, which AppKit code
/// cannot open and which does not activate an accessory app.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation: SettingsNavigation
    private let focusRestorer: FocusRestorer

    init(panes: [SettingsPane], focusRestorer: FocusRestorer) {
        self.focusRestorer = focusRestorer
        let sortedPanes = panes.sorted { $0.order < $1.order }
        navigation = SettingsNavigation(selection: sortedPanes.first?.id)
        let content = SettingsView(panes: sortedPanes, navigation: navigation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = String(localized: "\(AppInfo.name) Settings")
        window.setContentSize(NSSize(width: 660, height: 420))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Brings the window to the front, on `pane` if given. OpenRay stays an accessory app.
    func show(pane: SettingsPane.ID? = nil) {
        if let pane {
            navigation.selection = pane
        }
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

/// Which pane the settings window shows.
@Observable
final class SettingsNavigation {
    var selection: SettingsPane.ID?

    init(selection: SettingsPane.ID?) {
        self.selection = selection
    }
}
