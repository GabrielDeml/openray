import Foundation

/// Where picks are kept. Ranking reads them through `snapshot()`, which never waits on the disk.
public protocol UsageStore: Sendable {
    /// Counts one pick of the item, made with `query` as typed in the search field.
    func record(pick: ItemID, query: String, at: Date) async throws
    func snapshot() async -> UsageSnapshot
}

/// A store that forgets everything when it goes away, for tests and for a session whose database
/// could not be opened. It counts picks exactly as `SQLiteUsageStore` does.
public actor InMemoryUsageStore: UsageStore {
    private var usage = UsageSnapshot()

    public init() {}

    public func record(pick id: ItemID, query: String, at time: Date) {
        usage.record(pick: id, query: query, at: time)
    }

    public func snapshot() -> UsageSnapshot {
        usage
    }
}
