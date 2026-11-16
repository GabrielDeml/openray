import AppKit
@preconcurrency import ApplicationServices
import OpenRayCore

/// The only place a window of another app is read or moved (docs/DESIGN.md §4.7).
///
/// An Accessibility call blocks until the other app has answered, so the controller is an
/// actor on a queue of its own: a slow app then holds up neither the main thread nor a thread
/// of the cooperative pool. `AXUIElement` is not `Sendable`, and every element stays in here.
/// Where a window goes is decided by `WindowLayout` and `WindowMover` in Core; this finds the
/// window and gives the mover a way to read and write it.
///
/// Compiled only: no test makes an Accessibility call. What has to be tried by hand is in
/// docs/DESIGN.md §8, item 16.
actor AXWindowController {
    /// How long an app gets to answer one Accessibility call.
    private static let messagingTimeout: Float = 1.0

    /// Not in the public headers. Chromium and Electron apps have it.
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    private let queue = DispatchSerialQueue(label: "\(AppInfo.bundleIdentifier).windows")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var hasSetMessagingTimeout = false

    /// What Restore goes back to, for every window OpenRay has moved. By app first, so that
    /// the windows of an app that has quit can be forgotten. A window that was closed stays
    /// in here until then, which costs a few bytes.
    private var restoreRecords: [pid_t: [WindowKey: RestoreRecord]] = [:]

    /// Apps whose `AXEnhancedUserInterface` was switched off for a move and could not be
    /// switched on again, because the app had stopped answering by then.
    private var appsOwedEnhancedUserInterface: Set<pid_t> = []

    /// Applies the action to the focused window of the app with this process ID.
    func perform(
        _ action: WindowAction, pid: pid_t, displays: [DisplayGeometry], gap: CGFloat,
        stageStripInset: CGFloat, isDockOnTheLeft: Bool
    ) throws(WindowError) {
        setMessagingTimeoutOnce()
        forgetAppsThatQuit()
        switchEnhancedUserInterfaceBackOn()

        let app = AXUIElementCreateApplication(pid)
        let window = try focusedWindow(of: app)
        let key = WindowKey(element: window)

        // Chromium and Electron apps animate a resize of their own while this is on, and the
        // writes of a move then race with the animation. It is put back afterwards, also
        // when the move fails.
        let hasEnhancedUserInterface = Self.hasEnhancedUserInterface(app)
        if hasEnhancedUserInterface {
            // Without a look at the result: an app that does not take the value is moved as
            // it is.
            Self.setEnhancedUserInterface(of: app, to: false)
        }
        defer {
            if hasEnhancedUserInterface {
                let status = Self.setEnhancedUserInterface(of: app, to: true)
                // An app that stopped answering during the move does not take this either.
                // VoiceOver relies on the switch, so it is tried again at the next command.
                if status != .success {
                    appsOwedEnhancedUserInterface.insert(pid)
                }
            }
        }

        var record = restoreRecords[pid]?[key]
        // The record is kept whether the move succeeds or not: the mover brings it up to
        // date before it writes anything.
        defer { restoreRecords[pid, default: [:]][key] = record }
        try WindowMover.perform(
            action, on: AXWindowBackend(window: window), displays: displays, gap: gap,
            stageStripInset: stageStripInset, isDockOnTheLeft: isDockOnTheLeft, record: &record)
    }

    /// Bounds every Accessibility call of this process. Only a timeout on the system-wide
    /// element does that: one set on an app's element does not reach the windows read from it.
    ///
    /// Done at the first command and not when the controller is made, so that OpenRay makes
    /// no Accessibility call before the user has used something that needs the permission.
    private func setMessagingTimeoutOnce() {
        if hasSetMessagingTimeout { return }
        let status = AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(), Self.messagingTimeout)
        // A call that failed is made again at the next command.
        hasSetMessagingTimeout = status == .success
    }

    private func forgetAppsThatQuit() {
        for pid in Array(restoreRecords.keys) {
            if Self.hasQuit(pid) {
                restoreRecords[pid] = nil
            }
        }
        for pid in Array(appsOwedEnhancedUserInterface) {
            if Self.hasQuit(pid) {
                appsOwedEnhancedUserInterface.remove(pid)
            }
        }
    }

    private static func hasQuit(_ pid: pid_t) -> Bool {
        // There is no object for a process that is gone.
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        return app.isTerminated
    }

    /// Tries the apps that are owed the switch once more. Each one that still does not
    /// answer costs the command that is waiting one timeout.
    private func switchEnhancedUserInterfaceBackOn() {
        for pid in Array(appsOwedEnhancedUserInterface) {
            let app = AXUIElementCreateApplication(pid)
            if Self.setEnhancedUserInterface(of: app, to: true) == .success {
                appsOwedEnhancedUserInterface.remove(pid)
            }
        }
    }

    // MARK: Finding the window

    /// The window the user means: the one with the keyboard focus, or the app's main window
    /// when the focus is on something that is no ordinary window, a sheet or a popover.
    private func focusedWindow(of app: AXUIElement) throws(WindowError) -> AXUIElement {
        var focused: AXUIElement?
        do {
            focused = try Self.window(kAXFocusedWindowAttribute, of: app)
        } catch {
            // An app without a focused window may still have a main window. An app that
            // cannot be reached at all would only be waited for a second time.
            if error != .noWindow { throw error }
        }
        if let focused, Self.isStandardWindow(focused) {
            return focused
        }
        return try Self.window(kAXMainWindowAttribute, of: app)
    }

    private static func window(
        _ attribute: String, of app: AXUIElement
    ) throws(WindowError) -> AXUIElement {
        let value = try copyAttribute(attribute, of: app)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw .noWindow }
        // Core Foundation types have no conditional cast; the type was checked above.
        return value as! AXUIElement
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        let subrole = try? copyAttribute(kAXSubroleAttribute, of: window)
        return subrole as? String == kAXStandardWindowSubrole
    }

    // MARK: The app's AXEnhancedUserInterface

    private static func hasEnhancedUserInterface(_ app: AXUIElement) -> Bool {
        let value = try? copyAttribute(enhancedUserInterfaceAttribute, of: app)
        return value as? Bool ?? false
    }

    @discardableResult
    private static func setEnhancedUserInterface(of app: AXUIElement, to isOn: Bool) -> AXError {
        let value: CFBoolean = isOn ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(app, enhancedUserInterfaceAttribute as CFString, value)
    }
}

