import Foundation
import HabitKit
import SwiftData

/// Materialises the full record shape in the CloudKit **development** schema.
///
/// ### Why this exists instead of `initializeCloudKitSchema()`
///
/// That call belongs to `NSPersistentCloudKitContainer`. SwiftData exposes no equivalent, and
/// no CloudKit surface on `ModelContainer` at all, so the Core Data instruction does not
/// carry over however often it is repeated.
///
/// What SwiftData actually does is create record types and fields lazily, in the development
/// environment, as records are saved. That has a consequence worth stating plainly:
///
/// **A field only exists in the schema once a record carrying a non-nil value for it has been
/// saved.** An optional the development build never populates is simply absent. Promote in
/// that state and it is absent from production too, permanently, because a promoted schema
/// accepts additions but never renames or removals.
///
/// So this writes one record of every synced type with every single field populated, then
/// deletes them. The deletions sync; the schema they created does not go away.
///
/// ### How to use it
///
/// Once, from a **development** build signed into iCloud, before any build reaches TestFlight:
///
/// 1. Run it.
/// 2. Open the CloudKit dashboard and confirm every record type and field is present in the
///    development environment.
/// 3. Only then promote the schema to production.
///
/// Never call it from a shipping build. It writes real records to the user's private database
/// before removing them again, and there is nothing it can do for a schema already promoted.
/// The one fully-populated record of each synced type that priming writes.
///
/// Exposed so a test can assert on the actual property values. `Mirror` cannot do this: a
/// `@Model`'s stored properties are backed by `_$backingData`, and reflection reports
/// `_SwiftDataNoType()` for non-optionals and `nil` for optionals regardless of what was set.
public struct PrimingRecords {
    public let habit: StoredHabit
    public let completion: StoredCompletionEvent
    public let lifecycle: StoredLifecycleEvent
    public let run: StoredRoutineRun
    public let step: StoredRoutineStep
    public let planned: StoredPlannedHabit
}

public enum CloudKitSchemaPriming {

    /// Builds one record of every synced type with every field populated.
    ///
    /// Every optional here must be non-nil. An optional left nil is a column SwiftData never
    /// sees a value for, which means it does not exist in the development schema and is
    /// permanently absent from production once promoted.
    public static func records() -> PrimingRecords {
        let day = DayKey(year: 2000, month: 1, day: 1)
        let instant = Date(timeIntervalSince1970: 946_684_800)
        let habitID = UUID()
        let runID = "priming"

        let run = StoredRoutineRun(
            runID: runID, routineRaw: RoutineSlot.morning.rawValue, dayKeyRaw: day.rawValue,
            startedAt: instant, endedAt: instant, timeZoneIdentifier: "UTC",
            steps: [], payloadJSON: "{}"
        )
        let step = StoredRoutineStep(
            stepID: StoredRoutineStep.stepID(runID: runID, habitID: habitID),
            habitID: habitID, runID: runID, position: 0,
            startedAt: instant, endedAt: instant, run: run, payloadJSON: "{}"
        )

        return PrimingRecords(
            habit: StoredHabit(
                habitID: habitID,
                title: "schema priming",
                cue: "schema priming",
                twoMinuteVersion: "schema priming",
                identityStatement: "schema priming",
                routineRaw: RoutineSlot.morning.rawValue,
                order: 0,
                scheduleKindRaw: StoredSchedule.Kind.daysOfWeek.rawValue,
                scheduleDayMask: StoredSchedule.validMask,
                completionSourceRaw: CompletionSource.automatic.rawValue,
                startedOnRaw: day.rawValue,
                payloadJSON: "{}"
            ),
            completion: StoredCompletionEvent(
                eventID: "priming", habitID: habitID, dayKeyRaw: day.rawValue, slotIndex: 0,
                statusRaw: CompletionEvent.Status.completed.rawValue,
                sourceRaw: CompletionSource.automatic.rawValue,
                occurredAt: instant, recordedAt: instant,
                timeZoneIdentifier: "UTC", payloadJSON: "{}"
            ),
            lifecycle: StoredLifecycleEvent(
                eventID: "priming", habitID: habitID, dayKeyRaw: day.rawValue,
                stateRaw: LifecycleEvent.State.active.rawValue,
                occurredAt: instant, timeZoneIdentifier: "UTC", payloadJSON: "{}"
            ),
            run: run,
            step: step,
            planned: StoredPlannedHabit(
                routineRaw: RoutineSlot.morning.rawValue, title: "schema priming",
                recordedAt: instant, payloadJSON: "{}"
            )
        )
    }
}

extension HabitStoreActor {

    /// Writes and then removes one fully-populated record of every synced model.
    ///
    /// Returns the record types it touched, so the caller can print them against the
    /// dashboard rather than eyeballing the list.
    @discardableResult
    public func primeCloudKitSchema() throws -> [String] {
        let records = CloudKitSchemaPriming.records()

        modelContext.insert(records.habit)
        modelContext.insert(records.completion)
        modelContext.insert(records.lifecycle)
        modelContext.insert(records.run)
        modelContext.insert(records.step)
        modelContext.insert(records.planned)
        // The relationship is a field on both sides, so it has to be exercised too.
        records.run.steps = [records.step]
        try modelContext.save()

        for object in [records.habit, records.completion, records.lifecycle,
                       records.step, records.run, records.planned] as [any PersistentModel] {
            modelContext.delete(object)
        }
        try modelContext.save()

        return HabitSchemaV1.synced.map(String.init(describing:))
    }
}
