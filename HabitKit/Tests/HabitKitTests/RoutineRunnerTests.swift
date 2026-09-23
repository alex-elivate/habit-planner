import Foundation
import Testing
@testable import HabitKit

@Suite("Routine runner")
struct RoutineRunnerTests {

    let utc = TimeZone(identifier: "UTC")!
    /// 07:00 UTC on `referenceToday`.
    let morning = Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400 + 7 * 3_600)

    init() {
        #expect(DayKey(morning, in: utc) == referenceToday)
    }

    func habit(
        _ title: String,
        order: Int,
        routine: RoutineSlot = .morning,
        schedule: Schedule = .daily,
        id: UUID = UUID()
    ) -> Habit {
        Habit(id: id, title: title, routine: routine, order: order, schedule: schedule,
              startedOn: referenceToday.advanced(by: -10))
    }

    func histories(
        _ habits: [Habit],
        completedToday: Set<UUID> = [],
        paused: Set<UUID> = [],
        today: DayKey = referenceToday
    ) -> [HabitHistory] {
        habits.map { habit in
            let events = completedToday.contains(habit.id)
                ? [CompletionEvent(habitID: habit.id, dayKey: today, occurredAt: morning, timeZoneIdentifier: "UTC")]
                : []
            let lifecycle = paused.contains(habit.id)
                ? [LifecycleEvent(habitID: habit.id, dayKey: today.advanced(by: -1), state: .paused,
                                  occurredAt: morning, timeZoneIdentifier: "UTC")]
                : []
            return HabitHistory(habit: habit, events: events, lifecycle: lifecycle, today: today)
        }
    }

    // MARK: - What gets offered

    @Test("Offers habits in sequence order, not in the order the store returned them")
    func sequenceOrder() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1), c = habit("Journal", order: 2)
        // Reversed input, which is what an unordered fetch can hand over.
        let runner = RoutineRunner(routine: .morning, histories: histories([c, b, a]), at: morning, in: utc)
        #expect(runner.remaining == [a.id, b.id, c.id])
        #expect(runner.currentHabitID == a.id)
    }

    @Test("Two habits sharing a position come out the same way whatever order they arrive in")
    func tiedOrderIsDeterministic() {
        let low = habit("Low", order: 3, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = habit("High", order: 3, id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!)
        let forward = RoutineRunner(routine: .morning, histories: histories([low, high]), at: morning, in: utc)
        let reversed = RoutineRunner(routine: .morning, histories: histories([high, low]), at: morning, in: utc)
        #expect(forward.remaining == [low.id, high.id])
        #expect(reversed.remaining == forward.remaining)
    }

    @Test("Skips what is not due: other routine, rest day, paused, already done")
    func onlyWhatIsDue() {
        let due = habit("Due", order: 0)
        let evening = habit("Evening", order: 1, routine: .evening)
        // referenceToday is a Monday.
        let restDay = habit("Tuesdays", order: 2, schedule: .daysOfWeek([.tuesday]))
        let paused = habit("Paused", order: 3)
        let done = habit("Done", order: 4)

        let runner = RoutineRunner(
            routine: .morning,
            histories: histories([due, evening, restDay, paused, done],
                                 completedToday: [done.id], paused: [paused.id]),
            at: morning, in: utc
        )
        #expect(runner.remaining == [due.id])
    }

    @Test("Nothing due means no steps and a finished runner")
    func nothingDue() {
        let done = habit("Done", order: 0)
        let runner = RoutineRunner(routine: .morning, histories: histories([done], completedToday: [done.id]),
                                   at: morning, in: utc)
        #expect(runner.isFinished)
        #expect(runner.hasSteps == false)
        #expect(runner.run.steps.isEmpty)
    }

    // MARK: - Doing and skipping

    @Test("Completing records against the run's day, with the tap as both clocks")
    func completeRecordsEvent() throws {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: histories([a, b]), at: morning, in: utc)

        let tap = morning.addingTimeInterval(90)
        let eventResult = runner.complete(at: tap)
        let event = try #require(eventResult)
        #expect(event.habitID == a.id)
        #expect(event.dayKey == referenceToday)
        #expect(event.status == .completed)
        #expect(event.source == .manual)
        #expect(event.occurredAt == tap)
        #expect(event.recordedAt == tap)
        #expect(runner.currentHabitID == b.id)
    }

    @Test("A confirmed Health proposal keeps when it happened apart from when it was confirmed")
    func confirmedProposalKeepsBothClocks() throws {
        let walk = habit("Walk", order: 0)
        var runner = RoutineRunner(routine: .morning, histories: histories([walk]), at: morning, in: utc)

        let walkedAt = morning.addingTimeInterval(-3_600)
        let eventResult = runner.complete(at: morning, occurredAt: walkedAt, source: .automatic)
        let event = try #require(eventResult)
        #expect(event.occurredAt == walkedAt)
        #expect(event.recordedAt == morning)
        #expect(event.source == .automatic)
    }

    @Test("An evening run crossing midnight keeps completing the day it began")
    func crossesMidnight() throws {
        let read = habit("Read", order: 0, routine: .evening), teeth = habit("Teeth", order: 1, routine: .evening)
        let lateEvening = morning.addingTimeInterval(16 * 3_600 + 50 * 60)  // 23:50
        var runner = RoutineRunner(routine: .evening, histories: histories([read, teeth]), at: lateEvening, in: utc)

        _ = runner.complete(at: lateEvening.addingTimeInterval(60))
        let afterMidnight = lateEvening.addingTimeInterval(20 * 60)
        #expect(DayKey(afterMidnight, in: utc) == referenceToday.advanced(by: 1))

        let eventResult = runner.complete(at: afterMidnight)
        let event = try #require(eventResult)
        #expect(event.dayKey == referenceToday)
        #expect(runner.run.dayKey == referenceToday)
    }

    @Test("Skipping writes no completion, closes the step and moves on")
    func skipWritesNothing() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: histories([a, b]), at: morning, in: utc)

        let tap = morning.addingTimeInterval(30)
        runner.skip(at: tap)
        #expect(runner.currentHabitID == b.id)
        #expect(runner.passed.map(\.outcome) == [.skipped])
        let step = runner.run.steps.first { $0.habitID == a.id }
        #expect(step?.endedAt == tap)
    }

    @Test("Steps are timed from our own clock, and the run closes on the last one")
    func stepTiming() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: histories([a, b]), at: morning, in: utc)
        let t1 = morning.addingTimeInterval(60), t2 = morning.addingTimeInterval(200)

        _ = runner.complete(at: t1)
        runner.skip(at: t2)

        let steps = runner.run.orderedSteps
        #expect(steps.map(\.habitID) == [a.id, b.id])
        #expect(steps.map(\.position) == [0, 1])
        #expect(steps[0].startedAt == morning && steps[0].endedAt == t1)
        #expect(steps[1].startedAt == t1 && steps[1].endedAt == t2)
        #expect(runner.run.startedAt == morning)
        #expect(runner.run.endedAt == t2)
        #expect(runner.isFinished)
    }

    @Test("Steps not yet reached are not written")
    func unreachedStepsAbsent() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1), c = habit("Journal", order: 2)
        let runner = RoutineRunner(routine: .morning, histories: histories([a, b, c]), at: morning, in: utc)
        #expect(runner.run.steps.map(\.habitID) == [a.id])
    }

    @Test("Doing or skipping after the end changes nothing")
    func afterTheEnd() {
        let a = habit("Water", order: 0)
        var runner = RoutineRunner(routine: .morning, histories: histories([a]), at: morning, in: utc)
        _ = runner.complete(at: morning)
        let finished = runner.run

        let noResult = runner.complete(at: morning.addingTimeInterval(5))
        #expect(noResult == nil)
        runner.skip(at: morning.addingTimeInterval(10))
        #expect(runner.run == finished)
    }

    // MARK: - Undo

    @Test("Undoing a completion retracts it and puts the habit back on screen")
    func undoCompletion() throws {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: histories([a, b]), at: morning, in: utc)
        let doneResult = runner.complete(at: morning.addingTimeInterval(10))
        let done = try #require(doneResult)

        let undoAt = morning.addingTimeInterval(12)
        let retractionResult = runner.undo(at: undoAt)
        let retraction = try #require(retractionResult)
        #expect(retraction.id == done.id)
        #expect(retraction.status == .retracted)
        #expect(retraction.recordedAt == undoAt)
        // The pair has to resolve to not-done, which is the whole point of the retraction.
        #expect([done, retraction].completedDays(for: a.id).isEmpty)

        #expect(runner.currentHabitID == a.id)
        #expect(runner.remaining == [a.id, b.id])
        #expect(runner.run.steps.first { $0.habitID == a.id }?.endedAt == nil)
    }

    @Test("Undoing a skip writes nothing and reopens the step")
    func undoSkip() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1)
        var runner = RoutineRunner(routine: .morning, histories: histories([a, b]), at: morning, in: utc)
        runner.skip(at: morning.addingTimeInterval(10))

        let noResult = runner.undo(at: morning.addingTimeInterval(11))
        #expect(noResult == nil)
        #expect(runner.currentHabitID == a.id)
    }

    @Test("Undoing the last step reopens a finished run")
    func undoReopensRun() {
        let a = habit("Water", order: 0)
        var runner = RoutineRunner(routine: .morning, histories: histories([a]), at: morning, in: utc)
        _ = runner.complete(at: morning.addingTimeInterval(10))
        #expect(runner.run.endedAt != nil)

        _ = runner.undo(at: morning.addingTimeInterval(11))
        #expect(runner.isFinished == false)
        #expect(runner.run.endedAt == nil)
    }

    @Test("Undo walks back one step at a time, most recent first")
    func undoOrder() {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1), c = habit("Journal", order: 2)
        var runner = RoutineRunner(routine: .morning, histories: histories([a, b, c]), at: morning, in: utc)
        _ = runner.complete(at: morning)
        runner.skip(at: morning)

        _ = runner.undo(at: morning)
        #expect(runner.currentHabitID == b.id)
        _ = runner.undo(at: morning)
        #expect(runner.currentHabitID == a.id)
        let noResult = runner.undo(at: morning)
        #expect(noResult == nil)
        #expect(runner.remaining == [a.id, b.id, c.id])
    }

    // MARK: - Resuming

    @Test("Resuming skips what was already passed, done or skipped, and keeps the run's clock")
    func resume() throws {
        let a = habit("Water", order: 0), b = habit("Stretch", order: 1), c = habit("Journal", order: 2)
        var first = RoutineRunner(routine: .morning, histories: histories([a, b, c]), at: morning, in: utc)
        _ = first.complete(at: morning.addingTimeInterval(10))   // a done
        first.skip(at: morning.addingTimeInterval(20))           // b skipped, c now on screen
        let abandoned = first.run

        let later = morning.addingTimeInterval(3_600)
        let resumed = RoutineRunner(
            routine: .morning,
            histories: histories([a, b, c], completedToday: [a.id]),
            resuming: abandoned, at: later, in: utc
        )
        #expect(resumed.remaining == [c.id])
        #expect(resumed.run.startedAt == morning)
        // The step already on screen when the person left keeps its original presentation time.
        let step = try #require(resumed.run.steps.first { $0.habitID == c.id })
        #expect(step.startedAt == morning.addingTimeInterval(20))
        #expect(resumed.run.steps.count == 3)
    }

    @Test("A habit added after the run finished is appended after the existing steps")
    func resumeAppends() throws {
        let a = habit("Water", order: 5), late = habit("New", order: 0)
        var first = RoutineRunner(routine: .morning, histories: histories([a]), at: morning, in: utc)
        _ = first.complete(at: morning)
        #expect(first.run.endedAt != nil)

        let resumed = RoutineRunner(
            routine: .morning,
            histories: histories([a, late], completedToday: [a.id]),
            resuming: first.run, at: morning.addingTimeInterval(60), in: utc
        )
        #expect(resumed.currentHabitID == late.id)
        #expect(resumed.run.endedAt == nil)
        let step = try #require(resumed.run.steps.first { $0.habitID == late.id })
        // Position records what was presented when, not the habit's sequence order.
        #expect(step.position == 1)
    }

    @Test("Resuming a run left open with nothing remaining closes it")
    func resumeClosesStaleRun() {
        let a = habit("Water", order: 0)
        var first = RoutineRunner(routine: .morning, histories: histories([a]), at: morning, in: utc)
        _ = first.undo(at: morning)  // no-op, run still open with a on screen
        var open = first.run
        open.endedAt = nil

        let later = morning.addingTimeInterval(600)
        let resumed = RoutineRunner(routine: .morning, histories: histories([a], completedToday: [a.id]),
                                    resuming: open, at: later, in: utc)
        #expect(resumed.isFinished)
        #expect(resumed.run.endedAt == later)
    }
}
