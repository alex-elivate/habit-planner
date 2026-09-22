import Foundation
import Testing
@testable import HabitKit

@Suite("Lifecycle")
struct LifecycleTests {

    private func event(_ habitID: UUID, _ day: DayKey, _ state: LifecycleEvent.State,
                       at instant: Date = .distantPast) -> LifecycleEvent {
        LifecycleEvent(habitID: habitID, dayKey: day, state: state,
                       occurredAt: instant, timeZoneIdentifier: "UTC")
    }

    @Test("A habit with no lifecycle events is active")
    func defaultsToActive() {
        let timeline = LifecycleTimeline(habitID: UUID(),
                                         startedOn: referenceToday.advanced(by: -30),
                                         events: [LifecycleEvent]())
        #expect(timeline.isActive(on: referenceToday))
        #expect(timeline.state(on: referenceToday.advanced(by: -20)) == .active)
    }

    @Test("State applies from its day forward, not before")
    func statesApplyForward() {
        let id = UUID()
        let start = referenceToday.advanced(by: -30)
        let timeline = LifecycleTimeline(habitID: id, startedOn: start, events: [
            event(id, referenceToday.advanced(by: -10), .paused)
        ])

        #expect(timeline.state(on: referenceToday.advanced(by: -11)) == .active)
        #expect(timeline.state(on: referenceToday.advanced(by: -10)) == .paused)
        #expect(timeline.state(on: referenceToday) == .paused)
    }

    @Test("Pausing costs nothing and resuming does not replay the gap as misses")
    func pauseAndResume() {
        // Thirty perfect days, a thirty day pause, then ten more perfect days.
        let id = UUID()
        let start = referenceToday.advanced(by: -70)
        let pausedOn = start.advanced(by: 30)
        let resumedOn = start.advanced(by: 60)

        let habit = Habit(id: id, title: "Walk", routine: .morning, order: 0, startedOn: start)
        let completedDays = (0..<30).map { start.advanced(by: $0) }
            + (60..<70).map { start.advanced(by: $0) }
        let completions = completedDays.map {
            CompletionEvent(habitID: id, dayKey: $0, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        }

        let history = HabitHistory(
            habit: habit,
            events: completions,
            lifecycle: [event(id, pausedOn, .paused), event(id, resumedOn, .active)],
            today: referenceToday
        )

        // Forty scheduled days, all completed. The thirty paused days simply are not there.
        #expect(history.settledOccurrences.count == 40)
        let allCompleted = history.settledOccurrences.allSatisfy(\.isCompleted)
        #expect(allCompleted)
        #expect(history.streak == .healthy(length: 40))
        #expect(LockInGate.assess(history).decision == .open)
        #expect(history.currentState == .active)
    }

    @Test("A habit can be paused more than once")
    func repeatedPauses() {
        let id = UUID()
        let start = referenceToday.advanced(by: -40)
        let habit = Habit(id: id, title: "Walk", routine: .morning, order: 0, startedOn: start)

        let timeline = LifecycleTimeline(habitID: id, startedOn: start, events: [
            event(id, start.advanced(by: 10), .paused),
            event(id, start.advanced(by: 15), .active),
            event(id, start.advanced(by: 25), .paused),
            event(id, start.advanced(by: 30), .active)
        ])

        #expect(timeline.state(on: start.advanced(by: 5)) == .active)
        #expect(timeline.state(on: start.advanced(by: 12)) == .paused)
        #expect(timeline.state(on: start.advanced(by: 20)) == .active)
        #expect(timeline.state(on: start.advanced(by: 27)) == .paused)
        #expect(timeline.state(on: start.advanced(by: 35)) == .active)

        let completions = completeEveryScheduledDay(habit, through: referenceToday.advanced(by: -1))
        let history = HabitHistory(habit: habit, events: completions,
                                   lifecycle: [
                                       event(id, start.advanced(by: 10), .paused),
                                       event(id, start.advanced(by: 15), .active),
                                       event(id, start.advanced(by: 25), .paused),
                                       event(id, start.advanced(by: 30), .active)
                                   ],
                                   today: referenceToday)
        // Forty days minus two five-day pauses.
        #expect(history.settledOccurrences.count == 30)
    }

    @Test("Archiving stops the clock instead of accruing misses forever")
    func archivingStopsTheClock() {
        // Seventy perfect days, archived thirty days ago. Without an archive transition the
        // habit kept generating a miss every day and halved the score.
        let id = UUID()
        let start = referenceToday.advanced(by: -100)
        let archivedOn = start.advanced(by: 70)
        let habit = Habit(id: id, title: "Old", routine: .morning, order: 0, startedOn: start)

        let completions = (0..<70).map {
            CompletionEvent(habitID: id, dayKey: start.advanced(by: $0),
                            occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        }
        let archived = HabitHistory(habit: habit, events: completions,
                                    lifecycle: [event(id, archivedOn, .archived)],
                                    today: referenceToday)

        #expect(archived.settledOccurrences.count == 70)
        #expect(archived.currentState == .archived)
        #expect(!archived.isDueToday)
        #expect(ScoreEngine.trailingRate(for: [archived], days: 7) == nil)

        // And it no longer drags a live habit's score down.
        let live = makeHistory(String(repeating: "C", count: 30))
        #expect(ScoreEngine.score(for: [archived, live], days: 7) == 100)
    }

    @Test("A paused habit cannot show a completion checkmark")
    func pausedIsNotCompleteToday() {
        let history = makeHistory("CCCCC", completedToday: true, state: .paused)
        #expect(!history.isDueToday)
        #expect(!history.isCompletedToday)
    }

    @Test("The last decision of the day wins, and same-day flapping is a no-op")
    func sameDayResolution() {
        let id = UUID()
        let day = referenceToday.advanced(by: -5)
        let events = [
            event(id, day, .paused, at: Date(timeIntervalSince1970: 100)),
            event(id, day, .active, at: Date(timeIntervalSince1970: 500))
        ]
        #expect(events.deduplicated().count == 1)
        let timeline = LifecycleTimeline(habitID: id, startedOn: referenceToday.advanced(by: -30), events: events)
        #expect(timeline.state(on: referenceToday) == .active)
    }
}
