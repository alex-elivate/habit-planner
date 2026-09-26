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

/// A habit's logs folded into the shape every score and rule reads from.
///
/// Today is held apart from the settled history on purpose. A habit due today that has not
/// been done yet is not a miss, it is simply unfinished, and counting it as a miss would
/// break streaks every morning before breakfast.
public struct HabitHistory: Hashable, Sendable {
    public let habit: Habit
    public let today: DayKey

    /// Lifecycle folded from the log, so paused and archived stretches can be excluded.
    public let lifecycle: LifecycleTimeline

    /// Days this habit was due and active, through yesterday, oldest first.
    public let settledOccurrences: [ScheduledOccurrence]

    public let isDueToday: Bool
    public let isCompletedToday: Bool

    /// Days counted as done, corrections applied. Kept so the fold can be rerun for a changed
    /// habit without the raw log.
    private let completedDays: Set<DayKey>

    /// Whether a completion or a lifecycle change is dated after `today`, which happens only
    /// when the clock has gone back since it was recorded.
    public var hasRecordsAfterToday: Bool {
        completedDays.contains { $0 > today } || lifecycle.transitions.contains { $0.day > today }
    }

    public init(
        habit: Habit,
        events: some Sequence<CompletionEvent>,
        lifecycle lifecycleEvents: some Sequence<LifecycleEvent>,
        today: DayKey
    ) {
        let timeline = LifecycleTimeline(
            habitID: habit.id,
            startedOn: habit.startedOn,
            events: lifecycleEvents
        )

        // Corrections applied, so a retracted tick does not count as done.
        self.init(habit: habit, completedDays: Array(events).completedDays(for: habit.id),
                  lifecycle: timeline, today: today)
    }

    private init(habit: Habit, completedDays: Set<DayKey>, lifecycle timeline: LifecycleTimeline, today: DayKey) {
        self.habit = habit
        self.today = today
        self.lifecycle = timeline
        self.completedDays = completedDays

        // One pass over the ordinal range. Chaining through(), filter and map allocated
        // three arrays the size of the habit's entire lifetime, on a path that runs inside
        // a widget extension.
        let first = habit.startedOn.ordinal
        let last = today.advanced(by: -1).ordinal
        var occurrences: [ScheduledOccurrence] = []
        if last >= first {
            occurrences.reserveCapacity(last - first + 1)
            for ordinal in first...last {
                let day = DayKey(ordinal: ordinal)
                guard habit.isScheduled(on: day), timeline.isActive(on: day) else { continue }
                occurrences.append(
                    ScheduledOccurrence(day: day, isCompleted: completedDays.contains(day))
                )
            }
        }
        self.settledOccurrences = occurrences

        let dueToday = habit.isScheduled(on: today) && timeline.isActive(on: today)
        self.isDueToday = dueToday
        // Guarded by due, so a paused row cannot draw a checkmark.
        self.isCompletedToday = dueToday && completedDays.contains(today)
    }

    /// Convenience for a habit that has never been paused or archived.
    public init(habit: Habit, events: some Sequence<CompletionEvent>, today: DayKey) {
        self.init(habit: habit, events: events, lifecycle: [LifecycleEvent](), today: today)
    }

    /// The state this habit is in as of today.
    /// The same history folded for a changed habit, such as a proposed schedule edit.
    ///
    /// Answers "what would the gate say if this were saved" without a store round trip.
    public func replacing(_ habit: Habit) -> HabitHistory {
        precondition(habit.id == self.habit.id, "A history can only be refolded for its own habit")
        return HabitHistory(habit: habit, completedDays: completedDays, lifecycle: lifecycle, today: today)
    }

    public var currentState: LifecycleEvent.State {
        lifecycle.state(on: today)
    }

    /// The settled occurrences falling on the last `days` calendar days before today.
    public func settledOccurrences(withinLast days: Int) -> [ScheduledOccurrence] {
        let earliest = today.advanced(by: -days)
        return settledOccurrences.filter { $0.day >= earliest }
    }
}
