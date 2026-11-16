import CoreGraphics

/// A display as placement and window layout see it. Both rects are in AppKit global coordinates:
/// origin at the bottom-left of the primary display, y up.
public struct DisplayGeometry: Sendable, Equatable {
    public let id: UInt32
    public let frame: CGRect
    /// `frame` without the menu bar and the Dock.
    public let visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum PanelPlacement {
    /// How far below the top of the visible frame the panel's top edge sits, as a fraction of the
    /// visible frame's height.
    static let topInsetFraction = 0.22

    /// The launcher panel's frame: on the display under the mouse (the first display if the mouse
    /// is on none), centred horizontally, with a fixed top edge so results grow downward only.
    /// Whole points, in AppKit global coordinates.
    ///
    /// The panel stays inside the visible frame whenever it fits there: on a display too short
    /// for the usual top edge it sits higher, with its bottom edge on the bottom of the visible
    /// frame. A panel larger than the visible frame cannot fit. It then keeps its top-left
    /// corner, where the search field is, inside the visible frame and runs off the bottom or
    /// the right.
    public static func frame(displays: [DisplayGeometry], mouse: CGPoint, size: CGSize) -> CGRect {
        guard let display = display(under: mouse, in: displays) else {
            return CGRect(origin: .zero, size: size)
        }
        let visible = display.visibleFrame

        var top = visible.maxY - visible.height * topInsetFraction
        // Raised until the bottom edge is inside, but never past the top of the visible frame.
        // The second line wins when the panel is taller than the visible frame.
        top = max(top, visible.minY + size.height)
        top = min(top, visible.maxY)

        // A centred panel is inside the visible frame unless it is wider than it.
        var left = visible.midX - size.width / 2
        left = max(left, visible.minX)

        top = top.rounded()
        left = left.rounded()
        return CGRect(x: left, y: top - size.height, width: size.width, height: size.height)
    }

    private static func display(
        under mouse: CGPoint, in displays: [DisplayGeometry]
    ) -> DisplayGeometry? {
        for display in displays {
            if display.frame.contains(mouse) { return display }
        }
        // The mouse location can sit exactly on a display's top edge, which `contains` excludes.
        // Look again with every frame a point larger.
        for display in displays {
            if display.frame.insetBy(dx: -1, dy: -1).contains(mouse) { return display }
        }
        return displays.first
    }
}
