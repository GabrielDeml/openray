import Foundation

/// What the actions of a script ask of the app target, which has `NSWorkspace`
/// (docs/DESIGN.md §4.10). Tests put a fake in its place, so that no test opens an editor or
/// a Finder window.
@MainActor public protocol ScriptActionHost: AnyObject, Sendable {
    /// Opens the file in the app that edits plain text. Never the way Finder opens a file:
    /// for an executable script that can mean running it in Terminal.
    func openInEditor(_ file: URL) async throws
    /// Opens the folder in a Finder window.
    func openFolder(_ folder: URL)
    func showInFinder(_ url: URL)
}

/// The actions on a script's file that do not run it. A script in search has them, and so has
/// a file in the Script Diagnostics list.
enum ScriptFileActions {
    static func openInEditor(_ path: String, host: any ScriptActionHost) -> ActionDescriptor {
        let shortcut = KeyChord(keyCode: VirtualKey.ansiO, modifiers: [.command], characters: "o")

        return ActionDescriptor(
            id: ActionID(rawValue: "open-in-editor"), title: ScriptTitles.openInEditor,
            icon: .symbol("pencil"), shortcut: shortcut
        ) { context in
            // The editor's window must not come up behind the panel (§4.1.6).
            context.closeLauncher()
            try await host.openInEditor(URL(filePath: path))
            return .closeLauncher
        }
    }

    static func showInFinder(_ path: String, host: any ScriptActionHost) -> ActionDescriptor {
        ActionDescriptor(
            id: ActionID(rawValue: "show-in-finder"), title: ActionTitles.showInFinder,
            icon: .symbol("folder")
        ) { context in
            context.closeLauncher()
            host.showInFinder(URL(filePath: path))
            return .closeLauncher
        }
    }

    static func copyPath(_ path: String) -> ActionDescriptor {
        ActionDescriptor(
            id: ActionID(rawValue: "copy-path"), title: ActionTitles.copyPath,
            icon: .symbol("doc.on.doc")
        ) { context in
            context.copy(.text(path, cursorOffsetFromEnd: nil))
            return .copiedToClipboard
        }
    }
}
