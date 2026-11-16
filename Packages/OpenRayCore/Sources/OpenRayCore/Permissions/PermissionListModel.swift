import Observation

/// The list of permissions in Settings › General: every permission a command needs, with its
/// state and the commands it is for, and Accessibility for pasting (docs/DESIGN.md §5.1).
@MainActor @Observable public final class PermissionListModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public var permission: Permission
        /// The commands that need the permission.
        public var commandTitles: [String]
        public var state: PermissionState

        public var id: Permission { permission }

        /// How many commands `summary` names before it counts the rest.
        private static let namedInSummary = 3

        /// What the permission is for, in a line that stays short however many commands
        /// need it: Accessibility has every window command.
        public var summary: String {
            if commandTitles.count <= Self.namedInSummary {
                return commandTitles.formatted(.list(type: .and))
            }
            var parts = Array(commandTitles.prefix(Self.namedInSummary))
            let remaining = commandTitles.count - parts.count
            parts.append(
                String(
                    localized: "\(remaining) more", bundle: .module,
                    comment:
                        "The end of a list of commands that need a permission, after the first few were named: “Left Half, Right Half, Top Half, and 16 more”."
                ))
            return parts.formatted(.list(type: .and))
        }

        /// What the row's button does: nothing to do, ask macOS, or go to System Settings.
        public var step: PermissionGate.Step {
            PermissionGate.step(for: permission, state: state)
        }
    }

    /// How often, and for how long, a permission is read again after its button has sent the
    /// user to System Settings. Half a second feels immediate to someone watching the row, and
    /// two minutes is longer than finding and turning the switch takes.
    public static let followInterval: Duration = .milliseconds(500)
    public static let followTime: Duration = .seconds(120)

    public private(set) var rows: [Row] = []

    @ObservationIgnored private let checker: any PermissionChecking
    @ObservationIgnored private let currentItems: @MainActor () -> [SearchItem]
    @ObservationIgnored private let followInterval: Duration
    @ObservationIgnored private let followTime: Duration
    /// The permissions that are read again and again, because the user was sent to System
    /// Settings for them, each with the task that does it.
    @ObservationIgnored private var following: [Permission: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - currentItems: Everything the launcher's sources have yielded
    ///     (`CommandRegistry.items`). The permissions are read off their actions.
    ///   - followInterval: Tests pass shorter times for these two.
    public init(
        checker: any PermissionChecking, currentItems: @escaping @MainActor () -> [SearchItem],
        followInterval: Duration = PermissionListModel.followInterval,
        followTime: Duration = PermissionListModel.followTime
    ) {
        self.checker = checker
        self.currentItems = currentItems
        self.followInterval = followInterval
        self.followTime = followTime
    }

    deinit {
        for task in following.values {
            task.cancel()
        }
    }

    /// Reads the permissions the commands need and the state of each. The pane calls this when
    /// it appears and when OpenRay becomes the active app, because the user changes
    /// permissions in System Settings.
    public func refresh() async {
        let uses = usesToList()

        // The list first, every row with the state it had, and then the states one at a time
        // as they are read. Reading them all and assigning the rows at the end would put a
        // state from the start of a slow refresh over one the row was given since, which is
        // what following a permission does.
        var listedRows: [Row] = []
        for use in uses {
            let stateSoFar = rows.first { $0.permission == use.permission }?.state ?? .unknown
            listedRows.append(
                Row(
                    permission: use.permission, commandTitles: use.commandTitles,
                    state: stateSoFar))
        }
        rows = listedRows

        for use in uses {
            let state = await checker.state(use.permission)
            setState(state, of: use.permission)
        }
    }

    /// What the commands require, and Accessibility in any case. Pasting uses Accessibility
    /// without an action requiring it: a paste that lacks it copies instead (§4.1.7). So no
    /// command would bring it into this list, and this list is where it is granted.
    private func usesToList() -> [PermissionUse] {
        let pasting = String(
            localized: "Pasting into the app you came from", bundle: .module,
            comment:
                "What the Accessibility permission is for, in the list of permissions in Settings.")
        var uses = PermissionUse.uses(in: currentItems())

        if let index = uses.firstIndex(where: { $0.permission == .accessibility }) {
            uses[index].commandTitles.insert(pasting, at: 0)
        } else {
            // In front, where `PermissionUse.uses` puts Accessibility too.
            let accessibility = PermissionUse(permission: .accessibility, commandTitles: [pasting])
            uses.insert(accessibility, at: 0)
        }
        return uses
    }

    /// The button of a row: asks macOS for the permission, or leads to System Settings when
    /// macOS will not ask.
    public func grant(_ permission: Permission) async {
        guard let row = rows.first(where: { $0.permission == permission }) else { return }
        switch row.step {
        case .proceed:
            return
        case .explain:
            checker.openSystemSettings(for: permission)
            followState(of: permission)
        case .request:
            let answer = await checker.request(permission)
            setState(answer, of: permission)
        }
    }

    /// Keeps reading the permission until it is granted or `followTime` has passed. Nothing
    /// tells an app that a permission was granted in System Settings, and the user who has
    /// just switched it on there looks at this row to see whether it worked.
    private func followState(of permission: Permission) {
        // Pressing the button again starts the time over.
        following[permission]?.cancel()
        let deadline = ContinuousClock.now + followTime
        let interval = followInterval

        following[permission] = Task { [weak self] in
            while ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    // Cancelled: the button was pressed again, or the model is gone.
                    return
                }
                // Held for this one read only, so a model that is gone is released and its
                // `deinit` ends the task.
                guard let self else { return }
                let state = await checker.state(permission)
                if Task.isCancelled { return }
                setState(state, of: permission)
                if state == .granted { return }
            }
        }
    }

    private func setState(_ state: PermissionState, of permission: Permission) {
        // The rows may have been read anew while the answer was on its way.
        guard let index = rows.firstIndex(where: { $0.permission == permission }) else { return }
        rows[index].state = state
    }
}
