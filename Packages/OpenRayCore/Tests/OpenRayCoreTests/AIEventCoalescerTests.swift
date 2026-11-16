import Foundation
import Synchronization
import Testing

@testable import OpenRayCore

private let usage = AIEvent.usage(AIUsage(inputTokens: 12, outputTokens: 5))
private let started = AIEvent.started(model: ClaudeProvider.haiku, requestID: "req_fake")
private let finished = AIEvent.finished(.endTurn, assistant: assistantMessage("abcd"))

/// The rules by which text is held back, with made-up times.
@Suite struct AIEventCoalescerTests {
    /// When the reply began. Only the distances to it matter.
    private let start = ContinuousClock.now

    private func after(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    @Test func firstTextIsPassedOnAtOnce() {
        var coalescer = AIEventCoalescer()

        #expect(coalescer.receive(.textDelta("a"), at: after(0)) == [.textDelta("a")])
    }

    @Test func eventsBeforeTheFirstTextDoNotHoldItBack() {
        var coalescer = AIEventCoalescer()

        #expect(coalescer.receive(started, at: after(0)) == [started])
        #expect(
            coalescer.receive(.reasoning(active: true), at: after(1)) == [.reasoning(active: true)])
        #expect(
            coalescer.receive(.reasoning(active: false), at: after(2)) == [
                .reasoning(active: false)
            ])
        #expect(coalescer.receive(.textDelta("a"), at: after(3)) == [.textDelta("a")])
    }

    @Test func textInsideOneIntervalIsJoinedAndPassedOnWhenTheIntervalIsOver() {
        var coalescer = AIEventCoalescer()
        _ = coalescer.receive(.textDelta("a"), at: after(0))

        #expect(coalescer.receive(.textDelta("b"), at: after(10)) == [])
        #expect(coalescer.receive(.textDelta("c"), at: after(32)) == [])
        #expect(coalescer.receive(.textDelta("d"), at: after(33)) == [.textDelta("bcd")])
        // The interval is counted from the text that went out last.
        #expect(coalescer.receive(.textDelta("e"), at: after(65)) == [])
        #expect(coalescer.receive(.textDelta("f"), at: after(66)) == [.textDelta("ef")])
    }

    @Test func textAfterAQuietIntervalIsPassedOnAtOnce() {
        var coalescer = AIEventCoalescer()
        _ = coalescer.receive(.textDelta("a"), at: after(0))

        #expect(coalescer.receive(.textDelta("b"), at: after(500)) == [.textDelta("b")])
    }

    @Test func anyOtherEventIsPassedOnAtOnceBehindTheTextBeforeIt() {
        var coalescer = AIEventCoalescer()
        _ = coalescer.receive(.textDelta("a"), at: after(0))
        _ = coalescer.receive(.textDelta("b"), at: after(5))
        _ = coalescer.receive(.textDelta("c"), at: after(6))

        #expect(coalescer.receive(usage, at: after(7)) == [.textDelta("bc"), usage])
        // Nothing is held any more.
        #expect(coalescer.receive(finished, at: after(8)) == [finished])
    }

    @Test func textThatWentOutWithAnotherEventStartsTheIntervalAgain() {
        var coalescer = AIEventCoalescer()
        _ = coalescer.receive(.textDelta("a"), at: after(0))
        _ = coalescer.receive(.textDelta("b"), at: after(20))
        _ = coalescer.receive(usage, at: after(30))

        #expect(coalescer.receive(.textDelta("c"), at: after(40)) == [])
        #expect(coalescer.receive(.textDelta("d"), at: after(63)) == [.textDelta("cd")])
    }

    @Test func endOfTheReplyReleasesTheTextThatWasHeld() {
        var coalescer = AIEventCoalescer()
        _ = coalescer.receive(.textDelta("a"), at: after(0))
        _ = coalescer.receive(.textDelta("b"), at: after(1))

        #expect(coalescer.finish() == [.textDelta("b")])
        #expect(coalescer.finish() == [])
    }

    @Test func emptyTextIsNeverPassedOn() {
        var coalescer = AIEventCoalescer()

        #expect(coalescer.receive(.textDelta(""), at: after(0)) == [])
        // And it does not count as the first text.
        #expect(coalescer.receive(.textDelta("a"), at: after(1)) == [.textDelta("a")])
    }

    /// The text of neighbouring deltas joined into one, which is all the coalescer may change.
    private func joiningNeighbouringText(_ events: [AIEvent]) -> [AIEvent] {
        var joined: [AIEvent] = []
        for event in events {
            if case .textDelta(let text) = event, case .textDelta(let textBefore) = joined.last {
                joined[joined.count - 1] = .textDelta(textBefore + text)
            } else {
                joined.append(event)
            }
        }
        return joined
    }

    @Test func nothingIsLostOrReorderedWhateverTheTiming() {
        var generator = SeededGenerator(seed: 33)

        for _ in 0..<200 {
            var received: [AIEvent] = []
            var passedOn: [AIEvent] = []
            var coalescer = AIEventCoalescer()
            var milliseconds = 0

            for _ in 0..<Int.random(in: 1...60, using: &generator) {
                let isText = Int.random(in: 0..<5, using: &generator) > 0
                let event = isText ? AIEvent.textDelta("x") : usage
                // Mostly inside one interval, sometimes well past it.
                milliseconds += Int.random(in: 0...50, using: &generator)

                received.append(event)
                passedOn += coalescer.receive(event, at: after(milliseconds))
            }
            passedOn += coalescer.finish()

            #expect(joiningNeighbouringText(passedOn) == joiningNeighbouringText(received))
        }
    }
}