/// Reads one attribute. A failed call becomes the `WindowError` its status stands for.
private nonisolated func copyAttribute(
    _ attribute: String, of element: AXUIElement
) throws(WindowError) -> CFTypeRef {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard status == .success, let value else {
        throw WindowError(axStatus: status.rawValue)
    }
    return value
}

/// One window, read and written through the Accessibility API. Frames are in AX coordinates,
/// as the API has them. Every failed call becomes the `WindowError` its status stands for.
private nonisolated struct AXWindowBackend: WindowBackend {
    /// Not in the public headers.
    private static let fullScreenAttribute = "AXFullScreen"

    let window: AXUIElement

    func isFullScreen() throws(WindowError) -> Bool {
        do {
            let value = try copyAttribute(Self.fullScreenAttribute, of: window)
            return value as? Bool ?? false
        } catch {
            // A window without the attribute is not full screen. An app that cannot be
            // reached at all is a failure here as anywhere.
            if error != .noWindow { throw error }
            return false
        }
    }

    func readFrame() throws(WindowError) -> CGRect {
        let position = try copyAttribute(kAXPositionAttribute, of: window)
        let size = try copyAttribute(kAXSizeAttribute, of: window)
        guard CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else {
            throw .noWindow
        }

        var frame = CGRect.zero
        // Checked above, as for the window element itself.
        let hasOrigin = AXValueGetValue(position as! AXValue, .cgPoint, &frame.origin)
        let hasSize = AXValueGetValue(size as! AXValue, .cgSize, &frame.size)
        guard hasOrigin, hasSize else { throw .noWindow }
        return frame
    }

    func isSizeSettable() throws(WindowError) -> Bool {
        var isSettable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            window, kAXSizeAttribute as CFString, &isSettable)
        if status != .success {
            throw WindowError(axStatus: status.rawValue)
        }
        return isSettable.boolValue
    }

    func write(size: CGSize) throws(WindowError) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { throw .noWindow }
        try write(value, to: kAXSizeAttribute)
    }

    func write(position: CGPoint) throws(WindowError) {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { throw .noWindow }
        try write(value, to: kAXPositionAttribute)
    }

    private func write(_ value: AXValue, to attribute: String) throws(WindowError) {
        let status = AXUIElementSetAttributeValue(window, attribute as CFString, value)
        if status != .success {
            throw WindowError(axStatus: status.rawValue)
        }
    }
}

/// A window as a dictionary key. Two element objects for one window are different objects
/// that Core Foundation calls equal, so that is what the key goes by.
private nonisolated struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (first: WindowKey, second: WindowKey) -> Bool {
        CFEqual(first.element, second.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
