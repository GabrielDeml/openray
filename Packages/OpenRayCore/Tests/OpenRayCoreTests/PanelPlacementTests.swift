import CoreGraphics
import Testing

import OpenRayCore

@Suite struct PanelPlacementTests {
    private let size = CGSize(width: 750, height: 480)

    /// A 1920×1080 display with a 30-point menu bar and a 50-point Dock at the bottom.
    private let primary = DisplayGeometry(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 50, width: 1920, height: 1000))

    /// To the right of `primary`, raised by 200 points, without a menu bar or Dock.
    private let right = DisplayGeometry(
        id: 2,
        frame: CGRect(x: 1920, y: 200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1920, y: 200, width: 2560, height: 1440))

    /// To the left of `primary`, so its coordinates are negative.
    private let left = DisplayGeometry(
        id: 3,
        frame: CGRect(x: -1280, y: -100, width: 1280, height: 800),
        visibleFrame: CGRect(x: -1280, y: -100, width: 1280, height: 750))

    /// The frame of a panel of the usual `size`.
    private func panelFrame(_ displays: [DisplayGeometry], mouse: CGPoint) -> CGRect {
        PanelPlacement.frame(displays: displays, mouse: mouse, size: size)
    }

    @Test func singleDisplayCentresWithTopEdge22PercentDown() {
        let frame = panelFrame([primary], mouse: CGPoint(x: 100, y: 100))

        #expect(frame.size == size)
        #expect(frame.midX == 960)
        // 22 % of the 1000-point visible height below its top at y = 1050.
        #expect(frame.maxY == 830)
    }

    @Test func topEdgeDoesNotDependOnPanelHeight() {
        let short = PanelPlacement.frame(
            displays: [primary], mouse: .zero, size: CGSize(width: 750, height: 60))
        let tall = PanelPlacement.frame(
            displays: [primary], mouse: .zero, size: CGSize(width: 750, height: 600))

        #expect(short.maxY == tall.maxY)
        #expect(short.minY - tall.minY == 540)
    }

    @Test func panelOpensOnTheDisplayUnderTheMouse() {
        let frame = panelFrame([primary, right, left], mouse: CGPoint(x: 3000, y: 900))

        #expect(frame.midX == 3200)
        // 22 % of 1440 is 316.8 points below the top at y = 1640.
        #expect(frame.maxY == 1323)
    }

    @Test func panelOpensOnADisplayWithNegativeCoordinates() {
        let frame = panelFrame([primary, right, left], mouse: CGPoint(x: -640, y: -50))

        #expect(frame.midX == -640)
        // 22 % of the 750-point visible height below its top at y = 650.
        #expect(frame.maxY == 485)
        #expect(left.frame.contains(frame))
    }

    @Test func centresInTheVisibleFrameNotTheFullFrame() {
        let dockOnLeft = DisplayGeometry(
            id: 4,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 120, y: 0, width: 1800, height: 1050))

        let frame = panelFrame([dockOnLeft], mouse: CGPoint(x: 10, y: 10))

        // The visible frame runs from x = 120 to 1920. The full frame's centre would be 960.
        #expect(frame.midX == 1020)
    }

    @Test func shortDisplayRaisesThePanelUntilItFits() {
        // 22 % down from the top at y = 575 leaves 402 points above the Dock, and the panel
        // is 480 high.
        let short = DisplayGeometry(
            id: 6,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 600),
            visibleFrame: CGRect(x: 0, y: 60, width: 1280, height: 515))

        let frame = panelFrame([short], mouse: CGPoint(x: 10, y: 10))

        #expect(frame.size == size)
        #expect(frame.minY == 60)
        #expect(frame.midX == 640)
        #expect(short.visibleFrame.contains(frame))
    }

    @Test func narrowDisplayKeepsTheLeftEdgeOnScreen() {
        // 700 points wide, to the left of the primary display. The panel is 750 wide.
        let narrow = DisplayGeometry(
            id: 7,
            frame: CGRect(x: -700, y: 0, width: 700, height: 1200),
            visibleFrame: CGRect(x: -700, y: 0, width: 700, height: 1160))

        let frame = panelFrame([narrow], mouse: CGPoint(x: -10, y: 10))

        #expect(frame.size == size)
        #expect(frame.minX == -700)
        // The top edge is where it always is: 255.2 points below the top at y = 1160.
        #expect(frame.maxY == 905)
    }

    @Test func displaySmallerThanThePanelKeepsTheTopLeftCornerOnScreen() {
        // The Dock is on the left, so the visible frame starts at x = 50.
        let tiny = DisplayGeometry(
            id: 8,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            visibleFrame: CGRect(x: 50, y: 0, width: 590, height: 450))

        let frame = panelFrame([tiny], mouse: CGPoint(x: 10, y: 10))

        #expect(frame.size == size)
        #expect(frame.minX == 50)
        #expect(frame.maxY == 450)
    }

    @Test func mouseOnTheSeamBelongsToTheDisplayThatStartsThere() {
        // `primary` ends at x = 1920, where `right` starts.
        let onTheSeam = CGPoint(x: 1920, y: 500)
        let justLeftOfTheSeam = CGPoint(x: 1919.5, y: 500)

        #expect(panelFrame([primary, right], mouse: onTheSeam).midX == right.frame.midX)
        #expect(panelFrame([right, primary], mouse: onTheSeam).midX == right.frame.midX)
        #expect(panelFrame([primary, right], mouse: justLeftOfTheSeam).midX == 960)
    }

    @Test func mouseOnTheTopEdgeStaysOnThatDisplay() {
        let frame = panelFrame([primary, right], mouse: CGPoint(x: 3000, y: 1640))

        #expect(frame.midX == right.frame.midX)
    }

    @Test func mouseOutsideEveryDisplayFallsBackToTheFirst() {
        let farFromEveryDisplay = CGPoint(x: -5000, y: 9000)
        // Below the raised right-hand display: inside the displays' bounding box, on neither.
        let inTheGapBelowRight = CGPoint(x: 3000, y: 100)

        #expect(panelFrame([primary, right], mouse: farFromEveryDisplay).midX == 960)
        #expect(panelFrame([right, primary], mouse: farFromEveryDisplay).midX == right.frame.midX)
        #expect(panelFrame([primary, right], mouse: inTheGapBelowRight).midX == 960)
    }

    @Test func frameIsOnWholePoints() {
        let notched = DisplayGeometry(
            id: 5,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))
        let frame = PanelPlacement.frame(
            displays: [notched], mouse: .zero, size: CGSize(width: 751, height: 480))

        // Unrounded: x = 380.5, top = 944 − 207.68 = 736.32.
        #expect(frame == CGRect(x: 381, y: 256, width: 751, height: 480))
    }

    @Test func noDisplaysStillGivesAFrameOfTheRequestedSize() {
        #expect(panelFrame([], mouse: .zero).size == size)
    }
}
