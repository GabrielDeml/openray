import Foundation

extension AIError {
    /// What the user is told about the failure (docs/DESIGN.md §4.6.8). The chat shows it
    /// under the question, and the Quick AI pane after a key could not be verified.
    var userMessage: String {
        switch self {
        case .missingCredentials:
            return String(
                localized: "Add your Anthropic API key", bundle: .module,
                comment: "Quick AI: shown in the chat when no API key is stored.")
        case .credentialsUnreadable:
            return String(
                localized: "Couldn't read key", bundle: .module,
                comment: "Quick AI: shown when the API key could not be read from the Keychain.")
        case .invalidCredentials:
            return String(
                localized: "Key rejected", bundle: .module,
                comment: "Quick AI: shown when Anthropic did not accept the API key.")
        case .modelUnavailable:
            return String(
                localized: "Model unavailable to this key", bundle: .module,
                comment: "Quick AI: shown when the API key may not use the chosen model.")
        case .rateLimited(let retryAfter):
            guard let retryAfter else {
                return String(
                    localized: "Rate limited, try again later", bundle: .module,
                    comment: "Quick AI: shown when too many requests were sent.")
            }
            let seconds = Self.wholeSeconds(in: retryAfter).formatted()
            return String(
                localized: "Rate limited, try again in \(seconds) s", bundle: .module,
                comment:
                    "Quick AI: shown when too many requests were sent. The placeholder is a number of seconds."
            )
        case .overloaded:
            return String(
                localized: "Claude is overloaded, try again in a moment", bundle: .module,
                comment: "Quick AI: shown when Anthropic's servers are too busy to answer.")
        case .network(.notConnectedToInternet):
            return String(
                localized: "You're offline", bundle: .module,
                comment: "Quick AI: shown when the Mac has no internet connection.")
        case .network(.timedOut):
            return String(
                localized: "The request timed out", bundle: .module,
                comment: "Quick AI: shown when Anthropic's servers did not answer in time.")
        case .network:
            return String(
                localized: "Couldn't reach Anthropic", bundle: .module,
                comment: "Quick AI: shown when the connection to Anthropic's servers failed.")
        case .malformedStream:
            // What exactly was wrong with it is in the log and means nothing to the user.
            return String(
                localized: "The reply could not be read", bundle: .module,
                comment: "Quick AI: shown when the reply was not in the form the API documents.")
        case .permissionDenied(let message), .spendLimitReached(let message),
            .billing(let message), .badRequest(let message), .server(_, let message):
            // The API's own words: they name the limit or the setting that is in the way.
            return message
        }
    }

    /// The wait as whole seconds, rounded up: after "try again in 2 s" the third second is
    /// the first that is sure to be late enough.
    private static func wholeSeconds(in duration: Duration) -> Int64 {
        let components = duration.components
        return components.attoseconds > 0 ? components.seconds + 1 : components.seconds
    }
}
