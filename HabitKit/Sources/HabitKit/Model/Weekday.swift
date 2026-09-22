import Foundation

/// A day of the week, numbered to match `Calendar`'s `.weekday` component:
/// Sunday is 1 through Saturday at 7.
public enum Weekday: Int, Hashable, Codable, Sendable, CaseIterable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
}
