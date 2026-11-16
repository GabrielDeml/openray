import CoreGraphics
import Foundation

import OpenRayCore

/// Shorthand for the many rectangles of the window tests.
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

/// Displays for the window tests, in AppKit coordinates as `NSScreen` reports them. The work
/// areas in the comments are in AX coordinates, which is what the tests compare against.
enum TestDisplays {
    /// 1440 × 900 with a 25-point menu bar and a 60-point Dock at the bottom.
    /// Work area (0, 25, 1440, 815).
    static let primary = DisplayGeometry(
        id: 1, frame: rect(0, 0, 1440, 900), visibleFrame: rect(0, 60, 1440, 815))

    /// Left of `primary`, larger and hanging lower, with a menu bar and no Dock.
    /// Work area (-1920, -55, 1920, 1055).
    static let lowerLeft = DisplayGeometry(
        id: 2, frame: rect(-1920, -100, 1920, 1080), visibleFrame: rect(-1920, -100, 1920, 1055))

    /// Above `primary`, with a menu bar and no Dock. Work area (-240, -1055, 1920, 1055).
    static let above = DisplayGeometry(
        id: 3, frame: rect(-240, 900, 1920, 1080), visibleFrame: rect(-240, 900, 1920, 1055))

    /// A primary display of an odd width, with a 38-point menu bar and the Dock on the left.
    /// Work area (64, 38, 1448, 944).
    static let notebook = DisplayGeometry(
        id: 4, frame: rect(0, 0, 1512, 982), visibleFrame: rect(64, 0, 1448, 944))

    /// Right of `notebook` and larger, with a 25-point menu bar and an 80-point Dock at the
    /// bottom. Work area (1512, 25, 2560, 1335).
    static let desk = DisplayGeometry(
        id: 5, frame: rect(1512, -458, 2560, 1440), visibleFrame: rect(1512, -378, 2560, 1335))

    /// Left of `primary` with its bottom edge level with it. Work area (-1920, -155, 1920, 1055).
    static let levelLeft = DisplayGeometry(
        id: 6, frame: rect(-1920, 0, 1920, 1080), visibleFrame: rect(-1920, 0, 1920, 1055))

    /// Right of `primary` and smaller. Work area (1440, 125, 1280, 775).
    static let levelRight = DisplayGeometry(
        id: 7, frame: rect(1440, 0, 1280, 800), visibleFrame: rect(1440, 0, 1280, 775))
}

/// A window host that moves nothing: it records what it was asked for and fails on demand.
@MainActor final class FakeWindowHost: WindowHost {
    struct Call: Equatable {
        var action: WindowAction
        var pid: pid_t
        var displays: [DisplayGeometry]
        var gap: CGFloat
        var stageStripInset: CGFloat
        var isDockOnTheLeft: Bool
    }

    var displays = [TestDisplays.primary]
    var isStageManagerOn = false
    var isDockOnTheLeft = false
    /// What `perform` throws, for a test of what the command says then.
    var error: WindowError?

    private(set) var calls: [Call] = []

    func perform(
        _ action: WindowAction, pid: pid_t, displays: [DisplayGeometry], gap: CGFloat,
        stageStripInset: CGFloat, isDockOnTheLeft: Bool
    ) async throws(WindowError) {
        calls.append(
            Call(
                action: action, pid: pid, displays: displays, gap: gap,
                stageStripInset: stageStripInset, isDockOnTheLeft: isDockOnTheLeft))
        if let error { throw error }
    }
}
