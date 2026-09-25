import Foundation
import HabitKit
import Testing
@testable import HabitStore

@Suite("Complete the current step")
struct CompleteCurrentStepTests {

    let utc = TimeZone(identifier: "UTC")!
    /// 07:00 UTC on `referenceToday`.
    var morning: Date { Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400 + 7 * 3_600) }

    func habit(_ title: String, order: Int, routine: RoutineSlot = .morning) -> Habit {
        Habit(title: title, routine: routine, order: order, startedOn: referenceToday.advanced(by: -5))
    }

    @Test("Ticks habits in sequence, one per call, and says what comes next")
    @MainActor
    func inSequence() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        // Stored out of order, as a fetch can return them.
        try await store.upsert(stretch)
        try await store.upsert(water)

        #expect(try await store.completeCurrentStep(in: .morning, at: morning, timeZone: utc)
                == .completed(done: "Water", next: "Stretch", remaining: 1))
        #expect(try await store.completeCurrentStep(in: .morning, at: morning.addingTimeInterval(60), timeZone: utc)
                == .completed(done: "Stretch", next: nil, remaining: 0))
        #expect(try await store.completeCurrentStep(in: .morning, at: morning.addingTimeInterval(120), timeZone: utc)
                == .nothingLeft)

        let histories = try await store.loadHistories(today: referenceToday).values
        #expect(histories.allSatisfy { $0.isCompletedToday })
        let run = try #require(try await store.loadRoutineRuns().values.first)
        #expect(run.dayKey == referenceToday)
        #expect(Set(run.steps.filter { $0.endedAt != nil }.map(\.habitID)) == [water.id, stretch.id])
    }

    @Test("A step skipped in the runner stays skipped")
    @MainActor
    func respectsSkips() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        try await store.upsert(water)
        try await store.upsert(stretch)

        var runner = RoutineRunner(routine: .morning,
                                   histories: try await store.loadHistories(today: referenceToday).values,
                                   at: morning, in: utc)
        runner.skip(at: morning)
        try await store.upsert(runner.run)

        #expect(try await store.completeCurrentStep(in: .morning, at: morning.addingTimeInterval(60), timeZone: utc)
                == .completed(done: "Stretch", next: nil, remaining: 0))
        let water2 = try await store.loadHistories(today: referenceToday).values.first { $0.habit.id == water.id }
        #expect(water2?.isCompletedToday == false)
    }

    @Test("A habit already ticked from the list is not ticked again")
    @MainActor
    func skipsTickedHabits() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        try await store.upsert(water)
        try await store.upsert(stretch)
        try await store.record(CompletionEvent(habitID: water.id, dayKey: referenceToday,
                                               occurredAt: morning, timeZoneIdentifier: "UTC"))

        #expect(try await store.completeCurrentStep(in: .morning, at: morning, timeZone: utc)
                == .completed(done: "Stretch", next: nil, remaining: 0))
    }

    @Test("Only the named routine is touched, and an empty one says so")
    @MainActor
    func routineScoped() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(habit("Water", order: 0))
        #expect(try await store.completeCurrentStep(in: .evening, at: morning, timeZone: utc) == .nothingDue)
        #expect(try await store.loadCompletionEvents().values.isEmpty)
        #expect(try await store.loadRoutineRuns().values.isEmpty, "A routine with nothing due leaves no run")
    }

    @Test("The store's glance is the same fold the widget used to build by hand")
    @MainActor
    func glanceMatchesManualFold() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(habit("Water", order: 0))
        try await store.record(PlannedHabit(routine: .morning, title: "Meditate", recordedAt: morning))
        _ = try await store.completeCurrentStep(in: .morning, at: morning, timeZone: utc)

        let glance = try await store.glance(at: morning, in: utc)
        let manual = Glance(
            histories: try await store.loadHistories(today: referenceToday).values,
            runs: Dictionary(uniqueKeysWithValues: try await store.loadRoutineRuns().values.map { ($0.routine, $0) }),
            planned: try await store.loadPlannedHabits().values.resolved(),
            gateHasUnreadableInput: false, at: morning, in: utc)
        #expect(glance == manual)
        #expect(glance.routine(.morning).progress == Progress(completed: 1, total: 1))
        #expect(glance.routine(.morning).planned == "Meditate")
    }
}

@Suite("Glances for a timeline")
struct GlancesTests {
    @Test("Each instant gets the fold for its own day, and matches a single glance")
    @MainActor
    func perInstant() async throws {
        let (store, _) = try makeStore()
        let utc = TimeZone(identifier: "UTC")!
        let seven = Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400 + 7 * 3_600)
        try await store.upsert(Habit(title: "Water", routine: .morning, order: 0, startedOn: referenceToday.advanced(by: -5)))
        _ = try await store.completeCurrentStep(in: .morning, at: seven, timeZone: utc)

        let noon = seven.addingTimeInterval(5 * 3_600)
        let midnight = seven.addingTimeInterval(17 * 3_600)
        let glances = try await store.glances(at: [seven, noon, midnight], in: utc)
        #expect(glances.count == 3)
        #expect(glances[0] == (try await store.glance(at: seven, in: utc)))
        #expect(glances[1].routine(.morning).progress == Progress(completed: 1, total: 1))
        #expect(glances[2].day == referenceToday.advanced(by: 1))
        #expect(glances[2].routine(.morning).progress == Progress(completed: 0, total: 1),
                "Tomorrow starts undone")
    }
}
