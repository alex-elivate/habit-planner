import Foundation
import Testing
@testable import HabitKit

@Suite("Habit report")
struct HabitReportTests {

    // `referenceToday` is Monday 21 September 2026.

    @Test("Each kind of day gets its own mark")
    func marks() {
        let habit = Habit(title: "Walk", routine: .morning, order: 0,
                          schedule: .daysOfWeek([.monday, .wednesday, .friday]),
                          startedOn: DayKey(year: 2026, month: 9, day: 7))  // a Monday
        let events = [DayKey(year: 2026, month: 9, day: 7), DayKey(year: 2026, month: 9, day: 11)].map {
            CompletionEvent(habitID: habit.id, dayKey: $0, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        }
        let pause = LifecycleEvent(habitID: habit.id, dayKey: DayKey(year: 2026, month: 9, day: 14),
                                   state: .paused, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        let resume = LifecycleEvent(habitID: habit.id, dayKey: DayKey(year: 2026, month: 9, day: 18),
                                    state: .active, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        let report = HabitReport(HabitHistory(habit: habit, events: events, lifecycle: [pause, resume],
                                              today: referenceToday))
        let day = { (d: Int) in DayKey(year: 2026, month: 9, day: d) }

        #expect(report.mark(on: day(6)) == .beforeStart)
        #expect(report.mark(on: day(7)) == .done)
        #expect(report.mark(on: day(8)) == .rest)
        #expect(report.mark(on: day(9)) == .missed)
        #expect(report.mark(on: day(11)) == .done)
        #expect(report.mark(on: day(14)) == .paused)
        #expect(report.mark(on: day(15)) == .rest, "Off the schedule reads as rest even while paused")
        #expect(report.mark(on: day(16)) == .paused)
        #expect(report.mark(on: day(18)) == .missed, "Resumed that day, so it counts")
        #expect(report.mark(on: referenceToday) == .pending, "Today is never a miss")
        #expect(report.mark(on: referenceToday.advanced(by: 1)) == .future)
    }

    @Test("Archived days read as archived, and today can read as done")
    func archivedAndDoneToday() {
        let done = makeHistory("CCC", completedToday: true)
        #expect(HabitReport(done).mark(on: referenceToday) == .done)

        let archived = makeHistory("CCCMM", state: .archived, stateChangedOn: referenceToday.advanced(by: -2))
        let report = HabitReport(archived)
        #expect(report.mark(on: referenceToday.advanced(by: -3)) == .done)
        #expect(report.mark(on: referenceToday.advanced(by: -2)) == .archived)
        #expect(report.mark(on: referenceToday) == .archived)
    }

    @Test("Done and missed marks are exactly the occurrences the gate judges")
    func marksAgreeWithSettledOccurrences() {
        // Any disagreement would let the calendar show a streak or a rate the gate does not see.
        for seed in 0..<50 {
            let marks = (0..<60).map { ($0 * 7 + seed * 13) % 5 == 0 ? "M" : "C" }.joined()
            let history = makeHistory(marks, state: seed % 3 == 0 ? .paused : .active,
                                      stateChangedOn: referenceToday.advanced(by: -10))
            let report = HabitReport(history)
            let counted = history.habit.startedOn.through(referenceToday.advanced(by: -1)).filter {
                [.done, .missed].contains(report.mark(on: $0))
            }
            #expect(counted == history.settledOccurrences.map(\.day))
            #expect(counted.filter { report.mark(on: $0) == .done }.count
                    == history.settledOccurrences.filter(\.isCompleted).count)
        }
    }

    @Test("Weeks run Monday to Sunday, end with yesterday's week, and leave today out")
    func weeks() {
        // Done every day for three weeks except yesterday, Sunday the 20th.
        let history = makeHistory(pattern(length: 21, missesAt: [20]), completedToday: true)
        let weeks = HabitReport(history).weeks(3)
        #expect(weeks.map(\.start) == [DayKey(year: 2026, month: 8, day: 31),
                                      DayKey(year: 2026, month: 9, day: 7),
                                      DayKey(year: 2026, month: 9, day: 14)])
        #expect(weeks.map(\.scheduled) == [7, 7, 7])
        #expect(weeks.last?.completed == 6)
        #expect(weeks.reduce(0) { $0 + $1.completed } == history.settledOccurrences.filter(\.isCompleted).count)
    }

    @Test("Months run 1st to last, and a month with nothing scheduled has no rate")
    func months() {
        let history = makeHistory(pattern(length: 30, missesAt: [0]))  // from 22 August
        let months = HabitReport(history).months(3)
        #expect(months.map(\.start) == [DayKey(year: 2026, month: 7, day: 1),
                                       DayKey(year: 2026, month: 8, day: 1),
                                       DayKey(year: 2026, month: 9, day: 1)])
        #expect(months[0].rate == nil)
        #expect(months[1].scheduled == 10 && months[1].completed == 9)
        #expect(months[2].scheduled == 20 && months[2].completed == 20)
    }

    @Test("A month lists every day in order, February in a leap year included")
    func monthDays() {
        let report = HabitReport(makeHistory("C"))
        #expect(report.month(year: 2028, month: 2).count == 29)
        #expect(report.month(year: 2026, month: 12).last?.day == DayKey(year: 2026, month: 12, day: 31))
    }

    @Test("Monday of a day matches Foundation across four years")
    func mondayMatchesCalendar() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for offset in 0..<(4 * 366) {
            let day = DayKey(year: 2025, month: 1, day: 1).advanced(by: offset)
            let date = Date(timeIntervalSince1970: TimeInterval(day.ordinal) * 86_400)
            let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            #expect(HabitReport.monday(of: day) == DayKey(start, in: calendar.timeZone))
        }
    }
}
