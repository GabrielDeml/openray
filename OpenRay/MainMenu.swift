import AppKit

/// The main menu of an app that never shows a menu bar. It exists for its key equivalents: text
/// fields perform copy, paste, cut, undo and select-all through Edit-menu items, not through
/// `keyDown`, so without it ⌘V would do nothing in the search field or in Settings.
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        // AppKit treats the first item as the application menu.
        menu.addItem(submenu: NSMenu())
        menu.addItem(submenu: fileMenu())
        menu.addItem(submenu: editMenu())
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

extension NSMenu {
    fileprivate func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}
