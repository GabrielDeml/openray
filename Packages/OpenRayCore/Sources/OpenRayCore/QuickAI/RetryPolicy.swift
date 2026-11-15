/// Decides whether a failed request is sent again, and after how long (docs/DESIGN.md §4.6.2).
///
/// It only answers; the provider does the waiting and the sending.
public struct RetryPolicy: Sendable {
    /// The longest wait before the first retry when the server names none. It doubles with
    /// every retry.
    private static let baseDelay: Duration = .milliseconds(500)
    /// The longest wait a server may ask for. Beyond it the failure is reported at once: the
    /// user is looking at the launcher, and an error they can act on is better than a minute of
    /// nothing.
    private static let longestServerDelay: Duration = .seconds(10)

    /// How often a request is sent again before its failure is reported.
    public var maxRetries = 2

    /// A number from 0 to 1 that says how much of the longest wait is waited. Spreading the
    /// retries of many clients keeps them from arriving at a struggling server all at once.
    private let jitter: @Sendable () -> Double

    /// - Parameter jitter: Random by default. Tests pass a fixed number.
    public init(jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.jitter = jitter
    }

    /// How long to wait before sending the request again, or nil when the failure is final.
    ///
    /// - Parameters:
    ///   - retryAfter: The wait the server asked for with the failure, if it named one.
    ///   - retriesSoFar: How often the request has been sent again already.
    ///   - hasStreamedText: Whether text of the reply has reached the user. A second attempt
    ///     would write a different reply over it, so there is none.
    public func delay(
        after failure: AIError, retryAfter: Duration?, retriesSoFar: Int, hasStreamedText: Bool
    ) -> Duration? {
        if hasStreamedText || retriesSoFar >= maxRetries {
            return nil
        }
        if !isWorthRetrying(failure, retryAfter: retryAfter) {
            return nil
        }

        if let retryAfter {
            return retryAfter <= Self.longestServerDelay ? retryAfter : nil
        }

        var longestDelay = Self.baseDelay
        for _ in 0..<retriesSoFar {
            longestDelay *= 2
        }
        return longestDelay * jitter()
    }

    /// Whether the failure is of a kind that can pass by itself within seconds.
    private func isWorthRetrying(_ failure: AIError, retryAfter: Duration?) -> Bool {
        switch failure {
        case .network(let code):
            // Being offline is not among them: that does not pass until the user does
            // something about it, and they should hear of it at once.
            return code == .timedOut || code == .networkConnectionLost
                || code == .cannotConnectToHost

        case .rateLimited:
            // Only when the server says how long the limit lasts. Without that there is no
            // telling whether it is seconds or the rest of the day.
            return retryAfter != nil

        case .server(let status, _):
            return status == 500 || status == 502 || status == 503 || status == 504

        case .overloaded:
            return true

        case .missingCredentials, .credentialsUnreadable, .invalidCredentials, .permissionDenied,
            .spendLimitReached, .billing, .badRequest, .modelUnavailable, .malformedStream:
            return false
        }
    }
}
