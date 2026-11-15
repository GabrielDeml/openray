import Foundation

/// An error as the Claude API words it, in the body of a failed response and in an `error`
/// event of a stream:
/// `{"type": "error", "error": {"type": …, "message": …, "details": {…}}, "request_id": …}`.
struct ClaudeErrorBody: Decodable {
    struct Failure: Decodable {
        struct Details: Decodable {
            var errorCode: String?
        }

        var type: String
        var message: String
        var details: Details?
    }

    var error: Failure

    /// nil when the bytes are not that JSON, as with the HTML page of a proxy.
    init?(json: Data) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(ClaudeErrorBody.self, from: json) else { return nil }
        self = body
    }
}

/// Turns what can go wrong with a request to the Claude API into an `AIError`
/// (docs/DESIGN.md §4.6.2).
enum ClaudeErrors {
    /// How much of a failed response's body is read. The API's error bodies are a few hundred
    /// bytes; a proxy's error page can be any size and is not read to the end.
    static let bodySizeLimit = 64 * 1024

    /// The message of a spend limit the user set on the organisation or on a workspace begins
    /// with these words. The API reports such a limit as an ordinary invalid request, so the
    /// text is the only thing that tells it apart.
    private static let userSpendLimitPrefix = "You have reached your specified"
    /// What `error.details.error_code` says when the usage tier's monthly cap is reached. That
    /// comes as a 429 like a rate limit, but waiting a few seconds does not help.
    private static let tierSpendCapCode = "enforced_spend_limit_reached"

    /// The error for a response with a status outside 200 to 299.
    ///
    /// - Parameters:
    ///   - body: The response's body, or nil when it was not the API's JSON. The status then
    ///     decides alone and the message is a general one: what an unknown server wrote is
    ///     never shown.
    ///   - model: The model the request asked for, or nil when it asked for none.
    static func error(
        status: Int, body: ClaudeErrorBody?, retryAfter: Duration?, model: AIModelID?
    ) -> AIError {
        let message = body?.error.message ?? generalMessage(forStatus: status)

        switch status {
        case 400:
            let isInvalidRequest = body?.error.type == "invalid_request_error"
            if isInvalidRequest && message.hasPrefix(userSpendLimitPrefix) {
                return .spendLimitReached(message)
            }
            return .badRequest(message)
        case 401:
            return .invalidCredentials
        case 402:
            return .billing(message)
        case 403:
            return .permissionDenied(message)
        case 404:
            // The URLs are fixed, so the one thing a request can name that does not exist is
            // its model. A model the key may not use is reported the same way.
            if let model {
                return .modelUnavailable(model)
            }
            return .badRequest(message)
        case 408:
            return .network(.timedOut)
        case 429:
            if body?.error.details?.errorCode == tierSpendCapCode {
                return .spendLimitReached(message)
            }
            return .rateLimited(retryAfter: retryAfter)
        case 529:
            return .overloaded
        case 400..<500:
            // 413 and whatever else the request itself is to blame for.
            return .badRequest(message)
        default:
            return .server(status: status, message: message)
        }
    }

    /// The status each kind of error has when it is the answer to a request. An error that
    /// arrives inside a stream has only its kind, the status having been 200.
    private static let statusByErrorType = [
        "invalid_request_error": 400,
        "authentication_error": 401,
        "billing_error": 402,
        "permission_error": 403,
        "not_found_error": 404,
        "request_too_large": 413,
        "rate_limit_error": 429,
        "api_error": 500,
        "timeout_error": 504,
        "overloaded_error": 529,
    ]

    /// The error for an `error` event in a stream that had begun with status 200.
    static func error(forStreamError body: ClaudeErrorBody, model: AIModelID) -> AIError {
        // A kind this version does not know is taken for a fault of the server's.
        let status = statusByErrorType[body.error.type] ?? 500
        return error(status: status, body: body, retryAfter: nil, model: model)
    }

    /// The longest wait a `retry-after` header is believed to mean, a day.
    private static let longestRetryAfter: Double = 24 * 60 * 60

    /// The `retry-after` header: the seconds to wait before asking again.
    static func retryAfter(in response: HTTPURLResponse) -> Duration? {
        guard let text = response.value(forHTTPHeaderField: "retry-after") else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // HTTP also allows a date here. The API sends seconds, and a date is not waited for.
        guard let seconds = Double(trimmed) else { return nil }
        // "1e30" and "nan" are numbers too. `Duration` traps on one it cannot hold, so
        // nothing outside the range gets that far.
        guard seconds >= 0, seconds <= longestRetryAfter else { return nil }
        return .seconds(seconds)
    }

    /// What Quick AI reports for an error that was thrown while a request ran.
    ///
    /// - Throws: `CancellationError` when the request was cancelled. That is no failure and is
    ///   never reported as an `AIError`.
    static func aiError(from error: any Error) throws -> AIError {
        // A cancelled task can fail in any number of ways on its way out. None of them is
        // what happened.
        if Task.isCancelled {
            throw CancellationError()
        }

        switch error {
        case let error as AIError:
            return error
        case is CancellationError:
            throw error
        case let error as URLError:
            if error.code == .cancelled {
                throw CancellationError()
            }
            return .network(error.code)
        default:
            return .network(.unknown)
        }
    }

    private static func generalMessage(forStatus status: Int) -> String {
        String(
            localized: "The server answered with HTTP status \(String(status)).",
            bundle: .module,
            comment:
                "Quick AI: the error shown when a request failed and the server's reply gave no reason. The placeholder is a number such as 502."
        )
    }
}
