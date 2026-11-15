import OpenRayCore
import SwiftUI

/// Quicklinks (docs/DESIGN.md §4.2.9): the source that puts them into search, and the screen
/// that asks for a quicklink's argument. They are created and edited in Settings › Commands.
final class QuicklinksFeature: Feature {
    let id = QuicklinkSource.feature

    /// Kept for `makeScreen`, which looks the quicklink of a request up in it.
    private var source: QuicklinkSource?

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let source = QuicklinkSource(commands: env.commands, opener: env.workspace)
        self.source = source
        return [source]
    }

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard request.screen == QuicklinkSource.argumentScreen else { return nil }
        // The request names the quicklink by its UUID. One that was deleted while the launcher
        // was open is no longer there.
        guard let argument = request.argument, let id = UUID(uuidString: argument),
            let quicklink = source?.quicklink(withID: id)
        else { return nil }

        let model = QuicklinkArgumentModel(
            quicklink: quicklink, opener: env.workspace, context: context)
        return .custom(
            title: quicklink.name, searchBar: model.searchBarMode,
            view: QuicklinkArgumentView(model: model))
    }
}

/// Shows which quicklink the text in the search field is for, and the URL it will open.
private struct QuicklinkArgumentView: View {
    let model: QuicklinkArgumentModel

    var body: some View {
        VStack(spacing: 12) {
            IconView(icon: QuicklinkSource.icon(of: model.quicklink))
                .scaleEffect(2)
                .frame(width: 56, height: 56)
            Text(model.quicklink.name)
                .font(.system(size: 17, weight: .semibold))
            if let preview = model.preview {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            } else {
                Text("This quicklink's link is not a valid URL. Edit it in Settings › Commands.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
