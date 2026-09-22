import Foundation
import Testing
@testable import HabitKit

@Suite("Retraction")
struct RetractionTests {

    private let habitID = UUID()

    private func habit(startedDaysAgo days: Int) -> Habit {
        Habit(id: habitID, title: "Walk", routine: .morning, order: 0,
              startedOn: referenceToday.advanced(by: -days))
    }

    private func completion(_ day: DayKey, recordedAt: Date = Date(timeIntervalSince1970: 1_000)) -> CompletionEvent {
        CompletionEvent(habitID: habitID, dayKey: day, status: .completed,
                        occurredAt: Date(timeIntervalSince1970: 1_000),
                        recordedAt: recordedAt, timeZoneIdentifier: "UTC")
    }

    private func retraction(_ day: DayKey, recordedAt: Date) -> CompletionEvent {
        CompletionEvent(habitID: habitID, dayKey: day, status: .retracted,
                        occurredAt: Date(timeIntervalSince1970: 1_000),
                        recordedAt: recordedAt, timeZoneIdentifier: "UTC")
    }

    @Test("Retracting a completion un-completes that day")
    func retractionUndoesCompletion() {
        let day = referenceToday.advanced(by: -1)
        let events = [completion(day), retraction(day, recordedAt: Date(timeIntervalSince1970: 2_000))]

        #expect(events.completedDays(for: habitID).isEmpty)

        let history = HabitHistory(habit: habit(startedDaysAgo: 1), events: events, today: referenceToday)
        #expect(history.settledOccurrences.count == 1)
        #expect(history.settledOccurrences[0].isCompleted == false)
    }

    @Test("Changing your mind again re-completes it")
    func reCompletionWins() {
        let day = referenceToday.advanced(by: -1)
        let events = [
            completion(day, recordedAt: Date(timeIntervalSince1970: 1_000)),
            retraction(day, recordedAt: Date(timeIntervalSince1970: 2_000)),
            completion(day, recordedAt: Date(timeIntervalSince1970: 3_000))
        ]
        #expect(events.completedDays(for: habitID) == [day])
    }

    @Test("A retraction only touches the day it names")
    func retractionIsScopedToItsDay() {
        let yesterday = referenceToday.advanced(by: -1)
        let dayBefore = referenceToday.advanced(by: -2)
        let events = [
            completion(dayBefore),
            completion(yesterday),
            retraction(yesterday, recordedAt: Date(timeIntervalSince1970: 2_000))
        ]
        #expect(events.completedDays(for: habitID) == [dayBefore])
    }

    @Test("The convenience initializer retracts an existing assertion")
    func retractedHelper() {
        let day = referenceToday.advanced(by: -1)
        let original = completion(day)
        let undone = original.retracted(at: Date(timeIntervalSince1970: 5_000))

        #expect(undone.id == original.id)
        #expect(undone.status == .retracted)
        #expect([original, undone].completedDays(for: habitID).isEmpty)
    }

    @Test("Simultaneous assertions resolve to the retraction")
    func tiePrefersRetraction() {
        // Two devices asserting at the same instant should not decide an undo by coin flip.
        let day = referenceToday.advanced(by: -1)
        let instant = Date(timeIntervalSince1970: 4_000)
        let events = [completion(day, recordedAt: instant), retraction(day, recordedAt: instant)]

        var outcomes = Set<Bool>()
        for _ in 0..<100 {
            outcomes.insert(events.shuffled().completedDays(for: habitID).isEmpty)
        }
        #expect(outcomes == [true])
    }

    @Test("A duplicate completion keeps the moment the habit was actually done")
    func earliestOccurrenceSurvives() throws {
        // Recorded later by a second device, but it happened at the earlier instant.
        let day = referenceToday.advanced(by: -1)
        let onWatch = CompletionEvent(habitID: habitID, dayKey: day,
                                      occurredAt: Date(timeIntervalSince1970: 100),
                                      recordedAt: Date(timeIntervalSince1970: 100),
                                      timeZoneIdentifier: "UTC")
        let onPhone = CompletionEvent(habitID: habitID, dayKey: day,
                                      occurredAt: Date(timeIntervalSince1970: 900),
                                      recordedAt: Date(timeIntervalSince1970: 900),
                                      timeZoneIdentifier: "UTC")

        let resolved = [onPhone, onWatch].resolved()
        #expect(resolved.count == 1)
        let survivor = try #require(resolved.first)
        #expect(survivor.status == .completed)
        #expect(survivor.occurredAt == Date(timeIntervalSince1970: 100))
    }

    @Test("A backfilled completion counts for the day it happened, not the day it was recorded")
    func backfillCountsForItsOwnDay() {
        // HealthKit reconciliation on launch: the walk was yesterday, we heard about it today.
        let yesterday = referenceToday.advanced(by: -1)
        let backfilled = CompletionEvent(
            habitID: habitID, dayKey: yesterday, status: .completed,
            occurredAt: Date(timeIntervalSince1970: 1_000),
            recordedAt: Date(timeIntervalSince1970: 90_000),
            timeZoneIdentifier: "UTC"
        )
        #expect([backfilled].completedDays(for: habitID) == [yesterday])
    }

    @Test("Undoing a wrong tick reverses a gate that had opened")
    func retractionClosesTheGate() {
        // Nothing derived is stored, so the gate simply recomputes. There is no repair step,
        // and a habit already added on the strength of the old answer stays added.
        let start = referenceToday.advanced(by: -28)
        let habit = Habit(id: habitID, title: "Walk", routine: .morning, order: 0, startedOn: start)
        let days = (0..<28).map { start.advanced(by: $0) }
        let completions = days.map { completion($0) }

        let opened = HabitHistory(habit: habit, events: completions, today: referenceToday)
        #expect(LockInGate.assess(opened).decision == .open)

        // Two of those were auto-completed in error, on consecutive days last week.
        let corrections = [
            retraction(days[20], recordedAt: Date(timeIntervalSince1970: 9_000)),
            retraction(days[21], recordedAt: Date(timeIntervalSince1970: 9_000))
        ]
        let corrected = HabitHistory(habit: habit, events: completions + corrections, today: referenceToday)
        #expect(corrected.settledOccurrences.count == 28)
        #expect(LockInGate.assess(corrected).decision
                == .blocked(.recentDoubleMiss(secondMissOn: days[21])))
    }

    @Test("Retracting today's tick clears the checkmark and the ring")
    func retractionAffectsToday() {
        let habit = habit(startedDaysAgo: 5)
        let done = completion(referenceToday)
        let withTick = HabitHistory(habit: habit, events: [done], today: referenceToday)
        #expect(withTick.isCompletedToday)
        #expect(ScoreEngine.todayProgress(for: [withTick]).completed == 1)

        let undone = [done, done.retracted(at: Date(timeIntervalSince1970: 7_000))]
        let withoutTick = HabitHistory(habit: habit, events: undone, today: referenceToday)
        #expect(!withoutTick.isCompletedToday)
        #expect(ScoreEngine.todayProgress(for: [withoutTick]).completed == 0)
    }
}
