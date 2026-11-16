import Foundation
import Testing

import OpenRayCore

@Suite struct RetryPolicyTests {
    /// The jitter at its upper end, so that a wait is the longest it can be.
    private let policy = RetryPolicy(jitter: { 1 })

    /// The wait before the first retry of a failure that arrived before any text, without a
    /// `retry-after`.
    private func firstDelay(after failure: AIError) -> Duration? {
        policy.delay(after: failure, retryAfter: nil, retriesSoFar: 0, hasStreamedText: false)
    }

    @Test(arguments: [
        AIError.network(.timedOut),
        .network(.networkConnectionLost),
        .network(.cannotConnectToHost),
        .server(status: 500, message: "Internal server error"),
        .server(status: 502, message: ""),
        .server(status: 503, message: ""),
        .server(status: 504, message: ""),
        .overloaded,
    ])
    func failuresThatMayPassAreRetried(_ failure: AIError) {
        #expect(firstDelay(after: failure) == .milliseconds(500))
    }

    @Test(arguments: [
        AIError.missingCredentials,
        .credentialsUnreadable,
        .invalidCredentials,
        .permissionDenied("No access."),
        .spendLimitReached("You have reached your specified API usage limits."),
        .billing("Your credit balance is too low."),
        .badRequest("max_tokens: too large"),
        .modelUnavailable(ClaudeProvider.opus),
        .malformedStream("the stream ended before the message did"),
        .network(.notConnectedToInternet),
        .network(.cannotFindHost),
        .network(.secureConnectionFailed),
        .network(.unknown),
        .server(status: 501, message: ""),
        .rateLimited(retryAfter: nil),
    ])
    func failuresThatWillNotPassAreFinal(_ failure: AIError) {
        #expect(firstDelay(after: failure) == nil)
        // A `retry-after` does not make them worth another try either. A rate limit is the
        // exception, and has a test of its own.
        if failure != .rateLimited(retryAfter: nil) {
            let delay = policy.delay(
                after: failure, retryAfter: .seconds(1), retriesSoFar: 0, hasStreamedText: false)
            #expect(delay == nil)
        }
    }

    @Test func waitDoublesWithEveryRetryAndEndsAfterTheSecond() {
        var delays: [Duration?] = []
        for retriesSoFar in 0...3 {
            delays.append(
                policy.delay(
                    after: .overloaded, retryAfter: nil, retriesSoFar: retriesSoFar,
                    hasStreamedText: false))
        }

        #expect(delays == [.milliseconds(500), .seconds(1), nil, nil])
    }

    @Test func jitterTakesAShareOfTheLongestWait() {
        let half = RetryPolicy(jitter: { 0.5 })
        let none = RetryPolicy(jitter: { 0 })

        #expect(
            half.delay(after: .overloaded, retryAfter: nil, retriesSoFar: 1, hasStreamedText: false)
                == .milliseconds(500))
        #expect(
            none.delay(after: .overloaded, retryAfter: nil, retriesSoFar: 0, hasStreamedText: false)
                == .zero)
    }

    @Test func serversWaitIsKeptAndNotJittered() {
        let half = RetryPolicy(jitter: { 0.5 })

        let delay = half.delay(
            after: .overloaded, retryAfter: .seconds(4), retriesSoFar: 1, hasStreamedText: false)

        #expect(delay == .seconds(4))
    }

    @Test func rateLimitIsRetriedOnlyWhenTheServerSaysHowLongItLasts() {
        let short = policy.delay(
            after: .rateLimited(retryAfter: .seconds(3)), retryAfter: .seconds(3), retriesSoFar: 0,
            hasStreamedText: false)
        let atTheLimit = policy.delay(
            after: .rateLimited(retryAfter: .seconds(10)), retryAfter: .seconds(10),
            retriesSoFar: 0, hasStreamedText: false)
        let long = policy.delay(
            after: .rateLimited(retryAfter: .seconds(30)), retryAfter: .seconds(30),
            retriesSoFar: 0, hasStreamedText: false)

        #expect(short == .seconds(3))
        #expect(atTheLimit == .seconds(10))
        #expect(long == nil)
        #expect(firstDelay(after: .rateLimited(retryAfter: nil)) == nil)
    }

    @Test func waitOfMoreThanTenSecondsIsNotWaitedForOnAnyStatus() {
        let failures: [AIError] = [
            .overloaded, .server(status: 503, message: ""), .network(.timedOut),
        ]

        for failure in failures {
            let delay = policy.delay(
                after: failure, retryAfter: .seconds(11), retriesSoFar: 0, hasStreamedText: false)
            #expect(delay == nil)
        }
    }

    @Test func nothingIsRetriedOnceTextHasStreamed() {
        let delay = policy.delay(
            after: .overloaded, retryAfter: .seconds(1), retriesSoFar: 0, hasStreamedText: true)

        #expect(delay == nil)
    }

    @Test func defaultJitterStaysWithinTheLongestWait() {
        let randomPolicy = RetryPolicy()

        for _ in 0..<200 {
            let delay = randomPolicy.delay(
                after: .overloaded, retryAfter: nil, retriesSoFar: 1, hasStreamedText: false)
            #expect(delay != nil)
            if let delay {
                #expect(delay >= .zero && delay <= .seconds(1))
            }
        }
    }
}
