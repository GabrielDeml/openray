/// Something the user can do with an item or on a screen.
public struct ActionDescriptor: Sendable, Identifiable {
    public let id: ActionID
    public var title: String
    public var icon: IconSource?
    public var shortcut: KeyChord?
    public var isDestructive: Bool
    /// Shown in the panel before the action runs; the action is skipped if the user declines.
    public var confirmation: Confirmation?
    /// Checked before the action runs. An action stays listed while one is missing.
    public var requiredPermissions: Set<Permission>
    public var perform: @MainActor @Sendable (any ActionContext) async throws -> ActionOutcome

    public init(
        id: ActionID,
        title: String,
        icon: IconSource? = nil,
        shortcut: KeyChord? = nil,
        isDestructive: Bool = false,
        confirmation: Confirmation? = nil,
        requiredPermissions: Set<Permission> = [],
        perform: @escaping @MainActor @Sendable (any ActionContext) async throws -> ActionOutcome
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.confirmation = confirmation
        self.requiredPermissions = requiredPermissions
        self.perform = perform
    }
}

public struct Confirmation: Sendable, Hashable {
    public var title: String
    public var message: String?
    /// The label of the button that goes ahead.
    public var confirmTitle: String

    public init(title: String, message: String? = nil, confirmTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
    }
}

/// A privacy permission an action can require.
public enum Permission: Sendable, Hashable {
    case accessibility
    case automation(bundleID: String)
}

/// What the launcher does once an action has run.
public enum ActionOutcome: Sendable, Equatable {
    case closeLauncher
    case keepOpen
    case popToRoot
    case push(ScreenRequest)
    case replaceQuery(String)
    /// Closes the launcher, then shows the text in the HUD.
    case showHUD(String)
}
