import Foundation

/// One permission together with the commands that need it. Settings lists these, and the
/// permission screen says with them what a permission is for.
public struct PermissionUse: Sendable, Equatable, Identifiable {
    public var permission: Permission
    /// The titles of the items with an action that requires the permission, each once, in the
    /// order the items came in.
    public var commandTitles: [String]

    public var id: Permission { permission }

    public init(permission: Permission, commandTitles: [String]) {
        self.permission = permission
        self.commandTitles = commandTitles
    }

    /// Every permission that an action of `items` requires. Nothing is listed by hand: a
    /// command that declares a permission shows up here without any other code knowing it.
    public static func uses(in items: [SearchItem]) -> [PermissionUse] {
        var titlesByPermission: [Permission: [String]] = [:]
        for item in items {
            var permissionsOfItem: Set<Permission> = []
            for action in item.actions {
                permissionsOfItem.formUnion(action.requiredPermissions)
            }
            for permission in permissionsOfItem {
                titlesByPermission[permission, default: []].append(item.title)
            }
        }

        var uses: [PermissionUse] = []
        for (permission, titles) in titlesByPermission {
            uses.append(PermissionUse(permission: permission, commandTitles: titles))
        }
        // A dictionary has no order of its own.
        uses.sort { first, second in first.permission.sortKey < second.permission.sortKey }
        return uses
    }
}

extension Permission {
    /// Orders permissions the same way on every run: Accessibility first, then the Automation
    /// targets by bundle identifier.
    var sortKey: String {
        switch self {
        case .accessibility: return "0"
        case .automation(let bundleID): return "1" + bundleID
        }
    }

    /// The permissions in the order they are checked and listed in.
    public static func sorted(_ permissions: Set<Permission>) -> [Permission] {
        permissions.sorted { first, second in first.sortKey < second.sortKey }
    }
}
