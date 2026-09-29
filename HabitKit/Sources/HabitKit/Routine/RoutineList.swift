import Foundation

/// Where each habit in a routine stands today, for the list that replaces the runner.
///
/// Folded from the same things the runner plans from, and nothing else: the completion fold
/// says what is done, and today's run says what was passed without being done. So the list,
/// the widgets and Siri agree on which habit is next, because all of them ask `RoutineRunner`.
public enum StepState: Hashable, Sendable {
    /// Done today.
    case done
    /// Passed today without being done. Once the day settles it reads as a miss, and until
    /// then it can still be done.
    case skipped
    /// Due and not yet passed, and first in sequence. What the widget and Siri would tick.
    case next
    /// Due and not yet passed, after the next one.
    case waiting
    /// Not due today: a rest day, or paused.
    case notDue

    /// Whether the habit can be done today from where it stands.
    public var canComplete: Bool { self == .next || self == .waiting || self == .skipped }

    /// Whether the habit can be skipped from where it stands.
    public var canSkip: Bool { self == .next || self == .waiting }
}

extension RoutineRunner {
    /// Where every habit of `routine` in `histories` stands, keyed by habit.
    ///
    /// `histories` must all be folded for one day, and `run`, if there is one, must be that
    /// day's. Archived habits are left out.
    public static func states(
        of routine: RoutineSlot,
        histories: [HabitHistory],
        run: RoutineRun?,
        at instant: Date,
        in timeZone: TimeZone
    ) -> [UUID: StepState] {
        // Planned on the day the histories were folded for, not the clock's. Between midnight
        // and the next reload the two differ, and a run opened on the clock's day would be
        // planned against yesterday's fold.
        let day = histories.first?.today ?? DayKey(instant, in: timeZone)
        let planned = run ?? RoutineRun(routine: routine, dayKey: day, startedAt: instant,
                                        timeZoneIdentifier: timeZone.identifier)
        let runner = RoutineRunner(routine: routine, histories: histories, resuming: planned,
                                   at: instant, in: timeZone)
        let passed = Set(planned.steps.filter(\.isPassed).map(\.habitID))
        var states: [UUID: StepState] = [:]
        for history in histories where history.habit.routine == routine && history.currentState != .archived {
            let id = history.habit.id
            states[id] = if !history.isDueToday {
                .notDue
            } else if history.isCompletedToday {
                .done
            } else if runner.currentHabitID == id {
                .next
            } else if passed.contains(id) {
                .skipped
            } else {
                .waiting
            }
        }
        return states
    }
}
