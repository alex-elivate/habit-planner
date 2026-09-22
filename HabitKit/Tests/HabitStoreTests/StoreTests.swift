import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

@Suite("Store")
struct StoreTests {

    // MARK: Deduplication

    @Test("Recording the same completion twice leaves one row")
    @MainActor
    func writingTwiceKeepsOneRow() async throws {
        let (store, container) = try makeStore()
        let event = completion(UUID(), referenceToday.advanced(by: -1))

        try await store.record(event)
        try await store.record(event)

        let rows = try container.mainContext.fetchCount(FetchDescriptor<StoredCompletionEvent>())
        #expect(rows == 1)
    }

    @Test("A retraction beats the completion it undoes, whichever arrives first")
    @MainActor
    func retractionWins() async throws {
        for reversed in [false, true] {
            let (store, _) = try makeStore()
            let habitID = UUID()
            let done = completion(habitID, referenceToday.advanced(by: -1),
                                  occurredAt: t(1_000), recordedAt: t(1_000))
            let undone = done.retracted(at: t(5_000))

            // Arrival order must not matter. Conflicts resolve on `recordedAt`, not on
            // whichever device's write happened to land first.
            let order = reversed ? [undone, done] : [done, undone]
            for event in order { try await store.record(event) }

            let loaded = try await store.loadCompletionEvents()
            #expect(loaded.values.count == 1)
            #expect(loaded.values.first?.status == .retracted)
        }
    }

    @Test("Re-completing after a retraction wins again")
    @MainActor
    func recompletionWins() async throws {
        let (store, _) = try makeStore()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)

        try await store.record(completion(habitID, day, occurredAt: t(1_000), recordedAt: t(1_000)))
        try await store.retract(habitID: habitID, dayKey: day, at: t(2_000), timeZoneIdentifier: "UTC")
        try await store.record(completion(habitID, day, occurredAt: t(1_000), recordedAt: t(3_000)))

