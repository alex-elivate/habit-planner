import Foundation

/// What one habit's history looks like laid out on a calendar, and summed by week and month.
///
/// Read off `HabitHistory` and nothing else, so a report can never disagree with the streak,
/// the score or the lock-in gate. A day counts in a rate exactly when it is one of the
/// settled occurrences the gate judges: scheduled, active, and before today.
public struct HabitReport: Sendable {

    /// How a single day reads for this habit.
    public enum Mark: Hashable, Sendable {
        /// Before the habit started.
        case beforeStart
        /// Scheduled, active and done.
        case done
        /// Scheduled, active, settled and not done.
        case missed
        /// Not on the schedule.
        case rest
        /// On the schedule, but the habit was paused.
        case paused
        /// After the habit was archived.
        case archived
        /// Today, due and not yet done. Not a miss: today is never settled.
        case pending
        /// After today.
        case future
    }

    /// Done out of scheduled over a run of days.
    public struct Period: Hashable, Sendable {
        /// The first day of the period: a Monday for a week, the 1st for a month.
        public let start: DayKey
        public let completed: Int
        public let scheduled: Int

        /// `nil` when nothing was scheduled, which is not the same as zero.
        public var rate: Double? { scheduled == 0 ? nil : Double(completed) / Double(scheduled) }
    }

    public let history: HabitHistory
    private let settled: [DayKey: Bool]

    public init(_ history: HabitHistory) {
        self.history = history
        self.settled = Dictionary(history.settledOccurrences.map { ($0.day, $0.isCompleted) },
                                  uniquingKeysWith: { first, _ in first })
    }

    public var today: DayKey { history.today }

    public func mark(on day: DayKey) -> Mark {
        let habit = history.habit
        if day < habit.startedOn { return .beforeStart }
        if day > today { return .future }
        if day == today {
            if history.isDueToday { return history.isCompletedToday ? .done : .pending }
            return inactiveMark(on: day) ?? .rest
        }
        if let done = settled[day] { return done ? .done : .missed }
        // Not a settled occurrence: either off the schedule or the habit was not active.
        return inactiveMark(on: day) ?? .rest
    }

    private func inactiveMark(on day: DayKey) -> Mark? {
        switch history.lifecycle.state(on: day) {
        case .active: return nil
        case .paused: return history.habit.isScheduled(on: day) ? .paused : .rest
        case .archived: return .archived
        }
    }

    /// Every day of a calendar month with its mark, in order.
    public func month(year: Int, month: Int) -> [(day: DayKey, mark: Mark)] {
        let first = DayKey(year: year, month: month, day: 1)
        let next = month == 12 ? DayKey(year: year + 1, month: 1, day: 1) : DayKey(year: year, month: month + 1, day: 1)
        return first.through(next.advanced(by: -1)).map { ($0, mark(on: $0)) }
    }

    /// The last `count` weeks, Monday to Sunday, oldest first. The newest is the week that
    /// holds yesterday, since today never counts.
    public func weeks(_ count: Int) -> [Period] {
        let lastSettled = today.advanced(by: -1)
        let newest = Self.monday(of: lastSettled)
        return (0..<count).reversed().map { back in
            let start = newest.advanced(by: -7 * back)
            return period(from: start, through: start.advanced(by: 6))
        }
    }

    /// The last `count` calendar months, oldest first, ending with the month that holds
    /// yesterday.
    public func months(_ count: Int) -> [Period] {
        let lastSettled = today.advanced(by: -1)
        var year = lastSettled.year, month = lastSettled.month
        var starts: [DayKey] = []
        for _ in 0..<count {
            starts.append(DayKey(year: year, month: month, day: 1))
            month -= 1
            if month == 0 { month = 12; year -= 1 }
        }
        return starts.reversed().map { start in
            let next = start.month == 12
                ? DayKey(year: start.year + 1, month: 1, day: 1)
                : DayKey(year: start.year, month: start.month + 1, day: 1)
            return period(from: start, through: next.advanced(by: -1))
        }
    }

    private func period(from start: DayKey, through end: DayKey) -> Period {
        var completed = 0, scheduled = 0
        for occurrence in history.settledOccurrences where occurrence.day >= start && occurrence.day <= end {
            scheduled += 1
            if occurrence.isCompleted { completed += 1 }
        }
        return Period(start: start, completed: completed, scheduled: scheduled)
    }

    /// The Monday on or before `day`.
    static func monday(of day: DayKey) -> DayKey {
        // Weekday runs Sunday = 1 through Saturday = 7, so Monday is 2 and Sunday goes back 6.
        let offset = (day.weekday.rawValue + 5) % 7
        return day.advanced(by: -offset)
    }
}
