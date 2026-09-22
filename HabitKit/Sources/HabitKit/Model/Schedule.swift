import Foundation

/// When a habit is due.
///
/// Every case must answer "was this due on day X" deterministically, because the lock-in
/// gate counts scheduled occurrences rather than calendar days. That is what lets a
/// three-times-a-week habit be judged on the same terms as a daily one.
///
/// A "times per week" case is deliberately absent: it cannot say which days were due,
/// so there is no honest denominator to score against.
public enum Schedule: Hashable, Codable, Sendable {
    case daily
    case daysOfWeek(Set<Weekday>)

    public func isScheduled(on day: DayKey) -> Bool {
        switch self {
        case .daily:
            return true
        case .daysOfWeek(let days):
            return days.contains(day.weekday)
        }
    }
}

/// Which routine a habit belongs to.
public enum RoutineSlot: String, Hashable, Codable, Sendable, CaseIterable {
    case morning
    case evening
}
