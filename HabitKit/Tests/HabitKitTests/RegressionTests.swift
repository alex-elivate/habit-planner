import Foundation
import Testing
@testable import HabitKit

/// One test per defect found in review. Each names the wrong behavior it pins shut.
@Suite("Regressions")
struct RegressionTests {

    // MARK: Gate decisions

    @Test("Reordering habits cannot change the gate")
    func reorderingDoesNotFlipTheGate() {
        // The gate used to tiebreak on `Habit.order`, so when two habits shared a start date
        // dragging one above the other decided which was judged. A drag opened the gate.
        let start = referenceToday.advanced(by: -40)
        let strongID = UUID()
        let weakID = UUID()

        func history(_ marks: String, id: UUID, order: Int) -> HabitHistory {
            let habit = Habit(id: id, title: "x", routine: .morning, order: order, startedOn: start)
            let events = marks.enumerated().compactMap { index, mark -> CompletionEvent? in
                mark == "C" ? CompletionEvent(habitID: id, dayKey: start.advanced(by: index),
                                              occurredAt: .distantPast, timeZoneIdentifier: "UTC") : nil
            }
            return HabitHistory(habit: habit, events: events, today: referenceToday)
        }

        let strong = String(repeating: "C", count: 40)
        let weak = String(repeating: "CM", count: 20)   // 50%

        let before = LockInGate.canAddHabit(to: .morning, histories: [
            history(strong, id: strongID, order: 0),
            history(weak, id: weakID, order: 1)
        ])
        let afterDrag = LockInGate.canAddHabit(to: .morning, histories: [
            history(strong, id: strongID, order: 1),
            history(weak, id: weakID, order: 0)
        ])
        #expect(before == afterDrag)
    }

