import OpenRayCore
import SwiftUI

@main
struct OpenRayApp: App {
    var body: some Scene {
        MenuBarExtra(AppInfo.name, systemImage: "magnifyingglass") {
            Button("Quit \(AppInfo.name)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
