import Foundation
import HabitKit
import Testing
@testable import HabitStore

@Suite("List actions")
struct ListActionTests {

    let utc = TimeZone(identifier: "UTC")!
    var morning: Date { Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400 + 7 * 3_600) }

    func habit(_ title: String, order: Int) -> Habit {
        Habit(title: title, routine: .morning, order: order, startedOn: referenceToday.advanced(by: -5))
    }

    func states(_ store: HabitStoreActor) async throws -> [UUID: StepState] {
        let histories = try await store.loadHistories(today: referenceToday).values
        let run = try await store.loadRoutineRuns().values.first
        return RoutineRunner.states(of: .morning, histories: histories, run: run, at: morning, in: utc)
    }

    @Test("Done, skip, and undoing each, through the store")
    @MainActor
    func roundTrip() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        try await store.upsert(water)
        try await store.upsert(stretch)

        #expect(try await store.apply(.complete(), to: water.id, on: referenceToday, at: morning, timeZone: utc))
        #expect(try await store.apply(.skip, to: stretch.id, on: referenceToday, at: morning, timeZone: utc))
        var now = try await states(store)
        #expect(now[water.id] == .done)
        #expect(now[stretch.id] == .skipped)

        // The widget and Siri agree: nothing left.
        #expect(try await store.completeCurrentStep(in: .morning, at: morning, timeZone: utc) == .nothingLeft)

        // Not done: the completion is retracted and the step reopened, so it is next again.
        #expect(try await store.apply(.reopen, to: water.id, on: referenceToday, at: morning.addingTimeInterval(5), timeZone: utc))
        now = try await states(store)
        #expect(now[water.id] == .next)

        // Unskip.
        #expect(try await store.apply(.reopen, to: stretch.id, on: referenceToday, at: morning.addingTimeInterval(6), timeZone: utc))
        now = try await states(store)
        #expect(now[stretch.id] == .waiting)
        #expect(try await store.apply(.reopen, to: stretch.id, on: referenceToday, at: morning, timeZone: utc) == false)
    }

    @Test("A skipped habit can be done later without reopening it")
    @MainActor
    func doneAfterSkip() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0)
        try await store.upsert(water)
        try await store.apply(.skip, to: water.id, on: referenceToday, at: morning, timeZone: utc)
        #expect(try await store.apply(.complete(), to: water.id, on: referenceToday, at: morning.addingTimeInterval(60), timeZone: utc))
        #expect(try await states(store)[water.id] == .done)
        // Done twice is a no-op.
        #expect(try await store.apply(.complete(), to: water.id, on: referenceToday, at: morning, timeZone: utc) == false)
    }

    @Test("A Health match keeps the time Health reported")
    @MainActor
    func healthTime() async throws {
        let (store, _) = try makeStore()
        let meds = habit("Meds", order: 0)
        try await store.upsert(meds)
        let taken = morning.addingTimeInterval(-1_800)
        try await store.apply(.complete(occurredAt: taken), to: meds.id, on: referenceToday, at: morning, timeZone: utc)
        let event = try #require(try await store.loadCompletionEvents(for: meds.id).values.first)
        #expect(event.occurredAt == taken)
        #expect(event.source == .automatic)
    }

    @Test("An icon survives the store")
    @MainActor
    func iconRoundTrip() async throws {
        let (store, _) = try makeStore()
        var water = habit("Water", order: 0)
        water.symbolName = "drop.fill"
        water.tint = .teal
        try await store.upsert(water)
        let loaded = try #require(try await store.loadHabits().values.first)
        #expect(loaded.symbolName == "drop.fill")
        #expect(loaded.tint == .teal)
    }

    @Test("Unskip survives a stale copy of the run from the watch")
    @MainActor
    func unskipSurvivesWatchReport() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0), stretch = habit("Stretch", order: 1)
        try await store.upsert(water)
        try await store.upsert(stretch)

        try await store.apply(.skip, to: water.id, on: referenceToday, at: morning, timeZone: utc)
        // What the watch holds after the next snapshot: water skipped.
        let stale = try #require(try await store.loadRoutineRuns().values.first)

        try await store.apply(.reopen, to: water.id, on: referenceToday, at: morning.addingTimeInterval(60), timeZone: utc)
        #expect(try await states(store)[water.id] == .next)

        // The watch sends its copy back, as it does after any tick there.
        _ = try await store.merge(WatchReport(earliestDay: referenceToday, completions: [], runs: [stale]))
        #expect(try await states(store)[water.id] == .next, "The stale copy closed the step again")

        // And a skip after the reopen still wins over both.
        try await store.apply(.skip, to: water.id, on: referenceToday, at: morning.addingTimeInterval(120), timeZone: utc)
        _ = try await store.merge(WatchReport(earliestDay: referenceToday, completions: [], runs: [stale]))
        #expect(try await states(store)[water.id] == .skipped)
    }

    @Test("A write from a device that has not heard of a reopen does not undo it")
    @MainActor
    func staleWriterKeepsReopen() async throws {
        let (store, _) = try makeStore()
        let water = habit("Water", order: 0)
        try await store.upsert(water)
        try await store.apply(.skip, to: water.id, on: referenceToday, at: morning, timeZone: utc)
        let stale = try #require(try await store.loadRoutineRuns().values.first)
        try await store.apply(.reopen, to: water.id, on: referenceToday, at: morning.addingTimeInterval(60), timeZone: utc)

        try await store.upsert(stale)
        #expect(try await states(store)[water.id] == .next)
    }

    @Test("Health counts a habit nobody has had a say on, and never one they have")
    @MainActor
    func proposeRespectsThePerson() async throws {
        let (store, _) = try makeStore()
        let meds = habit("Meds", order: 0), water = habit("Water", order: 1)
        try await store.upsert(meds)
        try await store.upsert(water)
        let taken = morning.addingTimeInterval(-600)

        #expect(try await store.apply(.propose(occurredAt: taken), to: meds.id, on: referenceToday, at: morning, timeZone: utc))
        let event = try #require(try await store.loadCompletionEvents(for: meds.id).values.first)
        #expect(event.source == .automatic)
        #expect(event.occurredAt == taken)
        #expect(try await states(store)[meds.id] == .done)

        // Undone: the retraction is the person's say, so Health does not count it again.
        try await store.apply(.reopen, to: meds.id, on: referenceToday, at: morning.addingTimeInterval(5), timeZone: utc)
        #expect(try await store.apply(.propose(occurredAt: taken), to: meds.id, on: referenceToday, at: morning.addingTimeInterval(10), timeZone: utc) == false)
        #expect(try await states(store)[meds.id] == .next)

        // Skipped is not a say about done: the run step is not an assertion.
        try await store.apply(.skip, to: water.id, on: referenceToday, at: morning, timeZone: utc)
        #expect(try await store.apply(.propose(occurredAt: taken), to: water.id, on: referenceToday, at: morning.addingTimeInterval(20), timeZone: utc))
    }
}
