import AppKit
import OpenRayCore
import SwiftUI
import UniformTypeIdentifiers

/// The selected file beside the list of "Search Files" (docs/DESIGN.md §4.8): what Spotlight
/// says about it, or its Quick Look preview once ⌘Y has asked for that.
struct FileDetailView: View {
    let model: FileSearchModel
    let selection: ItemID

    var body: some View {
        // nil for a moment after the selected file was moved to the Trash.
        if let hit = model.hit(for: selection) {
            if model.showsPreview {
                QuickLookPreview(url: hit.url)
            } else {
                FileFactsView(hit: hit, folder: model.folder(of: hit))
            }
        }
    }
}

/// The icon, the name, and the few things Spotlight returned with the file. Nothing here
/// can be selected; the keyboard stays with the search field.
private struct FileFactsView: View {
    let hit: FileHit
    /// Where the file lies, with the home folder written as "~".
    let folder: String

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(hit.name)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                fact("Where", folder)
                if let kind {
                    fact("Kind", kind)
                }
                if let lastUsed = hit.lastUsed {
                    fact("Last opened", lastUsed.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.system(size: 12))
            .padding(.top, 6)

            Spacer(minLength: 0)
            Text("Press ⌘Y for a preview")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    /// The type as Finder names it: "PDF document" for `com.adobe.pdf`.
    private var kind: String? {
        guard let identifier = hit.contentType else { return nil }
        return UTType(identifier)?.localizedDescription
    }
}
