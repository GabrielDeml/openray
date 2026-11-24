import Foundation

/// What the actions of an app item ask of the app target, which has `NSWorkspace` and the
/// settings window (docs/DESIGN.md §4.2.8). Tests put a fake in its place.
@MainActor public protocol AppActionHost: AnyObject, Sendable {
    /// Opens the app, or brings it to the front when it is already running.
    func openApp(at url: URL) async throws
    /// Hides the app at `url` if it is the frontmost app and has a window on screen.
    ///
    /// - Returns: false when nothing was hidden: another app is in front, or this one has no
    ///   window to hide.
    func hideAppIfFrontmost(at url: URL) -> Bool
    func showInFinder(_ url: URL)
    /// Asks every running copy of the app at `url` to quit.
    ///
    /// - Returns: false when no copy of it is running.
    func quitApp(at url: URL) -> Bool
    /// Opens Settings › Commands on this item, where its aliases are edited.
    func showAliasSettings(for item: ItemID)
}
