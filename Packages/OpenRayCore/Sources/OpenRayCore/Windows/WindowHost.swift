import Foundation

/// What the window commands ask of the Mac (docs/DESIGN.md §4.7). The app target implements
/// it with `NSScreen` and the Accessibility API; tests put a fake in its place, so that no
/// test ever moves a window.
@MainActor public protocol WindowHost: AnyObject, Sendable {
    /// The displays as they are arranged now.
    var displays: [DisplayGeometry] { get }

    /// Whether Stage Manager is on, which is when its strip of recent apps takes up room at
    /// the side of a display.
    var isStageManagerOn: Bool { get }

    /// Whether the Dock is set to the left edge of the screen, shown or hidden. Stage
    /// Manager's strip is then on the right.
    var isDockOnTheLeft: Bool { get }

    /// Applies the action to the focused window of the app with this process ID.
    ///
    /// - Parameter displays: What `displays` returned, handed back so that the layout is
    ///   worked out for the arrangement the caller saw.
    func perform(
        _ action: WindowAction, pid: pid_t, displays: [DisplayGeometry], gap: CGFloat,
        stageStripInset: CGFloat, isDockOnTheLeft: Bool
    ) async throws(WindowError)
}
