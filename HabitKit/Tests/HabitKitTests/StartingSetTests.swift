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
        #expect(LockInGate.startingSet(in: .morning, histories: [rough, solid, added]).count == 2)
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
}