    @Test("The gate does not depend on the order histories arrive in")
    func gateIsIndependentOfSequenceOrder() {
        // Histories will arrive from an unordered SwiftData fetch.
        let a = makeHistory(String(repeating: "C", count: 40), id: UUID())
        let b = makeHistory(String(repeating: "CM", count: 20), id: UUID())
        #expect(LockInGate.canAddHabit(to: .morning, histories: [a, b])
                == LockInGate.canAddHabit(to: .morning, histories: [b, a]))
    }

    @Test("A double-miss whose second miss is exactly 14 days old still blocks")
    func doubleMissAtTheWindowEdge() {
        // The scan used to receive a pre-sliced window, so it started blind and could not
        // see a pair straddling the boundary. That made the window 13 days, not 14.
        let straddling = LockInGate.assess(makeHistory(pattern(missesAt: [13, 14])))
        #expect(straddling.decision == .blocked(.recentDoubleMiss(secondMissOn: referenceToday.advanced(by: -14))))

        // One day older still, and it has genuinely aged out.
        let aged = LockInGate.assess(makeHistory(pattern(missesAt: [12, 13])))
        #expect(aged.decision == .open)
    }

    @Test("For a weekly habit, two missed sessions in a row block even when days apart")
    func weeklyDoubleMissIsNotHiddenByTheDayWindow() {
        // Misses are adjacent as occurrences while the window is measured in days. Slicing
        // by days first hid a genuine never-miss-twice failure for any non-daily schedule.
        let today = referenceToday  // Monday
        let habit = Habit(title: "Gym", routine: .evening, order: 0,
                          schedule: .daysOfWeek([.monday, .wednesday, .friday]),
                          startedOn: today.advanced(by: -70))

        let missed: Set<DayKey> = [DayKey(year: 2026, month: 9, day: 4),   // Friday
                                   DayKey(year: 2026, month: 9, day: 7)]   // the next Monday
        let completions = completeEveryScheduledDay(habit, through: today.advanced(by: -1))
            .filter { !missed.contains($0.dayKey) }

        let history = HabitHistory(habit: habit, events: completions, today: today)
        let assessment = LockInGate.assess(history)

        #expect(history.settledOccurrences.count == 30)
        #expect((assessment.rate ?? 0) > LockInGate.requiredRate, "rate alone should not block")
        #expect(assessment.decision == .blocked(.recentDoubleMiss(secondMissOn: DayKey(year: 2026, month: 9, day: 7))))
    }

    @Test("Pausing your newest habit holds the gate, and archiving it releases it")
    func pausedHabitStillBlocks() {
        // Decided in Phase 3. Releasing the gate on pause let the person pause, add another,
        // and resume, leaving two habits bedding in at once. Archiving is the way out, and
        // restoring is gated like adding. See `canRestore`.
        let established = makeHistory(pattern(length: 60, missesAt: []))
        let paused = makeHistory(pattern(length: 10, missesAt: []), state: .paused)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [established, paused])
            == .blocked(.notEnoughHistory(elapsed: 10, required: 28)))

        let archived = makeHistory(pattern(length: 10, missesAt: []), state: .archived)
        #expect(LockInGate.canAddHabit(to: .morning, histories: [established, archived]) == .open)
    }

    // MARK: Stored shapes

    @Test("A day encodes as a bare integer")
    func dayKeyEncodesAsInt() throws {
        // The synthesized form was {"rawValue":20260921}. CloudKit wants an Int64 field.
        let data = try JSONEncoder().encode(DayKey(year: 2026, month: 9, day: 21))
        #expect(String(decoding: data, as: UTF8.self) == "20260921")

        let decoded = try JSONDecoder().decode(DayKey.self, from: data)
        #expect(decoded == DayKey(year: 2026, month: 9, day: 21))
    }

    @Test("Corrupt day values are rejected at the decode boundary", arguments: [
        0,          // a zeroed CloudKit Int64
        20260230,   // February 30th
        20261301,   // month 13
        20260900,   // day zero
        20260229,   // 2026 is not a leap year
        -20260921
    ])
    func invalidDaysAreRejected(raw: Int) {
        #expect(DayKey(validating: raw) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DayKey.self, from: Data("\(raw)".utf8))
        }
    }

    @Test("Real days survive validation")
    func validDaysAccepted() {
        #expect(DayKey(validating: 20240229) != nil)   // 2024 is a leap year
        #expect(DayKey(validating: 20000229) != nil)   // so was 2000
        #expect(DayKey(validating: 19000228) != nil)
        #expect(DayKey(validating: 19000229) == nil)   // but 1900 was not
        #expect(DayKey(validating: 20261231) != nil)
    }

    @Test("A corrupt day cannot be reached through history folding")
    func corruptDayCannotBlowUpHistory() {
        // DayKey(rawValue: 0) has ordinal -719560. Folding history from there used to build
        // a 740,000 element array inside a widget extension.
        #expect(DayKey(validating: 0) == nil)
    }

    @Test("Two copies of one completion collapse in a Set")
    func completionIdentityMatchesItsIdentifier() {
        // Synthesized Hashable covered occurredAt, so the same completion arriving from the
        // Mac and the Watch landed in a Set as two entries.
        let habitID = UUID()
        let day = DayKey(year: 2026, month: 9, day: 21)
        let fromWatch = CompletionEvent(habitID: habitID, dayKey: day,
                                        occurredAt: Date(timeIntervalSince1970: 100),
                                        timeZoneIdentifier: "America/Phoenix")
        let fromPhone = CompletionEvent(habitID: habitID, dayKey: day,
                                        occurredAt: Date(timeIntervalSince1970: 140),
                                        timeZoneIdentifier: "UTC")

        #expect(fromWatch == fromPhone)
        #expect(Set([fromWatch, fromPhone]).count == 1)
    }

    @Test("Deduplication returns a stable order even when instants tie")
    func deduplicationIsDeterministic() {
        // One "complete my whole routine" tap stamps every event with the same Date().
        let day = DayKey(year: 2026, month: 9, day: 21)
        let instant = Date(timeIntervalSince1970: 1_000)
        let events = (0..<8).map {
            CompletionEvent(habitID: UUID(), dayKey: day, slotIndex: $0,
                            occurredAt: instant, timeZoneIdentifier: "UTC")
        }

        var orderings = Set<String>()
        for _ in 0..<200 {
            orderings.insert(events.shuffled().resolved().map(\.id).joined(separator: ","))
        }
        #expect(orderings.count == 1, "expected one ordering, got \(orderings.count)")
    }

    @Test("slotIndex disambiguates taps and is deliberately not scored")
    func slotIndexIsNotScored() {
        // Documented behavior rather than an oversight: a habit is due at most once a day,
        // and scoring several slots would need a slotsPerDay denominator v1 does not have.
        let habit = Habit(title: "Meds", routine: .morning, order: 0,
                          startedOn: referenceToday.advanced(by: -5))
        let events = (0..<5).flatMap { offset in
            (0..<3).map { slot in
                CompletionEvent(habitID: habit.id, dayKey: habit.startedOn.advanced(by: offset),
                                slotIndex: slot, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
            }
        }
        let history = HabitHistory(habit: habit, events: events, today: referenceToday)
        #expect(history.settledOccurrences.count == 5)
        #expect(events.resolved().count == 15)
    }

    @Test("One habit's pause must not pause every other habit")
    func lifecycleDoesNotLeakBetweenHabits() {
        // `HabitHistory` filtered completions by habit and did not filter lifecycle events,
        // so handing it the whole lifecycle log — which is exactly what one store fetch
        // returns — applied any habit's pause to all of them. The unaffected habit read as
        // paused, and its settled history collapsed to the days since somebody else's pause,
        // so every score and gate assessment was computed from a handful of days.
        let start = referenceToday.advanced(by: -10)
        let paused = Habit(title: "paused", routine: .morning, order: 0, startedOn: start)
        let active = Habit(title: "active", routine: .morning, order: 1, startedOn: start)

        let wholeLog = [
            LifecycleEvent(habitID: paused.id, dayKey: start.advanced(by: 1), state: .paused,
                           occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        ]

        let history = HabitHistory(habit: active, events: [CompletionEvent](),
                                   lifecycle: wholeLog, today: referenceToday)

        #expect(history.currentState == .active)
        #expect(history.settledOccurrences.count == 10)
    }


    @Test("Folding assertions one at a time equals folding them all at once")
    func incrementalFoldEqualsBatchFold() {
        // A store folds incrementally: it holds one row per identifier and merges each new
        // assertion into it. That only agrees with the domain if the fold is associative and
        // order-independent. It was not. `resolved()` returned the earliest completion whole,
        // carrying that record's `recordedAt` as well as its `occurredAt`, which wound the
        // survivor's clock backwards. Nothing in memory reads `recordedAt` after a fold, so
        // it was invisible until a store resolved the next conflict against the result and a
        // stale retraction beat a newer completion.
        //
        // Note the comparison is field by field. `CompletionEvent.==` delegates to `id`, so
        // every assertion about one day compares equal and an `==` test here proves nothing.
        func fields(_ e: CompletionEvent?) -> String {
            guard let e else { return "nil" }
            return "\(e.status)|\(e.occurredAt.timeIntervalSince1970)|\(e.recordedAt.timeIntervalSince1970)|\(e.timeZoneIdentifier)"
        }
        func incremental(_ events: [CompletionEvent]) -> CompletionEvent? {
            var held: [CompletionEvent] = []
            for event in events { held = ([event] + held).resolved() }
            return held.first
        }

        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)
        func assertion(_ status: CompletionEvent.Status, occurred: Double, recorded: Double,
                       zone: String = "UTC") -> CompletionEvent {
            CompletionEvent(habitID: habitID, dayKey: day, status: status,
                            occurredAt: Date(timeIntervalSince1970: occurred),
                            recordedAt: Date(timeIntervalSince1970: recorded),
                            timeZoneIdentifier: zone)
        }

        // Brute force rather than argue: every ordering of every small assertion set.
        var sets: [[CompletionEvent]] = []
        for occurred in [0.0, 3_600.0] {
            for recorded in [0.0, 1_800.0, 3_600.0] {
                for status in CompletionEvent.Status.allCases {
                    sets.append([
                        assertion(.completed, occurred: 0, recorded: 0),
                        assertion(.retracted, occurred: 0, recorded: 1_800),
                        assertion(status, occurred: occurred, recorded: recorded, zone: "Europe/London")
                    ])
                }
            }
        }

        for set in sets {
            let batch = fields(set.resolved().first)
            for ordering in permutations(of: set) {
                #expect(fields(ordering.resolved().first) == batch,
                        "batch fold depends on order: \(batch)")
                #expect(fields(incremental(ordering)) == batch,
                        "incremental fold disagrees with batch: \(fields(incremental(ordering))) vs \(batch)")
            }
        }
    }

    @Test("A stale retraction cannot beat a newer completion")
    func staleRetractionLosesToNewerCompletion() {
        // The concrete shape: the watch ticks at 07:00, the phone undoes it at 07:30, and the
        // Mac, which never saw the undo, ticks again at 08:00. Last writer wins, so the day
        // is done.
        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)
        let tick = CompletionEvent(habitID: habitID, dayKey: day, occurredAt: Date(timeIntervalSince1970: 0),
                                   recordedAt: Date(timeIntervalSince1970: 0), timeZoneIdentifier: "UTC")
        let undo = tick.retracted(at: Date(timeIntervalSince1970: 1_800))
        let again = CompletionEvent(habitID: habitID, dayKey: day,
                                    occurredAt: Date(timeIntervalSince1970: 3_600),
                                    recordedAt: Date(timeIntervalSince1970: 3_600), timeZoneIdentifier: "UTC")

        let resolved = [tick, undo, again].resolved().first
        #expect(resolved?.status == .completed)
        // The moment kept is when it was first done, not when it was re-asserted.
        #expect(resolved?.occurredAt == Date(timeIntervalSince1970: 0))
        // The clock that decides future conflicts is the newest assertion's.
        #expect(resolved?.recordedAt == Date(timeIntervalSince1970: 3_600))
    }

}

/// Every ordering of `items`. Used to prove a fold does not depend on arrival order.
func permutations<T>(of items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var result: [[T]] = []
    for (index, item) in items.enumerated() {
        var rest = items
        rest.remove(at: index)
        for tail in permutations(of: rest) { result.append([item] + tail) }
    }
    return result
}
