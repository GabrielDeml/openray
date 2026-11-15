import SwiftUI

/// The settings window's content: a sidebar of panes and the selected pane.
struct SettingsView: View {
    let panes: [SettingsPane]
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            List(panes, selection: $navigation.selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.systemImage)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                if let pane = selectedPane {
                    pane.makeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// A sidebar selection can be cleared; the window then keeps showing its first pane.
    private var selectedPane: SettingsPane? {
        panes.first { $0.id == navigation.selection } ?? panes.first
    }
}
