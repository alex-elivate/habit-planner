import Foundation
import Testing
@testable import HabitKit

@Suite("Lock-in gate")
struct LockInGateTests {

    /// Coarse shape of a decision, so the table stays readable.
    enum Outcome: Sendable, Equatable {
        case open, notEnoughHistory, rateTooLow, recentDoubleMiss

        init(_ decision: LockInGate.Decision) {
            switch decision {
            case .open: self = .open
            case .blocked(.notEnoughHistory): self = .notEnoughHistory
            case .blocked(.rateTooLow): self = .rateTooLow
            case .blocked(.recentDoubleMiss): self = .recentDoubleMiss
            }
        }
    }

    struct Case: Sendable, CustomStringConvertible {
        let pattern: String
        let expected: Outcome
        let note: String
        var description: String { note }
    }

    @Test("The gate opens on consistency, not on the calendar", arguments: [
        Case(pattern: pattern(missesAt: []),
             expected: .open,
             note: "28 straight completions"),

        Case(pattern: pattern(length: 27, missesAt: []),
             expected: .notEnoughHistory,
             note: "27 perfect days is one short, however good it looks"),

        Case(pattern: pattern(missesAt: [0, 4, 8, 12]),
             expected: .open,
             note: "24 of 28 is 85.7%, scattered misses, all outside the recent window"),

        Case(pattern: pattern(missesAt: [0, 4, 8, 12, 16]),
             expected: .rateTooLow,
             note: "23 of 28 is 82.1%, under the bar"),

        Case(pattern: pattern(missesAt: [20, 21]),
             expected: .recentDoubleMiss,
             note: "93% overall, but two in a row last week"),

        Case(pattern: pattern(missesAt: [2, 3]),
             expected: .open,
             note: "an old double-miss has aged out of the 14-day window"),

        Case(pattern: pattern(missesAt: [26, 27]),
             expected: .recentDoubleMiss,
             note: "a double-miss right up against today")
    ])
    func decisions(testCase: Case) {
        let assessment = LockInGate.assess(makeHistory(testCase.pattern))
        #expect(Outcome(assessment.decision) == testCase.expected, "\(testCase)")
    }

    @Test("A blocked decision says exactly what is missing")
    func blockerDetail() throws {
        let short = LockInGate.assess(makeHistory(pattern(length: 20, missesAt: [])))
        #expect(short.decision == .blocked(.notEnoughHistory(elapsed: 20, required: 28)))
        #expect(abs(short.repetitionProgress - 20.0 / 28.0) < 0.0001)

        let low = LockInGate.assess(makeHistory(pattern(missesAt: [0, 4, 8, 12, 16])))
        #expect(low.decision == .blocked(.rateTooLow(rate: 23.0 / 28.0, required: 0.85)))

        // The second miss is the one that counts, and it lands seven days back.
        let doubled = LockInGate.assess(makeHistory(pattern(missesAt: [20, 21])))
        #expect(doubled.decision == .blocked(.recentDoubleMiss(secondMissOn: referenceToday.advanced(by: -7))))
    }

    @Test("Repetition is counted in occurrences, so a weekly habit is judged fairly")
    func weeklyHabitCountsOccurrences() {
        let today = referenceToday  // a Monday

        func mondayWednesdayFriday(startingDaysAgo days: Int) -> HabitHistory {
            let habit = Habit(
                title: "Gym",
                routine: .evening,
                order: 0,
                schedule: .daysOfWeek([.monday, .wednesday, .friday]),
                startedOn: today.advanced(by: -days)
            )
            let scheduled = habit.startedOn.through(today.advanced(by: -1))
                .filter { habit.wasScheduled(on: $0) }
            let events = scheduled.map {
                CompletionEvent(habitID: habit.id, dayKey: $0, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
            }
            return HabitHistory(habit: habit, events: events, today: today)
        }

        // Nine weeks is 63 days but only 27 sessions. Plenty of calendar, not enough reps.
        let nineWeeks = mondayWednesdayFriday(startingDaysAgo: 63)
        #expect(nineWeeks.settledOccurrences.count == 27)
        #expect(LockInGate.assess(nineWeeks).decision == .blocked(.notEnoughHistory(elapsed: 27, required: 28)))

        // Ten weeks gets there.
        let tenWeeks = mondayWednesdayFriday(startingDaysAgo: 70)
        #expect(tenWeeks.settledOccurrences.count == 30)
        #expect(LockInGate.assess(tenWeeks).decision == .open)
    }

    @Test("The first habit in an empty routine is never gated")
    func firstHabitIsFree() {
        #expect(LockInGate.canAddHabit(to: .morning, histories: [HabitHistory]()) == .open)

        // An evening habit does not unlock the morning.
        let eveningOnly = makeHistory(pattern(missesAt: []), routine: .evening)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [eveningOnly]) == .open)
    }

    @Test("Only the newest habit in the routine is judged")
    func onlyTheNewestCounts() {
        // An older habit with a poor record does not block, because it already earned its place.
        let oldAndRough = makeHistory(pattern(length: 60, missesAt: Set(0..<30)), routine: .morning)
        let newAndSolid = makeHistory(pattern(missesAt: []), routine: .morning)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [oldAndRough, newAndSolid]) == .open)

        // But a freshly added habit blocks, no matter how good everything before it was.
        let established = makeHistory(pattern(length: 60, missesAt: []), routine: .morning)
        let justStarted = makeHistory(pattern(length: 6, missesAt: []), routine: .morning)
        #expect(
            LockInGate.canAddHabit(to: .morning, histories: [established, justStarted])
                == .blocked(.notEnoughHistory(elapsed: 6, required: 28))
        )
    }

    @Test("An archived habit no longer holds the routine shut")
    func archivedDoesNotBlock() {
        let abandoned = makeHistory(pattern(length: 6, missesAt: []), lifecycle: .archived, routine: .morning)
        let established = makeHistory(pattern(length: 60, missesAt: []), routine: .morning)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [established, abandoned]) == .open)
    }
}
