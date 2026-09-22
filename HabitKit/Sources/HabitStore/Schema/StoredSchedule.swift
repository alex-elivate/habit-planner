import Foundation
import HabitKit

/// Flattens `Schedule` into the two primitive columns the store keeps, and back.
///
/// The strings and the bit layout here are frozen the moment the CloudKit schema is promoted,
/// so they are spelled out in one place rather than inlined at the call sites. `ScheduleTests`
/// pins them against the domain's own `Codable` output, so the two cannot drift apart
/// silently after this file stops being read.
public enum StoredSchedule {

    public enum Kind: String, CaseIterable, Sendable {
        case daily
        case daysOfWeek
    }

    /// Weekday `n` occupies bit `n - 1`, matching `Weekday`'s `Calendar`-aligned numbering.
    /// Sunday is bit 0 through Saturday at bit 6.
    public static func mask(for days: Set<Weekday>) -> Int {
        days.reduce(0) { $0 | (1 << ($1.rawValue - 1)) }
    }

    public static func days(from mask: Int) -> Set<Weekday> {
        Set(Weekday.allCases.filter { mask & (1 << ($0.rawValue - 1)) != 0 })
    }

    /// Every bit that means something. Anything outside this is a record from a future
    /// version that knows about a day we do not, which is worth noticing rather than
    /// quietly dropping.
    public static let validMask = (1 << Weekday.allCases.count) - 1

    public static func flatten(_ schedule: Schedule) -> (kind: Kind, mask: Int) {
        switch schedule {
        case .daily:
            return (.daily, 0)
        case .daysOfWeek(let days):
            return (.daysOfWeek, mask(for: days))
        }
    }
}
