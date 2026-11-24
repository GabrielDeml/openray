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

    func hideAppIfFrontmost(at url: URL) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            isRunning(frontmost, from: url),
            // An app in front without a window, such as Safari after its last window was
            // closed, is opened instead: that brings up a window, where hiding would show
            // nothing at all.
            hasWindowOnScreen(frontmost.processIdentifier)
        else { return false }
        return frontmost.hide()
    }

    /// Also what `FileActionHost` asks for a found file and `ScriptActionHost` for a script.
    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quitApp(at url: URL) -> Bool {
        let runningCopies = NSWorkspace.shared.runningApplications.filter { app in
            isRunning(app, from: url)
        }
        for app in runningCopies {
            app.terminate()
        }
        return !runningCopies.isEmpty
    }

    func showAliasSettings(for item: ItemID) {
        onShowAliasSettings?(item)
    }

    /// Whether `app` is a copy of the app the index found at `url`.
    ///
    /// The index knows an app by the path it was found under, which may be a symbolic link,
    /// and an iPhone or iPad app by its wrapper. A running app reports where its own bundle
    /// really is, which for an iPhone or iPad app is inside `Wrapper`.
    private func isRunning(_ app: NSRunningApplication, from url: URL) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let indexed = url.resolvingSymlinksInPath().pathComponents
        let running = bundleURL.resolvingSymlinksInPath().pathComponents
        return running == indexed || running.dropLast() == indexed + ["Wrapper"]
    }

    /// Whether the process has a window in the current Space. Minimized windows do not count.
    /// Reading only the owner and layer of a window needs no Screen Recording permission.
    private func hasWindowOnScreen(_ pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        return (windows ?? []).contains { window in
            // Layer 0 holds the ordinary windows. Menus, the menu bar and panels sit above it.
            window[kCGWindowOwnerPID as String] as? pid_t == pid
                && window[kCGWindowLayer as String] as? Int == 0
        }
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
