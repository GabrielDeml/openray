import OpenRayCore
import SwiftUI

/// One result. It holds only the values it draws, so SwiftUI can skip rows that did not change
/// when the selection moves or new results arrive.
struct ResultRow: View, Equatable {
    private let title: String
    private let subtitle: String?
    private let icon: IconSource
    private let kindLabel: String
    private let accessories: [String]
    private let highlights: [Range<Int>]
    private let isSelected: Bool

    init(_ row: ScoredItem, isSelected: Bool) {
        title = row.item.title
        subtitle = row.item.subtitle
        icon = row.item.icon
        kindLabel = row.item.kindLabel
        accessories = row.item.accessories
        highlights = row.highlights
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: icon)
            Text(highlightedTitle)
                .font(.system(size: 14))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ForEach(accessories, id: \.self) { accessory in
                Text(accessory)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2), in: Capsule())
            }
            Text(kindLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            Color.gray.opacity(isSelected ? 0.22 : 0),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The title with the matched characters emphasised.
    private var highlightedTitle: AttributedString {
        var text = AttributedString(title)
        let characters = text.characters
        for range in highlights {
            let range = range.clamped(to: 0..<characters.count)
            let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let end = characters.index(start, offsetBy: range.count)
            text[start..<end].font = .system(size: 14, weight: .bold)
        }
        return text
    }

    // Written by hand so that it can be `nonisolated`. A synthesized `==` would be isolated to
    // the main actor like the rest of the app target, and SwiftUI does not promise to compare
    // rows there.
    // Every stored property has to be compared here: the list wraps rows in `.equatable()`, so
    // a row is not redrawn when all that changed is a property missing from this list.
    nonisolated static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.icon == rhs.icon
            && lhs.kindLabel == rhs.kindLabel && lhs.accessories == rhs.accessories
            && lhs.highlights == rhs.highlights && lhs.isSelected == rhs.isSelected
    }
}
