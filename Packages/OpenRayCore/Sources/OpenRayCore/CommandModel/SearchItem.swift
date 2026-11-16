/// Where an icon comes from. The app target turns it into an image; Core never loads one.
public enum IconSource: Sendable, Hashable {
    /// The icon of the file at `path`, such as an app bundle.
    case file(path: String)
    /// An SF Symbol name.
    case symbol(String)
    case emoji(String)
    /// An image in the app's asset catalog.
    case bundled(String)
    /// The image file at `path` itself, such as the picture a script names as its icon.
    case image(path: String)
}

/// Another name an item can be found by.
public struct NameVariant: Sendable, Hashable {
    public var text: String
    /// Multiplies the match quality: 0.95 for an alias or keyword, 0.9 for a transliteration.
    public var weight: Double

    public init(text: String, weight: Double) {
        self.text = text
        self.weight = weight
    }

    /// The weight of a keyword: a word an item is also found by without being called that,
    /// such as "Reboot" for Restart. Just under 1, so that an item whose own name matches the
    /// query stays ahead of one that only has it as a keyword.
    public static let keywordWeight = 0.95

    public static func keyword(_ text: String) -> NameVariant {
        NameVariant(text: text, weight: keywordWeight)
    }
}

/// One thing the launcher can list and act on.
public struct SearchItem: Sendable, Identifiable {
    public let id: ItemID
    public var title: String
    public var subtitle: String?
    /// Localised names, transliterations and keywords.
    public var alternateNames: [NameVariant]
    public var icon: IconSource
    /// What kind of thing this is, shown at the trailing edge: "Application", "Command".
    public var kindLabel: String
    /// Short trailing labels.
    public var accessories: [String]
    /// The screen Tab opens for this item.
    public var tabTarget: ScreenRequest?
    /// `actions[0]` is the primary action (Return). `actions[1]` gets ⌘Return unless it has its
    /// own shortcut.
    public var actions: [ActionDescriptor]

    public init(
        id: ItemID,
        title: String,
        subtitle: String? = nil,
        alternateNames: [NameVariant] = [],
        icon: IconSource,
        kindLabel: String,
        accessories: [String] = [],
        tabTarget: ScreenRequest? = nil,
        actions: [ActionDescriptor] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.alternateNames = alternateNames
        self.icon = icon
        self.kindLabel = kindLabel
        self.accessories = accessories
        self.tabTarget = tabTarget
        self.actions = actions
    }
}
