import AppKit

/// Launches an app without bringing it to the front. Apple events and the Automation prompt
/// both need their target to be running, and System Events usually is not.
func launchInBackground(appWithBundleID bundleID: String) async throws {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        throw CocoaError(.fileNoSuchFile)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
}
