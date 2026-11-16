import Foundation

/// Where "Search Files" looks (docs/DESIGN.md §4.8): the home folder, folders the user chose,
/// or everything Spotlight has indexed on this Mac.
public struct FileScope: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case home
        case folders
        case everywhere
    }

    public var kind: Kind
    /// The folders of `.folders`, as absolute paths. They stay here while another kind is
    /// chosen, so that the list in Settings is still there when the user comes back to it.
    public var folders: [String]

    public init(kind: Kind = .home, folders: [String] = []) {
        self.kind = kind
        self.folders = folders
    }

    /// The scope a search really uses. Chosen folders without a single folder would search
    /// nothing at all, so they mean the home folder until one is added.
    public var searched: FileScope {
        if kind == .folders && folders.isEmpty {
            return FileScope(kind: .home)
        }
        return self
    }
}

extension PreferenceKey where Value == FileScope {
    public static var fileScope: PreferenceKey {
        PreferenceKey(name: "files.scope", defaultValue: FileScope())
    }
}

extension PreferenceKey where Value == Bool {
    /// Whether "Search Files" walks the folders itself while Spotlight has no index. Off
    /// unless the user asks for it: the walk is slow, and macOS may ask about the Desktop,
    /// Documents and Downloads folders when it reaches them.
    public static var fileFallbackWalk: PreferenceKey {
        PreferenceKey(name: "files.fallbackWalk", defaultValue: false)
    }
}

extension Preferences {
    public var fileScope: FileScope {
        get { self[.fileScope] }
        set { self[.fileScope] = newValue }
    }

    public var fileFallbackWalk: Bool {
        get { self[.fileFallbackWalk] }
        set { self[.fileFallbackWalk] = newValue }
    }
}
