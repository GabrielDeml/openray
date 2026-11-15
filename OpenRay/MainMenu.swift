import AppKit
import OpenRayCore

/// The main menu of an app that never shows a menu bar. It exists for its key equivalents: text
/// fields perform copy, paste, cut, undo and select-all through Edit-menu items, not through
/// `keyDown`, so without it ⌘V would do nothing in the search field or in Settings. ⌘Q and ⌘,
/// come from a menu in the same way.
enum MainMenu {
    /// - Parameter appDelegate: Opens Settings for the Settings… item.
    static func make(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        // AppKit treats the first item as the application menu.
        menu.addItem(submenu: applicationMenu(appDelegate: appDelegate))
        menu.addItem(submenu: fileMenu())
        menu.addItem(submenu: editMenu())
        return menu
    }

    /// The same Settings… and Quit as in the menu-bar menu (`MenuBarMenu`). That menu's key
    /// equivalents work only while it is open; these work whenever a window of OpenRay is key.
    private static func applicationMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        let settings = menu.addItem(
            withTitle: String(localized: "Settings…"),
            action: #selector(AppDelegate.showSettingsFromMainMenu(_:)), keyEquivalent: ",")
        // Without a target the action would be offered to `NSApp.delegate`, which under the
        // SwiftUI lifecycle is an object of SwiftUI's and not `AppDelegate`.
        settings.target = appDelegate
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Quit \(AppInfo.name)"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(
            withTitle: String(localized: "Close Window"),
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        // `undo:` and `redo:` are not declared anywhere `#selector` can name. The doubled
        // parentheses stop the compiler from suggesting it anyway.
        menu.addItem(
            withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        // A capital key equivalent means Shift: ⇧⌘Z.
        menu.addItem(
            withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)),
            keyEquivalent: "x")
        menu.addItem(
            withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)),
            keyEquivalent: "c")
        menu.addItem(
            withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)),
            keyEquivalent: "v")
        menu.addItem(
            withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        return menu
    }
}

extension AppDelegate {
    /// The action of Settings… in the application menu.
    @objc fileprivate func showSettingsFromMainMenu(_ sender: Any?) {
        showSettings()
    }
}

extension NSMenu {
    fileprivate func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}
