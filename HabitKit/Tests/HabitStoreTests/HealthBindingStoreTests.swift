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

@Suite("Health binding races and duplicates")
struct HealthBindingDuplicateTests {

    @Test("Duplicate rows for one habit load as one binding, the furthest reconciled")
    @MainActor
    func duplicatesCollapse() async throws {
        let (store, container) = try makeStore()
        let habitID = UUID()
        for day in [referenceToday.advanced(by: -5), referenceToday.advanced(by: -2)] {
            container.mainContext.insert(StoredHealthBinding(
                habitID: habitID, signalRaw: HealthSignal.workout.rawValue,
                externalIdentifier: "52", lastReconciledDayRaw: day.rawValue))
        }
        try container.mainContext.save()

        let loaded = try await store.loadHealthBindings().values
        #expect(loaded.count == 1)
        #expect(loaded.first?.lastReconciledDay == referenceToday.advanced(by: -2))
    }

    @Test("Advancing a binding that was removed meanwhile does not bring it back")
    func advanceAfterUnlink() async throws {
        let (store, _) = try makeStore()
        let binding = HealthBinding(habitID: UUID(), signal: .workout, externalIdentifier: "52",
                                    lastReconciledDay: referenceToday.advanced(by: -3))
        try await store.upsert(binding)
        try await store.removeHealthBinding(for: binding.habitID)

        let advanced = try await store.advanceReconciliation(of: binding, through: referenceToday.advanced(by: -1))
        #expect(advanced == false)
        #expect(try await store.loadHealthBindings().values.isEmpty)
    }

    @Test("Advancing a binding that was relinked meanwhile leaves the new link alone")
    func advanceAfterRelink() async throws {
        let (store, _) = try makeStore()
        let habitID = UUID()
        let run = HealthBinding(habitID: habitID, signal: .workout, externalIdentifier: "37",
                                lastReconciledDay: referenceToday.advanced(by: -3))
        try await store.upsert(run)
        let walk = HealthBinding(habitID: habitID, signal: .workout, externalIdentifier: "52",
                                 lastReconciledDay: referenceToday)
        try await store.upsert(walk)

        try await store.advanceReconciliation(of: run, through: referenceToday.advanced(by: -1))
        #expect(try await store.loadHealthBindings().values == [walk])
    }

    @Test("Advancing never moves the reconciled day backwards")
    func neverBackwards() async throws {
        let (store, _) = try makeStore()
        let binding = HealthBinding(habitID: UUID(), signal: .workout, externalIdentifier: "52",
                                    lastReconciledDay: referenceToday.advanced(by: -1))
        try await store.upsert(binding)
        try await store.advanceReconciliation(of: binding, through: referenceToday.advanced(by: -4))
        #expect(try await store.loadHealthBindings().values.first?.lastReconciledDay == referenceToday.advanced(by: -1))
    }

    @Test("Only unreadable habits and lifecycle events count as able to open the gate")
    func gateRelevance() {
        #expect(StoreMappingError.recordIsNewerThanThisBuild(record: "StoredHabit(x)", recordVersion: 2, understood: 1).couldOpenGate)
        #expect(StoreMappingError.invalidDayKey(record: "StoredLifecycleEvent(x)", field: "dayKeyRaw", raw: 0).couldOpenGate)
        #expect(StoreMappingError.invalidDayKey(record: "StoredCompletionEvent(x)", field: "dayKeyRaw", raw: 0).couldOpenGate == false)
        #expect(StoreMappingError.invalidDayKey(record: "StoredRoutineRun(x)", field: "dayKeyRaw", raw: 0).couldOpenGate == false)
    }
}
