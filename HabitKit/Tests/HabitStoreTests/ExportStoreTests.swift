import Foundation
import HabitKit
import Testing
@testable import HabitStore

@Suite("Export store")
struct ExportStoreTests {

    @Test("An export holds every kind of record the store has")
    @MainActor
    func holdsEverything() async throws {
        let (store, _) = try makeStore()
        let habit = sampleHabit()
        try await store.upsert(habit)
        try await store.record(completion(habit.id, referenceToday))
        try await store.record(LifecycleEvent(habitID: habit.id, state: .paused, at: Date(timeIntervalSince1970: 2_000),
                                              in: TimeZone(identifier: "Europe/London")!))
        try await store.record(PlannedHabit(routine: .morning, title: "Stretch", recordedAt: Date(timeIntervalSince1970: 3_000)))

        let export = try await store.export(at: Date(timeIntervalSince1970: 4_000))
        #expect(export.habits.map(\.id) == [habit.id])
        #expect(export.completions.map(\.dayKey) == [referenceToday])
        #expect(export.lifecycle.map(\.state) == [.paused])
        #expect(export.plannedHabits.map(\.title) == ["Stretch"])
        #expect(export.unreadableRecords.isEmpty)
    }
}
