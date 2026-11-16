import AppKit
import OpenRayCore

/// The only code that checks or requests a privacy permission (docs/DESIGN.md §5.1).
final class PermissionCenter: PermissionChecking {
    private static let automationSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    private static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    func state(_ permission: Permission) async -> PermissionState {
        switch permission {
        case .accessibility:
            return accessibilityState()
        case .automation(let bundleID):
            let status = await automationStatus(forBundleID: bundleID, askingUser: false)
            return AutomationPermission.state(forStatus: status)
        }
    }

    /// Shows the system's prompt for an Automation permission that has not been decided.
    /// macOS asks once; afterwards this only reports the answer.
    ///
    /// For Accessibility the prompt only points at System Settings and does not wait for the
    /// user, so the state that comes back is the one from before they have done anything.
    func request(_ permission: Permission) async -> PermissionState {
        switch permission {
        case .accessibility:
            promptForAccessibility()
            return accessibilityState()
        case .automation(let bundleID):
            var status = await automationStatus(forBundleID: bundleID, askingUser: true)
            if status == AutomationPermission.targetNotRunning {
                // macOS decides about a running target only. System Events for one is
                // usually not running.
                do {
                    try await launchInBackground(appWithBundleID: bundleID)
                } catch {
                    Log.permissions.error(
                        "Cannot launch \(bundleID, privacy: .public) to ask for Automation: \(error)"
                    )
                    return .unknown
                }
                status = await automationStatus(forBundleID: bundleID, askingUser: true)
            }
            return AutomationPermission.state(forStatus: status)
        }
    }

    func openSystemSettings(for permission: Permission) {
        let page: URL?
        switch permission {
        case .accessibility:
            // The page lists only the apps that have asked. Asking is what puts OpenRay
            // there, so that the user has a switch to turn on and need not add the app by
            // hand. macOS shows its own alert for it the first time.
            if !AXIsProcessTrusted() {
                promptForAccessibility()
            }
            page = Self.accessibilitySettings
        case .automation:
            page = Self.automationSettings
        }
        if let page {
            NSWorkspace.shared.open(page)
        }
    }

    /// macOS only says whether OpenRay is trusted, not whether the user was ever asked. So an
    /// Accessibility permission that is missing reads as denied, never as not determined.
    private func accessibilityState() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private func promptForAccessibility() {
        // The key is `kAXTrustedCheckOptionPrompt`, written out: Swift 6 refuses a reference
        // to that global because it is not concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        // The prompt comes up a moment later, and the result is the state from before it.
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Asks macOS whether OpenRay may send Apple events to an app. Off the main thread, where the
/// call's header warns that it can take arbitrarily long, and where with `askingUser` it waits
/// for the user to answer the prompt.
@concurrent
private func automationStatus(forBundleID bundleID: String, askingUser: Bool) async -> OSStatus {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    return AEDeterminePermissionToAutomateTarget(
        target.aeDesc, typeWildCard, typeWildCard, askingUser)
}
