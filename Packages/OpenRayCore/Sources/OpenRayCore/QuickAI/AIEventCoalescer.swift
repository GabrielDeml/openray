/// Gathers the text of a reply into fewer, larger pieces (docs/DESIGN.md §4.6.4).
///
/// A reply arrives as many small pieces of text, sometimes hundreds in a second, and each one
/// that reaches `QuickAISession` redraws the chat. The coalescer passes text on at most once
/// in `interval` and joins what arrives in between. Nothing else is held back or reordered.
///
/// There is no timer. Text that is held back goes out with the next event or when the reply
/// ends, whichever comes first. While a reply is arriving that is a matter of milliseconds.
struct AIEventCoalescer {
    /// The shortest time between two pieces of text that are passed on: one frame at 30 Hz.
    static let interval: Duration = .milliseconds(33)

    private var heldText = ""
    /// When text was last passed on. nil before the first text of a reply, which therefore
    /// goes out at once: the wait for the first word is the one the user notices.
    private var lastTextDelivery: ContinuousClock.Instant?

    /// Takes the next event of the reply and returns what is to be passed on now, in order.
    /// That is nothing when the event is text that is held back.
    mutating func receive(_ event: AIEvent, at instant: ContinuousClock.Instant) -> [AIEvent] {
        if case .textDelta(let text) = event {
            heldText += text
            if heldText.isEmpty { return [] }
            if let lastTextDelivery, instant - lastTextDelivery < Self.interval {
                return []
            }
            lastTextDelivery = instant
            return takeHeldText()
        }

        // Everything but text is passed on at once, behind the text that came before it.
        var batch = takeHeldText()
        if !batch.isEmpty {
            lastTextDelivery = instant
        }
        batch.append(event)
        return batch
    }

    /// The reply has ended, well or with an error: returns the text that was still held back.
    mutating func finish() -> [AIEvent] {
        takeHeldText()
    }

    private mutating func takeHeldText() -> [AIEvent] {
        if heldText.isEmpty { return [] }
        let text = heldText
        heldText = ""
        return [.textDelta(text)]
    }
}

extension AIEventCoalescer {
    /// The events of a reply in batches. Each batch is one update for its reader.
    ///
    /// The events are read in a task of their own, so that the reader's actor is entered once
    /// for a batch and not once for every piece of text. When the returned stream is no longer
    /// read, or its reader is cancelled, the task ends and `events` with it, which is how a
    /// provider learns that its request is not wanted any more.
    ///
    /// - Parameter now: The time an event is taken to have arrived at. Tests pass their own.
    static func batches(
        of events: AsyncThrowingStream<AIEvent, any Error>,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> AsyncThrowingStream<[AIEvent], any Error> {
        let (batches, continuation) = AsyncThrowingStream.makeStream(
            of: [AIEvent].self, throwing: (any Error).self)

        let reading = Task {
            var coalescer = AIEventCoalescer()
            var failure: (any Error)?
            do {
                for try await event in events {
                    let batch = coalescer.receive(event, at: now())
                    if !batch.isEmpty {
                        continuation.yield(batch)
                    }
                }
            } catch {
                failure = error
            }

            // The text came before the reply ended or failed, so the reader gets it first.
            let heldText = coalescer.finish()
            if !heldText.isEmpty {
                continuation.yield(heldText)
            }
            continuation.finish(throwing: failure)
        }
        continuation.onTermination = { _ in
            reading.cancel()
        }
        return batches
    }
}
