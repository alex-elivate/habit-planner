import Foundation
import Testing
@testable import HabitKit

@Suite("Schedule")
struct ScheduleTests {

    @Test("A daily habit is due every day")
    func daily() {
        let start = DayKey(year: 2026, month: 9, day: 21)
        for offset in 0..<14 {
            #expect(Schedule.daily.isScheduled(on: start.advanced(by: offset)))
        }
    }

    @Test("A weekly habit is due only on its chosen days")
    func daysOfWeek() {
        let schedule = Schedule.daysOfWeek([.monday, .wednesday, .friday])
        let monday = DayKey(year: 2026, month: 9, day: 21)

        #expect(schedule.isScheduled(on: monday))
        #expect(!schedule.isScheduled(on: monday.advanced(by: 1)))  // Tuesday
        #expect(schedule.isScheduled(on: monday.advanced(by: 2)))   // Wednesday
        #expect(!schedule.isScheduled(on: monday.advanced(by: 3)))  // Thursday
        #expect(schedule.isScheduled(on: monday.advanced(by: 4)))   // Friday
        #expect(!schedule.isScheduled(on: monday.advanced(by: 5)))  // Saturday
        #expect(!schedule.isScheduled(on: monday.advanced(by: 6)))  // Sunday
    }

    @Test("History starts at the start date, not before")
    func startDate() {
        let start = DayKey(year: 2026, month: 9, day: 21)
        let habit = Habit(title: "Walk", routine: .morning, order: 0, startedOn: start)

        #expect(!habit.isScheduled(on: start.advanced(by: -1)))
        #expect(habit.isScheduled(on: start))
        #expect(habit.isScheduled(on: start.advanced(by: 10)))
    }

    @Test("The same set of days always encodes to the same bytes")
    func encodingIsStable() throws {
        // Set has no stable iteration order, so the synthesized Codable emitted a different
        // blob almost every call. That manufactured CloudKit sync churn on records that had
        // not changed.
        let schedule = Schedule.daysOfWeek([.monday, .wednesday, .friday, .saturday])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        var encodings = Set<String>()
        for _ in 0..<200 {
            encodings.insert(String(decoding: try encoder.encode(schedule), as: UTF8.self))
        }
        #expect(encodings.count == 1, "expected one encoding, got \(encodings.count): \(encodings)")
    }

    @Test("Schedules round-trip through Codable")
    func codableRoundTrip() throws {
        let cases: [Schedule] = [
            .daily,
            .daysOfWeek([]),
            .daysOfWeek([.sunday]),
            .daysOfWeek([.monday, .wednesday, .friday]),
            .daysOfWeek(Set(Weekday.allCases))
        ]
        for schedule in cases {
            let data = try JSONEncoder().encode(schedule)
            let decoded = try JSONDecoder().decode(Schedule.self, from: data)
            #expect(decoded == schedule)
        }
    }
}
