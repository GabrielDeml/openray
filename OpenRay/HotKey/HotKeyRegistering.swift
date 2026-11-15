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

/// Registers global hotkeys. `HotKeyCenter` is the real implementation; tests use a fake.
protocol HotKeyRegistering {
    /// Gives `slot` the hotkey `key`, replacing the one it had. On failure the slot keeps its
    /// previous hotkey.
    func register(_ key: HotKey, for slot: HotKeySlot) -> Result<Void, HotKeyError>
    func unregister(_ slot: HotKeySlot)
    /// Releases every hotkey until `resumeAll()`, so that a recorder can see the chords.
    func suspendAll()
    func resumeAll()
}
