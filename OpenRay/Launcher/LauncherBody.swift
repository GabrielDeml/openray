import OpenRayCore
import SwiftUI

/// Everything in the launcher below the search bar.
struct LauncherBody: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ResultsListView(model: model)
            Divider()
            LauncherFooter(primaryActionTitle: model.selectedItem?.actions.first?.title)
        }
    }
}

/// Names the app and what Return does to the selected row.
private struct LauncherFooter: View {
    let primaryActionTitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(AppInfo.name)
                .foregroundStyle(.secondary)
            Spacer()
            if let primaryActionTitle {
                Text(primaryActionTitle)
                KeyCap(symbol: "↩")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

private struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 22, minHeight: 20)
            .background(
                Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
