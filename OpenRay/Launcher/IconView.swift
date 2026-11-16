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
                symbol(named: name)
            case .emoji(let emoji):
                Text(emoji).font(.system(size: 19))
            case .image(let path):
                if let image = imageFile(atPath: path) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    // The only images are the icons scripts name, and a script whose picture
                    // cannot be read looks like one that names none.
                    symbol(named: "terminal")
                }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }

    private func symbol(named name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size - 2, height: Self.size - 2)
            .background(.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    let key = cacheKey(forFileAt: path)
    if let cached = fileIcons.object(forKey: key) { return cached }
    let icon = NSWorkspace.shared.icon(forFile: path)
    fileIcons.setObject(icon, forKey: key)
    return icon
}

/// The path and the modification date of a file, as the key of what was made from it.
private func cacheKey(forFileAt path: String) -> NSString {
    // The date is part of the key so that an app that was updated shows its new icon: an update
    // replaces the bundle, which changes the date. Reading it is one attribute lookup.
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let modified = attributes?[.modificationDate] as? Date
    let modifiedSeconds = modified?.timeIntervalSinceReferenceDate ?? 0
    return "\(path)\n\(modifiedSeconds)" as NSString
}

/// The pictures that scripts name as their icons, by path and modification date like the file
/// icons, so that a picture is read from the disk once and again only after it was changed.
private let imageFiles: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 200
    return cache
}()

/// nil for a file that is missing or is no picture. That is not remembered, so such a file is
/// looked for again each time its row is drawn.
private func imageFile(atPath path: String) -> NSImage? {
    let key = cacheKey(forFileAt: path)
    if let cached = imageFiles.object(forKey: key) { return cached }
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    imageFiles.setObject(image, forKey: key)
    return image
}
