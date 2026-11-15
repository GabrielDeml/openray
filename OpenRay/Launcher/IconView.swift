import AppKit
import OpenRayCore
import SwiftUI

/// Draws an `IconSource` at the size of a result row's icon.
struct IconView: View {
    let icon: IconSource

    private static let size: CGFloat = 24

    var body: some View {
        Group {
            switch icon {
            case .file(let path):
                Image(nsImage: fileIcon(forPath: path)).resizable().interpolation(.high)
            case .bundled(let name):
                Image(name).resizable().interpolation(.high)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.size - 2, height: Self.size - 2)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .emoji(let emoji):
                Text(emoji).font(.system(size: 19))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

/// File icons by path. Looking one up costs a round trip to the icon service, and a row's body
/// runs every time it scrolls into view.
private let fileIcons = NSCache<NSString, NSImage>()

private func fileIcon(forPath path: String) -> NSImage {
    if let cached = fileIcons.object(forKey: path as NSString) { return cached }
    let icon = NSWorkspace.shared.icon(forFile: path)
    fileIcons.setObject(icon, forKey: path as NSString)
    return icon
}
