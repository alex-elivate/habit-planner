import Foundation
import Testing
@testable import HabitKit

@Suite("DayKey")
struct DayKeyTests {

    @Test("Components round-trip through the raw yyyyMMdd form")
    func componentsRoundTrip() {
        let day = DayKey(year: 2026, month: 9, day: 21)
        #expect(day.rawValue == 20260921)
        #expect(day.year == 2026)
        #expect(day.month == 9)
        #expect(day.day == 21)
    }

    @Test("Ordinal is anchored to the Unix epoch")
    func ordinalAnchor() {
        #expect(DayKey(year: 1970, month: 1, day: 1).ordinal == 0)
        #expect(DayKey(year: 1970, month: 1, day: 2).ordinal == 1)
        #expect(DayKey(year: 1969, month: 12, day: 31).ordinal == -1)
        #expect(DayKey(year: 2000, month: 1, day: 1).ordinal == 10_957)
    }

    @Test("Ordinal round-trips in both directions")
    func ordinalRoundTrip() {
        for offset in stride(from: -40_000, through: 40_000, by: 97) {
            let day = DayKey(ordinal: offset)
            #expect(day.ordinal == offset, "round trip failed at \(offset) -> \(day)")
        }
    }

    @Test("Day arithmetic crosses month, year, and leap boundaries")
    func boundaries() {
        // Leap year: 2024 has a 29th, 2026 does not.
        #expect(DayKey(year: 2024, month: 2, day: 28).advanced(by: 1) == DayKey(year: 2024, month: 2, day: 29))
        #expect(DayKey(year: 2026, month: 2, day: 28).advanced(by: 1) == DayKey(year: 2026, month: 3, day: 1))
        // Century rule: 1900 was not a leap year, 2000 was.
        #expect(DayKey(year: 1900, month: 2, day: 28).advanced(by: 1) == DayKey(year: 1900, month: 3, day: 1))
        #expect(DayKey(year: 2000, month: 2, day: 28).advanced(by: 1) == DayKey(year: 2000, month: 2, day: 29))
        // Year rollover, forward and back.
        #expect(DayKey(year: 2026, month: 12, day: 31).advanced(by: 1) == DayKey(year: 2027, month: 1, day: 1))
        #expect(DayKey(year: 2027, month: 1, day: 1).advanced(by: -1) == DayKey(year: 2026, month: 12, day: 31))
    }

    @Test("Distance between days is signed")
    func distance() {
        let start = DayKey(year: 2026, month: 9, day: 21)
        #expect(start.days(until: start.advanced(by: 30)) == 30)
        #expect(start.days(until: start.advanced(by: -30)) == -30)
        #expect(start.days(until: start) == 0)
    }

    @Test("Hand-rolled arithmetic agrees with Foundation across four years")
    func agreesWithFoundation() {
        // The civil-date math is hand-written for speed, so it is worth proving against
        // the system calendar rather than trusting the algorithm on sight.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 1
        components.hour = 12
        var cursor = calendar.date(from: components)!

        var day = DayKey(year: 2024, month: 1, day: 1)

        for step in 0..<(365 * 4) {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: cursor)
            #expect(day.year == parts.year, "year drift at step \(step)")
            #expect(day.month == parts.month, "month drift at step \(step)")
            #expect(day.day == parts.day, "day drift at step \(step)")
            #expect(day.weekday.rawValue == parts.weekday, "weekday drift at \(day)")

            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            day = day.advanced(by: 1)
        }
    }

    @Test("A range includes both ends, and inverts to empty")
    func ranges() {
        let start = DayKey(year: 2026, month: 9, day: 21)
        let end = start.advanced(by: 4)
        #expect(start.through(end).count == 5)
        #expect(start.through(end).first == start)
        #expect(start.through(end).last == end)
        #expect(start.through(start) == [start])
        #expect(end.through(start).isEmpty)
    }

    @Test("The same instant is a different day depending on where you stand")
    func timeZoneResolution() throws {
        // 06:30 UTC. Late evening the previous day in Phoenix, mid-afternoon in Tokyo.
        // This is the flying-east case that makes storing the resolved day non-negotiable.
        let instant = Date(timeIntervalSince1970: 1_789_972_200)
        let phoenix = try #require(TimeZone(identifier: "America/Phoenix"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))

        #expect(DayKey(instant, in: phoenix) == DayKey(year: 2026, month: 9, day: 20))
        #expect(DayKey(instant, in: tokyo) == DayKey(year: 2026, month: 9, day: 21))
    }

    @Test("Daylight saving transitions do not skip or repeat a day")
    func daylightSaving() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork

        // US DST begins March 8 2026: 02:00 local never happens.
        let springForward = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3))!
        #expect(DayKey(springForward, in: newYork) == DayKey(year: 2026, month: 3, day: 8))
        #expect(DayKey(year: 2026, month: 3, day: 7).advanced(by: 1) == DayKey(year: 2026, month: 3, day: 8))

        // And ends November 1 2026, where 01:30 local happens twice.
        let fallBack = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 3))!
        #expect(DayKey(fallBack, in: newYork) == DayKey(year: 2026, month: 11, day: 1))
        #expect(DayKey(year: 2026, month: 10, day: 31).advanced(by: 1) == DayKey(year: 2026, month: 11, day: 1))
    }
}
