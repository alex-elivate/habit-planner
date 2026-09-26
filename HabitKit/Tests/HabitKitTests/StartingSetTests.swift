import Foundation
import Testing
@testable import HabitKit

/// Somebody who already has a routine enters all of it on the first day, and the gate then
/// judges those habits together.
@Suite("Starting set")
struct StartingSetTests {

    @Test("Any number of habits can join a routine on its first day")
    func setupDayIsOpen() {
        // An empty pattern starts the habit today.
        let entered = (0..<5).map { _ in makeHistory("") }
        #expect(LockInGate.isSettingUp(.morning, histories: entered))
        #expect(LockInGate.canAddHabit(to: .morning, histories: entered) == .open)
        #expect(RoutineGlance.Unlock(routine: .morning, histories: entered, gateHasUnreadableInput: false) == .open)
    }

    @Test("The day after, the starting set holds the routine shut")
    func setupEndsAtMidnight() {
        let entered = (0..<3).map { _ in makeHistory("C") }
        #expect(!LockInGate.isSettingUp(.morning, histories: entered))
        #expect(LockInGate.canAddHabit(to: .morning, histories: entered)
                == .blocked(.notEnoughHistory(elapsed: 1, required: 28)))
    }

    @Test("A routine with an older habit is not in setup, however many join today")
    func onlyAFreshRoutineIsInSetup() {
        let established = makeHistory(pattern(length: 60, missesAt: []))
        let today = makeHistory("")
        #expect(!LockInGate.isSettingUp(.morning, histories: [established, today]))
        #expect(LockInGate.canAddHabit(to: .morning, histories: [established, today]) != .open)
    }

    @Test("Every starting habit must bed in, not only the newest")
    func judgedTogether() {
        let solid = makeHistory(pattern(missesAt: []))
        let rough = makeHistory(pattern(missesAt: [0, 5, 10, 15, 20]))
        let histories = [solid, rough]

        #expect(LockInGate.judged(in: .morning, histories: histories)?.habit.id == rough.habit.id)
        #expect(LockInGate.canAddHabit(to: .morning, histories: histories)
                == .blocked(.rateTooLow(rate: 23.0 / 28.0, required: 0.85)))

        let alsoSolid = makeHistory(pattern(missesAt: []))
        #expect(LockInGate.canAddHabit(to: .morning, histories: [solid, alsoSolid]) == .open)
    }

    @Test("The gate waits on the starting habit furthest behind")
    func furthestBehind() {
        let good = makeHistory(pattern(missesAt: [3]))
        let worse = makeHistory(pattern(missesAt: [3, 9, 12, 20, 25]))
        let bad = makeHistory(pattern(missesAt: [2, 4, 8, 12, 16, 20, 24]))
        #expect(LockInGate.judged(in: .morning, histories: [good, worse, bad])?.habit.id == bad.habit.id)
    }

    @Test("Once a later habit joins, only that habit is judged")
    func laterHabitsAreJudgedAlone() {
        // One starting habit never bedded in well, but the routine opened once and took
        // another. Re-judging the starting set would lock a routine that already moved on.
        let rough = makeHistory(pattern(length: 60, missesAt: Set(0..<30)))
        let solid = makeHistory(pattern(length: 60, missesAt: []))
        let added = makeHistory(pattern(missesAt: []))
        #expect(LockInGate.newestCohort(in: .morning, histories: [rough, solid, added]).map(\.habit.id) == [added.habit.id])
        #expect(LockInGate.canAddHabit(to: .morning, histories: [rough, solid, added]) == .open)
    }

    @Test("An archived starting habit no longer holds the routine")
    func archivedStartingHabitIsOut() {
        let solid = makeHistory(pattern(missesAt: []))
        let dropped = makeHistory(pattern(missesAt: Set(0..<10)), state: .archived)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [solid, dropped]) == .open)
    }

    @Test("A paused starting habit still holds the routine")
    func pausedStartingHabitHolds() {
        // Both joined 28 days ago. The second was paused 20 days ago, so only 8 of its
        // sessions count, and pausing it is no way past the gate.
        let solid = makeHistory(pattern(missesAt: []))
        let paused = makeHistory(pattern(missesAt: []), state: .paused,
                                 stateChangedOn: referenceToday.advanced(by: -20))
        #expect(LockInGate.judged(in: .morning, histories: [solid, paused])?.habit.id == paused.habit.id)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [solid, paused]) != .open)
    }

    // MARK: - Ways around it, found in review

    func habit(startedDaysAgo: Int, id: UUID = UUID()) -> Habit {
        Habit(id: id, title: "h", routine: .morning, order: 0, schedule: .daily,
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

    @Test("Archiving a whole routine does not reopen setup")
    func archivingEverythingKeepsSetupShut() {
        let old = habit(startedDaysAgo: 60)
        let archived = HabitHistory(habit: old, events: done(old, daysAgo: 1...60),
                                    lifecycle: [state(old, .archived, daysAgo: 0)], today: referenceToday)
        let fresh = makeHistory("")
        #expect(!LockInGate.isSettingUp(.morning, histories: [archived]))
        #expect(!LockInGate.isSettingUp(.morning, histories: [archived, fresh]))
        #expect(LockInGate.canAddHabit(to: .morning, histories: [archived, fresh]) != .open)
    }

    @Test("A habit restored after bedding in cannot stand in for one still bedding in")
    func restoredHabitKeepsItsOldPlace() {
        // Bedded in over 60 days, archived 10 days ago, restored today.
        let veteran = habit(startedDaysAgo: 70)
        let restored = HabitHistory(habit: veteran, events: done(veteran, daysAgo: 11...70),
                                    lifecycle: [state(veteran, .archived, daysAgo: 10), state(veteran, .active, daysAgo: 0)],
                                    today: referenceToday)
        let young = makeHistory(pattern(length: 5, missesAt: []))
        #expect(LockInGate.gateJoinDay(restored) == veteran.startedOn)
        #expect(LockInGate.judged(in: .morning, histories: [restored, young])?.habit.id == young.habit.id)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [restored, young]) != .open)
    }

    @Test("A habit restored before bedding in queues as the newest")
    func unfinishedRestoreStillQueues() {
        let dropped = habit(startedDaysAgo: 40)
        let restored = HabitHistory(habit: dropped, events: done(dropped, daysAgo: 31...40),
                                    lifecycle: [state(dropped, .archived, daysAgo: 30), state(dropped, .active, daysAgo: 1)],
                                    today: referenceToday)
        let settled = makeHistory(pattern(length: 60, missesAt: []))
        #expect(LockInGate.gateJoinDay(restored) == referenceToday.advanced(by: -1))
        #expect(LockInGate.judged(in: .morning, histories: [settled, restored])?.habit.id == restored.habit.id)
    }

    @Test("Habits added the same day on two devices are judged together")
    func sameDayFromTwoDevicesIsACohort() {
        let settled = makeHistory(pattern(length: 60, missesAt: []))
        let fromPhone = makeHistory(pattern(length: 3, missesAt: []))
        let fromMac = makeHistory(pattern(length: 3, missesAt: [2]))
        let histories = [settled, fromPhone, fromMac]
        #expect(Set(LockInGate.newestCohort(in: .morning, histories: histories).map(\.habit.id))
                == [fromPhone.habit.id, fromMac.habit.id])
        #expect(LockInGate.waitingOn(in: .morning, histories: histories).count == 2)
    }

    @Test("Winding the clock back to the first day does not reopen setup")
    func clockBackKeepsSetupShut() {
        // Started "today", with a completion dated tomorrow: the clock has gone back.
        let habit = habit(startedDaysAgo: 0)
        let ahead = CompletionEvent(habitID: habit.id, dayKey: referenceToday.advanced(by: 1),
                                    occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        let history = HabitHistory(habit: habit, events: [ahead], lifecycle: [], today: referenceToday)
        #expect(history.hasRecordsAfterToday)
        #expect(!LockInGate.isSettingUp(.morning, histories: [history]))
    }

    @Test("Nothing is waited on during setup")
    func nothingWaitedOnInSetup() {
        let entered = (0..<3).map { _ in makeHistory("") }
        #expect(LockInGate.waitingOn(in: .morning, histories: entered).isEmpty)
    }

    @Test("A restored veteran keeps its place when it slips later")
    func restoredPlaceIsSettledAtRestore() {
        // Bedded in over days 70 to 11 ago, archived 10 days ago, restored 5 days ago, then
        // missed the last two days. Today's record fails, but its place was earned before.
        let veteran = habit(startedDaysAgo: 70)
        let slipping = HabitHistory(habit: veteran, events: done(veteran, daysAgo: [3, 4, 5] + Array(11...70)),
                                    lifecycle: [state(veteran, .archived, daysAgo: 10), state(veteran, .active, daysAgo: 5)],
                                    today: referenceToday)
        #expect(!LockInGate.assess(slipping).isLockedIn)
        #expect(LockInGate.hadBeddedInBeforeLeaving(slipping))
        #expect(LockInGate.gateJoinDay(slipping) == veteran.startedOn)

        let settled = makeHistory(pattern(length: 40, missesAt: []))
        #expect(LockInGate.judged(in: .morning, histories: [slipping, settled])?.habit.id == settled.habit.id)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [slipping, settled]) == .open)
    }
}
