#if DEBUG
import Foundation
import HabitKit
import HabitStore

/// A few weeks of plausible history for the simulator and for screenshots.
///
/// Debug only, and only ever written into the in-memory store. See `StoreMode`. Shared by the
/// iPhone and watch apps, and neither one bridges to the other in that mode, so demo habits
/// can never reach a real replica.
enum DemoData {
    static func seed(into store: HabitStoreActor, timeZone: TimeZone = .current) async {
        let today = DayKey(.now, in: timeZone)

        let habits = [
            Habit(title: "Drink a glass of water", cue: "After I turn off my alarm",
                  twoMinuteVersion: "Fill the glass", identityStatement: "I look after my body",
                  routine: .morning, order: 0, startedOn: today.advanced(by: -60)),
            Habit(title: "Stretch", cue: "After I drink my water",
                  twoMinuteVersion: "Touch my toes once", identityStatement: "I'm someone who moves every morning",
                  routine: .morning, order: 1, startedOn: today.advanced(by: -40)),
            Habit(title: "Walk the dog", cue: "After I stretch",
                  twoMinuteVersion: "Put on my shoes",
                  routine: .morning, order: 2, schedule: .daysOfWeek([.monday, .wednesday, .friday]),
                  startedOn: today.advanced(by: -20)),
            Habit(title: "Read ten pages", cue: "After I get into bed",
                  twoMinuteVersion: "Read one page", identityStatement: "I'm a reader",
                  routine: .evening, order: 0, startedOn: today.advanced(by: -35)),
        ]

        for habit in habits {
            try? await store.upsert(habit)
            for day in habit.startedOn.through(today.advanced(by: -1)) where habit.isScheduled(on: day) {
                // Roughly nine in ten, deterministic so screenshots are repeatable.
                guard (day.ordinal + habit.order * 3) % 10 != 0 else { continue }
                let instant = day.start(in: timeZone).addingTimeInterval(7.5 * 3_600)
                _ = try? await store.record(CompletionEvent(
                    habitID: habit.id, dayKey: day, occurredAt: instant, timeZoneIdentifier: timeZone.identifier))
            }
        }
    }
}
#endif
