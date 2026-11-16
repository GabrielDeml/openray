import OpenRayCore
import SwiftUI

/// The ⌘K panel: the actions of the selected item, or of the screen, with their shortcuts.
///
/// It is drawn inside the launcher and is not a menu: a menu is a window of its own, and other
/// windows can come up below a panel at the launcher's level (docs/DESIGN.md §4.1.6). The search
/// field holds the panel's filter while it is open, and the reducer owns the selection.
struct ActionPanelView: View {
    let rows: [LauncherModel.ActionPanelRow]
    let selection: ActionID?
    let onPick: (ActionID) -> Void

    private static let width: CGFloat = 320
    fileprivate static let rowHeight: CGFloat = 34
    /// The space around the rows, inside the panel's edge.
    private static let listPadding: CGFloat = 6
    /// How many rows fit before the panel scrolls.
    private static let visibleRowLimit = 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        ActionPanelRowView(row: row, isSelected: row.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(row.id) }
                    }
                }
                .padding(Self.listPadding)
            }
            .onChange(of: selection) { _, selected in
                if let selected {
                    proxy.scrollTo(selected)
                }
            }
        }
        .frame(width: Self.width, height: height)
        .overlay {
            if rows.isEmpty {
                Text("No Matching Actions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.gray.opacity(0.3))
        }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    /// As tall as its rows, up to the limit. An empty panel keeps the height of one row for
    /// its message.
    private var height: CGFloat {
        let rowCount = min(max(rows.count, 1), Self.visibleRowLimit)
        return CGFloat(rowCount) * Self.rowHeight + 2 * Self.listPadding
    }
}

private struct ActionPanelRowView: View {
    let row: LauncherModel.ActionPanelRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon = row.icon {
                IconView(icon: icon)
            }
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(row.isDestructive ? Color.red : Color.primary)
            Spacer(minLength: 8)
            if row.isPrimary {
                KeyCap(symbol: "↩")
            } else if let shortcut = row.shortcut {
                KeyCap(symbol: HotKeyFormatter.string(for: shortcut))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: ActionPanelView.rowHeight)
        .background(
            Color.gray.opacity(isSelected ? 0.22 : 0),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
