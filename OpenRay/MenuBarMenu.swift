import OpenRayCore
import SwiftUI

/// The menu of the menu-bar item.
struct MenuBarMenu: View {
    let hotKey: LauncherHotKey
    let openSettings: (SettingsPane.ID?) -> Void

    var body: some View {
        if !hotKey.isActive {
            Button("Hotkey inactive — open Settings") {
                openSettings(SettingsPane.generalID)
            }
            Divider()
        } else if hotKey.usesFallback {
            let chord = HotKeyFormatter.string(for: hotKey.hotKey)
            Button("Hotkey is \(chord) for now — open Settings") {
                openSettings(SettingsPane.generalID)
            }
            Divider()
        }
        Button("Settings…") {
            openSettings(nil)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit \(AppInfo.name)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
