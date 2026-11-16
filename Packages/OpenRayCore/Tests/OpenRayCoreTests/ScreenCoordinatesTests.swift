import CoreGraphics
import Testing

import OpenRayCore

@Suite struct ScreenCoordinatesTests {
    /// The height of a 1440 × 900 primary display.
    private let primaryMaxY: CGFloat = 900

    @Test func displayWhoseTopIsAboveThePrimarysHasNegativeYInAX() {
        // It hangs lower than the primary display, and its top edge is still 80 points above
        // the primary's.
        let ax = ScreenCoordinates.toAX(rect(-1920, -100, 1920, 1080), primaryMaxY: primaryMaxY)

        #expect(ax == rect(-1920, -80, 1920, 1080))
    }

    @Test func displayAboveThePrimaryHasNegativeYInAX() {
        let ax = ScreenCoordinates.toAX(rect(-240, 900, 1920, 1080), primaryMaxY: primaryMaxY)

        #expect(ax == rect(-240, -1080, 1920, 1080))
    }

    @Test func windowIsMeasuredFromTheBottomAgainInAppKit() {
        let appKit = ScreenCoordinates.toAppKit(rect(100, 50, 800, 600), primaryMaxY: primaryMaxY)

        #expect(appKit == rect(100, 250, 800, 600))
    }

    @Test(arguments: [rect(100, 50, 800, 600), rect(-1920, -100, 1920, 1080), rect(0, 0, 1, 1)])
    func roundTripGivesTheRectangleBack(_ original: CGRect) {
        let ax = ScreenCoordinates.toAX(original, primaryMaxY: primaryMaxY)

        #expect(ScreenCoordinates.toAppKit(ax, primaryMaxY: primaryMaxY) == original)
    }
}
