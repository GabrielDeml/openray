import CoreGraphics
import Testing

import OpenRayCore

/// A window that lives in the test and behaves like the apps that are hard to move. Frames
/// are in AX coordinates.
private final class FakeWindow: WindowBackend {
    enum Write: Equatable {
        case size(CGSize)
        case position(CGPoint)
    }

    var frame: CGRect
    var isFullScreenWindow = false
    var canSetSize = true
    /// The window gets no smaller than this.
    var minimumSize = CGSize.zero
    /// As a terminal: the width is 4 points of padding and a whole number of columns this wide.
    var columnWidth: CGFloat?
    /// The displays, in AX coordinates. A window cannot be made larger than the display it
    /// is on at that moment, which is what clamps the first size write on the way to a
    /// larger display.
    var displayFrames: [CGRect] = []
    var readError: WindowError?
    var writeError: WindowError?
    /// How many writes go through before `writeError` is thrown.
    var writesBeforeTheError = 0

    /// Every write that was asked for, also one that failed.
    private(set) var writes: [Write] = []

    init(frame: CGRect) {
        self.frame = frame
    }

    func isFullScreen() throws(WindowError) -> Bool {
        if let readError { throw readError }
        return isFullScreenWindow
    }

    func readFrame() throws(WindowError) -> CGRect {
        if let readError { throw readError }
        return frame
    }

    func isSizeSettable() throws(WindowError) -> Bool {
        if let readError { throw readError }
        return canSetSize
    }

    func write(size: CGSize) throws(WindowError) {
        writes.append(.size(size))
        if let writeError, writes.count > writesBeforeTheError { throw writeError }

        var width = size.width
        var height = size.height
        if let display = displayFrames.first(where: { $0.contains(frame.origin) }) {
            width = min(width, display.width)
            height = min(height, display.height)
        }
        if let columnWidth {
            let columns = ((width - 4) / columnWidth).rounded(.down)
            width = 4 + columns * columnWidth
        }
        width = max(width, minimumSize.width)
        height = max(height, minimumSize.height)
        frame.size = CGSize(width: width, height: height)
    }

    func write(position: CGPoint) throws(WindowError) {
        writes.append(.position(position))
        if let writeError, writes.count > writesBeforeTheError { throw writeError }
        frame.origin = position
    }
}

// Unless a test says otherwise, the window is on `TestDisplays.primary`, whose work area is
// (0, 25, 1440, 815) in AX coordinates.
@Suite struct WindowMoverTests {
    private let window = FakeWindow(frame: rect(100, 100, 800, 600))

    /// Applies the action to `window` and keeps `record` up to date, as the app does.
    private func perform(
        _ action: WindowAction, record: inout RestoreRecord?,
        displays: [DisplayGeometry] = [TestDisplays.primary]
    ) throws(WindowError) {
        try WindowMover.perform(
            action, on: window, displays: displays, gap: 0, stageStripInset: 0,
            isDockOnTheLeft: false, record: &record)
    }

    /// For the tests that are not about Restore.
    private func perform(_ action: WindowAction) throws(WindowError) {
        var record: RestoreRecord?
        try perform(action, record: &record)
    }

    // MARK: A window that does as it is told

    @Test func windowIsResizedMovedAndResizedOnceMore() throws {
        try perform(.rightHalf)

        #expect(window.frame == rect(720, 25, 720, 815))
        let size = CGSize(width: 720, height: 815)
        #expect(window.writes == [.size(size), .position(CGPoint(x: 720, y: 25)), .size(size)])
    }

    @Test func windowAlreadyInPlaceIsNotWrittenTo() {
        window.frame = rect(720, 25, 720, 815)

        #expect(throws: WindowError.unchanged) { try perform(.rightHalf) }
        #expect(window.writes.isEmpty)
    }

    @Test func fullScreenWindowIsLeftAlone() {
        window.isFullScreenWindow = true

        #expect(throws: WindowError.fullScreen) { try perform(.leftHalf) }
        #expect(window.writes.isEmpty)
    }

