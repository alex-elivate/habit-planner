import Foundation
import HabitKit
import SwiftData

/// What a bulk read produced, and what it could not.
///
/// Failures are returned rather than swallowed. One unreadable row must not blank a widget,
/// and it must not vanish either: a store that quietly drops records is how a score ends up
/// subtly wrong with nothing anywhere saying so.
public struct LoadResult<Value: Sendable>: Sendable {
    public let values: [Value]
    public let skipped: [StoreMappingError]

    public init(values: [Value], skipped: [StoreMappingError] = []) {
        self.values = values
        self.skipped = skipped
    }

    public var hasFailures: Bool { !skipped.isEmpty }
}

/// The only writer to the store, and the only place deduplication happens.
///
/// A `@ModelActor` because `ModelContext` is not `Sendable` and Swift 6 strict concurrency is
/// on from day one. Everything crossing the boundary is a HabitKit value type, never a
/// `@Model` object, so nothing that is not `Sendable` can escape.
///
/// ### Deduplication
///
/// CloudKit has no unique constraints and SwiftData forbids `@Attribute(.unique)` on a synced
/// model, so nothing below this layer stops the same event existing twice. Every write here
/// collapses whatever already carries the same content-addressed identifier, and it does so
/// by calling the domain's own `resolved()` and `deduplicated()` rather than reimplementing
/// the rule. Reimplementing it would mean two copies of a subtle precedence rule that must
/// agree forever, and they would stop agreeing.
///
/// Read-side resolution still runs on top of this, because a write cannot stop a peer's row
/// arriving tomorrow.
@ModelActor
public actor HabitStoreActor {

    // MARK: - Habits

    /// Inserts a habit, or updates the one already carrying its identifier.
    public func upsert(_ habit: Habit) throws {
        let id = habit.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredHabit>(predicate: #Predicate { $0.habitID == id })
        )
        if let row = existing.first {
            row.update(from: habit)
            // A duplicate habit row can only come from sync. The rows describe the same
            // habit, so keeping the first and dropping the rest converges on every device.
            for extra in existing.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredHabit(habit))
        }
        try modelContext.save()
    }

    public func loadHabits() throws -> LoadResult<Habit> {
        let rows = try modelContext.fetch(FetchDescriptor<StoredHabit>())
        var values: [Habit] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        // Sorted on the way out. A SwiftData fetch has no inherent order, and a routine whose
        // steps reshuffled between launches would be its own bug.
        values.sort { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        return LoadResult(values: values, skipped: skipped)
    }

    // MARK: - Completions

    /// Records an assertion about a day, collapsing it with anything already asserted.
    ///
    /// Returns the rows it could not read. Those are left in place rather than deleted: they
    /// are a bug in whatever wrote them, and destroying the evidence while the user is trying
    /// to tick a habit helps nobody. The write still goes through.
    @discardableResult
    public func record(_ event: CompletionEvent) throws -> [StoreMappingError] {
        let id = event.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredCompletionEvent>(predicate: #Predicate { $0.eventID == id })
        )

        var assertions: [CompletionEvent] = [event]
        var readable: [StoredCompletionEvent] = []
        var skipped: [StoreMappingError] = []
        for row in existing {
            do {
                assertions.append(try row.toDomain())
                readable.append(row)
            } catch let error as StoreMappingError {
                skipped.append(error)
            }
        }

        // Every assertion shares one identifier, so exactly one survives the fold.
        guard let winner = assertions.resolved().first else { return skipped }

        if let row = readable.first {
            row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredCompletionEvent(winner))
        }

        try modelContext.save()
        return skipped
    }

    /// Records a completion only if nothing has ever been asserted about that day.
    ///
    /// This is the write an outside signal is allowed to make, and the restriction is the
    /// whole point of it. A bounded reconciliation on launch re-reads a trailing window of
    /// HealthKit, and a plain `record` would give the backfill a fresh `recordedAt` that beat
    /// the user's retraction — so a habit they explicitly un-ticked would tick itself again
    /// the next morning, repeatedly, with no way to make it stop.
    ///
    /// Guarding on "no assertion at all" rather than on "no completion" is deliberate: a
    /// retraction is an assertion, and it is precisely the one that must not be overridden.
    /// It also removes any need to remember which health samples have already been consumed,
    /// because event identifiers are content-addressed and re-reading the same day produces
    /// the identifier that is already there.
    ///
    /// Returns `true` if it wrote. `false` means the day already had an answer.
    @discardableResult
    public func propose(_ event: CompletionEvent) throws -> Bool {
        let id = event.id
        var descriptor = FetchDescriptor<StoredCompletionEvent>(predicate: #Predicate { $0.eventID == id })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return false }

        modelContext.insert(StoredCompletionEvent(event))
        try modelContext.save()
        return true
    }

    /// Undoes a completion by appending a contrary assertion, never by deleting one.
    @discardableResult
    public func retract(
        habitID: UUID,
        dayKey: DayKey,
        slotIndex: Int = 0,
        at instant: Date,
        timeZoneIdentifier: String
    ) throws -> [StoreMappingError] {
        try record(
            CompletionEvent(
                habitID: habitID,
                dayKey: dayKey,
                slotIndex: slotIndex,
                status: .retracted,
                occurredAt: instant,
                recordedAt: instant,
                timeZoneIdentifier: timeZoneIdentifier
            )
        )
    }

    public func loadCompletionEvents(for habitID: UUID? = nil) throws -> LoadResult<CompletionEvent> {
        var descriptor = FetchDescriptor<StoredCompletionEvent>()
        if let habitID {
            descriptor.predicate = #Predicate { $0.habitID == habitID }
        }
        let rows = try modelContext.fetch(descriptor)

        var values: [CompletionEvent] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        // Resolved on the way out, because a peer's duplicate can arrive after any write.
        return LoadResult(values: values.resolved(), skipped: skipped)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func record(_ event: LifecycleEvent) throws -> [StoreMappingError] {
        let id = event.eventIdentifier
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredLifecycleEvent>(predicate: #Predicate { $0.eventID == id })
        )

        var assertions: [LifecycleEvent] = [event]
        var readable: [StoredLifecycleEvent] = []
        var skipped: [StoreMappingError] = []
        for row in existing {
            do {
                assertions.append(try row.toDomain())
                readable.append(row)
            } catch let error as StoreMappingError {
                skipped.append(error)
            }
        }

        guard let winner = assertions.deduplicated().first else { return skipped }

        if let row = readable.first {
            row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredLifecycleEvent(winner))
        }

        try modelContext.save()
        return skipped
    }

    public func loadLifecycleEvents(for habitID: UUID? = nil) throws -> LoadResult<LifecycleEvent> {
        var descriptor = FetchDescriptor<StoredLifecycleEvent>()
        if let habitID {
            descriptor.predicate = #Predicate { $0.habitID == habitID }
        }
        let rows = try modelContext.fetch(descriptor)

        var values: [LifecycleEvent] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        return LoadResult(values: values.deduplicated(), skipped: skipped)
    }

    // MARK: - Routine runs

    /// Inserts a run, or merges into the one already recorded for that routine and day.
    ///
    /// Steps are matched by their own content address and updated in place. A step absent
    /// from `run` is left alone rather than deleted, because absence far more often means
    /// "not reached yet", or "this device has not heard about it", than "removed".
    public func upsert(_ run: RoutineRun) throws {
        let id = run.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredRoutineRun>(predicate: #Predicate { $0.runID == id })
        )

        let row: StoredRoutineRun
        if let first = existing.first {
            first.update(from: run)
            for extra in existing.dropFirst() { modelContext.delete(extra) }
            row = first
        } else {
            row = StoredRoutineRun(
                runID: run.id,
                routineRaw: run.routine.rawValue,
                dayKeyRaw: run.dayKey.rawValue,
                startedAt: run.startedAt,
                endedAt: run.endedAt,
                timeZoneIdentifier: run.timeZoneIdentifier,
                steps: []
            )
            modelContext.insert(row)
        }

        var byID = Dictionary(
            (row.steps ?? []).map { ($0.stepID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for step in run.steps {
            let stepID = StoredRoutineStep.stepID(runID: run.id, habitID: step.habitID)
            if let existingStep = byID[stepID] {
                existingStep.update(from: step)
            } else {
                let new = StoredRoutineStep(step, runID: run.id)
                new.run = row
                modelContext.insert(new)
                byID[stepID] = new
            }
        }

        try modelContext.save()
    }

    public func loadRoutineRuns() throws -> LoadResult<RoutineRun> {
        let rows = try modelContext.fetch(FetchDescriptor<StoredRoutineRun>())
        var values: [RoutineRun] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        values.sort { $0.dayKey == $1.dayKey ? $0.id < $1.id : $0.dayKey < $1.dayKey }
        return LoadResult(values: values, skipped: skipped)
    }

    // MARK: - The fold

    /// Every habit's logs folded into the shape scoring and the lock-in gate read from.
    ///
    /// This is the one read the app actually uses. Events are grouped by habit before the
    /// fold rather than handed to each history whole, which keeps it linear instead of
    /// quadratic on a path that runs inside a widget extension.
    public func loadHistories(today: DayKey) throws -> LoadResult<HabitHistory> {
        let habits = try loadHabits()
        let completions = try loadCompletionEvents()
        let lifecycle = try loadLifecycleEvents()

        let completionsByHabit = Dictionary(grouping: completions.values, by: \.habitID)
        let lifecycleByHabit = Dictionary(grouping: lifecycle.values, by: \.habitID)

        let histories = habits.values.map { habit in
            HabitHistory(
                habit: habit,
                events: completionsByHabit[habit.id] ?? [],
                lifecycle: lifecycleByHabit[habit.id] ?? [],
                today: today
            )
        }

        return LoadResult(
            values: histories,
            skipped: habits.skipped + completions.skipped + lifecycle.skipped
        )
    }
}

extension LifecycleEvent {
    /// `id` under a name a `#Predicate` can close over without ambiguity.
    fileprivate var eventIdentifier: String { id }
}
