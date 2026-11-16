import AppKit
import OpenRayCore

/// What Core's app and quicklink actions ask of `NSWorkspace`. Core cannot use AppKit itself.
final class WorkspaceActions: AppActionHost, QuicklinkOpening {
    /// Opens Settings › Commands on an item. Set by `AppDelegate`, which owns the window.
    var onShowAliasSettings: ((ItemID) -> Void)?

    // MARK: AppActionHost

    /// Opens the app, or brings it to the front when it is already running.
    func openApp(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

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
}
