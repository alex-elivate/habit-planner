import Foundation

/// Which days a routine's reminder should fire on.
///
/// A reminder that fires on a day with nothing due teaches the person to ignore it, and the
/// reminder is what starts the routine. So reminders are planned per day from the schedule
/// rather than set once as a daily repeat.
///
/// Planned days run a fixed distance ahead and are replanned every time the app is opened or a
/// habit changes. The cost is that reminders stop after `horizonDays` without a launch. That is
/// a fair trade for an app whose premise is being opened twice a day, and it keeps the plan
/// honest about pauses and schedule edits, which a repeating trigger cannot see.
public enum ReminderPlan {
    /// How far ahead to plan. Two routines at this horizon use 28 of the 64 pending
    /// notifications iOS allows an app.
    public static let horizonDays = 14

    /// The days from `histories`' today onward on which `routine` has something due.
    ///
    /// Future days are judged on each habit's schedule and its lifecycle state *today*. A
    /// paused habit stays paused until someone resumes it, and a resume replans.
    ///
    /// Today is included only while something in the routine is still due and not done, and
    /// never once `finishedToday` is set. Whether today's reminder time has already passed is
    /// the caller's question, since only it holds the time.
    public static func days(
        for routine: RoutineSlot,
        histories: some Sequence<HabitHistory>,
        finishedToday: Bool,
        horizonDays: Int = horizonDays
    ) -> [DayKey] {
        let candidates = histories.filter {
            $0.habit.routine == routine && $0.currentState == .active
        }
        guard let today = candidates.first?.today else { return [] }

        var days: [DayKey] = []
        let todayOutstanding = candidates.contains { $0.isDueToday && !$0.isCompletedToday }
        if todayOutstanding, !finishedToday { days.append(today) }

        guard horizonDays > 1 else { return days }
        for offset in 1..<horizonDays {
            let day = today.advanced(by: offset)
            if candidates.contains(where: { $0.habit.isScheduled(on: day) }) { days.append(day) }
        }
        return days
    }
}
