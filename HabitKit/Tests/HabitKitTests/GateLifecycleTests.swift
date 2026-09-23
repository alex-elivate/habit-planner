import Foundation
import Testing
@testable import HabitKit

/// The two gate loopholes found in the Phase 3 review, and the rules that closed them.
@Suite("Gate across pause, archive and schedule edits")
struct GateLifecycleTests {

    func habit(startedDaysAgo: Int, schedule: Schedule = .daily, id: UUID = UUID()) -> Habit {
        Habit(id: id, title: "h", routine: .morning, order: 0, schedule: schedule,
              startedOn: referenceToday.advanced(by: -startedDaysAgo))
    }

    func done(_ habit: Habit, daysAgo: some Sequence<Int>) -> [CompletionEvent] {
        daysAgo.map {
            CompletionEvent(habitID: habit.id, dayKey: referenceToday.advanced(by: -$0),
                            occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        }
    }

    func state(_ habit: Habit, _ state: LifecycleEvent.State, daysAgo: Int) -> LifecycleEvent {
        LifecycleEvent(habitID: habit.id, dayKey: referenceToday.advanced(by: -daysAgo), state: state,
                       occurredAt: .distantPast, timeZoneIdentifier: "UTC")
    }

    func history(_ habit: Habit, _ events: [CompletionEvent], _ lifecycle: [LifecycleEvent] = []) -> HabitHistory {
        HabitHistory(habit: habit, events: events, lifecycle: lifecycle, today: referenceToday)
    }

    // MARK: - Pause

    @Test("Pause, add, resume cannot leave two habits bedding in: the pause itself holds the gate")
    func pauseLoopholeClosed() {
        let settled = habit(startedDaysAgo: 90)
        let young = habit(startedDaysAgo: 5)
        let histories = [
            history(settled, done(settled, daysAgo: 1...90)),
            history(young, done(young, daysAgo: 2...5), [state(young, .paused, daysAgo: 1)]),
        ]
        #expect(LockInGate.canAddHabit(to: .morning, histories: histories).isOpen == false)
        #expect(LockInGate.judged(in: .morning, histories: histories)?.habit.id == young.id)
    }

    @Test("A paused habit that had already bedded in does not hold the gate")
    func pausedButBeddedIn() {
        let settled = habit(startedDaysAgo: 60)
        let histories = [history(settled, done(settled, daysAgo: 2...60), [state(settled, .paused, daysAgo: 1)])]
        #expect(LockInGate.canAddHabit(to: .morning, histories: histories).isOpen)
    }

    @Test("Resuming from a pause does not move a habit in the gate's order")
    func resumeKeepsOrder() {
        let older = habit(startedDaysAgo: 40)
        let newer = habit(startedDaysAgo: 20)
        let histories = [
            history(older, done(older, daysAgo: 1...40), [state(older, .paused, daysAgo: 10), state(older, .active, daysAgo: 5)]),
            history(newer, done(newer, daysAgo: 1...20)),
        ]
        #expect(LockInGate.judged(in: .morning, histories: histories)?.habit.id == newer.id)
    }

    // MARK: - Archive and restore

    @Test("A habit restored from the archive rejoins the routine on the day it was restored")
    func restoreRejoins() {
        let settled = habit(startedDaysAgo: 120)
        let restored = habit(startedDaysAgo: 100)
        let addedMeanwhile = habit(startedDaysAgo: 60)
        let histories = [
            history(settled, done(settled, daysAgo: 1...120)),
            history(restored, done(restored, daysAgo: 91...100),
                    [state(restored, .archived, daysAgo: 90), state(restored, .active, daysAgo: 2)]),
            history(addedMeanwhile, done(addedMeanwhile, daysAgo: 1...60)),
        ]
        // Started earliest of the two, but restored most recently, so it is the one judged,
        // and with 11 settled sessions it holds the gate.
        #expect(LockInGate.judged(in: .morning, histories: histories)?.habit.id == restored.id)
        #expect(LockInGate.canAddHabit(to: .morning, histories: histories).isOpen == false)
    }

    @Test("Archive, add, restore is refused while the added habit is still bedding in")
    func restoreLoopholeClosed() {
        let settled = habit(startedDaysAgo: 120)
        let archived = habit(startedDaysAgo: 30)
        let added = habit(startedDaysAgo: 10)
        let archivedHistory = history(archived, done(archived, daysAgo: 21...30), [state(archived, .archived, daysAgo: 20)])
        let histories = [
            history(settled, done(settled, daysAgo: 1...120)),
            archivedHistory,
            history(added, done(added, daysAgo: 1...10)),
        ]
        #expect(LockInGate.canRestore(archivedHistory, histories: histories) == false)
    }

    @Test("Restore is allowed when the gate is open, or when the habit had already bedded in")
    func restoreAllowed() {
        let settled = habit(startedDaysAgo: 120)
        let young = habit(startedDaysAgo: 30)
        let youngArchived = history(young, done(young, daysAgo: 21...30), [state(young, .archived, daysAgo: 20)])
        #expect(LockInGate.canRestore(youngArchived, histories: [history(settled, done(settled, daysAgo: 1...120)), youngArchived]))

        let veteran = habit(startedDaysAgo: 200)
        let veteranArchived = history(veteran, done(veteran, daysAgo: 100...200), [state(veteran, .archived, daysAgo: 99)])
        let bedding = habit(startedDaysAgo: 5)
        #expect(LockInGate.canRestore(veteranArchived,
                                      histories: [veteranArchived, history(bedding, done(bedding, daysAgo: 1...5))]))
    }

    // MARK: - Schedule edits

    @Test("A schedule edit that would open a shut gate is refused")
    func scheduleEditRefused() {
        // Daily, but only ever done Monday, Wednesday and Friday, so it misses twice a week.
        let young = habit(startedDaysAgo: 70)
        let mwf = (1...70).filter { [.monday, .wednesday, .friday].contains(referenceToday.advanced(by: -$0).weekday) }
        let histories = [history(young, done(young, daysAgo: mwf))]
        #expect(LockInGate.canAddHabit(to: .morning, histories: histories).isOpen == false)

        #expect(LockInGate.allowsScheduleChange(of: young.id, to: .daysOfWeek([.monday, .wednesday, .friday]),
                                                histories: histories) == false)
    }

    @Test("A schedule edit that leaves the gate shut, or edits a routine already open, is allowed")
    func scheduleEditAllowed() {
        let young = habit(startedDaysAgo: 5)
        let youngHistories = [history(young, done(young, daysAgo: 1...5))]
        #expect(LockInGate.allowsScheduleChange(of: young.id, to: .daysOfWeek([.monday]), histories: youngHistories))

        let settled = habit(startedDaysAgo: 60)
        let settledHistories = [history(settled, done(settled, daysAgo: 1...60))]
        #expect(LockInGate.allowsScheduleChange(of: settled.id, to: .daysOfWeek([.tuesday]), histories: settledHistories))
    }

    @Test("Refolding for a changed schedule matches folding from scratch")
    func replacingMatchesFreshFold() {
        let original = habit(startedDaysAgo: 30)
        let events = done(original, daysAgo: stride(from: 1, through: 30, by: 2))
        var changed = original
        changed.schedule = .daysOfWeek([.monday, .thursday])
        #expect(history(original, events).replacing(changed) == history(changed, events))
    }
}
