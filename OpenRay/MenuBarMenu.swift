import OpenRayCore
import SwiftUI

/// The menu of the menu-bar item.
struct MenuBarMenu: View {
    let hotKey: LauncherHotKey
    let updates: UpdatesModel
    let openSettings: (SettingsPane.ID?) -> Void

    var body: some View {
        if updates.waitingUpdateVersion != nil {
            // A scheduled check found an update and Sparkle has not shown it (docs/DESIGN.md
            // §6.4). Asking for a check is what brings its window to the front.
            Button("Update Available…") {
                updates.checkForUpdates()
            }
            Divider()
        }
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
        if updates.isAvailable {
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheck)
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
