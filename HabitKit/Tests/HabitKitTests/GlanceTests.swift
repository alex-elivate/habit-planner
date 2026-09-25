import Foundation
import Testing
@testable import HabitKit

@Suite("Planned habit")
struct PlannedHabitTests {

    let early = Date(timeIntervalSince1970: 1_000)
    let late = Date(timeIntervalSince1970: 2_000)

    @Test("The later assertion wins, and a clear is an assertion")
    func laterWins() {
        let plan = PlannedHabit(routine: .morning, title: "Meditate", recordedAt: early)
        let cleared = PlannedHabit.cleared(.morning, at: late)
        #expect([plan, cleared].resolved()[.morning] == cleared)
        #expect([cleared, plan].resolved()[.morning] == cleared)
        #expect([plan, cleared].resolved().active(for: .morning) == nil)

        // An older clear arriving late does not remove a newer plan.
        let newer = PlannedHabit(routine: .morning, title: "Journal", recordedAt: late)
        let stale = PlannedHabit.cleared(.morning, at: early)
        #expect([newer, stale].resolved().active(for: .morning) == newer)
    }

    @Test("Every ordering of the same assertions settles on one survivor")
    func orderIndependent() {
        // Two share a timestamp, so the survivor depends on the tiebreak being total. Over a
        // partial order `resolved()` would keep whichever it met first.
        let plans = [
            PlannedHabit(routine: .morning, title: "Journal", recordedAt: late),
            PlannedHabit(routine: .morning, title: "Meditate", recordedAt: late),
            PlannedHabit(routine: .morning, title: "Read", recordedAt: early),
            PlannedHabit.cleared(.morning, at: early),
        ]
        var survivors: Set<PlannedHabit> = []
        for ordering in permutations(of: plans) {
            survivors.insert(ordering.resolved()[.morning]!)
            // Folding one at a time, as a store does, gives the same answer as all at once.
            var incremental: PlannedHabit?
            for plan in ordering {
                incremental = [incremental, plan].compactMap { $0 }.resolved()[.morning]
            }
            #expect(incremental == ordering.resolved()[.morning])
        }
        #expect(survivors == [PlannedHabit(routine: .morning, title: "Meditate", recordedAt: late)])
    }

    @Test("Routines are resolved separately")
    func perRoutine() {
        let morning = PlannedHabit(routine: .morning, title: "Meditate", recordedAt: early)
        let evening = PlannedHabit(routine: .evening, title: "Floss", recordedAt: late)
        let resolved = [morning, evening].resolved()
        #expect(resolved.active(for: .morning) == morning)
        #expect(resolved.active(for: .evening) == evening)
    }

    @Test("A title of only whitespace is a cleared plan")
    func blankIsCleared() {
        #expect(PlannedHabit(routine: .evening, title: "  \n", recordedAt: early).isCleared)
        #expect(PlannedHabit(routine: .evening, title: " Floss ", recordedAt: early).title == "Floss")
    }

    @Test("A snapshot from a phone that predates plans decodes with none")
    func oldSnapshotDecodes() throws {
        let snapshot = WatchSnapshot(generatedAt: early, habits: [], completions: [], lifecycle: [], runs: [])
        var object = try #require(
            try JSONSerialization.jsonObject(with: BridgeCodec.encode(snapshot)) as? [String: Any]
        )
        object.removeValue(forKey: "planned")
        let decoded = try BridgeCodec.decodeSnapshot(try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.planned.isEmpty)
    }

    @Test("Plans survive the trip to the watch, cleared ones included")
    func snapshotCarriesPlans() throws {
        let plans = [PlannedHabit(routine: .morning, title: "Meditate", recordedAt: early),
                     PlannedHabit.cleared(.evening, at: late)]
        let snapshot = WatchSnapshot(generatedAt: early, habits: [], completions: [], lifecycle: [],
                                     runs: [], planned: plans)
        let decoded = try BridgeCodec.decodeSnapshot(try BridgeCodec.encode(snapshot))
        #expect(decoded.planned == plans)
    }
}

@Suite("Glance")
struct GlanceTests {

    let utc = TimeZone(identifier: "UTC")!

