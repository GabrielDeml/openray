import AppKit

/// Gives the keyboard back to the app OpenRay was used over.
///
/// The panel does not activate OpenRay, so usually that app is still frontmost when the launcher
/// goes and there is nothing to do. OpenRay itself is frontmost only after one of its own
/// windows was used, such as Settings.
final class FocusRestorer {
    /// How long `restore()` waits for the previous app to come forward.
    private static let activationTimeout: Duration = .milliseconds(300)
    private static let activationCheckInterval: Duration = .milliseconds(10)

    /// The app that was frontmost when OpenRay last showed the launcher over it, took
    /// activation from it, or ran a command for a hotkey pressed in it.
    private(set) var previousApp: NSRunningApplication?

    /// Call before showing the launcher, before activating OpenRay, and before making the
    /// context of an action that a hotkey started. When OpenRay is already frontmost, the app
    /// recorded earlier is kept.
    func recordFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != .current {
            previousApp = app
        }
    }

    /// Call after the launcher or the Settings window has left the screen. Does nothing unless
    /// OpenRay is the active app with no window left to take the keyboard, a state in which
    /// typing would go nowhere. It does not wait for the previous app, and when that app will
    /// not come forward it hides OpenRay, so that some app gets the keyboard.
    func restoreIfNeeded() {
        guard NSApp.isActive else { return }
        let hasWindowForKeyboard = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        guard !hasWindowForKeyboard else { return }

        if let previousApp, !previousApp.isTerminated {
            let activated = handActivation(to: previousApp)
            if activated { return }
        }
        // There is no app to go back to, or it would not activate. Hiding OpenRay lets the
        // system choose the next app.
        NSApp.hide(nil)
    }

    /// Brings the previous app to the front and waits until it is there. For a paste, whose
    /// ⌘V must not be typed before the app it is meant for can take it.
    ///
    /// Unlike `restoreIfNeeded()` this is about one particular app: it says whether that app
    /// is frontmost in the end, and has no fallback when it is not.
    ///
    /// - Returns: false when the app has quit, or has not come forward in time.
    func restore() async -> Bool {
        guard let previousApp, !previousApp.isTerminated else { return false }
        if isFrontmost(previousApp) { return true }

        let activated = handActivation(to: previousApp)
        if !activated { return false }

        // Activation happens a moment later and has no completion handler. The workspace's
        // notification would say the same as looking does, and it could be missed between
        // asking for the activation and starting to listen.
        let deadline = ContinuousClock.now + Self.activationTimeout
        while ContinuousClock.now < deadline {
            if isFrontmost(previousApp) { return true }
            do {
                try await Task.sleep(for: Self.activationCheckInterval)
            } catch {
                // The paste was cancelled while it waited.
                return false
            }
        }
        return isFrontmost(previousApp)
    }

    private func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication == app
    }

    /// - Returns: Whether macOS took the request. The app comes forward a moment later, or,
    ///   as the documentation of `activate(from:options:)` warns, not at all.
    private func handActivation(to app: NSRunningApplication) -> Bool {
        NSApp.yieldActivation(to: app)
        return app.activate(from: .current, options: [])
    }
}
