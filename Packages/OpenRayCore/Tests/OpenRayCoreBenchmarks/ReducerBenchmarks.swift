import Testing

import OpenRayCore

extension Benchmarks {
    /// What a keystroke costs in the reducer once its results are there: 200 rows, the most the
    /// root list shows, replacing the 200 of the keystroke before (docs/DESIGN.md §4.1.9).
    @Suite struct ReducerBenchmarks {
        private static let rowCount = 200

        /// Rows with the item IDs `system:<prefix>-0` to `system:<prefix>-199`.
        private func rows(prefix: String) -> [LauncherState.Row] {
            var rows: [LauncherState.Row] = []
            for index in 0..<Self.rowCount {
                let name = "\(prefix)-\(index)"
                let row = LauncherState.Row(
                    id: .system(name), primaryAction: ActionID(rawValue: "run-\(name)"))
                rows.append(row)
            }
            return rows
        }

        @Test func twoHundredRowsReplaceTwoHundredRows() {
            // Two queries and two sets of rows, taken in turn: an unchanged query starts no
            // search, and rows that only repeat the ones on screen would be the easy case.
            let queries = ["s", "sa"]
            let rowPrefixes = ["first", "second"]

            var state = LauncherState()
            var samples = BenchmarkSamples()
            let clock = ContinuousClock()

            for run in 0..<(Benchmarks.warmUpRuns + Benchmarks.measuredRuns) {
                let turn = run % 2
                _ = state.apply(.queryChanged(queries[turn]))
                // Built anew for every run, as the app builds them for every answer. The rows
                // they replace are then freed inside the reducer, which is part of its cost.
                let arrivingRows = rows(prefix: rowPrefixes[turn])

                let start = clock.now
                _ = state.apply(.resultsArrived(rows: arrivingRows, generation: state.generation))
                let elapsed = clock.now - start

                if run >= Benchmarks.warmUpRuns {
                    samples.add(elapsed)
                }
            }

            // Results of a stale generation are dropped at once. Had that happened here, the
            // numbers would be those of doing nothing.
            #expect(state.top.rows.count == Self.rowCount)
            #expect(state.top.selection == state.top.rows.first?.id)

            samples.report("reducer, \(Self.rowCount) rows arrive")
        }
    }
}
