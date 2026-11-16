import Foundation

import OpenRayCore

// Stand-ins for Spotlight and for the workspace, shared by the tests of file search. No test
// runs a real query, and none opens, reveals or trashes a real file.

/// A Spotlight that exists only in the test. It records every query it is asked and answers
/// with the hits the test gave it for that query string.
actor FakeFileSearcher: FileSearching {
    struct Ask: Equatable {
        var queryString: String
        var scope: FileScope
        var limit: Int
    }

    private(set) var asks: [Ask] = []
    private var hitsByQueryString: [String: [FileHit]] = [:]

    /// What the query returns from now on. A query that was given no hits finds nothing.
    func setHits(_ hits: [FileHit], for queryString: String) {
        hitsByQueryString[queryString] = hits
    }

    func hits(matching queryString: String, in scope: FileScope, limit: Int) -> [FileHit] {
        asks.append(Ask(queryString: queryString, scope: scope, limit: limit))
        return hitsByQueryString[queryString] ?? []
    }
}

/// A workspace that opens, reveals and trashes nothing: it records what it was asked to do.
@MainActor final class FakeFileActionHost: FileActionHost {
    enum Call: Equatable {
        case open(URL)
        case showInFinder(URL)
        case moveToTrash(URL)
        case openWithApp(URL, appURL: URL)
    }

    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The file could not be found." }
    }

    /// What `appsAbleToOpen` answers, in this order.
    var apps: [OpenWithApp] = []
    /// Makes every call that can fail throw `Refused`.
    var refusesEverything = false
    /// What happens while the move to the Trash waits, as it does on a prompt of macOS.
    var whileMovingToTrash: (() async -> Void)?

    private(set) var calls: [Call] = []

    func open(_ url: URL) async throws {
        calls.append(.open(url))
        if refusesEverything { throw Refused() }
    }

    func showInFinder(_ url: URL) {
        calls.append(.showInFinder(url))
    }

    func moveToTrash(_ url: URL) async throws {
        calls.append(.moveToTrash(url))
        if refusesEverything { throw Refused() }
        await whileMovingToTrash?()
    }

    func appsAbleToOpen(_ url: URL) -> [OpenWithApp] {
        apps
    }

    func open(_ url: URL, withAppAt appURL: URL) async throws {
        calls.append(.openWithApp(url, appURL: appURL))
        if refusesEverything { throw Refused() }
    }
}
