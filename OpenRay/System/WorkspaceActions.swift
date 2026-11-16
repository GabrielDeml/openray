import AppKit
import OpenRayCore
import UniformTypeIdentifiers

/// What Core's app, quicklink, file and script actions ask of `NSWorkspace`. Core cannot use
/// AppKit itself.
final class WorkspaceActions: AppActionHost, QuicklinkOpening, FileActionHost, ScriptActionHost {
    /// Opens Settings › Commands on an item. Set by `AppDelegate`, which owns the window.
    var onShowAliasSettings: ((ItemID) -> Void)?

    // MARK: AppActionHost

    /// Opens the app, or brings it to the front when it is already running.
    func openApp(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Also what `FileActionHost` asks for a found file and `ScriptActionHost` for a script.
    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quitApp(at url: URL) -> Bool {
        // The index knows an app by the path it was found under, which may be a symbolic link;
        // a running app reports where its bundle really is.
        let bundlePath = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let runningCopies = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleURL?.resolvingSymlinksInPath().path(percentEncoded: false) == bundlePath
        }
        for app in runningCopies {
            app.terminate()
        }
        return !runningCopies.isEmpty
    }

    func showAliasSettings(for item: ItemID) {
        onShowAliasSettings?(item)
    }

    // MARK: QuicklinkOpening

    func open(_ url: URL, withAppBundleID bundleID: String?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        // An app that has been uninstalled since the quicklink was made is no reason to fail:
        // the default app for the URL opens it.
        if let bundleID,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: appURL, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }

    // MARK: FileActionHost

    func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }

    func moveToTrash(_ url: URL) async throws {
        try await moveFileToTrash(url)
    }

    func appsAbleToOpen(_ url: URL) -> [OpenWithApp] {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        return NSWorkspace.shared.urlsForApplications(toOpen: url).map { appURL in
            OpenWithApp(
                url: appURL,
                name: FileManager.default.displayName(atPath: appURL.path(percentEncoded: false)),
                isDefault: appURL.standardizedFileURL == defaultApp?.standardizedFileURL)
        }
    }

    func open(_ url: URL, withAppAt appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: appURL, configuration: configuration)
    }

    // MARK: ScriptActionHost

    func openInEditor(_ file: URL) async throws {
        // Always with the app that edits plain text, whatever kind of file the script says
        // it is. Opened the way Finder opens a file, an executable script can go to
        // Terminal, which runs it.
        let textEdit = URL(
            filePath: "/System/Applications/TextEdit.app", directoryHint: .isDirectory)
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText) ?? textEdit

        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(
            [file], withApplicationAt: editor, configuration: configuration)
    }

    func openFolder(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }
}

/// Moves the file to the Trash, off the main thread. The first time OpenRay touches a file in
/// Desktop, Documents or Downloads, macOS may ask the user about the folder, and the call
/// then waits for the answer. The launcher is still open at that point (§4.8) and has to go
/// on answering Esc.
@concurrent
private func moveFileToTrash(_ url: URL) async throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
}
