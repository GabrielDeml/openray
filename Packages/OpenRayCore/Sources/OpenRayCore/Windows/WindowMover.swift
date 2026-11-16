import CoreGraphics

/// Why a window command did not move a window (docs/DESIGN.md §4.7).
public enum WindowError: Error, Sendable, Equatable {
    /// OpenRay is not allowed to use the Accessibility API, or no longer is.
    case notTrusted
    /// The app has no window that could be moved.
    case noWindow
    case fullScreen
    /// The app did not answer in time.
    case appNotResponding
    /// The window is where the command would put it, which is not a failure.
    case unchanged
    /// A move to another display, and there is only one.
    case noOtherDisplay
    /// Restore, and OpenRay knows no earlier place of this window that is still on a display.
    case nothingToRestore
}

extension WindowError {
    /// What a failed Accessibility call means for a window command. The codes are copied from
    /// AXError.h (HIServices), because Core does not import the framework that declares them.
    public init(axStatus: Int32) {
        switch axStatus {
        case -25211:  // kAXErrorAPIDisabled
            self = .notTrusted
        case -25204:  // kAXErrorCannotComplete: messaging failed, most often by timing out
            self = .appNotResponding
        default:
            // Whatever else went wrong, the app has no window that takes what was asked of it.
            self = .noWindow
        }
    }
}

/// One window, as the mover reads and writes it. All frames are in AX coordinates. The app
/// target implements it with the Accessibility API; tests use a fake that behaves like the
/// apps that are hard to move.
public protocol WindowBackend {
    func isFullScreen() throws(WindowError) -> Bool
    func readFrame() throws(WindowError) -> CGRect
    func isSizeSettable() throws(WindowError) -> Bool
    func write(size: CGSize) throws(WindowError)
    func write(position: CGPoint) throws(WindowError)
}

/// What is remembered about a window OpenRay has moved, for Restore.
public struct RestoreRecord: Sendable, Equatable {
    /// Where a command meant to put a window and where the window then was. The two differ
    /// for a window that did not take the size it was given.
    public struct Move: Sendable, Equatable {
        public var target: CGRect
        public var result: CGRect

        public init(target: CGRect, result: CGRect) {
            self.target = target
            self.result = result
        }
    }

    /// Where the window was before OpenRay first moved it.
    public var restoreFrame: CGRect
    /// The last command OpenRay finished on this window. A window that is not at its
    /// `result` has been moved by the user since, and that place is then the one to go back
    /// to. nil after a command that failed halfway, when nobody knows where the window was
    /// left.
    public var lastMove: Move?

    public init(restoreFrame: CGRect, lastMove: Move?) {
        self.restoreFrame = restoreFrame
        self.lastMove = lastMove
    }
}

/// Applies a window command to one window: works out where it goes, writes that, and deals
/// with a window that did not take the size it was given.
public enum WindowMover {
    /// A window this close to a frame counts as being there. AX frames are whole points.
    private static let inPlaceTolerance: CGFloat = 0.5
    /// An app may round the size it is given. Up to a point off is not a refusal.
    private static let roundingTolerance: CGFloat = 1

    /// - Parameter record: What is remembered about this window, nil when OpenRay has not
    ///   moved it yet. It is brought up to date here, and cleared by `restore`.
    /// - Throws: `.unchanged`, `.noOtherDisplay` and `.nothingToRestore` when there was
    ///   nothing to do, which is not a failure.
    public static func perform(
        _ action: WindowAction, on window: some WindowBackend, displays: [DisplayGeometry],
        gap: CGFloat, stageStripInset: CGFloat, isDockOnTheLeft: Bool,
        record: inout RestoreRecord?
    ) throws(WindowError) {
        if try window.isFullScreen() { throw .fullScreen }
        let frame = try window.readFrame()

        if action == .restore {
            guard let restoreFrame = record?.restoreFrame else { throw .nothingToRestore }
            // The display the window was on may have been unplugged or moved since. Sent to
            // where it was, the window would be out of sight. The record stays, for when the
            // display is back.
            if !WindowLayout.isOnADisplay(restoreFrame, displays: displays) {
                throw .nothingToRestore
            }
            if frame.isClose(to: restoreFrame, within: inPlaceTolerance) { throw .unchanged }
            // Without a last move, as below: should the app stop answering halfway, the
            // place to go back to is not replaced by where that left the window.
            record = RestoreRecord(restoreFrame: restoreFrame, lastMove: nil)
            try apply(restoreFrame, for: action, to: window, from: frame)
            // The window is back, and there is nothing left to go back to.
            record = nil
            return
        }

        let isDisplayMove = action == .nextDisplay || action == .previousDisplay
        if isDisplayMove && displays.count < 2 { throw .noOtherDisplay }

        let target = WindowLayout.target(
            for: action, window: frame, displays: displays, gap: gap,
            stageStripInset: stageStripInset, isDockOnTheLeft: isDockOnTheLeft)
        // Without a display there is nowhere to put a window.
        guard let target else { throw .unchanged }
        if frame.isClose(to: target, within: inPlaceTolerance) { throw .unchanged }

        // The same command again on a window that did not take the size it was given: it is
        // as near to the target as it gets, and writing again would only make it jump.
        if let lastMove = record?.lastMove, lastMove.target == target,
            frame.isClose(to: lastMove.result, within: inPlaceTolerance)
        {
            throw .unchanged
        }

        let restoreFrame = placeToGoBackTo(from: frame, record: record)
        // Remembered before anything is written, and without a last move, so that Restore
        // leads back even when the app stops answering halfway.
        var newRecord = RestoreRecord(restoreFrame: restoreFrame, lastMove: nil)
        record = newRecord
        let result = try apply(target, for: action, to: window, from: frame)
        newRecord.lastMove = RestoreRecord.Move(target: target, result: result)
        record = newRecord
    }

