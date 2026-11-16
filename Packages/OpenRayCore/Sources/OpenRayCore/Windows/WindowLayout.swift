import CoreGraphics

/// Where a window command puts a window (docs/DESIGN.md §4.7). Pure geometry: it reads no
/// window and no screen, so every rule here is tested with made-up displays.
///
/// Everything is worked out in AX coordinates, the space windows are read and written in.
public enum WindowLayout {
    /// The frame `action` gives the window.
    ///
    /// - Parameters:
    ///   - window: The window's frame now, in AX coordinates, as the result is.
    ///   - displays: In AppKit coordinates, as `DisplayGeometry` has them.
    ///   - gap: The space to leave around and between tiles. A negative one counts as 0.
    ///   - stageStripInset: What to leave free for Stage Manager's strip; 0 while it is off.
    ///   - isDockOnTheLeft: Whether the Dock is set to the left edge of the screen, shown or
    ///     hidden. Stage Manager's strip is then on the right.
    /// - Returns: nil when there is nothing to work out: without a display, for a move to
    ///   another display when there is only one, and for `restore`, which is not a layout
    ///   (`WindowMover` keeps the frame to go back to).
    public static func target(
        for action: WindowAction, window: CGRect, displays: [DisplayGeometry],
        gap: CGFloat, stageStripInset: CGFloat, isDockOnTheLeft: Bool
    ) -> CGRect? {
        guard let primaryMaxY = primaryMaxY(of: displays),
            let display = display(showing: window, in: displays, primaryMaxY: primaryMaxY)
        else {
            return nil
        }
        let gap = max(0, gap)
        let area = workArea(
            of: display, primaryMaxY: primaryMaxY, stageStripInset: stageStripInset,
            isDockOnTheLeft: isDockOnTheLeft)

        switch action {
        case .restore:
            return nil
        case .center:
            return centered(window.size, in: area)
        case .nextDisplay, .previousDisplay:
            guard
                let other = neighbour(of: display, in: displays, forward: action == .nextDisplay)
            else {
                return nil
            }
            let otherArea = workArea(
                of: other, primaryMaxY: primaryMaxY, stageStripInset: stageStripInset,
                isDockOnTheLeft: isDockOnTheLeft)
            return carried(window, from: area, to: otherArea, gap: gap)
        default:
            // A tile, Maximize or Almost Maximize.
            return frame(of: action, in: area, gap: gap)
        }
    }

    // MARK: Displays

    /// The top edge of the primary display in AppKit coordinates, which is what the two
    /// coordinate spaces are converted with. The primary display is the one at the origin.
    private static func primaryMaxY(of displays: [DisplayGeometry]) -> CGFloat? {
        let primary = displays.first { $0.frame.origin == .zero } ?? displays.first
        return primary?.frame.maxY
    }

    /// The display a window belongs to: the one that shows the most of it. A window that is on
    /// no display at all, or on two in equal parts, goes to the earlier one in the list.
    private static func display(
        showing window: CGRect, in displays: [DisplayGeometry], primaryMaxY: CGFloat
    ) -> DisplayGeometry? {
        var best = displays.first
        var largestShare: CGFloat = 0
        for display in displays {
            let frame = ScreenCoordinates.toAX(display.frame, primaryMaxY: primaryMaxY)
            // Rectangles that do not meet intersect in the null rectangle, which has no size.
            let shared = frame.intersection(window)
            let share = shared.width * shared.height
            if share > largestShare {
                best = display
                largestShare = share
            }
        }
        return best
    }

    /// Whether any display shows a part of this frame, which is in AX coordinates.
    static func isOnADisplay(_ frame: CGRect, displays: [DisplayGeometry]) -> Bool {
        guard let primaryMaxY = primaryMaxY(of: displays) else { return false }
        for display in displays {
            let displayFrame = ScreenCoordinates.toAX(display.frame, primaryMaxY: primaryMaxY)
            let shared = displayFrame.intersection(frame)
            if shared.width * shared.height > 0 {
                return true
            }
        }
        return false
    }

