import Foundation

/// What the paste path asks of the Mac and of OpenRay's own windows (docs/DESIGN.md §4.1.7).
///
/// The app target's `MacPasteHost` is the implementation, and the only code that writes the
/// general pasteboard or posts a key event. `PasteService` decides what happens and in which
/// order; tests run it against a fake of this.
@MainActor public protocol PasteHost: AnyObject {
    /// Replaces what is on the general pasteboard with these representations of one thing.
    ///
    /// - Returns: The pasteboard's change count for this write.
    func writePasteboard(_ representations: [ClipRepresentation]) -> Int

    /// Hides the launcher. Nothing happens when it is hidden already.
    func hideLauncher()

    /// Whether OpenRay is the active app. The launcher does not make it so; a window of its own
    /// that takes the keyboard does, such as Settings.
    var isOpenRayActive: Bool { get }

    /// Brings the app the launcher was opened over back to the front, and waits for it.
    ///
    /// - Returns: false when that app has quit or did not come forward.
    func restoreFocus() async -> Bool

    var frontmostAppPID: pid_t? { get }

    /// Presses and releases the chord as if the user had typed it. macOS drops the event when
    /// OpenRay does not have the Accessibility permission.
    func post(_ chord: KeyChord)

    func showHUD(_ text: String)
}
