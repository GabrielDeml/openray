import Synchronization
import Testing

@testable import OpenRayCore

// A stream keeps only its newest element, so an extra yield of an unchanged value cannot be seen
// from outside. What can be counted is how often the stream reads its value: once when it is
// made, and once more for every notification that reaches it.
@Suite struct PreferenceObserversTests {
    @Test func notifyingOneNameLeavesStreamsOfOtherNamesAlone() {
        let observers = PreferenceObservers()
        let readCount = Mutex(0)
        let stream = observers.stream(name: "clipboard.retention") {
            readCount.withLock { count in count += 1 }
        }

        observers.notify("clipboard.enabled")
        let readsAfterAnotherName = readCount.withLock { count in count }

        observers.notify("clipboard.retention")
        let readsAfterItsOwnName = readCount.withLock { count in count }

        #expect(readsAfterAnotherName == 1)
        #expect(readsAfterItsOwnName == 2)
        // A stream that nothing holds has ended. This one must live until the last `notify`.
        withExtendedLifetime(stream) {}
    }

    @Test func endedStreamIsNoLongerNotified() {
        let observers = PreferenceObservers()
        let readCount = Mutex(0)
        // Nothing holds the stream, so it ends as soon as it is made.
        _ = observers.stream(name: "clipboard.retention") {
            readCount.withLock { count in count += 1 }
        }

        observers.notify("clipboard.retention")

        let reads = readCount.withLock { count in count }
        #expect(reads == 1)
    }
}
