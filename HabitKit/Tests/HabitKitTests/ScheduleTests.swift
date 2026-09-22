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

        #expect(!habit.wasScheduled(on: start.advanced(by: -1)))
        #expect(habit.wasScheduled(on: start))
        #expect(habit.wasScheduled(on: start.advanced(by: 10)))
    }

    @Test("Pausing stops the clock rather than accruing misses")
    func pausing() {
        let start = DayKey(year: 2026, month: 9, day: 1)
        let paused = DayKey(year: 2026, month: 9, day: 10)
        var habit = Habit(title: "Walk", routine: .morning, order: 0, startedOn: start)
        habit.lifecycle = .paused
        habit.pausedOn = paused

        #expect(habit.wasScheduled(on: paused.advanced(by: -1)))
        #expect(!habit.wasScheduled(on: paused))
        #expect(!habit.wasScheduled(on: paused.advanced(by: 30)))
    }

    @Test("An archived habit keeps its history but is never due")
    func archived() {
        let start = DayKey(year: 2026, month: 9, day: 1)
        var habit = Habit(title: "Walk", routine: .morning, order: 0, startedOn: start)
        habit.lifecycle = .archived

        #expect(habit.wasScheduled(on: start.advanced(by: 3)))
        #expect(!habit.isDue(on: start.advanced(by: 3)))
    }
}
