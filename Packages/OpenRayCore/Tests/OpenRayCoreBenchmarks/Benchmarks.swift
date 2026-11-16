import Foundation
import Testing

/// The benchmarks run only when the environment variable `OPENRAY_BENCHMARKS` is `1`, so the
/// `swift test` that gates CI skips them: they take time and assert nothing about it.
///
/// This is not a member of `Benchmarks`, because the attribute on that type could not refer to
/// it: the compiler calls that a circular reference.
private let benchmarksAreSwitchedOn =
    ProcessInfo.processInfo.environment["OPENRAY_BENCHMARKS"] == "1"

/// The parent of every benchmark suite (docs/DESIGN.md §5.4). A benchmark prints what it
/// measured and leaves the judging to whoever reads the numbers.
///
/// The benchmarks run one after the other. Swift Testing would otherwise start them together,
/// and each would be timed while the others keep the cores busy.
@Suite(.serialized, .enabled(if: benchmarksAreSwitchedOn))
struct Benchmarks {
    /// How often a benchmark runs what it measures before it starts counting, so that the
    /// first, slower runs are not among the samples.
    static let warmUpRuns = 20
    /// How many runs a benchmark counts.
    static let measuredRuns = 200
}

/// The durations of one benchmark's measured runs.
struct BenchmarkSamples {
    private var milliseconds: [Double] = []

    mutating func add(_ duration: Duration) {
        let components = duration.components
        let fromSeconds = Double(components.seconds) * 1_000
        let fromAttoseconds = Double(components.attoseconds) / 1e15
        milliseconds.append(fromSeconds + fromAttoseconds)
    }

    /// The duration that the given share of the runs did not exceed, by the nearest-rank
    /// method: of 200 runs, the 95th percentile is the 190th shortest.
    func percentile(_ percent: Int) -> Double {
        precondition(!milliseconds.isEmpty, "A benchmark has to add a sample before it reports.")
        let sorted = milliseconds.sorted()
        let rank = (Double(percent) / 100 * Double(sorted.count)).rounded(.up)
        let index = max(Int(rank), 1) - 1
        return sorted[index]
    }

    /// Prints one line with the median and the 95th percentile, which is what the latency
    /// budget is written in (§4.1.9). Four decimals, because the reducer takes a few
    /// microseconds in a release build.
    func report(_ name: String) {
        let median = String(format: "%.4f", percentile(50))
        let p95 = String(format: "%.4f", percentile(95))
        print("[benchmark] \(name): median \(median) ms, p95 \(p95) ms, \(milliseconds.count) runs")
    }
}
