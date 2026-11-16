import CoreGraphics

/// Converts between the two coordinate spaces a window command meets (docs/DESIGN.md §4.7).
///
/// AppKit, and with it `DisplayGeometry`, has its origin at the bottom-left corner of the
/// primary display, with y going up. The Accessibility API has it at the top-left corner of
/// that display, with y going down. x is the same in both.
public enum ScreenCoordinates {
    /// - Parameter primaryMaxY: The top edge of the primary display in AppKit coordinates,
    ///   which is its height.
    public static func toAX(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The way back is the same flip: what was measured down from the top edge of the primary
    /// display is measured up from its bottom edge again.
    public static func toAppKit(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
