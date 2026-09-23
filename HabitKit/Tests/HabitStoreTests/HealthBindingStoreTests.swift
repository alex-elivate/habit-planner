import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

@Suite("Health bindings")
struct HealthBindingStoreTests {

    @Test("A binding round-trips every field")
    func roundTrip() async throws {
        let (store, _) = try makeStore()
        let binding = HealthBinding(habitID: UUID(), signal: .medication,
                                    externalIdentifier: "archived-concept", lastReconciledDay: referenceToday)
        try await store.upsert(binding)
        #expect(try await store.loadHealthBindings().values == [binding])
    }

    @Test("Saving again replaces rather than adding a second binding")
    func replaces() async throws {
        let (store, _) = try makeStore()
        let habitID = UUID()
        try await store.upsert(HealthBinding(habitID: habitID, signal: .workout, externalIdentifier: "52",
                                             lastReconciledDay: referenceToday.advanced(by: -3)))
        let caughtUp = HealthBinding(habitID: habitID, signal: .workout, externalIdentifier: "52",
                                     lastReconciledDay: referenceToday.advanced(by: -1))
        try await store.upsert(caughtUp)
        #expect(try await store.loadHealthBindings().values == [caughtUp])
    }

    @Test("Unlinking removes the binding and leaves the habit's completions alone")
    func removeKeepsHistory() async throws {
        let (store, _) = try makeStore()
        let habit = sampleHabit(source: .automatic)
        try await store.upsert(habit)
        try await store.record(completion(habit.id, referenceToday.advanced(by: -1)))
        try await store.upsert(HealthBinding(habitID: habit.id, signal: .workout, lastReconciledDay: referenceToday))

        try await store.removeHealthBinding(for: habit.id)
        #expect(try await store.loadHealthBindings().values.isEmpty)
        #expect(try await store.loadCompletionEvents(for: habit.id).values.count == 1)
    }

    @Test("A binding with the zero default day is skipped, not read as year zero")
    @MainActor
    func zeroDayRejected() async throws {
        let (store, container) = try makeStore()
        container.mainContext.insert(StoredHealthBinding(habitID: UUID(), signalRaw: HealthSignal.workout.rawValue))
        try container.mainContext.save()

        let result = try await store.loadHealthBindings()
        #expect(result.values.isEmpty)
        #expect(result.skipped.count == 1)
    }

    @Test("An unknown signal is skipped rather than guessed at")
    @MainActor
    func unknownSignal() async throws {
        let (store, container) = try makeStore()
        container.mainContext.insert(StoredHealthBinding(habitID: UUID(), signalRaw: "mindfulness",
                                                         lastReconciledDayRaw: referenceToday.rawValue))
        try container.mainContext.save()
        #expect(try await store.loadHealthBindings().skipped.count == 1)
    }
}
