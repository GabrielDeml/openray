import AppKit
import OpenRayCore

/// The only code that checks or requests a privacy permission (docs/DESIGN.md §5.1).
///
/// Accessibility is not checked yet: nothing requires it until the paste path exists, so its
/// state reads as unknown.
final class PermissionCenter: PermissionChecking {
    private static let automationSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    private static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    func state(_ permission: Permission) async -> PermissionState {
        switch permission {
        case .accessibility:
            return .unknown
        case .automation(let bundleID):
            let status = await automationStatus(forBundleID: bundleID, askingUser: false)
            return AutomationPermission.state(forStatus: status)
        }
    }

    /// Shows the system's prompt for an Automation permission that has not been decided.
    /// macOS asks once; afterwards this only reports the answer.
    func request(_ permission: Permission) async -> PermissionState {
        switch permission {
        case .accessibility:
            return .unknown
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
        case .accessibility: page = Self.accessibilitySettings
        case .automation: page = Self.automationSettings
        }
        if let page {
            NSWorkspace.shared.open(page)
        }
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
