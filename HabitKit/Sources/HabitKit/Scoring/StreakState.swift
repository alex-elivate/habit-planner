import Foundation

/// Where a habit stands under the "never miss twice" rule.
///
/// One miss dings the score but leaves the streak standing. Two misses in a row end it.
/// The rule exists because the second miss, not the first, is where habits actually die,
/// so `recovery` is the state worth shouting about in the interface.
public enum StreakState: Hashable, Sendable {
    /// The most recent settled occurrence was completed.
    case healthy(length: Int)

    /// The most recent settled occurrence was missed. The streak survives one more day.
    case recovery(length: Int)

    /// Two consecutive misses. The streak is over.
    case broken

    public var length: Int {
        switch self {
        case .healthy(let length), .recovery(let length): return length
        case .broken: return 0
        }
    }

    public var isAtRisk: Bool {
        if case .recovery = self { return true }
        return false
    }
}

extension HabitHistory {
    public var streak: StreakState {
        var trailingMisses = 0
        for occurrence in settledOccurrences.reversed() {
            if occurrence.isCompleted { break }
            trailingMisses += 1
            if trailingMisses >= 2 { break }
        }

        if trailingMisses >= 2 { return .broken }

        // Walk back counting completions, stopping at the first pair of consecutive misses.
        var length = 0
        var consecutiveMisses = 0
        for occurrence in settledOccurrences.reversed() {
            if occurrence.isCompleted {
                length += 1
                consecutiveMisses = 0
            } else {
                consecutiveMisses += 1
                if consecutiveMisses >= 2 { break }
            }
        }

        return trailingMisses == 1 ? .recovery(length: length) : .healthy(length: length)
    }
}
