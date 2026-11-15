import AppKit

/// Gives the keyboard back to the app OpenRay was used over.
///
/// The panel does not activate OpenRay, so usually that app is still frontmost when the launcher
/// goes and there is nothing to do. OpenRay itself is frontmost only after one of its own
/// windows was used, such as Settings.
final class FocusRestorer {
    /// The app that was frontmost when OpenRay last showed the launcher over it or took
    /// activation from it.
    private(set) var previousApp: NSRunningApplication?

    /// Call before showing the launcher and before activating OpenRay. When OpenRay is already
    /// frontmost, the app recorded earlier is kept.
    func recordFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != .current {
            previousApp = app
        }
    }

    /// Call after the launcher or the Settings window has left the screen. Does nothing unless
    /// OpenRay is the active app with no window left to take the keyboard, a state in which
    /// typing would go nowhere.
    func restoreIfNeeded() {
        guard NSApp.isActive else { return }
        let hasWindowForKeyboard = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        guard !hasWindowForKeyboard else { return }

        if let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            let activated = previousApp.activate(from: .current, options: [])
            if activated { return }
        }
        // There is no app to go back to, or it would not activate. Hiding OpenRay lets the
        // system choose the next app.
        NSApp.hide(nil)
    }
}
