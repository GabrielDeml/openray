import Foundation

/// How usage scores fade (docs/DESIGN.md §4.2.7). Every pick adds 1 to a score, and a score
/// halves with every `RankingTuning.halfLife` that passes, so recent picks count for more than
/// old ones.
enum Frecency {
    /// What a score that was `score` at `referenceTime` is worth at `now`.
    static func decayed(_ score: Double, from referenceTime: Date, to now: Date) -> Double {
        // The clock can be set back, which puts `referenceTime` in the future. A score never
        // grows by waiting, so that counts as no time passed.
        let elapsed = max(0, now.timeIntervalSince(referenceTime))
        return score * pow(2, -elapsed / RankingTuning.halfLife)
    }
}
