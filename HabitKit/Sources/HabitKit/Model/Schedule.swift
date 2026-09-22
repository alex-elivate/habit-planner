import Foundation

/// When a habit is due.
///
/// Every case must answer "was this due on day X" deterministically, because the lock-in
/// gate counts scheduled occurrences rather than calendar days. That is what lets a
/// three-times-a-week habit be judged on the same terms as a daily one.
///
/// A "times per week" case is deliberately absent: it cannot say which days were due,
/// so there is no honest denominator to score against.
public enum Schedule: Hashable, Sendable {
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

// MARK: - Codable

extension Schedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, days
    }

    private enum Kind: String, Codable {
        case daily, daysOfWeek
    }

    /// Days encode as a seven-bit mask rather than as a `Set`.
    ///
    /// `Set` has no stable iteration order, so the synthesized `Codable` emitted a different
    /// blob almost every call. Any change detection over the encoded habit then saw a
    /// modification on every save, manufacturing CloudKit sync churn and last-writer-wins
    /// conflicts on records that had not changed. The synthesized form also froze the
    /// compiler's `"_0"` key into what will become a production schema.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .daily:
            self = .daily
        case .daysOfWeek:
            let mask = try container.decode(Int.self, forKey: .days)
            let days = Weekday.allCases.filter { mask & (1 << ($0.rawValue - 1)) != 0 }
            self = .daysOfWeek(Set(days))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily:
            try container.encode(Kind.daily, forKey: .kind)
        case .daysOfWeek(let days):
            try container.encode(Kind.daysOfWeek, forKey: .kind)
            let mask = days.reduce(0) { $0 | (1 << ($1.rawValue - 1)) }
            try container.encode(mask, forKey: .days)
        }
    }
}

/// Which routine a habit belongs to.
public enum RoutineSlot: String, Hashable, Codable, Sendable, CaseIterable {
    case morning
    case evening
}