/// The coalescer between a provider's stream and its reader.
@Suite(.timeLimit(.minutes(1))) struct AIEventBatchesTests {
    /// A clock that says the next of these times each time it is asked: the times, in
    /// milliseconds, at which the events of a test arrive.
    private func clock(arrivals: [Int]) -> @Sendable () -> ContinuousClock.Instant {
        let start = ContinuousClock.now
        let remaining = Mutex(arrivals)
        return {
            let milliseconds = remaining.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
            return start + .milliseconds(milliseconds)
        }
    }

    /// A provider's stream that holds `events` and then ends, with `error` if one is given.
    private func upstream(
        of events: [AIEvent], endingWith error: (any Error)? = nil
    ) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish(throwing: error)
        }
    }

    @Test func replyComesThroughInBatches() async throws {
        let events: [AIEvent] = [
            started, .textDelta("a"), .textDelta("b"), .textDelta("c"), usage, .textDelta("d"),
            finished,
        ]
        let arrivals = [0, 1, 10, 20, 21, 100, 101]

        var batches: [[AIEvent]] = []
        let stream = AIEventCoalescer.batches(
            of: upstream(of: events), now: clock(arrivals: arrivals))
        for try await batch in stream {
            batches.append(batch)
        }

        #expect(
            batches == [
                [started], [.textDelta("a")], [.textDelta("bc"), usage], [.textDelta("d")],
                [finished],
            ])
    }

    @Test func textHeldAtTheEndOfTheStreamIsStillDelivered() async throws {
        let events: [AIEvent] = [.textDelta("a"), .textDelta("b")]

        var batches: [[AIEvent]] = []
        let stream = AIEventCoalescer.batches(
            of: upstream(of: events), now: clock(arrivals: [0, 1]))
        for try await batch in stream {
            batches.append(batch)
        }

        #expect(batches == [[.textDelta("a")], [.textDelta("b")]])
    }

    @Test func textBeforeAnErrorIsDeliveredBeforeTheError() async {
        let events: [AIEvent] = [.textDelta("a"), .textDelta("b")]
        let stream = AIEventCoalescer.batches(
            of: upstream(of: events, endingWith: AIError.overloaded),
            now: clock(arrivals: [0, 1]))

        var batches: [[AIEvent]] = []
        var failure: (any Error)?
        do {
            for try await batch in stream {
                batches.append(batch)
            }
        } catch {
            failure = error
        }

        #expect(batches == [[.textDelta("a")], [.textDelta("b")]])
        #expect(failure as? AIError == .overloaded)
    }

    /// A provider's stream that never ends by itself, and a signal for when its reader has
    /// ended it.
    private func endlessUpstream() -> (
        events: AsyncThrowingStream<AIEvent, any Error>, cancellations: AsyncStream<Void>
    ) {
        let (cancellations, cancelled) = AsyncStream.makeStream(of: Void.self)
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: AIEvent.self, throwing: (any Error).self)
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                cancelled.yield()
            }
        }
        continuation.yield(.textDelta("a"))
        return (events, cancellations)
    }

    @Test func readerThatStopsReadingEndsTheProvidersStream() async throws {
        let (events, cancellations) = endlessUpstream()

        for try await _ in AIEventCoalescer.batches(of: events) {
            break
        }

        // Were the provider's stream still open, nothing would arrive here and the test would
        // run into its time limit.
        for await _ in cancellations { break }
    }

    @Test func cancellingTheReaderEndsTheProvidersStream() async throws {
        let (events, cancellations) = endlessUpstream()
        let batches = AIEventCoalescer.batches(of: events)
        let (firstBatch, firstBatchContinuation) = AsyncStream.makeStream(of: Void.self)

        let reader = Task {
            var batchCount = 0
            for try await _ in batches {
                batchCount += 1
                firstBatchContinuation.yield()
            }
            return batchCount
        }
        for await _ in firstBatch { break }
        reader.cancel()

        // The reader sees its stream end, and the provider's stream ends with it.
        #expect(try await reader.value == 1)
        for await _ in cancellations { break }
    }
}
