import Foundation

/// Opens the URL a quicklink leads to. The app target implements it with `NSWorkspace`.
@MainActor public protocol QuicklinkOpening: AnyObject, Sendable {
    /// - Parameter bundleID: The app to open the URL with. nil opens it with the default app
    ///   for its scheme.
    func open(_ url: URL, withAppBundleID bundleID: String?) async throws
}

public enum QuicklinkError: Error, Equatable, LocalizedError {
    /// The template with its argument filled in is not a URL that can be opened.
    case invalidURL(quicklinkName: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let quicklinkName):
            return String(
                localized: "“\(quicklinkName)” does not lead to a valid URL.", bundle: .module,
                comment:
                    "Shown when a quicklink's URL template cannot be opened. The placeholder is the quicklink's name."
            )
        }
    }
}

/// Fills a quicklink's URL template in (docs/DESIGN.md §4.2.9).
public enum QuicklinkTemplate {
    /// Where the argument goes in a template.
    public static let placeholder = "{query}"

    /// What an argument may contain unescaped: what a URL's query allows, without the
    /// characters that would end the argument's value or begin something else there.
    private static let allowedInArgument: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return allowed
    }()

    public static func takesArgument(_ template: String) -> Bool {
        template.contains(placeholder)
    }

    /// The template with every placeholder replaced by the percent-encoded argument.
    public static func expand(_ template: String, argument: String) -> String {
        // A string made of Swift characters always encodes; the fallback is never used.
        let encoded =
            argument.addingPercentEncoding(withAllowedCharacters: allowedInArgument) ?? argument
        return template.replacingOccurrences(of: placeholder, with: encoded)
    }

    /// The URL the quicklink opens for `argument`.
    public static func url(for quicklink: Quicklink, argument: String) throws -> URL {
        let text = expand(quicklink.template, argument: argument)
        // Strict on purpose. The lenient parser would escape "not a url" into a relative URL,
        // which nothing can open, and the user would see the system's error for that and not
        // the name of the quicklink that is wrong.
        guard let url = URL(string: text, encodingInvalidCharacters: false), url.scheme != nil
        else {
            throw QuicklinkError.invalidURL(quicklinkName: quicklink.name)
        }
        return url
    }
}
