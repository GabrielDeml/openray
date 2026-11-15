import Foundation
import Observation

/// Names the shared permission screen, which the launcher pushes in place of an action whose
/// permission is missing (docs/DESIGN.md §5.1).
public enum PermissionScreen {
    public static let feature = FeatureID(rawValue: "permissions")
    public static let name = "permission"

    public static func request(for permission: Permission) -> ScreenRequest {
        ScreenRequest(feature: feature, screen: name, argument: permission.screenArgument)
    }
}

extension Permission {
    private static let accessibilityArgument = "accessibility"
    private static let automationPrefix = "automation:"

    /// The permission as the argument of a `ScreenRequest`, which is a string.
    public var screenArgument: String {
        switch self {
        case .accessibility: return Self.accessibilityArgument
        case .automation(let bundleID): return Self.automationPrefix + bundleID
        }
    }

    public init?(screenArgument: String) {
        if screenArgument == Self.accessibilityArgument {
            self = .accessibility
            return
        }
        guard screenArgument.hasPrefix(Self.automationPrefix) else { return nil }
        let bundleID = String(screenArgument.dropFirst(Self.automationPrefix.count))
        if bundleID.isEmpty { return nil }
        self = .automation(bundleID: bundleID)
    }
}

/// What the permission screen shows and does: what the permission is for, its state as it is
/// now, and the one action that helps from there.
@MainActor @Observable public final class PermissionScreenModel {
    public let permission: Permission
    /// The commands that need the permission, to say what it is for.
    public let commandTitles: [String]
    public private(set) var state: PermissionState = .unknown

    @ObservationIgnored private let checker: any PermissionChecking
    @ObservationIgnored private weak var context: (any ScreenContext)?
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(
        permission: Permission, commandTitles: [String], checker: any PermissionChecking,
        context: any ScreenContext
    ) {
        self.permission = permission
        self.commandTitles = commandTitles
        self.checker = checker
        self.context = context
        context.setScreenActions([action(for: state)])
    }

    deinit {
        following?.cancel()
    }

    /// One sentence on why OpenRay wants the permission.
    public var explanation: String {
        let commands = commandTitles.formatted(.list(type: .and))
        switch permission {
        case .accessibility:
            return String(
                localized:
                    "macOS asks for the Accessibility permission before OpenRay may do this.",
                bundle: .module,
                comment: "Explains the Accessibility permission on the permission screen.")
        case .automation(let bundleID):
            let target = Permission.automationTargetName(forBundleID: bundleID)
            if commandTitles.isEmpty {
                return String(
                    localized:
                        "OpenRay sends a command to \(target) for this, and macOS asks for your permission first.",
                    bundle: .module,
                    comment: "Explains an Automation permission. The placeholder is an app's name.")
            }
            return String(
                localized:
                    "\(commands) works by sending a command to \(target), and macOS asks for your permission first.",
                bundle: .module,
                comment:
                    "Explains an Automation permission. The first placeholder is a list of command names, the second an app's name."
            )
        }
    }

    /// Reads the state again and brings the screen's action in line with it.
    public func refresh() async {
        let newState = await checker.state(permission)
        setState(newState)
    }

    /// Keeps `state` current while the screen is on screen, until it is popped. The user
    /// changes a permission in System Settings, and nothing tells an app when that has
    /// happened.
    public func followState(every interval: Duration = .seconds(1)) {
        following?.cancel()
        // The task holds the model only while it works, so a model whose screen is gone is
        // released and its `deinit` ends the task.
        following = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfOnScreen()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refreshIfOnScreen() async {
        if context?.isOnScreen == true {
            await refresh()
        }
    }

    private func setState(_ newState: PermissionState) {
        if newState == state { return }
        state = newState
        context?.setScreenActions([action(for: newState)])
    }

    /// What Return does on the screen. The gate that sent the user here decides what helps
    /// from this state, so that the screen never offers what the launcher would not do.
    private func action(for state: PermissionState) -> ActionDescriptor {
        switch PermissionGate.step(for: permission, state: state) {
        case .proceed:
            let title = String(
                localized: "Done", bundle: .module,
                comment: "Leaves the permission screen once the permission is granted.")
            return ActionDescriptor(id: ActionID(rawValue: "done"), title: title) { _ in
                .popToRoot
            }

        case .explain:
            let title = String(
                localized: "Open System Settings", bundle: .module,
                comment: "Opens the page of System Settings where a permission can be granted.")
            let permission = permission
            let checker = checker
            return ActionDescriptor(id: ActionID(rawValue: "open-system-settings"), title: title) {
                context in
                context.closeLauncher()
                checker.openSystemSettings(for: permission)
                return .closeLauncher
            }

        case .request:
            let title = String(
                localized: "Grant", bundle: .module,
                comment: "Asks macOS for a permission.")
            return ActionDescriptor(id: ActionID(rawValue: "grant"), title: title) {
                [weak self] context in
                // The prompt is a system window, and it would come up behind the panel.
                context.closeLauncher()
                await self?.request()
                return .closeLauncher
            }
        }
    }

    private func request() async {
        let newState = await checker.request(permission)
        setState(newState)
    }
}
