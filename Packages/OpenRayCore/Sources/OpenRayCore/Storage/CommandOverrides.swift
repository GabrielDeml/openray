import Foundation

/// What the user has changed about one item (docs/DESIGN.md §4.3.2, `item_override`).
public struct ItemOverride: Sendable, Hashable {
    /// Not shown in root search. The item still works where it is named: in the fallback list
    /// and on screens.
    public var hidden: Bool
    /// Not available anywhere.
    public var disabled: Bool

    public init(hidden: Bool = false, disabled: Bool = false) {
        self.hidden = hidden
        self.disabled = disabled
    }

    /// Whether this says anything at all. An override that does not is not stored.
    var isDefault: Bool { !hidden && !disabled }
}

/// Everything `CommandStore` holds, read in one go: the aliases, the overrides, the quicklinks
/// and the order of the fallback list.
public struct CommandOverrides: Sendable, Equatable {
    /// The item each alias stands for. The keys are folded as `SearchQuery.normalized` is.
    public var aliases: [String: ItemID]
    /// Only the items the user has hidden or disabled.
    public var overrides: [ItemID: ItemOverride]
    /// Oldest first.
    public var quicklinks: [Quicklink]
    /// The items of the fallback section, in the user's order.
    public var fallbackOrder: [ItemID]

    public init(
        aliases: [String: ItemID] = [:], overrides: [ItemID: ItemOverride] = [:],
        quicklinks: [Quicklink] = [], fallbackOrder: [ItemID] = []
    ) {
        self.aliases = aliases
        self.overrides = overrides
        self.quicklinks = quicklinks
        self.fallbackOrder = fallbackOrder
    }

    /// The aliases of one item, in alphabetical order.
    public func aliases(of id: ItemID) -> [String] {
        var itemAliases: [String] = []
        for (alias, aliasedID) in aliases where aliasedID == id {
            itemAliases.append(alias)
        }
        return itemAliases.sorted()
    }

    /// Whether the item is shown in root search: neither hidden nor disabled.
    public func isSearchable(_ id: ItemID) -> Bool {
        guard let override = overrides[id] else { return true }
        return !override.hidden && !override.disabled
    }

    public func isDisabled(_ id: ItemID) -> Bool {
        overrides[id]?.disabled ?? false
    }
}