    /// The part of a display that windows are laid out in, in AX coordinates: what the menu
    /// bar and the Dock leave free, without the room for Stage Manager's strip.
    private static func workArea(
        of display: DisplayGeometry, primaryMaxY: CGFloat, stageStripInset: CGFloat,
        isDockOnTheLeft: Bool
    ) -> CGRect {
        var area = ScreenCoordinates.toAX(display.visibleFrame, primaryMaxY: primaryMaxY)
        // At least a point of the width stays, whatever the preference says.
        let inset = min(stageStripInset, area.width - 1)
        if inset <= 0 { return area }

        // The strip is on the left, unless the Dock is there: then it is on the right, on
        // every display and also while the Dock is hidden. (That is how macOS is said to
        // place it; docs/DESIGN.md §8, item 16 has it among the things still to be looked
        // at on a Mac.)
        if !isDockOnTheLeft {
            area.origin.x += inset
        }
        area.size.width -= inset
        return area
    }

    /// The display a window moves to: the next or the previous one in the order the displays
    /// stand in from left to right, and from bottom to top where two start at the same x.
    /// After the last comes the first again. nil when there is no other display.
    private static func neighbour(
        of display: DisplayGeometry, in displays: [DisplayGeometry], forward: Bool
    ) -> DisplayGeometry? {
        if displays.count < 2 { return nil }
        let ordered = displays.sorted { first, second in
            if first.frame.minX != second.frame.minX {
                return first.frame.minX < second.frame.minX
            }
            return first.frame.minY < second.frame.minY
        }
        guard let index = ordered.firstIndex(of: display) else { return nil }

        // The count is added so that the step back from the first display does not go below 0
        // before it wraps.
        let step = forward ? 1 : -1
        let neighbourIndex = (index + step + ordered.count) % ordered.count
        return ordered[neighbourIndex]
    }

    // MARK: Tiles

    /// A stretch of one axis of the work area, counted in equal parts of it: the centre third
    /// starts after 1 of 3 parts and ends after 2.
    private struct Span {
        var start: CGFloat
        var end: CGFloat
        var parts: CGFloat

        static let whole = Span(start: 0, end: 1, parts: 1)
        static let firstHalf = Span(start: 0, end: 1, parts: 2)
        static let secondHalf = Span(start: 1, end: 2, parts: 2)
        static let firstThird = Span(start: 0, end: 1, parts: 3)
        static let centerThird = Span(start: 1, end: 2, parts: 3)
        static let lastThird = Span(start: 2, end: 3, parts: 3)
        static let firstTwoThirds = Span(start: 0, end: 2, parts: 3)
        static let lastTwoThirds = Span(start: 1, end: 3, parts: 3)
        /// What Almost Maximize keeps of each axis: all but a twentieth at either end.
        static let almostWhole = Span(start: 1, end: 19, parts: 20)
    }

    /// The part of the work area an action fills, across and down. nil for the actions whose
    /// frame depends on more than the work area.
    private static func spans(of action: WindowAction) -> (across: Span, down: Span)? {
        switch action {
        case .leftHalf: return (.firstHalf, .whole)
        case .rightHalf: return (.secondHalf, .whole)
        case .topHalf: return (.whole, .firstHalf)
        case .bottomHalf: return (.whole, .secondHalf)
        case .topLeft: return (.firstHalf, .firstHalf)
        case .topRight: return (.secondHalf, .firstHalf)
        case .bottomLeft: return (.firstHalf, .secondHalf)
        case .bottomRight: return (.secondHalf, .secondHalf)
        case .firstThird: return (.firstThird, .whole)
        case .centerThird: return (.centerThird, .whole)
        case .lastThird: return (.lastThird, .whole)
        case .firstTwoThirds: return (.firstTwoThirds, .whole)
        case .lastTwoThirds: return (.lastTwoThirds, .whole)
        case .maximize: return (.whole, .whole)
        case .almostMaximize: return (.almostWhole, .almostWhole)
        case .center, .nextDisplay, .previousDisplay, .restore: return nil
        }
    }

    /// The frame of an action that depends on the work area alone: a tile, Maximize or Almost
    /// Maximize. nil for the others.
    private static func frame(of action: WindowAction, in area: CGRect, gap: CGFloat) -> CGRect? {
        guard let spans = spans(of: action) else { return nil }
        // Almost Maximize keeps its distance from every edge as it is and has no neighbour to
        // keep a gap to.
        let tileGap = action == .almostMaximize ? 0 : gap

        let across = stretch(
            of: spans.across, areaStart: area.minX, areaLength: area.width, gap: tileGap)
        let down = stretch(
            of: spans.down, areaStart: area.minY, areaLength: area.height, gap: tileGap)
        return CGRect(x: across.start, y: down.start, width: across.length, height: down.length)
    }

