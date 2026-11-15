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
    public static func frame(displays: [DisplayGeometry], mouse: CGPoint, size: CGSize) -> CGRect {
        guard let display = display(under: mouse, in: displays) else {
            return CGRect(origin: .zero, size: size)
        }
        let visible = display.visibleFrame
        let top = (visible.maxY - visible.height * topInsetFraction).rounded()
        let left = (visible.midX - size.width / 2).rounded()
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
