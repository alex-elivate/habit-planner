import Foundation

/// A civil calendar day, stored as its `yyyyMMdd` integer. September 21 2026 is `20260921`.
///
/// A `DayKey` is resolved once, in the user's time zone, at the moment something happens,
/// and then stored. Never re-derive "today" from a raw `Date` at read time: a user who flies
/// east would silently gain or lose a day of streak, which in turn misfires the lock-in gate.
///
/// Arithmetic on a `DayKey` is deliberately time-zone free. Once a day has been named, "the
/// day after" is a question about the calendar, not about where anyone is standing. It is
/// also pure integer math, because folding a year of history per habit on every refresh is
/// far too hot a path for `Calendar`.
public struct DayKey: Hashable, Comparable, Sendable {
    public let rawValue: Int

    /// Trusts the caller. Use `init?(validating:)` for anything crossing a storage
    /// or network boundary.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Rejects anything that is not a real calendar date.
    ///
    /// This matters more than it looks. `DayKey(rawValue: 0)` is the natural value of a
    /// missing or zeroed CloudKit `Int64`, and its ordinal is -719560. Folding history for
    /// a habit that started then builds a 740,000 element array, on a code path that runs
    /// inside a widget extension under a tight memory budget.
    public init?(validating rawValue: Int) {
        self.init(rawValue: rawValue)
        guard isValid else { return nil }
    }

    /// Whether this names a day that actually exists.
    public var isValid: Bool {
        guard year >= 1, (1...12).contains(month), day >= 1 else { return false }
        return day <= Self.daysInMonth(month: month, year: year)
    }

    static func daysInMonth(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public init(year: Int, month: Int, day: Int) {
        self.rawValue = year * 10_000 + month * 100 + day
    }

    /// Resolves the civil day that `date` fell on, as seen from `timeZone`.
    ///
    /// This is the only place a `Date` is allowed to become a day.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    public var year: Int { rawValue / 10_000 }
    public var month: Int { (rawValue / 100) % 100 }
    public var day: Int { rawValue % 100 }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Arithmetic

extension DayKey {
    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    ///
    /// The conversions below are Howard Hinnant's `days_from_civil` and `civil_from_days`,
    /// which are exact for any year and involve nothing but integer division. Swift's `/`
    /// truncates toward zero, which is what the era arithmetic assumes.
    public var ordinal: Int {
        var y = year
        let m = month
        let d = day
        if m <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(ordinal: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        self.init(year: m <= 2 ? y + 1 : y, month: m, day: d)
    }

    /// The day `days` after this one. Negative values move backward.
    public func advanced(by days: Int) -> DayKey {
        DayKey(ordinal: ordinal + days)
    }

    /// The number of days from this day to `other`. Negative when `other` is earlier.
    public func days(until other: DayKey) -> Int {
        other.ordinal - ordinal
    }

    public var weekday: Weekday {
        // 1970-01-01 was a Thursday. Shift so the result is 0 = Sunday, then match
        // Calendar's 1-based numbering.
        let z = ordinal
        let index = z >= -4 ? (z + 4) % 7 : (z + 5) % 7 + 6
        return Weekday(rawValue: index + 1)!
    }

    /// Every day from this one through `end`, inclusive. Empty when `end` is earlier.
    public func through(_ end: DayKey) -> [DayKey] {
        guard self <= end else { return [] }
        return (ordinal...end.ordinal).map(DayKey.init(ordinal:))
    }
}

extension DayKey: CustomStringConvertible {
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - Codable

extension DayKey: Codable {
    /// Encodes as a bare integer. The synthesized form would be `{"rawValue": 20260921}`,
    /// and in CloudKit this needs to be a plain `Int64` field. Worth six lines now, a
    /// schema migration later.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let value = DayKey(validating: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "\(raw) is not a valid yyyyMMdd day")
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
