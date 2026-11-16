import Observation

/// Whether OpenRay opens when the user logs in (docs/DESIGN.md §4.3.6). The state lives with
/// macOS and is never stored by OpenRay: the user can change it in System Settings.
public enum LoginItemStatus: Sendable, Equatable {
    case disabled
    case enabled
    /// Registered, but the user has to allow it in System Settings › General › Login Items.
    case requiresApproval
    /// macOS cannot find the app to register, as for a copy that runs from a disk image.
    case unavailable
}

/// Registers OpenRay as a login item. The app target implements it with `SMAppService`.
@MainActor public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ on: Bool) throws
    /// Opens System Settings at the list of login items.
    func openSystemSettings()
}

/// What the launch-at-login switch shows and does.
@MainActor @Observable public final class LoginItemModel {
    public private(set) var status: LoginItemStatus
    /// Why the last change did not work. Cleared by the next one that does.
    public private(set) var errorMessage: String?
    /// False where the switch is shown but must not work: in Debug builds, whose login item
    /// would point into the build folder.
    public let canChange: Bool

    @ObservationIgnored private let controller: any LoginItemControlling

    public init(controller: any LoginItemControlling, canChange: Bool = true) {
        self.controller = controller
        self.canChange = canChange
        status = controller.status
    }

    /// Whether the switch is on. An item that waits for approval is registered, so it is.
    public var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Reads the status again. The pane calls this when it appears and when OpenRay becomes
    /// the active app, because the user may have been to System Settings in between.
    public func refresh() {
        status = controller.status
    }

    public func setEnabled(_ on: Bool) {
        guard canChange else { return }
        do {
            try controller.setEnabled(on)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        // Whatever happened, macOS has the last word on what the status is now.
        status = controller.status
    }

    public func openSystemSettings() {
        controller.openSystemSettings()
    }
}
