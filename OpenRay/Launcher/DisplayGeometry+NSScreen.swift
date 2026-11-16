import AppKit
import OpenRayCore

extension NSScreen {
    /// This screen as Core sees it. AppKit global coordinates already have their origin at the
    /// bottom-left of the primary display.
    var geometry: DisplayGeometry {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return DisplayGeometry(
            id: number?.uint32Value ?? 0, frame: frame, visibleFrame: visibleFrame)
    }
}
