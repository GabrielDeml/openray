import Foundation

/// Quick AI in root search (docs/DESIGN.md §4.6.6).
///
/// It shows up in three ways. "Ask AI" is a command that is found by its name and opens the
/// chat. When a search finds nothing, "Ask AI" leads the fallback section and asks the query
/// as it was typed. And while a thread is live, the empty search field has "Continue AI chat"
/// at its top.
public struct QuickAISource: SearchSource {
    public static let feature = FeatureID(rawValue: "ai")
    /// The chat, the feature's one screen.
    public static let chatScreen = "chat"
    /// The "Ask AI" item. `SearchSession` puts it first in the fallback section (§4.2.9).
    public static let askItemID = ItemID.command(feature, "ask")

    /// The request that opens the chat.
    ///
    /// - Parameter question: Asked as soon as the chat opens. nil only opens the chat, with
    ///   the thread as it is.
    public static func chatScreenRequest(asking question: String? = nil) -> ScreenRequest {
        ScreenRequest(feature: feature, screen: chatScreen, argument: question)
    }

    public let id = SourceID(rawValue: "ai")
    public let latency = SourceLatency.inline

    private let session: QuickAISession

    public init(session: QuickAISession) {
        self.session = session
    }

    /// The "Ask AI" command, which never changes. Being indexed is what lets the user find it
    /// by name, give it an alias or turn it off in Settings.
    public func indexedItems() -> AsyncStream<[SearchItem]> {
        let command = Self.askItem(asking: nil)
        return AsyncStream { continuation in
            continuation.yield([command])
            continuation.finish()
        }
    }

    public func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        let question = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if question.isEmpty {
            // Only the session knows whether there is a thread, and it lives on the main
            // actor. The empty field is the one search that waits for it.
            guard await session.isLive else { return nil }
            return [ScoredItem(item: Self.continueItem(), quality: 1, placement: .pinnedTop)]
        }
        // The session shows this row when the search found nothing else (§4.2.9).
        return [ScoredItem(item: Self.askItem(asking: question), quality: 0, placement: .fallback)]
    }

    // MARK: Items

    private static var kindLabel: String {
        String(
            localized: "Command", bundle: .module,
            comment: "The kind of a search result that is a command, shown at the end of its row."
        )
    }

    /// "Ask AI", as the command that opens the chat or as the fallback row that asks
    /// `question` there. Both are the same item to the usage and override tables.
    private static func askItem(asking question: String?) -> SearchItem {
        let title = String(
            localized: "Ask AI", bundle: .module,
            comment:
                "The command that opens the Quick AI chat. It is also the first row when a search finds nothing, where it asks what was typed."
        )
        let keywords = [
            String(
                localized: "Quick AI", bundle: .module,
                comment: "Another name the Ask AI command is found by."),
            String(
                localized: "Chat", bundle: .module,
                comment: "Another word the Ask AI command is found by."),
        ]
        var alternateNames: [NameVariant] = []
        for keyword in keywords {
            alternateNames.append(.keyword(keyword))
        }

        let chat = chatScreenRequest(asking: question)
        let ask = ActionDescriptor(id: ActionID(rawValue: "ask"), title: title) { _ in
            .push(chat)
        }
        return SearchItem(
            id: askItemID, title: title, alternateNames: alternateNames,
            icon: .symbol("sparkles"), kindLabel: kindLabel, tabTarget: chat, actions: [ask])
    }

    private static func continueItem() -> SearchItem {
        let title = String(
            localized: "Continue AI chat", bundle: .module,
            comment:
                "The row at the top of the empty search field while a Quick AI chat is going on. It opens the chat again."
        )
        let chat = chatScreenRequest()
        let open = ActionDescriptor(id: ActionID(rawValue: "continue"), title: title) { _ in
            .push(chat)
        }
        return SearchItem(
            id: .command(feature, "continue"), title: title,
            icon: .symbol("bubble.left.and.bubble.right"), kindLabel: kindLabel, tabTarget: chat,
            actions: [open])
    }
}
