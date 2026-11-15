import Observation

/// The list of permissions in Settings › General: every permission a command needs, with its
/// state and the commands it is for (docs/DESIGN.md §5.1).
@MainActor @Observable public final class PermissionListModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public var permission: Permission
        /// The commands that need the permission.
        public var commandTitles: [String]
        public var state: PermissionState

        public var id: Permission { permission }

        /// What the row's button does: nothing to do, ask macOS, or go to System Settings.
        public var step: PermissionGate.Step {
            PermissionGate.step(for: permission, state: state)
        }
    }

    public private(set) var rows: [Row] = []

    @ObservationIgnored private let checker: any PermissionChecking
    @ObservationIgnored private let currentItems: @MainActor () -> [SearchItem]

    /// - Parameter currentItems: Everything the launcher's sources have yielded
    ///   (`CommandRegistry.items`). The permissions are read off their actions.
    public init(
        checker: any PermissionChecking, currentItems: @escaping @MainActor () -> [SearchItem]
    ) {
        self.checker = checker
        self.currentItems = currentItems
    }

    /// Reads the permissions the commands need and the state of each. The pane calls this when
    /// it appears and when OpenRay becomes the active app, because the user changes
    /// permissions in System Settings.
    public func refresh() async {
        var newRows: [Row] = []
        for use in PermissionUse.uses(in: currentItems()) {
            let state = await checker.state(use.permission)
            newRows.append(
                Row(permission: use.permission, commandTitles: use.commandTitles, state: state))
        }
        rows = newRows
    }

    /// The button of a row: asks macOS for the permission, or leads to System Settings when
    /// macOS will not ask again.
    public func grant(_ permission: Permission) async {
        guard let index = rows.firstIndex(where: { $0.permission == permission }) else { return }
        switch rows[index].step {
        case .proceed:
            return
        case .explain:
            checker.openSystemSettings(for: permission)
        case .request:
            rows[index].state = await checker.request(permission)
        }
    }
}
