import AppKit
import OpenRayCore

/// The one place the launcher sees key presses: a local monitor, installed while the panel is
/// key, that asks `KeyRouter` what each key means. It runs before key-equivalent dispatch, so ⌘
/// chords and plain keys take the same path. Keys the router declines go on to the field editor.
final class LauncherKeyMonitor {
    private let panel: NSPanel
    private let searchField: ShellSearchField
    private let model: LauncherModel
    private let router = KeyRouter()
    private var monitor: Any?

    init(panel: NSPanel, searchField: ShellSearchField, model: LauncherModel) {
        self.panel = panel
        self.searchField = searchField
        self.model = model
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            if route(event) {
                // Returning nil stops the event here.
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// - Returns: Whether the launcher consumed the event.
    private func route(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let chord = KeyChord(
            keyCode: event.keyCode,
            modifiers: HotKey.Modifiers(eventModifierFlags: event.modifierFlags.rawValue),
            characters: event.charactersIgnoringModifiers)
        let context = KeyRouter.Context(
            state: model.state,
            selectedItemShortcuts: model.selectedItemShortcuts,
            hasMarkedText: searchField.hasMarkedText)
        guard let intent = router.intent(for: chord, in: context) else { return false }
        model.apply(intent)
        return true
    }
}
