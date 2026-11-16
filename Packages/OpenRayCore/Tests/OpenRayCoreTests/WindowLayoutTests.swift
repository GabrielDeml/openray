import CoreGraphics
import Testing

import OpenRayCore

// Windows and expected frames are in AX coordinates (origin at the top-left of the primary
// display, y down). The displays are in AppKit coordinates; `TestDisplays` says what the work
// area of each is in AX coordinates.

@Suite struct WindowLayoutTests {
    /// The actions that split the work area: every tile.
    private static let tiles: [WindowAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft,
        .bottomRight, .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds,
    ]

    private func target(
        _ action: WindowAction, of window: CGRect, on displays: [DisplayGeometry],
        gap: CGFloat = 0, stageStripInset: CGFloat = 0, isDockOnTheLeft: Bool = false
    ) -> CGRect? {
        WindowLayout.target(
            for: action, window: window, displays: displays, gap: gap,
            stageStripInset: stageStripInset, isDockOnTheLeft: isDockOnTheLeft)
    }

    // MARK: One display

    private static let onlyPrimary = [TestDisplays.primary]
    /// Somewhere on `TestDisplays.primary`.
    private static let smallWindow = rect(100, 100, 800, 600)

    @Test(arguments: [
        (WindowAction.leftHalf, rect(0, 25, 720, 815)),
        (.rightHalf, rect(720, 25, 720, 815)),
        // 815 points do not halve: the top half gets the odd point.
        (.topHalf, rect(0, 25, 1440, 408)),
        (.bottomHalf, rect(0, 433, 1440, 407)),
        (.topLeft, rect(0, 25, 720, 408)),
        (.topRight, rect(720, 25, 720, 408)),
        (.bottomLeft, rect(0, 433, 720, 407)),
        (.bottomRight, rect(720, 433, 720, 407)),
        (.firstThird, rect(0, 25, 480, 815)),
        (.centerThird, rect(480, 25, 480, 815)),
        (.lastThird, rect(960, 25, 480, 815)),
        (.firstTwoThirds, rect(0, 25, 960, 815)),
        (.lastTwoThirds, rect(480, 25, 960, 815)),
        (.maximize, rect(0, 25, 1440, 815)),
        // A twentieth of 1440 and of 815 (40.75, rounded) is left free on every side.
        (.almostMaximize, rect(72, 66, 1296, 733)),
    ])
    func actionFillsItsPartOfTheWorkArea(_ action: WindowAction, _ expected: CGRect) {
        #expect(target(action, of: Self.smallWindow, on: Self.onlyPrimary) == expected)
    }

    @Test func centerKeepsTheSizeOfTheWindow() {
        let centered = target(.center, of: Self.smallWindow, on: Self.onlyPrimary)

        // 107.5 points are free above and below; the half point goes to the top.
        #expect(centered == rect(320, 133, 800, 600))
    }

    @Test func centerCutsAWindowThatIsLargerThanTheWorkAreaDownToIt() {
        let centered = target(.center, of: rect(-50, 0, 2000, 700), on: Self.onlyPrimary)

        #expect(centered == rect(0, 83, 1440, 700))
    }

    @Test(arguments: [WindowAction.nextDisplay, .previousDisplay])
    func windowHasNowhereToGoOnASingleDisplay(_ action: WindowAction) {
        #expect(target(action, of: Self.smallWindow, on: Self.onlyPrimary) == nil)
    }

    @Test func restoreIsNotALayout() {
        #expect(target(.restore, of: Self.smallWindow, on: Self.onlyPrimary) == nil)
    }

    @Test(arguments: WindowAction.allCases)
    func nothingIsLaidOutWithoutADisplay(_ action: WindowAction) {
        #expect(target(action, of: Self.smallWindow, on: []) == nil)
    }

    // MARK: Gap

    @Test(arguments: [
        (WindowAction.leftHalf, rect(10, 35, 705, 795)),
        (.rightHalf, rect(725, 35, 705, 795)),
        (.topLeft, rect(10, 35, 705, 393)),
        (.bottomLeft, rect(10, 438, 705, 392)),
        (.maximize, rect(10, 35, 1420, 795)),
    ])
    func gapIsWholeAtTheEdgesAndSharedBetweenTwoTiles(_ action: WindowAction, _ expected: CGRect) {
        #expect(target(action, of: Self.smallWindow, on: Self.onlyPrimary, gap: 10) == expected)
    }

