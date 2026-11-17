/// Names a global hotkey: the launcher's own, or the one a command has been given.
public enum HotKeySlot: Hashable, Sendable {
    case launcher
    case command(ItemID)
}

public enum HotKeyError: Error, Equatable, Sendable {
    /// Another app holds the chord.
    case inUseByAnotherApp
    /// macOS refused the chord. The value is the `OSStatus` it answered with, as a plain
    /// integer because Core does not import Carbon.
    case rejected(Int32)
    /// OpenRay holds the chord itself, for this other slot.
    case heldBySlot(HotKeySlot)

    /// The error for a line in the log. It leaves out which command holds the chord: the ID
    /// of an app or a script can be a path, and these lines are public.
    public var logDescription: String {
        switch self {
        case .inUseByAnotherApp:
            return "in use by another app"
        case .rejected(let status):
            return "rejected with \(status)"
        case .heldBySlot(.launcher):
            return "held by the launcher"
        case .heldBySlot(.command):
            return "held by a command"
        }
    }
}

/// A hotkey that is not registered, and why: the launcher's, or the one of a command.
public struct HotKeyFailure: Equatable, Sendable {
    /// The chord that could not be registered.
    public let hotKey: HotKey
    public let error: HotKeyError

    public init(hotKey: HotKey, error: HotKeyError) {
        self.hotKey = hotKey
        self.error = error
    }
}

/// Registers global hotkeys. `HotKeyCenter` in the app target is the implementation that talks
/// to Carbon; the protocol is where the tests of `CommandHotKeys` put a fake
/// (docs/DESIGN.md, thin-shell rule).
@MainActor public protocol HotKeyRegistering {
    /// Gives `slot` the hotkey `key`, replacing the one it had. On failure the slot keeps its
    /// previous hotkey. A chord that another slot has, registered or suspended, is refused with
    /// `.heldBySlot`.
    func register(_ key: HotKey, for slot: HotKeySlot) -> Result<Void, HotKeyError>
    func unregister(_ slot: HotKeySlot)
    /// Releases every hotkey until `resumeAll()`, so that a recorder can see the chords.
    func suspendAll()
    /// Registers the suspended hotkeys again.
    /// - Returns: The slots whose hotkey could not be registered again, and why. They are left
    ///   without a hotkey, as after `unregister`.
    func resumeAll() -> [HotKeySlot: HotKeyError]
}
