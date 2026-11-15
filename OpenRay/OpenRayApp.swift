import OpenRayCore
import SwiftUI

@main
struct OpenRayApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra(AppInfo.name, systemImage: "magnifyingglass") {
            MenuBarMenu(hotKey: appDelegate.launcherHotKey) { pane in
                appDelegate.showSettings(pane: pane)
            }
        }
    }
}
