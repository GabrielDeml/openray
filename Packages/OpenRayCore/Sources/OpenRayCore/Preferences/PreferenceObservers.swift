import Synchronization

/// The `changes(for:)` streams of one store, notified by name when a preference is set.
final class PreferenceObservers: Sendable {
    /// One live stream.
    private struct Observer {
        /// The name of the preference the stream follows.
        let name: String
        /// Reads the preference from the store and yields it to the stream.
        let deliver: @Sendable () -> Void
    }

    private struct Registry {
        var nextToken: UInt64 = 0
        var observers: [UInt64: Observer] = [:]
    }

    private let registry = Mutex(Registry())
    /// Held from reading the store to yielding what was read. Without it two concurrent sets
    /// could yield in the opposite order to their reads and leave a stream on the older value.
    private let delivery = Mutex(())

    /// A stream of `read()`: once now, and again after every `notify(name)`. Only the newest
    /// value is kept for a consumer that falls behind.
    func stream<V: Sendable>(name: String, read: @escaping @Sendable () -> V) -> AsyncStream<V> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: V.self, bufferingPolicy: .bufferingNewest(1))
        let deliver: @Sendable () -> Void = {
            continuation.yield(read())
        }

        // Registered before the first read, so a change in between is never missed.
        let token = registry.withLock { registry in
            registry.nextToken += 1
            registry.observers[registry.nextToken] = Observer(name: name, deliver: deliver)
            return registry.nextToken
        }
        delivery.withLock { _ in
            deliver()
        }
        continuation.onTermination = { [weak self] _ in
            self?.registry.withLock { $0.observers[token] = nil }
        }
        return stream
    }

    func notify(_ name: String) {
        // The observers are copied out and run outside the registry's lock: they read the
        // store, which may be slow.
        let observers = registry.withLock { registry in
            registry.observers.values.filter { $0.name == name }
        }
        delivery.withLock { _ in
            for observer in observers {
                observer.deliver()
            }
        }
    }
}
