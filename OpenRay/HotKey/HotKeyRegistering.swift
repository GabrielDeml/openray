import Foundation
import OpenRayCore

/// Names a global hotkey. The raw value is its Carbon hotkey ID.
nonisolated enum HotKeySlot: UInt32, Sendable {
    case launcher = 1
}

nonisolated enum HotKeyError: Error, Equatable {
    /// Another app holds the chord.
    case inUseByAnotherApp
    case rejected(OSStatus)
}

/// Registers global hotkeys. `HotKeyCenter` is the only implementation so far; the protocol is
/// where a test of `LauncherHotKey` puts a fake (docs/DESIGN.md, thin-shell rule).
protocol HotKeyRegistering {
    /// Gives `slot` the hotkey `key`, replacing the one it had. On failure the slot keeps its
    /// previous hotkey.
    func register(_ key: HotKey, for slot: HotKeySlot) -> Result<Void, HotKeyError>
    func unregister(_ slot: HotKeySlot)
    /// Releases every hotkey until `resumeAll()`, so that a recorder can see the chords.
    func suspendAll()
    /// Registers the suspended hotkeys again.
    /// - Returns: The slots whose hotkey could not be registered again, and why. They are left
    ///   without a hotkey, as after `unregister`.
    func resumeAll() -> [HotKeySlot: HotKeyError]
}