    @Test func almostMaximizeAndCenterTakeNoGap() {
        let almostMaximized = target(
            .almostMaximize, of: Self.smallWindow, on: Self.onlyPrimary, gap: 10)
        let centered = target(.center, of: Self.smallWindow, on: Self.onlyPrimary, gap: 10)

        #expect(almostMaximized == rect(72, 66, 1296, 733))
        #expect(centered == rect(320, 133, 800, 600))
    }

    @Test func negativeGapAndInsetCountAsNone() {
        let leftHalf = target(
            .leftHalf, of: Self.smallWindow, on: Self.onlyPrimary, gap: -10, stageStripInset: -64)

        #expect(leftHalf == rect(0, 25, 720, 815))
    }

    @Test(arguments: tiles + [.maximize])
    func absurdGapStillLeavesSomethingOfTheWindow(_ action: WindowAction) throws {
        let workArea = rect(0, 25, 1440, 815)

        let frame = try #require(
            target(action, of: Self.smallWindow, on: Self.onlyPrimary, gap: 10_000))

        #expect(frame.width >= 1)
        #expect(frame.height >= 1)
        #expect(workArea.contains(frame))
    }

    // MARK: Stage Manager

    @Test func stageStripInsetIsLeftFreeOnTheLeft() {
        let leftHalf = target(
            .leftHalf, of: Self.smallWindow, on: Self.onlyPrimary, stageStripInset: 64)
        let rightHalf = target(
            .rightHalf, of: Self.smallWindow, on: Self.onlyPrimary, stageStripInset: 64)

        #expect(leftHalf == rect(64, 25, 688, 815))
        #expect(rightHalf == rect(752, 25, 688, 815))
    }

    // The strip changes sides when the Dock is on the left, as it is on `notebook`.
    @Test func stageStripInsetIsLeftFreeOnTheRightWhenTheDockIsOnTheLeft() {
        let displays = [TestDisplays.notebook, TestDisplays.desk]
        let window = rect(200, 200, 800, 600)

        let leftHalf = target(
            .leftHalf, of: window, on: displays, stageStripInset: 64, isDockOnTheLeft: true)
        let rightHalf = target(
            .rightHalf, of: window, on: displays, stageStripInset: 64, isDockOnTheLeft: true)

        #expect(leftHalf == rect(64, 38, 692, 944))
        #expect(rightHalf == rect(756, 38, 692, 944))
    }

    // A hidden Dock takes nothing off the visible frame, and the strip is on the right all
    // the same.
    @Test func stageStripInsetIsLeftFreeOnTheRightWhileTheDockOnTheLeftIsHidden() {
        let leftHalf = target(
            .leftHalf, of: Self.smallWindow, on: Self.onlyPrimary, stageStripInset: 64,
            isDockOnTheLeft: true)
        let rightHalf = target(
            .rightHalf, of: Self.smallWindow, on: Self.onlyPrimary, stageStripInset: 64,
            isDockOnTheLeft: true)

        #expect(leftHalf == rect(0, 25, 688, 815))
        #expect(rightHalf == rect(688, 25, 688, 815))
    }

    // The Dock is on `notebook` only, and the strip is on the right of `desk` as well.
    @Test func stageStripInsetIsLeftFreeOnTheRightOfADisplayWithoutTheDock() {
        let displays = [TestDisplays.notebook, TestDisplays.desk]
        let windowOnDesk = rect(2000, 300, 800, 600)

        let maximized = target(
            .maximize, of: windowOnDesk, on: displays, stageStripInset: 64, isDockOnTheLeft: true)

        #expect(maximized == rect(1512, 25, 2496, 1335))
    }

    @Test func insetWiderThanTheDisplayStillLeavesAWorkArea() throws {
        let maximized = try #require(
            target(.maximize, of: Self.smallWindow, on: Self.onlyPrimary, stageStripInset: 5000))

        #expect(maximized == rect(1439, 25, 1, 815))
    }

    // MARK: A display to the left, at a negative origin

    private static let withLowerLeft = [TestDisplays.primary, TestDisplays.lowerLeft]
    private static let windowOnLowerLeft = rect(-1800, 0, 800, 600)

    @Test(arguments: [
        (WindowAction.leftHalf, rect(-1920, -55, 960, 1055)),
        (.rightHalf, rect(-960, -55, 960, 1055)),
        // Rounded as a distance from the top of the work area, so the odd point goes to the
        // top half here too, although the coordinates are negative.
        (.topHalf, rect(-1920, -55, 1920, 528)),
        (.bottomHalf, rect(-1920, 473, 1920, 527)),
        (.lastThird, rect(-640, -55, 640, 1055)),
        (.maximize, rect(-1920, -55, 1920, 1055)),
    ])
    func windowIsLaidOutOnADisplayAtANegativeOrigin(_ action: WindowAction, _ expected: CGRect) {
        #expect(target(action, of: Self.windowOnLowerLeft, on: Self.withLowerLeft) == expected)
    }

    // With two displays the next one and the previous one are the same.
    @Test(arguments: [WindowAction.nextDisplay, .previousDisplay])
    func windowKeepsItsShareOfTheWorkAreaOnTheOtherDisplay(_ action: WindowAction) {
        let moved = target(action, of: Self.windowOnLowerLeft, on: Self.withLowerLeft)

        // 120 of 1920 points from the left become 90 of 1440, and 55 of 1055 from the top
        // become 42 of 815.
        #expect(moved == rect(90, 67, 600, 464))
    }

    @Test func tiledWindowKeepsItsTileOnTheOtherDisplay() {
        let leftHalfThere = rect(-1920, -55, 960, 1055)

        let moved = target(.nextDisplay, of: leftHalfThere, on: Self.withLowerLeft)

        #expect(moved == rect(0, 25, 720, 815))
    }

    @Test func tileIsRecognisedWithItsGap() {
        let displays = Self.withLowerLeft
        let leftHalfWithGap = rect(-1910, -45, 945, 1035)

        let moved = target(.nextDisplay, of: leftHalfWithGap, on: displays, gap: 10)

        #expect(moved == rect(10, 35, 705, 795))
    }

    // MARK: A display above

    private static let withAbove = [TestDisplays.primary, TestDisplays.above]

    @Test(arguments: [
        (WindowAction.topLeft, rect(-240, -1055, 960, 528)),
        (.bottomRight, rect(720, -527, 960, 527)),
        (.maximize, rect(-240, -1055, 1920, 1055)),
    ])
    func windowIsLaidOutOnADisplayAboveThePrimary(_ action: WindowAction, _ expected: CGRect) {
        let windowOnUpperDisplay = rect(0, -800, 640, 480)

        #expect(target(action, of: windowOnUpperDisplay, on: Self.withAbove) == expected)
    }

    @Test func windowOnTwoDisplaysBelongsToTheOneThatShowsMoreOfIt() {
        // 100 of its 600 points of height are on the upper display.
        let straddling = rect(0, -100, 800, 600)

        #expect(target(.leftHalf, of: straddling, on: Self.withAbove) == rect(0, 25, 720, 815))
    }

    @Test func windowInEqualPartsOnTwoDisplaysBelongsToTheEarlierOne() {
        let straddling = rect(0, -300, 800, 600)

        let leftHalf = target(.leftHalf, of: straddling, on: Self.withAbove)
        let leftHalfInReverse = target(.leftHalf, of: straddling, on: Self.withAbove.reversed())

        #expect(leftHalf == rect(0, 25, 720, 815))
        #expect(leftHalfInReverse == rect(-240, -1055, 960, 1055))
    }

    @Test func windowOnNoDisplayBelongsToTheFirstOne() {
        let offScreen = rect(9000, 9000, 800, 600)

        #expect(target(.leftHalf, of: offScreen, on: Self.withAbove) == rect(0, 25, 720, 815))
    }

    // MARK: Two displays of different sizes

    private static let notebookAndDesk = [TestDisplays.notebook, TestDisplays.desk]
    private static let windowOnNotebook = rect(200, 200, 800, 600)
    private static let windowOnDesk = rect(2000, 300, 800, 600)

    @Test(arguments: [
        (WindowAction.leftHalf, rect(64, 38, 724, 944)),
        (.rightHalf, rect(788, 38, 724, 944)),
        // 1448 points do not divide by three: the thirds are 483, 482 and 483 wide.
        (.firstThird, rect(64, 38, 483, 944)),
        (.centerThird, rect(547, 38, 482, 944)),
        (.lastThird, rect(1029, 38, 483, 944)),
        (.firstTwoThirds, rect(64, 38, 965, 944)),
        (.lastTwoThirds, rect(547, 38, 965, 944)),
    ])
    func oddWidthIsSharedOutInWholePoints(_ action: WindowAction, _ expected: CGRect) {
        #expect(target(action, of: Self.windowOnNotebook, on: Self.notebookAndDesk) == expected)
    }

    @Test(arguments: [
        (WindowAction.firstThird, rect(72, 46, 471, 928)),
        (.centerThird, rect(551, 46, 474, 928)),
        (.lastThird, rect(1033, 46, 471, 928)),
    ])
    func thirdsOfAnOddWidthKeepTheGapBetweenThem(_ action: WindowAction, _ expected: CGRect) {
        let third = target(action, of: Self.windowOnNotebook, on: Self.notebookAndDesk, gap: 8)

        #expect(third == expected)
    }

    @Test(arguments: [
        (WindowAction.topRight, rect(2792, 25, 1280, 668)),
        (.bottomRight, rect(2792, 693, 1280, 667)),
        (.lastTwoThirds, rect(2365, 25, 1707, 1335)),
    ])
    func windowIsLaidOutOnTheSecondDisplay(_ action: WindowAction, _ expected: CGRect) {
        #expect(target(action, of: Self.windowOnDesk, on: Self.notebookAndDesk) == expected)
    }

    @Test func tiledWindowFillsTheSameTileOfALargerDisplay() {
        let leftHalfOfNotebook = rect(64, 38, 724, 944)

        let moved = target(.nextDisplay, of: leftHalfOfNotebook, on: Self.notebookAndDesk)

        #expect(moved == rect(1512, 25, 1280, 1335))
    }

    // MARK: The order of the displays

    private static let threeInARow = [
        TestDisplays.primary, TestDisplays.levelLeft, TestDisplays.levelRight,
    ]

    @Test func nextDisplayAfterTheRightmostIsTheLeftmost() {
        let maximizedOnTheRight = rect(1440, 125, 1280, 775)

        let moved = target(.nextDisplay, of: maximizedOnTheRight, on: Self.threeInARow)

        #expect(moved == rect(-1920, -155, 1920, 1055))
    }

    @Test func previousDisplayBeforeTheLeftmostIsTheRightmost() {
        let maximizedOnTheLeft = rect(-1920, -155, 1920, 1055)

        let moved = target(.previousDisplay, of: maximizedOnTheLeft, on: Self.threeInARow)

        #expect(moved == rect(1440, 125, 1280, 775))
    }

    @Test func nextAndPreviousGoThroughTheDisplaysFromLeftToRight() {
        let maximizedInTheMiddle = rect(0, 25, 1440, 815)

        let next = target(.nextDisplay, of: maximizedInTheMiddle, on: Self.threeInARow)
        let previous = target(.previousDisplay, of: maximizedInTheMiddle, on: Self.threeInARow)

        #expect(next == rect(1440, 125, 1280, 775))
        #expect(previous == rect(-1920, -155, 1920, 1055))
    }

    @Test func ofTwoDisplaysThatStartAtTheSameXTheLowerOneComesFirst() {
        // Stacked on the primary display, without a menu bar. Work area (0, -900, 1440, 900).
        let stacked = DisplayGeometry(
            id: 8, frame: rect(0, 900, 1440, 900), visibleFrame: rect(0, 900, 1440, 900))
        let displays = [TestDisplays.levelRight, stacked, TestDisplays.primary]
        let maximizedOnPrimary = rect(0, 25, 1440, 815)

        let next = target(.nextDisplay, of: maximizedOnPrimary, on: displays)
        let previous = target(.previousDisplay, of: maximizedOnPrimary, on: displays)

        // Primary, stacked, right: the stacked display follows the primary one.
        #expect(next == rect(0, -900, 1440, 900))
        #expect(previous == rect(1440, 125, 1280, 775))
    }

    // MARK: A window that is not inside its work area

    @Test func windowThatSticksOutOfItsDisplayIsMovedInsideTheOtherOne() {
        // Mostly on the right display, with 440 points of its width on the primary one.
        let straddling = rect(1000, 150, 1000, 600)

        let moved = target(.previousDisplay, of: straddling, on: Self.threeInARow)

        // Scaled alone, it would start 495 points left of the primary display.
        #expect(moved == rect(0, 51, 1125, 631))
    }

    @Test func windowLargerThanItsWorkAreaIsCutDownToTheOtherOne() {
        let oversizedOnPrimary = rect(-100, 0, 1700, 1000)

        let moved = target(.nextDisplay, of: oversizedOnPrimary, on: Self.threeInARow)

        #expect(moved == rect(1440, 125, 1280, 775))
    }

    // It counts as on the first display of the list, the primary one, so the move brings it
    // to the right one: into the corner nearest to where it was.
    @Test func windowOnNoDisplayIsBroughtOntoTheOtherOne() {
        let offScreen = rect(9000, 9000, 800, 600)

        let moved = target(.nextDisplay, of: offScreen, on: Self.threeInARow)

        #expect(moved == rect(2009, 330, 711, 570))
    }

    // MARK: Tiles cover the work area

    /// One display of the arrangements above, picked out by a window that is on it.
    struct Arrangement: Sendable {
        var displays: [DisplayGeometry]
        /// A window on the display that is meant.
        var window: CGRect
        /// The work area that display should have.
        var workArea: CGRect
    }

    private static let arrangements = [
        Arrangement(
            displays: onlyPrimary, window: smallWindow, workArea: rect(0, 25, 1440, 815)),
        Arrangement(
            displays: withLowerLeft, window: windowOnLowerLeft,
            workArea: rect(-1920, -55, 1920, 1055)),
        Arrangement(
            displays: withAbove, window: rect(0, -800, 640, 480),
            workArea: rect(-240, -1055, 1920, 1055)),
        Arrangement(
            displays: notebookAndDesk, window: windowOnNotebook,
            workArea: rect(64, 38, 1448, 944)),
        Arrangement(
            displays: notebookAndDesk, window: windowOnDesk,
            workArea: rect(1512, 25, 2560, 1335)),
        Arrangement(
            displays: threeInARow, window: rect(-1800, 0, 800, 600),
            workArea: rect(-1920, -155, 1920, 1055)),
        Arrangement(
            displays: threeInARow, window: rect(1500, 200, 800, 500),
            workArea: rect(1440, 125, 1280, 775)),
    ]

    @Test(arguments: arrangements)
    func maximizeFillsTheWorkArea(_ arrangement: Arrangement) {
        let maximized = target(.maximize, of: arrangement.window, on: arrangement.displays)

        #expect(maximized == arrangement.workArea)
    }

    @Test(
        arguments: arrangements,
        [
            [WindowAction.leftHalf, .rightHalf],
            [.topHalf, .bottomHalf],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.firstThird, .centerThird, .lastThird],
            [.firstTwoThirds, .lastThird],
            [.firstThird, .lastTwoThirds],
        ])
    func tilesCoverTheWorkAreaWithoutHoleOrOverlap(
        _ arrangement: Arrangement, _ actions: [WindowAction]
    ) throws {
        let workArea = arrangement.workArea
        var frames: [CGRect] = []
        for action in actions {
            let frame = target(action, of: arrangement.window, on: arrangement.displays)
            frames.append(try #require(frame))
        }

        // Tiles that lie inside the work area, do not overlap and have its area between
        // them leave no hole.
        var coveredArea: CGFloat = 0
        for (index, frame) in frames.enumerated() {
            #expect(workArea.contains(frame))
            coveredArea += frame.width * frame.height
            for laterFrame in frames[(index + 1)...] {
                #expect(frame.intersection(laterFrame).isEmpty)
            }
        }
        #expect(coveredArea == workArea.width * workArea.height)
    }
}
