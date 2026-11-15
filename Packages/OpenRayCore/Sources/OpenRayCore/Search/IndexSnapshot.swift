import Foundation
import os

/// Everything root search can find, prepared for matching: each item with its names already
/// folded (docs/DESIGN.md §4.2.4). Immutable, so a search can keep reading one snapshot while the
/// next is being built.
struct IndexSnapshot: Sendable {
    /// One name an item can be found by.
    struct Name: Sendable {
        var normalized: NormalizedName
        /// Multiplies the quality of a match against this name.
        var weight: Double
        /// Whether this is the item's title. Highlights are offsets into the title, so only a
        /// match against this name can give any.
        var isTitle: Bool
    }

    struct Entry: Sendable {
        var item: SearchItem
        /// The title first, then the alternate names, each followed by its transliteration when
        /// it has one.
        var names: [Name]
    }

    let entries: [Entry]
    /// How many items were left out because an earlier item had the same ID.
    let duplicateIDCount: Int

    static let empty = IndexSnapshot(entries: [], duplicateIDCount: 0)

    /// What a transliterated name's weight is multiplied by.
    static let transliterationWeight = 0.9

    /// Folds every name of every item. Of items that share an ID only the first is kept: the
    /// results list tells its rows apart by ID.
    @concurrent
    static func build(from items: [SearchItem]) async -> IndexSnapshot {
        // A build that was overtaken still runs to its end, so two can overlap. An ID of its
        // own keeps the two ends of each interval together.
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(
            Signposts.indexBuild, id: signposter.makeSignpostID(), "\(items.count) items")
        defer { signposter.endInterval(Signposts.indexBuild, interval) }

        var entries: [Entry] = []
        var seenIDs: Set<ItemID> = []
        var duplicateIDCount = 0

        for item in items {
            let isNewID = seenIDs.insert(item.id).inserted
            if !isNewID {
                duplicateIDCount += 1
                continue
            }
            entries.append(Entry(item: item, names: names(of: item)))
        }
        return IndexSnapshot(entries: entries, duplicateIDCount: duplicateIDCount)
    }

    private static func names(of item: SearchItem) -> [Name] {
        var names: [Name] = []
        add(item.title, weight: 1, isTitle: true, to: &names)
        for alternate in item.alternateNames {
            add(alternate.text, weight: alternate.weight, isTitle: false, to: &names)
        }
        return names
    }

    /// Adds the name and, for a name in another script, its transliteration.
    private static func add(_ text: String, weight: Double, isTitle: Bool, to names: inout [Name]) {
        let name = Name(normalized: NormalizedName(text), weight: weight, isTitle: isTitle)
        addUnlessDuplicate(name, to: &names)

        guard let latin = transliteration(of: text) else { return }
        let transliterated = Name(
            normalized: NormalizedName(latin),
            weight: weight * transliterationWeight,
            isTitle: false)
        addUnlessDuplicate(transliterated, to: &names)
    }

    /// Two names that fold to the same text match the same queries, so only one is kept, with
    /// the higher weight of the two. This is also what drops the transliteration of a name that
    /// was in Latin letters all along: "Größe" comes back as "Große", which folds like the
    /// original.
    private static func addUnlessDuplicate(_ name: Name, to names: inout [Name]) {
        for index in names.indices {
            guard names[index].normalized.scalars == name.normalized.scalars else { continue }
            names[index].weight = max(names[index].weight, name.weight)
            return
        }
        names.append(name)
    }

    /// The name in Latin letters without diacritics ("微信" becomes "wei xin"), or nil for a name
    /// that is plain ASCII already, which saves most names the trip through ICU.
    private static func transliteration(of text: String) -> String? {
        let isASCII = text.utf8.allSatisfy { byte in byte < 0x80 }
        if isASCII { return nil }

        let latin = text.applyingTransform(.toLatin, reverse: false)
        return latin?.applyingTransform(.stripDiacritics, reverse: false)
    }
}
