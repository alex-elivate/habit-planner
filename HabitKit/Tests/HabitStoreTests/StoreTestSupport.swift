import Foundation
import HabitKit
import SwiftData
@testable import HabitStore

/// A fixed Monday, matching HabitKit's own fixtures.
let referenceToday = DayKey(year: 2026, month: 9, day: 21)

/// An in-memory store, torn down with the test.
func makeContainer() throws -> ModelContainer {
    try HabitStoreContainer.container(role: .inMemory)
}

func makeStore() throws -> (HabitStoreActor, ModelContainer) {
    let container = try makeContainer()
    return (HabitStoreActor(modelContainer: container), container)
}

func sampleHabit(
    id: UUID = UUID(),
    schedule: Schedule = .daily,
    source: CompletionSource = .manual,
    startedOn: DayKey = referenceToday.advanced(by: -30)
) -> Habit {
    Habit(
        id: id,
        title: "Walk the dog",
        cue: "after I pour my coffee",
        twoMinuteVersion: "put on my shoes",
        identityStatement: "I'm someone who moves every morning",
        routine: .morning,
        order: 2,
        schedule: schedule,
        completionSource: source,
        startedOn: startedOn
    )
}

func completion(
    _ habitID: UUID,
    _ day: DayKey,
    status: CompletionEvent.Status = .completed,
    occurredAt: Date = Date(timeIntervalSince1970: 1_000),
    recordedAt: Date? = nil
) -> CompletionEvent {
    CompletionEvent(
        habitID: habitID,
        dayKey: day,
        slotIndex: 0,
        status: status,
        occurredAt: occurredAt,
        recordedAt: recordedAt ?? occurredAt,
        timeZoneIdentifier: "Europe/London"
    )
}
