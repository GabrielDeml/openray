import OpenRayCore
import SwiftUI

/// Everything in the launcher below the search bar: the results or the screen on top, the
/// footer, and over them the action panel and a confirmation while one is up.
struct LauncherBody: View {
    let model: LauncherModel

    /// How much of the panel's width the detail view of a list screen gets.
    private static let detailWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
            Divider()
            LauncherFooter(
                title: model.topScreen?.spec.title ?? AppInfo.name,
                isBusy: model.state.top.actionInFlight,
                primaryActionTitle: model.currentActions.first?.title,
                hasActions: !model.currentActions.isEmpty)
        }
        .overlay(alignment: .bottomTrailing) {
            if let panel = model.state.actionPanel {
                ActionPanelView(rows: model.actionPanelRows, selection: panel.selection) { action in
                    model.apply(.performAction(action))
                }
                .padding(.trailing, 10)
                // Above the footer, which stays readable under the panel.
                .padding(.bottom, LauncherFooter.height + 8)
            }
        }
        .overlay {
            if let confirmation = model.state.confirmation {
                // Return and Esc reach the reducer through the key monitor; the buttons send
                // the same two intents.
                ConfirmationView(
                    confirmation: confirmation,
                    onConfirm: { model.apply(.performPrimary) },
                    onCancel: { model.apply(.escape) })
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let screen = model.topScreen {
            switch screen.spec.body {
            case .custom(let view, _):
                view.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .list(let detail):
                HStack(spacing: 0) {
                    ResultsListView(model: model)
                    if let detail, let selection = model.state.top.selection {
                        Divider()
                        detail(selection).frame(width: Self.detailWidth)
                    }
                }
                // A list of its own for each screen, so that one screen's scroll position is
                // not the next one's.
                .id(model.state.depth)
            }
        } else {
            ResultsListView(model: model)
        }
    }
}

/// Names where the user is, shows that an action is running, and says what Return and ⌘K do.
private struct LauncherFooter: View {
    static let height: CGFloat = 38

    let title: String
    let isBusy: Bool
    let primaryActionTitle: String?
    let hasActions: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Spacer()
            if let primaryActionTitle {
                Text(primaryActionTitle)
                KeyCap(symbol: "↩")
            }
            if hasActions {
                Text("Actions")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                KeyCap(symbol: "⌘K")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: Self.height)
    }
}

/// A key or chord drawn as a key.
struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(
                Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
