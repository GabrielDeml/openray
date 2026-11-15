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

/// File icons by path and modification date. Looking one up costs a round trip to the icon
/// service, and a row's body runs every time it scrolls into view.
private let fileIcons: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    // Several times the apps of a well-filled Mac, so the limit only matters once file search
    // puts arbitrary files in the list.
    cache.countLimit = 1_000
    return cache
}()

private func fileIcon(forPath path: String) -> NSImage {
    // The date is part of the key so that an app that was updated shows its new icon: an update
    // replaces the bundle, which changes the date. Reading it is one attribute lookup.
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let modified = attributes?[.modificationDate] as? Date
    let modifiedSeconds = modified?.timeIntervalSinceReferenceDate ?? 0
    let key = "\(path)\n\(modifiedSeconds)" as NSString

    if let cached = fileIcons.object(forKey: key) { return cached }
    let icon = NSWorkspace.shared.icon(forFile: path)
    fileIcons.setObject(icon, forKey: key)
    return icon
}