    /// Where Restore leads after the command that is about to move a window from `frame`.
    private static func placeToGoBackTo(from frame: CGRect, record: RestoreRecord?) -> CGRect {
        guard let record else { return frame }
        guard let lastMove = record.lastMove else {
            // The last command failed halfway and left the window somewhere between. The
            // place from before it still counts.
            return record.restoreFrame
        }
        // Where the window is now is the place to go back to, unless OpenRay put it here: a
        // second command in a row keeps the place from before the first.
        if frame.isClose(to: lastMove.result, within: inPlaceTolerance) {
            return record.restoreFrame
        }
        return frame
    }

    /// Writes the target and reads back what the window made of it.
    ///
    /// - Parameter frame: The window's frame before the write.
    /// - Returns: The window's frame afterwards.
    @discardableResult
    private static func apply(
        _ target: CGRect, for action: WindowAction, to window: some WindowBackend,
        from frame: CGRect
    ) throws(WindowError) -> CGRect {
        guard try window.isSizeSettable() else {
            // Only moved, at the size it has, against the edge its action keeps to.
            let origin = anchoredOrigin(of: frame.size, in: target, for: action)
            try window.write(position: origin)
            return try window.readFrame()
        }

        // The size is written before the move and again after it: while the window is still
        // on a smaller display, the first write can be clamped to that display.
        try window.write(size: target.size)
        try window.write(position: target.origin)
        try window.write(size: target.size)

        // An app may refuse a size or round it: a minimum size, or a terminal that only
        // grows by whole characters. The window is then put where its size fits the action
        // best, a right half against the right edge for one.
        var result = try window.readFrame()
        let tookTheSize =
            abs(result.width - target.width) <= roundingTolerance
            && abs(result.height - target.height) <= roundingTolerance
        if !tookTheSize {
            let origin = anchoredOrigin(of: result.size, in: target, for: action)
            if origin != result.origin {
                try window.write(position: origin)
                result = try window.readFrame()
            }
        }
        return result
    }

    // MARK: Anchors

    /// Which edge of its target a window keeps to when it has another size than the target.
    private enum Anchor {
        case start, middle, end
    }

    private static func horizontalAnchor(of action: WindowAction) -> Anchor {
        switch action {
        case .leftHalf, .topHalf, .bottomHalf, .topLeft, .bottomLeft, .firstThird,
            .firstTwoThirds:
            return .start
        case .rightHalf, .topRight, .bottomRight, .lastThird, .lastTwoThirds:
            return .end
        case .centerThird, .maximize, .almostMaximize, .center, .nextDisplay,
            .previousDisplay, .restore:
            return .middle
        }
    }

    private static func verticalAnchor(of action: WindowAction) -> Anchor {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .topLeft, .topRight, .firstThird, .centerThird,
            .lastThird, .firstTwoThirds, .lastTwoThirds:
            return .start
        case .bottomHalf, .bottomLeft, .bottomRight:
            return .end
        case .maximize, .almostMaximize, .center, .nextDisplay, .previousDisplay, .restore:
            return .middle
        }
    }

    /// Where a window of `size` goes when its target has another size.
    private static func anchoredOrigin(
        of size: CGSize, in target: CGRect, for action: WindowAction
    ) -> CGPoint {
        let x = anchoredStart(
            of: size.width, targetStart: target.minX, targetLength: target.width,
            anchor: horizontalAnchor(of: action))
        let y = anchoredStart(
            of: size.height, targetStart: target.minY, targetLength: target.height,
            anchor: verticalAnchor(of: action))
        return CGPoint(x: x, y: y)
    }

    private static func anchoredStart(
        of length: CGFloat, targetStart: CGFloat, targetLength: CGFloat, anchor: Anchor
    ) -> CGFloat {
        switch anchor {
        case .start:
            return targetStart
        case .middle:
            return targetStart + ((targetLength - length) / 2).rounded()
        case .end:
            return targetStart + targetLength - length
        }
    }
}