    func instant(hour: Int, on day: DayKey = referenceToday) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day.ordinal) * 86_400 + TimeInterval(hour) * 3_600)
    }

    func habit(_ title: String, order: Int, routine: RoutineSlot = .morning,
               startedDaysAgo: Int = 10, id: UUID = UUID()) -> Habit {
        Habit(id: id, title: title, routine: routine, order: order,
              startedOn: referenceToday.advanced(by: -startedDaysAgo))
    }

    /// Every settled day completed, plus today for the habits in `doneToday`.
    func histories(_ habits: [Habit], doneToday: Set<UUID> = [], today: DayKey = referenceToday) -> [HabitHistory] {
        habits.map { habit in
            var events = completeEveryScheduledDay(habit, through: today.advanced(by: -1))
            if doneToday.contains(habit.id) {
                events.append(CompletionEvent(habitID: habit.id, dayKey: today,
                                              occurredAt: .distantPast, timeZoneIdentifier: "UTC"))
            }
            return HabitHistory(habit: habit, events: events, lifecycle: [], today: today)
        }
    }

    func glance(_ histories: [HabitHistory], runs: [RoutineSlot: RoutineRun] = [:],
                planned: [PlannedHabit] = [], unreadable: Bool = false, hour: Int = 7) -> Glance {
        Glance(histories: histories, runs: runs, planned: planned.resolved(),
               gateHasUnreadableInput: unreadable, at: instant(hour: hour), in: utc)
    }

    // MARK: - Next habit and progress

    @Test("Names the habit the runner would open on, and counts what is left")
    func nextHabitIsTheRunnersFirst() {
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1), walk = habit("Walk", order: 2)
        let result = glance(histories([walk, stretch, water], doneToday: [water.id])).routine(.morning)
        #expect(result.nextHabitTitle == "Stretch")
        #expect(result.remaining == 2)
        #expect(result.progress == Progress(completed: 1, total: 3))
    }

    @Test("A run left halfway resumes past the steps already passed")
    func resumesARun() {
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        let all = histories([water, stretch])
        var runner = RoutineRunner(routine: .morning, histories: all, at: instant(hour: 7), in: utc)
        runner.skip(at: instant(hour: 7))

        let result = glance(all, runs: [.morning: runner.run]).routine(.morning)
        #expect(result.nextHabitTitle == "Stretch")
        #expect(result.remaining == 1)
    }

    @Test("A run from another day does not resume today")
    func ignoresYesterdaysRun() {
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        let yesterday = histories([water, stretch], today: referenceToday.advanced(by: -1))
        var runner = RoutineRunner(routine: .morning, histories: yesterday,
                                   at: instant(hour: 7, on: referenceToday.advanced(by: -1)), in: utc)
        runner.skip(at: instant(hour: 7, on: referenceToday.advanced(by: -1)))

        let result = glance(histories([water, stretch]), runs: [.morning: runner.run]).routine(.morning)
        #expect(result.nextHabitTitle == "Water")
    }

    @Test("Histories folded for another day are not read as today")
    func ignoresStaleFolds() {
        // A widget entry for tomorrow must be built from a fold for tomorrow. Handing it
        // today's fold would show today's ticks on a day nobody has touched yet.
        let water = habit("Water", order: 0)
        let today = histories([water], doneToday: [water.id])
        let tomorrow = Glance(histories: today, runs: [:], planned: [:], gateHasUnreadableInput: false,
                              at: instant(hour: 7, on: referenceToday.advanced(by: 1)), in: utc)
        #expect(tomorrow.routine(.morning).progress.total == 0)
    }

    @Test("Each routine counts only its own habits")
    func routinesAreSeparate() {
        let water = habit("Water", order: 0), read = habit("Read", order: 0, routine: .evening)
        let result = glance(histories([water, read], doneToday: [water.id]))
        #expect(result.routine(.morning).progress == Progress(completed: 1, total: 1))
        #expect(result.routine(.morning).remaining == 0)
        #expect(result.routine(.evening).progress == Progress(completed: 0, total: 1))
        #expect(result.routine(.evening).nextHabitTitle == "Read")
    }

    // MARK: - Unlock

    @Test("An empty routine is open")
    func emptyRoutineIsOpen() {
        #expect(glance([]).routine(.evening).unlock == .open)
    }

    @Test("A habit still bedding in is named, with the gate's own assessment")
    func beddingIn() {
        let old = habit("Water", order: 0, startedDaysAgo: 60)
        let new = habit("Stretch", order: 1, startedDaysAgo: 10)
        let all = histories([old, new])
        guard case .beddingIn(let title, let assessment) = glance(all).routine(.morning).unlock else {
            Issue.record("Expected the routine to be bedding in")
            return
        }
        #expect(title == "Stretch")
        #expect(assessment == LockInGate.assess(LockInGate.judged(in: .morning, histories: all)!))
        #expect(assessment.elapsedOccurrences == 10)
    }

    @Test("A bedded-in routine is open")
    func beddedInIsOpen() {
        #expect(glance(histories([habit("Water", order: 0, startedDaysAgo: 40)])).routine(.morning).unlock == .open)
    }

    @Test("An unreadable record shows the gate as unavailable, never as open")
    func unreadableIsNotOpen() {
        let all = histories([habit("Water", order: 0, startedDaysAgo: 40)])
        #expect(glance(all, unreadable: true).routine(.morning).unlock == .unavailable)
        #expect(glance([], unreadable: true).routine(.evening).unlock == .unavailable)
    }

    @Test("Shows the routine's plan, and nothing once it is cleared")
    func planned() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let plan = PlannedHabit(routine: .evening, title: "Floss", recordedAt: early)
        #expect(glance([], planned: [plan]).routine(.evening).planned == "Floss")
        #expect(glance([], planned: [plan]).routine(.morning).planned == nil)
        #expect(glance([], planned: [plan, .cleared(.evening, at: late)]).routine(.evening).planned == nil)
    }

    // MARK: - Featured routine

    @Test("Morning until noon, evening from noon")
    func featuredByTime() {
        let all = histories([habit("Water", order: 0), habit("Read", order: 0, routine: .evening)])
        #expect(glance(all, hour: 7).featured(at: instant(hour: 7), in: utc) == .morning)
        #expect(glance(all, hour: 11).featured(at: instant(hour: 11), in: utc) == .morning)
        #expect(glance(all, hour: 12).featured(at: instant(hour: 12), in: utc) == .evening)
    }

    @Test("A finished morning hands over to the evening, and never the other way")
    func featuredHandsOver() {
        let water = habit("Water", order: 0), read = habit("Read", order: 0, routine: .evening)

        let morningDone = histories([water, read], doneToday: [water.id])
        #expect(glance(morningDone, hour: 7).featured(at: instant(hour: 7), in: utc) == .evening)

        // Evening finished and morning missed: still the evening, not a morning long gone.
        let eveningDone = histories([water, read], doneToday: [read.id])
        #expect(glance(eveningDone, hour: 21).featured(at: instant(hour: 21), in: utc) == .evening)

        // Nothing left anywhere: the time of day decides.
        let allDone = histories([water, read], doneToday: [water.id, read.id])
        #expect(glance(allDone, hour: 7).featured(at: instant(hour: 7), in: utc) == .morning)
    }

    @Test("A routine with nothing due gives way to one with something due, at any hour")
    func featuredSkipsAnEmptyRoutine() {
        // The case the simulator showed: evening, no evening habits, one morning habit.
        let morningOnly = histories([habit("Water", order: 0)])
        #expect(glance(morningOnly, hour: 21).featured(at: instant(hour: 21), in: utc) == .morning)

        let eveningOnly = histories([habit("Read", order: 0, routine: .evening)])
        #expect(glance(eveningOnly, hour: 7).featured(at: instant(hour: 7), in: utc) == .evening)

        // Nothing due anywhere: the time of day decides.
        #expect(glance([], hour: 21).featured(at: instant(hour: 21), in: utc) == .evening)
    }

    @Test("The hour is read in the person's time zone, not UTC")
    func featuredUsesTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 05:00 UTC is 14:00 in Tokyo.
        let at = instant(hour: 5)
        let result = Glance(histories: [], runs: [:], planned: [:], gateHasUnreadableInput: false, at: at, in: tokyo)
        #expect(result.featured(at: at, in: tokyo) == .evening)
        #expect(result.featured(at: at, in: utc) == .morning)
    }
}

