/// What macOS says about one permission (docs/DESIGN.md §5.1).
public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    /// The user has not been asked yet.
    case notDetermined
    /// It could not be found out: for Automation, the target app is not running.
    case unknown
}

/// Checks and requests permissions. The app target's `PermissionCenter` is the implementation
/// and the only code that talks to the system about them; Core reaches it through this protocol
/// so that tests can put a fake in its place.
@MainActor public protocol PermissionChecking: AnyObject {
    func state(_ permission: Permission) async -> PermissionState
    /// Shows the system's prompt where there is one, and returns the state afterwards.
    func request(_ permission: Permission) async -> PermissionState
    func openSystemSettings(for permission: Permission)
}

/// Decides what the launcher does about a permission an action requires, before it runs the
/// action (§5.1).
public enum PermissionGate {
    public enum Step: Sendable, Equatable {
        /// The permission is there. Go on.
        case proceed
        /// Close the launcher, because the prompt is a system window, request the permission
        /// and go on if it was granted.
        case request
        /// Push the permission screen in place of running the action.
        case explain
    }

    public static func step(for permission: Permission, state: PermissionState) -> Step {
        if state == .granted { return .proceed }

        switch permission {
        case .accessibility:
            // Its prompt only points at System Settings and returns at once, so the screen
            // that explains what to do there is the better place to start from.
            return .explain
        case .automation:
            // macOS asks once. After a refusal only System Settings can change the answer.
            if state == .denied { return .explain }
            // `.unknown` is a target that is not running, System Events for one. Requesting
            // launches it, and then the system either asks or already has an answer.
            return .request
        }
    }
}

/// How the result of `AEDeterminePermissionToAutomateTarget` reads as a `PermissionState`.
/// The values are copied from MacErrors.h and AppleEvents.h, because Core does not import the
/// frameworks that declare them.
public enum AutomationPermission {
    public static let noError: Int32 = 0  // noErr
    public static let targetNotRunning: Int32 = -600  // procNotFound
    public static let notPermitted: Int32 = -1743  // errAEEventNotPermitted
    public static let wouldRequireConsent: Int32 = -1744  // errAEEventWouldRequireUserConsent

    public static func state(forStatus status: Int32) -> PermissionState {
        switch status {
        case noError: return .granted
        case notPermitted: return .denied
        case wouldRequireConsent: return .notDetermined
        default: return .unknown
        }
    }
}
