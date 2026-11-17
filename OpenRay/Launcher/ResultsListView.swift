import OpenRayCore
import SwiftUI

/// The results as sections of rows. The model owns the selection and asks for scrolling; the
/// rows are not focusable, so the search field keeps the keyboard.
///
/// A `ScrollView` with a `LazyVStack`, not `List`: a list's own selection and focus handling
/// would compete with the launcher's key routing.
struct ResultsListView: View {
    let model: LauncherModel

    /// The top of the content, above the first section header.
    private static let topID = "top"

    var body: some View {
        let sections = model.visibleSections
        let selection = model.state.top.selection
        // Read here and not in the rows, so that the list is drawn again when a hotkey is
        // given or taken away.
        let hotKeys = model.hotKeysOfItems
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 6).id(Self.topID)
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows, id: \.item.id) { row in
                                ResultRow(
                                    row, hotKey: Self.text(of: hotKeys[row.item.id]),
                                    isSelected: row.item.id == selection
                                )
                                .equatable()
                            }
                        } header: {
                            if let title = section.title {
                                SectionHeader(title: title)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                let firstRowID = sections.first?.rows.first?.item.id
                if request.item == firstRowID {
                    // The first row brings its section header into view with it.
                    proxy.scrollTo(Self.topID, anchor: .top)
                } else {
                    proxy.scrollTo(request.item)
                }
            }
            .onAppear {
                // The list is built anew when the screen above it is popped, and a new list
                // starts at the top. The scroll request made by the pop came before this view
                // existed.
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
        }
        .overlay {
            if let message = model.emptyListMessage {
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    /// The hotkey as its row shows it; nil for a row without one, which is most.
    private static func text(of hotKey: HotKey?) -> String? {
        guard let hotKey else { return nil }
        return HotKeyFormatter.string(for: hotKey)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
