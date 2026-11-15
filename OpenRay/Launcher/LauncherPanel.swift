import AppKit

/// The launcher's window: a borderless panel that takes key focus without activating OpenRay, so
/// the frontmost app stays frontmost, and that sits above other apps' full-screen Spaces.
///
/// Created once and only ever ordered out, never closed.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 720, height: 474)
    static let cornerRadius: CGFloat = 18

    init(contentRect: NSRect) {
        // `.nonactivatingPanel` must be part of the initial style: adding it later does not
        // update the window server's activation-prevention flag.
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient,
            .ignoresCycle,
        ]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // The glass content view draws the only background.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Last: `.floating` and `.statusBar` sit below full-screen Spaces, and setting
        // `isFloatingPanel` would reset the level to `.floating`.
        level = .screenSaver
        // Keep this at the end of `init`: it is there to catch a property set later on that
        // moves the level, as `isFloatingPanel` does.
        assert(level == .screenSaver)
    }

    // Borderless windows refuse key status by default.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