@Suite("Unlock matches the gate")
struct UnlockMatchesGateTests {
    @Test("Open exactly when the lock-in gate would let a habit be added")
    func agreesWithCanAddHabit() {
        // Every mix of a bedded-in habit, a new one and a gapped one, in both routines.
        let patterns = ["", pattern(missesAt: []), pattern(length: 10, missesAt: []),
                        pattern(missesAt: [20, 21]), pattern(missesAt: [1, 5, 9, 13, 17])]
        for first in patterns {
            for second in patterns {
                let histories = [first, second].enumerated().compactMap { index, marks -> HabitHistory? in
                    marks.isEmpty ? nil : makeHistory(marks, order: index)
                }
                let decision = LockInGate.canAddHabit(to: .morning, histories: histories)
                let unlock = RoutineGlance.Unlock(routine: .morning, histories: histories, gateHasUnreadableInput: false)
                #expect(unlock.isOpen == decision.isOpen, "\(first) / \(second)")
            }
        }
    }

    @Test("A cleared plan survives the trip as cleared, even if it arrives padded")
    func paddedTitleDecodesCleared() throws {
        let json = #"{"routine":"morning","title":"  ","recordedAt":0}"#
        let plan = try JSONDecoder().decode(PlannedHabit.self, from: Data(json.utf8))
        #expect(plan.isCleared)
    }
}