    /// Where a tile starts on one axis and how long it is there.
    ///
    /// Both of its edges are worked out as distances from the start of the work area and
    /// rounded as such, so a display at a negative origin rounds like one at zero. They are
    /// multiplied before they are divided, so two thirds of 1440 are exactly 960. Two tiles
    /// that meet work out their common edge with the same expression, which is why they
    /// neither overlap nor leave a hole.
    private static func stretch(
        of span: Span, areaStart: CGFloat, areaLength: CGFloat, gap: CGFloat
    ) -> (start: CGFloat, length: CGFloat) {
        // The gap is whole towards the edge of the work area and half towards a neighbouring
        // tile, whose own half makes it whole.
        let startShare: CGFloat = span.start == 0 ? 1 : 0.5
        let endShare: CGFloat = span.end == span.parts ? 1 : 0.5

        // A gap that would leave less than a point of the tile is cut down to one that
        // leaves a point.
        let lengthWithoutGap = areaLength * (span.end - span.start) / span.parts
        let widestGap = max(0, (lengthWithoutGap - 1) / (startShare + endShare))
        let usedGap = min(gap, widestGap)

        let startDistance = (areaLength * span.start / span.parts + usedGap * startShare).rounded()
        let endDistance = (areaLength * span.end / span.parts - usedGap * endShare).rounded()
        // A work area of a point or two can still round a tile away.
        let length = max(1, endDistance - startDistance)
        return (areaStart + startDistance, length)
    }

    // MARK: Center and the other display

    /// The window at its own size in the middle of the work area, or at the size of the work
    /// area where it is larger than that.
    private static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        let x = area.minX + ((area.width - width) / 2).rounded()
        let y = area.minY + ((area.height - height) / 2).rounded()
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where a window lands on another display. A window that fills a tile fills the same
    /// tile there, which is not the same as scaling it: gaps do not grow with the display.
    /// Any other window keeps its place and its share of the work area, as far as that
    /// leaves it inside the work area there.
    private static func carried(
        _ window: CGRect, from source: CGRect, to destination: CGRect, gap: CGFloat
    ) -> CGRect {
        for action in WindowAction.allCases {
            guard let frameHere = frame(of: action, in: source, gap: gap),
                let frameThere = frame(of: action, in: destination, gap: gap)
            else {
                continue
            }
            // Within a point, because an app may have rounded what it was given.
            if window.isClose(to: frameHere, within: 1) {
                return frameThere
            }
        }

        let minX = scaled(
            window.minX, from: source.minX, length: source.width,
            to: destination.minX, length: destination.width)
        let maxX = scaled(
            window.maxX, from: source.minX, length: source.width,
            to: destination.minX, length: destination.width)
        let minY = scaled(
            window.minY, from: source.minY, length: source.height,
            to: destination.minY, length: destination.height)
        let maxY = scaled(
            window.maxY, from: source.minY, length: source.height,
            to: destination.minY, length: destination.height)
        let scaledFrame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // What stuck out of the work area here would stick out of it there, and a window
        // that was on no display would be on none again.
        return fitted(scaledFrame, into: destination)
    }

    /// One edge of a window, as far along the destination as it was along the source.
    private static func scaled(
        _ edge: CGFloat, from sourceStart: CGFloat, length sourceLength: CGFloat,
        to destinationStart: CGFloat, length destinationLength: CGFloat
    ) -> CGFloat {
        let distance = (edge - sourceStart) * destinationLength / sourceLength
        return destinationStart + distance.rounded()
    }

    /// The frame inside the work area: cut down to it where it is larger, and moved in from
    /// the side it sticks out on.
    private static func fitted(_ frame: CGRect, into area: CGRect) -> CGRect {
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.minY, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension CGRect {
    /// Whether each edge of `other` is within `tolerance` points of the same edge of this
    /// rectangle.
    func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(maxX - other.maxX) <= tolerance
            && abs(minY - other.minY) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }
}
