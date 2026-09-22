import Foundation
@testable import HabitKit

/// A fixed Monday, so weekday-sensitive tests read the same every run.
let referenceToday = DayKey(year: 2026, month: 9, day: 21)

/// Builds a habit and its logs from a compact pattern.
///
/// Each character is one scheduled occurrence: `C` completed, `M` missed. The last character
/// is yesterday, so `"CCM"` means done two days ago, done three days ago, missed yesterday.
/// Only valid for daily habits; weekly schedules get their own explicit fixtures.
func makeHistory(
    _ pattern: String,
    today: DayKey = referenceToday,
    completedToday: Bool = false,
    state: LifecycleEvent.State = .active,
    stateChangedOn: DayKey? = nil,
    routine: RoutineSlot = .morning,
    order: Int = 0,
    id: UUID = UUID()
) -> HabitHistory {
    let marks = Array(pattern)
    let startedOn = today.advanced(by: -marks.count)

    let habit = Habit(
        id: id,
        title: "Test habit",
        routine: routine,
        order: order,
        schedule: .daily,
        startedOn: startedOn
    )

    var events = marks.enumerated().compactMap { index, mark -> CompletionEvent? in
        guard mark == "C" else { return nil }
        return CompletionEvent(
            habitID: habit.id,
            dayKey: startedOn.advanced(by: index),
            occurredAt: .distantPast,
            timeZoneIdentifier: "UTC"
        )
    }

    if completedToday {
        events.append(CompletionEvent(
            habitID: habit.id,
            dayKey: today,
            occurredAt: .distantPast,
            timeZoneIdentifier: "UTC"
        ))
    }

    // Defaults to taking effect today, so the pattern describes history that still counts.
    var lifecycle: [LifecycleEvent] = []
    if state != .active {
        lifecycle.append(LifecycleEvent(
            habitID: habit.id,
            dayKey: stateChangedOn ?? today,
            state: state,
            occurredAt: .distantPast,
            timeZoneIdentifier: "UTC"
        ))
    }

    return HabitHistory(habit: habit, events: events, lifecycle: lifecycle, today: today)
}

/// A pattern of the given length that is all completions except at the given indices.
func pattern(length: Int = 28, missesAt misses: Set<Int>) -> String {
    (0..<length).map { misses.contains($0) ? "M" : "C" }.joined()
}

/// A completion on every day the habit was scheduled, for fixtures built by hand.
func completeEveryScheduledDay(_ habit: Habit, through end: DayKey) -> [CompletionEvent] {
    habit.startedOn.through(end)
        .filter { habit.isScheduled(on: $0) }
        .map { CompletionEvent(habitID: habit.id, dayKey: $0, occurredAt: .distantPast, timeZoneIdentifier: "UTC") }
}
