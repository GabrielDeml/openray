import Foundation

/// One file or folder that a search found, with what Spotlight says about it.
public struct FileHit: Sendable, Hashable {
    /// The content type of a folder that is not a package.
    static let folderType = "public.folder"

    /// The absolute path. It is what Spotlight returns, and what the row's `ItemID`, Copy
    /// Path and the log use.
    public var path: String
    /// When the file was last opened (`kMDItemLastUsedDate`). nil for a file that never was,
    /// and for everything the walk without Spotlight finds.
    public var lastUsed: Date?
    /// The uniform type identifier, such as `public.folder` or `com.adobe.pdf`.
    public var contentType: String?

    public init(path: String, lastUsed: Date? = nil, contentType: String? = nil) {
        self.path = path
        self.lastUsed = lastUsed
        self.contentType = contentType
    }

    public var url: URL {
        URL(filePath: path)
    }

    /// The file's name with its extension, as the last part of the path has it.
    public var name: String {
        url.lastPathComponent
    }

    public var itemID: ItemID {
        .file(path: path)
    }

    public var isFolder: Bool {
        contentType == Self.folderType
    }
}
