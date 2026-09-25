import Foundation
import Testing
@testable import HabitKit

@Suite("Reminder plan")
struct ReminderPlanTests {

    func history(
        routine: RoutineSlot = .morning,
        schedule: Schedule = .daily,
        completedToday: Bool = false,
        paused: Bool = false,
        startedOn: DayKey = referenceToday.advanced(by: -5)
    ) -> HabitHistory {
        let habit = Habit(title: "h", routine: routine, order: 0, schedule: schedule, startedOn: startedOn)
        let events = completedToday
            ? [CompletionEvent(habitID: habit.id, dayKey: referenceToday, occurredAt: .distantPast, timeZoneIdentifier: "UTC")]
            : []
        let lifecycle = paused
            ? [LifecycleEvent(habitID: habit.id, dayKey: referenceToday.advanced(by: -1), state: .paused,
                              occurredAt: .distantPast, timeZoneIdentifier: "UTC")]
            : []
        return HabitHistory(habit: habit, events: events, lifecycle: lifecycle, today: referenceToday)
    }

    @Test("A daily routine is reminded every day of the horizon, today included")
    func daily() {
        let days = ReminderPlan.days(for: .morning, histories: [history()], finishedToday: false)
        #expect(days.count == ReminderPlan.horizonDays)
        #expect(days.first == referenceToday)
        #expect(days.last == referenceToday.advanced(by: ReminderPlan.horizonDays - 1))
    }

    @Test("Rest days get no reminder")
    func restDays() {
        // referenceToday is a Monday.
        let days = ReminderPlan.days(for: .morning,
                                     histories: [history(schedule: .daysOfWeek([.wednesday]))],
                                     finishedToday: false)
        #expect(days == [referenceToday.advanced(by: 2), referenceToday.advanced(by: 9)])
    }

    @Test("Days are the union across the routine's habits")
    func union() {
        let days = ReminderPlan.days(
            for: .morning,
            histories: [history(schedule: .daysOfWeek([.monday])), history(schedule: .daysOfWeek([.tuesday]))],
            finishedToday: false, horizonDays: 7
        )
        #expect(days == [referenceToday, referenceToday.advanced(by: 1)])
    }

    @Test("Today drops out once everything is done or the run has finished")
    func todayDropsOut() {
        let done = ReminderPlan.days(for: .morning, histories: [history(completedToday: true)],
                                     finishedToday: false)
        #expect(done.first == referenceToday.advanced(by: 1))

        let finished = ReminderPlan.days(for: .morning, histories: [history()], finishedToday: true)
        #expect(finished.first == referenceToday.advanced(by: 1))
    }

    @Test("A routine whose only habit is paused, or belongs elsewhere, is never reminded")
    func pausedAndOtherRoutine() {
        #expect(ReminderPlan.days(for: .morning, histories: [history(paused: true)], finishedToday: false).isEmpty)
        #expect(ReminderPlan.days(for: .morning, histories: [history(routine: .evening)], finishedToday: false).isEmpty)
    }

    @Test("A habit starting in the future is reminded from its first day, not before")
    func futureStart() {
        let start = referenceToday.advanced(by: 3)
        let days = ReminderPlan.days(for: .morning, histories: [history(startedOn: start)],
                                     finishedToday: false, horizonDays: 6)
        #expect(days == [start, start.advanced(by: 1), start.advanced(by: 2)])
    }
}