    @Test(arguments: [WindowAction.nextDisplay, .previousDisplay])
    func displayMoveOnASingleDisplayHasNowhereToGo(_ action: WindowAction) {
        #expect(throws: WindowError.noOtherDisplay) { try perform(action) }
        #expect(window.writes.isEmpty)
    }

    // MARK: A window that refuses its size

    @Test(arguments: [
        // Against the right edge, in line with the left edge, and centred on its third.
        (WindowAction.rightHalf, rect(540, 25, 900, 815)),
        (.leftHalf, rect(0, 25, 900, 815)),
        (.centerThird, rect(270, 25, 900, 815)),
    ])
    func windowWithAMinimumWidthKeepsToTheEdgeOfItsTile(
        _ action: WindowAction, _ expected: CGRect
    ) throws {
        window.minimumSize = CGSize(width: 900, height: 0)

        try perform(action)

        #expect(window.frame == expected)
    }

    @Test func windowTooWideForTheLeftHalfIsNotMovedAgainBecauseItsLeftEdgeIsInPlace() throws {
        window.minimumSize = CGSize(width: 900, height: 0)

        try perform(.leftHalf)

        let size = CGSize(width: 720, height: 815)
        #expect(window.writes == [.size(size), .position(CGPoint(x: 0, y: 25)), .size(size)])
    }

    @Test func windowWithAMinimumHeightKeepsToTheBottomOfTheBottomHalf() throws {
        window.minimumSize = CGSize(width: 0, height: 600)

        try perform(.bottomHalf)

        #expect(window.frame == rect(0, 240, 1440, 600))
    }

    @Test func terminalThatRoundsItsWidthIsPutAgainstTheRightEdge() throws {
        // 102 columns of 7 points and the padding make 718 points of the 720 asked for.
        window.columnWidth = 7

        try perform(.rightHalf)

        #expect(window.frame == rect(722, 25, 718, 815))
    }

    @Test func roundingByOnePointIsNotWorthAnotherMove() throws {
        // 143 columns of 5 points and the padding make 719 points.
        window.columnWidth = 5

        try perform(.rightHalf)

        #expect(window.frame == rect(720, 25, 719, 815))
        #expect(window.writes.count == 3)
    }

    // The window is as near to its target as it gets. Written to again, it would jump to
    // the target's origin and back.
    @Test func sameCommandAgainOnAWindowWithAMinimumWidthWritesNothing() throws {
        window.minimumSize = CGSize(width: 900, height: 0)
        var record: RestoreRecord?
        try perform(.rightHalf, record: &record)
        let writesOfTheFirstRun = window.writes

        #expect(throws: WindowError.unchanged) { try perform(.rightHalf, record: &record) }
        #expect(window.writes == writesOfTheFirstRun)
    }

    @Test(arguments: [7, 5] as [CGFloat])
    func sameCommandAgainOnATerminalWritesNothing(_ columnWidth: CGFloat) throws {
        window.columnWidth = columnWidth
        var record: RestoreRecord?
        try perform(.rightHalf, record: &record)
        let writesOfTheFirstRun = window.writes

        #expect(throws: WindowError.unchanged) { try perform(.rightHalf, record: &record) }
        #expect(window.writes == writesOfTheFirstRun)
    }

    @Test func otherCommandOnAWindowThatRefusedItsSizeStillMovesIt() throws {
        window.minimumSize = CGSize(width: 900, height: 0)
        var record: RestoreRecord?
        try perform(.rightHalf, record: &record)

        try perform(.leftHalf, record: &record)

        #expect(window.frame == rect(0, 25, 900, 815))
    }

    // MARK: A window whose size cannot be set

    @Test(arguments: [
        (WindowAction.rightHalf, CGPoint(x: 640, y: 25)),
        // Centred in the work area, as Center Window would put it.
        (.maximize, CGPoint(x: 320, y: 133)),
    ])
    func windowOfAFixedSizeIsOnlyMoved(_ action: WindowAction, _ expected: CGPoint) throws {
        window.canSetSize = false

        try perform(action)

        #expect(window.frame == CGRect(origin: expected, size: CGSize(width: 800, height: 600)))
        #expect(window.writes == [.position(expected)])
    }

