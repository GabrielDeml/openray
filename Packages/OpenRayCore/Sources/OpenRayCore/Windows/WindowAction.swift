/// What a window command does with the focused window (docs/DESIGN.md §4.7).
///
/// The raw values are part of the commands' item IDs (`command:window.leftHalf`), which the
/// usage and override tables store, so they never change.
public enum WindowAction: String, Sendable, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize
    /// Nine tenths of the work area in each direction, centred.
    case almostMaximize
    /// Centred at the size the window has.
    case center
    case nextDisplay, previousDisplay
    /// Back to where the window was before OpenRay first moved it.
    case restore
}