        let loaded = try await store.loadCompletionEvents()
        #expect(loaded.values.first?.status == .completed)
        // The surviving moment is when the habit was actually done, not when it was re-asserted.
        #expect(loaded.values.first?.occurredAt == t(1_000))
    }

    @Test("Duplicate rows arriving from a peer resolve on read")
    @MainActor
    func syncDuplicatesResolveOnRead() async throws {
        // Neither CloudKit nor SwiftData can enforce uniqueness on a synced model, so a write
        // cannot stop a peer's row landing tomorrow. These rows are inserted underneath the
        // writer on purpose, which is exactly how sync delivers them.
        let container = try makeContainer()
        let habitID = UUID()
        let done = completion(habitID, referenceToday.advanced(by: -2),
                              occurredAt: t(1_000), recordedAt: t(1_000))
        let undone = done.retracted(at: t(5_000))

        container.mainContext.insert(StoredCompletionEvent(done))
        container.mainContext.insert(StoredCompletionEvent(undone))
        try container.mainContext.save()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredCompletionEvent>()) == 2)

        let store = HabitStoreActor(modelContainer: container)
        let loaded = try await store.loadCompletionEvents()
        #expect(loaded.values.count == 1)
        #expect(loaded.values.first?.status == .retracted)
    }

    @Test("A later write collapses duplicate rows a peer already delivered")
    @MainActor
    func writingCollapsesPeerDuplicates() async throws {
        let container = try makeContainer()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -2)
        let done = completion(habitID, day, occurredAt: t(1_000), recordedAt: t(1_000))

        container.mainContext.insert(StoredCompletionEvent(done))
        container.mainContext.insert(StoredCompletionEvent(done))
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        try await store.retract(habitID: habitID, dayKey: day, at: t(9_000), timeZoneIdentifier: "UTC")

        let rows = try container.mainContext.fetchCount(FetchDescriptor<StoredCompletionEvent>())
        #expect(rows == 1)
    }

    @Test("Upserting a habit updates in place rather than forking it")
    @MainActor
    func habitUpsertUpdatesInPlace() async throws {
        let (store, container) = try makeStore()
        let id = UUID()
        var habit = sampleHabit(id: id)

        try await store.upsert(habit)
        habit.title = "Walk the other dog"
        habit.order = 9
        try await store.upsert(habit)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredHabit>()) == 1)
        let loaded = try await store.loadHabits()
        #expect(loaded.values.count == 1)
        #expect(loaded.values.first?.title == "Walk the other dog")
        #expect(loaded.values.first?.order == 9)
    }

    // MARK: Proposals from an outside signal

    @Test("A proposal never overwrites an answer the person already gave")
    @MainActor
    func proposalDoesNotOverrideARetraction() async throws {
        // This is the reason reconciliation needs no ledger of consumed health samples. It
        // re-reads the same trailing window on every launch, and the guard is that the day
        // already has an answer, whatever that answer is.
        let (store, _) = try makeStore()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)

        try await store.record(completion(habitID, day, occurredAt: t(1_000), recordedAt: t(1_000)))
        try await store.retract(habitID: habitID, dayKey: day, at: t(2_000), timeZoneIdentifier: "UTC")

        // A backfill on the next two launches re-reads the same walk.
        let firstWrote = try await store.propose(
            completion(habitID, day, occurredAt: t(1_000), recordedAt: t(80_000)))
        let secondWrote = try await store.propose(
            completion(habitID, day, occurredAt: t(1_000), recordedAt: t(160_000)))

        #expect(firstWrote == false)
        #expect(secondWrote == false)
        let loaded = try await store.loadCompletionEvents()
        #expect(loaded.values.first?.status == .retracted)
    }

    @Test("A proposal fills a day nobody has answered")
    @MainActor
    func proposalFillsAnUnansweredDay() async throws {
        let (store, _) = try makeStore()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -4)

        #expect(try await store.propose(completion(habitID, day)) == true)
        // Idempotent: the same day re-read on the next launch writes nothing further.
        #expect(try await store.propose(completion(habitID, day)) == false)

        let loaded = try await store.loadCompletionEvents()
        #expect(loaded.values.count == 1)
        #expect(loaded.values.first?.status == .completed)
    }

    // MARK: The fold

    @Test("The fold matches computing the same history in memory")
    @MainActor
    func foldMatchesTheDomain() async throws {
        let (store, _) = try makeStore()
        let habit = sampleHabit(startedOn: referenceToday.advanced(by: -10))
        try await store.upsert(habit)

        var events: [CompletionEvent] = []
        for offset in 1...10 where offset != 4 {
            let event = completion(habit.id, referenceToday.advanced(by: -offset))
            events.append(event)
            try await store.record(event)
        }

        let fromStore = try await store.loadHistories(today: referenceToday)
        let inMemory = HabitHistory(habit: habit, events: events, today: referenceToday)

        #expect(fromStore.hasFailures == false)
        #expect(fromStore.values.count == 1)
        #expect(fromStore.values.first == inMemory)
        #expect(ScoreEngine.score(for: fromStore.values) == ScoreEngine.score(for: [inMemory]))
    }

    @Test("One habit's pause does not pause another through the store")
    @MainActor
    func lifecycleDoesNotLeakThroughTheStore() async throws {
        // The store is the first caller that hands the whole lifecycle log to every habit,
        // because that is what one fetch returns.
        let (store, _) = try makeStore()
        let start = referenceToday.advanced(by: -10)
        let paused = sampleHabit(startedOn: start)
        let active = sampleHabit(startedOn: start)

        try await store.upsert(paused)
        try await store.upsert(active)
        try await store.record(LifecycleEvent(habitID: paused.id, dayKey: start.advanced(by: 1),
                                              state: .paused, occurredAt: t(0),
                                              timeZoneIdentifier: "UTC"))

        let histories = try await store.loadHistories(today: referenceToday)
        let activeHistory = try #require(histories.values.first { $0.habit.id == active.id })
        let pausedHistory = try #require(histories.values.first { $0.habit.id == paused.id })

        #expect(activeHistory.currentState == .active)
        #expect(activeHistory.settledOccurrences.count == 10)
        #expect(pausedHistory.currentState == .paused)
    }

    // MARK: Routine runs

    @Test("A run accumulates steps across writes without forking")
    @MainActor
    func runAccumulatesSteps() async throws {
        let (store, container) = try makeStore()
        let first = UUID(), second = UUID()

        var run = RoutineRun(routine: .morning, dayKey: referenceToday,
                             startedAt: t(1_000), timeZoneIdentifier: "UTC")
        run.steps = [RoutineStep(habitID: first, position: 0, startedAt: t(1_000))]
        try await store.upsert(run)

        // The first step finishes and the second is reached.
        run.steps = [
            RoutineStep(habitID: first, position: 0, startedAt: t(1_000), endedAt: t(1_120)),
            RoutineStep(habitID: second, position: 1, startedAt: t(1_120))
        ]
        run.endedAt = t(1_300)
        try await store.upsert(run)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRoutineRun>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRoutineStep>()) == 2)

        let loaded = try await store.loadRoutineRuns()
        let restored = try #require(loaded.values.first)
        #expect(restored.steps.map(\.habitID) == [first, second])
        #expect(restored.steps[0].duration == 120)
        #expect(restored.duration == 300)
    }

    @Test("A second routine on the same day is a separate run")
    @MainActor
    func morningAndEveningAreSeparateRuns() async throws {
        let (store, _) = try makeStore()
        try await store.upsert(RoutineRun(routine: .morning, dayKey: referenceToday,
                                          timeZoneIdentifier: "UTC"))
        try await store.upsert(RoutineRun(routine: .evening, dayKey: referenceToday,
                                          timeZoneIdentifier: "UTC"))
        let loaded = try await store.loadRoutineRuns()
        #expect(loaded.values.count == 2)
    }

    // MARK: Failures surface

    @Test("An unreadable row is reported rather than silently dropped")
    @MainActor
    func unreadableRowsAreReported() async throws {
        let container = try makeContainer()
        let habit = sampleHabit()
        container.mainContext.insert(StoredHabit(habit))
        // A habit whose start day never made it across.
        container.mainContext.insert(StoredHabit(habitID: UUID(), title: "broken", startedOnRaw: 0))
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        let loaded = try await store.loadHabits()

        #expect(loaded.values.count == 1)
        #expect(loaded.skipped.count == 1)
        #expect(loaded.hasFailures)
    }
}
