import Foundation

/// A completed-out-of-due count.
public struct Progress: Hashable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// Zero when nothing is due, so the ring reads empty rather than full on a rest day.
    public var fraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    public var isComplete: Bool {
        total > 0 && completed == total
    }
}

/// Derives every displayed number by folding the completion log. Holds no state.
public enum ScoreEngine {
    /// Default window for the headline score. Long enough to smooth a bad day, short enough
    /// to still respond to this week.
    public static let defaultWindowDays = 7

    /// Today's live progress. This is the ring.
    public static func todayProgress(for histories: some Sequence<HabitHistory>) -> Progress {
        var completed = 0
        var total = 0
        for history in histories where history.isDueToday {
            total += 1
            if history.isCompletedToday { completed += 1 }
        }
        return Progress(completed: completed, total: total)
    }

    /// Completion rate across settled days, `nil` when nothing was ever due in the window.
    ///
    /// Today is excluded deliberately. The ring already covers today, and a number that
    /// sagged every morning and recovered every evening would be unreadable at a glance.
    public static func trailingRate(
        for histories: some Sequence<HabitHistory>,
        days: Int = defaultWindowDays
    ) -> Double? {
        var completed = 0
        var total = 0
        for history in histories {
            for occurrence in history.settledOccurrences(withinLast: days) {
                total += 1
                if occurrence.isCompleted { completed += 1 }
            }
        }
        guard total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    /// The headline score, 0 through 100. This is the number on the watch face.
    ///
    /// `nil` when there is no settled history to judge, so the interface can show a dash
    /// instead of claiming a perfect or a failing week that never happened.
    public static func score(
        for histories: some Sequence<HabitHistory>,
        days: Int = defaultWindowDays
    ) -> Int? {
        guard let rate = trailingRate(for: histories, days: days) else { return nil }
        return Int((rate * 100).rounded())
    }
}
