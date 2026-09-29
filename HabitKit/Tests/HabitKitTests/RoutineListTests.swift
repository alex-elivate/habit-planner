import Foundation
import Testing
@testable import HabitKit

/// The list does what the runner did, one row at a time: any habit can be done or skipped from
/// where it sits, and the next habit is the one the widget and Siri would tick.
@Suite("Routine list")
struct RoutineListTests {

    let utc = TimeZone(identifier: "UTC")!
    let morning = Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400 + 7 * 3_600)

    func habit(_ title: String, order: Int, schedule: Schedule = .daily) -> Habit {
        Habit(title: title, routine: .morning, order: order, schedule: schedule,
              startedOn: referenceToday.advanced(by: -10))
    }

    func fold(_ habits: [Habit], done: Set<UUID> = []) -> [HabitHistory] {
        habits.map { habit in
            let events = done.contains(habit.id)
                ? [CompletionEvent(habitID: habit.id, dayKey: referenceToday, occurredAt: morning, timeZoneIdentifier: "UTC")]
                : []
            return HabitHistory(habit: habit, events: events, lifecycle: [], today: referenceToday)
        }
    }

    @Test("Doing a later habit first leaves the next one on offer")
    func outOfOrderComplete() throws {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1), c = habit("Journal", order: 2)
        var runner = RoutineRunner(routine: .morning, histories: fold([a, b, c]), at: morning, in: utc)

        let done = runner.complete(c.id, at: morning.addingTimeInterval(60))
        let event = try #require(done)
        #expect(event.habitID == c.id)
        #expect(event.dayKey == referenceToday)
        #expect(runner.currentHabitID == a.id)
        #expect(runner.remaining == [a.id, b.id])

        // It still leaves a step, so the run records the whole morning.
        let step = try #require(runner.run.steps.first { $0.habitID == c.id })
        #expect(step.endedAt == morning.addingTimeInterval(60))
        #expect(step.duration == 0)
    }

    @Test("A habit already passed cannot be passed again")
    func passOnce() {
        let a = habit("Water", order: 0)
        var runner = RoutineRunner(routine: .morning, histories: fold([a]), at: morning, in: utc)
        let first = runner.complete(a.id, at: morning)
        let second = runner.complete(a.id, at: morning)
        #expect(first != nil)
        #expect(second == nil)
        #expect(runner.isFinished)
        #expect(runner.run.endedAt == morning)
    }

    @Test("Skipping the next habit moves next on")
    func skipNext() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: fold([a, b]), at: morning, in: utc)
        runner.skip(a.id, at: morning)
        #expect(runner.currentHabitID == b.id)
        // Presented as it came up, as the runner screen did.
        #expect(runner.run.steps.first { $0.habitID == b.id }?.startedAt == morning)
    }

    @Test("States: done, skipped, next, waiting, and not due")
    func states() {
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        let journal = habit("Journal", order: 2), walk = habit("Walk", order: 3)
        // Not due on the reference day's weekday.
        let restDay = Weekday.allCases.first { !Schedule.daysOfWeek([$0]).isScheduled(on: referenceToday) }!
        let rest = habit("Rest", order: 4, schedule: .daysOfWeek([restDay]))
        let habits = [water, stretch, journal, walk, rest]

        var runner = RoutineRunner(routine: .morning, histories: fold(habits), at: morning, in: utc)
        _ = runner.complete(water.id, at: morning)
        runner.skip(stretch.id, at: morning)

        let states = RoutineRunner.states(of: .morning, histories: fold(habits, done: [water.id]),
                                          run: runner.run, at: morning, in: utc)
        #expect(states[water.id] == .done)
        #expect(states[stretch.id] == .skipped)
        #expect(states[journal.id] == .next)
        #expect(states[walk.id] == .waiting)
        #expect(states[rest.id] == .notDue)
    }

    @Test("A skipped habit can still be done, and cannot be skipped twice")
    func skippedAffordances() {
        #expect(StepState.skipped.canComplete)
        #expect(!StepState.skipped.canSkip)
        #expect(!StepState.done.canComplete)
        #expect(!StepState.notDue.canComplete)
        #expect(StepState.waiting.canSkip)
    }

    @Test("Reopening a skipped step offers the habit again, in its place")
    func reopen() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: fold([a, b]), at: morning, in: utc)
        runner.skip(a.id, at: morning)
        runner.skip(b.id, at: morning)
        var run = runner.run
        #expect(run.endedAt != nil)

        let reopened = run.reopen(a.id, at: morning.addingTimeInterval(10))
        let again0 = run.reopen(a.id, at: morning.addingTimeInterval(10))
        #expect(reopened)
        #expect(!again0, "Already open")
        #expect(run.endedAt == nil)
        let again = RoutineRunner(routine: .morning, histories: fold([a, b]), resuming: run, at: morning, in: utc)
        #expect(again.currentHabitID == a.id)
        #expect(again.remaining == [a.id])
    }

    @Test("Undo in the runner still steps back through passes made out of order")
    func undoAfterOutOfOrder() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: fold([a, b]), at: morning, in: utc)
        _ = runner.complete(b.id, at: morning)
        let retraction = runner.undo(at: morning)
        #expect(retraction?.habitID == b.id)
        #expect(runner.remaining.first == b.id)
    }

    @Test("A reopen and a pass settle the same way in any merge order")
    func reopenMerges() {
        let id = UUID()
        let skipped = RoutineStep(habitID: id, position: 0, startedAt: morning, endedAt: morning.addingTimeInterval(10))
        var reopened = skipped
        reopened.reopen(at: morning.addingTimeInterval(20))
        var passedAgain = reopened
        passedAgain.pass(at: morning.addingTimeInterval(30))

        #expect(skipped.isPassed)
        #expect(!reopened.isPassed)
        #expect(passedAgain.isPassed)
        #expect(!skipped.merged(with: reopened).isPassed)
        #expect(!reopened.merged(with: skipped).isPassed)
        #expect(skipped.merged(with: reopened).merged(with: passedAgain).isPassed)
        #expect(passedAgain.merged(with: skipped).merged(with: reopened).isPassed)
        #expect(reopened.merged(with: reopened) == reopened)
    }

    @Test("A clock behind the other device still reopens, and passes again after")
    func clockSkew() {
        var step = RoutineStep(habitID: UUID(), position: 0, startedAt: morning, endedAt: morning.addingTimeInterval(100))
        step.reopen(at: morning)
        #expect(!step.isPassed)
        step.pass(at: morning)
        #expect(step.isPassed)
    }

    @Test("Just after midnight, before a reload, the list still reads yesterday's fold")
    func pastMidnight() {
        let a = habit("Water", order: 0)
        // Folded for the reference day, asked about two hours into the next.
        let tomorrow = morning.addingTimeInterval(19 * 3_600)
        #expect(DayKey(tomorrow, in: utc) != referenceToday)
        let states = RoutineRunner.states(of: .morning, histories: fold([a]), run: nil, at: tomorrow, in: utc)
        #expect(states[a.id] == .next)
    }
}