    @Test func sameCommandAgainOnAWindowOfAFixedSizeWritesNothing() throws {
        window.canSetSize = false
        var record: RestoreRecord?
        try perform(.maximize, record: &record)

        #expect(throws: WindowError.unchanged) { try perform(.maximize, record: &record) }
        #expect(window.writes.count == 1)
    }

    // MARK: To another display

    @Test func sizeThatWasClampedOnTheSmallerDisplayIsWrittenAgainOnTheLargerOne() throws {
        let displays = [TestDisplays.primary, TestDisplays.lowerLeft]
        window.displayFrames = [rect(0, 0, 1440, 900), rect(-1920, -80, 1920, 1080)]
        // Maximized on the primary display, so it is maximized on the other one too.
        window.frame = rect(0, 25, 1440, 815)

        var record: RestoreRecord?
        try perform(.nextDisplay, record: &record, displays: displays)

        #expect(window.frame == rect(-1920, -55, 1920, 1055))
        let size = CGSize(width: 1920, height: 1055)
        #expect(
            window.writes == [.size(size), .position(CGPoint(x: -1920, y: -55)), .size(size)])
    }

    // MARK: An app that stops answering

    @Test func failureToReadTheWindowIsPassedOnAndNothingIsWritten() {
        window.readError = .appNotResponding

        #expect(throws: WindowError.appNotResponding) { try perform(.leftHalf) }
        #expect(window.writes.isEmpty)
    }

    @Test func failureToWriteIsPassedOnAndNothingMoreIsWritten() {
        window.writeError = .appNotResponding

        #expect(throws: WindowError.appNotResponding) { try perform(.leftHalf) }
        // The write that failed, and none after it.
        #expect(window.writes.count == 1)
    }

    // MARK: Restore

    @Test func restoreLeadsBackToWhereTheWindowWasBeforeTheFirstCommand() throws {
        let original = window.frame
        var record: RestoreRecord?

        try perform(.leftHalf, record: &record)
        try perform(.topRight, record: &record)
        try perform(.restore, record: &record)

        #expect(window.frame == original)
        #expect(record == nil)
    }

    @Test func restoreLeadsBackToWhereTheUserPutTheWindowSince() throws {
        var record: RestoreRecord?
        try perform(.leftHalf, record: &record)

        let draggedTo = rect(300, 200, 640, 480)
        window.frame = draggedTo
        try perform(.topRight, record: &record)
        try perform(.restore, record: &record)

        #expect(window.frame == draggedTo)
    }

    @Test func windowThatOpenRayNeverMovedHasNothingToRestore() {
        var record: RestoreRecord?

        #expect(throws: WindowError.nothingToRestore) { try perform(.restore, record: &record) }
        #expect(window.writes.isEmpty)
    }

    @Test func secondRestoreInARowHasNothingToRestore() throws {
        var record: RestoreRecord?
        try perform(.leftHalf, record: &record)
        try perform(.restore, record: &record)

        #expect(throws: WindowError.nothingToRestore) { try perform(.restore, record: &record) }
    }

    @Test func restoreOfAWindowThatTheUserPutBackAlreadyChangesNothing() throws {
        let original = window.frame
        var record: RestoreRecord?
        try perform(.leftHalf, record: &record)
        let writesOfTheCommand = window.writes

        window.frame = original

        #expect(throws: WindowError.unchanged) { try perform(.restore, record: &record) }
        #expect(window.writes == writesOfTheCommand)
    }

    // The window was on a display that has been unplugged since, and macOS has put it on
    // the one that is left.
    @Test func restoreDoesNotSendAWindowToADisplayThatIsGone() throws {
        let bothDisplays = [TestDisplays.primary, TestDisplays.levelRight]
        let onTheRightDisplay = rect(1600, 300, 800, 400)
        window.frame = onTheRightDisplay
        var record: RestoreRecord?
        try perform(.leftHalf, record: &record, displays: bothDisplays)
        let writesOfTheCommand = window.writes

        window.frame = rect(100, 100, 720, 775)
        #expect(throws: WindowError.nothingToRestore) {
            try perform(.restore, record: &record, displays: [TestDisplays.primary])
        }
        #expect(window.writes == writesOfTheCommand)

        // With the display back, so is the place on it.
        try perform(.restore, record: &record, displays: bothDisplays)
        #expect(window.frame == onTheRightDisplay)
    }

    @Test func placeToGoBackToIsKeptWhenTheAppStopsAnsweringHalfway() throws {
        let original = window.frame
        var record: RestoreRecord?
        window.writeError = .appNotResponding
        #expect(throws: WindowError.appNotResponding) { try perform(.leftHalf, record: &record) }

        window.writeError = nil
        window.frame = rect(0, 25, 720, 600)
        try perform(.restore, record: &record)

        #expect(window.frame == original)
    }

    // Trying the command once more is what one does after "App not responding".
    @Test func placeToGoBackToIsKeptWhenTheCommandThatFailedHalfwayIsRepeated() throws {
        let original = window.frame
        var record: RestoreRecord?
        // The size is written and the position is not.
        window.writeError = .appNotResponding
        window.writesBeforeTheError = 1
        #expect(throws: WindowError.appNotResponding) { try perform(.leftHalf, record: &record) }
        #expect(window.frame == rect(100, 100, 720, 815))

        window.writeError = nil
        try perform(.leftHalf, record: &record)
        #expect(window.frame == rect(0, 25, 720, 815))
        try perform(.restore, record: &record)

        #expect(window.frame == original)
    }

    @Test func placeToGoBackToIsKeptWhenRestoreItselfFailsHalfway() throws {
        let original = window.frame
        var record: RestoreRecord?
        try perform(.rightHalf, record: &record)

        // The size is written and the position is not.
        window.writeError = .appNotResponding
        window.writesBeforeTheError = window.writes.count + 1
        #expect(throws: WindowError.appNotResponding) { try perform(.restore, record: &record) }
        #expect(window.frame == rect(720, 25, 800, 600))

        window.writeError = nil
        try perform(.leftHalf, record: &record)
        try perform(.restore, record: &record)

        #expect(window.frame == original)
    }

    @Test func commandThatFailedBeforeItChangedAnythingIsNotTakenForDoneWhenRepeated() throws {
        var record: RestoreRecord?
        window.writeError = .appNotResponding
        #expect(throws: WindowError.appNotResponding) { try perform(.rightHalf, record: &record) }

        window.writeError = nil
        try perform(.rightHalf, record: &record)

        #expect(window.frame == rect(720, 25, 720, 815))
    }

    @Test func recordSaysWhereTheWindowWasLeft() throws {
        window.minimumSize = CGSize(width: 900, height: 0)
        var record: RestoreRecord?

        try perform(.rightHalf, record: &record)

        // The frame the window ended up with is not the one it was asked to take.
        let rightHalf = RestoreRecord.Move(
            target: rect(720, 25, 720, 815), result: rect(540, 25, 900, 815))
        #expect(
            record == RestoreRecord(restoreFrame: rect(100, 100, 800, 600), lastMove: rightHalf))
    }

    @Test func recordOfACommandThatFailedHalfwayHasNoLastMove() {
        var record: RestoreRecord?
        window.writeError = .appNotResponding

        #expect(throws: WindowError.appNotResponding) { try perform(.leftHalf, record: &record) }

        #expect(record == RestoreRecord(restoreFrame: rect(100, 100, 800, 600), lastMove: nil))
    }
}

@Suite struct WindowErrorTests {
    // The codes of AXError.h.
    @Test func accessibilityThatIsSwitchedOffReadsAsNotTrusted() {
        #expect(WindowError(axStatus: -25211) == .notTrusted)  // kAXErrorAPIDisabled
    }

    @Test func messagingThatFailedReadsAsAnAppThatDoesNotRespond() {
        #expect(WindowError(axStatus: -25204) == .appNotResponding)  // kAXErrorCannotComplete
    }

    @Test(arguments: [
        Int32(-25212),  // kAXErrorNoValue
        -25205,  // kAXErrorAttributeUnsupported
        -25200,  // kAXErrorFailure
        -1,
    ])
    func everyOtherFailureReadsAsNoWindow(_ status: Int32) {
        #expect(WindowError(axStatus: status) == .noWindow)
    }
}
