import Foundation

/// One day on which a habit was due, and whether it got done.
public struct ScheduledOccurrence: Hashable, Sendable {
    public let day: DayKey
    public let isCompleted: Bool

    public init(day: DayKey, isCompleted: Bool) {
        self.day = day
        self.isCompleted = isCompleted
    }
}

/// A habit's completion log folded into the shape every score and rule reads from.
///
/// Today is held apart from the settled history on purpose. A habit due today that has not
/// been done yet is not a miss, it is simply unfinished, and counting it as a miss would
/// break streaks every morning before breakfast.
public struct HabitHistory: Hashable, Sendable {
    public let habit: Habit
    public let today: DayKey

    /// Days this habit was due, through yesterday, oldest first.
    public let settledOccurrences: [ScheduledOccurrence]

    public let isDueToday: Bool
    public let isCompletedToday: Bool

    public init(habit: Habit, events: some Sequence<CompletionEvent>, today: DayKey) {
        self.habit = habit
        self.today = today

        let completedDays = Set(
            events.lazy.filter { $0.habitID == habit.id }.map(\.dayKey)
        )

        let lastSettledDay = today.advanced(by: -1)
        self.settledOccurrences = habit.startedOn.through(lastSettledDay)
            .filter { habit.wasScheduled(on: $0) }
            .map { ScheduledOccurrence(day: $0, isCompleted: completedDays.contains($0)) }

        self.isDueToday = habit.isDue(on: today)
        self.isCompletedToday = completedDays.contains(today)
    }

    /// The settled occurrences falling on the last `days` calendar days before today.
    public func settledOccurrences(withinLast days: Int) -> [ScheduledOccurrence] {
        let earliest = today.advanced(by: -days)
        return settledOccurrences.filter { $0.day >= earliest }
    }
}
