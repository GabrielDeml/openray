import OpenRayCore

/// Milestone 1 only: static items matched by substring, so the launcher shell has something to
/// list. Delete this file when the app index and the matcher arrive.
nonisolated struct FakeSearchSource: SearchSource {
    let id = SourceID(rawValue: "fake")
    let latency = SourceLatency.inline

    func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        guard !query.normalized.isEmpty else {
            return Self.items.map { ScoredItem(item: $0, quality: 1) }
        }

        var matches: [ScoredItem] = []
        for item in Self.items {
            let title = item.title
            guard
                let match = title.range(
                    of: query.normalized, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            // Highlights are character offsets into the title.
            let start = title.distance(from: title.startIndex, to: match.lowerBound)
            let length = title.distance(from: match.lowerBound, to: match.upperBound)
            let highlight = start..<start + length
            matches.append(ScoredItem(item: item, quality: 1, highlights: [highlight]))
        }
        return matches
    }

    /// The list size the latency budget is measured at (docs/DESIGN.md §4.1.5).
    private static let benchmarkRowCount = 200

    private static let items: [SearchItem] = makeItems()

    private static func makeItems() -> [SearchItem] {
        var items: [SearchItem] = []
        for app in apps {
            let item = SearchItem(
                id: .app(bundleID: app.bundleID),
                title: app.name,
                icon: .file(path: app.path),
                kindLabel: "Application",
                actions: [action("open", title: "Open")])
            items.append(item)
        }
        for command in commands {
            let item = SearchItem(
                id: .system(command.name),
                title: command.title,
                icon: .symbol(command.symbol),
                kindLabel: "Command",
                actions: [action("run", title: "Run")])
            items.append(item)
        }
        // Sample scripts fill the list up to `benchmarkRowCount`. Typing "sample script"
        // replaces every one of these rows on each keystroke, which is the case
        // `keystrokeToResults` has to be profiled in.
        let sampleCount = benchmarkRowCount - items.count
        for number in 1...sampleCount {
            let item = SearchItem(
                id: .script(path: "/Samples/\(number).sh"),
                title: "Sample Script \(number)",
                icon: .symbol("terminal"),
                kindLabel: "Script",
                actions: [action("run", title: "Run")])
            items.append(item)
        }
        return items
    }

    private static func action(_ id: String, title: String) -> ActionDescriptor {
        ActionDescriptor(id: ActionID(rawValue: id), title: title) { _ in .closeLauncher }
    }

    private static let apps: [(name: String, bundleID: String, path: String)] = [
        (
            "Activity Monitor", "com.apple.ActivityMonitor",
            "/System/Applications/Utilities/Activity Monitor.app"
        ),
        ("App Store", "com.apple.AppStore", "/System/Applications/App Store.app"),
        ("Books", "com.apple.iBooksX", "/System/Applications/Books.app"),
        ("Calculator", "com.apple.calculator", "/System/Applications/Calculator.app"),
        ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
        ("Clock", "com.apple.clock", "/System/Applications/Clock.app"),
        ("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
        ("Dictionary", "com.apple.Dictionary", "/System/Applications/Dictionary.app"),
        ("FaceTime", "com.apple.FaceTime", "/System/Applications/FaceTime.app"),
        ("Finder", "com.apple.finder", "/System/Library/CoreServices/Finder.app"),
        ("Font Book", "com.apple.FontBook", "/System/Applications/Font Book.app"),
        ("Freeform", "com.apple.freeform", "/System/Applications/Freeform.app"),
        ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
        ("Maps", "com.apple.Maps", "/System/Applications/Maps.app"),
        ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
        ("Music", "com.apple.Music", "/System/Applications/Music.app"),
        ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
        ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
        ("Podcasts", "com.apple.podcasts", "/System/Applications/Podcasts.app"),
        ("Preview", "com.apple.Preview", "/System/Applications/Preview.app"),
        ("Reminders", "com.apple.reminders", "/System/Applications/Reminders.app"),
        ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
        ("Shortcuts", "com.apple.shortcuts", "/System/Applications/Shortcuts.app"),
        (
            "System Settings", "com.apple.systempreferences",
            "/System/Applications/System Settings.app"
        ),
        ("Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app"),
        ("TextEdit", "com.apple.TextEdit", "/System/Applications/TextEdit.app"),
        ("Weather", "com.apple.weather", "/System/Applications/Weather.app"),
    ]

    private static let commands: [(name: String, title: String, symbol: String)] = [
        ("emptyTrash", "Empty Trash", "trash"),
        ("lockScreen", "Lock Screen", "lock"),
        ("restart", "Restart", "arrow.clockwise"),
        ("sleep", "Sleep", "moon"),
        ("toggleAppearance", "Toggle System Appearance", "circle.lefthalf.filled"),
    ]
}
