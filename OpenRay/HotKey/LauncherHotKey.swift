import Observation
import OpenRayCore

/// The launcher's global hotkey: keeps the stored preference and the registration in step, and
/// says why the hotkey is not working when it is not.
@Observable
final class LauncherHotKey {
    nonisolated struct Failure: Equatable {
        /// The chord that could not be registered.
        let hotKey: HotKey
        let error: HotKeyError
    }

    /// What the default falls back to when macOS refuses an Option-only chord.
    static let fallback = HotKey(
        keyCode: UInt32(VirtualKey.space), modifiers: [.control, .option])

    /// Whether a hotkey is registered. While it is not, only the menu-bar item reaches OpenRay.
    private(set) var isActive = false
    /// The last registration that failed; cleared by the next one that succeeds.
    private(set) var failure: Failure?
    /// Whether the default could not be registered at launch and `fallback` stands in for it
    /// until OpenRay quits. The preference keeps the default, so every launch tries it again.
    private(set) var usesFallback = false

    @ObservationIgnored private let registrar: any HotKeyRegistering
    @ObservationIgnored private let preferences: Preferences

    init(registrar: any HotKeyRegistering, preferences: Preferences) {
        self.registrar = registrar
        self.preferences = preferences
    }

    /// The chord that opens the launcher while `isActive` is true: the one the user chose, or
    /// the fallback standing in for it.
    var hotKey: HotKey { usesFallback ? Self.fallback : preferences.launcherHotKey }

    /// Registers the stored hotkey. If that is the default and macOS refuses it, the fallback is
    /// registered in its place, without being stored.
    func registerAtLaunch() {
        let stored = preferences.launcherHotKey
        if tryToRegister(stored) { return }
        // Only the default has a stand-in. A chord the user chose stays unregistered, and
        // Settings shows why.
        guard stored == .launcherDefault else { return }

        let refusalOfDefault = failure
        if tryToRegister(Self.fallback) {
            usesFallback = true
        } else {
            // The recorder still shows the default, so that is the failure to explain.
            failure = refusalOfDefault
        }
    }

    /// Makes `key` the launcher hotkey. If it cannot be registered, the previous hotkey stays.
    func record(_ key: HotKey) {
        guard tryToRegister(key) else { return }
        preferences.launcherHotKey = key
        usesFallback = false
    }

    /// Asks the registrar for `key`. Success sets `isActive`; a refusal is kept in `failure`.
    private func tryToRegister(_ key: HotKey) -> Bool {
        switch registrar.register(key, for: .launcher) {
        case .success:
            isActive = true
            failure = nil
            return true
        case .failure(let error):
            failure = Failure(hotKey: key, error: error)
            Log.launcher.error(
                "Hotkey registration failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The recorder must see every chord, including the current hotkey.
    func beginRecording() {
        registrar.suspendAll()
    }

    func endRecording() {
        registrar.resumeAll()
    }
}
