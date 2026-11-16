import Foundation

// What the permission screen and Settings call the permissions and their states.

extension Permission {
    /// The name of the permission as System Settings groups it, with the app an Automation
    /// permission is about.
    public var title: String {
        switch self {
        case .accessibility:
            return String(
                localized: "Accessibility", bundle: .module,
                comment: "The name of the Accessibility permission, as in System Settings.")
        case .automation(let bundleID):
            let target = Self.automationTargetName(forBundleID: bundleID)
            return String(
                localized: "Automation: \(target)", bundle: .module,
                comment: "The permission to send commands to another app, which is named.")
        }
    }

    /// What to call the app that an Automation permission is about. The targets OpenRay's own
    /// commands use have names; any other is shown by its bundle identifier.
    public static func automationTargetName(forBundleID bundleID: String) -> String {
        switch bundleID {
        case AppleEventDescription.finderBundleID:
            return String(
                localized: "Finder", bundle: .module, comment: "The name of the Finder app.")
        case AppleEventDescription.systemEventsBundleID:
            return String(
                localized: "System Events", bundle: .module,
                comment: "The name of the System Events app, as System Settings shows it.")
        case AppleEventDescription.loginWindowBundleID:
            return String(
                localized: "the login window", bundle: .module,
                comment: "The system process that restarts, shuts down and logs out.")
        default:
            return bundleID
        }
    }
}

extension PermissionState {
    /// The state in a word or two, for Settings and the permission screen.
    public var label: String {
        switch self {
        case .granted:
            return String(
                localized: "Allowed", bundle: .module,
                comment: "The state of a permission the user has granted.")
        case .denied:
            // Not "Denied": Accessibility reads like this before the user was ever asked,
            // because macOS does not say whether it has asked.
            return String(
                localized: "Not allowed", bundle: .module,
                comment: "The state of a permission OpenRay does not have.")
        case .notDetermined:
            return String(
                localized: "Not asked yet", bundle: .module,
                comment: "The state of a permission macOS has not asked the user about.")
        case .unknown:
            return String(
                localized: "Not known", bundle: .module,
                comment: "The state of a permission that could not be found out.")
        }
    }
}
